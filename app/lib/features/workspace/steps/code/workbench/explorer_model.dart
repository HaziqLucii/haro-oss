import '../../../../../api/models/models.dart';
import '../diff_model.dart';

/// The git letter beside a changed file. Green is for `A` only (an added line is a gate colour);
/// the others read in ink, deletions in red.
enum ChangeLetter {
  added('A'),
  modified('M'),
  deleted('D'),
  renamed('R');

  const ChangeLetter(this.text);

  final String text;
}

ChangeLetter letterOf(DiffFile f) => switch (f.tag) {
  DiffFileTag.added => ChangeLetter.added,
  DiffFileTag.deleted => ChangeLetter.deleted,
  DiffFileTag.renamed => ChangeLetter.renamed,
  DiffFileTag.none => ChangeLetter.modified,
};

/// One line of the explorer: a directory, a file, or (Changes list only) a folder heading.
class ExplorerRow {
  const ExplorerRow({
    required this.path,
    required this.name,
    this.isDir = false,
    this.isGroup = false,
    this.depth = 0,
    this.expanded = false,
    this.file,
    this.hasChanges = false,
  });

  final String path;
  final String name;
  final bool isDir;

  /// A non-interactive folder heading in the Changes list.
  final bool isGroup;
  final int depth;
  final bool expanded;

  /// The diff entry when this file changed.
  final DiffFile? file;

  /// A directory that contains at least one changed file.
  final bool hasChanges;

  ChangeLetter? get letter => file == null ? null : letterOf(file!);
}

/// Every directory that holds a changed file, at any depth.
Set<String> dirsWithChanges(Iterable<String> changedPaths) {
  final out = <String>{};
  for (final p in changedPaths) {
    var d = dirnameOf(p);
    while (d.isNotEmpty && out.add(d)) {
      d = dirnameOf(d);
    }
  }
  return out;
}

int _byName(FileNode a, FileNode b) {
  if (a.dir != b.dir) return a.dir ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

bool _matches(String path, String needle) =>
    needle.isEmpty || path.toLowerCase().contains(needle);

/// The All files list: directories first, each level by name. A [filter] keeps files whose path
/// contains it and the directories above them, all open; without one only [expanded] directories
/// show their children.
List<ExplorerRow> allFilesRows(
  List<FileNode> tree, {
  required Set<String> expanded,
  required Map<String, DiffFile> changed,
  String filter = '',
}) {
  final needle = filter.trim().toLowerCase();
  final dirty = dirsWithChanges(changed.keys);
  bool keeps(FileNode n) =>
      n.dir ? n.children.any(keeps) : _matches(n.path, needle);

  final out = <ExplorerRow>[];
  void walk(List<FileNode> level, int depth) {
    for (final n in [...level]..sort(_byName)) {
      if (needle.isNotEmpty && !keeps(n)) continue;
      final open = n.dir && (needle.isNotEmpty || expanded.contains(n.path));
      out.add(
        ExplorerRow(
          path: n.path,
          name: n.name,
          isDir: n.dir,
          depth: depth,
          expanded: open,
          file: n.dir ? null : changed[n.path],
          hasChanges: n.dir && dirty.contains(n.path),
        ),
      );
      if (open) walk(n.children, depth + 1);
    }
  }

  walk(tree, 0);
  return out;
}

/// The Changes list: changed files grouped under their folder, folders by name.
List<ExplorerRow> changedRows(List<DiffFile> files, {String filter = ''}) {
  final needle = filter.trim().toLowerCase();
  final groups = <String, List<DiffFile>>{};
  for (final f in files) {
    if (_matches(f.path, needle)) (groups[f.dirname] ??= []).add(f);
  }
  final out = <ExplorerRow>[];
  for (final dir in groups.keys.toList()..sort()) {
    if (dir.isNotEmpty) {
      out.add(
        ExplorerRow(
          path: '#$dir',
          name: '$dir/',
          isDir: true,
          isGroup: true,
          expanded: true,
        ),
      );
    }
    final inDir = groups[dir]!
      ..sort((a, b) => a.basename.compareTo(b.basename));
    for (final f in inDir) {
      out.add(
        ExplorerRow(
          path: f.path,
          name: f.basename,
          depth: dir.isEmpty ? 0 : 1,
          file: f,
        ),
      );
    }
  }
  return out;
}

enum TreeNavKey { up, down, left, right, enter }

/// What one arrow or Enter press does. At most one field is set.
class TreeNav {
  const TreeNav({
    this.cursor,
    this.expand,
    this.collapse,
    this.open,
    this.toggle,
  });

  static const none = TreeNav();

  /// Move the keyboard row here.
  final String? cursor;
  final String? expand;
  final String? collapse;

  /// Open this file pinned.
  final String? open;
  final String? toggle;
}

/// Keyboard navigation over [rows] from [cursor]. Group headings are skipped. Right opens a
/// directory (or steps into an open one), Left closes it (or jumps to its parent), Enter opens a
/// file pinned or toggles a directory.
TreeNav navigateTree(List<ExplorerRow> rows, String? cursor, TreeNavKey key) {
  final idx = rows.indexWhere((r) => r.path == cursor);
  final cur = idx < 0 ? null : rows[idx];

  int step(int from, int delta) {
    var j = from + delta;
    while (j >= 0 && j < rows.length && rows[j].isGroup) {
      j += delta;
    }
    return j;
  }

  switch (key) {
    case TreeNavKey.down:
    case TreeNavKey.up:
      final delta = key == TreeNavKey.down ? 1 : -1;
      final start = idx < 0 ? (delta > 0 ? -1 : rows.length) : idx;
      final j = step(start, delta);
      return j >= 0 && j < rows.length
          ? TreeNav(cursor: rows[j].path)
          : TreeNav.none;
    case TreeNavKey.right:
      if (cur == null || !cur.isDir || cur.isGroup) return TreeNav.none;
      if (!cur.expanded) return TreeNav(expand: cur.path);
      final j = step(idx, 1);
      return j < rows.length && rows[j].depth > cur.depth
          ? TreeNav(cursor: rows[j].path)
          : TreeNav.none;
    case TreeNavKey.left:
      if (cur == null || cur.isGroup) return TreeNav.none;
      if (cur.isDir && cur.expanded) return TreeNav(collapse: cur.path);
      final parent = dirnameOf(cur.path);
      return parent.isNotEmpty && rows.any((r) => r.path == parent)
          ? TreeNav(cursor: parent)
          : TreeNav.none;
    case TreeNavKey.enter:
      if (cur == null || cur.isGroup) return TreeNav.none;
      return cur.isDir ? TreeNav(toggle: cur.path) : TreeNav(open: cur.path);
  }
}
