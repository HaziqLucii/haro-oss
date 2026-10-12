import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../settings_tokens.dart';

/// 34x18 square switch. Ink when on, never green (§0). The knob jumps, only colours fade.
class SettingToggle extends StatelessWidget {
  const SettingToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: HaroPressable(
        onTap: enabled ? () => onChanged!(!value) : null,
        builder: (context, hovered) {
          if (HaroTokens.palette.bigSwitch) return _bigSwitch(hovered, enabled);
          final track = value ? HaroTokens.accent : HaroTokens.transparent;
          final border = value
              ? HaroTokens.accent
              : (hovered ? HaroTokens.ink66 : HaroTokens.ink42);
          return Opacity(
            opacity: enabled ? 1 : .5,
            child: AnimatedContainer(
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              width: SettingsTokens.toggleWidth,
              height: SettingsTokens.toggleHeight,
              decoration: BoxDecoration(
                color: track,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Align(
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: AnimatedContainer(
                    duration: HaroTokens.fadeFast,
                    curve: HaroTokens.curve,
                    width: SettingsTokens.toggleKnob,
                    height: SettingsTokens.toggleKnob,
                    decoration: BoxDecoration(
                      color: value ? HaroTokens.onAccent : HaroTokens.ink42,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The Material 3 switch: a 52 by 32 pill, the thumb grows from 16 to 24 when it is on.
  Widget _bigSwitch(bool hovered, bool enabled) {
    final thumb = value
        ? SettingsTokens.bigThumbOn
        : SettingsTokens.bigThumbOff;
    return Opacity(
      opacity: enabled ? 1 : .5,
      child: AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        width: SettingsTokens.bigToggleWidth,
        height: SettingsTokens.bigToggleHeight,
        decoration: BoxDecoration(
          color: value ? HaroTokens.accent : HaroTokens.raised,
          border: Border.all(
            color: value
                ? HaroTokens.accent
                : (hovered ? HaroTokens.ink66 : HaroTokens.ink42),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(
            SettingsTokens.bigToggleHeight / 2,
          ),
        ),
        child: Align(
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: value ? 2 : 6),
            child: AnimatedContainer(
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              width: thumb,
              height: thumb,
              decoration: BoxDecoration(
                color: value ? HaroTokens.onAccent : HaroTokens.ink66,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
