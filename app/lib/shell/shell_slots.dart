import 'package:flutter/material.dart';

import '../state/format.dart' show plural;
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_pressable.dart';
import 'shell_models.dart';

/// The foot of the expanded sidebar: level, rank, XP bar, 14-day streak, the latest reward and
/// a "?" that opens "How XP works". Draws nothing when [xp] is null (XP off, or not loaded).
/// The bar is bone ink: green is the gate's colour and this is not the gate.
class SidebarFooterSlot extends StatelessWidget {
  const SidebarFooterSlot({super.key, this.xp, this.onHelp});

  final XpFooterData? xp;
  final VoidCallback? onHelp;

  @override
  Widget build(BuildContext context) {
    final x = xp;
    if (x == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('xp-footer'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              LevelBox(level: x.level, key: const ValueKey('xp-level')),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      x.rank,
                      key: const ValueKey('xp-rank'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.ui(size: 13),
                    ),
                    Text(
                      x.xpText,
                      key: const ValueKey('xp-text'),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.mono(
                        size: 10,
                        color: HaroTokens.ink42,
                        tracking: 0,
                      ),
                    ),
                  ],
                ),
              ),
              _HelpButton(onTap: onHelp),
            ],
          ),
          const SizedBox(height: 10),
          _Bar(progress: x.progress),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _Streak(ticks: x.streak)),
              const SizedBox(width: 8),
              Text(
                '${x.streakDays}d',
                key: const ValueKey('xp-streak-days'),
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink,
                  tracking: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Latest(amount: x.latestAmount, label: x.latestLabel),
        ],
      ),
    );
  }
}

/// The level number in a hairline box, shared by the footer and the strip badge.
class LevelBox extends StatelessWidget {
  const LevelBox({super.key, required this.level, this.size = 28});

  final int level;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: HaroTokens.line30),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Text(
      '$level',
      maxLines: 1,
      softWrap: false,
      style: HaroText.mono(
        size: level > 99 ? 9.5 : 12,
        weight: FontWeight.w700,
        color: HaroTokens.ink,
        tracking: 0,
      ),
    ),
  );
}

class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: 'How XP works',
    semanticLabel: 'How XP works',
    builder: (_, hovered) => AnimatedContainer(
      key: const ValueKey('xp-help'),
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line20),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: AnimatedDefaultTextStyle(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        style: HaroText.mono(
          size: 10.5,
          tracking: 0,
          color: hovered ? HaroTokens.ink : HaroTokens.ink66,
        ),
        child: const Text('?'),
      ),
    ),
  );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('xp-bar'),
    height: HaroTokens.xpBarHeight,
    color: HaroTokens.line12,
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: progress.clamp(0.0, 1.0),
      child: Container(
        key: const ValueKey('xp-bar-fill'),
        color: HaroTokens.ink,
      ),
    ),
  );
}

/// Fourteen ticks, oldest first, today last. A day with a by-hand merge is filled; today's
/// tick is hollow until it has one.
class _Streak extends StatelessWidget {
  const _Streak({required this.ticks});

  final List<bool> ticks;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('xp-streak'),
    children: [
      for (final (i, done) in ticks.indexed) ...[
        if (i > 0) const SizedBox(width: 2),
        Expanded(
          child: Container(
            key: ValueKey('xp-tick-$i'),
            height: HaroTokens.xpTickHeight,
            decoration: BoxDecoration(
              color: done
                  ? (i == ticks.length - 1 ? HaroTokens.ink : HaroTokens.ink66)
                  : i == ticks.length - 1
                  ? HaroTokens.transparent
                  : HaroTokens.line12,
              border: !done && i == ticks.length - 1
                  ? Border.all(color: HaroTokens.line20)
                  : null,
            ),
          ),
        ),
      ],
    ],
  );
}

class _Latest extends StatelessWidget {
  const _Latest({required this.amount, required this.label});

  final int? amount;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(
      size: 10.5,
      tracking: 0,
      height: 1.5,
      color: HaroTokens.ink66,
    );
    if (label == null) {
      return Text(
        'Nothing earned yet',
        key: const ValueKey('xp-latest'),
        style: style,
      );
    }
    final a = amount ?? 0;
    return Text.rich(
      key: const ValueKey('xp-latest'),
      TextSpan(
        style: style,
        children: [
          if (a > 0)
            TextSpan(
              text: '+$a XP ',
              style: style.copyWith(color: HaroTokens.ink),
            ),
          TextSpan(text: label),
        ],
      ),
    );
  }
}

/// The level badge in the collapsed sidebar strip, between the workspace squares and the
/// new-workspace button. Tapping it opens "How XP works". Draws nothing when [xp] is null.
class StripBadgeSlot extends StatelessWidget {
  const StripBadgeSlot({super.key, this.xp, this.onTap});

  final XpFooterData? xp;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final x = xp;
    if (x == null) return const SizedBox.shrink();
    return HaroPressable(
      onTap: onTap,
      tooltip:
          '${x.tooltip} · ${x.streakDays} ${plural(x.streakDays, 'day')} streak',
      semanticLabel: 'Level ${x.level}',
      builder: (_, hovered) => AnimatedOpacity(
        key: const ValueKey('xp-strip-badge'),
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        opacity: hovered ? 1 : .8,
        child: LevelBox(level: x.level),
      ),
    );
  }
}
