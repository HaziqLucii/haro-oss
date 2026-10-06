import 'package:flutter/material.dart';

import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../../../../../widgets/shell_icons.dart';
import 'workbench_icons.dart';
import 'workbench_state.dart';
import 'workbench_widgets.dart';

/// The 48px icon rail on the left of the code step: Files, Search, Changes (with a count) and
/// Gate. The first three switch the side panel (the active one closes it); Gate opens the bottom
/// panel; it reads as "on" only when the caller says that panel is showing its Gate tab.
class ActivityBar extends StatelessWidget {
  const ActivityBar({
    super.key,
    required this.view,
    required this.sideOpen,
    required this.changeCount,
    required this.onPick,
    required this.onGate,
    this.gateOpen = false,
    this.searchHint = '',
    this.focus = false,
    this.onFocus,
    this.focusHint = '',
  });

  final WorkbenchView view;
  final bool sideOpen;
  final int changeCount;
  final ValueChanged<WorkbenchView> onPick;
  final VoidCallback onGate;

  /// The bottom panel is open on its Gate tab.
  final bool gateOpen;

  /// Shortcut text appended to the Search tooltip.
  final String searchHint;

  /// Focus mode is on: the button at the foot then leaves it. A null [onFocus] draws none.
  final bool focus;
  final VoidCallback? onFocus;
  final String focusHint;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('activity-bar'),
    width: WorkbenchTokens.activityBarWidth,
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: HaroTokens.line12)),
    ),
    child: Column(
      children: [
        Expanded(child: SingleChildScrollView(child: _buttons())),
        if (onFocus != null)
          _FocusButton(on: focus, hint: focusHint, onTap: onFocus!),
      ],
    ),
  );

  Widget _buttons() => Column(
    children: [
      _ActivityButton(
        id: 'files',
        icon: WorkbenchIcon.files,
        tooltip: 'Files',
        on: sideOpen && view == WorkbenchView.files,
        onTap: () => onPick(WorkbenchView.files),
      ),
      const SizedBox(height: 4),
      _ActivityButton(
        id: 'search',
        icon: WorkbenchIcon.search,
        tooltip: searchHint.isEmpty ? 'Search' : 'Search $searchHint',
        on: sideOpen && view == WorkbenchView.search,
        onTap: () => onPick(WorkbenchView.search),
      ),
      const SizedBox(height: 4),
      _ActivityButton(
        id: 'changes',
        icon: WorkbenchIcon.changes,
        tooltip: 'Changes',
        on: sideOpen && view == WorkbenchView.changes,
        badge: changeCount > 0 ? '$changeCount' : null,
        onTap: () => onPick(WorkbenchView.changes),
      ),
      const SizedBox(height: 4),
      _ActivityButton(
        id: 'gate',
        icon: WorkbenchIcon.gate,
        tooltip: 'Gate',
        on: gateOpen,
        onTap: onGate,
      ),
    ],
  );
}

/// Focus mode toggle at the foot of the bar: lit with a hairline while focus is on.
class _FocusButton extends StatelessWidget {
  const _FocusButton({
    required this.on,
    required this.hint,
    required this.onTap,
  });

  final bool on;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tip = on ? 'Exit focus' : 'Focus the editor';
    return HaroPressable(
      onTap: onTap,
      tooltip: hint.isEmpty ? tip : '$tip $hint',
      semanticLabel: tip,
      builder: (context, hovered) => AnimatedContainer(
        key: const ValueKey('activity:focus'),
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        width: WorkbenchTokens.activityButton,
        height: WorkbenchTokens.activityButton,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HaroTokens.radius),
          border: Border.all(
            color: on ? HaroTokens.line30 : HaroTokens.transparent,
          ),
        ),
        child: ShellIconView(
          on ? ShellIcon.shrink : ShellIcon.expand,
          size: 16,
          color: on || hovered ? HaroTokens.ink : HaroTokens.ink66,
        ),
      ),
    );
  }
}

class _ActivityButton extends StatelessWidget {
  const _ActivityButton({
    required this.id,
    required this.icon,
    required this.tooltip,
    required this.on,
    required this.onTap,
    this.badge,
  });

  final String id;
  final WorkbenchIcon icon;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    builder: (context, hovered) => SizedBox(
      key: ValueKey('activity:$id'),
      width: WorkbenchTokens.activityButton,
      height: WorkbenchTokens.activityButton,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: on ? HaroTokens.panel : HaroTokens.transparent,
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Center(
                child: WorkbenchIconView(
                  icon,
                  size: 18,
                  color: on || hovered ? HaroTokens.ink : HaroTokens.ink42,
                ),
              ),
            ),
          ),
          if (on)
            const Positioned(
              left: -6,
              top: 6,
              bottom: 6,
              width: 2,
              child: ColoredBox(
                key: ValueKey('activity-marker'),
                color: HaroTokens.ink,
              ),
            ),
          if (badge != null)
            Positioned(
              right: 1,
              bottom: 2,
              child: Container(
                key: ValueKey('activity-badge:$id'),
                constraints: const BoxConstraints(minWidth: 14),
                height: 13,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: HaroTokens.ink,
                  borderRadius: BorderRadius.circular(1),
                ),
                child: Text(
                  badge!,
                  style: HaroText.mono(
                    size: 8.5,
                    color: HaroTokens.bg,
                    tracking: 0,
                    height: 1.2,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
