import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// Display prefs for the widget tree. It sits above the navigator so overlays see it too, and
/// without one (a widget pumped alone in a test) everything reads as the shipped look.
class DisplayScope extends InheritedWidget {
  const DisplayScope({
    super.key,
    required this.codingFont,
    required this.density,
    this.syntaxColour = true,
    required super.child,
  });

  /// A Settings option name such as `JetBrains Mono`; map it with `codingFontFamily`.
  final String codingFont;
  final DensityScale density;
  final bool syntaxColour;

  static const defaultCodingFont = 'Space Mono';

  static DisplayScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DisplayScope>();

  static String codingFontOf(BuildContext context) =>
      maybeOf(context)?.codingFont ?? defaultCodingFont;

  static bool syntaxColourOf(BuildContext context) =>
      maybeOf(context)?.syntaxColour ?? true;

  static DensityScale densityOf(BuildContext context) =>
      maybeOf(context)?.density ?? DensityScale.comfortable;

  @override
  bool updateShouldNotify(DisplayScope old) =>
      codingFont != old.codingFont ||
      density != old.density ||
      syntaxColour != old.syntaxColour;
}
