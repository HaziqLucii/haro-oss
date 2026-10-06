import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/controls/segmented.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/settings/controls/mono_input.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/settings_overlay.dart';
import 'package:haro_app/features/settings/settings_scope.dart';
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

String _scopeText(WidgetTester tester) =>
    tester.widget<Text>(_scopeTag()).data!;

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle();

void main() {
  setUpAll(loadBrandFonts);

  group('layout', () {
    for (final size in const [Size(1400, 900), Size(960, 640)]) {
      testWidgets(
        'every tab lays out without overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await openSettings(
            tester,
            size: size,
            projects: const [proj1, proj2],
            projectId: 'p1',
          );
          for (final tab in SettingsTab.values) {
            await goTab(tester, tab.label);
            expect(tester.takeException(), isNull, reason: tab.label);
            expect(find.text('Loading…'), findsNothing, reason: tab.label);
          }
        },
      );
    }

    testWidgets(
      'the panel is 980x660 on a roomy window and clamps at 92% x 80%',
      (tester) async {
        await openSettings(tester);
        // The overlay border takes 1px on each side.
        expect(
          tester.getSize(find.byType(SettingsOverlay)),
          const Size(978, 658),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        await openSettings(tester, size: const Size(960, 640));
        final small = tester.getSize(find.byType(SettingsOverlay));
        expect(small.width, closeTo(960 * .92 - 2, .5));
        expect(small.height, closeTo(640 * .8 - 2, .5));
      },
    );
  });

  testWidgets('nav lists the app group and the project group with its name', (
    tester,
  ) async {
    await openSettings(tester);
    for (final t in SettingsTab.values) {
      expect(
        find.descendant(
          of: find.byType(ListView).first,
          matching: find.text(t.label),
        ),
        findsOneWidget,
        reason: t.label,
      );
    }
    expect(find.text('APP'), findsOneWidget);
    expect(find.text('PROJECT · HARO'), findsOneWidget);
  });

  group('header and scope tags', () {
    testWidgets('each tab names where it saves', (tester) async {
      await openSettings(tester);
      final expected = {
        'Display': SettingsScope.device,
        'Notifications': SettingsScope.device,
        'Usage': SettingsScope.readOnly,
        'System': SettingsScope.readOnly,
        'Git': SettingsScope.team,
        'Setup': SettingsScope.readOnly,
        'Gate': SettingsScope.team,
        'Agent': SettingsScope.team,
        'Roles': SettingsScope.team,
        'Environment': SettingsScope.env,
      };
      for (final e in expected.entries) {
        await goTab(tester, e.key);
        expect(_scopeText(tester), e.value.label, reason: e.key);
      }
      expect(SettingsScope.team.label, 'Team · .haro/settings.toml');
      expect(
        SettingsScope.personal.label,
        'Personal · .haro/settings.local.toml',
      );
    });

    testWidgets('the Instructions tag follows the Personal / Team pick', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.instructions);
      expect(_scopeText(tester), SettingsScope.personalInstructions.label);
      await tester.tap(find.text('Team'));
      await _settle(tester);
      expect(_scopeText(tester), SettingsScope.teamInstructions.label);
      expect(_bar, findsNothing, reason: 'switching view is not an edit');
    });

    testWidgets('titles and intros', (tester) async {
      await openSettings(tester, tab: SettingsTab.roles);
      expect(find.text('Most people never open this page.'), findsOneWidget);
      await goTab(tester, 'Setup');
      expect(find.textContaining('HARO_PORT'), findsWidgets);
    });
  });

  group('dirty tracking and the save bar', () {
    testWidgets('the bar appears on an edit and goes away when it is undone', (
      tester,
    ) async {
      await openSettings(tester);
      expect(_bar, findsNothing);
      await _tapToggle(tester, 'Film grain');
      await _settle(tester);
      expect(_bar, findsOneWidget);
      expect(find.textContaining('Unsaved changes'), findsOneWidget);
      expect(find.textContaining('saves to This device'), findsOneWidget);
      await _tapToggle(tester, 'Film grain');
      await _settle(tester);
      expect(_bar, findsNothing);
    });

    testWidgets('Discard resets the controls and hides the bar', (
      tester,
    ) async {
      await openSettings(tester);
      await tester.tap(find.text('Compact'));
      await _settle(tester);
      expect(_bar, findsOneWidget);
      await tester.tap(find.text('Discard'));
      await _settle(tester);
      expect(_bar, findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is SettingSegmented<String> && w.value == 'comfortable',
        ),
        findsOneWidget,
      );
    });

    testWidgets('edits survive a tab switch and the bar totals every tab', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.gate);
      await _tapToggle(tester, 'Flaky guard');
      await _settle(tester);
      expect(
        find.descendant(
          of: _bar,
          matching: find.textContaining(SettingsScope.team.label),
        ),
        findsOneWidget,
      );

      await goTab(tester, 'Environment');
      expect(_bar, findsOneWidget, reason: 'bar stays on other tabs');
      await tester.enterText(find.byType(TextField).last, 'X=1\n');
      await _settle(tester);
      expect(find.textContaining('Gate, Environment'), findsOneWidget);
      expect(find.textContaining('saves to 2 places'), findsOneWidget);

      await goTab(tester, 'Gate');
      final flaky = tester.widget<SettingToggle>(_toggle('Flaky guard'));
      expect(flaky.value, isTrue, reason: 'draft kept while away');
      expect(find.byKey(const ValueKey('dirty-gate')), findsOneWidget);
      expect(find.byKey(const ValueKey('dirty-environment')), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets(
      'Gate: PUT /projects/p1/gate carries every field and target shared',
      (tester) async {
        final o = await openSettings(tester, tab: SettingsTab.gate);
        await _tapToggle(tester, 'Flaky guard');
        await _settle(tester);
        await tester.tap(find.text('Save'));
        await _settle(tester);

        final put = o.backend.puts('/projects/p1/gate').single;
        final body = o.backend.body(put);
        expect(body['flaky_rerun'], true);
        expect(body['target'], 'shared');
        expect(body['runner'], 'vitest');
        expect(body['gate_dir'], 'frontend');
        expect(
          body['mutation'],
          true,
          reason: 'fields the tab does not touch must round-trip',
        );
        expect(body['tamper_alarm'], 'warn');
        expect(body['code_to_check'], 'warn');
        expect(body['verified_hunks'], true);
        expect(body['coverage_tolerance'], 0.0);
        expect(_bar, findsNothing, reason: 'clean after a successful save');
      },
    );

    testWidgets('Gate: Run on save saves as [gate] run_on_save', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.gate);
      expect(
        tester.widget<SettingToggle>(_toggle('Run on save')).value,
        isFalse,
        reason: 'off until chosen: a save then spends a test run',
      );
      await _tapToggle(tester, 'Run on save');
      await _settle(tester);
      await tester.tap(find.text('Save'));
      await _settle(tester);

      final body = o.backend.body(o.backend.puts('/projects/p1/gate').single);
      expect(body['run_on_save'], true);
      expect(body['target'], 'shared');
    });

    testWidgets('Gate: known-flaky tests list and remove', (tester) async {
      final o = await openSettings(tester, tab: SettingsTab.gate);
      expect(find.textContaining('retries once'), findsOneWidget);
      expect(_toggle('Retry known-flaky tests'), findsOneWidget);
      expect(
        tester.widget<SettingToggle>(_toggle('Retry known-flaky tests')).value,
        isTrue,
      );
      await tester.ensureVisible(find.text('Remove'));
      await tester.tap(find.text('Remove'));
      await _settle(tester);
      final del = o.backend.log.where((r) => r.method == 'DELETE').single;
      expect(del.url.path, '/projects/p1/known-flaky');
      expect(del.url.queryParameters, {
        'file': 'a.test.ts',
        'name': 'retries once',
      });
      expect(find.text('None flagged.'), findsOneWidget);
    });

    testWidgets(
      'Gate: Secrets scan sits under the advisory section and saves',
      (tester) async {
        final o = await openSettings(tester, tab: SettingsTab.gate);
        expect(_toggle('Secrets scan'), findsOneWidget);
        expect(
          find.textContaining('Flags possible credentials in the diff'),
          findsOneWidget,
        );
        final advisory = tester
            .getTopLeft(find.text('ADVISORY · NEVER BLOCKS'))
            .dy;
        expect(
          tester.getTopLeft(find.text('Secrets scan')).dy,
          greaterThan(advisory),
        );
        expect(
          tester.widget<SettingToggle>(_toggle('Secrets scan')).value,
          isTrue,
        );
        await _tapToggle(tester, 'Secrets scan');
        await _settle(tester);
        await tester.tap(find.text('Save'));
        await _settle(tester);
        final body = o.backend.body(o.backend.puts('/projects/p1/gate').single);
        expect(body['secrets_scan'], false);
        expect(body['target'], 'shared');
      },
    );

    testWidgets('Gate: a backend without secrets_scan reads as on', (
      tester,
    ) async {
      final be = FakeBackend();
      be.routes['/projects/p1/gate'] = {...gateJson()..remove('secrets_scan')};
      await openSettings(tester, backend: be, tab: SettingsTab.gate);
      expect(
        tester.widget<SettingToggle>(_toggle('Secrets scan')).value,
        isTrue,
      );
    });

    testWidgets('Roles: Review is the Review with AI model, no gate wording', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.roles);
      expect(find.textContaining('used by Review with AI'), findsOneWidget);
      expect(find.text('Review fix rounds'), findsNothing);
      expect(find.textContaining('after a green gate'), findsNothing);
    });

    testWidgets('Agent: numbers parse and the rest is sent back untouched', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.agent);
      final field = find.descendant(
        of: find.byType(SettingNumberInput).first,
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '7.5');
      await _settle(tester);
      await tester.tap(find.text('Save'));
      await _settle(tester);
      final body = o.backend.body(o.backend.puts('/projects/p1/agent').single);
      expect(body['max_budget_usd'], 7.5);
      expect(body['default_model'], 'opus');
      expect(body['default_effort'], 'high');
      expect(body['cost_warn_usd'], 20.0);
      expect(body['max_parallel'], 4);
      expect(body['local_model'], 'qwen');
      expect(body['target'], 'shared');
    });

    testWidgets('Setup hands editing to your editor', (tester) async {
      await openSettings(tester, tab: SettingsTab.setup);
      expect(find.text('Edit in your editor'), findsOneWidget);
      expect(find.text('settings.toml ↗'), findsOneWidget);
      expect(find.text('settings.local.toml ↗'), findsOneWidget);
    });

    testWidgets('Instructions hands editing to your editor', (tester) async {
      await openSettings(tester, tab: SettingsTab.instructions);
      expect(find.text('Edit in your editor'), findsOneWidget);
      expect(find.text('Open in editor ↗'), findsOneWidget);
    });

    testWidgets(
      'Setup is read only: no save bar, no scripts write, and the note says why',
      (tester) async {
        final o = await openSettings(tester, tab: SettingsTab.setup);
        expect(find.text('npm install'), findsOneWidget);
        expect(find.text('npm run dev'), findsOneWidget);
        expect(
          find.textContaining('edit the files below in your editor'),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsOneWidget, reason: 'only search');
        await _tapToggle(tester, 'Use login shell');
        await _settle(tester);
        expect(_bar, findsNothing);
        expect(o.backend.log.where((r) => r.method != 'GET'), isEmpty);
      },
    );

    testWidgets('Git only calls the endpoints whose value changed', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.git);
      await tester.tap(find.text('Merge only'));
      await _settle(tester);
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(o.backend.puts('/projects/p1/default-branch'), isEmpty);
      expect(o.backend.puts('/projects/p1/remote'), isEmpty);
      final body = o.backend.body(
        o.backend.puts('/projects/p1/workflow').single,
      );
      expect(body, {'merge_mode': 'merge', 'target': 'shared'});
    });

    testWidgets(
      'Git base branch menu folds origin/ copies, picking saves the bare name',
      (tester) async {
        final o = await openSettings(tester, tab: SettingsTab.git);
        await tester.tap(find.text('main').last);
        await _settle(tester);
        expect(find.text('origin'), findsNothing);
        expect(find.text('origin/main'), findsNothing);
        await tester.tap(find.text('dev'));
        await _settle(tester);
        await tester.tap(find.text('Save'));
        await _settle(tester);
        final body = o.backend.body(
          o.backend.puts('/projects/p1/default-branch').single,
        );
        expect(body, {'branch': 'dev'});
      },
    );

    testWidgets('Environment sends the raw content', (tester) async {
      final o = await openSettings(tester, tab: SettingsTab.environment);
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'API_KEY=abc\nNEW=1\n');
      await _settle(tester);
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(o.backend.body(o.backend.puts('/projects/p1/env').single), {
        'content': 'API_KEY=abc\nNEW=1\n',
      });
    });

    testWidgets(
      'Instructions save only the file that changed, to its own target',
      (tester) async {
        final o = await openSettings(tester, tab: SettingsTab.instructions);
        await tester.enterText(find.byType(TextField).last, 'mine v2');
        await _settle(tester);
        expect(
          find.textContaining('.haro/instructions.local.md'),
          findsWidgets,
        );
        await tester.tap(find.text('Save'));
        await _settle(tester);
        final put = o.backend.puts('/projects/p1/instructions').single;
        expect(o.backend.body(put), {'text': 'mine v2', 'target': 'local'});
      },
    );

    testWidgets(
      'Roles: turning it on with nothing picked fills sensible picks',
      (tester) async {
        final be = FakeBackend();
        be.routes['/projects/p1/roles'] = {
          'enabled': false,
          'plan': '',
          'build': '',
          'review': '',
          'scout': '',
          'review_enforce': 'off',
          'review_max_rounds': 2,
        };
        await openSettings(tester, backend: be, tab: SettingsTab.roles);
        await _tapToggle(tester, 'Use roles');
        await _settle(tester);
        await tester.tap(find.text('Save'));
        await _settle(tester);
        final body = be.body(be.puts('/projects/p1/roles').single);
        expect(body['enabled'], true);
        expect(body['plan'], 'opus:high');
        expect(body['build'], 'sonnet:high');
        expect(body['scout'], 'haiku');
        expect(body.containsKey('review_enforce'), isFalse);
        expect(body.containsKey('review_max_rounds'), isFalse);
      },
    );

    testWidgets('Roles: View config reveals the generated TOML', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.roles);
      expect(find.textContaining('[roles]'), findsNothing);
      await tester.tap(find.text('View config'));
      await _settle(tester);
      expect(find.textContaining('plan = "opus:high"'), findsOneWidget);
    });

    testWidgets('one Save persists every dirty tab, each to its own endpoint', (
      tester,
    ) async {
      final o = await openSettings(tester, tab: SettingsTab.gate);
      await _tapToggle(tester, 'Flaky guard');
      await goTab(tester, 'Environment');
      await tester.enterText(find.byType(TextField).last, 'X=1\n');
      await _settle(tester);
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(o.backend.puts('/projects/p1/gate'), hasLength(1));
      expect(o.backend.puts('/projects/p1/env'), hasLength(1));
      expect(_bar, findsNothing);
    });

    testWidgets(
      'a failing save shows its message in the bar and stays dirty, others still save',
      (tester) async {
        final be = FakeBackend()..failing['/projects/p1/gate'] = 422;
        await openSettings(tester, backend: be, tab: SettingsTab.gate);
        await _tapToggle(tester, 'Flaky guard');
        await goTab(tester, 'Environment');
        await tester.enterText(find.byType(TextField).last, 'X=1\n');
        await _settle(tester);
        await tester.tap(find.text('Save'));
        await _settle(tester);
        expect(_bar, findsOneWidget);
        expect(find.byKey(const ValueKey('save-error')), findsOneWidget);
        expect(find.textContaining('Gate: backend said no'), findsOneWidget);
        expect(be.puts('/projects/p1/env'), hasLength(1));
        expect(find.byKey(const ValueKey('dirty-environment')), findsNothing);
        expect(find.byKey(const ValueKey('dirty-gate')), findsOneWidget);
      },
    );

    testWidgets('device settings land in the JSON file and keep unknown keys', (
      tester,
    ) async {
      final store = MemoryDevicePrefsStore({
        'other_tool': {'x': 1},
        'display': {'density': 'comfortable', 'future_key': true},
      });
      await openSettings(tester, prefs: store);
      await tester.tap(find.text('Compact'));
      await _settle(tester);
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(store.data['other_tool'], {'x': 1});
      final display = store.data['display'] as Map;
      expect(display['density'], 'compact');
      expect(display['film_grain'], true);
      expect(display['coding_font'], 'Space Mono');
    });
  });

  group('search', () {
    testWidgets('narrows the nav to matching tabs and the rows to matches', (
      tester,
    ) async {
      await openSettings(tester);
      await tester.enterText(find.widgetWithText(TextField, '').first, 'flaky');
      await _settle(tester);
      final nav = find.byType(ListView).first;
      expect(
        find.descendant(of: nav, matching: find.text('Gate')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: nav, matching: find.text('Display')),
        findsNothing,
      );
      expect(find.text('Flaky guard'), findsOneWidget);
      expect(find.text('Runner'), findsNothing, reason: 'only matching rows');
    });

    testWidgets('matches help text too', (tester) async {
      await openSettings(tester);
      await tester.enterText(find.widgetWithText(TextField, '').first, 'nvm');
      await _settle(tester);
      expect(find.text('Use login shell'), findsOneWidget);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await openSettings(tester);
      await tester.enterText(find.widgetWithText(TextField, '').first, 'zzzz');
      await _settle(tester);
      expect(find.textContaining('No settings match'), findsOneWidget);
    });
  });

  group('gate tab', () {
    testWidgets('opens with the summary sentence built from the data', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.gate);
      expect(
        find.text(
          'Green means every Vitest test in frontend/ passes. '
          'Advisory checks below list what to look at but never block a merge.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('BLOCKS MERGE'), findsOneWidget);
      expect(find.text('ADVISORY · NEVER BLOCKS'), findsOneWidget);
    });

    testWidgets('the summary follows the draft before it is saved', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.gate);
      await tester.tap(find.text('Vitest').last);
      await _settle(tester);
      await tester.tap(find.text('pytest'));
      await _settle(tester);
      expect(
        find.textContaining(
          'every pytest test in frontend/ passes',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('never offers the removed quality / Double Gate settings', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.gate);
      for (final word in ['quality', 'Double Gate', 'secrets scan', 'lint']) {
        expect(find.textContaining(word, findRichText: true), findsNothing);
      }
    });

    testWidgets('Command and Coverage tolerance appear only when they apply', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.gate);
      expect(find.text('Command'), findsNothing);
      expect(find.text('Coverage tolerance'), findsNothing);
      await tester.ensureVisible(find.text('Warn').first);
      await tester.tap(find.text('Warn').first);
      await _settle(tester);
      expect(find.text('Coverage tolerance'), findsOneWidget);
    });
  });

  group('app tabs', () {
    testWidgets(
      'Display has the three device settings and a disabled editor row',
      (tester) async {
        await openSettings(tester);
        for (final l in [
          'Coding font',
          'Density',
          'Film grain',
          'Preferred editor',
        ]) {
          expect(find.text(l), findsOneWidget);
        }
        expect(find.text('Theme'), findsNothing);
        expect(find.textContaining('Nvim'), findsNothing);
        expect(find.textContaining('Neovim'), findsNothing);
      },
    );

    testWidgets('Usage shows meters from the limits', (tester) async {
      await openSettings(tester, tab: SettingsTab.usage);
      expect(find.text('Current session'), findsOneWidget);
      expect(find.text('39%'), findsOneWidget);
      expect(find.text('12%'), findsOneWidget);
    });

    testWidgets('Usage error state has Retry, and Retry reloads', (
      tester,
    ) async {
      final be = FakeBackend()..failingGet['/usage'] = 500;
      await openSettings(tester, backend: be, tab: SettingsTab.usage);
      expect(find.textContaining('Could not load usage'), findsOneWidget);
      be.failingGet.clear();
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.text('Current session'), findsOneWidget);
    });

    testWidgets('Usage unavailable explains why and offers Retry', (
      tester,
    ) async {
      final be = FakeBackend();
      be.routes['/usage'] = {'available': false, 'reason': 'token_expired'};
      await openSettings(tester, backend: be, tab: SettingsTab.usage);
      expect(find.textContaining('token has expired'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('System is read only and shows the update status', (
      tester,
    ) async {
      await openSettings(tester, tab: SettingsTab.system);
      expect(find.text('Data folder'), findsOneWidget);
      expect(find.text('Launch at login'), findsOneWidget);
      expect(find.textContaining('Up to date (f4803ada)'), findsOneWidget);
      expect(_scopeText(tester), 'Read only');
    });

    testWidgets('Setup has no custom instructions row', (tester) async {
      await openSettings(tester, tab: SettingsTab.setup);
      expect(find.textContaining('ustom instructions'), findsNothing);
    });
  });

  group('closing', () {
    testWidgets('Esc closes a clean overlay', (tester) async {
      await openSettings(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Search settings'), findsNothing);
      expect(haroOverlayDepthValue(), 0);
    });

    testWidgets('Esc and the close button refuse while edits are unsaved', (
      tester,
    ) async {
      await openSettings(tester);
      await _tapToggle(tester, 'Film grain');
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Search settings'), findsOneWidget);
      expect(find.textContaining('save or discard'), findsOneWidget);
      await tester.tap(find.text('✕'));
      await tester.pump();
      expect(find.text('Search settings'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await _settle(tester);
      await tester.tap(find.text('✕'));
      await _settle(tester);
      expect(find.text('Search settings'), findsNothing);
    });
  });

  test('device prefs round-trip through json', () {
    final d = DisplayPrefs.fromJson(const DisplayPrefs().toJson());
    expect(d.codingFont, 'Space Mono');
    final n = NotificationPrefs.fromJson(const NotificationPrefs().toJson());
    expect(n.toastPosition, 'bottom-right');
    expect(n.toastSeconds, 4);
  });
}

int haroOverlayDepthValue() => 0;
