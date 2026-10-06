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
  static const double runningDither = 12;
  static const double verbWidth = 44;

  static const double composerButtonHeight = 30;
  static const double composerChipHeight = 28;
  static const double menuMaxHeight = 220;
  static const double menuWidth = 360;

  /// Distance from the bottom that still counts as "following the stream".
  static const double followSlack = 48;

  static TextStyle label({Color color = HaroTokens.ink42}) =>
      HaroText.mono(size: 10.5, color: color, tracking: .14);

  static TextStyle prose = HaroText.ui(
    size: 15,
    color: HaroTokens.ink86,
    height: 1.6,
  );

  static TextStyle userText = HaroText.ui(size: 15, height: 1.55);

  static TextStyle tool({Color color = HaroTokens.ink66}) =>
      HaroText.mono(size: 12.5, color: color, tracking: 0);

  static TextStyle footer = HaroText.mono(
    size: 11,
    color: HaroTokens.ink42,
    tracking: 0,
  );

  static TextStyle composerMono({Color color = HaroTokens.ink}) =>
      HaroText.mono(size: 13, color: color, tracking: 0, height: 1.6);

  static TextStyle chip({Color color = HaroTokens.ink86}) =>
      HaroText.mono(size: 11.5, color: color, tracking: 0);

  static TextStyle hint = HaroText.mono(
    size: 11,
    color: HaroTokens.ink42,
    tracking: 0,
  );
}
