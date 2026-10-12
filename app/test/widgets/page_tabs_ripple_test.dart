import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_pressable.dart';
import 'package:haro_app/widgets/page_tabs.dart';

void main() {
  testWidgets('a tab ripples across its own height, not past the hairline', (
    tester,
  ) async {
    HaroTokens.apply(HaroPalette.material3);
    addTearDown(() => HaroTokens.apply(HaroPalette.haro));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaroTheme(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: PageTabBar(
                tabs: const [
                  PageTab('TODO FILES', count: 3, tabKey: Key('t0')),
                  PageTab('NOTES', tabKey: Key('t1')),
                ],
                selected: 0,
                onPick: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final tab = tester.getRect(find.byKey(const Key('t1')));
    final press = await tester.startGesture(tab.center);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    final clip = rippleClipBounds(
      tester.widget<CustomPaint>(find.byKey(const ValueKey('ripple'))).painter,
    )!.single;
    // In the tab's own coordinates: its full height, ten pixels of room either side.
    expect(
      clip,
      rectMoreOrLessEquals(
        Rect.fromLTRB(-10, 0, tab.width + 10, tab.height),
        epsilon: .01,
      ),
    );
    // Clear of the tab beside it, whose edge is 28 px away.
    expect(
      tab.left - 10,
      greaterThan(tester.getRect(find.byKey(const Key('t0'))).right),
    );
    await press.cancel();
    await tester.pumpAndSettle();
  });
}
