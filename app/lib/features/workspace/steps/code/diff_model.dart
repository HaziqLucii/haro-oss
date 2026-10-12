/// Unified-diff parsing for the code step. Ported from the React `parseDiff` with three
/// fixes: `--- ` / `+++ ` only count as file headers before the first hunk (a removed line
/// like `-- comment` used to be swallowed), the empty string after the final newline is not a
/// context line, and `\ No newline at end of file` becomes a note on the line above.
library;

import 'dart:convert';

enum DiffLineKind { context, add, del }

enum DiffFileTag { none, added, deleted, renamed }

class DiffLine {
  const DiffLine(
    this.kind,
    this.text, {
    this.oldNo,
    this.newNo,
    this.noNewline = false,
  });

  final DiffLineKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;

  /// The source file ends here without a trailing newline.
  final bool noNewline;

  DiffLine withNoNewline() =>
      DiffLine(kind, text, oldNo: oldNo, newNo: newNo, noNewline: true);
}

class DiffHunk {
  DiffHunk({
    required this.oldStart,
    required this.newStart,
    required this.section,
    required this.header,
  });

  final int oldStart;
  final int newStart;
  final String section;

  /// The raw `@@ -a,b +c,d @@ section` text.
  final String header;
  final List<DiffLine> lines = [];

  List<int> get addedLineNos => [
    for (final l in lines)
      if (l.kind == DiffLineKind.add && l.newNo != null) l.newNo!,
  ];
}

class DiffFile {
  DiffFile();

  String oldPath = '';
  String newPath = '';
  DiffFileTag tag = DiffFileTag.none;
  bool isBinary = false;
  int additions = 0;
  int deletions = 0;
  final List<DiffHunk> hunks = [];

  /// The path the rest of the app knows the file by: the new side unless it was deleted.
  String get path => newPath.isNotEmpty ? newPath : oldPath;

  /// 1-based line in the new file where the change starts: the first added line, or for a
  /// pure deletion the spot it was removed from. Null for a deleted or binary file.
  int? get firstChangedLine {
    if (tag == DiffFileTag.deleted || isBinary) return null;
    for (final h in hunks) {
      for (final l in h.lines) {
        if (l.kind == DiffLineKind.add && l.newNo != null) return l.newNo;
      }
    }
    return hunks.isEmpty ? null : hunks.first.newStart.clamp(1, 1 << 30);
  }

  String get display => tag == DiffFileTag.renamed && oldPath != newPath
      ? '$oldPath → $newPath'
      : path;

  String get basename => basenameOf(path);
  String get dirname => dirnameOf(path);
}

/// The new-file line the editor should open on for the row at [index] of [hunk]: its own line
/// for an added or context row; for a deleted row (which has no new line) the next added or
/// context line below it, else the hunk's new start.
int lineFor(DiffHunk hunk, int index) {
  final lines = hunk.lines;
  for (var i = index; i < lines.length; i++) {
    final l = lines[i];
    if (l.kind != DiffLineKind.del && l.newNo != null) return l.newNo!;
  }
  return hunk.newStart < 1 ? 1 : hunk.newStart;
}

String basenameOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

String dirnameOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// Decodes git's C-style quoted path (`core.quotepath`): `\"`, `\\`, `\t`, `\n`... and
/// three-digit octal escapes, which are UTF-8 bytes (`caf\303\251` is `café`). Text that is
/// not wrapped in quotes is returned as is.
String unquoteGitPath(String p) {
  if (p.length < 2 || !p.startsWith('"') || !p.endsWith('"')) return p;
  final body = p.substring(1, p.length - 1);
  final bytes = <int>[];
  var i = 0;
  while (i < body.length) {
    final ch = body[i];
    if (ch != r'\' || i + 1 >= body.length) {
      bytes.addAll(utf8.encode(ch));
      i++;
      continue;
    }
    final n = body[i + 1];
    final code = n.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x37) {
      var end = i + 1;
      while (end < body.length &&
          end < i + 4 &&
          body.codeUnitAt(end) >= 0x30 &&
          body.codeUnitAt(end) <= 0x37) {
        end++;
      }
      bytes.add(int.parse(body.substring(i + 1, end), radix: 8) & 0xFF);
      i = end;
      continue;
    }
    const simple = {
      'a': 7,
      'b': 8,
      'f': 12,
      'n': 10,
      'r': 13,
      't': 9,
      'v': 11,
      '"': 34,
      r'\': 92,
    };
    final v = simple[n];
    if (v != null) {
      bytes.add(v);
    } else {
      bytes.addAll(utf8.encode(n));
    }
    i += 2;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// `---` / `+++` paths: git appends a tab when the name contains a space.
String _headerPath(String raw) {
  var p = raw;
  if (p.endsWith('\t')) p = p.substring(0, p.length - 1);
  return unquoteGitPath(p);
}

String _stripPrefix(String p, String prefix) =>
    p.startsWith(prefix) ? p.substring(prefix.length) : p;

/// The two paths of a `diff --git` line, or null when it cannot be split. Handles quoted
/// names on either side, and the unquoted same-name case (`a/X b/X`), which git itself
/// splits by length because `X` may contain spaces.
(String, String)? _splitGitHeader(String line) {
  final rest = line.substring('diff --git '.length);
  if (rest.startsWith('"')) {
    var i = 1;
    while (i < rest.length && rest[i] != '"') {
      if (rest[i] == r'\') i++;
      i++;
    }
    if (i >= rest.length) return null;
    final a = unquoteGitPath(rest.substring(0, i + 1));
    final b = unquoteGitPath(rest.substring(i + 1).trimLeft());
    return (_stripPrefix(a, 'a/'), _stripPrefix(b, 'b/'));
  }
  final q = rest.lastIndexOf(' "b/');
  if (rest.endsWith('"') && q > 0) {
    return (
      _stripPrefix(rest.substring(0, q), 'a/'),
      _stripPrefix(unquoteGitPath(rest.substring(q + 1)), 'b/'),
    );
  }
  final len = rest.length - 5;
  if (len > 0 && len.isEven && rest.startsWith('a/')) {
    final half = len ~/ 2;
    final a = rest.substring(2, 2 + half);
    if (rest.substring(2 + half) == ' b/$a') return (a, a);
  }
  final m = _gitHeader.firstMatch(line);
  return m == null ? null : (m.group(1)!, m.group(2)!);
}

final _gitHeader = RegExp(r'^diff --git a/(.+) b/(.+)$');
final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)');

const _metaPrefixes = [
  'index ',
  'old mode',
  'new mode',
  'similarity index',
  'dissimilarity index',
  'copy from',
  'copy to',
  'GIT binary patch',
  'literal ',
  'delta ',
];

List<DiffFile> parseUnifiedDiff(String raw) {
  final files = <DiffFile>[];
  DiffFile? file;
  DiffHunk? hunk;
  var oldNo = 0;
  var newNo = 0;
  var isNew = false;
  var isDeleted = false;
  var isRename = false;

  void finalize() {
    final f = file;
    if (f == null) return;
    f.tag = isRename
        ? DiffFileTag.renamed
        : isNew
        ? DiffFileTag.added
        : isDeleted
        ? DiffFileTag.deleted
        : DiffFileTag.none;
  }

  final lines = raw.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  for (var line in lines) {
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.startsWith('diff --git')) {
      finalize();
      file = DiffFile();
      files.add(file);
      hunk = null;
      isNew = isDeleted = isRename = false;
      final paths = line.startsWith('diff --git ')
          ? _splitGitHeader(line)
          : null;
      if (paths != null) {
        file.oldPath = paths.$1;
        file.newPath = paths.$2;
      }
      continue;
    }
    final f = file;
    if (f == null) continue;

    if (hunk == null) {
      if (line.startsWith('new file mode')) {
        isNew = true;
        continue;
      }
      if (line.startsWith('deleted file mode')) {
        isDeleted = true;
        continue;
      }
      if (line.startsWith('rename from ')) {
        f.oldPath = unquoteGitPath(line.substring(12));
        isRename = true;
        continue;
      }
      if (line.startsWith('rename to ')) {
        f.newPath = unquoteGitPath(line.substring(10));
        isRename = true;
        continue;
      }
      if (line.startsWith('Binary files') ||
          line.startsWith('GIT binary patch')) {
        f.isBinary = true;
        continue;
      }
      if (line.startsWith('--- ')) {
        // The `diff --git` header (and rename lines) win; these only fill a gap.
        final p = _headerPath(line.substring(4));
        if (f.oldPath.isEmpty && p != '/dev/null' && p.startsWith('a/')) {
          f.oldPath = p.substring(2);
        }
        continue;
      }
      if (line.startsWith('+++ ')) {
        final p = _headerPath(line.substring(4));
        if (f.newPath.isEmpty && p != '/dev/null' && p.startsWith('b/')) {
          f.newPath = p.substring(2);
        }
        continue;
      }
      if (_metaPrefixes.any(line.startsWith)) continue;
    }

    if (line.startsWith('@@')) {
      final m = _hunkHeader.firstMatch(line);
      oldNo = m == null ? 0 : int.parse(m.group(1)!);
      newNo = m == null ? 0 : int.parse(m.group(2)!);
      hunk = DiffHunk(
        oldStart: oldNo,
        newStart: newNo,
        section: m == null ? '' : m.group(3)!.trim(),
        header: line,
      );
      f.hunks.add(hunk);
      continue;
    }
    final h = hunk;
    if (h == null) continue;
    if (line.startsWith('\\')) {
      if (h.lines.isNotEmpty) {
        h.lines[h.lines.length - 1] = h.lines.last.withNoNewline();
      }
      continue;
    }
    if (line.startsWith('+')) {
      h.lines.add(DiffLine(DiffLineKind.add, line.substring(1), newNo: newNo));
      newNo++;
      f.additions++;
    } else if (line.startsWith('-')) {
      h.lines.add(DiffLine(DiffLineKind.del, line.substring(1), oldNo: oldNo));
      oldNo++;
      f.deletions++;
    } else {
      h.lines.add(
        DiffLine(
          DiffLineKind.context,
          line.startsWith(' ') ? line.substring(1) : line,
          oldNo: oldNo,
          newNo: newNo,
        ),
      );
      oldNo++;
      newNo++;
    }
  }
  finalize();
  return files;
}
