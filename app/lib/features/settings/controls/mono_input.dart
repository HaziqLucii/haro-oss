import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_text_field.dart';
import '../settings_tokens.dart';

/// Mono text input sitting on the darkest ground. [value] is pushed into the field only when
/// it differs from what is typed, so Discard resets the text without fighting the caret.
class SettingInput extends StatefulWidget {
  const SettingInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.width = SettingsTokens.inputWidth,
    this.enabled = true,
    this.keyboardType,
    this.inputFormatters,
  });

  final String value;
  final ValueChanged<String>? onChanged;
  final String? hint;
  final double width;
  final bool enabled;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<SettingInput> createState() => _SettingInputState();
}

class _SettingInputState extends State<SettingInput> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(SettingInput old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) _sync(widget.value);
  }

  void _sync(String text) => _c.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: widget.enabled ? 1 : .5,
    child: Container(
      width: widget.width,
      color: HaroTokens.bg,
      child: HaroTextField(
        controller: _c,
        mono: true,
        fontSize: 12.5,
        height: SettingsTokens.fieldHeight,
        hintText: widget.hint,
        enabled: widget.enabled && widget.onChanged != null,
        keyboardType: widget.keyboardType,
        inputFormatters: widget.inputFormatters,
        onChanged: widget.onChanged,
      ),
    ),
  );
}

/// Numeric variant: zero shows as an empty field with [hint] ("no limit"), and the text is
/// left alone while it still parses to the current value so "1." survives the round trip.
class SettingNumberInput extends StatefulWidget {
  const SettingNumberInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.decimals = false,
    this.width = 140,
    this.enabled = true,
  });

  final num value;
  final ValueChanged<double>? onChanged;
  final String? hint;
  final bool decimals;
  final double width;
  final bool enabled;

  @override
  State<SettingNumberInput> createState() => _SettingNumberInputState();
}

class _SettingNumberInputState extends State<SettingNumberInput> {
  late final TextEditingController _c = TextEditingController(
    text: _format(widget.value),
  );

  String _format(num v) {
    if (v == 0) return '';
    if (v == v.roundToDouble()) return v.round().toString();
    return v.toString();
  }

  double _parse(String s) => double.tryParse(s.trim()) ?? 0;

  @override
  void didUpdateWidget(SettingNumberInput old) {
    super.didUpdateWidget(old);
    if (_parse(_c.text) != widget.value.toDouble()) {
      final text = _format(widget.value);
      _c.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: widget.enabled ? 1 : .5,
    child: Container(
      width: widget.width,
      color: HaroTokens.bg,
      child: HaroTextField(
        controller: _c,
        mono: true,
        fontSize: 12.5,
        height: SettingsTokens.fieldHeight,
        hintText: widget.hint,
        enabled: widget.enabled && widget.onChanged != null,
        keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            widget.decimals ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
          ),
        ],
        onChanged: (s) => widget.onChanged?.call(_parse(s)),
      ),
    ),
  );
}

/// Multi-line mono editor on the darkest ground: .env, scripts, instructions.
class SettingCodeEditor extends StatefulWidget {
  const SettingCodeEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.minLines = 6,
    this.maxLines = 14,
  });

  final String value;
  final ValueChanged<String>? onChanged;
  final String? hint;
  final int minLines;
  final int maxLines;

  @override
  State<SettingCodeEditor> createState() => _SettingCodeEditorState();
}

class _SettingCodeEditorState extends State<SettingCodeEditor> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focused != _focus.hasFocus) {
        setState(() => _focused = _focus.hasFocus);
      }
    });
  }

  @override
  void didUpdateWidget(SettingCodeEditor old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) {
      _c.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(
      size: 12.5,
      color: HaroTokens.ink86,
      tracking: 0,
      height: 1.7,
    );
    return Material(
      type: MaterialType.transparency,
      child: AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: HaroTokens.bg,
          border: Border.all(
            color: _focused ? HaroTokens.line30 : HaroTokens.line14,
          ),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: TextField(
          controller: _c,
          focusNode: _focus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          enabled: widget.onChanged != null,
          onChanged: widget.onChanged,
          style: style,
          cursorColor: HaroTokens.ink,
          cursorWidth: 1,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration.collapsed(
            hintText: widget.hint,
            hintStyle: style.copyWith(color: HaroTokens.ink42),
          ),
        ),
      ),
    );
  }
}

/// Read-only code block, e.g. the generated TOML behind "View config".
class SettingCodeView extends StatelessWidget {
  const SettingCodeView(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: HaroTokens.bg,
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: SelectableText(
      text,
      style: HaroText.mono(
        size: 12.5,
        color: HaroTokens.ink86,
        tracking: 0,
        height: 1.7,
      ),
    ),
  );
}
