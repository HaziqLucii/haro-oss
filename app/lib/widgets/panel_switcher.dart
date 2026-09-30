import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// A side panel that swaps between fixed-width variants (open, strip, hidden) by fading.
/// Nothing slides: the frame takes the new width at once, and the outgoing variant fades out
/// at its own width, clipped, instead of being squeezed while it goes.
class PanelSwitcher extends StatelessWidget {
  const PanelSwitcher({
    super.key,
    required this.variant,
    required this.width,
    required this.alignment,
    required this.child,
  });

  /// Names the variant showing; a new value starts the cross-fade.
  final Object variant;
  final double width;

  /// The edge the panel hugs: its outgoing variant stays pinned to it.
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: AnimatedSwitcher(
      duration: HaroTokens.fade,
      switchInCurve: HaroTokens.curve,
      switchOutCurve: HaroTokens.curve,
      layoutBuilder: (current, previous) =>
          Stack(alignment: alignment, children: [...previous, ?current]),
      child: KeyedSubtree(
        key: ValueKey(variant),
        child: OverflowBox(
          minWidth: width,
          maxWidth: width,
          alignment: alignment,
          child: child,
        ),
      ),
    ),
  );
}
