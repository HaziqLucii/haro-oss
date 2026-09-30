import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/theme/haro_theme.dart';

Widget _host(void Function(BuildContext) onOpen) => MaterialApp(
  theme: buildHaroTheme(),
  home: Builder(
    builder: (context) => Center(
      child: GestureDetector(
        onTap: () => onOpen(context),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() => haroOverlayDepth.value = 0);

  testWidgets('shows the child and closes on Esc', (tester) async {
    await tester.pumpWidget(
      _host(
        (c) => showHaroOverlay<void>(c, width: 400, child: const Text('panel')),
      ),
    );
    await open(tester);
    expect(find.text('panel'), findsOneWidget);
    expect(haroOverlayDepth.value, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('panel'), findsNothing);
    expect(haroOverlayDepth.value, 0);
  });

  testWidgets('closes on a click outside, not inside', (tester) async {
    await tester.pumpWidget(
      _host(
        (c) => showHaroOverlay<void>(c, width: 400, child: const Text('panel')),
      ),
    );
    await open(tester);

    await tester.tap(find.text('panel'));
    await tester.pumpAndSettle();
    expect(find.text('panel'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('panel'), findsNothing);
  });

  testWidgets('fades in without moving', (tester) async {
    await tester.pumpWidget(
      _host(
        (c) => showHaroOverlay<void>(c, width: 400, child: const Text('panel')),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final early = tester.getTopLeft(find.text('panel'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('panel')), early);
    expect(find.byType(SlideTransition), findsNothing);
    expect(find.byType(ScaleTransition), findsNothing);
  });

  testWidgets('a non-dismissible overlay ignores Esc', (tester) async {
    await tester.pumpWidget(
      _host(
        (c) => showHaroOverlay<void>(
          c,
          width: 400,
          dismissible: false,
          child: const Text('panel'),
        ),
      ),
    );
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('panel'), findsOneWidget);
  });

  testWidgets('closeHaroOverlay returns a result', (tester) async {
    int? result;
    await tester.pumpWidget(
      _host(
        (c) async => result = await showHaroOverlay<int>(
          c,
          width: 400,
          child: Builder(
            builder: (c) => GestureDetector(
              onTap: () => closeHaroOverlay(c, 7),
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await open(tester);
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();
    expect(result, 7);
  });
}
