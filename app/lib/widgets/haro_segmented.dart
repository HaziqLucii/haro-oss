import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import 'haro_pressable.dart';

class HaroSegment<T> {
  const HaroSegment(this.value, this.label, {this.tooltip});

  final T value;
  final String label;
  final String? tooltip;
}

/// A two-or-more way switch in a hairline frame (Finalized UI: WHO WRITES THE CODE, Who
/// writes it). The selected segment is bone ink with dark text; the rest sit at 66% ink.
class HaroSegmented<T> extends StatelessWidget {
  const HaroSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.mono = true,
    this.height = 24,
    this.horizontalPadding = 10,
    this.frame = HaroTokens.line30,
    this.keyPrefix = 'segment',
  });

  final List<HaroSegment<T>> segments;
  final T selected;

  /// Null disables every segment.
  final ValueChanged<T>? onChanged;

  /// Space Mono at 10.5 with tracking (top bar) instead of Space Grotesk at 13 (form rows).
  final bool mono;
  final double height;
  final double horizontalPadding;
  final Color frame;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: frame),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, s) in segments.indexed) ...[
            if (i > 0) const SizedBox(width: 2),
            _Segment<T>(
              key: ValueKey('$keyPrefix-${s.label.toLowerCase()}'),
              segment: s,
              active: s.value == selected,
              mono: mono,
              height: height,
              horizontalPadding: horizontalPadding,
              onTap: onChanged == null ? null : () => onChanged!(s.value),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    super.key,
    required this.segment,
    required this.active,
    required this.mono,
    required this.height,
    required this.horizontalPadding,
    required this.onTap,
  });

  final HaroSegment<T> segment;
  final bool active;
  final bool mono;
  final double height;
  final double horizontalPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: segment.tooltip,
    semanticLabel: segment.label,
    builder: (context, hovered) {
      final color = active
          ? HaroTokens.bg
          : hovered
          ? HaroTokens.ink
          : HaroTokens.ink66;
      return AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: height,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? HaroTokens.ink : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(1),
        ),
        child: Text(
          segment.label,
          maxLines: 1,
          softWrap: false,
          style: mono
              ? HaroText.mono(size: 10.5, tracking: .1, color: color)
              : HaroText.ui(size: 13, color: color),
        ),
      );
    },
  );
}
