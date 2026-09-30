import 'package:flutter/widgets.dart';

/// A passed check: a stroked tick in the status square's footprint, so a checklist row
/// lines up with the rows that still show a square.
class CheckMark extends StatelessWidget {
  const CheckMark({super.key, required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _TickPainter(color)),
  );
}

class _TickPainter extends CustomPainter {
  const _TickPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final path = Path()
      ..moveTo(w * .12, w * .52)
      ..lineTo(w * .40, w * .80)
      ..lineTo(w * .90, w * .22);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * .16
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter,
    );
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.color != color;
}
