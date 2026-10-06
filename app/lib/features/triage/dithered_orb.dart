import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

const _bayer4 = [
  [0, 8, 2, 10],
  [12, 4, 14, 6],
  [3, 11, 1, 9],
  [15, 7, 13, 5],
];

/// One halftone sphere: a lit ball (the Haro of the name) rendered with a 4x4 Bayer ordered
/// dither, so it reads as ink pressed on paper rather than as an image. Ordered, so it is
/// the same every paint. A thin seam round the middle is left open, like the real thing.
class DitheredOrb extends StatelessWidget {
  const DitheredOrb({super.key, this.size = 96, this.cell = 3});

  final double size;

  /// Edge of one dot in logical pixels.
  final double cell;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      key: const ValueKey('dithered-orb'),
      width: size,
      height: size,
      child: CustomPaint(painter: _OrbPainter(cell)),
    ),
  );
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.cell);

  final double cell;

  /// Light from the upper left, a little toward the viewer.
  static final _light = () {
    const x = -.5, y = -.6, z = .62;
    final n = math.sqrt(x * x + y * y + z * z);
    return (x / n, y / n, z / n);
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final n = (size.shortestSide / cell).floor();
    final paint = Paint()..color = HaroTokens.ink.withValues(alpha: .55);
    final dot = cell - .6;
    for (var gy = 0; gy < n; gy++) {
      for (var gx = 0; gx < n; gx++) {
        final u = (gx + .5) / n * 2 - 1;
        final v = (gy + .5) / n * 2 - 1;
        final r2 = u * u + v * v;
        if (r2 >= 1) continue;
        if (v.abs() < .045) continue;
        final z = math.sqrt(1 - r2);
        final diffuse = math.max(
          0.0,
          u * _light.$1 + v * _light.$2 + z * _light.$3,
        );
        final shade = .1 + .9 * math.pow(diffuse, 1.15);
        final threshold = (_bayer4[gy % 4][gx % 4] + .5) / 16;
        if (shade > threshold) {
          canvas.drawRect(Rect.fromLTWH(gx * cell, gy * cell, dot, dot), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.cell != cell;
}
