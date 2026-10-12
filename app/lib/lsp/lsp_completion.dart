import 'dart:async';

import 'package:flutter/widgets.dart'
    show
        Action,
        AxisDirection,
        BuildContext,
        CallbackAction,
        Intent,
        ValueNotifier;
import 'package:flutter/foundation.dart' show ValueChanged, VoidCallback;
import 'package:flutter/services.dart' show TextSelection;
import 'package:re_editor/re_editor.dart';

import 'lsp_client.dart';
import 'lsp_edits.dart';

/// One server suggestion, reduced to what the list and the insertion need.
class LspItem {
  const LspItem({
    required this.label,
    required this.insertText,
    required this.sortText,
    required this.kind,
    required this.raw,
  });

  final String label;
  final String insertText;
  final String sortText;
  final int? kind;

  /// The item as the server sent it: `completionItem/resolve` wants it back untouched.
  final Map<String, Object?> raw;

  /// One mono letter for the LSP `CompletionItemKind`.
  String get kindLetter => switch (kind) {
    2 || 3 || 4 => 'f',
    5 || 10 => 'p',
    6 || 21 => 'v',
    7 => 'c',
    8 => 'i',
    9 => 'm',
    13 || 20 => 'e',
    14 => 'k',
    _ => ' ',
  };
}

/// What the cursor is completing: the identifier typed so far (maybe empty) and whether a
/// member access `.` triggered it. Null when nothing should open a list (whitespace, digits,
/// a spread, punctuation).
({String word, bool dot})? completionTrigger(String lineText, int offset) {
  final before = lineText.substring(0, offset.clamp(0, lineText.length));
  final m = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*$').firstMatch(before);
  if (m != null) {
    final start = m.start;
    if (start > 0 && RegExp(r'[0-9]').hasMatch(before[start - 1])) return null;
    return (word: m.group(0)!, dot: false);
  }
  if (before.endsWith('.') &&
      !before.endsWith('..') &&
      !RegExp(r'[0-9]\.$').hasMatch(before)) {
    return (word: '', dot: true);
  }
  return null;
}

/// Filters the server's list to what the typed [word] allows, in the server's `sortText`
/// order, one row per label, at most [cap]. The server sends everything in scope and leaves
/// filtering to the client. An item whose own `textEdit` is not the plain word replacement
/// (for example it rewrites the preceding `.`) is dropped: the editor can only replace the word.
List<LspItem> rankCompletionItems(
  Object? result, {
  required String word,
  required int line,
  required int cursor,
  int cap = 50,
}) {
  final raw = switch (result) {
    final List<Object?> l => l,
    final Map<Object?, Object?> m when m['items'] is List => m['items'] as List,
    _ => const <Object?>[],
  };
  final wordStart = cursor - word.length;
  final lower = word.toLowerCase();
  final out = <(int, LspItem)>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final item = entry.cast<String, Object?>();
    final label = item['label'];
    if (label is! String || label.isEmpty) continue;
    final filter = item['filterText'];
    final key = (filter is String && filter.isNotEmpty ? filter : label)
        .toLowerCase();
    if (!key.startsWith(lower)) continue;
    final insert = _insertText(item, label, line, wordStart, cursor);
    if (insert == null) continue;
    final sort = item['sortText'];
    final kind = item['kind'];
    out.add((
      out.length,
      LspItem(
        label: label,
        insertText: insert,
        sortText: sort is String ? sort : label,
        kind: kind is int ? kind : null,
        raw: item,
      ),
    ));
  }
  out.sort((a, b) {
    final c = a.$2.sortText.compareTo(b.$2.sortText);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final seen = <String>{};
  final items = <LspItem>[];
  for (final (_, it) in out) {
    if (!seen.add(it.label)) continue;
    items.add(it);
    if (items.length >= cap) break;
  }
  return items;
}

String? _insertText(
  Map<String, Object?> item,
  String label,
  int line,
  int wordStart,
  int cursor,
) {
  final edit = item['textEdit'];
  if (edit is Map) {
    final range = edit['range'] ?? edit['insert'];
    final newText = edit['newText'];
    if (range is! Map || newText is! String) return null;
    final s = range['start'];
    final e = range['end'];
    if (s is! Map || e is! Map) return null;
    final fits =
        s['line'] == line &&
        e['line'] == line &&
        s['character'] == wordStart &&
        e['character'] == cursor;
    return fits ? newText : null;
  }
  final text = item['insertText'];
  return text is String && text.isNotEmpty ? text : label;
}

/// A prompt that accepts like any other word and, the one time the editor reads
/// [autocomplete] (Enter and a click both read it exactly once, and nothing else may), schedules
/// [onAccepted] after the word has been inserted. That is the only hook covering both
/// accept paths: re_editor's Enter key never goes through the view builder's `onSelected`.
class LspPrompt extends CodePrompt {
  LspPrompt(this.item, this.onAccepted) : super(word: item.insertText);

  final LspItem item;
  final void Function(LspPrompt) onAccepted;
  bool _fired = false;

  @override
  CodeAutocompleteResult get autocomplete {
    if (!_fired) {
      _fired = true;
      scheduleMicrotask(() => onAccepted(this));
    }
    return CodeAutocompleteResult.fromWord(word);
  }

  @override
  bool match(String input) => true;
}

/// Stands in while the server has not answered. The overlay, once shown, owns Enter, so an
/// Enter that lands here must still break the line.
class _Placeholder extends CodePrompt {
  _Placeholder(this.onEnter) : super(word: '');

  final VoidCallback onEnter;

  @override
  CodeAutocompleteResult get autocomplete {
    scheduleMicrotask(onEnter);
    return CodeAutocompleteResult.fromWord('');
  }

  @override
  bool match(String input) => false;
}

/// Applies a resolved item's `additionalTextEdits` (the auto-import) as one undo step and
/// keeps the selection on the same text. Only edits that sit wholly above the cursor line,
/// or insert whole lines at its column 0, are applied; anything else, or any range outside
/// the buffer, skips the lot rather than corrupt text.
///
/// [since] is the buffer's lines when the edits were requested. The user may have typed
/// meanwhile: the edits still apply when every line they touch is unchanged, shifted by the
/// number of lines inserted or removed above them; a changed touched line skips the lot.
bool applyAdditionalEdits(
  CodeLineEditingController c,
  Object? rawEdits, {
  List<String>? since,
}) {
  if (hasFolds(c)) return false;
  var edits = parseTextEdits(rawEdits);
  if (edits == null || edits.isEmpty) return false;
  if (since != null) {
    final now = [for (var i = 0; i < c.lineCount; i++) c.codeLines[i].text];
    final shift = _shiftFor(since, now, edits);
    if (shift == null) return false;
    if (shift != 0) {
      edits = [
        for (final e in edits)
          LspTextEdit(e.sl + shift, e.sc, e.el + shift, e.ec, e.text),
      ];
    }
  }
  final sel = c.selection;
  final top = sel.startIndex;
  var shift = 0;
  for (final e in edits) {
    final inBuffer =
        e.sl >= 0 &&
        e.el < c.lineCount &&
        (e.sl < e.el || (e.sl == e.el && e.sc <= e.ec)) &&
        e.sc >= 0 &&
        e.sc <= c.codeLines[e.sl].length &&
        e.ec <= c.codeLines[e.el].length;
    if (!inBuffer) return false;
    final lines = '\n'.allMatches(e.text).length - (e.el - e.sl);
    if (e.el < top) {
      shift += lines;
    } else if (e.sl == e.el &&
        e.el == top &&
        e.sc == 0 &&
        e.ec == 0 &&
        e.text.endsWith('\n')) {
      shift += lines;
    } else {
      return false;
    }
  }
  // Bottom-up so earlier ranges stay valid. Inserts at one position must read in array order
  // in the result, so among ties the later edit goes in first (the server relies on this
  // for `import type { FC }` becoming `import { useState, type FC }`).
  final all = edits;
  final order = [for (var i = 0; i < all.length; i++) i]
    ..sort((a, b) {
      final x = all[a], y = all[b];
      if (x.sl != y.sl) return y.sl - x.sl;
      if (x.sc != y.sc) return y.sc - x.sc;
      return b - a;
    });
  c.runRevocableOp(() {
    for (final e in [for (final i in order) all[i]]) {
      c.replaceSelection(
        e.text,
        CodeLineSelection(
          baseIndex: e.sl,
          baseOffset: e.sc,
          extentIndex: e.el,
          extentOffset: e.ec,
        ),
      );
    }
  });
  c.selection = CodeLineSelection(
    baseIndex: sel.baseIndex + shift,
    baseOffset: sel.baseOffset,
    extentIndex: sel.extentIndex + shift,
    extentOffset: sel.extentOffset,
  );
  return true;
}

/// How many lines to move [edits] by so they hit the same text in [now] as in [then], or null
/// when a line they touch changed. Edits are measured against the unchanged head of the buffer,
/// or, when the user changed lines above them, its unchanged tail.
int? _shiftFor(List<String> then, List<String> now, List<LspTextEdit> edits) {
  var first = then.length;
  var last = -1;
  for (final e in edits) {
    if (e.sl < first) first = e.sl;
    if (e.el > last) last = e.el;
  }
  if (first < 0 || last >= then.length) return null;
  var head = 0;
  while (head < then.length && head < now.length && then[head] == now[head]) {
    head++;
  }
  if (last < head) return 0;
  var tail = 0;
  while (tail < then.length - head &&
      tail < now.length - head &&
      then[then.length - 1 - tail] == now[now.length - 1 - tail]) {
    tail++;
  }
  return first >= then.length - tail ? now.length - then.length : null;
}

const _dismissResult = CodeAutocompleteResult(
  input: '',
  word: '',
  selection: TextSelection.collapsed(offset: 0),
);

class _NavigateAction extends CallbackAction<CodeShortcutCursorMoveIntent> {
  _NavigateAction(this._c) : super(onInvoke: _c._navigate);

  final LspCompletionController _c;

  @override
  bool get isActionEnabled => _c.listShowing;

  @override
  bool consumesKey(CodeShortcutCursorMoveIntent intent) =>
      intent.direction == AxisDirection.up ||
      intent.direction == AxisDirection.down;
}

class _Session {
  _Session({
    required this.id,
    required this.word,
    required this.line,
    required this.cursor,
    required this.version,
    required this.dot,
  });

  final int id;
  final String word;
  final int line;
  final int cursor;
  final int version;
  final bool dot;

  ValueNotifier<CodeAutocompleteEditingValue>? notifier;
  ValueChanged<CodeAutocompleteResult>? onSelected;
  List<LspItem>? items;
  bool cancelled = false;
  bool pushed = false;
  bool shown = false;
  Timer? _timer;
  Completer<bool>? _sleeper;

  Future<bool> sleep(Duration d) {
    final c = Completer<bool>();
    _sleeper = c;
    _timer = Timer(d, () {
      if (!c.isCompleted) c.complete(true);
    });
    return c.future;
  }

  void cancel() {
    cancelled = true;
    _timer?.cancel();
    final s = _sleeper;
    if (s != null && !s.isCompleted) s.complete(false);
  }
}

/// Feeds re_editor's autocomplete overlay from the language server. It is the editor's
/// prompts builder: [build] answers at once with an invisible placeholder (the builder is
/// synchronous), starts the request, and pushes the real list into the overlay's notifier when
/// it lands, provided that request is still the newest and the text has not changed.
class LspCompletionController implements CodeAutocompletePromptsBuilder {
  LspCompletionController({
    required this.client,
    required this.uri,
    required this.controller,
    this.retryDelay = const Duration(milliseconds: 700),
    this.maxTries = 3,
    this.cap = 50,
  });

  final LspClient client;
  final String uri;
  final CodeLineEditingController controller;

  /// The first completion after `didOpen` can lack module exports (tsserver builds them
  /// asynchronously, and `isIncomplete` does not say so): a document's first answer is asked
  /// again, and the list is replaced if the later answer differs.
  final Duration retryDelay;
  final int maxTries;
  final int cap;

  int _seq = 0;
  _Session? _current;
  bool _warm = false;
  bool _disposed = false;

  @override
  CodeAutocompleteEditingValue? build(
    BuildContext context,
    CodeLine codeLine,
    CodeLineSelection selection,
  ) {
    if (_disposed || client.status == LspStatus.unavailable) return null;
    final trigger = completionTrigger(codeLine.text, selection.extentOffset);
    final version = client.versionOf(uri);
    // The server counts every line; the selection counts only the unfolded ones.
    final line = controller.index2lineIndex(selection.extentIndex);
    if (trigger == null || version == null || line < 0) return null;
    _current?.cancel();
    final s = _Session(
      id: ++_seq,
      word: trigger.word,
      line: line,
      cursor: selection.extentOffset,
      version: version,
      dot: trigger.dot,
    );
    _current = s;
    unawaited(_run(s));
    return CodeAutocompleteEditingValue(
      input: s.word,
      prompts: [_Placeholder(controller.applyNewLine)],
      index: 0,
    );
  }

  bool _live(_Session s) =>
      !_disposed &&
      !s.cancelled &&
      s.id == _seq &&
      client.versionOf(uri) == s.version;

  Future<void> _run(_Session s) async {
    List<LspItem>? last;
    for (var attempt = 1; ; attempt++) {
      final raw = await client.completion(
        uri,
        s.line,
        s.cursor,
        triggerCharacter: s.dot ? '.' : null,
      );
      if (!_live(s)) return;
      final items = rankCompletionItems(
        raw,
        word: s.word,
        line: s.line,
        cursor: s.cursor,
        cap: cap,
      );
      final changed =
          items.isNotEmpty && (last == null || !_sameLabels(last, items));
      if (items.isNotEmpty && changed) {
        last = items;
        _deliver(s, items, force: attempt > 1);
      }
      // A cold document's first answer is not final even when it has rows: the module
      // exports (`useState` from react) arrive on a later request. Ask again until two
      // answers agree, so the cost is paid once per document.
      final settled =
          _warm ||
          attempt >= maxTries ||
          client.status != LspStatus.ready ||
          (attempt > 1 && last != null && !changed);
      if (settled) {
        _warm = true;
        if (last == null) _deliver(s, const []);
        return;
      }
      if (!await s.sleep(retryDelay) || !_live(s)) return;
    }
  }

  static bool _sameLabels(List<LspItem> a, List<LspItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label) return false;
    }
    return true;
  }

  void _deliver(_Session s, List<LspItem> items, {bool force = false}) {
    s.items = items;
    _push(s, force: force);
  }

  void _push(_Session s, {bool force = false}) {
    final n = s.notifier;
    final items = s.items;
    if (n == null || items == null || s.cancelled) return;
    if (s.pushed && !force) return;
    s.pushed = true;
    if (items.isEmpty) {
      // An overlay with nothing to offer would still swallow Enter and the arrow keys.
      s.onSelected?.call(_dismissResult);
      return;
    }
    s.shown = true;
    n.value = CodeAutocompleteEditingValue(
      input: s.word,
      index: 0,
      prompts: [for (final it in items) LspPrompt(it, _accepted)],
    );
  }

  /// Called by the overlay view when it mounts, with the notifier this keystroke's overlay
  /// owns. Returns the detach to call when the view goes away, which ends any retries.
  VoidCallback attach(
    ValueNotifier<CodeAutocompleteEditingValue> notifier,
    ValueChanged<CodeAutocompleteResult> onSelected,
  ) {
    final s = _current;
    if (s == null || s.cancelled) return () {};
    if (s.notifier != null && !identical(s.notifier, notifier)) return () {};
    s.notifier = notifier;
    s.onSelected = onSelected;
    // Mounting happens mid-build; dismissing or updating belongs after it.
    scheduleMicrotask(() => _push(s));
    return s.cancel;
  }

  Future<void> _accepted(LspPrompt p) async {
    if (_disposed || client.versionOf(uri) == null || hasFolds(controller)) {
      return;
    }
    final since = [
      for (var i = 0; i < controller.lineCount; i++)
        controller.codeLines[i].text,
    ];
    final resolved = await client.resolveCompletionItem(p.item.raw);
    if (_disposed || resolved == null || client.versionOf(uri) == null) return;
    applyAdditionalEdits(
      controller,
      resolved['additionalTextEdits'],
      since: since,
    );
  }

  /// True only while real rows are on screen. Until then the overlay must not take the arrow
  /// keys, so they move the cursor as they would without a list.
  bool get listShowing {
    final s = _current;
    return s != null && s.shown && !s.cancelled;
  }

  Object? _navigate(CodeShortcutCursorMoveIntent intent) {
    final n = _current?.notifier;
    if (n == null || !listShowing) return null;
    final v = n.value;
    final count = v.prompts.length;
    if (count == 0) return null;
    final next = intent.direction == AxisDirection.up
        ? (v.index - 1 + count) % count
        : (v.index + 1) % count;
    n.value = v.copyWith(index: next);
    return intent;
  }

  /// Shadows re_editor's own arrow handling, which is on for any shown overlay, including the
  /// invisible placeholder.
  Map<Type, Action<Intent>> get actions => {
    CodeShortcutCursorMoveIntent: _NavigateAction(this),
  };

  void dispose() {
    _disposed = true;
    _current?.cancel();
  }
}
