import 'package:flutter/material.dart';

import '../../../theme/grain.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';

/// A small panel showing the film grain texture on or off per the draft value, drawn with
/// the same overlay the canvas uses.
class GrainPreview extends StatelessWidget {
  const GrainPreview({super.key, required this.on});

  final bool on;

  static const double height = 56;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('grain-preview'),
    width: double.infinity,
    height: height,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: HaroTokens.panel,
      border: Border.all(color: HaroTokens.line12),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Stack(
      children: [
        Positioned.fill(
          child: AnimatedOpacity(
            key: const ValueKey('grain-preview-texture'),
            opacity: on ? 1 : 0,
            duration: HaroTokens.fadeFast,
            curve: HaroTokens.curve,
            child: const GrainOverlay(),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                on ? 'Grain on: a fine texture over the canvas' : 'Grain off',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(size: 13, color: HaroTokens.ink66),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
