import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// Single-purpose text input: hairline border that brightens to line30 on focus (never green,
/// never a Material underline). `mono` gives the Space Mono data look, otherwise Space Grotesk.
///
/// `bordered: false` draws nothing so the caller can supply its own rule (the palette input
/// sits on a bottom hairline). Wraps its own transparent [Material], so it works in overlays.
class HaroTextField extends StatefulWidget {
  const HaroTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.mono = false,
    this.bordered = true,
    this.autofocus = false,
    this.obscureText = false,
    this.enabled = true,
    this.height = HaroTokens.controlHeight,
    this.fontSize,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool mono;
  final bool bordered;
  final bool autofocus;
  final bool obscureText;
  final bool enabled;
  final double height;

  /// Defaults to 13 (mono) or 14 (UI).
  final double? fontSize;
  final EdgeInsetsGeometry padding;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<HaroTextField> createState() => _HaroTextFieldState();
}

class _HaroTextFieldState extends State<HaroTextField> {
  FocusNode? _ownNode;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(HaroTextField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownNode)?.removeListener(_onFocus);
      _node.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _ownNode?.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focused != _node.hasFocus) setState(() => _focused = _node.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.fontSize ?? (widget.mono ? 13 : 14);
    final style = widget.mono
        ? HaroText.mono(size: size, color: HaroTokens.ink, tracking: 0)
        : HaroText.ui(size: size);
    final hint = style.copyWith(color: HaroTokens.ink42);
    return Material(
      type: MaterialType.transparency,
      child: AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: widget.height,
        padding: widget.padding,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HaroTokens.radius),
          border: widget.bordered
              ? Border.all(
                  color: _focused ? HaroTokens.line30 : HaroTokens.line14,
                )
              : null,
        ),
        child: TextField(
          controller: widget.controller,
          focusNode: _node,
          autofocus: widget.autofocus,
          obscureText: widget.obscureText,
          enabled: widget.enabled,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          style: style,
          cursorColor: HaroTokens.ink,
          cursorWidth: 1,
          decoration: InputDecoration.collapsed(
            hintText: widget.hintText,
            hintStyle: hint,
          ),
        ),
      ),
    );
  }
}
