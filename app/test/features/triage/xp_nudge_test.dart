import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/triage/xp_nudge.dart';
import 'package:haro_app/theme/haro_theme.dart';

import '../../api/xp_api_test.dart' show xpJson;
import '../../shell/xp_shell_test.dart' show FakeXpStore;

final nudge = find.byKey(const ValueKey('xp-nudge'));

Future<MemoryDevicePrefsStore> pumpNudge(
  WidgetTester tester, {
  XpState? xp,
  Json? prefs,
  String today = '2026-09-30',
}) async {
  final store = MemoryDevicePrefsStore(prefs);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        xpStoreProvider.overrideWith(
          () => FakeXpStore(
            xp ??
                XpState(
                  status: XpStatus.fromJson(xpJson(today: false, days: 14)),
                ),
          ),
        ),
        devicePrefsStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        theme: buildHaroTheme(),
        home: Scaffold(body: XpNudge(today: today)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

XpState stateWith({int days = 3, bool today = false}) => XpState(
  status: XpStatus.fromJson(xpJson(days: days, today: today)),
);

void main() {
  test('the day key is the zero-padded local date', () {
    expect(xpDayKey(DateTime(2026, 3, 8, 23, 59)), '2026-03-08');
    expect(xpDayKey(DateTime(2026, 12, 31)), '2026-12-31');
  });

  testWidgets('names the streak and asks for one by hand', (tester) async {
    await pumpNudge(tester);
    expect(
      find.text('Your streak is 14 days. Finish one by hand today.'),
      findsOneWidget,
    );
  });

  testWidgets('singular day', (tester) async {
    await pumpNudge(tester, xp: stateWith(days: 1));
    expect(
      find.text('Your streak is 1 day. Finish one by hand today.'),
      findsOneWidget,
    );
  });

  testWidgets('no streak yet', (tester) async {
    await pumpNudge(tester, xp: stateWith(days: 0));
    expect(
      find.text('No streak yet. Finish one by hand today.'),
      findsOneWidget,
    );
  });

  testWidgets('gone once today has its by-hand merge', (tester) async {
    await pumpNudge(tester, xp: stateWith(today: true));
    expect(nudge, findsNothing);
  });

  testWidgets('gone before the backend answers', (tester) async {
    await pumpNudge(tester, xp: const XpState());
    expect(nudge, findsNothing);
  });

  testWidgets('the streak reminder switch hides it', (tester) async {
    await pumpNudge(
      tester,
      prefs: {
        'xp': {'streak_reminder': false},
      },
    );
    expect(nudge, findsNothing);
  });

  testWidgets('Show XP off hides it too', (tester) async {
    await pumpNudge(
      tester,
      prefs: {
        'xp': {'show_xp': false},
      },
    );
    expect(nudge, findsNothing);
  });

  testWidgets('dismissing hides it for the day and remembers on disk', (
    tester,
  ) async {
    final store = await pumpNudge(tester);
    await tester.tap(find.byKey(const ValueKey('xp-nudge-dismiss')));
    await tester.pumpAndSettle();
    expect(nudge, findsNothing);
    expect(store.data['xp_nudge'], {'dismissed_on': '2026-09-30'});
    expect(store.data.containsKey('xp'), isFalse);
  });

  testWidgets('a dismissal from earlier today is honoured on load', (
    tester,
  ) async {
    await pumpNudge(
      tester,
      prefs: {
        'xp_nudge': {'dismissed_on': '2026-09-30'},
      },
    );
    expect(nudge, findsNothing);
  });

  testWidgets('a dismissal from yesterday does not hide today\'s nudge', (
    tester,
  ) async {
    await pumpNudge(
      tester,
      prefs: {
        'xp_nudge': {'dismissed_on': '2026-09-29'},
      },
    );
    expect(nudge, findsOneWidget);
  });
}
