import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../settings_tokens.dart';

/// Hairline trigger that opens a small haro-styled list (not Material's DropdownButton).
/// [options] are (value, label) pairs; a [value] missing from them shows as its raw text so a
/// setting the client does not know still reads back.
class SettingSelect<T> extends StatefulWidget {
  const SettingSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.minWidth = SettingsTokens.selectMinWidth,
    this.fallbackLabel,
    this.child,
  });

  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final double minWidth;

  /// Shown when [value] is not in [options].
  final String? fallbackLabel;

  /// Replaces the default trigger box (used by the nav's project switcher).
  final Widget Function(BuildContext context, String label, bool hovered)?
  child;

  @override
  State<SettingSelect<T>> createState() => _SettingSelectState<T>();
}

class _SettingSelectState<T> extends State<SettingSelect<T>> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;

  String get _label {
    for (final o in widget.options) {
      if (o.$1 == widget.value) return o.$2;
    }
    return widget.fallbackLabel ?? '${widget.value ?? ''}';
  }

  void _open() {
    if (_entry != null || widget.options.isEmpty) return;
    final box = context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    final menuHeight = math.min(
      SettingsTokens.menuMaxHeight,
      widget.options.length * _Menu.itemHeight + 8,
    );
    final below = screen.height - (origin.dy + box.size.height) - 12;
    final above = origin.dy - 12;
    final up = below < menuHeight && above > below;
    final maxHeight = math.min(menuHeight, math.max(up ? above : below, 80.0));
    _entry = OverlayEntry(
      builder: (_) => _Menu<T>(
        link: _link,
        minWidth: math.max(widget.minWidth, box.size.width),
        maxHeight: maxHeight,
        up: up,
        options: widget.options,
        value: widget.value,
        onPick: (v) {
          _close();
          widget.onChanged?.call(v);
        },
        onClose: _close,
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return CompositedTransformTarget(
      link: _link,
      child: Semantics(
        button: true,
        enabled: enabled,
        value: _label,
        child: HaroPressable(
          onTap: enabled ? (_entry == null ? _open : _close) : null,
          builder: (context, hovered) {
            if (widget.child != null) {
              return widget.child!(context, _label, hovered);
            }
            return Opacity(
              opacity: enabled ? 1 : .5,
              child: AnimatedContainer(
                duration: HaroTokens.fadeFast,
                curve: HaroTokens.curve,
                constraints: BoxConstraints(minWidth: widget.minWidth),
                height: SettingsTokens.fieldHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: hovered || _entry != null
                        ? HaroTokens.line30
                        : HaroTokens.line20,
                  ),
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        _label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.ui(size: 13.5),
                      ),
                    ),
                    const SizedBox(width: 16),
                    const SettingChevron(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Menu<T> extends StatefulWidget {
  const _Menu({
    required this.link,
    required this.minWidth,
    required this.maxHeight,
    required this.up,
    required this.options,
    required this.value,
    required this.onPick,
    required this.onClose,
  });

  static const double itemHeight = 30;

  final LayerLink link;
  final double minWidth;
  final double maxHeight;
  final bool up;
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T> onPick;
  final VoidCallback onClose;

  @override
  State<_Menu<T>> createState() => _MenuState<T>();
}

class _MenuState<T> extends State<_Menu<T>> {
  late int _hi = math.max(
    0,
    widget.options.indexWhere((o) => o.$1 == widget.value),
  );
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = _hi * _Menu.itemHeight;
    final view = _scroll.position.viewportDimension;
    final offset = _scroll.offset;
    if (top < offset) {
      _scroll.jumpTo(top);
    } else if (top + _Menu.itemHeight > offset + view) {
      _scroll.jumpTo(top + _Menu.itemHeight - view);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final step = k == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(
        () => _hi = (_hi + step).clamp(0, widget.options.length - 1).toInt(),
      );
      _reveal();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      widget.onPick(widget.options[_hi].$1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    autofocus: true,
    child: Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onClose,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: widget.link,
            showWhenUnlinked: false,
            targetAnchor: widget.up ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor: widget.up
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(0, widget.up ? -4 : 4),
            child: Align(
              alignment: widget.up ? Alignment.bottomLeft : Alignment.topLeft,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: widget.minWidth,
                  constraints: BoxConstraints(maxHeight: widget.maxHeight),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: HaroTokens.raised,
                    border: Border.all(color: HaroTokens.line20),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemExtent: _Menu.itemHeight,
                    itemCount: widget.options.length,
                    itemBuilder: (context, i) {
                      final o = widget.options[i];
                      final selected = o.$1 == widget.value;
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _hi = i),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => widget.onPick(o.$1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.centerLeft,
                            color: i == _hi
                                ? HaroTokens.line08
                                : HaroTokens.transparent,
                            child: Text(
                              o.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HaroText.ui(
                                size: 13.5,
                                weight: selected
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                color: selected
                                    ? HaroTokens.ink
                                    : HaroTokens.ink66,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The small down triangle. Drawn rather than typed so it never depends on a fallback font.
class SettingChevron extends StatelessWidget {
  const SettingChevron({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 8,
    height: 5,
    child: CustomPaint(painter: _Chevron()),
  );
}

class _Chevron extends CustomPainter {
  const _Chevron();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close(),
    Paint()..color = HaroTokens.ink42,
  );

  @override
  bool shouldRepaint(_Chevron old) => false;
}
