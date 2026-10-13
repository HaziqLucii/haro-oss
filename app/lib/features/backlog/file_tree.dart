import 'package:flutter/material.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_tag.dart';
import '../../widgets/shell_icons.dart';

/// A folder of the notes tree: its sub-folders and the items directly in it. [path] is `''` for
/// the root and `a/b` below it, the same form the backend uses for a note's path.
class TreeFolder<T> {
  TreeFolder(this.name, this.path);

  final String name;
  final String path;
  final folders = <TreeFolder<T>>[];
  final items = <T>[];

  /// Items in this folder and everything under it.
  int get total => items.length + folders.fold(0, (n, f) => n + f.total);
}

/// Case-insensitive, and a run of digits compares as a number, so `item-2` sorts before `item-10`.
int compareNatural(String a, String b) {
  final ta = RegExp(r'\d+|\D+').allMatches(a.toLowerCase()).map((m) => m[0]!);
  final tb = RegExp(r'\d+|\D+').allMatches(b.toLowerCase()).map((m) => m[0]!);
  final ia = ta.iterator, ib = tb.iterator;
  while (true) {
    final ha = ia.moveNext(), hb = ib.moveNext();
    if (!ha || !hb) return ha == hb ? 0 : (ha ? 1 : -1);
    final x = ia.current, y = ib.current;
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
}

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Folders first, then items, each in natural order of their names.
TreeFolder<T> buildTree<T>(Iterable<T> items, String Function(T) pathOf) {
  final root = TreeFolder<T>('', '');
  final folders = <String, TreeFolder<T>>{'': root};
  for (final item in items) {
    final parts = pathOf(item).split('/');
    var dir = root;
    for (var i = 0; i < parts.length - 1; i++) {
      final path = parts.sublist(0, i + 1).join('/');
      var next = folders[path];
      if (next == null) {
        next = TreeFolder<T>(parts[i], path);
        folders[path] = next;
        dir.folders.add(next);
      }
      dir = next;
    }
    dir.items.add(item);
  }
  void sort(TreeFolder<T> f) {
    f.folders.sort((a, b) => compareNatural(a.name, b.name));
    f.items.sort(
      (a, b) => compareNatural(_baseName(pathOf(a)), _baseName(pathOf(b))),
    );
    f.folders.forEach(sort);
  }

  sort(root);
  return root;
}

/// `a/b/c.md` -> `{a, a/b}`.
Set<String> ancestorsOf(String path) {
  final parts = path.split('/');
  return {for (var i = 1; i < parts.length; i++) parts.sublist(0, i).join('/')};
}

/// Every folder path under [root].
Set<String> allFolders<T>(TreeFolder<T> root) => {
  for (final f in root.folders) ...{f.path, ...allFolders(f)},
};

/// A small tree opens fully; a big one (a vault's worth) opens only down to the open note.
const treeOpenAllLimit = 40;

Set<String> defaultExpanded<T>(TreeFolder<T> root, String? openPath) =>
    root.total <= treeOpenAllLimit
    ? allFolders(root)
    : (openPath == null ? <String>{} : ancestorsOf(openPath));

sealed class TreeRow<T> {
  const TreeRow(this.depth);
  final int depth;
}

class FolderRow<T> extends TreeRow<T> {
  const FolderRow(this.folder, super.depth, {required this.open});
  final TreeFolder<T> folder;
  final bool open;
}

class ItemRow<T> extends TreeRow<T> {
  const ItemRow(this.item, super.depth);
  final T item;
}

/// The rows to draw: a folder, then (when it is open) its sub-folders and items one level in.
List<TreeRow<T>> flattenTree<T>(TreeFolder<T> root, Set<String> expanded) {
  final rows = <TreeRow<T>>[];
  void walk(TreeFolder<T> dir, int depth) {
    for (final f in dir.folders) {
      final open = expanded.contains(f.path);
      rows.add(FolderRow<T>(f, depth, open: open));
      if (open) walk(f, depth + 1);
    }
    for (final i in dir.items) {
      rows.add(ItemRow<T>(i, depth));
    }
  }

  walk(root, 0);
  return rows;
}

const double _indent = 16;
const double _chevron = 13;

/// One hairline per level above the row, so a deep row reads as inside its folders.
class _Guides extends StatelessWidget {
  const _Guides(this.depth);

  final int depth;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < depth; i++)
        SizedBox(
          width: _indent,
          height: 30,
          child: Center(child: Container(width: 1, color: HaroTokens.line08)),
        ),
    ],
  );
}

BoxDecoration _rowBox(bool lit) => BoxDecoration(
  color: lit ? HaroTokens.raised : HaroTokens.transparent,
  borderRadius: BorderRadius.circular(HaroTokens.radius),
);

/// A folder: chevron and folder icon (both Lucide), its name and how many items it holds. The
/// whole row is the button, drawn as a box of its own size so the Expressive ripple stays inside.
class TreeFolderRow extends StatelessWidget {
  const TreeFolderRow({
    super.key,
    required this.name,
    required this.depth,
    required this.open,
    required this.count,
    required this.onTap,
    this.onMenu,
  });

  final String name;
  final int depth;
  final bool open;
  final int count;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: onMenu == null
        ? null
        : (d) => onMenu!(d.globalPosition),
    child: HaroPressable(
      onTap: onTap,
      semanticLabel: '${open ? 'Fold' : 'Open'} $name',
      builder: (context, hovered) => Container(
        height: 30,
        padding: const EdgeInsets.only(left: 6, right: 8),
        decoration: _rowBox(hovered),
        child: Row(
          children: [
            _Guides(depth),
            ShellIconView(
              open ? ShellIcon.chevronDown : ShellIcon.chevronRight,
              size: _chevron,
              color: hovered ? HaroTokens.ink : HaroTokens.ink42,
            ),
            const SizedBox(width: 6),
            ShellIconView(
              open ? ShellIcon.folderOpen : ShellIcon.folder,
              size: 15,
              color: hovered ? HaroTokens.ink : HaroTokens.ink66,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(size: 13, color: HaroTokens.ink86),
              ),
            ),
            const SizedBox(width: 8),
            HaroTag('$count'),
          ],
        ),
      ),
    ),
  );
}

/// A note or a file in the tree: an icon, a label, a quiet trailing fact. Lined up under its
/// folder's own icon, so the chevron column stays empty.
class TreeLeafRow extends StatelessWidget {
  const TreeLeafRow({
    super.key,
    required this.depth,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.selected = false,
    this.tooltip,
    this.onMenu,
  });

  final int depth;
  final ShellIcon icon;
  final String label;
  final String? trailing;
  final bool selected;
  final String? tooltip;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: onMenu == null
        ? null
        : (d) => onMenu!(d.globalPosition),
    child: HaroPressable(
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: label,
      builder: (context, hovered) => Container(
        height: 30,
        padding: const EdgeInsets.only(left: 6, right: 8),
        decoration: _rowBox(selected || hovered),
        child: Row(
          children: [
            _Guides(depth),
            const SizedBox(width: _chevron + 6),
            ShellIconView(
              icon,
              size: 15,
              color: selected || hovered ? HaroTokens.ink : HaroTokens.ink66,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 13,
                  color: selected ? HaroTokens.ink : HaroTokens.ink86,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              Text(
                trailing!,
                maxLines: 1,
                style: HaroText.mono(
                  size: 10,
                  tracking: 0,
                  color: HaroTokens.ink42,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
