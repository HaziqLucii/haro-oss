import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/settings/settings_overlay.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import 'settings_harness.dart';

final _picker = find.byKey(const ValueKey('project-picker'));
final _bar = find.byKey(const ValueKey('save-bar'));
final _projectGets = RegExp(r'^/projects/p\d/');

String _tag(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('scope-tag'))).data!;

Iterable<String> _projectTabRequests(FakeBackend b) => b.log
    .where((r) => r.method == 'GET' && _projectGets.hasMatch(r.url.path))
    .map((r) => r.url.path);

Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(_picker);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _tapToggle(WidgetTester tester, String label) async {
  final f = find.byWidgetPredicate(
    (w) => w is SettingToggle && w.semanticLabel == label,
  );
  await tester.ensureVisible(f);
  await tester.tap(f);
}

const _both = [proj1, proj2];

void main() {
  setUpAll(loadBrandFonts);

  test('paths under home read as ~', () {
    expect(tildePath('/Users/h/Projects/haro', '/Users/h'), '~/Projects/haro');
    expect(tildePath('/Users/h', '/Users/h'), '~');
    expect(tildePath('/Users/hh/x', '/Users/h'), '/Users/hh/x');
    expect(tildePath('/x/haro', null), '/x/haro');
  });

  group('no project context', () {
    testWidgets(
      'opens on Display with the project tabs disabled and untouched',
      (tester) async {
        final o = await openSettings(tester, projects: _both);
        expect(find.text('Display'), findsWidgets);
        expect(find.byKey(const ValueKey('scope-tag')), findsNothing);
        expect(find.text('PROJECT · CHOOSE'), findsOneWidget);
        expect(find.text('Choose a project'), findsOneWidget);
        expect(find.byTooltip('Pick a project first'), findsNWidgets(7));

        await goTab(tester, 'Gate');
        await goTab(tester, 'Git');
        expect(
          find.byKey(const ValueKey('scope-tag')),
          findsNothing,
          reason: 'disabled tabs do not open',
        );
        expect(_projectTabRequests(o.backend), isEmpty);
      },
    );

    testWidgets('picking a project enables the tabs and loads that project', (
      tester,
    ) async {
      final o = await openSettings(tester, projects: _both);
      await _pick(tester, 'sandbox · /x/sandbox');
      expect(find.text('PROJECT · SANDBOX'), findsOneWidget);
      expect(find.byTooltip('Pick a project first'), findsNothing);
      expect(_projectTabRequests(o.backend), isEmpty, reason: 'still lazy');

      await goTab(tester, 'Gate');
      expect(find.text('Gate · sandbox'), findsOneWidget);
      expect(_projectTabRequests(o.backend), contains('/projects/p2/gate'));
      expect(
        _projectTabRequests(o.backend)
            .where((p) => p.startsWith('/projects/p1')),
        isEmpty,
      );
    });

    testWidgets('a deep link to Gate waits for the pick, then lands on Gate', (
      tester,
    ) async {
      final o = await openSettings(
        tester,
        projects: _both,
        tab: SettingsTab.gate,
      );
      expect(find.text('Gate'), findsNWidgets(2), reason: 'nav item and title');
      expect(
        find.textContaining('Choose a project in the Project group'),
        findsOneWidget,
      );
      expect(_projectTabRequests(o.backend), isEmpty);

      await _pick(tester, 'haro · /x/haro');
      expect(find.text('Gate · haro'), findsOneWidget);
      expect(_projectTabRequests(o.backend), contains('/projects/p1/gate'));
      expect(
        find.textContaining(
          'every Vitest test in frontend/ passes',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('a requested App tab still wins', (tester) async {
      await openSettings(tester, projects: _both, tab: SettingsTab.usage);
      expect(find.text('Usage'), findsWidgets);
      expect(_tag(tester), 'Read only');
    });
  });

  group('project context', () {
    testWidgets('a given project opens on its requested tab', (tester) async {
      final o = await openSettings(
        tester,
        projects: _both,
        projectId: 'p2',
        tab: SettingsTab.gate,
      );
      expect(find.text('PROJECT · SANDBOX'), findsOneWidget);
      expect(find.text('Gate · sandbox'), findsOneWidget);
      expect(_projectTabRequests(o.backend), ['/projects/p2/gate']);
    });

    testWidgets(
      'exactly one project is picked automatically and still labelled',
      (tester) async {
        await openSettings(tester);
        expect(find.text('PROJECT · HARO'), findsOneWidget);
        expect(find.text('haro · /x/haro'), findsOneWidget);
        expect(find.byTooltip('Pick a project first'), findsNothing);
        await goTab(tester, 'Agent');
        expect(find.text('Agent · haro'), findsOneWidget);
      },
    );

    testWidgets(
      'an unknown project id falls back to choosing, not to the first',
      (tester) async {
        await openSettings(tester, projects: _both, projectId: 'nope');
        expect(find.text('PROJECT · CHOOSE'), findsOneWidget);
      },
    );

    testWidgets('every project tab names its project in the header', (
      tester,
    ) async {
      await openSettings(tester, projects: _both, projectId: 'p1');
      for (final t in SettingsTab.values.where((t) => t.project)) {
        await goTab(tester, t.label);
        expect(find.text('${t.label} · haro'), findsOneWidget, reason: t.label);
      }
      await goTab(tester, 'Display');
      expect(find.text('Display'), findsWidgets);
      expect(find.textContaining('Display ·'), findsNothing);
    });

    testWidgets('switching is blocked while project tabs have unsaved edits', (
      tester,
    ) async {
      await openSettings(
        tester,
        projects: _both,
        projectId: 'p1',
        tab: SettingsTab.gate,
      );
      await _tapToggle(tester, 'Flaky guard');
      await tester.pumpAndSettle();
      await _pick(tester, 'sandbox · /x/sandbox');
      expect(find.text('PROJECT · HARO'), findsOneWidget, reason: 'blocked');
      expect(find.textContaining('save or discard them first'), findsOneWidget);
      expect(_bar, findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      await _pick(tester, 'sandbox · /x/sandbox');
      expect(find.text('PROJECT · SANDBOX'), findsOneWidget);
      expect(find.text('Gate · sandbox'), findsOneWidget);
      expect(
        find.textContaining(
          'every Vitest test in web/ passes',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('the picker state has no overflow at 960x640', (tester) async {
    await openSettings(
      tester,
      projects: _both,
      tab: SettingsTab.gate,
      size: const Size(960, 640),
    );
    expect(tester.takeException(), isNull);
    await _pick(tester, 'haro · /x/haro');
    expect(tester.takeException(), isNull);
    for (final t in SettingsTab.values) {
      await goTab(tester, t.label);
      expect(tester.takeException(), isNull, reason: t.label);
    }
  });
}
