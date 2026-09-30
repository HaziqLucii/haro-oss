import 'package:flutter/widgets.dart';

import '../state/display_state.dart';
import '../theme/tokens.dart';

/// The status glyph (§0): filled = settled, hollow ink = in progress, hollow dim = idle.
class StatusSquare extends StatelessWidget {
  const StatusSquare({
    super.key,
    this.size = 7,
    required this.color,
    required this.filled,
  });

  StatusSquare.forState(DisplayState state, {super.key, this.size = 7})
    : color = state.color,
      filled = state.settled;

  final double size;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: filled ? color : HaroTokens.transparent,
        border: Border.all(color: color),
      ),
    ),
  );
}
