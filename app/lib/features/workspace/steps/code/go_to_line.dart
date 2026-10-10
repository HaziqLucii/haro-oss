/// Where a ⌘P query points: a line in the active file (`:42`) or a line in a named file
/// (`lib/rates.ts:42`). [path] is the text before the colon, still a fuzzy query.
class QuickOpenTarget {
  const QuickOpenTarget(this.path, this.line);

  final String? path;
  final int line;

  @override
  bool operator ==(Object other) =>
      other is QuickOpenTarget && other.path == path && other.line == line;

  @override
  int get hashCode => Object.hash(path, line);

  @override
  String toString() => 'QuickOpenTarget($path, $line)';
}

final _bare = RegExp(r'^:\s*(\d{1,9})$');
final _withPath = RegExp(r'^(.*\S)\s*:\s*(\d{1,9})$');

/// Null when [query] is an ordinary file search.
QuickOpenTarget? parseQuickOpenQuery(String query) {
  final q = query.trim();
  final bare = _bare.firstMatch(q);
  if (bare != null) return QuickOpenTarget(null, int.parse(bare.group(1)!));
  final named = _withPath.firstMatch(q);
  if (named != null) {
    return QuickOpenTarget(named.group(1)!, int.parse(named.group(2)!));
  }
  return null;
}

/// The number typed into the editor's go-to-line field, with or without a leading colon.
int? parseLineNumber(String text) {
  final m = RegExp(r'^:?\s*(\d{1,9})$').firstMatch(text.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

/// 1-based [line] as a 0-based index inside a file of [count] lines (past the end lands on
/// the last line, zero on the first).
int lineIndexFor(int line, int count) =>
    count <= 0 ? 0 : (line - 1).clamp(0, count - 1);
