import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/animation.dart' show Cubic;

/// The Expressive theme's shapes (Claude Design's agent loaders and boot screens): five closed
/// curves described by their radius around the centre, and the morph between them. A shape is
/// sampled at [_n] points and drawn as a smooth Catmull-Rom spline, so the in-between frames of
/// a morph are smooth too. Unit radius: the path spans about -1.1 to 1.1.
const int _n = 96;

double _pw(double x, double p) => math.pow(math.max(0, x), p).toDouble();

final List<double Function(double)> _shapes = [
  (th) => 1,
  (th) => 1.08 * (.6 + .4 * _pw((1 + math.cos(4 * th)) / 2, 2.6)),
  (th) => .84 - .16 * math.cos(4 * th),
  (th) => .86 + .14 * math.cos(3 * th - math.pi / 2),
  (th) =>
      .94 *
      math
          .pow(
            math.pow(math.cos(th).abs(), 4) + math.pow(math.sin(th).abs(), 4),
            -.25,
          )
          .toDouble(),
];

final List<List<double>> _radii = [
  for (final f in _shapes)
    [for (var i = 0; i < _n; i++) f(i / _n * 2 * math.pi)],
];

const Cubic _emphasized = Cubic(.2, 0, 0, 1);

/// The order the loader, the opening screen and the closing steps walk through the shapes.
const List<int> morphOpenOrder = [0, 1, 2, 3, 4];

/// Where a morph stands at [ms]: which two shapes it is between and how far (eased).
class MorphPoint {
  const MorphPoint(this.from, this.to, this.eased, this.segment, this.progress);

  final int from;
  final int to;

  /// 0 to 1, eased: how far from [from] to [to].
  final double eased;

  /// How many shapes have been passed, and 0 to 1 raw progress of the move (0 while holding).
  final int segment;
  final double progress;
}

MorphPoint morphPoint(int ms, List<int> order, int seg, double hold) {
  final t = math.max(0, ms);
  final n = order.length;
  final s = t ~/ seg;
  final f = (t % seg) / seg;
  final m = f < hold ? 0.0 : (f - hold) / (1 - hold);
  return MorphPoint(
    order[s % n],
    order[(s + 1) % n],
    _emphasized.transform(m),
    s,
    m,
  );
}

/// The shape [from] drawn into [to] by [e], rotated and scaled, as a closed path in unit
/// coordinates (multiply by the radius in pixels).
Path morphPath(MorphPoint p, {required double direction, bool pulse = true}) {
  final rad = [
    for (var k = 0; k < _n; k++)
      _radii[p.from][k] + (_radii[p.to][k] - _radii[p.from][k]) * p.eased,
  ];
  final rot = direction * (p.segment + p.eased) * math.pi / 2;
  final scale = pulse
      ? 1 - .1 * math.sin(math.pi * math.min(1, p.progress * 1.15))
      : 1.0;
  return _spline(rad, rot, scale);
}

Path _spline(List<double> rad, double rot, double s) {
  final pts = <Offset>[
    for (var i = 0; i < _n; i++)
      Offset(
        math.cos(i / _n * 2 * math.pi + rot) * rad[i] * s,
        math.sin(i / _n * 2 * math.pi + rot) * rad[i] * s,
      ),
  ];
  final path = Path()..moveTo(pts[0].dx, pts[0].dy);
  for (var i = 0; i < _n; i++) {
    final p0 = pts[(i - 1 + _n) % _n];
    final p1 = pts[i];
    final p2 = pts[(i + 1) % _n];
    final p3 = pts[(i + 2) % _n];
    path.cubicTo(
      p1.dx + (p2.dx - p0.dx) / 6,
      p1.dy + (p2.dy - p0.dy) / 6,
      p2.dx - (p3.dx - p1.dx) / 6,
      p2.dy - (p3.dy - p1.dy) / 6,
      p2.dx,
      p2.dy,
    );
  }
  return path..close();
}

/// The colour between [colours] for the same morph point.
Color morphColour(MorphPoint p, List<Color> colours) =>
    Color.lerp(colours[p.from], colours[p.to], p.eased)!;
