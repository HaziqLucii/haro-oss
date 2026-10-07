import 'package:flutter/material.dart';

import 'tokens.dart';

@immutable
class HaroColors extends ThemeExtension<HaroColors> {
  const HaroColors();

  Color get ink => HaroTokens.ink;
  Color get ink86 => HaroTokens.ink86;
  Color get ink66 => HaroTokens.ink66;
  Color get ink42 => HaroTokens.ink42;
  Color get line08 => HaroTokens.line08;
  Color get line12 => HaroTokens.line12;
  Color get line14 => HaroTokens.line14;
  Color get line20 => HaroTokens.line20;
  Color get line30 => HaroTokens.line30;
  Color get bg => HaroTokens.bg;
  Color get panel => HaroTokens.panel;
  Color get raised => HaroTokens.raised;
  Color get gate => HaroTokens.gate;
  Color get fail => HaroTokens.fail;
  Color get merged => HaroTokens.merged;

  @override
  HaroColors copyWith() => this;

  @override
  HaroColors lerp(HaroColors? other, double t) => this;
}

extension HaroThemeX on BuildContext {
  HaroColors get haro => Theme.of(this).extension<HaroColors>()!;
}

abstract final class HaroText {
  static TextStyle ui({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color color = HaroTokens.ink,
    double? height,
  }) => TextStyle(
    fontFamily: HaroTokens.fontUi,
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
  );

  /// Space Mono label. Pass already-uppercased text; `tracking` is a multiple of font size.
  static TextStyle mono({
    double size = 11,
    FontWeight weight = FontWeight.w400,
    Color color = HaroTokens.ink66,
    double tracking = .14,
    double? height,
  }) => TextStyle(
    fontFamily: HaroTokens.fontMono,
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: size * tracking,
    height: height,
  );

  static const TextStyle wordmark = TextStyle(
    fontFamily: HaroTokens.fontWordmark,
    fontSize: 22,
    fontWeight: FontWeight.w500,
    color: HaroTokens.ink,
  );
}

class _FadePageTransitions extends PageTransitionsBuilder {
  const _FadePageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: HaroTokens.curve),
    child: child,
  );
}

ThemeData buildHaroTheme() {
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(HaroTokens.radius)),
  );
  const fade = _FadePageTransitions();
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: HaroTokens.fontUi,
  );
  return base.copyWith(
    scaffoldBackgroundColor: HaroTokens.bg,
    canvasColor: HaroTokens.bg,
    colorScheme: const ColorScheme.dark(
      primary: HaroTokens.ink,
      onPrimary: HaroTokens.bg,
      secondary: HaroTokens.ink66,
      surface: HaroTokens.panel,
      onSurface: HaroTokens.ink,
      error: HaroTokens.fail,
      outline: HaroTokens.line20,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: HaroTokens.fontUi,
      bodyColor: HaroTokens.ink,
      displayColor: HaroTokens.ink,
    ),
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    dividerColor: HaroTokens.line12,
    dividerTheme: const DividerThemeData(
      color: HaroTokens.line12,
      thickness: 1,
      space: 1,
    ),
    cardTheme: const CardThemeData(elevation: 0, shape: shape),
    dialogTheme: const DialogThemeData(
      elevation: 0,
      shape: shape,
      backgroundColor: HaroTokens.panel,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      elevation: 0,
      shape: shape,
      color: HaroTokens.raised,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: HaroTokens.raised,
        borderRadius: BorderRadius.all(Radius.circular(HaroTokens.radius)),
      ),
      textStyle: TextStyle(
        fontFamily: HaroTokens.fontMono,
        fontSize: 11,
        color: HaroTokens.ink86,
      ),
      waitDuration: Duration(milliseconds: 400),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: HaroTokens.ink,
      selectionColor: HaroTokens.line30,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(HaroTokens.line20),
      radius: const Radius.circular(HaroTokens.radius),
      thickness: WidgetStateProperty.all(6),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.macOS: fade,
        TargetPlatform.linux: fade,
        TargetPlatform.windows: fade,
      },
    ),
    extensions: const [HaroColors()],
  );
}
