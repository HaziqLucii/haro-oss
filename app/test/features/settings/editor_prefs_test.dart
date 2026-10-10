import 'package:flutter/widgets.dart' show ValueKey;
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
      expect(p.formatOnSave, isFalse);
    });

    test('round-trips through json', () {
      const p = EditorPrefs(fontSize: 15, minimap: false);
      final back = EditorPrefs.fromJson(p.toJson());
      expect(back.fontSize, 15);
      expect(back.minimap, isFalse);
    });

    test('format on save round-trips and a missing key reads as off', () {
      const p = EditorPrefs(formatOnSave: true);
      expect(EditorPrefs.fromJson(p.toJson()).formatOnSave, isTrue);
      expect(EditorPrefs.fromJson(const {}).formatOnSave, isFalse);
      expect(p.copyWith(fontSize: 14).formatOnSave, isTrue);
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
      expect(find.byKey(const ValueKey('scope-tag')), findsNothing);
    });

    testWidgets('font size and minimap save to the device file', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.editor);
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SettingToggle).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = o.prefs.data['editor'] as Map;
      expect(saved['font_size'], 15);
      expect(saved['minimap'], false);
      expect(saved['word_wrap'], false);
    });

    testWidgets('word wrap is a second toggle that saves and loads back', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.editor);
      expect(find.text('Word wrap'), findsOneWidget);
      await tester.tap(find.byType(SettingToggle).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = o.prefs.data['editor'] as Map;
      expect(saved['word_wrap'], true);
      expect(saved['format_on_save'], false);
      expect(saved['minimap'], true);
      expect(
        EditorPrefs.fromJson(saved.cast<String, Object?>()).wordWrap,
        true,
      );
    });

    testWidgets('format on save is off, explains itself, and persists', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.editor);
      expect(find.text('Format on save (TS/JS)'), findsOneWidget);
      expect(
        find.text(
          'Off by default: can disagree with your prettier or eslint style',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<SettingToggle>(find.byType(SettingToggle).last).value,
        isFalse,
      );
      await tester.tap(find.byType(SettingToggle).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = o.prefs.data['editor'] as Map;
      expect(saved['format_on_save'], true);
      expect(saved['word_wrap'], false);
      expect(
        EditorPrefs.fromJson(saved.cast<String, Object?>()).formatOnSave,
        true,
      );
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
