import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/widgets/dither_square.dart';

void main() {
  tearDown(() => DitherSquare.animate = false);

  testWidgets('reserves only its layout size so it never pushes the text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [DitherSquare(size: 8, layoutSize: 5), Text('Bash')],
        ),
      ),
    );
    final box = tester.getSize(find.byType(DitherSquare));
    expect(box, const Size(5, 5));
  });

  Future<bool> moves(
    WidgetTester tester, {
    required bool animate,
    bool reduce = false,
  }) async {
    DitherSquare.animate = animate;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          key: UniqueKey(),
          data: MediaQueryData(disableAnimations: reduce),
          child: const Align(
            alignment: Alignment.topLeft,
            child: DitherSquare(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final moving = tester.binding.hasScheduledFrame;
    await tester.pumpWidget(const SizedBox());
    return moving;
  }

  testWidgets('a still frame in tests', (tester) async {
    expect(await moves(tester, animate: false), isFalse);
  });

  testWidgets('a still frame under reduce motion', (tester) async {
    expect(await moves(tester, animate: true, reduce: true), isFalse);
  });

  testWidgets('shimmers when animation is allowed', (tester) async {
    expect(await moves(tester, animate: true), isTrue);
  });
}
