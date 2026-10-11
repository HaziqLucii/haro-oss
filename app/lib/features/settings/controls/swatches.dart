import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';

/// A row of colour dots for a choice of colours: (id, label, colour). The chosen one wears a
/// ring in the ink colour; each has a tooltip with its name.
class SettingSwatches extends StatelessWidget {
  const SettingSwatches({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(String, String, Color)> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final (id, label, colour) in options)
        Semantics(
          button: true,
          selected: id == value,
          label: label,
          onTap: () => onChanged(id),
          child: ExcludeSemantics(
            child: HaroPressable(
              key: ValueKey('swatch-$id'),
              rippleOnAccent: true,
              onTap: () => onChanged(id),
              tooltip: label,
              semanticLabel: label,
              builder: (_, hovered) => Container(
                width: 30,
                height: 30,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: id == value
                        ? HaroTokens.ink
                        : (hovered
                              ? HaroTokens.line30
                              : HaroTokens.transparent),
                    width: 2,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colour,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
