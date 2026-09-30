import 'package:flutter/material.dart';

/// Hover + tap without Material ink. Every clickable in the app is built on this so there is
/// one place that decides cursor and semantics.
class HaroPressable extends StatefulWidget {
  const HaroPressable({
    super.key,
    required this.builder,
    required this.onTap,
    this.tooltip,
    this.semanticLabel,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final String? tooltip;
  final String? semanticLabel;

  @override
  State<HaroPressable> createState() => _HaroPressableState();
}

class _HaroPressableState extends State<HaroPressable> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget result = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(context, _hovered && enabled),
      ),
    );
    result = Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: result,
    );
    if (widget.tooltip != null) {
      result = Tooltip(message: widget.tooltip!, child: result);
    }
    return result;
  }
}
