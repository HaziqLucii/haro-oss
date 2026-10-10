import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/verify/verify_model.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/gate_facts.dart';
import 'package:haro_app/state/look_at.dart';
import 'package:haro_app/state/verdict.dart';

import '../../../../state/builders.dart';
import 'verify_harness.dart';

Map<String, String> byLabel(List<Metric> m) => {
  for (final x in m) x.label: x.value,
};

Metric metric(List<Metric> m, String label) =>
    m.firstWhere((x) => x.label == label);

const noProgress = (done: 0, total: 0);

void main() {
  group('verdictMeta', () {
    const config = GateConfig(gateDir: 'frontend');

    test('a settled run reads runner, folder, scope, age and duration', () {
      final r = greenRun();
      expect(
        verdictMeta(
          state: DisplayState.green,
          run: r,
          summary: null,
          config: config,
          now: DateTime.now(),
        ),
        'vitest · frontend/ · all tests · 4m ago · 2.1s',
      );
    });

    test('a running gate has no age or scope', () {
      expect(
        verdictMeta(
          state: DisplayState.gate,
          run: greenRun(),
          summary: null,
          config: config,
          now: DateTime.now(),
        ),
        'vitest · frontend/ · running',
      );
    });

    test('a tree that never ran says so, with the configured scope', () {
      expect(
        verdictMeta(
          state: DisplayState.idle,
          run: null,
          summary: null,
          config: const GateConfig(defaultScope: 'impacted'),
          now: DateTime.now(),
        ),
        'vitest · impacted tests · never run',
      );
    });

    test('an impacted run is labelled as such', () {
      final r = run(
        overrides: {'scope': 'impacted', ...endedAgo(const Duration(hours: 2))},
      );
      final meta = verdictMeta(
        state: DisplayState.green,
        run: r,
        summary: null,
        config: null,
        now: DateTime.now(),
      );
      expect(meta, contains('impacted tests'));
      expect(meta, contains('2h ago'));
    });
  });

  group('deriveMetrics', () {
    final greenFacts = GateFacts.fromRun(greenRun());

    List<Metric> derive({
      DisplayState state = DisplayState.green,
      GateFacts? facts,
      TestRun? r,
      bool flakyRerun = false,
      ({int done, int total}) progress = noProgress,
    }) => deriveMetrics(
      state: state,
      facts: facts ?? greenFacts,
      run: r ?? greenRun(),
      progress: progress,
      flakyRerun: flakyRerun,
    );

    test('green: tests in gate green, unmeasured values say so', () {
      final m = derive();
      expect(byLabel(m), {
        'Tests': '594 / 594',
        'Duration': '2.1s',
        'Coverage': 'not measured',
        'Flaky': 'not measured',
      });
      expect(metric(m, 'Tests').tone, MetricTone.gate);
      expect(metric(m, 'Coverage').tone, MetricTone.dim);
    });

    test(
      'a gate with no test count (a command or linter) says so, not 0 / 0',
      () {
        final r = greenRun(
          overrides: {
            'runner': 'command',
            'total': 0,
            'passed': 0,
            'failed': 0,
          },
        );
        final m = derive(facts: GateFacts.fromRun(r), r: r);
        expect(byLabel(m)['Tests'], 'not counted');
        expect(metric(m, 'Tests').tone, MetricTone.dim);
      },
    );

    test(
      'zero tests under a counting runner stays 0 / 0, not "not counted"',
      () {
        final r = greenRun(
          overrides: {'runner': 'vitest', 'total': 0, 'passed': 0, 'failed': 0},
        );
        expect(
          byLabel(derive(facts: GateFacts.fromRun(r), r: r))['Tests'],
          '0 / 0',
        );
      },
    );

    test('red: passed of total in red', () {
      final r = failingRun();
      final m = derive(
        state: DisplayState.red,
        facts: GateFacts.fromRun(r),
        r: r,
      );
      expect(metric(m, 'Tests').value, '13 / 16');
      expect(metric(m, 'Tests').tone, MetricTone.fail);
    });

    test('running: live count, the rest wait for the run', () {
      final m = derive(
        state: DisplayState.gate,
        facts: GateFacts.none,
        progress: (done: 412, total: 594),
      );
      expect(byLabel(m), {
        'Tests': '412 / 594',
        'Duration': '–',
        'Coverage': 'after run',
        'Flaky': 'after run',
      });
    });

    test('idle: nothing is invented', () {
      final m = derive(
        state: DisplayState.idle,
        facts: GateFacts.none,
        r: null,
      );
      expect(m.map((x) => x.value).toSet(), {'–'});
    });

    test('coverage shows the gate run delta against main', () {
      final m = derive(r: greenRun(overrides: {'coverage_delta': 1.4}));
      expect(metric(m, 'Coverage').value, '↑1.4 vs main');
      final down = derive(r: greenRun(overrides: {'coverage_delta': -0.6}));
      expect(metric(down, 'Coverage').value, '↓0.6 vs main');
    });

    test('flaky comes from the gate run, and only when the re-run is on', () {
      final r = greenRun(
        overrides: {
          'flaky_tests': ['a'],
        },
      );
      expect(metric(derive(r: r), 'Flaky').value, 'not measured');
      final on = derive(r: r, flakyRerun: true);
      expect(metric(on, 'Flaky').value, '1');
      expect(metric(on, 'Flaky').tone, MetricTone.fail);
      expect(metric(derive(flakyRerun: true), 'Flaky').tone, MetricTone.ink);
    });

    test('a gate error reads as not run, not as 0 of 0', () {
      final m = derive(
        state: DisplayState.red,
        facts: const GateFacts(measured: true, status: TestRunStatus.error),
      );
      expect(metric(m, 'Tests').value, '–');
    });
  });

  group('tamperDetail', () {
    test('names the deleted test and its file', () {
      final alarm = TamperAlarm(
        count: 1,
        headline: 'x',
        findings: [TamperFinding.fromJson(removedTest)],
      );
      expect(
        tamperDetail(alarm),
        '“is free at exactly the \$100 boundary” is gone from lib/shipping.test.ts. A passing suite would now prove less than before.',
      );
    });

    test('counts the rest', () {
      final alarm = TamperAlarm(
        count: 2,
        headline: 'x',
        findings: [
          TamperFinding.fromJson(removedTest),
          const TamperFinding(kind: 'skip', file: 'a.test.ts', detail: 'x'),
        ],
      );
      expect(tamperDetail(alarm), contains('and 1 more'));
    });

    test('a non-deletion reads its own detail', () {
      final alarm = TamperAlarm(
        count: 1,
        headline: 'x',
        findings: const [
          TamperFinding(kind: 'skip', file: 'a.test.ts', detail: '.skip added'),
        ],
      );
      expect(tamperDetail(alarm), '.skip added · a.test.ts');
    });

    test('with only a summary it falls back to the note', () {
      expect(
        tamperDetail(
          const TamperAlarm(count: 2, headline: 'x', note: '2 removed'),
        ),
        '2 removed',
      );
    });
  });

  group('lines no test ran', () {
    test('parseAddedLines maps new-file line numbers to code', () {
      final a = parseAddedLines(sampleDiff);
      expect(
        a['frontend/src/components/AgentStream.tsx']![211],
        "  if (evt.kind === 'retry') return",
      );
      expect(a['desktop/main.js']![205], '  return 0 // OS-assigned fallback');
    });

    test('a removed line starting with dashes is not a file header', () {
      const diff = '''
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
--- not a header
+++ still an added line
''';
      final a = parseAddedLines(diff);
      expect(a['a.txt']![1], '++ still an added line');
    });

    test('groups consecutive cold lines into a range', () {
      const v = VerifiedHunksResponse(
        baseRef: 'main',
        supported: true,
        files: [
          VerifiedFile(
            path: 'lib/a.ts',
            inMap: true,
            added: 10,
            executed: 6,
            unexecuted: 4,
            lines: {10: 0, 11: 0, 12: 3, 20: 0, 21: 0},
          ),
        ],
      );
      final u = deriveUntested(v, '');
      expect(u.spots.map((s) => s.label), ['a.ts:10–11', 'a.ts:20–21']);
      expect(u.meta, '4 of 10 added lines');
    });

    test(
      'code comes from the diff, unmapped files say no test imports them',
      () {
        final u = deriveUntested(sampleHunks(), sampleDiff);
        final byPath = {for (final s in u.spots) s.path: s};
        expect(
          byPath['frontend/src/components/AgentStream.tsx']!.code,
          "if (evt.kind === 'retry') return",
        );
        expect(
          byPath['frontend/src/components/ProjectSettingsModal.tsx']!.unmapped,
          isTrue,
        );
        expect(u.spots.first.path, contains('ProjectSettingsModal'));
      },
    );

    test('unsupported or missing maps are not measured, not zero', () {
      expect(deriveUntested(null, '').meta, 'not measured');
      expect(
        deriveUntested(
          const VerifiedHunksResponse(baseRef: 'main', note: 'no gate yet'),
          '',
        ).note,
        'no gate yet',
      );
    });

    test('stale files are ignored', () {
      const v = VerifiedHunksResponse(
        baseRef: 'main',
        supported: true,
        files: [
          VerifiedFile(
            path: 'a',
            inMap: true,
            stale: true,
            added: 3,
            unexecuted: 3,
          ),
        ],
      );
      final u = deriveUntested(v, '');
      expect(u.spots, isEmpty);
      expect(u.unexecuted, 0);
    });
  });

  group('review rows', () {
    LookAt lookAt() => deriveLookAt(
      run: greenRun(
        unchecked: [untestedRow('a.ts', 1), untestedRow('b.ts', 2)],
      ),
      checkedKeys: ['untested_lines:b.ts:2'],
    );

    test('open rows first, ticked rows after', () {
      final rows = reviewRows(lookAt(), {});
      expect(rows.map((r) => r.reviewed), [false, true]);
      expect(rows.first.remote, isTrue);
    });

    test('a locally ticked row moves down and counts as reviewed', () {
      final l = deriveLookAt(
        run: failingRun(),
        cells: [for (final c in failingRun().cases) c.toCell(0)],
      );
      final first = l.pending.first.key;
      final rows = reviewRows(l, {first});
      expect(rows.last.item.key, first);
      expect(rows.last.reviewed, isTrue);
      expect(rows.last.remote, isFalse);
    });

    test('copy per state', () {
      expect(lookAtTitle(DisplayState.red), 'Failing & flagged');
      expect(lookAtTitle(DisplayState.green), 'Needs your review');
      expect(lookAtHint(DisplayState.red), 'Failures block the merge');
      expect(
        lookAtHint(DisplayState.green),
        'Advisory · never blocks the merge',
      );
      expect(
        emptyLookAtText(DisplayState.gate),
        'Appears when the run finishes.',
      );
      expect(
        emptyLookAtText(DisplayState.idle),
        'Nothing to review until the gate has run.',
      );
      expect(
        emptyLookAtText(DisplayState.green),
        'Nothing flagged on this run.',
      );
    });
  });

  test('codePath carries the file and line', () {
    expect(
      codePath('ws_1', file: 'lib/a b.ts', line: 12),
      '/w/ws_1/code?file=lib%2Fa+b.ts&line=12',
    );
    expect(codePath('ws_1'), '/w/ws_1/code');
  });
}
