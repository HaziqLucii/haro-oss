import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import 'edit_buffer.dart';

/// Open editor buffers for one workspace, keyed by path. The page swaps the step body when
/// the user goes to another step, which disposes the code step's widgets; a buffer with
/// unsaved edits must outlive that, so the store holds a keep-alive link for as long as any
/// buffer is dirty and lets everything go once they are saved or discarded.
final codeBuffersProvider = Provider.autoDispose
    .family<CodeBufferStore, String>((ref, id) {
      final store = CodeBufferStore(ref.keepAlive);
      ref.onDispose(store.dispose);
      return store;
    });

class CodeBufferStore extends ChangeNotifier {
  CodeBufferStore(this._keepAlive);

  final KeepAliveLink Function() _keepAlive;
  final _buffers = <String, EditBuffer>{};
  KeepAliveLink? _link;
  bool _disposed = false;

  EditBuffer? bufferFor(String path) => _buffers[path];

  Set<String> get dirtyPaths => {
    for (final e in _buffers.entries)
      if (e.value.dirty) e.key,
  };

  /// Buffers flagged deleted on disk, unsaved edits or not: a dirty one outlives the step, so its
  /// flag can be stale when the step comes back.
  Set<String> get missingPaths => {
    for (final e in _buffers.entries)
      if (e.value.missingOnDisk) e.key,
  };

  /// The buffer for [path], created and loaded from [read] only when there is none yet. Every
  /// open tab holds one, so switching tabs never drops or re-reads it.
  EditBuffer ensure(String path, Future<FileContent> Function() read) {
    final existing = _buffers[path];
    if (existing != null) return existing;
    final b = EditBuffer(path)..addListener(_onBufferChanged);
    _buffers[path] = b;
    b.load(read);
    _syncLink();
    return b;
  }

  /// Drops every buffer whose path is not in [keep] and has no unsaved edits. Dirty buffers of
  /// closed tabs are only dropped by an explicit [drop] (the user discarded them).
  void retainOnly(Set<String> keep) {
    final gone = [
      for (final e in _buffers.entries)
        if (!keep.contains(e.key) && !e.value.dirty) e.key,
    ];
    for (final path in gone) {
      drop(path);
    }
  }

  /// A fresh buffer for [path], loaded from [read]. A dirty one is kept and returned as is:
  /// unsaved edits are never replaced by a re-read.
  EditBuffer open(String path, Future<FileContent> Function() read) {
    final existing = _buffers[path];
    if (existing != null && existing.dirty) return existing;
    existing?.dispose();
    final b = EditBuffer(path)..addListener(_onBufferChanged);
    _buffers[path] = b;
    b.load(read);
    _syncLink();
    return b;
  }

  void drop(String path) {
    final b = _buffers.remove(path);
    if (b == null) return;
    b.removeListener(_onBufferChanged);
    b.dispose();
    _syncLink();
    notifyListeners();
  }

  static bool _under(String prefix, String path) =>
      path == prefix || path.startsWith('$prefix/');

  /// Buffers with unsaved edits at [path] or, for a folder, below it.
  Set<String> dirtyUnder(String path) => {
    for (final p in dirtyPaths)
      if (_under(path, p)) p,
  };

  /// Re-keys the buffer for [from] (and every one below it, for a folder) to [to]: the file
  /// was renamed, and its unsaved edits, scroll and cursor go with it.
  void moveUnder(String from, String to) {
    final moving = [
      for (final p in _buffers.keys)
        if (_under(from, p)) p,
    ];
    if (moving.isEmpty) return;
    final taken = {for (final p in moving) p: _buffers.remove(p)!};
    for (final e in taken.entries) {
      final next = '$to${e.key.substring(from.length)}';
      _buffers.remove(next)?.dispose();
      e.value.path = next;
      _buffers[next] = e.value;
    }
    notifyListeners();
  }

  /// Drops the buffers at [path] or below it, unsaved edits included (the file was deleted
  /// and the user was told).
  void dropUnder(String path) {
    for (final p in [
      for (final p in _buffers.keys)
        if (_under(path, p)) p,
    ]) {
      drop(p);
    }
  }

  /// Disposes every buffer without unsaved edits (the step is going away).
  void releaseClean() {
    for (final path in [
      for (final e in _buffers.entries)
        if (!e.value.dirty) e.key,
    ]) {
      final b = _buffers.remove(path)!;
      b.removeListener(_onBufferChanged);
      b.dispose();
    }
    _syncLink();
  }

  void _onBufferChanged() {
    _syncLink();
    if (!_disposed) notifyListeners();
  }

  void _syncLink() {
    final dirty = _buffers.values.any((b) => b.dirty);
    if (dirty && _link == null && !_disposed) {
      _link = _keepAlive();
    } else if (!dirty && _link != null) {
      final link = _link!;
      _link = null;
      link.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final b in _buffers.values) {
      b.removeListener(_onBufferChanged);
      b.dispose();
    }
    _buffers.clear();
    super.dispose();
  }
}

/// Writes every buffer with unsaved edits, in order. Throws on the first that cannot be saved,
/// so a gate run never starts on a tree that is missing the user's last edits. A file that
/// changed or vanished on disk since it was opened is refused by the backend (409), not
/// overwritten: its buffer is flagged, the rest are still written, and the throw names the
/// files to open and answer (Overwrite or Reload, Save anyway or Close).
Future<void> saveDirtyBuffers(
  CodeBufferStore store,
  WorkspaceActions actions,
) async {
  final changed = <String>[];
  final deleted = <String>[];
  for (final path in store.dirtyPaths) {
    final b = store.bufferFor(path);
    // A save that was in flight meanwhile may already have written it.
    if (b == null || !b.dirty) continue;
    final ok = await b.save(
      (content, etag) => actions.saveFile(path, content, expectedEtag: etag),
    );
    if (ok) continue;
    if (b.saveError == null && b.diskConflict) {
      changed.add(path);
    } else if (b.saveError == null && b.missingOnDisk) {
      deleted.add(path);
    } else {
      throw HaroApiException(
        0,
        'Could not save $path: ${b.saveError ?? 'unknown error'}',
      );
    }
  }
  if (changed.isNotEmpty) {
    throw HaroApiException(
      0,
      '${changed.join(', ')} changed on disk since you opened '
      '${changed.length == 1 ? 'it' : 'them'}: open the file to overwrite or reload.',
    );
  }
  if (deleted.isNotEmpty) {
    throw HaroApiException(
      0,
      '${deleted.join(', ')} ${deleted.length == 1 ? 'was' : 'were'} deleted '
      'on disk: open the file to save it again or close it.',
    );
  }
}
