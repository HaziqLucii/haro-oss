import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/theme/tokens.dart';

import '../../../../data/pr_poll_api.dart';
import 'ship_harness.dart';

Finder key(String k) => find.byKey(ValueKey(k));

String title(WidgetTester tester) =>
    tester.widget<Text>(key('ship-title')).data ?? '';

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('merging on github.com flips the step to merged on its own', (
    tester,
  ) async {
    final api = PrPollApi([openPr(), openPr(merged: true)]);
    await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    expect(find.text('View #232 ↗'), findsOneWidget);
    expect(title(tester), isNot(startsWith('Merged')));

    await tester.pump(HaroTokens.prPollInterval);
    await tester.pumpAndSettle();
    expect(api.calls, 2);
    expect(title(tester), startsWith('Merged into'));
    await unmount(tester);
  });

  testWidgets('the last good PR stays on screen when a re-read fails', (
    tester,
  ) async {
    final api = PrPollApi([openPr(), const HaroApiException(500, 'boom')]);
    await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    await tester.pump(HaroTokens.prPollInterval);
    await tester.pump();
    expect(api.calls, greaterThanOrEqualTo(2));
    expect(find.text('View #232 ↗'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('no polling when the workspace has no PR', (tester) async {
    final api = PrPollApi([noPr()]);
    await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    await tester.pump(HaroTokens.prPollInterval * 3);
    expect(api.calls, 1);
    await unmount(tester);
  });

  testWidgets('leaving the ship step stops the polling', (tester) async {
    final api = PrPollApi([openPr()]);
    final router = await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    router.go('/w/ws_1/verify');
    await tester.pumpAndSettle();
    await tester.pump(HaroTokens.prPollInterval * 3);
    expect(api.calls, 1);
    await unmount(tester);
  });

  testWidgets('regaining focus re-reads the PR at once', (tester) async {
    final api = PrPollApi([openPr(), openPr(merged: true)]);
    await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    expect(api.calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(api.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(api.calls, 2);
    expect(title(tester), startsWith('Merged into'));
    await unmount(tester);
  });

  testWidgets('no poll tick runs while the app is backgrounded', (
    tester,
  ) async {
    final api = PrPollApi([openPr(), openPr(merged: true)]);
    await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(HaroTokens.prPollInterval * 3);
    expect(api.calls, 1);
    await unmount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
