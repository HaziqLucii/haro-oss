import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import 'haro_pressable.dart';
import 'kbd.dart';

enum HaroButtonVariant { primary, secondary, tertiary, destructive }

/// Primary: bone fill + dark text. Secondary: 1px hairline. Tertiary: text only (§0).
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

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onPressed,
    tooltip: tooltip,
    semanticLabel: label,
    builder: (context, hovered) {
      final primary = variant == HaroButtonVariant.primary;
      final secondary = variant == HaroButtonVariant.secondary;
      final destructive = variant == HaroButtonVariant.destructive;
      final Color fg = primary
          ? HaroTokens.bg
          : destructive
          ? HaroTokens.fail
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
                child: Text(
                  label!,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
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
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: primary
              ? (hovered ? HaroTokens.ink86 : HaroTokens.ink)
              : destructive && hovered
              ? HaroTokens.diffDelBg
              : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.radius),
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
          child: content,
        ),
      );
    },
  );
}
