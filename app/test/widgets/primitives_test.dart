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
    Future<BoxDecoration> deco(DisplayState s) async {
      await tester.pumpWidget(_wrap(StatusSquare.forState(s)));
      return tester.widget<DecoratedBox>(find.byType(DecoratedBox)).decoration
          as BoxDecoration;
    }

    expect((await deco(DisplayState.green)).color, HaroTokens.gate);
    expect((await deco(DisplayState.red)).color, HaroTokens.fail);
    expect((await deco(DisplayState.agent)).color, const Color(0x00000000));
    expect((await deco(DisplayState.idle)).border!.top.color, HaroTokens.ink42);
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
