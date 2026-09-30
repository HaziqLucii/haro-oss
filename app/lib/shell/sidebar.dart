import 'package:flutter/material.dart';

import '../backend/backend_health.dart';
import '../features/open_in/open_in_launcher.dart' show menuAnchor;
import '../shortcuts/platform_keys.dart';
import '../state/display_state.dart';
import '../theme/display_scope.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import '../widgets/haro_pressable.dart';
import '../widgets/status_square.dart';
import 'shell_models.dart';
import 'shell_slots.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.data,
    required this.actions,
    this.selectedWorkspaceId,
    this.triageSelected = false,
    this.backendStatus = BackendStatus.up,
    this.backendHost,
  });

  final ShellData data;
  final ShellActions actions;
  final String? selectedWorkspaceId;
  final bool triageSelected;
  final BackendStatus backendStatus;
  final String? backendHost;

  @override
  Widget build(BuildContext context) => Container(
    width: HaroTokens.sidebarWidth,
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: HaroTokens.line12)),
    ),
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 16),
            children: [
              _NavRow(
                label: 'Triage',
                count: '${data.triageCount}',
                selected: triageSelected,
                onTap: actions.onTriage,
              ),
              const SizedBox(height: 2),
              _NavRow(
                label: 'Backlog',
                count: '${data.backlogOpen} open',
                selected: false,
                onTap: actions.onBacklog,
              ),
              for (final project in data.projects) ...[
                const SizedBox(height: 22),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapUp: (d) =>
                      actions.onProjectMenu(project.id, d.globalPosition),
                  child: _ProjectHeader(
                    name: project.name,
                    onAdd: () => actions.onNewWorkspace(project.id),
                    onMenu: (position) =>
                        actions.onProjectMenu(project.id, position),
                  ),
                ),
                for (final ws in project.workspaces)
                  SidebarWorkspaceRow(
                    workspace: ws,
                    selected: ws.id == selectedWorkspaceId,
                    onTap: () => actions.onOpenWorkspace(ws.id),
                    onMenu: (position) =>
                        actions.onWorkspaceMenu(ws.id, position),
                  ),
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
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String count;
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
          const SizedBox(width: 8),
          Text(
            count,
            style: HaroText.mono(color: HaroTokens.ink42, tracking: 0),
          ),
        ],
      ),
    ),
  );
}

class _ProjectHeader extends StatefulWidget {
  const _ProjectHeader({
    required this.name,
    required this.onAdd,
    required this.onMenu,
  });

  final String name;
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
            child: Text(
              widget.name.toUpperCase(),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
            ),
          ),
          // Always laid out so the name never reflows when the button fades in.
          SidebarMoreButton(
            visible: _hovered,
            label: 'Actions for ${widget.name}',
            onMenu: widget.onMenu,
          ),
          HaroPressable(
            onTap: widget.onAdd,
            tooltip: 'New workspace',
            semanticLabel: 'New workspace in ${widget.name}',
            builder: (_, hovered) => SizedBox(
              width: 20,
              child: AnimatedDefaultTextStyle(
                duration: HaroTokens.fadeFast,
                curve: HaroTokens.curve,
                textAlign: TextAlign.right,
                style: HaroText.mono(
                  size: 13,
                  tracking: 0,
                  color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                ),
                child: const Text('+'),
              ),
            ),
          ),
        ],
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
    this.background = HaroTokens.transparent,
  });

  final bool visible;
  final String label;
  final ValueChanged<Offset> onMenu;

  /// Opaque behind the dots when they sit over other row content.
  final Color background;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: HaroTokens.fadeFast,
    curve: HaroTokens.curve,
    child: IgnorePointer(
      ignoring: !visible,
      child: Builder(
        builder: (context) => HaroPressable(
          onTap: () => onMenu(menuAnchor(context)),
          tooltip: 'More actions',
          semanticLabel: label,
          builder: (_, hovered) => Container(
            width: 24,
            alignment: Alignment.centerRight,
            color: background,
            child: AnimatedDefaultTextStyle(
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              style: HaroText.mono(
                size: 13,
                tracking: 0,
                color: hovered ? HaroTokens.ink : HaroTokens.ink42,
              ),
              child: const Text('···'),
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
                      StatusSquare.forState(state),
                      const SizedBox(width: 10),
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
                            if (state != DisplayState.idle) ...[
                              const SizedBox(width: 10),
                              Text(
                                workspace.word ?? state.word,
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
            const StatusSquare(size: 6, color: HaroTokens.ink42, filled: false),
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
