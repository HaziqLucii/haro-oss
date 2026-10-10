import 'package:flutter/widgets.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import 'haro_mark_motion.dart' show MarkKind, markHeight, markPieces, markWidth;

/// The haro glyph without the app icon's squircle: three rows of ink cells resolving
/// into one green cell (the gate going green). Painted from the same rects as
/// `design/brand/haro-mark-glyph.svg`, so it stays crisp at any size.
class HaroMark extends StatelessWidget {
  const HaroMark({super.key, this.height = 18});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: height * markWidth / markHeight,
    height: height,
    child: const CustomPaint(painter: _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / markWidth, size.height / markHeight);
    final ink = Paint()..color = HaroTokens.ink;
    final gate = Paint()..color = HaroTokens.gate;
    for (final p in markPieces) {
      canvas.drawRect(p.rect, p.kind == MarkKind.gate ? gate : ink);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}

/// `[mark] haro.`: the lockup. The mark sits on the text baseline and is sized
/// off the font so it matches the lowercase ascender height at any size.
class HaroWordmark extends StatelessWidget {
  const HaroWordmark({super.key, required this.fontSize, this.textKey});

  final double fontSize;
  final Key? textKey;

  static const double markToFont = .72;
  static const double gapToFont = .36;

  @override
  Widget build(BuildContext context) => Text.rich(
    key: textKey,
    TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Padding(
            padding: EdgeInsets.only(right: fontSize * gapToFont),
            child: HaroMark(height: fontSize * markToFont),
          ),
        ),
        const TextSpan(text: 'haro.'),
      ],
    ),
    style: HaroText.wordmark.copyWith(
      fontSize: fontSize,
      letterSpacing: -fontSize / 100,
    ),
  );
}
