import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/haro_pressable.dart';

Future<MouseCursor> cursorOver(WidgetTester tester, Finder at) async {
  final mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    pointer: 1,
  );
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(at));
  await tester.pump();
  return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;
}

void main() {
  testWidgets('a pressable shows the click cursor inside a SelectionArea', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          child: Center(
            child: HaroPressable(
              onTap: () {},
              builder: (context, hovered) =>
                  const Text('Open it', key: ValueKey('t')),
            ),
          ),
        ),
      ),
    );
    expect(
      await cursorOver(tester, find.byKey(const ValueKey('t'))),
      SystemMouseCursors.click,
    );
  });

  testWidgets('so does a button, and the text is not selectable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          child: Center(
            child: HaroButton(
              key: const ValueKey('b'),
              label: 'Restore',
              variant: HaroButtonVariant.control,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    expect(
      await cursorOver(tester, find.byKey(const ValueKey('b'))),
      SystemMouseCursors.click,
    );
  });

  testWidgets('an unpressable one does not claim the click cursor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: HaroPressable(
            onTap: null,
            builder: (context, hovered) =>
                const Text('Nope', key: ValueKey('t')),
          ),
        ),
      ),
    );
    expect(
      await cursorOver(tester, find.byKey(const ValueKey('t'))),
      isNot(SystemMouseCursors.click),
    );
  });
}
