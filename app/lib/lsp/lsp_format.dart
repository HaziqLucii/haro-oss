import 'dart:math' as math;

import 'package:re_editor/re_editor.dart';

import 'lsp_client.dart';
import 'lsp_edits.dart';

const formatTimeout = Duration(seconds: 2);

/// What `textDocument/formatting` is told about the file's indentation. The editor has no
/// tab-size setting, so this follows the file: a first indented line that starts with a tab means
/// tabs, otherwise spaces at the file's detected step (2 when nothing is indented).
({int tabSize, bool insertSpaces}) formatOptionsFor(
  List<String> lines,
  int unit,
) {
  for (var i = 0; i < lines.length && i < 400; i++) {
    final l = lines[i];
    if (l.isEmpty) continue;
    final c = l.codeUnitAt(0);
    if (c == 0x09) return (tabSize: unit, insertSpaces: false);
    if (c == 0x20 && l.trim().isNotEmpty) break;
  }
  return (tabSize: unit, insertSpaces: true);
}

/// Formats the buffer through the language server and applies the answer as ONE undo step.
/// Returns true only when the text changed. Every other outcome (server not ready, error,
/// timeout, no edits, an edit that cannot be placed, the buffer edited while waiting) leaves the
/// text untouched: formatting is a courtesy before a save and must never stand in its way.
Future<bool> formatBuffer({
  required LspClient client,
  required String uri,
  required CodeLineEditingController controller,
  required int unit,
  Duration timeout = formatTimeout,
}) async {
  if (client.status != LspStatus.ready || !client.tracks(uri)) return false;
  if (hasFolds(controller)) return false;
  final version = client.versionOf(uri);
  final before = controller.codeLines;
  final opts = formatOptionsFor([
    for (var i = 0; i < before.length; i++) before[i].text,
  ], unit);
  final Object? raw;
  try {
    raw = await client
        .formatting(uri, tabSize: opts.tabSize, insertSpaces: opts.insertSpaces)
        .timeout(timeout, onTimeout: () => null);
  } on Object {
    return false;
  }
  if (client.versionOf(uri) != version ||
      !identical(controller.codeLines, before)) {
    return false;
  }
  final edits = parseTextEdits(raw);
  if (edits == null || edits.isEmpty) return false;
  return applyFormatEdits(controller, edits);
}

/// Applies [edits] (positions against the controller's current text) as one revocable op and
/// moves the selection with the text it was on. The edits are resolved against the text bottom
/// up, so no edit sees another's shift, and the result lands as a single replacement of the
/// lines that differ: one undo step, one change notification for the whole format.
///
/// Out-of-range positions clamp as the LSP spec says; edits that overlap, or whose end sits
/// before their start, make the whole batch skip.
bool applyFormatEdits(CodeLineEditingController c, List<LspTextEdit> edits) {
  if (hasFolds(c)) return false;
  final old = [for (var i = 0; i < c.lineCount; i++) c.codeLines[i].text];
  final starts = <int>[];
  var total = 0;
  for (final l in old) {
    starts.add(total);
    total += l.length + 1;
  }
  final length = total - 1;
  int flat(int line, int col) {
    if (line < 0) return 0;
    if (line >= old.length) return length;
    return starts[line] + col.clamp(0, old[line].length);
  }

  final ranges = <({int start, int end, String text, int order})>[];
  for (var i = 0; i < edits.length; i++) {
    final e = edits[i];
    if (e.sl < 0 || e.sc < 0 || e.el < 0 || e.ec < 0) return false;
    final s = flat(e.sl, e.sc);
    final en = flat(e.el, e.ec);
    if (en < s) return false;
    ranges.add((start: s, end: en, text: e.text, order: i));
  }
  ranges.sort((a, b) {
    final x = a.start - b.start;
    return x != 0 ? x : a.order - b.order;
  });
  for (var i = 1; i < ranges.length; i++) {
    if (ranges[i].start < ranges[i - 1].end) return false;
  }
  var text = old.join('\n');
  for (final r in ranges.reversed) {
    text = text.replaceRange(r.start, r.end, r.text);
  }
  final next = text.split('\n');
  if (_same(old, next)) return false;

  final sel = c.selection;
  final base = flat(sel.baseIndex, sel.baseOffset);
  final extent = flat(sel.extentIndex, sel.extentOffset);
  int move(int off) {
    var delta = 0;
    for (final r in ranges) {
      if (r.start >= off) break;
      if (r.end <= off) {
        delta += r.text.length - (r.end - r.start);
      } else {
        return r.start + delta + math.min(off - r.start, r.text.length);
      }
    }
    return off + delta;
  }

  var head = 0;
  while (head < old.length && head < next.length && old[head] == next[head]) {
    head++;
  }
  var tail = 0;
  while (tail < old.length - head &&
      tail < next.length - head &&
      old[old.length - 1 - tail] == next[next.length - 1 - tail]) {
    tail++;
  }
  // Both spans must keep a line: a pure insertion or deletion borrows one line of context.
  if (head + tail >= old.length || head + tail >= next.length) {
    if (head > 0) {
      head--;
    } else {
      tail--;
    }
  }
  final oldEnd = old.length - tail - 1;
  final newEnd = next.length - tail - 1;
  c.runRevocableOp(() {
    c.replaceSelection(
      next.sublist(head, newEnd + 1).join('\n'),
      CodeLineSelection(
        baseIndex: head,
        baseOffset: 0,
        extentIndex: oldEnd,
        extentOffset: old[oldEnd].length,
      ),
    );
  });

  final nextStarts = <int>[];
  var at = 0;
  for (final l in next) {
    nextStarts.add(at);
    at += l.length + 1;
  }
  CodeLinePosition place(int off) {
    var line = 0;
    while (line + 1 < next.length && nextStarts[line + 1] <= off) {
      line++;
    }
    return CodeLinePosition(
      index: line,
      offset: (off - nextStarts[line]).clamp(0, next[line].length),
    );
  }

  final b = place(move(base));
  final x = place(move(extent));
  c.selection = CodeLineSelection(
    baseIndex: b.index,
    baseOffset: b.offset,
    extentIndex: x.index,
    extentOffset: x.offset,
  );
  return true;
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
