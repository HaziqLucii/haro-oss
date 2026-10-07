import 'package:flutter/painting.dart';

import '../../theme/tokens.dart';

/// Sizes and shared styles for the settings surface (§6.1). Colours come from [HaroTokens].
abstract final class SettingsTokens {
  static const double overlayWidth = 980;
  static const double overlayHeight = 660;
  static const double navWidth = 220;
  static const double navItemHeight = 30;
  static const double fieldHeight = 32;

  static const double toggleWidth = 34;
  static const double toggleHeight = 18;
  static const double toggleKnob = 12;

  static const double segHeight = 26;
  static const double selectMinWidth = 180;
  static const double inputWidth = 260;
  static const double meterWidth = 260;
  static const double menuMaxHeight = 280;

  /// Below this pane width a row stacks its control under the label instead of beside it.
  static const double stackBelow = 560;

  static const EdgeInsets paneHeaderPadding = EdgeInsets.fromLTRB(
    32,
    26,
    32,
    18,
  );
  static const EdgeInsets paneBodyPadding = EdgeInsets.fromLTRB(32, 4, 32, 24);
  static const EdgeInsets barPadding = EdgeInsets.symmetric(
    horizontal: 32,
    vertical: 12,
  );

  static const Color disabledInk = HaroTokens.ink42;
}
