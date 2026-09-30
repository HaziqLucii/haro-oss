import 'package:flutter/material.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../overlays/overlay.dart';

/// Extra sizes shared by the three creation overlays. Colours always come from [HaroTokens].
abstract final class CreationMetrics {
  static const double closeSize = 28;
  static const double rowGap = 14;
}

/// The square hairline close button used in every overlay header.
class OverlayCloseButton extends StatelessWidget {
  const OverlayCloseButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => HaroButton(
    width: CreationMetrics.closeSize,
    height: CreationMetrics.closeSize,
    padding: EdgeInsets.zero,
    label: 'Close',
    tooltip: 'Close (Esc)',
    onPressed: onPressed ?? () => closeHaroOverlay(context),
    child: const Center(child: Text('✕')),
  );
}

/// Uppercase mono caption.
class MonoCaption extends StatelessWidget {
  const MonoCaption(this.text, {super.key, this.color = HaroTokens.ink42});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: HaroText.mono(size: 10.5, tracking: .16, color: color),
  );
}

/// Inline failure line. Red is for failures (§0).
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: HaroText.ui(size: 13, color: HaroTokens.fail, height: 1.4),
  );
}

/// Drop-down for a short mono value (project, base branch). The popup is the themed
/// Material menu, so there is no ripple and no elevation.
class MenuSelect<T> extends StatelessWidget {
  const MenuSelect({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onSelected,
    this.enabled = true,
    this.style,
    this.upper = false,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final TextStyle? style;

  /// Show the current value in uppercase (caption use). The menu items keep their case.
  final bool upper;

  @override
  Widget build(BuildContext context) {
    final base =
        style ?? HaroText.mono(size: 13, color: HaroTokens.ink, tracking: 0);
    final canOpen = enabled && options.length > 1;
    return PopupMenuButton<T>(
      enabled: canOpen,
      tooltip: '',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 420),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final o in options)
          PopupMenuItem<T>(
            value: o,
            height: 32,
            child: Text(
              labelOf(o),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 12.5,
                tracking: 0,
                color: o == value ? HaroTokens.ink : HaroTokens.ink66,
              ),
            ),
          ),
      ],
      child: MouseRegion(
        cursor: canOpen ? SystemMouseCursors.click : MouseCursor.defer,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                upper ? labelOf(value).toUpperCase() : labelOf(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base,
              ),
            ),
            if (canOpen) ...[
              const SizedBox(width: 6),
              Text('▾', style: base.copyWith(color: HaroTokens.ink42)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Square check row: bone fill and a dark tick when on. Never green (§0).
class CheckRow extends StatelessWidget {
  const CheckRow({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.hint,
  });

  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;

  /// A dim mono note after the label (the XP a choice earns).
  final String? hint;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    semanticLabel: label,
    builder: (context, hovered) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: HaroTokens.fadeFast,
          curve: HaroTokens.curve,
          width: 16,
          height: 16,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: value ? HaroTokens.ink : HaroTokens.transparent,
            border: Border.all(
              color: hovered ? HaroTokens.ink66 : HaroTokens.ink42,
            ),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: value
              ? Text(
                  '✓',
                  style: HaroText.ui(
                    size: 11,
                    color: HaroTokens.bg,
                    weight: FontWeight.w600,
                    height: 1,
                  ),
                )
              : null,
        ),
        const SizedBox(width: 10),
        Flexible(child: Text(label, style: HaroText.ui())),
        if (hint != null) ...[
          const SizedBox(width: 10),
          Text(
            hint!,
            style: HaroText.mono(
              size: 10.5,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        ],
      ],
    ),
  );
}
