import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart';

/// Fades its child in on first build. Give it a fresh key to replay.
class FadeIn extends StatelessWidget {
  const FadeIn({super.key, required this.child, this.duration});

  final Widget child;
  final Duration? duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: duration ?? HaroTokens.fade,
    curve: HaroTokens.curve,
    builder: (context, t, child) => Opacity(opacity: t, child: child),
    child: child,
  );
}
