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
import 'window_controls.dart';

/// Room for the macOS traffic lights when the title bar is hidden.
const double trafficLightInset = 64;

/// The space between the need-you pill, help and settings: close, but not touching.
const double _buttonGap = 4;

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
    this.account,
    this.windowControls,
    this.minimal = false,
    this.xp,
  });

  final String crumb1;
  final String? crumb2;
  final int needYouCount;
  final ShellActions actions;
  final WorkspaceMode? workspaceMode;
  final bool trafficLightRoom;
  final bool draggable;

  /// The GitHub avatar at the far right.
  final Widget? account;

  /// Minimize, maximize and close, drawn by haro when the native title bar is hidden (Linux).
  /// Null means [useWindowControls] decides; tests pass `false` or a fake.
  final bool? windowControls;

  /// Minimal view: search shrinks to its key, the need-you pill to its square, help and
  /// settings step aside and the level chip takes the sidebar footer's place.
  final bool minimal;
  final XpFooterData? xp;

  @override
  Widget build(BuildContext context) {
    final controls = windowControls ?? useWindowControls;
    final content = Padding(
      padding: EdgeInsets.only(
        left: 16 + (trafficLightRoom ? trafficLightInset : 0),
        right: controls ? 6 : 16,
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
          SizedBox(
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
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: IgnorePointer(
                                child: _Breadcrumb(
                                  crumb1: crumb1,
                                  crumb2: crumb2,
                                ),
                              ),
                            ),
                            if (minimal && crumb2 != null)
                              Builder(
                                builder: (context) => ShellIconButton(
                                  key: const ValueKey('top-switch-workspace'),
                                  icon: ShellIcon.chevronDown,
                                  tooltip: 'Switch workspace',
                                  width: 24,
                                  height: 24,
                                  iconSize: 14,
                                  onTap: () {
                                    final box =
                                        context.findRenderObject() as RenderBox;
                                    actions.onSwitchWorkspace(
                                      box.localToGlobal(
                                        Offset(0, box.size.height + 4),
                                      ),
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (workspaceMode != null) ...[
                      const SizedBox(width: 16),
                      _ModeToggle(
                        mode: workspaceMode!,
                        onChanged: actions.onSetMode,
                      ),
                    ],
                    const SizedBox(width: 16),
                    if (minimal)
                      HaroButton(
                        key: const ValueKey('top-search-compact'),
                        height: HaroTokens.controlHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        tooltip: 'Search or run a command',
                        label: 'Search or run a command',
                        variant: HaroButtonVariant.control,
                        textStyle: HaroText.mono(size: 10.5, tracking: 0),
                        onPressed: actions.onSearch,
                        child: Text(primaryLabel('K')),
                      )
                    else
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
          if (minimal)
            _NeedYouSquare(count: needYouCount, onTap: actions.onNeedYou)
          else
            _NeedYouPill(count: needYouCount, onTap: actions.onNeedYou),
          const SizedBox(width: _buttonGap),
          if (minimal && xp != null) ...[
            _LevelChip(xp: xp!, onTap: actions.onXpHelp),
            const SizedBox(width: _buttonGap),
          ],
          if (!minimal) ...[
            const SizedBox(width: _buttonGap),
            HaroButton(
              width: HaroTokens.controlHeight,
              height: HaroTokens.controlHeight,
              padding: EdgeInsets.zero,
              tooltip: 'Help and guide',
              label: '?',
              variant: HaroButtonVariant.control,
              textStyle: HaroText.mono(size: 12, tracking: 0),
              onPressed: actions.onHelp,
              child: const Center(child: Text('?')),
            ),
          ],
          const SizedBox(width: _buttonGap),
          HaroButton(
            key: const ValueKey('top-settings'),
            width: HaroTokens.controlHeight,
            height: HaroTokens.controlHeight,
            padding: EdgeInsets.zero,
            tooltip: 'Settings',
            label: 'Settings',
            variant: HaroButtonVariant.control,
            onPressed: actions.onSettings,
            child: Center(
              child: ShellIconView(
                ShellIcon.gear,
                size: 16,
                color: HaroTokens.bg,
              ),
            ),
          ),
          if (account != null) ...[const SizedBox(width: 16), account!],
          if (controls) ...[const SizedBox(width: 14), const WindowControls()],
        ],
      ),
    );
    final rule = DecoratedBox(
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
          if (draggable) DragToMoveArea(child: rule) else rule,
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
    semanticLabel: 'Dashboard',
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
  const _ModeToggle({required this.mode, required this.onChanged});

  final WorkspaceMode mode;
  final ValueChanged<WorkspaceMode> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
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
  Widget build(BuildContext context) {
    // Pressable only when something needs you; at zero it is a dim ghost, like any control that
    // would do nothing.
    final live = count > 0;
    return HaroButton(
      key: const ValueKey('top-need-you'),
      height: HaroTokens.controlHeight,
      tooltip: 'Jump to the next workspace to review',
      label: live ? '$count to review' : 'Nothing to review',
      variant: live ? HaroButtonVariant.control : HaroButtonVariant.secondary,
      foreground: HaroTokens.ink42,
      textStyle: HaroText.mono(size: 11, tracking: .08),
      onPressed: live ? onTap : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          live
              ? StatusSquare(color: HaroTokens.fail, filled: true)
              : StatusSquare(color: HaroTokens.ink42, filled: false),
          const SizedBox(width: 8),
          if (live) ...[
            Text('$count', maxLines: 1, softWrap: false),
            const SizedBox(width: 6),
            ShellIconView(
              ShellIcon.chevronRight,
              size: 12,
              color: HaroTokens.onAccent,
            ),
            const SizedBox(width: 6),
            const Text('REVIEW', maxLines: 1, softWrap: false),
          ] else
            const Text('NOTHING TO REVIEW', maxLines: 1, softWrap: false),
          const SizedBox(width: 12),
          Kbd(
            primaryLabel('J'),
            bordered: false,
            size: 11,
            color: live ? HaroTokens.bg : HaroTokens.ink42,
          ),
        ],
      ),
    );
  }
}

/// Minimal view's need-you: just the square, the count in the tooltip.
class _NeedYouSquare extends StatelessWidget {
  const _NeedYouSquare({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final live = count > 0;
    return HaroButton(
      key: const ValueKey('top-need-you-square'),
      width: HaroTokens.controlHeight,
      height: HaroTokens.controlHeight,
      padding: EdgeInsets.zero,
      tooltip: live
          ? '$count to review (${primaryLabel('J')})'
          : 'Nothing to review',
      label: live ? '$count to review' : 'Nothing to review',
      variant: live ? HaroButtonVariant.control : HaroButtonVariant.secondary,
      onPressed: live ? onTap : null,
      child: Center(
        child: live
            ? StatusSquare(color: HaroTokens.fail, filled: true)
            : StatusSquare(color: HaroTokens.ink42, filled: false),
      ),
    );
  }
}

/// `Lv 7 · 14 d`: the level and the streak, where the sidebar footer would show them.
class _LevelChip extends StatelessWidget {
  const _LevelChip({required this.xp, required this.onTap});

  final XpFooterData xp;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroButton(
    key: const ValueKey('top-xp-chip'),
    height: HaroTokens.controlHeight,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    tooltip: xp.tooltip,
    label: xp.tooltip,
    variant: HaroButtonVariant.secondary,
    foreground: HaroTokens.ink66,
    textStyle: HaroText.mono(size: 10.5, tracking: 0),
    onPressed: onTap,
    child: Text(
      xp.streakDays > 0
          ? 'Lv ${xp.level}, ${xp.streakDays} d'
          : 'Lv ${xp.level}',
      maxLines: 1,
      softWrap: false,
    ),
  );
}
