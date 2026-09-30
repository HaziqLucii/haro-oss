import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/xp_prefs_provider.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import '../../api/xp_api_test.dart' show rulesJson;
import 'settings_harness.dart';

void main() {
  group('XpPrefs', () {
    test('XP and the reminder are on by default', () {
      const p = XpPrefs();
      expect(p.showXp, isTrue);
      expect(p.streakReminder, isTrue);
    });

    test(
      'round-trips through json and a missing block reads as the defaults',
      () {
        final back = XpPrefs.fromJson(
          const XpPrefs(showXp: false, streakReminder: false).toJson(),
        );
        expect(back.showXp, isFalse);
        expect(back.streakReminder, isFalse);
        final none = XpPrefs.fromJson(const {});
        expect(none.showXp && none.streakReminder, isTrue);
      },
    );
  });

  group('provider', () {
    test('loads the stored prefs after start', () async {
      final c = ProviderContainer(
        overrides: [
          devicePrefsStoreProvider.overrideWithValue(
            MemoryDevicePrefsStore({
              'xp': {'show_xp': false},
            }),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(xpPrefsProvider).showXp, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(xpPrefsProvider).showXp, isFalse);
    });

    test(
      'a save that lands before the first read is not overwritten',
      () async {
        final c = ProviderContainer(
          overrides: [
            devicePrefsStoreProvider.overrideWithValue(
              MemoryDevicePrefsStore({
                'xp': {'show_xp': false},
              }),
            ),
          ],
        );
        addTearDown(c.dispose);
        c.read(xpPrefsProvider);
        c.read(xpPrefsProvider.notifier).set(const XpPrefs());
        await Future<void>.delayed(Duration.zero);
        expect(c.read(xpPrefsProvider).showXp, isTrue);
      },
    );
  });

  group('Settings, XP tab', () {
    testWidgets('is an App tab with the two switches and the rules row', (
      tester,
    ) async {
      await openSettings(tester);
      final labels = [
        for (final t in SettingsTab.values.where((t) => !t.project)) t.label,
      ];
      expect(labels, contains('XP'));
      await goTab(tester, 'XP');
      expect(find.text('Show XP'), findsOneWidget);
      expect(find.text('Streak reminder'), findsOneWidget);
      expect(find.text('How XP works'), findsOneWidget);
      expect(find.text('This device'), findsWidgets);
    });

    testWidgets('both switches save to the device file under xp', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.xp);
      final toggles = find.byType(SettingToggle);
      await tester.tap(toggles.at(0));
      await tester.pumpAndSettle();
      await tester.tap(toggles.at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(o.prefs.data['xp'], {'show_xp': false, 'streak_reminder': false});
    });

    testWidgets('unknown device keys and the nudge dismissal survive a save', (
      tester,
    ) async {
      final o = await openSettings(
        tester,
        tab: SettingsTab.xp,
        prefs: MemoryDevicePrefsStore({
          'display': {'density': 'compact'},
          'xp_nudge': {'dismissed_on': '2026-09-30'},
        }),
      );
      await tester.tap(find.byType(SettingToggle).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((o.prefs.data['display'] as Map)['density'], 'compact');
      expect((o.prefs.data['xp_nudge'] as Map)['dismissed_on'], '2026-09-30');
      expect((o.prefs.data['xp'] as Map)['streak_reminder'], false);
    });

    testWidgets('the rules row opens How XP works from the served table', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.xp);
      o.backend.routes['/xp/rules'] = rulesJson();
      await tester.tap(find.byKey(const ValueKey('xp-how')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('xp-popover')), findsOneWidget);
      expect(find.byKey(const ValueKey('xp-rule-merge_green')), findsOneWidget);
      expect(
        o.backend.log.where((r) => r.url.path == '/xp/rules'),
        hasLength(1),
      );
    });

    testWidgets('an unreachable table says so instead of hanging', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.xp);
      await tester.tap(find.byKey(const ValueKey('xp-how')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('xp-rules-status')), findsOneWidget);
      expect(find.text('The award table did not load'), findsOneWidget);
    });
  });
}
