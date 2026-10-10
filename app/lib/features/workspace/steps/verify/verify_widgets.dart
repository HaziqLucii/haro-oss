import 'package:flutter/widgets.dart';

import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import 'verify_model.dart';

Color toneColor(MetricTone t) => switch (t) {
  MetricTone.ink => HaroTokens.ink,
  MetricTone.dim => HaroTokens.ink42,
  MetricTone.gate => HaroTokens.gate,
  MetricTone.fail => HaroTokens.fail,
};

/// Below this the step runs in the cramped main column (900px window with both side
/// panels open), where side-by-side layouts stack.
const double narrowWidth = 560;

/// Zone heading: mono caps title, a count, a one-line hint, hairline under it.
class ZoneHeading extends StatelessWidget {
  const ZoneHeading({
    super.key,
    required this.title,
    this.count,
    required this.hint,
  });

  final String title;
  final String? count;
  final String hint;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(bottom: 10),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line20)),
    ),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 14,
      runSpacing: 4,
      children: [
        Text(
          title.toUpperCase(),
          style: HaroText.mono(size: 11, color: HaroTokens.ink, tracking: .16),
        ),
        if (count != null)
          Text(
            count!,
            style: HaroText.mono(
              size: 11,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        Text(hint, style: HaroText.ui(size: 13, color: HaroTokens.ink42)),
      ],
    ),
  );
}

/// A small mono error line, for a request that failed.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Text(
    message,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    style: HaroText.mono(size: 11, color: HaroTokens.fail, tracking: 0),
  );
}

/// Sizes a button to its label. `HaroButton` fills whatever width it is given, which is
/// everything in a wrapping row.
class Fit extends StatelessWidget {
  const Fit({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(child: child);
}
