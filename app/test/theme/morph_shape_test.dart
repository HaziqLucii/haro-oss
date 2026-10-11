import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/morph_shape.dart';
import 'package:haro_app/theme/palette.dart';

void main() {
  test('a morph holds, then eases to the next shape in the order', () {
    final hold = morphPoint(100, morphOpenOrder, 600, .22);
    expect((hold.from, hold.to, hold.eased), (0, 1, 0.0));
    final mid = morphPoint(400, morphOpenOrder, 600, .22);
    expect(mid.eased, inExclusiveRange(0, 1));
    final next = morphPoint(650, morphOpenOrder, 600, .22);
    expect((next.from, next.to, next.segment), (1, 2, 1));
    final wrap = morphPoint(600 * 5 + 50, morphOpenOrder, 600, .22);
    expect((wrap.from, wrap.to), (0, 1));
    expect(morphPoint(-500, morphOpenOrder, 600, .22).segment, 0);
  });

  test('every frame is a closed shape of about unit radius', () {
    for (var ms = 0; ms < 3000; ms += 137) {
      final p = morphPoint(ms, morphOpenOrder, 600, .22);
      final b = morphPath(p, direction: 1).getBounds();
      expect(b.width, inInclusiveRange(1.2, 2.5), reason: '$ms');
      expect(b.height, inInclusiveRange(1.2, 2.5), reason: '$ms');
      expect(b.center.distance, lessThan(.3), reason: '$ms');
    }
    expect(
      morphPath(
        morphPoint(0, morphOpenOrder, 600, .22),
        direction: 1,
        pulse: false,
      ).getBounds().width,
      closeTo(2, .02),
    );
  });

  test('colours move with the shapes', () {
    const cols = [
      Color(0xFF000000),
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFF000000),
      Color(0xFF000000),
    ];
    expect(morphColour(morphPoint(0, morphOpenOrder, 600, .22), cols), cols[0]);
    final c = morphColour(morphPoint(550, morphOpenOrder, 600, .22), cols);
    expect(c.r, greaterThan(0));
  });

  test('only Expressive has the four-colour logo', () {
    expect(HaroPalette.haro.colourMark, isFalse);
    expect(HaroPalette.paper.colourMark, isFalse);
    expect(HaroPalette.material3.colourMark, isTrue);
    expect(HaroPalette.material3.tertiary, const Color(0xFFEFB8C8));
  });
}
