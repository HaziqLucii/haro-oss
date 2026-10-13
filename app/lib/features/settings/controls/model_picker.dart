import 'package:flutter/material.dart';

import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/shell_icons.dart';
import 'mono_input.dart';
import 'select.dart';

/// A model chosen from the list the coding agent can run, so a typo cannot happen (a wrong name only fails
/// when a run starts). With no list (loading, its program missing or the server down) it falls back to a text
/// field and says why, so a model can still be typed. The refresh button reads the list again, for
/// after a provider was set up or the server started.
class SettingModelPicker extends StatelessWidget {
  const SettingModelPicker({
    super.key,
    required this.value,
    required this.models,
    required this.onChanged,
    required this.onRefresh,
    required this.defaultLabel,
    required this.hint,
    this.loading = false,
    this.error,
    this.selectKey,
  });

  final String value;
  final List<String> models;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;

  /// What the empty value means (`OpenCode's default`).
  final String defaultLabel;
  final String hint;
  final bool loading;
  final String? error;
  final Key? selectKey;

  @override
  Widget build(BuildContext context) {
    final canPick = models.isNotEmpty;
    final options = <(String, String)>[
      ('', defaultLabel),
      for (final m in models) (m, m),
      if (value.isNotEmpty && !models.contains(value))
        (value, '$value (not in the list)'),
    ];
    final note = loading
        ? 'Reading the models...'
        : error != null && error!.isNotEmpty
        ? error
        : canPick
        ? null
        : 'No models found. Type one.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canPick)
              SettingSelect<String>(
                key: selectKey,
                options: options,
                value: value,
                minWidth: 280,
                onChanged: onChanged,
              )
            else
              SettingInput(
                key: selectKey == null
                    ? null
                    : ValueKey('${(selectKey! as ValueKey).value}-input'),
                width: 320,
                value: value,
                hint: hint,
                onChanged: onChanged,
              ),
            const SizedBox(width: 8),
            ShellIconButton(
              key: selectKey == null
                  ? null
                  : ValueKey('${(selectKey! as ValueKey).value}-refresh'),
              icon: ShellIcon.reload,
              tooltip: 'Read the models again',
              bordered: true,
              width: 30,
              onTap: loading ? null : onRefresh,
            ),
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                note,
                textAlign: TextAlign.end,
                style: HaroText.mono(
                  size: 10.5,
                  tracking: 0,
                  color: HaroTokens.ink42,
                  height: 1.4,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
