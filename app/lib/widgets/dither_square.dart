import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

const _bayer4 = [
  [0, 8, 2, 10],
  [12, 4, 14, 6],
  [3, 11, 1, 9],
  [15, 7, 13, 5],
];

/// The "this line is running right now" mark: a small square that fills with an ordered
/// (Bayer) dither and slowly shimmers along a diagonal, so a glance at the stream finds the
/// live line. Done lines keep the plain filled square; this is only ever on in-flight work.
///
/// It stops moving (one fixed frame) under the OS reduce-motion setting, and tests turn
/// [animate] off globally so a repeating ticker never keeps `pumpAndSettle` waiting.
class DitherSquare extends StatefulWidget {
  const DitherSquare({
    super.key,
    this.size = 8,
    this.layoutSize,
    this.color = HaroTokens.ink,
  });

  /// Edge of the drawn square.
  final double size;

  /// Space the row reserves for it (default [size]); a smaller value lets the mark overhang
  /// so it does not push the text beside it.
  final double? layoutSize;
  final Color color;

  /// Off in the test binding (see `test/flutter_test_config.dart`).
  static bool animate = true;

  @override
  State<DitherSquare> createState() => _DitherSquareState();
}

class _DitherSquareState extends State<DitherSquare>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _moving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final want =
        DitherSquare.animate && !MediaQuery.disableAnimationsOf(context);
    if (want && !_moving) {
      _c.repeat();
    } else if (!want && _moving) {
      _c.stop();
    }
    _moving = want;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.layoutSize ?? widget.size;
    return SizedBox.square(
      dimension: box,
      child: OverflowBox(
        minWidth: 0,
        minHeight: 0,
        maxWidth: widget.size,
        maxHeight: widget.size,
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _DitherPainter(_c, widget.color)),
        ),
      ),
    );
  }
}

class _DitherPainter extends CustomPainter {
  _DitherPainter(this.t, this.color) : super(repaint: t);

  final Animation<double> t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 4;
    final fill = Paint()..color = color;
    for (var gy = 0; gy < 4; gy++) {
      for (var gx = 0; gx < 4; gx++) {
        // A diagonal swell: each cell peaks a little after its upper-left neighbour.
        final level =
            .5 + .5 * math.sin(2 * math.pi * (t.value - (gx + gy) / 8));
        final threshold = (_bayer4[gy][gx] + .5) / 16;
        if (level > threshold) {
          canvas.drawRect(
            Rect.fromLTWH(gx * cell, gy * cell, cell, cell),
            fill,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_DitherPainter old) => old.color != color;
}
