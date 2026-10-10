import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import 'haro_pressable.dart';

class PageTab {
  const PageTab(this.label, {this.count, this.tabKey});

  /// Shown as given; pass it uppercased.
  final String label;
  final int? count;
  final Key? tabKey;
}

/// The underlined tab row under a page headline (dashboard, backlog): mono labels with a
/// count, the selected one inked and underlined, an optional [trailing] widget (a search box,
/// a summary) pinned to the right on the same hairline.
class PageTabBar extends StatelessWidget {
  const PageTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onPick,
    this.trailing,
  });

  final List<PageTab> tabs;
  final int selected;
  final ValueChanged<int> onPick;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line12)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < tabs.length; i++) ...[
          if (i > 0) const SizedBox(width: 28),
          _TabLabel(
            key: tabs[i].tabKey,
            label: tabs[i].label,
            count: tabs[i].count,
            on: i == selected,
            onTap: () => onPick(i),
          ),
        ],
        if (trailing == null)
          const Spacer()
        else
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 16),
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ),
      ],
    ),
  );
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
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
  Widget build(BuildContext context) => Semantics(
    selected: on,
    child: HaroPressable(
      onTap: onTap,
      semanticLabel: count == null ? label : '$label $count',
      builder: (context, hovered) {
        final fg = on
            ? HaroTokens.ink
            : (hovered ? HaroTokens.ink66 : HaroTokens.ink42);
        return Container(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: on ? HaroTokens.ink : HaroTokens.transparent,
                width: 1.5,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: HaroText.mono(color: fg, tracking: .16)),
              if (count != null) ...[
                const SizedBox(width: 10),
                Text(
                  '$count',
                  style: HaroText.mono(
                    size: 10.5,
                    color: fg.withValues(alpha: .7),
                    tracking: 0,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}
