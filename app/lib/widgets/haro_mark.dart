import 'package:flutter/widgets.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// The haro glyph without the app icon's squircle: three rows of ink cells resolving
/// into one green cell (the gate going green). Painted from the same rects as
/// `design/brand/haro-mark-glyph.svg`, so it stays crisp at any size.
class HaroMark extends StatelessWidget {
  const HaroMark({super.key, this.height = 18});

  final double height;

  // Glyph bounds inside the 100x100 icon: x 22..78, y 26..77.
  static const double _w = 56;
  static const double _h = 51;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: height * _w / _h,
    height: height,
    child: const CustomPaint(painter: _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  static const List<Rect> _ink = [
    Rect.fromLTWH(0, 0, 6, 6),
    Rect.fromLTWH(12, 0, 6, 6),
    Rect.fromLTWH(24, 0, 6, 6),
    Rect.fromLTWH(36, 0, 6, 6),
    Rect.fromLTWH(48, 0, 6, 6),
    Rect.fromLTWH(0, 16, 9, 9),
    Rect.fromLTWH(18, 16, 9, 9),
    Rect.fromLTWH(36, 16, 9, 9),
    Rect.fromLTWH(9, 25, 9, 9),
    Rect.fromLTWH(27, 25, 9, 9),
    Rect.fromLTWH(45, 25, 9, 9),
    Rect.fromLTWH(0, 40, 42, 11),
  ];
  static const Rect _gate = Rect.fromLTWH(45, 40, 11, 11);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / HaroMark._w, size.height / HaroMark._h);
    final ink = Paint()..color = HaroTokens.ink;
    for (final r in _ink) {
      canvas.drawRect(r, ink);
    }
    canvas.drawRect(_gate, Paint()..color = HaroTokens.gate);
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
