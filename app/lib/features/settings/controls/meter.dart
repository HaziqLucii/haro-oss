import 'package:flutter/material.dart';

import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../settings_tokens.dart';

/// 4px track with an ink fill and a mono percentage. Never green, never coloured by
/// severity (§0): a meter is not a gate verdict.
class SettingMeter extends StatelessWidget {
  const SettingMeter({super.key, required this.percent});

  final double percent;

  @override
  Widget build(BuildContext context) {
    final pct = percent.clamp(0, 100).toDouble();
    return SizedBox(
      width: SettingsTokens.meterWidth,
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 4,
              alignment: Alignment.centerLeft,
              color: HaroTokens.line12,
              child: FractionallySizedBox(
                widthFactor: pct / 100,
                child: Container(height: 4, color: HaroTokens.ink),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 40,
            child: Text(
              '${pct.round()}%',
              textAlign: TextAlign.right,
              style: HaroText.mono(
                size: 12,
                color: HaroTokens.ink,
                tracking: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only mono value (`row.isValue`).
class SettingValue extends StatelessWidget {
  const SettingValue(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 340),
    child: Text(
      text,
      textAlign: TextAlign.right,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: HaroText.mono(size: 12.5, color: HaroTokens.ink86, tracking: 0),
    ),
  );
}
