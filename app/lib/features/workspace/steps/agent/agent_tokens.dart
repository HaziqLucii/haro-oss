import 'package:flutter/widgets.dart';

import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';

/// Sizes and text styles of the agent step and composer. Colours come from [HaroTokens].
abstract final class AgentTokens {
  static const double columnMax = 760;
  static const double gap = 20;
  static const double toolGap = 8;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(32, 28, 32, 32);

  static const double toolSquare = 5;
  static const double runningLoader = 16;
  static const double verbWidth = 44;

  static const double composerButtonHeight = 30;
  static const double composerChipHeight = 28;
  static const double menuMaxHeight = 220;
  static const double menuWidth = 360;

  /// Distance from the bottom that still counts as "following the stream".
  static const double followSlack = 48;

  static TextStyle label({Color? color}) => HaroText.mono(
    size: 10.5,
    color: color ?? HaroTokens.ink42,
    tracking: .14,
  );

  // Getters, not fields: a field would read the ink colour once and keep it when the theme
  // changes, leaving dark-theme grey text on Paper's white.
  static TextStyle get prose =>
      HaroText.text(size: 15, color: HaroTokens.ink86, height: 1.6);

  static TextStyle get userText => HaroText.text(size: 15, height: 1.55);

  static TextStyle tool({Color? color}) =>
      HaroText.mono(size: 12.5, color: color ?? HaroTokens.ink66, tracking: 0);

  static TextStyle get footer =>
      HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);

  static TextStyle composerMono({Color? color}) => HaroText.mono(
    size: 13,
    color: color ?? HaroTokens.ink,
    tracking: 0,
    height: 1.6,
  );

  static TextStyle chip({Color? color}) =>
      HaroText.mono(size: 11.5, color: color ?? HaroTokens.ink86, tracking: 0);

  static TextStyle get hint =>
      HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
}
