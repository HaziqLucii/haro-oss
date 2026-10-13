import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// A small outlined label for a count or a short status (`4`, `1 of 6 done`, `open`), beside a title
/// instead of glued onto it with punctuation. Colours and corner come from the theme.
class HaroTag extends StatelessWidget {
  const HaroTag(this.text, {super.key, this.color, this.height = 18});

  final String text;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(
      color: HaroTokens.ink02,
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.radius + 1),
    ),
    // As wide as its text, and no wider: a long tag shrinks (with an ellipsis) when it is in a
    // Flexible, rather than filling the line or overflowing it.
    child: Align(
      alignment: Alignment.center,
      widthFactor: 1,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: HaroText.mono(
          size: 10.5,
          tracking: 0,
          color: color ?? HaroTokens.ink66,
          height: 1,
        ),
      ),
    ),
  );
}
