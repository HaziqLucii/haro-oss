import 'dart:ui';

import 'package:flutter/animation.dart' show Curve, Curves;

import 'palette.dart';

/// Every colour, size and duration in the app. Widgets never hard-code a hex value.
abstract final class HaroTokens {
  static HaroPalette _palette = HaroPalette.haro;

  static HaroPalette get palette => _palette;

  /// Switches the theme every token below reads from. The caller rebuilds the widget tree.
  static void apply(HaroPalette p) => _palette = p;

  static Color get ink => _palette.ink;
  static Color get bg => _palette.bg;
  static const Color transparent = Color(0x00000000);
  static Color get panel => _palette.panel;
  static Color get raised => _palette.raised;

  static Color get ink86 => _palette.ink86;
  static Color get ink66 => _palette.ink66;
  static Color get ink42 => _palette.ink42;
  static Color get ink02 => _palette.ink02;

  static Color get line08 => _palette.line08;
  static Color get line12 => _palette.line12;
  static Color get line14 => _palette.line14;
  static Color get line20 => _palette.line20;
  static Color get line30 => _palette.line30;

  /// What you can press, and what is switched on: bone in the warm-monochrome themes, the
  /// primary colour in Material 3. [onAccent] is the colour on top of it.
  static Color get accent => _palette.accent;
  static Color get onAccent => _palette.onAccent;
  static Color get accentHover => _palette.accent.withValues(alpha: .86);

  /// Gate only: verdict, test cells, diff adds, "line ran". Never buttons, focus or meters.
  static Color get gate => _palette.gate;
  static Color get fail => _palette.fail;
  static Color get merged => _palette.merged;

  /// An advisory notice that wants your attention and is not a failure (the review limit). Amber,
  /// so it neither reads as the gate's green nor as a red failure.
  static Color get warn => _palette.warn;

  static Color get diffAddBg => _palette.diffAddBg;

  /// First run: the faint row wash behind a passed gate-evidence check.
  static Color get gateWash => _palette.gateWash;
  static Color get diffDelBg => _palette.diffDelBg;
  static Color get backdrop => _palette.backdrop;

  /// Corners, from the theme: small controls and inputs, buttons and chips, cards and menus,
  /// dialogs, checkboxes.
  static double get radius => _palette.radius;
  static double get buttonRadius => _palette.buttonRadius;
  static double get panelRadius => _palette.panelRadius;
  static double get dialogRadius => _palette.dialogRadius;
  static double get checkRadius => _palette.checkRadius;

  /// The corner of a selected segment inside a framed control with [buttonRadius] corners.
  static double get innerRadius => _palette.buttonRadius > 100
      ? 999
      : (_palette.buttonRadius - 1).clamp(1, 99).toDouble();

  /// Edge of the status square (`StatusSquare`) at each place it is bigger than the default.
  static const double markGateHero = 18;
  static const double markAgentRow = 10;
  static const double markAgentLoader = 16;
  static const double markSidebarRow = 9;
  static const double markSidebarStrip = 10;
  static const double markVerdict = 13;
  static const double markPanelTab = 9;
  static const double markTriageRow = 10;

  /// Gap between a bigger marker and its text, scaled up with the marker.
  static const double markGateHeroGap = 12;
  static const double markSidebarGap = 11;
  static const double markTriageGap = 10;

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
  static const double avatarSize = 26;
  static const double avatarSizeSmall = 18;
  static const double accountMenuWidth = 300;
  static const double backdropBlur = 3;
  static const double grainOpacity = .07;
  static const Size minWindow = Size(960, 640);

  static const Duration fadeFast = Duration(milliseconds: 180);
  static const Duration fade = Duration(milliseconds: 240);
  static const Duration fadeSlow = Duration(milliseconds: 300);
  static const Curve curve = Curves.easeOut;

  /// Loading placeholders (`HaroSkeleton`): one full pulse, the two ink opacities it swings
  /// between, and how long a block stays invisible so a fast answer never flashes one.
  static const Duration skeletonPulse = Duration(milliseconds: 1400);
  static const double skeletonOpacityLow = .06;
  static const double skeletonOpacityHigh = .10;
  static const Duration skeletonDelay = Duration(milliseconds: 150);

  /// A hairline that draws itself (the boot rule) takes this long.
  static const Duration draw = Duration(milliseconds: 600);

  /// Ship step: the PR and merge buttons share one width so their skeletons match them
  /// exactly, and the gate receipt card is reserved at about its real height while it loads.
  static const double shipButtonWidth = 176;
  static const double shipReceiptSkeletonHeight = 250;

  /// How long a finished result stays on screen before the flow moves on by itself.
  static const Duration beat = Duration(milliseconds: 1200);

  /// How often an open pull request is re-read on the ship step. A merge on github.com raises
  /// no local event, so this is the only way the step notices it while the app stays open.
  static const Duration prPollInterval = Duration(seconds: 30);

  static String get fontUi => _palette.fontUi;
  static String get fontMono => _palette.fontMono;
  static String get fontWordmark => _palette.fontWordmark;

  /// ANSI slots that have no brand colour, only for program output inside the terminal.
  static Color get ansiYellow => _palette.ansiYellow;
  static Color get ansiBlue => _palette.ansiBlue;
  static Color get ansiCyan => _palette.ansiCyan;
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
  static Color get keyword => HaroTokens.palette.syntaxKeyword;
  static Color get string => HaroTokens.palette.syntaxString;
  static Color get number => HaroTokens.palette.syntaxNumber;
  static Color get function => HaroTokens.palette.syntaxFunction;
  static Color get type => HaroTokens.palette.syntaxType;

  static List<Color> get all => [keyword, string, number, function, type];
}
