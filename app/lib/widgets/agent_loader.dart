import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/morph_shape.dart';
import '../theme/palette.dart' show BootStyle;
import '../theme/tokens.dart';
import 'dither_square.dart';

/// The "the agent is working on this line" marker, one per theme (Claude Design's agent
/// loaders): Classic is a small 8 by 8 ordered dither with a soft ripple through it,
/// Expressive a tiny shape that morphs and turns in the accent colour, Paper a typewriter
/// braille spinner in ink. It stops moving (one still frame) under the OS reduce-motion setting
/// and in tests ([DitherSquare.animate] is off there), so a repeating ticker never keeps
/// `pumpAndSettle` waiting.
const _stillMs = 1500;

class AgentLoader extends StatefulWidget {
  const AgentLoader({super.key, this.size = 16, this.layoutSize});

  /// Edge of the drawn marker.
  final double size;

  /// Space the row reserves for it (default [size]); a smaller value lets the marker overhang
  /// so it does not push the text beside it.
  final double? layoutSize;

  @override
  State<AgentLoader> createState() => _AgentLoaderState();
}

class _AgentLoaderState extends State<AgentLoader>
    with SingleTickerProviderStateMixin {
  final _ms = ValueNotifier<int>(_stillMs);
  late final Ticker _ticker = createTicker((d) => _ms.value = d.inMilliseconds);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final move =
        DitherSquare.animate && !MediaQuery.disableAnimationsOf(context);
    if (move && !_ticker.isActive) {
      _ticker.start();
    } else if (!move && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _ms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.layoutSize ?? widget.size;
    final style = HaroTokens.palette.boot;
    return SizedBox.square(
      dimension: box,
      child: OverflowBox(
        minWidth: 0,
        minHeight: 0,
        maxWidth: widget.size,
        maxHeight: widget.size,
        child: SizedBox.square(
          dimension: widget.size,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: switch (style) {
                BootStyle.kuro => RipplePainter(_ms, HaroTokens.ink),
                BootStyle.expressive => MorphPainter(_ms, HaroTokens.accent),
                BootStyle.paper => BraillePainter(_ms, HaroTokens.ink),
              },
            ),
          ),
        ),
      ),
    );
  }
}

const _b8 = [
  0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, //
  12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, //
  3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, //
  15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
];

class RipplePainter extends CustomPainter {
  RipplePainter(this.clock, this.colour) : super(repaint: clock);

  final ValueListenable<int> clock;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final ms = clock.value;
    final cell = size.width / 8;
    final on = Paint()
      ..color = colour
      ..isAntiAlias = false;
    final off = Paint()
      ..color = colour.withValues(alpha: .08)
      ..isAntiAlias = false;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final cx = x - 3.5;
        final cy = y - 3.5;
        final r = math.sqrt(cx * cx + cy * cy);
        final v =
            .4 + .36 * math.sin(ms / 230 - r * .9 + math.atan2(cy, cx) * .2);
        final th = (_b8[y * 8 + x] + .5) / 64;
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          v > th ? on : off,
        );
      }
    }
  }

  @override
  bool shouldRepaint(RipplePainter old) => old.colour != colour;
}

class MorphPainter extends CustomPainter {
  MorphPainter(this.clock, this.colour) : super(repaint: clock);

  final ValueListenable<int> clock;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final p = morphPoint(clock.value, morphOpenOrder, 600, .22);
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..scale(size.width / 2.5)
      ..drawPath(morphPath(p, direction: 1), Paint()..color = colour);
  }

  @override
  bool shouldRepaint(MorphPainter old) => old.colour != colour;
}

/// The braille spinner, drawn as dots (bit n of a pattern is dot n+1 of the cell) so it does
/// not depend on a font that has U+2800.
const _braille = [0x0B, 0x19, 0x39, 0x38, 0x3C, 0x34, 0x26, 0x27, 0x07, 0x0F];
const _brailleDots = [
  (0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3), //
];

class BraillePainter extends CustomPainter {
  BraillePainter(this.clock, this.colour) : super(repaint: clock);

  final ValueListenable<int> clock;
  final Color colour;

  int get frame => clock.value ~/ 90 % _braille.length;

  @override
  void paint(Canvas canvas, Size size) {
    final bits = _braille[frame];
    final pitch = size.height * .27;
    final w = pitch;
    final left = (size.width - w) / 2;
    final top = (size.height - pitch * 3) / 2 - pitch * .1;
    final paint = Paint()..color = colour;
    for (var i = 0; i < 8; i++) {
      if (bits & (1 << i) == 0) continue;
      final (c, r) = _brailleDots[i];
      canvas.drawCircle(
        Offset(left + c * w, top + r * pitch),
        pitch * .32,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(BraillePainter old) => old.colour != colour;
}
