import 'package:re_editor/re_editor.dart';

/// One LSP `TextEdit` (0-based line and UTF-16 column, which is also what re_editor counts).
class LspTextEdit {
  LspTextEdit(this.sl, this.sc, this.el, this.ec, this.text);

  final int sl, sc, el, ec;
  final String text;
}

List<LspTextEdit>? parseTextEdits(Object? raw) {
  if (raw is! List) return null;
  final out = <LspTextEdit>[];
  for (final e in raw) {
    if (e is! Map) return null;
    final range = e['range'];
    final text = e['newText'];
    if (range is! Map || text is! String) return null;
    final s = range['start'];
    final en = range['end'];
    if (s is! Map || en is! Map) return null;
    final sl = s['line'];
    final sc = s['character'];
    final el = en['line'];
    final ec = en['character'];
    if (sl is! int || sc is! int || el is! int || ec is! int) return null;
    out.add(LspTextEdit(sl, sc, el, ec, text.replaceAll('\r\n', '\n')));
  }
  return out;
}

/// True while any chunk is collapsed. re_editor's `lineCount` counts every line but `codeLines`
/// and every selection index count only the visible ones (a folded parent holds its children),
/// so the server's full-text line numbers cannot be applied through them. Edit application skips
/// a folded buffer instead of guessing: a folded buffer saves unformatted and takes an
/// auto-import never.
bool hasFolds(CodeLineEditingController c) => c.lineCount != c.codeLines.length;
