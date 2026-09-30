import 'package:flutter/widgets.dart';

enum EditorIconKind {
  close,

  /// A window split into two side-by-side panes.
  splitRight,
}

/// Stroke icons for the editor chrome, drawn as vector paths on a 16px grid (the app bundles no
/// icon font and no SVG runtime). They take the colour they are given, like `currentColor`.
class EditorIcon extends StatelessWidget {
  const EditorIcon(this.kind, {super.key, required this.color, this.size = 12});

  final EditorIconKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _IconPainter(kind, color));
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.kind, this.color);

  final EditorIconKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 16;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (kind) {
      case EditorIconKind.close:
        canvas.drawLine(Offset(4 * u, 4 * u), Offset(12 * u, 12 * u), p);
        canvas.drawLine(Offset(12 * u, 4 * u), Offset(4 * u, 12 * u), p);
      case EditorIconKind.splitRight:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(2 * u, 3 * u, 14 * u, 13 * u),
            Radius.circular(1.5 * u),
          ),
          p,
        );
        canvas.drawLine(Offset(8 * u, 3 * u), Offset(8 * u, 13 * u), p);
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.kind != kind || old.color != color;
}
