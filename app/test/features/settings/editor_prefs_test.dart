import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/editor_prefs_provider.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import 'settings_harness.dart';

void main() {
  group('EditorPrefs', () {
    test('defaults are the shipped look', () {
      const p = EditorPrefs();
      expect(p.fontSize, 13);
      expect(p.minimap, isTrue);
    });

    test('round-trips through json', () {
      const p = EditorPrefs(fontSize: 15, minimap: false);
      final back = EditorPrefs.fromJson(p.toJson());
      expect(back.fontSize, 15);
      expect(back.minimap, isFalse);
    });

    test('a hand-edited size outside 12 to 15 is clamped', () {
      expect(EditorPrefs.fromJson({'font_size': 40}).fontSize, 15);
      expect(EditorPrefs.fromJson({'font_size': 3}).fontSize, 12);
    });

    test('a missing block reads as the defaults', () {
      final p = EditorPrefs.fromJson(const {});
      expect(p.fontSize, 13);
      expect(p.minimap, isTrue);
    });
  });

  group('provider', () {
    test('loads the stored prefs after start', () async {
      final store = MemoryDevicePrefsStore({
        'editor': {'font_size': 14, 'minimap': false},
      });
      final c = ProviderContainer(
        overrides: [devicePrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      expect(c.read(editorPrefsProvider).fontSize, 13);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(editorPrefsProvider).fontSize, 14);
      expect(c.read(editorPrefsProvider).minimap, isFalse);
    });

    test(
      'a save that lands before the first read is not overwritten',
      () async {
        final store = MemoryDevicePrefsStore({
          'editor': {'font_size': 12},
        });
        final c = ProviderContainer(
          overrides: [devicePrefsStoreProvider.overrideWithValue(store)],
        );
        addTearDown(c.dispose);
        c.read(editorPrefsProvider);
        c
            .read(editorPrefsProvider.notifier)
            .set(const EditorPrefs(fontSize: 15));
        await Future<void>.delayed(Duration.zero);
        expect(c.read(editorPrefsProvider).fontSize, 15);
      },
    );
  });

  group('Settings, Editor tab', () {
    testWidgets('sits right after Display in the App group', (tester) async {
      await openSettings(tester);
      final labels = [
        for (final t in SettingsTab.values.where((t) => !t.project)) t.label,
      ];
      expect(labels.take(3), ['Display', 'Editor', 'Notifications']);
      await goTab(tester, 'Editor');
      expect(find.text('Font size'), findsOneWidget);
      expect(find.text('Minimap'), findsOneWidget);
      expect(find.text('This device'), findsWidgets);
    });

    testWidgets('font size and minimap save to the device file', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.editor);
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SettingToggle));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = o.prefs.data['editor'] as Map;
      expect(saved['font_size'], 15);
      expect(saved['minimap'], false);
    });

    testWidgets('unknown device keys survive an Editor save', (tester) async {
      final o = await openSettings(
        tester,
        tab: SettingsTab.editor,
        prefs: MemoryDevicePrefsStore({
          'display': {'density': 'compact'},
        }),
      );
      await tester.tap(find.text('14'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((o.prefs.data['display'] as Map)['density'], 'compact');
      expect((o.prefs.data['editor'] as Map)['font_size'], 14);
    });
  });
}
