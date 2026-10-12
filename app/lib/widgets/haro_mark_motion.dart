import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// The haro glyph assembling like a gate run (queued, running, green, merged) and coming apart
/// in reverse. Same rects as [HaroMark]; only opacity and the bar's width change, nothing moves.
enum MarkMotion { assemble, disassemble }

enum MarkKind { dot, cell, bar, gate }

class MarkPiece {
  const MarkPiece(this.rect, this.kind, this.index);

  final Rect rect;
  final MarkKind kind;
  final int index;
}

/// Glyph bounds in glyph units: x 0..56, y 0..51 (the 100x100 icon's x 22..78, y 26..77).
const double markWidth = 56;
const double markHeight = 51;

const List<MarkPiece> markPieces = [
  MarkPiece(Rect.fromLTWH(0, 0, 6, 6), MarkKind.dot, 0),
  MarkPiece(Rect.fromLTWH(12, 0, 6, 6), MarkKind.dot, 1),
  MarkPiece(Rect.fromLTWH(24, 0, 6, 6), MarkKind.dot, 2),
  MarkPiece(Rect.fromLTWH(36, 0, 6, 6), MarkKind.dot, 3),
  MarkPiece(Rect.fromLTWH(48, 0, 6, 6), MarkKind.dot, 4),
  MarkPiece(Rect.fromLTWH(0, 16, 9, 9), MarkKind.cell, 0),
  MarkPiece(Rect.fromLTWH(18, 16, 9, 9), MarkKind.cell, 1),
  MarkPiece(Rect.fromLTWH(36, 16, 9, 9), MarkKind.cell, 2),
  MarkPiece(Rect.fromLTWH(9, 25, 9, 9), MarkKind.cell, 3),
  MarkPiece(Rect.fromLTWH(27, 25, 9, 9), MarkKind.cell, 4),
  MarkPiece(Rect.fromLTWH(45, 25, 9, 9), MarkKind.cell, 5),
  MarkPiece(Rect.fromLTWH(0, 40, 11, 11), MarkKind.gate, 0),
  MarkPiece(Rect.fromLTWH(14, 40, 42, 11), MarkKind.bar, 0),
];

/// How long each motion takes from its first frame to its last.
const Duration markAssembleDuration = Duration(milliseconds: 1980);
const Duration markDisassembleDuration = Duration(milliseconds: 1500);

class MarkFrame {
  const MarkFrame(this.rect, this.opacity, this.gate);

  final Rect rect;
  final double opacity;
  final bool gate;
}

/// 0 until [at], then climbing to 1 over [d] milliseconds.
double rampFade(int ms, int at, [int d = 260]) =>
    ((ms - at) / d).clamp(0.0, 1.0);

/// Every piece at [ms] milliseconds into [motion].
List<MarkFrame> markFrames(MarkMotion motion, int ms) {
  return [
    for (final p in markPieces)
      () {
        final r = p.rect;
        var o = 1.0;
        var w = r.width;
        if (motion == MarkMotion.assemble) {
          final at = switch (p.kind) {
            MarkKind.dot => 300 + p.index * 80,
            MarkKind.cell => 820 + p.index * 70,
            MarkKind.gate => 1300,
            MarkKind.bar => 1560,
          };
          o = rampFade(ms, at);
          if (p.kind == MarkKind.bar) {
            final t = ((ms - 1560) / 420).clamp(0.0, 1.0);
            w = r.width * (1 - math.pow(1 - t, 3));
            o = t > 0 ? 1 : 0;
          }
        } else {
          final at = switch (p.kind) {
            MarkKind.bar => 0,
            MarkKind.gate => 260,
            MarkKind.cell => 620 + (5 - p.index) * 60,
            MarkKind.dot => 1000 + (4 - p.index) * 60,
          };
          o = 1 - rampFade(ms, at);
          if (p.kind == MarkKind.bar) {
            final t = (ms / 360).clamp(0.0, 1.0);
            w = r.width * (1 - t);
            o = t < 1 ? 1 : 0;
          }
        }
        return MarkFrame(
          Rect.fromLTWH(r.left, r.top, w, r.height),
          o,
          p.kind == MarkKind.gate,
        );
      }(),
  ];
}

/// The glyph at one moment of its motion; the parent ticks [ms].
class HaroMarkMotion extends StatelessWidget {
  const HaroMarkMotion({
    super.key,
    required this.motion,
    required this.ms,
    this.height = 102,
  });

  final MarkMotion motion;
  final int ms;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: height * markWidth / markHeight,
    height: height,
    child: CustomPaint(painter: _MotionPainter(motion, ms)),
  );
}

class _MotionPainter extends CustomPainter {
  const _MotionPainter(this.motion, this.ms);

  final MarkMotion motion;
  final int ms;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / markWidth, size.height / markHeight);
    for (final f in markFrames(motion, ms)) {
      if (f.opacity <= 0 || f.rect.width <= 0) continue;
      final color = f.gate ? HaroTokens.gate : HaroTokens.ink;
      canvas.drawRect(
        f.rect,
        Paint()..color = color.withValues(alpha: f.opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_MotionPainter old) =>
      old.ms != ms || old.motion != motion;
}
