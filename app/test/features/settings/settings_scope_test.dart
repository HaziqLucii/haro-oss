import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/controls/segmented.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/settings_controller.dart';
import 'package:haro_app/features/settings/settings_layers.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import 'settings_harness.dart';

final _bar = find.byKey(const ValueKey('save-bar'));
Finder _toggle(String label) => find.byWidgetPredicate(
  (w) => w is SettingToggle && w.semanticLabel == label,
);
Future<void> _tapToggle(WidgetTester tester, String label) async {
  await tester.ensureVisible(_toggle(label));
  await tester.tap(_toggle(label));
}

Finder _scopeTag() => find.byKey(const ValueKey('scope-tag'));
String _tag(WidgetTester t) => t.widget<Text>(_scopeTag()).data!;

void main() {
  setUpAll(loadBrandFonts);

  group('Team / Personal save target (Agent, Gate, Roles)', () {
    testWidgets('the switch changes the PUT target and the scope tag', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.agent);
      expect(_tag(tester), 'Team · .haro/settings.toml');

      await tester.tap(find.text('Personal'));
      await tester.pumpAndSettle();
      expect(_tag(tester), 'Personal · .haro/settings.local.toml');
      expect(_bar, findsNothing, reason: 'switching the target is not an edit');

      await tester.tap(find.text('Sonnet'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _bar,
          matching: find.textContaining('Personal · .haro/settings.local.toml'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final put = o.backend.puts('/projects/p1/agent').single;
      expect(o.backend.body(put)['target'], 'local');
      expect(o.backend.body(put)['default_model'], 'sonnet');
    });

    testWidgets('the same edit on Team goes to the shared target', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.roles);
      await _tapToggle(tester, 'Use roles');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        o.backend.body(o.backend.puts('/projects/p1/roles').single)['target'],
        'shared',
      );
    });

    testWidgets(
      'with a personal layer in play Team is off and nothing shared is ever sent',
      (tester) async {
        final layers = FakeLayers(safe: false);
        final o = await openSettings(
          tester,
          layers: layers,
          tab: SettingsTab.agent,
        );
        expect(_tag(tester), 'Personal · .haro/settings.local.toml');
        expect(find.textContaining('Team is off'), findsOneWidget);
        final seg = tester.widget<SettingSegmented<String>>(
          find.byWidgetPredicate(
            (w) => w is SettingSegmented<String> && w.disabled.isNotEmpty,
          ),
        );
        expect(seg.disabled, {'shared'});
        expect(seg.value, 'local');

        await tester.tap(find.text('Team'));
        await tester.pumpAndSettle();
        expect(_tag(tester), startsWith('Personal'), reason: 'Team ignored');

        await tester.tap(find.text('Sonnet'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final puts = o.backend.puts('/projects/p1/agent').toList();
        expect(puts, hasLength(1));
        expect(o.backend.body(puts.single)['target'], 'local');
        expect(
          o.backend.log.where(
            (r) => r.method != 'GET' && r.body.contains('"shared"'),
          ),
          isEmpty,
        );
        expect(layers.asked.first, ['agent']);
      },
    );

    test(
      'a forced shared save is refused when the personal layer is unsafe',
      () async {
        final backend = FakeBackend();
        final c = SettingsController(
          api: backend.api(),
          devicePrefs: MemoryDevicePrefsStore(),
          projects: const [proj1],
          layers: FakeLayers(safe: false),
        );
        addTearDown(c.dispose);
        final s = c.config<ScopedDraft<AgentConfig>>(SettingsTab.agent);
        await s.load();
        expect(s.draft.target, 'local');
        s.edit(
          (d) => d
              .withValue(
                AgentConfig.fromJson({
                  ...d.value.toJson(),
                  'default_model': 'haiku',
                }),
              )
              .withTarget('shared'),
        );
        await c.saveAll();
        expect(backend.log.where((r) => r.method != 'GET'), isEmpty);
        expect(c.saveError, contains('Team saving is unavailable'));
        expect(s.dirty, isTrue);
      },
    );

    test('the safety check runs again at save time', () async {
      final backend = FakeBackend();
      final layers = FakeLayers(safe: true);
      final c = SettingsController(
        api: backend.api(),
        devicePrefs: MemoryDevicePrefsStore(),
        projects: const [proj1],
        layers: layers,
      );
      addTearDown(c.dispose);
      final s = c.config<ScopedDraft<GateConfig>>(SettingsTab.gate);
      await s.load();
      expect(s.draft.target, 'shared');
      s.edit(
        (d) => d.withValue(
          GateConfig.fromJson({...d.value.toJson(), 'flaky_rerun': true}),
        ),
      );
      layers.safe = false;
      await c.saveAll();
      expect(backend.puts('/projects/p1/gate'), isEmpty);
    });

    testWidgets('Gate and Roles ask about their own tables', (tester) async {
      final layers = FakeLayers();
      await openSettings(tester, layers: layers, tab: SettingsTab.gate);
      expect(layers.asked.single, ['gate', 'workflow']);
      await tester.tap(
        find.descendant(
          of: find.byType(ListView).first,
          matching: find.text('Roles'),
        ),
      );
      await tester.pumpAndSettle();
      expect(layers.asked.last, ['roles']);
    });
  });

  group('layer reader', () {
    test('detects tables however they are written', () {
      expect(tablesDeclared('[agent]\nadapter = "local"\n', ['agent']), isTrue);
      expect(tablesDeclared('  [ agent.x ]\n', ['agent']), isTrue);
      expect(tablesDeclared('agent.adapter = "local"\n', ['agent']), isTrue);
      expect(
        tablesDeclared('agent = { adapter = "local" }\n', ['agent']),
        isTrue,
      );
      expect(tablesDeclared('[roles]\nplan = "x"\n', ['agent']), isFalse);
      expect(tablesDeclared('# [agent] in a comment\n', ['agent']), isFalse);
      expect(
        tablesDeclared('[workflow]\nmerge_mode = "pr"\n', ['gate', 'workflow']),
        isTrue,
      );
      expect(tablesDeclared('[scripts]\nagent_x = 1\n', ['agent']), isFalse);
    });

    late Directory dir;
    late Project project;
    late String globalPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('haro_layers');
      Directory('${dir.path}/proj/.haro').createSync(recursive: true);
      project = Project(
        id: 'p',
        name: 'p',
        path: '${dir.path}/proj',
        defaultBranch: 'main',
      );
      globalPath = '${dir.path}/global.toml';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'safe only when neither the personal nor the global file sets the table',
      () async {
        final r = FileSettingsLayerReader(globalPath: globalPath);
        expect(
          await r.teamWriteSafe(project, ['agent']),
          isTrue,
          reason: 'no files',
        );

        File('${dir.path}/proj/.haro/settings.local.toml')
            .writeAsStringSync('[roles]\nplan = "x"\n');
        expect(await r.teamWriteSafe(project, ['agent']), isTrue);
        expect(await r.teamWriteSafe(project, ['roles']), isFalse);

        File('${dir.path}/proj/.haro/settings.local.toml')
            .writeAsStringSync('[agent]\nlocal_model = "q"\n');
        expect(await r.teamWriteSafe(project, ['agent']), isFalse);

        File('${dir.path}/proj/.haro/settings.local.toml').deleteSync();
        File(globalPath).writeAsStringSync('[agent]\ndefault_model = "opus"\n');
        expect(await r.teamWriteSafe(project, ['agent']), isFalse);
      },
    );

    test(
      'a project folder this machine cannot see is unknown, not clean',
      () async {
        final r = FileSettingsLayerReader(globalPath: globalPath);
        final ghost = Project(
          id: 'g',
          name: 'g',
          path: '${dir.path}/not-here',
          defaultBranch: 'main',
        );
        expect(await r.teamWriteSafe(ghost, ['agent']), isFalse);
      },
    );
  });

  group('Setup is never written', () {
    testWidgets('no PUT to scripts from any interaction on the tab', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.setup);
      expect(_tag(tester), 'Read only');
      expect(_bar, findsNothing);
      expect(o.backend.puts('/projects/p1/scripts'), isEmpty);
    });
  });

  group('Git base branch', () {
    testWidgets('comes from the project record, not the branches list', (
      tester,
    ) async {
      final be = FakeBackend();
      (be.routes['/projects']! as List)[0]['default_branch'] = 'dev';
      be.routes['/projects/p1/branches'] = {
        'branches': ['main', 'dev'],
        'default': 'main',
      };
      await openSettings(tester, backend: be, tab: SettingsTab.git);
      final selects = find.text('dev');
      expect(selects, findsOneWidget);
    });

    testWidgets('falls back to the project handed to the overlay', (
      tester,
    ) async {
      final be = FakeBackend()..failingGet['/projects'] = 500;
      be.routes['/projects/p1/branches'] = {
        'branches': ['main', 'dev'],
        'default': 'dev',
      };
      await openSettings(tester, backend: be, tab: SettingsTab.git);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('dev'), findsNothing);
    });
  });
}
