import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/tokens.dart';

/// Hover + tap without Material ink. Every clickable in the app is built on this so there is
/// one place that decides cursor and semantics. Under a theme with [HaroPalette.ripple]
/// (Material 3) a press also starts a ripple from the pointer. The ripple is clipped to the
/// shape of the control's own background (the first full-size decorated box under it), so a
/// square row ripples square and a pill ripples pill, on that same layer. A control with no
/// background of its own (a logo, a text tab) ripples in a rounded box a little larger than
/// it, so the ripple has room around the text.
class HaroPressable extends StatefulWidget {
  const HaroPressable({
    super.key,
    required this.builder,
    required this.onTap,
    this.tooltip,
    this.semanticLabel,
    this.rippleOnAccent = false,
    this.rippleOutset = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.rippleRadius = 12,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final String? tooltip;
  final String? semanticLabel;

  /// The control is filled with the accent colour, so its ripple is the colour on it.
  final bool rippleOnAccent;

  /// How far past a background-less control the ripple reaches, and the corner of that box.
  /// Not used when the control draws its own background.
  final EdgeInsets rippleOutset;
  final double rippleRadius;

  @override
  State<HaroPressable> createState() => _HaroPressableState();
}

const double _rowWidth = 160;

/// The pointers a pressable has already taken for its ripple. A press inside a nested pressable
/// (a checkbox or a menu button in a row) reaches the inner one first and then the row around it;
/// only the inner one ripples, so the row does not flash under the control that was pressed.
final _taken = <int>{};

bool _takePointer(int pointer) {
  if (!_taken.add(pointer)) return false;
  scheduleMicrotask(() => _taken.remove(pointer));
  return true;
}

/// A decoration that is a surface (a fill, rounded corners, a circle), not just a hairline
/// under a tab or between rows.
bool _drawsShape(Decoration d) {
  if (d is BoxDecoration) {
    return (d.color != null && d.color!.a > .01) ||
        d.gradient != null ||
        d.borderRadius != null ||
        d.shape == BoxShape.circle;
  }
  return true;
}

class _Ripple {
  _Ripple(this.origin, this.controller, this.clip);

  final Offset origin;
  final AnimationController controller;
  final Path clip;
}

class _HaroPressableState extends State<HaroPressable>
    with TickerProviderStateMixin {
  bool _hovered = false;
  final _ripples = <_Ripple>[];

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  /// The ripple's clip in this widget's own coordinates.
  Path _clipPath() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Path();
    final size = box.size;
    RenderDecoratedBox? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderDecoratedBox &&
          o.position == DecorationPosition.background &&
          o.hasSize &&
          _drawsShape(o.decoration) &&
          o.size.width >= size.width * .9 &&
          o.size.height >= size.height * .9) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    box.visitChildren(visit);
    final bg = found;
    if (bg != null) {
      final rect = bg.localToGlobal(Offset.zero, ancestor: box) & bg.size;
      return bg.decoration.getClipPath(rect, TextDirection.ltr);
    }
    // A wide target is a row: it fills its line, and a ripple reaching past it would run into
    // the rows above and below.
    final o = size.width >= _rowWidth ? EdgeInsets.zero : widget.rippleOutset;
    return Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          -o.left,
          -o.top,
          size.width + o.right,
          size.height + o.bottom,
        ),
        Radius.circular(widget.rippleRadius),
      ),
    );
  }

  void _startRipple(Offset origin) {
    final c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 560),
    );
    final ripple = _Ripple(origin, c, _clipPath());
    setState(() => _ripples.add(ripple));
    c.forward().whenComplete(() {
      if (!mounted) return;
      setState(() => _ripples.remove(ripple));
      c.dispose();
    });
  }

  @override
  void dispose() {
    for (final r in _ripples) {
      r.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final ripple = enabled && HaroTokens.palette.ripple;
    Widget inner = widget.builder(context, _hovered && enabled);
    if (ripple) {
      final base = widget.rippleOnAccent
          ? HaroTokens.onAccent
          : HaroTokens.accent;
      inner = Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          inner,
          if (_ripples.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('ripple'),
                  painter: _RipplePainter(
                    List.of(_ripples),
                    base.withValues(alpha: .22),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    Widget result = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Inside a SelectionArea (the agent stream) a Text under the pointer asks for the text
        // cursor and wins over this region's click cursor. A control is not something to select.
        child: SelectionContainer.disabled(child: inner),
      ),
    );
    if (ripple) {
      result = Listener(
        onPointerDown: (e) {
          if (e.buttons & kPrimaryButton != 0 && _takePointer(e.pointer)) {
            _startRipple(e.localPosition);
          }
        },
        child: result,
      );
    }
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

/// The bounds each live ripple is clipped to, in the control's own coordinates, for tests.
/// `null` when [paint] is not a ripple layer.
@visibleForTesting
List<Rect>? rippleClipBounds(CustomPainter? paint) => paint is _RipplePainter
    ? [for (final r in paint.ripples) r.clip.getBounds()]
    : null;

/// The path each live ripple is clipped to (corners included), for tests.
@visibleForTesting
List<Path>? rippleClipPaths(CustomPainter? paint) =>
    paint is _RipplePainter ? [for (final r in paint.ripples) r.clip] : null;

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.ripples, this.color)
    : super(repaint: Listenable.merge([for (final r in ripples) r.controller]));

  final List<_Ripple> ripples;
  final Color color;

  static const _spread = Cubic(.2, 0, 0, 1);

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in ripples) {
      final t = r.controller.value;
      final grow = _spread.transform(math.min(1, t / .65));
      final fade = t < .65 ? 1.0 : 1 - (t - .65) / .35;
      final bounds = r.clip.getBounds();
      final reach = math.sqrt(
        math.pow(
              math.max(r.origin.dx - bounds.left, bounds.right - r.origin.dx),
              2,
            ) +
            math.pow(
              math.max(r.origin.dy - bounds.top, bounds.bottom - r.origin.dy),
              2,
            ),
      );
      canvas.save();
      canvas.clipPath(r.clip);
      canvas.drawCircle(
        r.origin,
        reach * grow,
        Paint()..color = color.withValues(alpha: color.a * fade),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.color != color || old.ripples.length != ripples.length;
}
