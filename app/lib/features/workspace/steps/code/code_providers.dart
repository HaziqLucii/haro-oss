import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../data/workspace_store.dart';

/// Directories the backend lists (it only skips `.git` and `node_modules`) that nobody goes
/// looking in: virtualenvs and tool caches would bury every real match in ⌘P.
const _noiseDirs = {
  '.venv',
  'venv',
  '__pycache__',
  '.pytest_cache',
  '.mypy_cache',
  '.ruff_cache',
  '.next',
  '.turbo',
  '.cache',
};

List<FileNode> withoutNoise(List<FileNode> nodes) => [
  for (final n in nodes)
    if (!(n.dir && _noiseDirs.contains(n.name)))
      n.dir
          ? FileNode(
              name: n.name,
              path: n.path,
              dir: true,
              children: withoutNoise(n.children),
            )
          : n,
];

/// The worktree file tree for ALL FILES and ⌘P. Fetched on first watch only, so a workspace
/// whose code step never opens either pays nothing.
final codeFileTreeProvider = FutureProvider.autoDispose
    .family<List<FileNode>, String>(
      (ref, id) async =>
          withoutNoise(await ref.read(haroApiProvider).listFiles(id)),
    );

/// Every file path in [nodes], depth first.
List<String> flattenFilePaths(List<FileNode> nodes) {
  final out = <String>[];
  void walk(List<FileNode> level) {
    for (final n in level) {
      if (n.dir) {
        walk(n.children);
      } else {
        out.add(n.path);
      }
    }
  }

  walk(nodes);
  return out;
}

class TreeRow {
  const TreeRow(this.node, this.depth, this.expanded);

  final FileNode node;
  final int depth;
  final bool expanded;
}

/// The rows an expandable tree shows: directories first, then files, each level sorted by
/// name; children appear only under an expanded directory.
List<TreeRow> visibleTreeRows(List<FileNode> nodes, Set<String> expanded) {
  final out = <TreeRow>[];
  void walk(List<FileNode> level, int depth) {
    final sorted = [...level]
      ..sort((a, b) {
        if (a.dir != b.dir) return a.dir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    for (final n in sorted) {
      final open = n.dir && expanded.contains(n.path);
      out.add(TreeRow(n, depth, open));
      if (open) walk(n.children, depth + 1);
    }
  }

  walk(nodes, 0);
  return out;
}
