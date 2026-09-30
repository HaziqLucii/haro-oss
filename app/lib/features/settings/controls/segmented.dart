import 'package:flutter/material.dart';

import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../settings_tokens.dart';

/// Hairline box with one filled (bone) option.
class SettingSegmented<T> extends StatelessWidget {
  const SettingSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.disabled = const {},
  });

  /// Options that show dimmed and ignore taps.
  final Set<T> disabled;

  /// (value, label) pairs.
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onChanged == null ? .5 : 1,
    child: Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line20),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            _Option(
              label: options[i].$2,
              selected: options[i].$1 == value,
              dimmed: disabled.contains(options[i].$1),
              onTap: onChanged == null || disabled.contains(options[i].$1)
                  ? null
                  : () => onChanged!(options[i].$1),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dimmed = false,
  });

  final bool dimmed;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: HaroPressable(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, hovered) => AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: SettingsTokens.segHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? HaroTokens.ink : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(1),
        ),
        child: Opacity(
          opacity: dimmed ? .4 : 1,
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: HaroText.ui(
              size: 12.5,
              color: selected
                  ? HaroTokens.bg
                  : (hovered ? HaroTokens.ink : HaroTokens.ink66),
            ),
          ),
        ),
      ),
    ),
  );
}
