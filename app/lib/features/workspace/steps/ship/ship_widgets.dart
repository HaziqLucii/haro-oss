import 'package:flutter/widgets.dart';

import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_skeleton.dart';

/// `GATE RECEIPT   What reviewers see on the PR      [actions]` over a hairline (spec 5.7).
class ShipSectionHead extends StatelessWidget {
  const ShipSectionHead({
    super.key,
    required this.title,
    this.sub,
    this.actions = const [],
    this.loadingSub = false,
  });

  final String title;
  final String? sub;
  final List<Widget> actions;

  /// A skeleton where [sub] will be, while the text it is made from is still loading.
  final bool loadingSub;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(bottom: 10),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line20)),
    ),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              title.toUpperCase(),
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.ink,
                tracking: .16,
              ),
            ),
            if (loadingSub) ...[
              const SizedBox(width: 14),
              SkeletonLine(
                style: HaroText.ui(size: 13, color: HaroTokens.ink42),
                width: 190,
              ),
            ] else if (sub != null) ...[
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  sub!,
                  style: HaroText.ui(size: 13, color: HaroTokens.ink42),
                ),
              ),
            ],
          ],
        ),
        if (actions.isNotEmpty)
          Row(mainAxisSize: MainAxisSize.min, children: actions),
      ],
    ),
  );
}

/// A skeleton bar as tall as one line of [style], so the text that replaces it keeps the row's
/// height. The bar is inset a little so stacked lines read as separate.
class SkeletonLine extends StatelessWidget {
  const SkeletonLine({
    super.key,
    required this.style,
    this.width,
    this.inset = 3,
  });

  final TextStyle style;
  final double? width;
  final double inset;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width ?? double.infinity,
    child: Stack(
      children: [
        Opacity(opacity: 0, child: Text('M', maxLines: 1, style: style)),
        Positioned(
          left: 0,
          right: 0,
          top: inset,
          bottom: inset,
          child: const HaroSkeleton(),
        ),
      ],
    ),
  );
}

/// Cross-fades between a skeleton and what replaces it. The children share a footprint, so
/// the swap changes ink only.
class ShipFade extends StatelessWidget {
  const ShipFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: HaroTokens.fade,
    switchInCurve: HaroTokens.curve,
    switchOutCurve: HaroTokens.curve,
    layoutBuilder: (current, previous) =>
        Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
    child: child,
  );
}
