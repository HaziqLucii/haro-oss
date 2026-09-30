import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';

enum BufferPhase { loading, ready, guarded, failed, mixedEndings }

enum LineEnding { none, lf, crlf, cr, mixed }

/// Which line ending [text] uses. `mixed` when more than one kind occurs: re_editor joins
/// every line with a single break, so saving such a file would rewrite the odd lines.
LineEnding detectLineEnding(String text) {
  var crlf = 0;
  var lf = 0;
  var cr = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x0D) {
      if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) {
        crlf++;
        i++;
      } else {
        cr++;
      }
    } else if (c == 0x0A) {
      lf++;
    }
  }
  final kinds = (crlf > 0 ? 1 : 0) + (lf > 0 ? 1 : 0) + (cr > 0 ? 1 : 0);
  if (kinds > 1) return LineEnding.mixed;
  if (crlf > 0) return LineEnding.crlf;
  if (cr > 0) return LineEnding.cr;
  if (lf > 0) return LineEnding.lf;
  return LineEnding.none;
}

const mixedEndingsNote = 'Mixed line endings: edit in your editor';

/// One file open in the Edit tab. Held by the step, not the editor widget, so flipping to
/// Diff and back does not throw unsaved edits away.
class EditBuffer extends ChangeNotifier {
  EditBuffer(this.path);

  /// Follows the file when the explorer renames it, so the buffer (and its unsaved edits)
  /// keeps its place instead of being reloaded from a path that no longer exists.
  String path;

  BufferPhase phase = BufferPhase.loading;
  CodeLineEditingController? controller;

  /// What the backend last confirmed. Dirty is text != saved, so undoing back to the
  /// original clears the unsaved state.
  String saved = '';

  /// Set when the backend refuses the file (too large or binary): no editor is shown and
  /// saving is off, so an empty buffer can never overwrite the real bytes.
  String? guardReason;
  int? guardSize;
  String? loadError;

  /// Vertical scroll position kept for the tab so coming back lands where you left.
  double scrollOffset = 0;

  bool saving = false;
  bool justSaved = false;
  String? saveError;

  /// The file on disk no longer matches what this buffer last read or wrote, and the buffer
  /// has unsaved edits: a save has to ask before it overwrites the other change.
  bool diskConflict = false;
  Future<void>? _inflight;
  bool _dirty = false;
  CodeLines? _lines;
  bool _disposed = false;

  bool get dirty => _dirty;
  bool get canSave => phase == BufferPhase.ready && !saving;

  Future<void> load(Future<FileContent> Function() read) async {
    try {
      final f = await read();
      if (_disposed) return;
      if (f.error != null) {
        phase = BufferPhase.guarded;
        guardReason = f.error;
        guardSize = f.size;
      } else {
        final ending = detectLineEnding(f.content);
        if (ending == LineEnding.mixed) {
          phase = BufferPhase.mixedEndings;
        } else {
          saved = _normalise(f.content);
          controller = CodeLineEditingController.fromText(
            saved,
            CodeLineOptions(
              lineBreak: switch (ending) {
                LineEnding.crlf => TextLineBreak.crlf,
                LineEnding.cr => TextLineBreak.cr,
                _ => TextLineBreak.lf,
              },
            ),
          )..addListener(_onChanged);
          _lines = controller!.codeLines;
          phase = BufferPhase.ready;
        }
      }
    } on HaroApiException catch (e) {
      if (_disposed) return;
      phase = BufferPhase.failed;
      loadError = e.message;
    } on Object catch (e) {
      if (_disposed) return;
      phase = BufferPhase.failed;
      loadError = e.toString();
    }
    notifyListeners();
  }

  /// Re-reads the file and swaps in what the agent (or another tool) wrote, keeping the
  /// controller, so the cursor and scroll stay. A buffer with unsaved edits is never touched.
  Future<void> refreshIfClean(Future<FileContent> Function() read) async {
    final c = controller;
    if (phase != BufferPhase.ready || c == null || _dirty || saving) return;
    try {
      final f = await read();
      if (_disposed || _dirty || saving || f.error != null) return;
      if (detectLineEnding(f.content) == LineEnding.mixed) return;
      final text = _normalise(f.content);
      if (text == saved) return;
      saved = text;
      c.text = text;
      notifyListeners();
    } on Object {
      return;
    }
  }

  void _onChanged() {
    final c = controller;
    if (c == null) return;
    // Cursor moves notify too; only an edit swaps the lines.
    if (identical(c.codeLines, _lines)) return;
    _lines = c.codeLines;
    final next = _normalise(c.text) != saved;
    var changed = false;
    if (next != _dirty) {
      _dirty = next;
      changed = true;
    }
    if (next && (justSaved || saveError != null)) {
      justSaved = false;
      saveError = null;
      changed = true;
    }
    if (!next && diskConflict) {
      diskConflict = false;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// The controller joins with its own line break, so a CRLF file stays CRLF on disk while
  /// `saved` is kept LF-normalised for comparison.
  String _normalise(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  String get currentText => controller == null ? saved : controller!.text;

  /// Whether the file on disk differs from [saved], the text last read or written here.
  /// A file that cannot be read now (deleted, guarded) is not a conflict: the write recreates it.
  Future<bool> changedOnDisk(Future<FileContent> Function() read) async {
    // A save in flight is about to move [saved] to what it writes; reading disk now would
    // report our own write as someone else's change.
    while (_inflight != null) {
      await _inflight;
    }
    if (phase != BufferPhase.ready) return false;
    try {
      final f = await read();
      if (_disposed || f.error != null) return false;
      return _normalise(f.content) != saved;
    } on Object {
      return false;
    }
  }

  void markDiskConflict(bool on) {
    if (diskConflict == on) return;
    diskConflict = on;
    notifyListeners();
  }

  /// Throws the unsaved edits away for what is on disk now ("Reload" in the conflict bar).
  Future<void> reloadFromDisk(Future<FileContent> Function() read) async {
    final c = controller;
    if (c == null) return;
    try {
      final f = await read();
      if (_disposed || f.error != null) return;
      if (detectLineEnding(f.content) == LineEnding.mixed) return;
      saved = _normalise(f.content);
      c.text = saved;
      _dirty = false;
      diskConflict = false;
      saveError = null;
      justSaved = false;
      notifyListeners();
    } on Object {
      return;
    }
  }

  /// Writes the buffer. A save already in flight is waited for, not refused: whoever asked
  /// second gets the outcome once the file is settled, and writes again only if edits landed
  /// meanwhile.
  Future<bool> save(Future<void> Function(String content) write) async {
    var waited = false;
    while (_inflight != null) {
      waited = true;
      await _inflight;
    }
    if (_disposed) return true;
    if (waited && !_dirty && saveError == null) return true;
    if (!canSave) return false;
    final done = Completer<void>();
    _inflight = done.future;
    try {
      return await _write(write);
    } finally {
      _inflight = null;
      done.complete();
    }
  }

  Future<bool> _write(Future<void> Function(String content) write) async {
    final text = currentText;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      await write(text);
      if (_disposed) return true;
      saved = _normalise(text);
      saving = false;
      _dirty = _normalise(currentText) != saved;
      justSaved = !_dirty;
      diskConflict = false;
      notifyListeners();
      return true;
    } on HaroApiException catch (e) {
      _failSave(e.message);
    } on Object catch (e) {
      _failSave(e.toString());
    }
    return false;
  }

  void _failSave(String message) {
    if (_disposed) return;
    saving = false;
    justSaved = false;
    saveError = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    controller?.removeListener(_onChanged);
    controller?.dispose();
    super.dispose();
  }
}
