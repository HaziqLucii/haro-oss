import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../../theme/coding_font.dart';
import '../../../theme/tokens.dart';

/// Brand terminal: bone ink on near-black, muted ANSI. Green and red follow the gate colours
/// because they are program output there (a test runner's pass and fail), never chrome.
const haroTerminalTheme = TerminalTheme(
  cursor: HaroTokens.ink,
  selection: HaroTokens.line30,
  foreground: HaroTokens.ink,
  background: HaroTokens.bg,
  black: HaroTokens.raised,
  red: HaroTokens.fail,
  green: HaroTokens.gate,
  yellow: HaroTokens.ansiYellow,
  blue: HaroTokens.ansiBlue,
  magenta: HaroTokens.merged,
  cyan: HaroTokens.ansiCyan,
  white: HaroTokens.ink66,
  brightBlack: HaroTokens.ink42,
  brightRed: HaroTokens.fail,
  brightGreen: HaroTokens.gate,
  brightYellow: HaroTokens.ansiYellow,
  brightBlue: HaroTokens.ansiBlue,
  brightMagenta: HaroTokens.merged,
  brightCyan: HaroTokens.ansiCyan,
  brightWhite: HaroTokens.ink,
  searchHitBackground: HaroTokens.line30,
  searchHitBackgroundCurrent: HaroTokens.line30,
  searchHitForeground: HaroTokens.ink,
);

final _styles = <String, TerminalStyle>{};

/// Cached per font: xterm compares styles by identity, so a fresh instance on every build
/// would re-measure and repaint the whole grid.
TerminalStyle haroTerminalStyleFor(String codingFont) => _styles.putIfAbsent(
  codingFont,
  () => TerminalStyle(
    fontSize: 12.5,
    height: 1.4,
    fontFamily: codingFontFamily(codingFont),
    fontFamilyFallback: codingFontFallback,
  ),
);

const haroTerminalPadding = EdgeInsets.fromLTRB(16, 8, 16, 8);
