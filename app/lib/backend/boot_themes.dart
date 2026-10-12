import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import '../theme/haro_theme.dart';
import '../theme/morph_shape.dart';
import '../theme/tokens.dart';
import '../widgets/check_mark.dart';
import '../widgets/haro_mark_motion.dart';
import 'boot_splash.dart' show BootLine;

/// The start and quit screens of Material 3 and Paper, from Claude Design's boot screens for
/// them. Their timelines must fit the sequence lengths `bootSequence` (Expressive 3.1 s, Paper
/// 3.4 s) and `closingTail` (Expressive 2.4 s, Paper 1.9 s) in `boot_splash.dart`; change them
/// together. Only what is real is shown: the lines are the ones the launcher reports and the
/// quit lists, never scripted stats. The haro theme keeps its own screens in `boot_splash.dart`.

const Cubic _spring = Cubic(.34, 1.56, .64, 1);
const Cubic _soft = Cubic(.34, 1.4, .64, 1);
const Cubic _standard = Cubic(.4, 0, .2, 1);

double _k(num ms, num at, num d, [Curve curve = Curves.linear]) =>
    curve.transform(((ms - at) / d).clamp(0.0, 1.0).toDouble());

/// The bottom-right status text both themes share.
class _Status extends StatelessWidget {
  const _Status(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Positioned(
    right: 24,
    bottom: 18,
    child: Text(
      text,
      key: const Key('boot-status'),
      style: HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .14),
    ),
  );
}

// ---------------------------------------------------------------------------------------------
// Expressive: a shape morphs while haro loads, then breaks into the mark; on the way out the
// mark is stirred into a spinning pool. The shapes are the loader's
// (`lib/theme/morph_shape.dart`), each with its own colour.
// ---------------------------------------------------------------------------------------------

const double _mark = 2.57;
const double _stage = 150;

/// The glyph's rect in the 150 by 150 stage, centred.
final Offset _markOrigin = Offset(
  (_stage - markWidth * _mark) / 2,
  (_stage - markHeight * _mark) / 2,
);

/// The colour each shape takes: accent, tertiary, the gate's green, ink, tertiary.
List<Color> _shapeColours() => [
  HaroTokens.accent,
  HaroTokens.palette.tertiary,
  HaroTokens.gate,
  HaroTokens.ink,
  HaroTokens.palette.tertiary,
];

void _paintShape(Canvas canvas, Path unit, Color color, double scale) {
  if (scale <= 0) return;
  canvas
    ..save()
    ..translate(_stage / 2, _stage / 2)
    ..scale(_stage / 2.5 * scale)
    ..drawPath(unit, Paint()..color = color)
    ..restore();
}

/// A glyph piece's box in the stage, its colour and its corner radius: the one place the quit
/// screens and the swirl read them from.
Rect _pieceBox(MarkPiece p) => Rect.fromLTWH(
  _markOrigin.dx + p.rect.left * _mark,
  _markOrigin.dy + p.rect.top * _mark,
  p.rect.width * _mark,
  p.rect.height * _mark,
);

Color _pieceColour(MarkKind kind) => switch (kind) {
  MarkKind.dot => HaroTokens.palette.tertiary,
  MarkKind.cell => HaroTokens.accent,
  MarkKind.gate => HaroTokens.gate,
  MarkKind.bar => HaroTokens.ink,
};

double _pieceRadius(MarkKind kind, Rect box) => switch (kind) {
  MarkKind.dot || MarkKind.bar => box.height / 2,
  MarkKind.cell => 5.0,
  MarkKind.gate => 8.0,
};

/// The glyph's thirteen pieces at one moment: [gather] pulls them toward the centre (negative
/// pushes them out), [scale] sizes each about its own middle, [opacity] fades them all.
void _paintMarkPieces(
  Canvas canvas, {
  required double gather,
  required double scale,
  double opacity = 1,
}) {
  if (scale <= 0 || opacity <= 0) return;
  final centre = Offset(markWidth / 2, markHeight / 2);
  for (final p in markPieces) {
    final r = p.rect;
    final toward = (centre - r.topLeft) * _mark * gather;
    final box = Rect.fromLTWH(
      _markOrigin.dx + r.left * _mark + toward.dx,
      _markOrigin.dy + r.top * _mark + toward.dy,
      r.width * _mark,
      r.height * _mark,
    );
    final scaled = Rect.fromCenter(
      center: box.center,
      width: box.width * scale,
      height: box.height * scale,
    );
    final color = _pieceColour(p.kind);
    final radius = _pieceRadius(p.kind, scaled);
    canvas.drawRRect(
      RRect.fromRectAndRadius(scaled, Radius.circular(radius)),
      Paint()..color = color.withValues(alpha: opacity),
    );
  }
}

class _M3OpeningPainter extends CustomPainter {
  const _M3OpeningPainter(this.t);

  final int t;

  static const splitAt = 2100;

  @override
  void paint(Canvas canvas, Size size) {
    if (t < splitAt) {
      final pt = morphPoint(t - 80, morphOpenOrder, 600, .22);
      _paintShape(
        canvas,
        morphPath(pt, direction: 1),
        morphColour(pt, _shapeColours()),
        t < 80 ? 0 : _k(t, 80, 550, _spring),
      );
    } else {
      _paintMarkPieces(
        canvas,
        gather: .85 * (1 - _k(t, splitAt + 60, 600, _spring)),
        scale: _k(t, splitAt, 600, _spring).clamp(0.0, 1.2),
      );
    }
  }

  @override
  bool shouldRepaint(_M3OpeningPainter old) => old.t != t;
}

/// The start screen: the shape morphs while the backend starts and breaks into the mark, then
/// the word. Under it the lines say what really happened.
class M3Opening extends StatelessWidget {
  const M3Opening({
    super.key,
    required this.t,
    required this.lines,
    required this.lineOpacity,
    required this.status,
  });

  final int t;
  final List<BootLine> lines;
  final double Function(int index) lineOpacity;
  final String status;

  @override
  Widget build(BuildContext context) {
    final word = _k(t, 2600, 400);
    return Scaffold(
      backgroundColor: HaroTokens.bg,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: _stage,
                  child: CustomPaint(painter: _M3OpeningPainter(t)),
                ),
                const SizedBox(height: 26),
                Opacity(
                  opacity: word,
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - _k(t, 2600, 500, _soft))),
                    child: Text(
                      'haro.',
                      key: const Key('boot-wordmark'),
                      style: HaroText.wordmark.copyWith(
                        fontSize: 56,
                        letterSpacing: -2.52,
                        color: HaroTokens.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                _M3Lines(lines: lines, opacity: lineOpacity),
              ],
            ),
          ),
          _Status(status),
        ],
      ),
    );
  }
}

class _M3Lines extends StatelessWidget {
  const _M3Lines({required this.lines, required this.opacity});

  final List<BootLine> lines;
  final double Function(int index) opacity;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    child: Column(
      children: [
        for (final (i, l) in lines.indexed)
          Opacity(
            opacity: opacity(i),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      l.label,
                      key: ValueKey('boot-line-$i'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.mono(
                        size: 11.5,
                        color: HaroTokens.ink66,
                        tracking: 0,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l.result ?? '…',
                        key: ValueKey('boot-line-result-$i'),
                        style: HaroText.mono(
                          size: 11.5,
                          color: l.result == null
                              ? HaroTokens.ink42
                              : HaroTokens.ink,
                          tracking: 0,
                        ),
                      ),
                      if (l.result != null) ...[
                        const SizedBox(width: 6),
                        CheckMark(
                          key: ValueKey('boot-line-check-$i'),
                          color: HaroTokens.accent,
                          size: 11,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// When each part of the quit plays, in milliseconds after the backend stopped. Together they
/// make [closingTail] (2.4 s): the steps tick off, the list and the word fade, then the mark is
/// stirred into a spinning pool that shrinks away.
abstract final class _Close {
  static const stepGap = 200;
  static const fade = 700;
  static const swirl = 750;
  static const swirlTime = 800;
  static const poolGone = 1300;
  static const poolShrink = 150;
  static const blurRamp = 240;
  static const maxBlur = 3.4;
  static const stepSeg = 300;
  static const stepHold = .15;
}

/// How long the quit screen needs after the backend stops: the swirl's start, the pool's life
/// and a beat for the layer to fade. `closingTail` must be at least this.
const Duration m3ClosingNeeds = Duration(
  milliseconds: _Close.swirl + _Close.poolGone + _Close.poolShrink + 150,
);

double _smooth(double x) {
  final c = x.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

/// The order the mark's pieces are stirred in: green, then the white bar, then the purple cells,
/// then the pink dots, each group left to right, a beat apart.
final List<double> _swirlStarts = () {
  final centre = Offset(_stage / 2, _stage / 2);
  const base = [0, 160, 300, 700];
  final items = <({int i, int group, double x, double y})>[];
  for (final (i, p) in markPieces.indexed) {
    final box = _pieceBox(p);
    final group = switch (p.kind) {
      MarkKind.gate => 0,
      MarkKind.bar => 1,
      MarkKind.cell => 2,
      MarkKind.dot => 3,
    };
    items.add((
      i: i,
      group: group,
      x: box.center.dx - centre.dx,
      y: box.center.dy - centre.dy,
    ));
  }
  items.sort((a, b) {
    final g = a.group.compareTo(b.group);
    if (g != 0) return g;
    final x = a.x.compareTo(b.x);
    return x != 0 ? x : a.y.compareTo(b.y);
  });
  final starts = List<double>.filled(markPieces.length, 0);
  final seen = [0, 0, 0, 0];
  for (final it in items) {
    starts[it.i] = base[it.group] + seen[it.group]++ * 55.0;
  }
  return starts;
}();

/// The glyph stirred away like coffee: each piece swells into a pink disc and spirals into the
/// middle, and what has arrived is a pink pool of two discs that turns and shrinks to nothing. A
/// blur followed by an alpha threshold makes the discs run into each other (a goo filter).
void _paintSwirl(Canvas canvas, int k0) {
  if (k0 < 0) {
    _paintMarkPieces(canvas, gather: 0, scale: 1);
    return;
  }
  final tertiary = HaroTokens.palette.tertiary;
  final centre = Offset(_stage / 2, _stage / 2);
  final sigma = math.min(_Close.maxBlur, k0 / _Close.blurRamp * _Close.maxBlur);
  final bounds = Offset.zero & const Size(_stage, _stage);
  final fade = 1 - _k(k0, _Close.poolGone + _Close.poolShrink, 150);
  if (fade <= 0) return;
  canvas.saveLayer(
    bounds.inflate(60),
    Paint()..color = Color.fromRGBO(0, 0, 0, fade),
  );
  canvas.saveLayer(
    bounds.inflate(60),
    Paint()
      ..colorFilter = const ColorFilter.matrix(<double>[
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 24, -2550,
      ]),
  );
  canvas.saveLayer(
    bounds.inflate(60),
    Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: math.max(sigma, .01),
        sigmaY: math.max(sigma, .01),
        tileMode: TileMode.decal,
      ),
  );
  var mass = 0.0;
  for (final (i, p) in markPieces.indexed) {
    final box = _pieceBox(p);
    final colour = _pieceColour(p.kind);
    final radius0 = _pieceRadius(p.kind, box);
    final m = ((k0 - _swirlStarts[i]) / _Close.swirlTime).clamp(0.0, 1.0);
    if (m <= 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(radius0)),
        Paint()..color = colour,
      );
      continue;
    }
    mass += _smooth((m - .55) / .45) * box.width * box.height;
    if (m >= 1) continue;
    final l = _smooth(m / .28);
    final d = math.sqrt(box.width * box.height) * .92;
    final w = box.width + (d - box.width) * l;
    final h = box.height + (d - box.height) * l;
    final radius = radius0 + (math.min(w, h) / 2 - radius0) * l;
    final rel = box.center - centre;
    final dist = rel.distance * math.pow(1 - _smooth(m), 1.1);
    final angle = math.atan2(rel.dy, rel.dx) - math.pi * 2.6 * math.pow(m, 1.4);
    final vel = math.sin(math.pi * m) * l;
    final stretch = 1 + .75 * vel;
    final s = math.max(0.0, 1 - math.pow(m, 1.8) * .9);
    canvas
      ..save()
      ..translate(
        centre.dx + math.cos(angle) * dist,
        centre.dy + math.sin(angle) * dist,
      )
      ..rotate(angle - math.pi / 2)
      ..scale(s * stretch, s / math.sqrt(stretch))
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w, height: h),
          Radius.circular(radius),
        ),
        Paint()..color = Color.lerp(colour, tertiary, _smooth((m - .15) / .6))!,
      )
      ..restore();
  }
  final shrink = 1 - _smooth((k0 - _Close.poolGone) / _Close.poolShrink);
  final pool = math.sqrt(mass) * .62 * shrink;
  final spin = -k0 * .011;
  for (var i = 0; i < 2; i++) {
    final size = pool * (i == 1 ? .62 : .84);
    final off = pool * .17;
    canvas.drawCircle(
      centre +
          Offset(math.cos(spin + i * math.pi), math.sin(spin + i * math.pi)) *
              off,
      size / 2,
      Paint()..color = tertiary,
    );
  }
  canvas
    ..restore()
    ..restore()
    ..restore();
}

class _M3ClosingPainter extends CustomPainter {
  const _M3ClosingPainter(this.s);

  final int? s;

  @override
  void paint(Canvas canvas, Size size) {
    final s = this.s;
    if (s == null) {
      _paintMarkPieces(canvas, gather: 0, scale: 1);
      return;
    }
    _paintSwirl(canvas, s - _Close.swirl);
  }

  @override
  bool shouldRepaint(_M3ClosingPainter old) => old.s != s;
}

/// The quit screen: the steps turn through the shapes like a loader while the backend stops and
/// spring into green ticks when it has, then the list and the word fade and the mark is stirred
/// into a pink pool that spins away.
class M3Closing extends StatelessWidget {
  const M3Closing({
    super.key,
    required this.t,
    required this.sinceStopped,
    required this.lines,
    required this.stopped,
  });

  final int t;

  /// Milliseconds since the backend stopped, or null while it is stopping or motion is off.
  final int? sinceStopped;
  final List<String> lines;
  final bool stopped;

  @override
  Widget build(BuildContext context) {
    final s = sinceStopped;
    final out = s == null ? 0.0 : _k(s, _Close.fade, 350);
    final stoppedAt = s == null ? null : t - s;
    return Scaffold(
      backgroundColor: HaroTokens.bg,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: _stage,
                  child: CustomPaint(painter: _M3ClosingPainter(s)),
                ),
                const SizedBox(height: 26),
                Opacity(
                  opacity: 1 - out,
                  child: Text(
                    'haro.',
                    key: const Key('boot-wordmark'),
                    style: HaroText.wordmark.copyWith(
                      fontSize: 56,
                      letterSpacing: -2.52,
                      color: HaroTokens.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Opacity(
                  opacity: (1 - out) * _k(t, 150, 300),
                  child: SizedBox(
                    width: 360,
                    child: Column(
                      children: [
                        for (final (i, l) in lines.indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                _Step(
                                  t: t,
                                  doneAt: stoppedAt != null
                                      ? stoppedAt + i * _Close.stepGap
                                      : (stopped ? 0 : null),
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    l,
                                    key: ValueKey('boot-line-$i'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HaroText.ui(
                                      size: 14,
                                      color: HaroTokens.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const _Status('CLOSING'),
        ],
      ),
    );
  }
}

/// A shape turning through the others in its colours, at [t] ms on the screen's own clock.
class _StepLoaderPainter extends CustomPainter {
  const _StepLoaderPainter(this.t);

  final int t;

  @override
  void paint(Canvas canvas, Size size) {
    final pt = morphPoint(t, morphOpenOrder, _Close.stepSeg, _Close.stepHold);
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..scale(size.width / 2.5)
      ..drawPath(
        morphPath(pt, direction: 1),
        Paint()..color = morphColour(pt, _shapeColours()),
      );
  }

  @override
  bool shouldRepaint(_StepLoaderPainter old) => old.t != t;
}

/// A step's marker, as the design has it: the morphing shape while the step is going, then (at
/// [doneAt], on the same clock as [t]) the shape fades and a green circle with a tick springs in.
/// A null [doneAt] is still going.
class _Step extends StatelessWidget {
  const _Step({required this.t, required this.doneAt});

  final int t;
  final int? doneAt;

  @override
  Widget build(BuildContext context) {
    final at = doneAt;
    final done = at == null ? 0.0 : _k(t, at, 450, _spring);
    final loader = at == null ? 1.0 : 1 - _k(t, at, 200);
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (loader > 0)
            Opacity(
              opacity: loader,
              child: CustomPaint(
                size: const Size.square(24),
                painter: _StepLoaderPainter(t),
              ),
            ),
          if (done > 0)
            Transform.scale(
              scale: done,
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: HaroTokens.gate,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: CheckMark(color: HaroTokens.bg, size: 11),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Paper: outlines are drawn, then inked in like a stamp, the word is typed; on the way out the
// session prints as a receipt, then the paper goes blank.
// ---------------------------------------------------------------------------------------------

/// The paper's off-white, warmer than the theme's white.
const Color _paper = Color(0xFFFBFAF7);

const double _ps = 1.6;

class _PaperLinesPainter extends CustomPainter {
  const _PaperLinesPainter(this.opacity);

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final line = Paint()
      ..color = HaroTokens.ink.withValues(alpha: .05 * opacity)
      ..strokeWidth = 1;
    for (var y = 28.0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    canvas.drawLine(
      const Offset(64, 0),
      Offset(64, size.height),
      Paint()
        ..color = HaroTokens.fail.withValues(alpha: .25 * opacity)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_PaperLinesPainter old) => old.opacity != opacity;
}

class _PaperMarkPainter extends CustomPainter {
  const _PaperMarkPainter(this.t);

  final int t;

  static int _drawAt(MarkPiece p) => switch (p.kind) {
    MarkKind.dot => 200 + p.index * 70,
    MarkKind.cell => 650 + p.index * 70,
    MarkKind.gate => 1150,
    MarkKind.bar => 1300,
  };

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in markPieces) {
      final d0 = _drawAt(p);
      final drawn = t >= d0;
      final inked = t >= d0 + 500;
      final stamp = inked && t < d0 + 650;
      final colour = p.kind == MarkKind.gate ? HaroTokens.gate : HaroTokens.ink;
      final s = stamp
          ? 1.12
          : drawn
          ? 1.0
          : .96;
      final r = Rect.fromLTWH(
        p.rect.left * _ps,
        p.rect.top * _ps,
        p.rect.width * _ps,
        p.rect.height * _ps,
      );
      canvas.save();
      canvas.translate(r.center.dx, r.center.dy);
      canvas.rotate(inked ? 0 : -2 * math.pi / 180);
      canvas.scale(s);
      final box = Rect.fromCenter(
        center: Offset.zero,
        width: r.width,
        height: r.height,
      );
      final rr = RRect.fromRectAndRadius(box, const Radius.circular(2));
      if (inked) canvas.drawRRect(rr, Paint()..color = colour);
      if (drawn) {
        canvas.drawRRect(
          rr.deflate(.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = colour,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PaperMarkPainter old) => old.t != t;
}

class _TicksPainter extends CustomPainter {
  const _TicksPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      const Offset(0, 6),
      Offset(size.width, 6),
      Paint()..color = HaroTokens.ink.withValues(alpha: .18),
    );
    for (var i = 0; i < 21; i++) {
      final major = i % 5 == 0;
      final on = i / 20 <= progress;
      canvas.drawRect(
        Rect.fromLTWH(i * 15.0, major ? 0 : 3, 1, major ? 12 : 6),
        Paint()
          ..color = on ? HaroTokens.ink : HaroTokens.ink.withValues(alpha: .22),
      );
    }
  }

  @override
  bool shouldRepaint(_TicksPainter old) => old.progress != progress;
}

class _Dotted extends StatelessWidget {
  const _Dotted();

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(top: 6, left: 6, right: 6),
      child: CustomPaint(
        painter: _DotsPainter(),
        size: const Size.fromHeight(1),
      ),
    ),
  );
}

class _DotsPainter extends CustomPainter {
  const _DotsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = HaroTokens.ink.withValues(alpha: .35);
    for (var x = 0.0; x < size.width; x += 3) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, 1), p);
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => false;
}

class PaperOpening extends StatelessWidget {
  const PaperOpening({
    super.key,
    required this.t,
    required this.lines,
    required this.lineOpacity,
    required this.progress,
    required this.status,
  });

  final int t;
  final List<BootLine> lines;
  final double Function(int index) lineOpacity;

  /// How far the backend start has got, 0 to 1, shown on the ruler.
  final double progress;
  final String status;

  @override
  Widget build(BuildContext context) {
    const word = 'haro.';
    final n = t < 1900 ? 0 : math.min(word.length, (t - 1900) ~/ 110 + 1);
    final caret = t >= 1900 && (t ~/ 400).isEven;
    final textStyle = HaroText.wordmark.copyWith(
      fontSize: 52,
      letterSpacing: -2.6,
      color: HaroTokens.ink,
    );
    return Scaffold(
      backgroundColor: _paper,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _PaperLinesPainter(_k(t, 50, 800))),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: markWidth * _ps,
                  height: markHeight * _ps,
                  child: CustomPaint(painter: _PaperMarkPainter(t)),
                ),
                const SizedBox(height: 40),
                // The full word is laid out invisibly so the typed letters stay where they land.
                Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Opacity(opacity: 0, child: Text(word, style: textStyle)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          word.substring(0, n),
                          key: const Key('boot-wordmark'),
                          style: textStyle,
                        ),
                        Container(
                          width: 3,
                          height: 44,
                          margin: const EdgeInsets.only(left: 3),
                          color: HaroTokens.ink.withValues(
                            alpha: caret ? 1 : 0,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: 300,
                  child: Column(
                    children: [
                      for (final (i, l) in lines.indexed)
                        Opacity(
                          opacity: lineOpacity(i),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 220,
                                  ),
                                  child: Text(
                                    l.label,
                                    key: ValueKey('boot-line-$i'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HaroText.mono(
                                      size: 12,
                                      color: HaroTokens.ink,
                                      tracking: 0,
                                    ),
                                  ),
                                ),
                                const _Dotted(),
                                Text(
                                  l.result ?? '…',
                                  key: ValueKey('boot-line-result-$i'),
                                  style: HaroText.mono(
                                    size: 12,
                                    weight: FontWeight.w600,
                                    color: l.result == null
                                        ? HaroTokens.ink42
                                        : HaroTokens.ink,
                                    tracking: 0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  key: const Key('boot-bar'),
                  width: 300,
                  height: 12,
                  child: CustomPaint(painter: _TicksPainter(progress)),
                ),
              ],
            ),
          ),
          _Status(status),
        ],
      ),
    );
  }
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _stamp(DateTime d) =>
    '${d.day} ${_months[d.month - 1]} ${d.year} · '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _Zigzag extends CustomPainter {
  const _Zigzag();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, 0);
    for (var x = 0.0; x < size.width; x += 10) {
      path
        ..lineTo(x + 5, size.height)
        ..lineTo(x + 10, 0);
    }
    path.close();
    canvas
      ..drawPath(path, Paint()..color = HaroTokens.bg)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = HaroTokens.ink.withValues(alpha: .14),
      );
  }

  @override
  bool shouldRepaint(_Zigzag old) => false;
}

/// The quit screen on paper: the stopping steps print as a receipt from a slot, tear off and
/// vanish once the backend is gone.
class PaperClosing extends StatelessWidget {
  const PaperClosing({
    super.key,
    required this.t,
    required this.sinceStopped,
    required this.lines,
    required this.stopped,
    required this.printed,
  });

  final int t;
  final int? sinceStopped;
  final List<String> lines;
  final bool stopped;

  /// The receipt's wall-clock stamp, taken when the quit began.
  final DateTime printed;

  @override
  Widget build(BuildContext context) {
    // The receipt finishes printing (by 0.7 s) before it tears off, however fast the backend
    // stops, so the 'done' rows and the footer are always seen.
    final s = sinceStopped == null ? null : math.min(sinceStopped!, t - 700);
    final print = _k(t, 100, 600);
    final tear = s == null ? 0.0 : _k(s, 300, 800, _standard);
    final fade = s == null ? 1.0 : 1 - _k(s, 600, 600);
    return Scaffold(
      backgroundColor: _paper,
      body: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 36),
              child: Opacity(
                opacity: fade,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: s == null ? 1 : 1 - _k(s, 300, 400),
                      child: Container(
                        width: 380,
                        height: 6,
                        decoration: BoxDecoration(
                          color: HaroTokens.ink,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(0, 40 * tear),
                      child: SizedBox(
                        width: 340,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.topCenter,
                            heightFactor: print,
                            child: _Receipt(
                              lines: lines,
                              stopped: stopped,
                              printed: printed,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Opacity(
              opacity: s != null && s >= 900 ? 0 : 1,
              child: Text(
                stopped
                    ? 'Stopped. Closing haro.'
                    : 'Printing session receipt…',
                key: const Key('boot-status'),
                textAlign: TextAlign.center,
                style: HaroText.mono(
                  size: 11,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Receipt extends StatelessWidget {
  const _Receipt({
    required this.lines,
    required this.stopped,
    required this.printed,
  });

  final List<String> lines;
  final bool stopped;
  final DateTime printed;

  Widget _rule() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: CustomPaint(
      painter: const _DashPainter(),
      size: const Size(double.infinity, 1),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final mono = HaroText.mono(size: 12, color: HaroTokens.ink, tracking: 0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 26),
          decoration: BoxDecoration(
            color: HaroTokens.bg,
            border: Border(
              left: BorderSide(color: HaroTokens.ink.withValues(alpha: .14)),
              right: BorderSide(color: HaroTokens.ink.withValues(alpha: .14)),
              bottom: BorderSide(color: HaroTokens.ink.withValues(alpha: .14)),
            ),
          ),
          child: Column(
            children: [
              Text(
                'haro.',
                style: HaroText.wordmark.copyWith(
                  fontSize: 22,
                  letterSpacing: -.88,
                  color: HaroTokens.ink,
                ),
              ),
              Text(
                'session receipt · ${_stamp(printed)}',
                style: HaroText.mono(
                  size: 11,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
              _rule(),
              for (final (i, l) in lines.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          l,
                          key: ValueKey('boot-line-$i'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono,
                        ),
                      ),
                      const _Dotted(),
                      Text(
                        stopped ? 'done' : '…',
                        style: mono.copyWith(
                          fontWeight: FontWeight.w600,
                          color: stopped ? HaroTokens.ink : HaroTokens.ink42,
                        ),
                      ),
                    ],
                  ),
                ),
              _rule(),
              Text(
                stopped ? '- stopped · see you next time -' : '',
                style: HaroText.mono(
                  size: 12,
                  color: HaroTokens.ink66,
                  tracking: 0,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          height: 10,
          child: CustomPaint(painter: const _Zigzag()),
        ),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = HaroTokens.ink.withValues(alpha: .35);
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 4, 1), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => false;
}
