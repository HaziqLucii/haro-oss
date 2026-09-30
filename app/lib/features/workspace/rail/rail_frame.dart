import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shell/gate_chip.dart';
import '../../../shell/shell_layout.dart';
import '../../../shortcuts/platform_keys.dart';
import '../../../state/workspace_flow.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/panel_switcher.dart';
import '../../../widgets/shell_icons.dart';
import 'workspace_rail.dart';

/// The right rail's container: 290px open, the 44px strip when collapsed, gone in focus mode.
/// Only the frame lives here; what the open rail shows is [WorkspaceRail].
class RailFrame extends ConsumerWidget {
  const RailFrame({
    super.key,
    required this.workspaceId,
    required this.flow,
    required this.terminalOpen,
    required this.hidden,
    required this.onVerify,
    required this.onToggleTerminal,
    required this.onError,
  });

  final String workspaceId;
  final WorkspaceFlow flow;
  final bool terminalOpen;

  /// Focus mode: no rail at all.
  final bool hidden;
  final VoidCallback onVerify;
  final VoidCallback onToggleTerminal;
  final ValueChanged<Object> onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(shellLayoutProvider.select((l) => l.railOpen));
    final layout = ref.read(shellLayoutProvider.notifier);
    if (hidden) {
      return const PanelSwitcher(
        variant: 'hidden',
        width: 0,
        alignment: Alignment.centerRight,
        child: SizedBox.shrink(),
      );
    }
    if (!open) {
      return PanelSwitcher(
        variant: 'strip',
        width: HaroTokens.railStripWidth,
        alignment: Alignment.centerRight,
        child: RailStrip(
          flow: flow,
          terminalOpen: terminalOpen,
          onExpand: layout.toggleRail,
          onVerify: onVerify,
          onToggleTerminal: onToggleTerminal,
        ),
      );
    }
    return PanelSwitcher(
      variant: 'open',
      width: HaroTokens.railWidth,
      alignment: Alignment.centerRight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          WorkspaceRail(
            workspaceId: workspaceId,
            flow: flow,
            terminalOpen: terminalOpen,
            onVerify: onVerify,
            onToggleTerminal: onToggleTerminal,
            onError: onError,
          ),
          Positioned(
            top: 12,
            right: 10,
            child: ShellIconButton(
              key: const ValueKey('rail-collapse'),
              icon: ShellIcon.chevronsRight,
              tooltip: 'Minimize rail',
              width: 24,
              height: 22,
              iconSize: 14,
              onTap: layout.toggleRail,
            ),
          ),
        ],
      ),
    );
  }
}

/// The collapsed rail: the gate square, the needs-your-eyes count, who writes the code, and
/// the terminal toggle.
class RailStrip extends StatelessWidget {
  const RailStrip({
    super.key,
    required this.flow,
    required this.terminalOpen,
    required this.onExpand,
    required this.onVerify,
    required this.onToggleTerminal,
  });

  final WorkspaceFlow flow;
  final bool terminalOpen;
  final VoidCallback onExpand;
  final VoidCallback onVerify;
  final VoidCallback onToggleTerminal;

  @override
  Widget build(BuildContext context) {
    final gate = gateChipFor(flow);
    final mode = flow.manual ? 'MANUAL' : 'AGENT';
    return Container(
      key: const ValueKey('rail-strip'),
      color: HaroTokens.bg,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          ShellIconButton(
            key: const ValueKey('rail-expand'),
            icon: ShellIcon.chevronsLeft,
            tooltip: 'Expand rail',
            width: 30,
            onTap: onExpand,
          ),
          Container(
            width: 22,
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 10),
            color: HaroTokens.line12,
          ),
          HaroPressable(
            onTap: onVerify,
            tooltip: 'Gate ${gate.word.toLowerCase()}',
            semanticLabel: 'Gate',
            builder: (context, _) => Container(
              key: const ValueKey('rail-strip-gate'),
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: gate.filled ? gate.color : HaroTokens.transparent,
                border: Border.all(color: gate.color),
              ),
            ),
          ),
          const SizedBox(height: 10),
          HaroPressable(
            onTap: onVerify,
            tooltip: 'Needs your eyes',
            semanticLabel: 'Needs your eyes',
            builder: (context, hovered) => Text(
              '${flow.openLookCount}',
              key: const ValueKey('rail-strip-eyes'),
              style: HaroText.mono(
                size: 10.5,
                color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                tracking: 0,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Tooltip(
            message: flow.manual ? 'Manual mode' : 'Agent mode',
            child: RotatedBox(
              quarterTurns: 1,
              child: Text(
                mode,
                key: const ValueKey('rail-strip-mode'),
                maxLines: 1,
                softWrap: false,
                style: HaroText.mono(
                  size: 9,
                  color: HaroTokens.ink42,
                  tracking: .08,
                ),
              ),
            ),
          ),
          const Spacer(),
          ShellIconButton(
            key: const ValueKey('rail-strip-terminal'),
            icon: ShellIcon.terminal,
            tooltip: 'Terminal ${controlLabel('`')}',
            width: 30,
            on: terminalOpen,
            onTap: onToggleTerminal,
          ),
        ],
      ),
    );
  }
}
