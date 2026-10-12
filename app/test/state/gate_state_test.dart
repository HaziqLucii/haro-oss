import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/agent_signals.dart';
import 'package:haro_app/state/diff_stats.dart';
import 'package:haro_app/state/format.dart';
import 'package:haro_app/state/gate_facts.dart';
import 'package:haro_app/state/live_gate.dart';

import '../api/fixtures.dart';
import 'builders.dart';

Cell cell(String id, String status) => Cell.fromJson(cellJson(id, status));

void main() {
  group('LiveGate', () {
    test(
      'run_started clears cells, cell upserts by id, snapshot sets the run',
      () {
        var g = LiveGate.empty;
        g = g.apply(TestCellEvent(cell('a', 'running')));
        g = g.apply(TestCellEvent(cell('b', 'passed')));
        g = g.apply(TestCellEvent(cell('a', 'failed')));
        expect(g.cells.map((c) => c.status), [
          CellStatus.failed,
          CellStatus.passed,
        ]);

        g = g.apply(TestSnapshotEvent(run()));
        expect(g.run!.total, 594);
        expect(g.cells, hasLength(2), reason: 'snapshot keeps the grid');

        g = g.apply(const TestRunStarted());
        expect(g.cells, isEmpty);
        expect(
          g.run,
          isNotNull,
          reason: 'the last settled run survives until the next snapshot',
        );
      },
    );

    test('apply does not mutate the previous state', () {
      final a = LiveGate.empty.apply(TestCellEvent(cell('a', 'passed')));
      final b = a.apply(TestCellEvent(cell('b', 'passed')));
      expect(a.cells, hasLength(1));
      expect(b.cells, hasLength(2));
    });

    test('fromRun rebuilds the grid from stored cases', () {
      final g = LiveGate.fromRun(redRun(failed: 1));
      expect(g.cells.where((c) => c.status == CellStatus.failed), hasLength(1));
      expect(LiveGate.fromRun(null).cells, isEmpty);
    });
  });

  group('LiveWatch is a separate state', () {
    test('watch events feed LiveWatch and cannot reach LiveGate', () {
      final wev = WatchEvent(TestCellEvent(cell('w', 'failed')));
      final watch = LiveWatch.empty.apply(wev);
      expect(watch.cells.single.id, 'w');

      var gate = LiveGate.empty.apply(TestCellEvent(cell('g', 'passed')));
      // The only way to touch gate state is a TestEvent; WatchEvent is not one.
      expect(wev is TestEvent, isFalse);
      gate = gate.apply(const TestRunStarted());
      expect(
        watch.cells,
        hasLength(1),
        reason: 'gate events never clear the watch grid',
      );
    });

    test('watch snapshot and run_started', () {
      var w = LiveWatch.empty;
      w = w.apply(WatchEvent(TestCellEvent(cell('w', 'passed'))));
      w = w.apply(
        WatchEvent(TestSnapshotEvent(run(overrides: {'trigger': 'watch'}))),
      );
      expect(w.run!.trigger, 'watch');
      w = w.apply(const WatchEvent(TestRunStarted()));
      expect(w.cells, isEmpty);
    });
  });

  test('tally counts every status', () {
    final t = tally([
      cell('a', 'passed'),
      cell('b', 'failed'),
      cell('c', 'skipped'),
      cell('d', 'running'),
      cell('e', 'running'),
    ]);
    expect(
      (t.passed, t.failed, t.skipped, t.inflight, t.total, t.done),
      (1, 1, 1, 2, 5, 3),
    );
  });

  group('gateProgress', () {
    test('expected total only raises the denominator', () {
      expect(gateProgress(cells(10), expectedTotal: 594), (
        done: 10,
        total: 594,
      ));
      expect(gateProgress(cells(10), expectedTotal: 5), (done: 10, total: 10));
      expect(gateProgress(cells(4, running: 2)), (done: 4, total: 6));
    });
  });

  group('GateFacts and blockers', () {
    test('blockers come in a fixed order and a gate error stops the list', () {
      final f = GateFacts.fromRun(
        run(
          status: 'failed',
          failed: 2,
          passed: 0,
          unchecked: null,
          tamper: [removedTest],
          overrides: {
            'merge_conflict': true,
            'tamper_blocked': true,
            'coverage_blocked': true,
            'degraded_reasons': ['x'],
          },
        ),
      );
      expect(deriveBlockers(f).map((b) => b.kind), [
        BlockerKind.failingTests,
        BlockerKind.mergeConflict,
        BlockerKind.tamperBlocked,
        BlockerKind.coverageBlocked,
        BlockerKind.degraded,
      ]);

      final err = GateFacts.fromRun(
        run(
          status: 'error',
          failed: 2,
          unchecked: null,
          overrides: {'error_kind': 'runner'},
        ),
      );
      expect(deriveBlockers(err).single.kind, BlockerKind.gateError);
      expect(deriveBlockers(GateFacts.none), isEmpty);
    });

    test('isCantShip covers red and degraded green only', () {
      const degraded = GateFacts(measured: true, degraded: true);
      expect(isCantShip(WorkspaceStatus.gateRed, GateFacts.none), isTrue);
      expect(isCantShip(WorkspaceStatus.gateGreen, degraded), isTrue);
      expect(isCantShip(WorkspaceStatus.gateGreen, GateFacts.none), isFalse);
      expect(isCantShip(WorkspaceStatus.merged, degraded), isFalse);
    });

    test('coverage fix wording depends on whether a number exists', () {
      expect(coverageBlockHint(true), 'Relax coverage guard');
      expect(coverageBlockHint(false), 'Fix coverage reporting');
    });

    test('resolve prefers a real run, ignores watch runs, falls back to the summary', () {
      final summary = GateSummary.fromJson(
        gateSummaryJson(passed: 1, total: 1),
      );
      expect(GateFacts.resolve(run(passed: 9, total: 9), summary).passed, 9);
      expect(
        GateFacts.resolve(
          run(passed: 9, total: 9, overrides: {'trigger': 'watch'}),
          summary,
        ).passed,
        1,
      );
      expect(GateFacts.resolve(null, null).measured, isFalse);
    });
  });

  group('agent signals', () {
    AgentEvent ev(String type, [Map<String, dynamic> payload = const {}]) =>
        AgentEvent.fromJson({
          'run_id': 'r',
          'workspace_id': 'w',
          'ts': 1,
          'type': type,
          'payload': payload,
        });

    test('empty transcript', () {
      final s = deriveAgentSignals(const [], busy: false);
      expect(s.hasActivity, isFalse);
      expect(s.planReady, isFalse);
    });

    test(
      'plan ready: newest terminal event is a plan done and nothing is running',
      () {
        final events = [
          ev('token', {'text': 'thinking'}),
          ev('done', {'plan': true, 'duration_ms': 90000}),
        ];
        final s = deriveAgentSignals(events, busy: false);
        expect(s.planReady, isTrue);
        expect(s.lastRunDuration, const Duration(seconds: 90));
        expect(deriveAgentSignals(events, busy: true).planReady, isFalse);
      },
    );

    test('plan superseded by a later build run', () {
      final events = [
        ev('done', {'plan': true}),
        ev('user', {'text': 'approved'}),
        ev('done', {}),
      ];
      expect(deriveAgentSignals(events, busy: false).planReady, isFalse);
    });

    test('a plan run that errored has no plan', () {
      final events = [
        ev('done', {'plan': true}),
        ev('error', {'message': 'x'}),
      ];
      expect(deriveAgentSignals(events, busy: false).planReady, isFalse);
    });

    test(
      'waiting on input: live run whose newest non-token event asks a question',
      () {
        final asking = [
          ev('tool_call', {'tool': 'Read'}),
          ev('tool_call', {'tool': 'AskUserQuestion'}),
          ev('token', {'text': '?'}),
        ];
        expect(deriveAgentSignals(asking, busy: true).waitingOnInput, isTrue);
        expect(deriveAgentSignals(asking, busy: false).waitingOnInput, isFalse);
        final moved = [
          ...asking,
          ev('tool_call', {'tool': 'Edit'}),
        ];
        expect(deriveAgentSignals(moved, busy: true).waitingOnInput, isFalse);
      },
    );

    test('last edited file is made relative to the worktree', () {
      final events = [
        ev('file_edit', {'tool': 'Edit', 'path': '/wt/w1/lib/rates.ts'}),
        ev('token', {'text': 'x'}),
      ];
      expect(
        deriveAgentSignals(
          events,
          busy: true,
          worktreePath: '/wt/w1',
        ).lastEditedFile,
        'lib/rates.ts',
      );
      expect(
        deriveAgentSignals(events, busy: true).lastEditedFile,
        '/wt/w1/lib/rates.ts',
      );
    });
  });

  group('parseDiffStats', () {
    test('counts files and hunk lines, not file headers', () {
      const diff = '''
diff --git a/a.ts b/a.ts
index 111..222 100644
--- a/a.ts
+++ b/a.ts
@@ -1,3 +1,4 @@
 keep
-old
+new
+more
--- a removed line that starts with dashes
diff --git a/b.ts b/b.ts
new file mode 100644
--- /dev/null
+++ b/b.ts
@@ -0,0 +1 @@
+hello
''';
      final s = parseDiffStats(diff);
      expect(s.files, 2);
      expect(s.added, 3);
      expect(s.removed, 2);
    });

    test('empty diff', () {
      expect(parseDiffStats('').isEmpty, isTrue);
    });
  });

  group('format', () {
    test('formatDuration', () {
      expect(formatDuration(const Duration(seconds: 45)), '45s');
      expect(formatDuration(const Duration(minutes: 14, seconds: 3)), '14m');
      expect(formatDuration(const Duration(hours: 1)), '1h');
      expect(formatDuration(const Duration(hours: 1, minutes: 5)), '1h 5m');
    });

    test('formatMs and relativeAgo', () {
      expect(formatMs(2013.4), '2.0s');
      expect(formatMs(125000), '2m');
      final now = DateTime.utc(2026, 9, 29, 12);
      double ago(Duration d) => now.subtract(d).millisecondsSinceEpoch / 1000;
      expect(relativeAgo(ago(const Duration(seconds: 10)), now), 'now');
      expect(relativeAgo(ago(const Duration(minutes: 2)), now), '2m');
      expect(relativeAgo(ago(const Duration(hours: 5)), now), '5h');
      expect(relativeAgo(ago(const Duration(days: 3)), now), '3d');
    });
  });
}
