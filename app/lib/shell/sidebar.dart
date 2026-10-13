import 'package:flutter/material.dart';

import '../backend/backend_health.dart';
import '../features/open_in/open_in_launcher.dart' show menuAnchor;
import '../features/workspace/steps/code/workbench/workbench_icons.dart';
import '../shortcuts/platform_keys.dart';
import '../state/display_state.dart';
import '../theme/display_scope.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import '../widgets/haro_pressable.dart';
import '../widgets/shell_icons.dart';
import '../widgets/agent_loader.dart';
import '../widgets/status_square.dart';
import 'shell_models.dart';
import 'shell_slots.dart';
import 'sidebar_fold.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.data,
    required this.actions,
    this.selectedWorkspaceId,
    this.triageSelected = false,
    this.backlogSelected = false,
    this.fold = const SidebarFold(),
    this.backendStatus = BackendStatus.up,
    this.backendHost,
  });

  final ShellData data;
  final ShellActions actions;
  final String? selectedWorkspaceId;
  final bool triageSelected;
  final bool backlogSelected;
  final SidebarFold fold;
  final BackendStatus backendStatus;
  final String? backendHost;

  @override
  Widget build(BuildContext context) => Container(
    width: HaroTokens.sidebarWidth,
    decoration: BoxDecoration(
      border: Border(right: BorderSide(color: HaroTokens.line12)),
    ),
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 16),
            children: [
              _NavRow(
                label: 'Dashboard',
                selected: triageSelected,
                onTap: actions.onTriage,
              ),
              const SizedBox(height: 2),
              _NavRow(
                label: 'Backlog',
                selected: backlogSelected,
                onTap: actions.onBacklog,
              ),
              for (final project in data.projects) ...[
                const SizedBox(height: 22),
                ..._projectSection(project),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HaroButton(
                variant: HaroButtonVariant.primary,
                height: 34,
                fontSize: 13.5,
                spread: true,
                label: 'New workspace',
                kbd: primaryLabel('N'),
                onPressed: () => actions.onNewWorkspace(null),
              ),
              const SizedBox(height: 6),
              HaroButton(label: 'Add project', onPressed: actions.onAddProject),
              _BackendNote(status: backendStatus, host: backendHost),
            ],
          ),
        ),
        SidebarFooterSlot(xp: data.xp, onHelp: actions.onXpHelp),
      ],
    ),
  );

  List<Widget> _projectSection(SidebarProject project) {
    final view = sidebarProjectView(project, fold, selectedWorkspaceId);
    return [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) =>
            actions.onProjectMenu(project.id, d.globalPosition),
        child: _ProjectHeader(
          key: ValueKey('project-header-${project.id}'),
          name: project.name,
          folded: view.folded,
          count: project.workspaces.length,
          onToggle: () => actions.onToggleProject(project.id),
          onAdd: () => actions.onNewWorkspace(project.id),
          onMenu: (position) => actions.onProjectMenu(project.id, position),
        ),
      ),
      for (final ws in view.rows)
        SidebarWorkspaceRow(
          workspace: ws,
          selected: ws.id == selectedWorkspaceId,
          onTap: () => actions.onOpenWorkspace(ws.id),
          onMenu: (position) => actions.onWorkspaceMenu(ws.id, position),
        ),
      if (view.mergedCount > 0)
        _MergedToggle(
          key: ValueKey('merged-toggle-${project.id}'),
          count: view.mergedCount,
          open: view.mergedOpen,
          onTap: () => actions.onToggleMerged(project.id),
        ),
    ];
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    builder: (_, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: selected || hovered ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(size: 14),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ProjectHeader extends StatefulWidget {
  const _ProjectHeader({
    super.key,
    required this.name,
    required this.folded,
    required this.count,
    required this.onToggle,
    required this.onAdd,
    required this.onMenu,
  });

  final String name;
  final bool folded;
  final int count;
  final VoidCallback onToggle;
  final VoidCallback onAdd;
  final ValueChanged<Offset> onMenu;

  @override
  State<_ProjectHeader> createState() => _ProjectHeaderState();
}

class _ProjectHeaderState extends State<_ProjectHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: HaroPressable(
              onTap: widget.onToggle,
              semanticLabel: widget.folded
                  ? 'Show ${widget.name}'
                  : 'Fold ${widget.name}',
              builder: (_, hovered) {
                final color = hovered ? HaroTokens.ink66 : HaroTokens.ink42;
                return Row(
                  children: [
                    WorkbenchIconView(
                      widget.folded
                          ? WorkbenchIcon.chevronRight
                          : WorkbenchIcon.chevronDown,
                      size: 11,
                      color: color,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        widget.name.toUpperCase(),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.mono(size: 10.5, color: color),
                      ),
                    ),
                    if (widget.folded) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${widget.count}',
                        style: HaroText.mono(
                          size: 10.5,
                          tracking: 0,
                          color: HaroTokens.ink42,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          // Always laid out so the name never reflows when the button fades in.
          SidebarMoreButton(
            visible: _hovered,
            label: 'Actions for ${widget.name}',
            onMenu: widget.onMenu,
          ),
          SidebarAddButton(onTap: widget.onAdd, name: widget.name),
        ],
      ),
    ),
  );
}

/// The `+` at the end of a project header. A 24 px square like the dots beside it, so its
/// ripple is a circle of exactly that size instead of a pill reaching over its neighbour.
class SidebarAddButton extends StatelessWidget {
  const SidebarAddButton({super.key, required this.onTap, required this.name});

  final VoidCallback onTap;
  final String name;

  @override
  Widget build(BuildContext context) => HaroPressable(
    rippleOutset: EdgeInsets.zero,
    onTap: onTap,
    tooltip: 'New workspace',
    semanticLabel: 'New workspace in $name',
    builder: (_, hovered) => SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: AnimatedDefaultTextStyle(
          duration: HaroTokens.fadeFast,
          curve: HaroTokens.curve,
          style: HaroText.mono(
            size: 13,
            tracking: 0,
            color: hovered ? HaroTokens.ink : HaroTokens.ink42,
          ),
          child: const Text('+'),
        ),
      ),
    ),
  );
}

/// One line standing for a project's merged workspaces: "3 merged" to list them, "hide
/// merged" to fold them away again.
class _MergedToggle extends StatelessWidget {
  const _MergedToggle({
    super.key,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: open ? 'Hide merged' : 'Show $count merged',
    builder: (_, hovered) => Container(
      height: DisplayScope.densityOf(context).sidebarRow,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: Text(
        open ? 'HIDE MERGED' : '$count MERGED',
        style: HaroText.mono(
          size: 10.5,
          color: hovered ? HaroTokens.ink66 : HaroTokens.ink42,
        ),
      ),
    ),
  );
}

/// The `···` that opens a row's context menu, for users who never right-click. It fades in
/// with its row's hover and opens the menu under itself.
class SidebarMoreButton extends StatelessWidget {
  const SidebarMoreButton({
    super.key,
    required this.visible,
    required this.label,
    required this.onMenu,
    this.background,
  });

  final bool visible;
  final String label;
  final ValueChanged<Offset> onMenu;

  /// Opaque behind the dots when they sit over other row content; none by default.
  final Color? background;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: HaroTokens.fadeFast,
    curve: HaroTokens.curve,
    child: IgnorePointer(
      ignoring: !visible,
      child: Builder(
        builder: (context) => HaroPressable(
          rippleOutset: EdgeInsets.zero,
          onTap: () => onMenu(menuAnchor(context)),
          tooltip: 'More actions',
          semanticLabel: label,
          builder: (_, hovered) => SizedBox(
            width: 24,
            height: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The box that hides a long name under the dots only shows once the row's own
                // hover fill is nearly there, so it never reads as a rectangle of its own; on
                // the way out it goes at once.
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: visible ? 1 : 0),
                    duration: visible ? HaroTokens.fadeFast : Duration.zero,
                    curve: const Interval(.75, 1, curve: Curves.easeOut),
                    builder: (_, v, child) => Opacity(opacity: v, child: child),
                    child: ColoredBox(
                      color: background ?? HaroTokens.transparent,
                    ),
                  ),
                ),
                ShellIconView(
                  ShellIcon.ellipsis,
                  size: 16,
                  color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// One workspace line. Public so the Display settings preview draws the real row.
class SidebarWorkspaceRow extends StatelessWidget {
  const SidebarWorkspaceRow({
    super.key,
    required this.workspace,
    required this.selected,
    required this.onTap,
    this.onMenu,
  });

  final SidebarWorkspace workspace;
  final bool selected;
  final VoidCallback onTap;

  /// Right-click and the hover `···`, with the position to open the menu at. Null draws
  /// neither (the Display settings preview).
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final state = workspace.state;
    final onMenu = this.onMenu;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: onMenu == null
            ? null
            : (d) => onMenu(d.globalPosition),
        child: HaroPressable(
          onTap: onTap,
          semanticLabel: workspace.name,
          builder: (_, hovered) => Opacity(
            opacity: state == DisplayState.merged ? .55 : 1,
            child: AnimatedContainer(
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              height: DisplayScope.densityOf(context).sidebarRow,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: selected || hovered
                    ? HaroTokens.raised
                    : HaroTokens.transparent,
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Stack(
                alignment: Alignment.centerRight,
                children: [
                  Row(
                    children: [
                      state == DisplayState.agent
                          ? const AgentLoader(
                              key: ValueKey('sidebar-agent-loader'),
                              size: 12,
                              layoutSize: HaroTokens.markSidebarRow,
                            )
                          : StatusSquare.forState(
                              state,
                              size: HaroTokens.markSidebarRow,
                            ),
                      const SizedBox(width: HaroTokens.markSidebarGap),
                      Expanded(
                        child: Text(
                          workspace.name,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.ui(size: 13.5),
                        ),
                      ),
                      AnimatedOpacity(
                        opacity: onMenu != null && hovered ? 0 : 1,
                        duration: HaroTokens.fadeFast,
                        curve: HaroTokens.curve,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (workspace.manual) ...[
                              const SizedBox(width: 8),
                              Text(
                                'manual',
                                maxLines: 1,
                                softWrap: false,
                                style: HaroText.mono(
                                  size: 10,
                                  color: HaroTokens.ink42,
                                  tracking: 0,
                                ),
                              ),
                            ],
                            if (state.sidebarWord(workspace.word) != null) ...[
                              const SizedBox(width: 10),
                              Text(
                                state.sidebarWord(workspace.word)!,
                                maxLines: 1,
                                softWrap: false,
                                style: HaroText.mono(
                                  size: 10,
                                  color: state.color,
                                  tracking: 0,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (onMenu != null)
                    SidebarMoreButton(
                      visible: hovered,
                      label: 'Actions for ${workspace.name}',
                      onMenu: onMenu,
                      background: HaroTokens.raised,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackendNote extends StatelessWidget {
  const _BackendNote({required this.status, required this.host});

  final BackendStatus status;
  final String? host;

  @override
  Widget build(BuildContext context) {
    if (status != BackendStatus.down) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Tooltip(
        message: 'No backend answering${host == null ? '' : ' at $host'}',
        child: Row(
          children: [
            StatusSquare(size: 6, color: HaroTokens.ink42, filled: false),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'BACKEND DOWN',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: HaroText.mono(size: 10, color: HaroTokens.ink42),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
