import 'package:flutter/painting.dart';

import 'tokens.dart';

/// Pubspec family for a Settings "Coding font" option. Unknown names (an older prefs file)
/// fall back to Space Mono so code never renders in the UI font.
String codingFontFamily(String option) => switch (option) {
  'JetBrains Mono' => 'JetBrainsMono',
  'Fira Code' => 'FiraCode',
  'IBM Plex Mono' => 'IBMPlexMono',
  _ => HaroTokens.fontMono,
};

/// Platform monospace faces tried when a glyph is missing from the chosen family.
const codingFontFallback = [
  HaroTokens.fontMono,
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'DejaVu Sans Mono',
  'monospace',
];

/// Code, terminal and inline code only. Labels, data and kbd stay on [HaroTokens.fontMono].
TextStyle codingTextStyle(
  String option, {
  double? fontSize,
  double? height,
  Color? color,
}) => TextStyle(
  fontFamily: codingFontFamily(option),
  fontFamilyFallback: codingFontFallback,
  fontSize: fontSize,
  height: height,
  color: color,
);
