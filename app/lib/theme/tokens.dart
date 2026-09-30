import 'dart:ui';

import 'package:flutter/animation.dart' show Curve, Curves;

/// Every colour, size and duration in the app. Widgets never hard-code a hex value.
abstract final class HaroTokens {
  static const Color ink = Color(0xFFD8D0C5);
  static const Color bg = Color(0xFF0B0A09);
  static const Color transparent = Color(0x00000000);
  static const Color panel = Color(0xFF131210);
  static const Color raised = Color(0xFF1B1915);

  static const Color ink86 = Color.fromRGBO(216, 208, 197, .86);
  static const Color ink66 = Color.fromRGBO(216, 208, 197, .66);
  static const Color ink42 = Color.fromRGBO(216, 208, 197, .42);
  static const Color ink02 = Color.fromRGBO(216, 208, 197, .02);

  static const Color line08 = Color.fromRGBO(216, 208, 197, .08);
  static const Color line12 = Color.fromRGBO(216, 208, 197, .12);
  static const Color line14 = Color.fromRGBO(216, 208, 197, .14);
  static const Color line20 = Color.fromRGBO(216, 208, 197, .2);
  static const Color line30 = Color.fromRGBO(216, 208, 197, .3);

  /// Gate only: verdict, test cells, diff adds, "line ran". Never buttons, focus or meters.
  static const Color gate = Color(0xFF41D183);
  static const Color fail = Color(0xFFE0685E);
  static const Color merged = Color(0xFFB3A0D6);

  static const Color diffAddBg = Color.fromRGBO(65, 209, 131, .06);
  static const Color diffDelBg = Color.fromRGBO(224, 104, 94, .07);
  static const Color backdrop = Color.fromRGBO(8, 7, 6, .8);

  static const double radius = 2;
  static const double topBarHeight = 48;
  static const double focusBarHeight = 34;
  static const double statusBarHeight = 24;
  static const double sidebarWidth = 220;
  static const double sidebarStripWidth = 52;
  static const double railWidth = 290;
  static const double railStripWidth = 44;
  static const double controlHeight = 30;
  static const double terminalHeight = 240;
  static const double xpBarHeight = 3;
  static const double xpTickHeight = 12;
  static const double xpPopoverWidth = 380;
  static const double backdropBlur = 3;
  static const double grainOpacity = .07;
  static const Size minWindow = Size(960, 640);

  static const Duration fadeFast = Duration(milliseconds: 180);
  static const Duration fade = Duration(milliseconds: 240);
  static const Duration fadeSlow = Duration(milliseconds: 300);
  static const Curve curve = Curves.easeOut;

  static const String fontUi = 'SpaceGrotesk';
  static const String fontMono = 'SpaceMono';
  static const String fontWordmark = 'Fraunces';

  /// ANSI slots that have no brand colour, only for program output inside the terminal.
  static const Color ansiYellow = Color(0xFFC9A96A);
  static const Color ansiBlue = Color(0xFF7F9BB8);
  static const Color ansiCyan = Color(0xFF7FB3AE);
}

/// Row sizes that follow Settings, Display, Density. `comfortable` is the shipped look.
class DensityScale {
  const DensityScale({
    required this.sidebarRow,
    required this.triageRowMin,
    required this.triageRowPadY,
    required this.fileRow,
    required this.lookAtPadY,
  });

  static const comfortable = DensityScale(
    sidebarRow: 30,
    triageRowMin: 62,
    triageRowPadY: 10,
    fileRow: 28,
    lookAtPadY: 16,
  );

  static const compact = DensityScale(
    sidebarRow: 26,
    triageRowMin: 48,
    triageRowPadY: 6,
    fileRow: 24,
    lookAtPadY: 9,
  );

  final double sidebarRow;
  final double triageRowMin;
  final double triageRowPadY;
  final double fileRow;
  final double lookAtPadY;

  static DensityScale of(String density) =>
      density == 'compact' ? compact : comfortable;
}

/// Code syntax colours, the one scoped exception to the warm-monochrome brand (Display, Syntax
/// colours). Warm and muted, and never green, red or lilac: those hues stay reserved for the
/// gate, failures and merged, so diff tints and "line ran" markers remain the only green/red
/// in a code view.
abstract final class SyntaxColors {
  static const Color keyword = Color(0xFFD6A15E);
  static const Color string = Color(0xFF8FAFC8);
  static const Color number = Color(0xFFCFC08A);
  static const Color function = Color(0xFFB8C7D9);
  static const Color type = Color(0xFFD9B98C);

  static const all = [keyword, string, number, function, type];
}
