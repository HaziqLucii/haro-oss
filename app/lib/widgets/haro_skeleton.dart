import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// A loading placeholder: a filled block of an exact size, so the real content lands in the
/// space it already holds and nothing around it moves. It pulses slowly in ink opacity and
/// stays invisible for [HaroTokens.skeletonDelay] first, so an answer that arrives at once
/// never shows one. Pass no [width] (or [height]) to fill what the parent gives.
///
/// Still under the OS reduce-motion setting, and tests turn [animate] off globally so the
/// repeating ticker never keeps `pumpAndSettle` waiting (it then shows at once, unpulsed).
class HaroSkeleton extends StatefulWidget {
  const HaroSkeleton({super.key, this.width, this.height});

  final double? width;
  final double? height;

  /// Off in the test binding (see `test/flutter_test_config.dart`).
  static bool animate = true;

  @override
  State<HaroSkeleton> createState() => _HaroSkeletonState();
}

class _HaroSkeletonState extends State<HaroSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: HaroTokens.skeletonPulse,
  );
  bool _moving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final want =
        HaroSkeleton.animate && !MediaQuery.disableAnimationsOf(context);
    if (want && !_moving) {
      _c.repeat(reverse: true);
    } else if (!want && _moving) {
      _c.stop();
    }
    _moving = want;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final block = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _moving ? _c.value : .5;
        final alpha =
            HaroTokens.skeletonOpacityLow +
            (HaroTokens.skeletonOpacityHigh - HaroTokens.skeletonOpacityLow) *
                t;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: HaroTokens.ink.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
        );
      },
    );
    final Widget shown;
    if (_moving) {
      final delay = HaroTokens.skeletonDelay;
      final total = delay + HaroTokens.fade;
      shown = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: total,
        builder: (context, v, child) {
          final start = delay.inMilliseconds / total.inMilliseconds;
          final o = v <= start ? 0.0 : (v - start) / (1 - start);
          return Opacity(opacity: HaroTokens.curve.transform(o), child: child);
        },
        child: block,
      );
    } else {
      shown = block;
    }
    return ExcludeSemantics(
      child: SizedBox(width: widget.width, height: widget.height, child: shown),
    );
  }
}
