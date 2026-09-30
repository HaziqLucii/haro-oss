import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../api/models/models.dart' show WorkspaceMode;
import '../shortcuts/platform_keys.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import '../widgets/haro_mark.dart';
import '../widgets/haro_pressable.dart';
import '../widgets/haro_segmented.dart';
import '../widgets/kbd.dart';
import '../widgets/shell_icons.dart';
import '../widgets/status_square.dart';
import 'shell_models.dart';

/// Room for the macOS traffic lights when the title bar is hidden.
const double trafficLightInset = 64;

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.crumb1,
    this.crumb2,
    required this.needYouCount,
    required this.actions,
    this.workspaceMode,
    this.trafficLightRoom = false,
    this.draggable = true,
  });

  final String crumb1;
  final String? crumb2;
  final int needYouCount;
  final ShellActions actions;
  final WorkspaceMode? workspaceMode;
  final bool trafficLightRoom;
  final bool draggable;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.only(
        left: 16 + (trafficLightRoom ? trafficLightInset : 0),
        right: 16,
      ),
      child: Row(
        children: [
          ShellIconButton(
            key: const ValueKey('sidebar-toggle'),
            icon: ShellIcon.menu,
            tooltip: 'Toggle sidebar',
            onTap: actions.onToggleSidebar,
          ),
          const SizedBox(width: 14),
          _Wordmark(onTap: actions.onHome),
          const SizedBox(width: 16),
          const SizedBox(
            width: 1,
            height: 18,
            child: ColoredBox(color: HaroTokens.line14),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                // CSS flex 0 1 260: the search box gives way before the breadcrumb does.
                final searchWidth = ((box.maxWidth - 16) * .4).clamp(
                  0.0,
                  260.0,
                );
                return Row(
                  children: [
                    Expanded(
                      child: IgnorePointer(
                        child: _Breadcrumb(crumb1: crumb1, crumb2: crumb2),
                      ),
                    ),
                    if (workspaceMode != null) ...[
                      const SizedBox(width: 16),
                      _ModeToggle(
                        mode: workspaceMode!,
                        onChanged: actions.onSetMode,
                        showLabel: box.maxWidth >= 660,
                      ),
                    ],
                    const SizedBox(width: 16),
                    Flexible(
                      child: SizedBox(
                        width: searchWidth,
                        child: HaroButton(
                          height: HaroTokens.controlHeight,
                          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                          foreground: HaroTokens.ink42,
                          spread: true,
                          label: 'Search or run a command',
                          onPressed: actions.onSearch,
                          child: const _SearchContent(),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 16),
          _NeedYouPill(count: needYouCount, onTap: actions.onNeedYou),
          const SizedBox(width: 16),
          HaroButton(
            width: HaroTokens.controlHeight,
            height: HaroTokens.controlHeight,
            padding: EdgeInsets.zero,
            tooltip: 'Keyboard shortcuts',
            label: '?',
            textStyle: HaroText.mono(size: 12, tracking: 0),
            onPressed: actions.onShortcuts,
            child: const Center(child: Text('?')),
          ),
          const SizedBox(width: 16),
          HaroButton(
            height: HaroTokens.controlHeight,
            label: 'Settings',
            onPressed: actions.onSettings,
          ),
        ],
      ),
    );
    const rule = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: SizedBox.expand(),
    );
    // The drag area sits under the controls, not around them: its double-tap recognizer
    // would otherwise hold every button click for 300ms.
    return SizedBox(
      height: HaroTokens.topBarHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (draggable) const DragToMoveArea(child: rule) else rule,
          content,
        ],
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: 'Triage',
    builder: (_, _) => const HaroWordmark(fontSize: 21),
  );
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.crumb1, required this.crumb2});

  final String crumb1;
  final String? crumb2;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(color: HaroTokens.ink42, tracking: .12);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: crumb1.toUpperCase()),
          if (crumb2 != null && crumb2!.isNotEmpty) ...[
            const TextSpan(text: '  /  '),
            TextSpan(
              text: crumb2!.toUpperCase(),
              style: style.copyWith(color: HaroTokens.ink),
            ),
          ],
        ],
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.mode,
    required this.onChanged,
    required this.showLabel,
  });

  final WorkspaceMode mode;
  final ValueChanged<WorkspaceMode> onChanged;
  final bool showLabel;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (showLabel) ...[
        Text(
          'WHO WRITES THE CODE',
          key: const ValueKey('mode-label'),
          maxLines: 1,
          softWrap: false,
          style: HaroText.mono(
            size: 10,
            color: HaroTokens.ink42,
            tracking: .12,
          ),
        ),
        const SizedBox(width: 8),
      ],
      HaroSegmented<WorkspaceMode>(
        keyPrefix: 'mode',
        selected: mode,
        onChanged: (m) {
          if (m != mode) onChanged(m);
        },
        segments: const [
          HaroSegment(
            WorkspaceMode.agent,
            'AGENT',
            tooltip: 'The agent writes, you review',
          ),
          HaroSegment(
            WorkspaceMode.manual,
            'MANUAL',
            tooltip: 'You write; AI only plans and researches',
          ),
        ],
      ),
    ],
  );
}

class _SearchContent extends StatelessWidget {
  const _SearchContent();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Row(
      children: [
        const Expanded(
          child: Text(
            'Search or run a command',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // The hint gives way first when the mode switch leaves the box little room.
        if (box.maxWidth >= 120) ...[
          const SizedBox(width: 24),
          Kbd(primaryLabel('K')),
        ],
      ],
    ),
  );
}

class _NeedYouPill extends StatelessWidget {
  const _NeedYouPill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroButton(
    height: HaroTokens.controlHeight,
    tooltip: 'Jump to the next workspace that needs you',
    label: '$count need you',
    foreground: HaroTokens.ink,
    textStyle: HaroText.mono(size: 11, tracking: .08),
    onPressed: onTap,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        count > 0
            ? const StatusSquare(color: HaroTokens.fail, filled: true)
            : const StatusSquare(color: HaroTokens.ink42, filled: false),
        const SizedBox(width: 8),
        Text('$count need you'.toUpperCase(), maxLines: 1, softWrap: false),
        const SizedBox(width: 12),
        Kbd(primaryLabel('J'), bordered: false, size: 11),
      ],
    ),
  );
}
