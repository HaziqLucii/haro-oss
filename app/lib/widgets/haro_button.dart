import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import 'haro_pressable.dart';
import 'haro_tag.dart';
import 'kbd.dart';
import 'shell_icons.dart';

enum HaroButtonVariant {
  primary,
  secondary,
  tertiary,
  destructive,
  control,
  tonal,
}

/// Primary: bone fill + dark text. Secondary: 1px hairline. Tertiary: text only (§0).
/// Control: the same bone fill for the window's chrome (the header, the top bar): what can be
/// pressed is the bright thing. It is never "the primary action" of a screen.
/// Tonal: the theme's accent as a tint with accent text (bone in Classic, the primary colour in
/// Expressive and Paper): a coloured action that is not the screen's one solid primary, like the
/// composer's Run agent, Queue and Stop.
/// Destructive: a secondary with a red border and red text, for irreversible actions.
/// Hover only changes colour (fade), never size, so layouts don't jump.
class HaroButton extends StatelessWidget {
  const HaroButton({
    super.key,
    this.label,
    this.child,
    required this.onPressed,
    this.variant = HaroButtonVariant.secondary,
    this.kbd,
    this.height = 32,
    this.width,
    this.fontSize = 13,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.foreground,
    this.textStyle,
    this.spread = false,
    this.tooltip,
    this.trailing,
    this.leading,
    this.count,
  }) : assert(label != null || child != null);

  final String? label;

  /// Replaces the label row. Text inside inherits the button's colour and size.
  final Widget? child;
  final VoidCallback? onPressed;
  final HaroButtonVariant variant;

  /// Plain (unbordered) shortcut hint shown at the trailing edge.
  final String? kbd;
  final double height;
  final double? width;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  /// Resting text colour for secondary and tertiary. Hover always goes to full ink.
  final Color? foreground;
  final TextStyle? textStyle;

  /// Fill the available width and push the trailing hint to the far edge.
  final bool spread;
  final String? tooltip;

  /// A Lucide icon after the label, in the label's colour: `Open` + [ShellIcon.openExternal]
  /// instead of a `↗` glyph.
  final ShellIcon? trailing;

  /// A Lucide icon before the label, in the label's colour: what makes a small action read as a
  /// button at a glance (`New note` + [ShellIcon.plus]).
  final ShellIcon? leading;

  /// A number shown as a small tag after the label (`Sort inbox` and `4`).
  final int? count;

  @override
  Widget build(BuildContext context) => HaroPressable(
    rippleOnAccent:
        variant == HaroButtonVariant.primary ||
        variant == HaroButtonVariant.control,
    onTap: onPressed,
    tooltip: tooltip,
    semanticLabel: label,
    builder: (context, hovered) {
      final primary =
          variant == HaroButtonVariant.primary ||
          variant == HaroButtonVariant.control;
      final secondary = variant == HaroButtonVariant.secondary;
      final destructive = variant == HaroButtonVariant.destructive;
      final tonal = variant == HaroButtonVariant.tonal;
      final Color fg = primary
          ? HaroTokens.onAccent
          : destructive
          ? HaroTokens.fail
          : tonal
          ? HaroTokens.accent
          : hovered
          ? HaroTokens.ink
          : (foreground ?? HaroTokens.ink66);
      final base =
          textStyle ??
          HaroText.ui(
            size: fontSize,
            weight: primary ? FontWeight.w500 : FontWeight.w400,
          );
      final content =
          child ??
          Row(
            mainAxisSize: spread ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      ShellIconView(leading!, size: fontSize + 2, color: fg),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        label!,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(width: 8),
                      HaroTag('$count'),
                    ],
                    if (trailing != null) ...[
                      const SizedBox(width: 6),
                      ShellIconView(trailing!, size: fontSize + 1, color: fg),
                    ],
                  ],
                ),
              ),
              if (kbd != null) ...[
                const SizedBox(width: 12),
                Kbd(kbd!, bordered: false, color: fg),
              ],
            ],
          );
      return AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: height,
        width: width,
        padding: padding,
        // A button is as wide as its content, also under a Wrap or an Align (whose loose
        // constraints would otherwise let an aligned Container fill the whole line). Only a
        // spread or fixed-width button fills.
        alignment: spread || width != null ? Alignment.centerLeft : null,
        decoration: BoxDecoration(
          color: primary
              ? (hovered ? HaroTokens.accentHover : HaroTokens.accent)
              : tonal
              ? HaroTokens.accent.withValues(alpha: hovered ? .24 : .14)
              : destructive && hovered
              ? HaroTokens.diffDelBg
              : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.buttonRadius),
          border: secondary
              ? Border.all(
                  color: hovered ? HaroTokens.line30 : HaroTokens.line14,
                )
              : destructive
              ? Border.all(color: HaroTokens.fail)
              : null,
        ),
        child: AnimatedDefaultTextStyle(
          duration: HaroTokens.fadeFast,
          curve: HaroTokens.curve,
          style: base.copyWith(color: fg),
          child: spread || width != null
              ? content
              : Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1,
                  child: content,
                ),
        ),
      );
    },
  );
}
