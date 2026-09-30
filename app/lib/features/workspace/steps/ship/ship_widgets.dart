import 'package:flutter/widgets.dart';

import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';

/// `GATE RECEIPT   What reviewers see on the PR      [actions]` over a hairline (spec 5.7).
class ShipSectionHead extends StatelessWidget {
  const ShipSectionHead({
    super.key,
    required this.title,
    this.sub,
    this.actions = const [],
  });

  final String title;
  final String? sub;
  final List<Widget> actions;

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
            if (sub != null) ...[
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
