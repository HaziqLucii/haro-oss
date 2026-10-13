import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/agent_loader.dart';
import 'package:haro_app/widgets/dither_square.dart';

void main() {
  tearDown(() {
    DitherSquare.animate = false;
    HaroTokens.apply(HaroPalette.haro);
  });

  Future<void> pumpLoader(
    WidgetTester tester, {
    bool animate = false,
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
            child: Row(
              children: [AgentLoader(size: 16, layoutSize: 5), Text('Bash')],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('reserves only its layout size', (tester) async {
    await pumpLoader(tester);
    expect(tester.getSize(find.byType(AgentLoader)), const Size(5, 5));
  });

  for (final p in [
    HaroPalette.haro,
    HaroPalette.material3,
    HaroPalette.paper,
  ]) {
    testWidgets('${p.boot} draws a still frame in tests', (tester) async {
      HaroTokens.apply(p);
      await pumpLoader(tester);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${p.boot} moves when animation is allowed', (tester) async {
      HaroTokens.apply(p);
      await pumpLoader(tester, animate: true);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('${p.boot} stops under reduce motion', (tester) async {
      HaroTokens.apply(p);
      await pumpLoader(tester, animate: true, reduce: true);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('Paper cycles the braille frame', (tester) async {
    HaroTokens.apply(HaroPalette.paper);
    await pumpLoader(tester, animate: true);
    int frame() =>
        (tester
                    .widget<CustomPaint>(
                      find.descendant(
                        of: find.byType(AgentLoader),
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .painter!
                as BraillePainter)
            .frame;
    final first = frame();
    await tester.pump(const Duration(milliseconds: 200));
    expect(frame(), isNot(first));
    await tester.pumpWidget(const SizedBox());
  });
}
