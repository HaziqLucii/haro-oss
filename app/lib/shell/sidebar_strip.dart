import 'package:flutter/material.dart';

import '../shortcuts/platform_keys.dart';
import '../state/display_state.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_pressable.dart';
import '../widgets/shell_icons.dart';
import '../widgets/status_square.dart';
import 'shell_models.dart';
import 'shell_slots.dart';

/// The 52px sidebar: one status square per workspace (a gap between projects), the level
/// badge slot and a new-workspace button. Everything the expanded sidebar names is a tooltip.
class SidebarStrip extends StatelessWidget {
  const SidebarStrip({
    super.key,
    required this.data,
    required this.actions,
    required this.onExpand,
    this.selectedWorkspaceId,
  });

  final ShellData data;
  final ShellActions actions;
  final VoidCallback onExpand;
  final String? selectedWorkspaceId;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('sidebar-strip'),
    width: HaroTokens.sidebarStripWidth,
    padding: const EdgeInsets.symmetric(vertical: 12),
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: HaroTokens.line12)),
    ),
    child: Column(
      children: [
        ShellIconButton(
          key: const ValueKey('sidebar-expand'),
          icon: ShellIcon.chevronsRight,
          tooltip: 'Expand sidebar',
          width: 32,
          onTap: onExpand,
        ),
        Container(
          width: 24,
          height: 1,
          margin: const EdgeInsets.symmetric(vertical: 10),
          color: HaroTokens.line12,
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final (i, project) in data.projects.indexed)
                for (final (j, ws) in project.workspaces.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i > 0 && j == 0 ? 8 : 0),
                    child: _StripCell(
                      workspace: ws,
                      selected: ws.id == selectedWorkspaceId,
                      onTap: () => actions.onOpenWorkspace(ws.id),
                    ),
                  ),
            ],
          ),
        ),
        StripBadgeSlot(xp: data.xp, onTap: actions.onXpHelp),
        const SizedBox(height: 6),
        HaroPressable(
          onTap: () => actions.onNewWorkspace(null),
          tooltip: 'New workspace ${primaryLabel('N')}',
          semanticLabel: 'New workspace',
          builder: (context, hovered) => AnimatedContainer(
            key: const ValueKey('strip-new-workspace'),
            duration: HaroTokens.fadeFast,
            curve: HaroTokens.curve,
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? HaroTokens.ink86 : HaroTokens.ink,
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: const ShellIconView(
              ShellIcon.plus,
              size: 16,
              color: HaroTokens.bg,
            ),
          ),
        ),
      ],
    ),
  );
}

class _StripCell extends StatelessWidget {
  const _StripCell({
    required this.workspace,
    required this.selected,
    required this.onTap,
  });

  final SidebarWorkspace workspace;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = workspace.state;
    return HaroPressable(
      onTap: onTap,
      tooltip: '${workspace.name} · ${workspace.word ?? state.word}',
      semanticLabel: workspace.name,
      builder: (context, hovered) => Opacity(
        opacity: state == DisplayState.merged ? .55 : 1,
        child: AnimatedContainer(
          key: ValueKey('strip-ws:${workspace.id}'),
          duration: HaroTokens.fadeFast,
          curve: HaroTokens.curve,
          width: 32,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected || hovered
                ? HaroTokens.raised
                : HaroTokens.transparent,
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              StatusSquare.forState(state, size: HaroTokens.markSidebarStrip),
              if (workspace.manual)
                Positioned(
                  right: 3,
                  bottom: 1,
                  child: Text(
                    'M',
                    key: ValueKey('strip-manual:${workspace.id}'),
                    style: HaroText.mono(
                      size: 8,
                      color: HaroTokens.ink42,
                      tracking: 0,
                      height: 1.2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
