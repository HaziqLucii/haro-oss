import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/status_square.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildHaroTheme(),
  home: Material(
    color: HaroTokens.bg,
    child: Center(child: child),
  ),
);

BoxDecoration _decoration(WidgetTester tester) =>
    tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).decoration!
        as BoxDecoration;

void main() {
  testWidgets('StatusSquare: filled only for settled states', (tester) async {
    Future<ShapeDecoration> deco(DisplayState s) async {
      await tester.pumpWidget(_wrap(StatusSquare.forState(s)));
      return tester.widget<DecoratedBox>(find.byType(DecoratedBox)).decoration
          as ShapeDecoration;
    }

    expect((await deco(DisplayState.green)).color, HaroTokens.gate);
    expect((await deco(DisplayState.red)).color, HaroTokens.fail);
    expect((await deco(DisplayState.agent)).color, const Color(0x00000000));
    final idle = await deco(DisplayState.idle);
    expect((idle.shape as OutlinedBorder).side.color, HaroTokens.ink42);
  });

  testWidgets('StatusSquare is a squircle, filled or hollow', (tester) async {
    for (final size in [5.0, 9.0, 18.0]) {
      for (final filled in [true, false]) {
        await tester.pumpWidget(
          _wrap(
            StatusSquare(size: size, color: HaroTokens.gate, filled: filled),
          ),
        );
        expect(tester.getSize(find.byType(StatusSquare)), Size.square(size));
        final d =
            tester.widget<DecoratedBox>(find.byType(DecoratedBox)).decoration
                as ShapeDecoration;
        final shape = d.shape as RoundedSuperellipseBorder;
        expect(
          shape.borderRadius,
          BorderRadius.circular(size * HaroTokens.markCorner),
        );
        expect(shape.side.color, HaroTokens.gate);
        expect(shape.side.width, 1);
        expect(d.color, filled ? HaroTokens.gate : HaroTokens.transparent);
      }
    }
  });

  testWidgets('primary button is bone with dark text', (tester) async {
    await tester.pumpWidget(
      _wrap(
        HaroButton(
          variant: HaroButtonVariant.primary,
          label: 'Go',
          onPressed: () {},
        ),
      ),
    );
    expect(_decoration(tester).color, HaroTokens.ink);
  });

  testWidgets('secondary button border brightens on hover', (tester) async {
    await tester.pumpWidget(_wrap(HaroButton(label: 'Go', onPressed: () {})));
    expect(_decoration(tester).border!.top.color, HaroTokens.line14);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(HaroButton)));
    await tester.pumpAndSettle();
    expect(_decoration(tester).border!.top.color, HaroTokens.line30);
  });

  testWidgets('tertiary button has no fill or border', (tester) async {
    await tester.pumpWidget(
      _wrap(
        HaroButton(
          variant: HaroButtonVariant.tertiary,
          label: 'Go',
          onPressed: () {},
        ),
      ),
    );
    final d = _decoration(tester);
    expect(d.border, isNull);
    expect(d.color, const Color(0x00000000));
  });
}
