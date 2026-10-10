import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shell/shell_layout.dart';
import '../../../../../shortcuts/platform_keys.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../../../../../widgets/shell_icons.dart';

/// The editor toolbar's two window controls: show or hide the right rail, and focus mode.
class EditorShellButtons extends ConsumerWidget {
  const EditorShellButtons({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final railOpen = ref.watch(shellLayoutProvider.select((l) => l.railOpen));
    final focus = ref.watch(
      shellLayoutProvider.select(
        (l) => l.focusOn(workspaceId: workspaceId, codeStep: true),
      ),
    );
    final layout = ref.read(shellLayoutProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Focus mode hides the rail, so toggling it there would only change the saved state.
        if (!focus)
          _ToolbarIcon(
            key: const ValueKey('toolbar-rail'),
            icon: ShellIcon.panelRight,
            tooltip: 'Toggle right rail',
            on: railOpen,
            onTap: layout.toggleRail,
          ),
        _ToolbarIcon(
          key: const ValueKey('toolbar-focus'),
          icon: focus ? ShellIcon.shrink : ShellIcon.expand,
          tooltip:
              '${focus ? 'Exit focus' : 'Focus'} ${primaryLabel('↵', shift: true)}',
          on: focus,
          onTap: () => layout.toggleFocus(workspaceId),
        ),
      ],
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.on,
    required this.onTap,
  });

  final ShellIcon icon;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    builder: (context, hovered) => Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      child: ShellIconView(
        icon,
        size: 14,
        color: on || hovered ? HaroTokens.ink : HaroTokens.ink42,
      ),
    ),
  );
}
