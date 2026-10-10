import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../capture/capture_mode.dart';
import '../theme/tokens.dart';
import '../widgets/haro_pressable.dart';

/// Linux hides the native (GTK) title bar so the top bar runs edge to edge like macOS does, which
/// leaves the minimize, maximize and close buttons to haro. Not in capture mode (the shots show
/// haro's own pixels) and not on macOS, whose traffic lights stay native.
bool get useWindowControls =>
    !kIsWeb && !captureMode && defaultTargetPlatform == TargetPlatform.linux;

/// What the buttons do to the window; the real one talks to `window_manager`.
abstract class WindowActions {
  const WindowActions();

  Future<bool> isMaximized();
  Future<void> minimize();
  Future<void> toggleMaximize();
  Future<void> close();

  /// Calls [onChange] when the window is maximized or restored. Returns the cancel.
  VoidCallback listen(ValueChanged<bool> onChange);
}

class ManagerWindowActions extends WindowActions {
  const ManagerWindowActions();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> toggleMaximize() async => await windowManager.isMaximized()
      ? windowManager.unmaximize()
      : windowManager.maximize();

  @override
  Future<void> close() => windowManager.close();

  @override
  VoidCallback listen(ValueChanged<bool> onChange) {
    final l = _MaximizeListener(onChange);
    windowManager.addListener(l);
    return () => windowManager.removeListener(l);
  }
}

class _MaximizeListener with WindowListener {
  _MaximizeListener(this.onChange);

  final ValueChanged<bool> onChange;

  @override
  void onWindowMaximize() => onChange(true);

  @override
  void onWindowUnmaximize() => onChange(false);
}

/// Minimize, maximize or restore, and close, flush at the top bar's right end.
class WindowControls extends StatefulWidget {
  const WindowControls({
    super.key,
    this.actions = const ManagerWindowActions(),
  });

  final WindowActions actions;

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> {
  bool _maximized = false;
  VoidCallback? _cancel;

  @override
  void initState() {
    super.initState();
    widget.actions.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
    _cancel = widget.actions.listen((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _WindowButton(
        key: const ValueKey('window-minimize'),
        tooltip: 'Minimize',
        glyph: _Glyph.minimize,
        onTap: widget.actions.minimize,
      ),
      _WindowButton(
        key: const ValueKey('window-maximize'),
        tooltip: _maximized ? 'Restore' : 'Maximize',
        glyph: _maximized ? _Glyph.restore : _Glyph.maximize,
        onTap: widget.actions.toggleMaximize,
      ),
      _WindowButton(
        key: const ValueKey('window-close'),
        tooltip: 'Close',
        glyph: _Glyph.close,
        onTap: widget.actions.close,
      ),
    ],
  );
}

enum _Glyph { minimize, maximize, restore, close }

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    super.key,
    required this.tooltip,
    required this.glyph,
    required this.onTap,
  });

  final String tooltip;
  final _Glyph glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      width: 36,
      height: 32,
      margin: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(
        color: hovered ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: CustomPaint(
        painter: _GlyphPainter(
          glyph,
          hovered ? HaroTokens.ink : HaroTokens.ink66,
        ),
      ),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final c = size.center(Offset.zero);
    const h = 5.0;
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(c + const Offset(-h, 3), c + const Offset(h, 3), p);
      case _Glyph.maximize:
        canvas.drawRect(
          Rect.fromCenter(center: c, width: h * 2, height: h * 2),
          p,
        );
      case _Glyph.restore:
        // A front square and the corner of the one behind it, up and to the right.
        final front = Rect.fromLTWH(c.dx - 5, c.dy - 2, 7, 7);
        final back = Rect.fromLTWH(c.dx - 2.5, c.dy - 5, 7, 7);
        canvas.drawRect(front, p);
        canvas.drawPath(
          Path()
            ..moveTo(back.left, front.top)
            ..lineTo(back.left, back.top)
            ..lineTo(back.right, back.top)
            ..lineTo(back.right, back.bottom)
            ..lineTo(front.right, back.bottom),
          p,
        );
      case _Glyph.close:
        canvas.drawLine(c + const Offset(-h, -h), c + const Offset(h, h), p);
        canvas.drawLine(c + const Offset(h, -h), c + const Offset(-h, h), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
