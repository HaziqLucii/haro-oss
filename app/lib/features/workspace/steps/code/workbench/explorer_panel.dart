import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../data/workspace_detail.dart';
import '../../../../../data/workspace_store.dart';
import '../../../../../shortcuts/platform_keys.dart';
import '../../../../../theme/display_scope.dart';
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../code_file_list.dart' show Counts, ProofDot;
import '../code_providers.dart';
import '../diff_model.dart';
import '../editor/editor_tabs.dart';
import '../proof.dart';
import 'explorer_actions.dart';
import 'explorer_model.dart';
import 'workbench_icons.dart';
import 'workbench_state.dart';
import 'workbench_widgets.dart';

/// The project's name, for the `FILES · NAME` caption.
final workbenchProjectNameProvider = Provider.autoDispose
    .family<String?, String>((ref, id) {
      final projectId = ref.watch(
        workspaceDetailProvider(id).select((d) => d.workspace?.projectId),
      );
      return ref.watch(
        workspaceStoreProvider.select((s) {
          for (final p in s.projects) {
            if (p.id == projectId) return p.name;
          }
          return null;
        }),
      );
    });

/// The Files panel: an All files / Changes toggle, a filter, and the tree (or the changed
/// files grouped by folder) with git letters, keyboard navigation and the right-click menu.
class ExplorerPanel extends ConsumerStatefulWidget {
  const ExplorerPanel({
    super.key,
    required this.workspaceId,
    required this.changed,
    required this.proof,
  });

  final String workspaceId;
  final List<DiffFile> changed;
  final ProofIndex? proof;

  @override
  ConsumerState<ExplorerPanel> createState() => _ExplorerPanelState();
}

class _ExplorerPanelState extends ConsumerState<ExplorerPanel> {
  final _filter = TextEditingController();
  final _treeFocus = FocusNode(debugLabel: 'explorer-tree');
  final _scroll = ScrollController();
  List<ExplorerRow> _rows = const [];
  double _rowHeight = 28;
  String? _tapPath;
  DateTime _tapAt = DateTime.fromMillisecondsSinceEpoch(0);

  String get _id => widget.workspaceId;
  WorkbenchNotifier get _wb => ref.read(workbenchProvider(_id).notifier);
  ExplorerActions get _actions => ExplorerActions(ref, context, _id);

  @override
  void dispose() {
    _filter.dispose();
    _treeFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _ensureVisible(String path) {
    final i = _rows.indexWhere((r) => r.path == path);
    if (i < 0 || !_scroll.hasClients) return;
    final top = i * _rowHeight;
    final bottom = top + _rowHeight;
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(bottom - pos.viewportDimension);
    }
  }

  void _reveal(String path) {
    _wb.reveal(path);
    _filter.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final i = _rows.indexWhere((r) => r.path == path);
      if (i < 0) return;
      final pos = _scroll.position;
      final target = (i * _rowHeight - pos.viewportDimension / 3).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      _scroll.jumpTo(target);
    });
  }

  void _tap(ExplorerRow row) {
    _treeFocus.requestFocus();
    _wb.setCursor(row.path);
    if (row.isGroup) return;
    if (row.isDir) {
      _wb.toggleDir(row.path);
      return;
    }
    final now = DateTime.now();
    final again =
        _tapPath == row.path &&
        now.difference(_tapAt) < const Duration(milliseconds: 400);
    _tapPath = row.path;
    _tapAt = now;
    ref.read(editorTabsProvider(_id).notifier).open(row.path, preview: !again);
  }

  void _menu(Offset at, ExplorerRow row) {
    if (row.isGroup) return;
    _treeFocus.requestFocus();
    _wb.setCursor(row.path);
    _actions.showMenu(
      at,
      path: row.path,
      isDir: row.isDir,
      changed: row.file != null,
      line: row.file?.firstChangedLine,
    );
  }

  ExplorerRow? _cursorRow(String? cursor) {
    for (final r in _rows) {
      if (r.path == cursor) return r;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final kb = HardwareKeyboard.instance;
    final primary = primaryModifier == PrimaryModifier.control
        ? kb.isControlPressed
        : kb.isMetaPressed;
    final cursor = ref.read(workbenchProvider(_id)).cursor;
    final row = _cursorRow(cursor);

    if (primary && kb.isAltPressed && key == LogicalKeyboardKey.keyC) {
      if (row == null || row.isGroup) return KeyEventResult.ignored;
      kb.isShiftPressed
          ? _actions.copyRelativePath(row.path)
          : _actions.copyPath(row.path);
      return KeyEventResult.handled;
    }
    if (kb.isAltPressed || (primary && key != LogicalKeyboardKey.enter)) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.f2) {
      if (row == null || row.isGroup) return KeyEventResult.ignored;
      _actions.rename(row.path);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (row == null || row.isGroup) return KeyEventResult.ignored;
      _actions.delete(row.path, isDir: row.isDir);
      return KeyEventResult.handled;
    }

    final nav = switch (key) {
      LogicalKeyboardKey.arrowDown => TreeNavKey.down,
      LogicalKeyboardKey.arrowUp => TreeNavKey.up,
      LogicalKeyboardKey.arrowLeft => TreeNavKey.left,
      LogicalKeyboardKey.arrowRight => TreeNavKey.right,
      LogicalKeyboardKey.enter ||
      LogicalKeyboardKey.numpadEnter => TreeNavKey.enter,
      _ => null,
    };
    if (nav == null) return KeyEventResult.ignored;

    if (nav == TreeNavKey.enter && primary) {
      if (row != null && !row.isDir && !row.isGroup) {
        _actions.openToSide(row.path);
      }
      return KeyEventResult.handled;
    }

    final result = navigateTree(_rows, cursor, nav);
    if (result.cursor != null) {
      _wb.setCursor(result.cursor);
      _ensureVisible(result.cursor!);
    } else if (result.expand != null) {
      _wb.toggleDir(result.expand!, force: true);
    } else if (result.collapse != null) {
      _wb.toggleDir(result.collapse!, force: false);
    } else if (result.toggle != null) {
      _wb.toggleDir(result.toggle!);
    } else if (result.open != null) {
      _actions.open(result.open!);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final wb = ref.watch(workbenchProvider(_id));
    final active = ref.watch(
      editorTabsProvider(_id).select((s) => s.activePath),
    );
    final project = ref.watch(workbenchProjectNameProvider(_id));
    final density = DisplayScope.densityOf(context);
    _rowHeight = density.fileRow;
    final byPath = {for (final f in widget.changed) f.path: f};
    final allScope = wb.scope == ExplorerScope.all;

    Widget body;
    if (allScope) {
      final tree = ref.watch(codeFileTreeProvider(_id));
      body = tree.when(
        loading: () {
          _rows = const [];
          return const PanelNote('Loading…');
        },
        error: (e, _) {
          _rows = const [];
          return const PanelNote('Could not list files.');
        },
        data: (nodes) {
          _rows = allFilesRows(
            nodes,
            expanded: wb.expanded,
            changed: byPath,
            filter: wb.filter,
          );
          return _list(wb, active);
        },
      );
    } else {
      _rows = changedRows(widget.changed, filter: wb.filter);
      body = _list(wb, active);
    }

    return PanelColumn(
      children: [
        PanelHeader(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelTitle(
                project == null ? 'FILES' : 'FILES · ${project.toUpperCase()}',
                actions: [
                  IconAction(
                    key: const ValueKey('explorer-new-file'),
                    icon: WorkbenchIcon.newFile,
                    tooltip: 'New file',
                    onTap: () {
                      final row = _cursorRow(wb.cursor);
                      _actions.newEntry(
                        _actions.folderFor(
                          wb.cursor,
                          cursorIsDir: row?.isDir ?? false,
                        ),
                        dir: false,
                      );
                    },
                  ),
                  IconAction(
                    key: const ValueKey('explorer-collapse'),
                    icon: WorkbenchIcon.collapseAll,
                    tooltip: 'Collapse all',
                    onTap: _wb.collapseAll,
                  ),
                  IconAction(
                    key: const ValueKey('explorer-reveal'),
                    icon: WorkbenchIcon.reveal,
                    tooltip: 'Reveal open file',
                    onTap: active == null ? null : () => _reveal(active),
                  ),
                ],
              ),
              _ScopeToggle(
                scope: wb.scope,
                all: ref.watch(_allCountProvider(_id)),
                changes: widget.changed.length,
                onPick: _wb.setScope,
              ),
              const SizedBox(height: 8),
              FieldBox(
                leading: const WorkbenchIconView(
                  WorkbenchIcon.search,
                  size: 12,
                  color: HaroTokens.ink42,
                ),
                child: BareField(
                  key: const ValueKey('explorer-filter'),
                  controller: _filter,
                  hint: 'Filter files',
                  onChanged: _wb.setFilter,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Focus(focusNode: _treeFocus, onKeyEvent: _onKey, child: body),
        ),
      ],
    );
  }

  Widget _list(WorkbenchState wb, String? active) {
    if (_rows.isEmpty) {
      return const PanelNote('No files match.');
    }
    return ListView.builder(
      key: const ValueKey('explorer-list'),
      controller: _scroll,
      itemExtent: _rowHeight,
      padding: const EdgeInsets.only(bottom: 10),
      itemCount: _rows.length,
      itemBuilder: (context, i) {
        final row = _rows[i];
        return _RowView(
          row: row,
          cursor: row.path == wb.cursor,
          active: row.path == active,
          showCounts: wb.scope == ExplorerScope.changes,
          proof: row.file == null
              ? null
              : proofSquareFor(row.file!, widget.proof),
          onTap: () => _tap(row),
          onMenu: (at) => _menu(at, row),
        );
      },
    );
  }
}

/// How many files the All files list holds: the tree if it has loaded, else nothing to show.
final _allCountProvider = Provider.autoDispose.family<int?, String>((ref, id) {
  final tree = ref.watch(codeFileTreeProvider(id)).value;
  return tree == null ? null : flattenFilePaths(tree).length;
});

class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({
    required this.scope,
    required this.all,
    required this.changes,
    required this.onPick,
  });

  final ExplorerScope scope;
  final int? all;
  final int changes;
  final ValueChanged<ExplorerScope> onPick;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Row(
      children: [
        _Segment(
          key: const ValueKey('explorer-scope:all'),
          label: 'All files',
          count: all,
          on: scope == ExplorerScope.all,
          onTap: () => onPick(ExplorerScope.all),
        ),
        const SizedBox(width: 2),
        _Segment(
          key: const ValueKey('explorer-scope:changes'),
          label: 'Changes',
          count: changes,
          on: scope == ExplorerScope.changes,
          onTap: () => onPick(ExplorerScope.changes),
        ),
      ],
    ),
  );
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.count,
    required this.on,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: HaroPressable(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, hovered) => Container(
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? HaroTokens.ink : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 12.5,
                  color: on
                      ? HaroTokens.bg
                      : hovered
                      ? HaroTokens.ink
                      : HaroTokens.ink66,
                ),
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text(
                '$count',
                style: HaroText.mono(
                  size: 10,
                  color: (on ? HaroTokens.bg : HaroTokens.ink66).withValues(
                    alpha: .7,
                  ),
                  tracking: 0,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _RowView extends StatelessWidget {
  const _RowView({
    required this.row,
    required this.cursor,
    required this.active,
    required this.showCounts,
    required this.proof,
    required this.onTap,
    required this.onMenu,
  });

  final ExplorerRow row;

  /// The keyboard row.
  final bool cursor;

  /// The file shown in the editor.
  final bool active;
  final bool showCounts;
  final ProofSquare? proof;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final changed = row.file != null;
    final key = row.isGroup
        ? 'group-row:${row.path}'
        : showCounts && !row.isDir
        ? 'file-row:${row.path}'
        : 'tree-row:${row.path}';
    final nameColor = row.isGroup
        ? HaroTokens.ink66
        : changed
        ? HaroTokens.ink
        : row.isDir
        ? HaroTokens.ink86
        : HaroTokens.ink66;
    final icon = row.isGroup
        ? WorkbenchIcon.folderOpen
        : row.isDir
        ? (row.expanded ? WorkbenchIcon.folderOpen : WorkbenchIcon.folder)
        : WorkbenchIcon.file;
    final iconColor = row.isDir
        ? HaroTokens.ink66
        : changed
        ? HaroTokens.ink
        : HaroTokens.ink42;
    final letter = row.letter;

    Widget inner(bool hovered) => Container(
      key: ValueKey(key),
      padding: EdgeInsets.only(
        left: 8 + row.depth * WorkbenchTokens.rowIndent,
        right: WorkbenchTokens.rowPadRight,
      ),
      decoration: BoxDecoration(
        color: cursor
            ? HaroTokens.raised
            : (active || hovered)
            ? HaroTokens.panel
            : HaroTokens.transparent,
        border: Border(
          left: BorderSide(
            width: 2,
            color: active ? HaroTokens.ink : HaroTokens.transparent,
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: WorkbenchTokens.chevronWidth,
            child: row.isDir && !row.isGroup
                ? WorkbenchIconView(
                    row.expanded
                        ? WorkbenchIcon.chevronDown
                        : WorkbenchIcon.chevronRight,
                    size: 10,
                    color: HaroTokens.ink42,
                  )
                : null,
          ),
          const SizedBox(width: 6),
          WorkbenchIconView(
            icon,
            size: WorkbenchTokens.iconSize - 2,
            color: iconColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              row.name,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(size: 13, color: nameColor),
            ),
          ),
          if (proof != null) ...[
            const SizedBox(width: 6),
            ProofDot(proof!, key: ValueKey('proof:${row.path}')),
          ],
          if (showCounts && row.file != null) ...[
            const SizedBox(width: 8),
            Counts(added: row.file!.additions, removed: row.file!.deletions),
          ],
          SizedBox(
            width: 18,
            child: Text(
              letter != null
                  ? letter.text
                  : (row.isDir && row.hasChanges ? '•' : ''),
              key: letter == null && !row.hasChanges
                  ? null
                  : ValueKey('letter:${row.path}'),
              textAlign: TextAlign.right,
              style: HaroText.mono(
                size: 10.5,
                color: switch (letter) {
                  ChangeLetter.added => HaroTokens.gate,
                  ChangeLetter.deleted => HaroTokens.fail,
                  _ => HaroTokens.ink,
                },
                tracking: 0,
              ),
            ),
          ),
        ],
      ),
    );

    if (row.isGroup) return inner(false);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: HaroPressable(
        onTap: onTap,
        semanticLabel: row.path,
        builder: (context, hovered) => inner(hovered),
      ),
    );
  }
}
