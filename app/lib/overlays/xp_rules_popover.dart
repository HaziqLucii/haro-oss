import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models/models.dart';
import '../state/format.dart' show groupThousands;
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// "How XP works": the award table rendered from `GET /xp/rules`, so a number changed on the
/// backend changes here without a client release. A popover over the sidebar's foot with a
/// clear barrier: a click anywhere else, or Esc, closes it.
Future<void> showHowXpWorks(
  BuildContext context, {
  required Future<XpRules> Function() loadRules,
  XpStatus? status,
  double left = 12,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: HaroTokens.transparent,
  transitionDuration: HaroTokens.fadeFast,
  pageBuilder: (context, _, _) =>
      _PopoverFrame(loadRules: loadRules, status: status, left: left),
  transitionBuilder: (context, animation, _, page) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: HaroTokens.curve),
    child: page,
  ),
);

/// The value column for one rule: what each mode earns.
String xpRuleValue(XpRule r) {
  if (r.group == 'badge') return 'badge';
  final m = r.manual;
  final a = r.agent;
  if (m != null && a != null) return '+$m by hand · +$a agent';
  if (m != null) return '+$m by hand';
  if (a != null) return '+$a agent';
  return '';
}

/// `560 XP to Craftsman`, or null at the top rank.
String? xpToNextText(XpStatus? s, XpRules rules) {
  final next = s?.nextRankAt;
  if (s == null || next == null) return null;
  final name = rules.ranks.where((r) => r.at == next).firstOrNull?.name;
  return '${groupThousands(next - s.xp)} XP to ${name ?? 'the next rank'}';
}

const _groups = [
  ('daily', 'Every day', 'once a day each'),
  ('merge', 'On merge', 'once per workspace'),
  ('manual', 'Manual bonuses', 'by hand only'),
  ('badge', 'Badges', 'once ever'),
];

class _PopoverFrame extends StatelessWidget {
  const _PopoverFrame({
    required this.loadRules,
    required this.status,
    required this.left,
  });

  final Future<XpRules> Function() loadRules;
  final XpStatus? status;
  final double left;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context, rootNavigator: true).maybePop(),
        },
        child: Stack(
          children: [
            Positioned(
              left: left,
              bottom: HaroTokens.statusBarHeight + 12,
              width: math.min(HaroTokens.xpPopoverWidth, size.width - left - 8),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  key: const ValueKey('xp-popover'),
                  constraints: BoxConstraints(maxHeight: size.height - 96),
                  decoration: BoxDecoration(
                    color: HaroTokens.panel,
                    border: Border.all(color: HaroTokens.line30),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: FutureBuilder<XpRules>(
                    future: loadRules(),
                    builder: (context, snap) => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                      child: _Body(
                        rules: snap.data,
                        failed: snap.hasError,
                        status: status,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.rules,
    required this.failed,
    required this.status,
  });

  final XpRules? rules;
  final bool failed;
  final XpStatus? status;

  @override
  Widget build(BuildContext context) {
    final r = rules;
    final toNext = r == null ? null : xpToNextText(status, r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                'How XP works',
                style: HaroText.ui(size: 16, weight: FontWeight.w500),
              ),
            ),
            if (toNext != null)
              Text(
                toNext,
                key: const ValueKey('xp-to-next'),
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
          ],
        ),
        if (r == null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              failed ? 'The award table did not load' : 'Loading',
              key: const ValueKey('xp-rules-status'),
              style: HaroText.ui(size: 13, color: HaroTokens.ink42),
            ),
          )
        else ...[
          for (final (group, title, tag) in _groups)
            if (r.inGroup(group).isNotEmpty)
              _Group(title: title, tag: tag, rules: r.inGroup(group)),
          const SizedBox(height: 14),
          Text(
            'Ranks: ${[for (final k in r.ranks) '${k.name} ${groupThousands(k.at)}'].join(' · ')}. A level is every ${r.levelXp} XP.',
            key: const ValueKey('xp-ranks'),
            style: HaroText.ui(size: 12, color: HaroTokens.ink42, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            'Streak: a day counts when you merge on green a workspace you wrote by hand the whole way. Daily activity never extends it, only a green merge by hand does.',
            style: HaroText.ui(size: 12, color: HaroTokens.ink42, height: 1.5),
          ),
        ],
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.tag, required this.rules});

  final String title;
  final String tag;
  final List<XpRule> rules;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: HaroText.mono(size: 10, color: HaroTokens.ink66),
              ),
            ),
            Text(
              tag.toUpperCase(),
              style: HaroText.mono(size: 10, color: HaroTokens.ink42),
            ),
          ],
        ),
        for (final rule in rules)
          Container(
            key: ValueKey('xp-rule-${rule.kind}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: HaroTokens.line08)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    rule.cap == null
                        ? rule.text
                        : '${rule.text} (up to ${rule.cap})',
                    style: HaroText.ui(size: 13, color: HaroTokens.ink86),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    xpRuleValue(rule),
                    softWrap: false,
                    style: HaroText.mono(
                      size: 11,
                      color: HaroTokens.ink,
                      tracking: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
