import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/settings/settings_controller.dart';
import 'package:haro_app/features/settings/settings_logic.dart';
import 'package:haro_app/features/settings/settings_scope.dart';
import 'package:haro_app/features/settings/settings_tab_spec.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

GateConfig gate(Map<String, dynamic> patch) =>
    GateConfig.fromJson({'runner': 'vitest', ...patch});

SettingRowSpec row(String label, {String help = '', String? section}) =>
    SettingRowSpec(
      id: label,
      label: label,
      help: help,
      section: section,
      control: (_) => const SizedBox(),
    );

void main() {
  group('gate summary', () {
    test('vitest in a folder', () {
      final s = gateSummary(gate({'gate_dir': 'frontend'}));
      expect(
        s.plain,
        'Green means every Vitest test in frontend/ passes. '
        'Advisory checks below list what to look at but never block a merge.',
      );
      expect(s.strong, 'every Vitest test in frontend/ passes');
    });

    test('slashes are normalised and an empty dir reads as the repo root', () {
      expect(
        gateSummary(gate({'gate_dir': '/web/app/'})).strong,
        'every Vitest test in web/app/ passes',
      );
      expect(
        gateSummary(gate({})).strong,
        'every Vitest test in the repo root passes',
      );
    });

    test('other runners say what green means for them', () {
      expect(
        gateSummary(gate({'runner': 'pytest', 'gate_dir': 'backend'})).strong,
        'every pytest test in backend/ passes',
      );
      expect(
        gateSummary(gate({'runner': 'command', 'command': 'make check'}))
            .strong,
        'make check in the repo root exits 0',
      );
      expect(
        gateSummary(gate({'runner': 'offense', 'command': 'eslint .'})).strong,
        'no offenses from eslint . in the repo root',
      );
    });
  });

  group('roles', () {
    test('split and join the model:effort shorthand', () {
      expect(splitRole('opus:high'), ('opus', 'high'));
      expect(splitRole('haiku'), ('haiku', ''));
      expect(splitRole(''), ('', ''));
      expect(joinRole('opus', 'high'), 'opus:high');
      expect(joinRole('haiku', ''), 'haiku');
      expect(joinRole('', 'high'), '');
    });

    test('haiku drops efforts it rejects', () {
      expect(effortFor('haiku', 'xhigh'), 'high');
      expect(effortFor('opus', 'xhigh'), 'xhigh');
    });

    test('enabling an empty config fills the sensible picks', () {
      final on = enableRoles(const RolesConfig());
      expect(on.enabled, isTrue);
      expect(on.plan, 'opus:high');
      expect(on.build, 'sonnet:high');
      expect(on.scout, 'haiku');
      expect(on.review, '');
    });

    test('enabling keeps picks the user already made', () {
      final on = enableRoles(const RolesConfig(build: 'fable:xhigh'));
      expect(on.build, 'fable:xhigh');
      expect(on.plan, '');
    });

    test('rolesToml lists only what differs from the defaults', () {
      expect(rolesToml(const RolesConfig()), '# [roles] · off');
      expect(
        rolesToml(const RolesConfig(enabled: true, plan: 'opus:high')),
        '[roles]\nenabled = true\nplan = "opus:high"',
      );
    });
  });

  group('usage helpers', () {
    final now = DateTime.utc(2026, 9, 29, 12);
    test('reset labels', () {
      expect(
        resetLabel('2026-09-29T14:14:00+00:00', now: now),
        'Resets in 2h 14m',
      );
      expect(
        resetLabel('2026-10-02T16:00:00+00:00', now: now),
        'Resets in 3d 4h',
      );
      expect(
        resetLabel('2026-09-29T12:20:00+00:00', now: now),
        'Resets in 20m',
      );
      expect(resetLabel('2026-09-29T11:00:00+00:00', now: now), 'Resetting…');
      expect(resetLabel(null, now: now), isNull);
    });

    test('unavailable reasons give a next step', () {
      expect(usageUnavailable('no_credentials'), contains('Sign in'));
      expect(usageUnavailable('token_expired'), contains('expired'));
      expect(usageUnavailable('fetch_failed'), contains('retry'));
    });
  });

  test('base branch choices fold origin/ copies and drop noise', () {
    expect(
      baseBranchChoices([
        'main',
        'origin',
        'origin/main',
        'origin/feat/x',
        'HEAD',
        'dev',
      ], 'main'),
      ['main', 'feat/x', 'dev'],
    );
    expect(baseBranchChoices([], 'trunk'), ['trunk']);
  });

  test('scope summary names one scope or counts several', () {
    expect(scopeSummary({SettingsScope.team}), SettingsScope.team.label);
    expect(
      scopeSummary({SettingsScope.team, SettingsScope.personal}),
      '2 places',
    );
    expect(scopeSummary({}), '');
  });

  group('search', () {
    final spec = SettingsTabSpec(
      tab: SettingsTab.gate,
      title: 'Gate',
      intro: '',
      scope: SettingsScope.team,
      rows: [
        row(
          'Runner',
          help: 'What runs to decide green',
          section: 'Blocks merge',
        ),
        row('Flaky guard', help: 'Re-run once on red'),
      ],
    );

    test('matches label, help and section, case-insensitively', () {
      expect(filterRows(spec, 'FLAKY').map((r) => r.label), ['Flaky guard']);
      expect(filterRows(spec, 'decide').map((r) => r.label), ['Runner']);
      expect(filterRows(spec, 'blocks').map((r) => r.label), ['Runner']);
    });

    test('a tab-name hit keeps every row', () {
      expect(filterRows(spec, 'gate'), hasLength(2));
      expect(tabMatches(spec, 'gate'), isTrue);
    });

    test('no hit drops the tab', () {
      expect(tabMatches(spec, 'zzz'), isFalse);
      expect(filterRows(spec, 'zzz'), isEmpty);
      expect(tabMatches(spec, ''), isTrue);
    });
  });
}
