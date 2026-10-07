import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/features/workspace/steps/verify/verify_model.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/gate_facts.dart';
import 'package:haro_app/state/look_at.dart';
import 'package:haro_app/state/verdict.dart';

import '../../../../api/fixtures.dart';
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
      WorkspaceAnalysis analysis = WorkspaceAnalysis.none,
      MutationView? mutation,
      bool flakyRerun = false,
      ({int done, int total}) progress = noProgress,
    }) => deriveMetrics(
      state: state,
      facts: facts ?? greenFacts,
      run: r ?? greenRun(),
      progress: progress,
      analysis: analysis,
      mutation: mutation,
      flakyRerun: flakyRerun,
    );

    test('green: tests in gate green, unmeasured values say so', () {
      final m = derive();
      expect(byLabel(m), {
        'Tests': '594 / 594',
        'Duration': '2.1s',
        'Coverage': 'not measured',
        'Mutation': 'not measured',
        'Flaky': 'not measured',
      });
      expect(metric(m, 'Tests').tone, MetricTone.gate);
      expect(metric(m, 'Coverage').tone, MetricTone.dim);
    });

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
        'Mutation': 'after run',
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

    test('measured values show, with a coverage delta arrow', () {
      final m = derive(
        analysis: WorkspaceAnalysis(
          coverage: CoverageResponse.fromJson({
            'supported': true,
            'base_ref': 'main',
            'current': {'lines': 91.2},
            'baseline': {'lines': 89.8},
            'delta': {'lines': 1.4},
          }),
          flaky: const FlakyResponse(runs: 5, checked: 594),
        ),
        mutation: mutationView(sampleMutation(), null),
      );
      expect(metric(m, 'Coverage').value, '91.2% ↑1.4');
      expect(metric(m, 'Mutation').value, '82%');
      expect(metric(m, 'Flaky').value, '0');
    });

    test('a gate error reads as not run, not as 0 of 0', () {
      final m = derive(
        state: DisplayState.red,
        facts: const GateFacts(measured: true, status: TestRunStatus.error),
      );
      expect(metric(m, 'Tests').value, '–');
    });
  });

  group('evidence meta', () {
    test('mutation', () {
      expect(mutationMeta(null, running: false), 'not measured');
      expect(mutationMeta(null, running: true), 'running…');
      expect(
        mutationMeta(mutationView(sampleMutation(), null), running: false),
        '82% · 41 of 50 mistakes caught',
      );
      expect(
        mutationMeta(
          const MutationView(supported: true, score: null),
          running: false,
        ),
        'no runnable mutants',
      );
    });

    test(
      'a cached mutation score from the receipt stands in, unless stale',
      () {
        const cached = ReceiptMutation(supported: true, ran: true, score: 71);
        expect(mutationValue(mutationView(null, cached)), '71%');
        expect(mutationMeta(mutationView(null, cached), running: false), '71%');
        const stale = ReceiptMutation(
          supported: true,
          ran: true,
          stale: true,
          score: 71,
        );
        expect(mutationView(null, stale), isNull);
        expect(mutationView(null, const ReceiptMutation()), isNull);
      },
    );

    test('a fresh answer beats the cached one', () {
      const cached = ReceiptMutation(supported: true, ran: true, score: 10);
      expect(mutationValue(mutationView(sampleMutation(), cached)), '82%');
    });

    test('coverage', () {
      expect(coverageMeta(null, running: false), 'not measured');
      final c = CoverageResponse.fromJson({
        'supported': true,
        'base_ref': 'main',
        'current': {'lines': 91.2},
        'delta': {'lines': -0.6},
      });
      expect(coverageMeta(c, running: false), '91.2% · down 0.6 from main');
      expect(
        coverageMeta(const CoverageResponse(supported: false), running: false),
        'unavailable',
      );
    });

    test('flaky', () {
      expect(flakyMeta(null, null, false, running: false), 'not measured');
      expect(
        flakyMeta(const FlakyResponse(runs: 5), null, false, running: false),
        'none in the last 5 runs',
      );
      expect(
        flakyMeta(
          FlakyResponse(
            runs: 5,
            flaky: const [FlakyTest(file: 'a', name: 'b')],
            stable: false,
          ),
          null,
          false,
          running: false,
        ),
        '1 flaky in 5 runs',
      );
      expect(
        flakyMeta(null, greenRun(), true, running: false),
        'none flagged on the last run',
      );
    });

    test('impact', () {
      expect(impactMeta(null), 'tests that touch the change');
      expect(impactMeta(sampleImpact()), '3 tests touch this change');
      final by = impactByFile(sampleImpact());
      expect(by.first, (file: 'desktop/main.test.js', tests: 2));
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

  group('test grid', () {
    Cell cell(String id, String status, {String file = 'a.test.ts'}) =>
        Cell.fromJson(cellJson(id, status, file: file));

    test('one square per three tests of a file, worst status wins', () {
      final s = gridSquares([
        cell('1', 'passed'),
        cell('2', 'failed'),
        cell('3', 'passed'),
        cell('4', 'passed'),
        cell('5', 'passed', file: 'b.test.ts'),
      ]);
      expect(s.map((x) => x.state), [
        SquareState.failed,
        SquareState.passed,
        SquareState.passed,
      ]);
      expect(s.map((x) => x.group), [0, 0, 1]);
    });

    test('a running test makes its square hollow, failure still wins', () {
      final s = gridSquares([
        cell('1', 'passed'),
        cell('2', 'running'),
        cell('3', 'passed'),
        cell('4', 'running'),
        cell('5', 'failed'),
        cell('6', 'passed'),
      ]);
      expect(s.map((x) => x.state), [SquareState.running, SquareState.failed]);
    });

    test('a square holding a retried test is marked and labelled', () {
      final cells = [
        cell('1', 'passed'),
        cell('2', 'passed', file: 'b.test.ts'),
      ];
      final s = gridSquares(
        cells,
        retried: {'${cells[0].file}::${cells[0].name}'},
      );
      expect(s.map((x) => x.retried), [true, false]);
      expect(s[0].label, endsWith(' · retried'));
      expect(s[1].label, isNot(contains('retried')));
    });

    test('tests not started yet fill the tail', () {
      final s = gridSquares([cell('1', 'passed')], expectedTotal: 10);
      expect(s.length, 1 + 3);
      expect(s.skip(1).every((x) => x.state == SquareState.pending), isTrue);
    });

    test('layout wraps at the width and opens a gap between files', () {
      final squares = [
        for (var i = 0; i < 4; i++) GridSquare(SquareState.passed, '', 0),
        const GridSquare(SquareState.passed, '', 1),
      ];
      final l = layoutGrid(squares, width: 50);
      expect(l.positions[0], (x: 0.0, y: 0.0));
      expect(l.positions[3], (x: 36.0, y: 0.0));
      // 5th square: group gap pushes it past the width, so it wraps.
      expect(l.positions[4].y, 12.0);
      expect(l.height, 12.0 + 9);
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
      expect(lookAtTitle(DisplayState.green), 'Needs your eyes');
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
