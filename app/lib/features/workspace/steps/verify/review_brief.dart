import 'dart:math' as math;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import 'review_order.dart';
import 'verify_widgets.dart';

/// The overview of the review step: what was asked, how far the agent was let go, and how much
/// there is to read. It is only facts haro already holds (the first prompt, the fence, the diff
/// size). It never says the change is fine or risky, and what the fence cannot see is said next
/// to what it can.
/// Where the reading pace comes from: a field study, named and bounded. Secondary summaries of
/// SmartBear's "Best Kept Secrets of Peer Code Review" (Cisco MeetingPlace, 2006-07): 2,500
/// reviews, 3.2 million lines, 50 developers; reviews under about 400 lines found the most defects
/// per line, and 87% of reviews faster than 450 lines an hour found fewer than average.
/// What the bar under the size line means, for its tooltip.
const reviewMeterHelp =
    'This bar shows how big the change is. Empty is nothing, full is 1,000 lines.\n\n'
    'The two little marks are 100 and 400 lines. Around 100 is easy to read in one go. '
    'Around 400 is where careful reading starts to get tiring, so past that the bar gets '
    'brighter.\n\n'
    "A long bar doesn't mean the code is bad. It just takes longer to read well, so take it "
    'file by file and give yourself breaks.';

const reviewStudyFact =
    'When Cisco studied 2,500 code reviews (SmartBear, 2006), reviews under 400 '
    'lines caught the most bugs. And in 87% of the reviews that went faster than about 450 '
    "lines an hour, people caught fewer bugs than average. That's one team's data from before "
    'AI wrote code, so treat it as a rule of thumb.';

class ReviewBrief extends StatelessWidget {
  const ReviewBrief({
    super.key,
    required this.size,
    this.intent,
    this.followUps = 0,
    this.scope,
    this.scopeLoading = false,
    this.agentSeen = false,
    this.newDependencies = const [],
  });

  final ReviewSize size;

  /// The first prompt, as typed. Null in a workspace with no agent.
  final String? intent;

  /// Prompts after the first.
  final int followUps;
  final ReceiptScope? scope;
  final bool scopeLoading;

  /// The transcript has agent events, so a fence line is expected even before it loads.
  final bool agentSeen;

  /// Manifest names added since the base, from the receipt. Empty when there are none.
  final List<ReceiptNewDependency> newDependencies;

  bool get _agentEdited => scope != null && scope!.editingRuns > 0;

  @override
  Widget build(BuildContext context) {
    final count =
        '${size.files} ${size.files == 1 ? 'file' : 'files'}'
        ' · ${size.lines} ${size.lines == 1 ? 'line' : 'lines'}';
    return Column(
      key: const ValueKey('review-brief'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZoneHeading(
          title: 'Overview',
          count: count,
          hint: 'what was asked, how far the agent could go, how much to read',
        ),
        const SizedBox(height: 6),
        if (intent != null && intent!.trim().isNotEmpty)
          _Row(
            label: 'INTENT',
            child: _Intent(text: intent!.trim(), followUps: followUps),
          ),
        if (_agentEdited)
          _Row(
            label: 'FENCE',
            child: _Fence(scope: scope!),
          )
        else if (scope == null && agentSeen)
          _Row(
            label: 'FENCE',
            child: Text(
              scopeLoading ? 'Loading…' : 'Unknown: the receipt did not load.',
              key: const ValueKey('brief-fence-unknown'),
              style: HaroText.ui(size: 14, color: HaroTokens.ink42),
            ),
          ),
        if (newDependencies.isNotEmpty)
          _Row(
            label: 'NEW DEPS',
            child: _NewDependencies(deps: newDependencies),
          ),
        _Row(
          label: 'SIZE',
          child: _Size(size: size, agentEdited: _agentEdited),
        ),
      ],
    );
  }
}

class _NewDependencies extends StatelessWidget {
  const _NewDependencies({required this.deps});

  final List<ReceiptNewDependency> deps;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final d in deps)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '${d.path}: ${d.names.join(', ')}',
            key: ValueKey('brief-deps-${d.path}'),
            style: HaroText.mono(
              size: 12,
              color: HaroTokens.ink86,
              tracking: 0,
              height: 1.5,
            ),
          ),
        ),
      Text(
        'Named in a manifest now, not at the base. No registry was checked, so this says nothing about the package.',
        key: const ValueKey('brief-deps-bound'),
        style: HaroText.ui(size: 12.5, color: HaroTokens.ink42),
      ),
    ],
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              label,
              style: HaroText.mono(
                size: 10.5,
                color: HaroTokens.ink42,
                tracking: .16,
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

class _Intent extends StatelessWidget {
  const _Intent({required this.text, required this.followUps});

  final String text;
  final int followUps;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        text,
        key: const ValueKey('brief-intent'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: HaroText.ui(size: 14, color: HaroTokens.ink86, height: 1.45),
      ),
      if (followUps > 0) ...[
        const SizedBox(height: 4),
        Text(
          '+$followUps ${followUps == 1 ? 'follow-up' : 'follow-ups'}',
          key: const ValueKey('brief-followups'),
          style: HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0),
        ),
      ],
    ],
  );
}

class _Fence extends StatelessWidget {
  const _Fence({required this.scope});

  final ReceiptScope scope;

  @override
  Widget build(BuildContext context) {
    final fenced = scope.patterns.isNotEmpty;
    final unfenced = scope.editingRuns - scope.fencedRuns;
    final facts = <String>[
      if (fenced)
        '${scope.fencedRuns} of ${scope.editingRuns} ${scope.editingRuns == 1 ? 'run' : 'runs'} fenced',
      if (scope.blocked.isNotEmpty)
        '${scope.blocked.length} ${scope.blocked.length == 1 ? 'edit' : 'edits'} refused before the write',
      if (scope.reverted.isNotEmpty)
        '${scope.reverted.length} reverted after the run',
      if (scope.uncheckedRuns > 0)
        'could not check ${scope.uncheckedRuns} ${scope.uncheckedRuns == 1 ? 'run' : 'runs'}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fenced && unfenced > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Only part of this work was fenced: $unfenced '
              '${unfenced == 1 ? 'run' : 'runs'} had no fence.',
              key: const ValueKey('brief-fence-partial'),
              style: HaroText.ui(size: 14, color: HaroTokens.ink86),
            ),
          ),
        if (fenced)
          Text(
            scope.patterns.join('  ·  '),
            key: const ValueKey('brief-fence-paths'),
            style: HaroText.mono(
              size: 12,
              color: HaroTokens.ink86,
              tracking: 0,
              height: 1.5,
            ),
          )
        else
          Text(
            'Not fenced: the agent could change any file.',
            key: const ValueKey('brief-fence-none'),
            style: HaroText.ui(size: 14, color: HaroTokens.ink86),
          ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            facts.join(' · '),
            key: const ValueKey('brief-fence-facts'),
            style: HaroText.mono(
              size: 11,
              color: HaroTokens.ink66,
              tracking: 0,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'The fence covers files. Commands and network are not restricted.',
          key: const ValueKey('brief-fence-bound'),
          style: HaroText.ui(size: 12.5, color: HaroTokens.ink42),
        ),
      ],
    );
  }
}

class _Size extends StatelessWidget {
  const _Size({required this.size, required this.agentEdited});

  final ReviewSize size;

  /// The fence advice only means something when an agent did the editing.
  final bool agentEdited;

  @override
  Widget build(BuildContext context) {
    final skipped = size.skipped == 0
        ? ''
        : ' · ${size.skipped} ${size.skipped == 1 ? 'file' : 'files'} not counted (generated, lock, binary or renamed)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${size.lines} changed ${size.lines == 1 ? 'line' : 'lines'} in '
          '${size.files} ${size.files == 1 ? 'file' : 'files'}$skipped',
          key: const ValueKey('brief-size'),
          style: HaroText.ui(size: 14, color: HaroTokens.ink86),
        ),
        const SizedBox(height: 2),
        Tooltip(
          key: const ValueKey('brief-meter-tip'),
          message: reviewMeterHelp,
          constraints: const BoxConstraints(maxWidth: 340),
          waitDuration: const Duration(milliseconds: 250),
          child: MouseRegion(
            cursor: SystemMouseCursors.help,
            // A taller hit area than the 6 px bar, so it is easy to land on.
            child: Container(
              height: 18,
              color: const Color(0x00000000),
              alignment: Alignment.center,
              child: _Meter(lines: size.lines),
            ),
          ),
        ),
        Text(
          size.lines == 0
              ? 'Nothing to read.'
              : 'About ${readTime(size.minutes)} if you read 400 lines an hour.',
          key: const ValueKey('brief-size-time'),
          style: HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0),
        ),
        if (size.lines > 0) ...[const SizedBox(height: 14), const _FunFact()],
        if (size.over && agentEdited) ...[
          const SizedBox(height: 6),
          Text(
            'Past about ${ReviewSize.strained} lines or ${ReviewSize.manyFiles} files, reviewers '
            'find fewer problems. Next time, fence the run to fewer files.',
            key: const ValueKey('brief-size-nudge'),
            style: HaroText.ui(
              size: 12.5,
              color: HaroTokens.ink66,
              height: 1.45,
            ),
          ),
        ],
      ],
    );
  }
}

/// The study behind the pace, in a dashed hairline box with a FUN FACT tag sitting on its top
/// edge, so it reads as an aside and not as something to act on.
class _FunFact extends StatelessWidget {
  const _FunFact();

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      CustomPaint(
        painter: const _DashedBox(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
          child: Text(
            reviewStudyFact,
            key: const ValueKey('brief-size-fact'),
            style: HaroText.ui(
              size: 12.5,
              color: HaroTokens.ink66,
              height: 1.5,
            ),
          ),
        ),
      ),
      Positioned(
        left: 12,
        top: -7,
        child: Container(
          color: HaroTokens.bg,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            'FUN FACT',
            key: const ValueKey('brief-size-fact-tag'),
            style: HaroText.mono(
              size: 10,
              color: HaroTokens.ink66,
              tracking: .16,
            ),
          ),
        ),
      ),
    ],
  );
}

class _DashedBox extends CustomPainter {
  const _DashedBox();

  static const double _dash = 5;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = HaroTokens.line30
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(HaroTokens.radius),
        ),
      );
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + _dash, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => false;
}

/// A hairline scale to 1,000 lines with ticks at 100 and 400. Ink fills it; there is no colour,
/// because a long diff is a reason to slow down, not a failure.
class _Meter extends StatelessWidget {
  const _Meter({required this.lines});

  final int lines;

  @override
  Widget build(BuildContext context) {
    final fill = (lines / ReviewSize.excessive).clamp(0.0, 1.0);
    return SizedBox(
      key: const ValueKey('brief-meter'),
      height: 6,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          Widget tick(int at) => Positioned(
            left: w * at / ReviewSize.excessive,
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: HaroTokens.line30),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: HaroTokens.line14),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 1,
                bottom: 1,
                width: w * fill,
                child: Container(
                  color: lines > ReviewSize.strained
                      ? HaroTokens.ink
                      : HaroTokens.ink42,
                ),
              ),
              tick(ReviewSize.comfortable),
              tick(ReviewSize.strained),
            ],
          );
        },
      ),
    );
  }
}
