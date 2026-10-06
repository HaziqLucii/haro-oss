import 'dart:async';

import 'package:haro_app/widgets/dither_square.dart';
import 'package:haro_app/widgets/haro_skeleton.dart';

/// Runs before every test file. The running-line marker shimmers on a repeating ticker, which
/// would keep `pumpAndSettle` waiting forever, so tests see its still frame. Skeletons pulse
/// the same way and also show at once instead of after their anti-flash delay.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  DitherSquare.animate = false;
  HaroSkeleton.animate = false;
  await testMain();
}
