import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/gate_facts.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../api/fixtures.dart';
import 'builders.dart';

void main() {
  group('spec 5.1 rows', () {
    test('idle', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.idle,
          agent: AgentPhase.none,
          activity: false,
          diff: const DiffStatsEmpty().value,
          elapsed: null,
        ),
      );
      expect(f.displayState, DisplayState.idle);
      expect(f.triageGroup, TriageGroup.idle);
      expect(lines(f), [
        'ready for a task',
        'no changes yet',
        'runs when agent finishes',
        'blocked',
      ]);
      expect(f.nextAction.kind, NextActionKind.runAgent);
      expect(f.nextAction.label, 'Run agent');
      expect(f.nextAction.enabled, isTrue);
      expect(f.defaultStep, StepKey.agent);
      expect(ticks(f), 'oooo');
      expect(f.rowDetail, 'No task yet');
      expect(f.rowAction, 'Write a task');
      expect(f.verdict.word, 'NOT RUN');
      expect(f.verdict.headline, 'The gate hasn’t run on this tree.');
      expect(f.verdict.rail, 'Runs when the agent finishes');
    });

    test('running (gate)', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.testsRunning,
          cells: cells(412, running: 3),
          expectedTotal: 594,
          // the previous run is still loaded while the new one streams
          run: run(),
        ),
      );
      expect(f.displayState, DisplayState.gate);
      expect(f.triageGroup, TriageGroup.running);
      expect(lines(f), [
        'done · 14m',
        '21 files · +367 −130',
        'running · 412 / 594',
        'waits for green',
      ]);
      expect(f.nextAction.label, 'Gate running');
      expect(f.nextAction.enabled, isFalse);
      expect(f.defaultStep, StepKey.verify);
      expect(ticks(f), 'ddco');
      expect(f.verdict.word, 'RUNNING');
      expect(f.verdict.headline, '412 of 594 tests done');
      expect(f.verdict.rail, '412 / 594 · no failures yet');
      expect(f.rowDetail, 'Gate 412 / 594 · no failures yet');
      expect(
        f.lookAt.openCount,
        0,
        reason: 'a stale run must not leak into a live one',
      );
    });

    test('running with failures so far', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.testsRunning,
          cells: cells(10, failed: 2),
          expectedTotal: 100,
        ),
      );
      expect(f.rowDetail, 'Gate 10 / 100 · 2 failing so far');
      expect(f.verdict.sub, contains('2 failing so far'));
    });

    test('running before any cell has appeared', () {
      final f = deriveWorkspaceFlow(input(WorkspaceStatus.testsRunning));
      expect(f.step(StepKey.verify).line, 'running');
      expect(f.verdict.headline, 'Gate starting');
    });

    test('red', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateRed, run: redRun(failed: 3, total: 16)),
      );
      expect(f.displayState, DisplayState.red);
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(lines(f), [
        'done · 14m',
        '21 files · +367 −130',
        'red · 3 failing',
        'blocked',
      ]);
      expect(f.nextAction.kind, NextActionKind.sendFailures);
      expect(f.nextAction.label, 'Send failures to agent');
      expect(f.nextAction.step, StepKey.agent);
      expect(f.defaultStep, StepKey.verify);
      expect(ticks(f), 'ddro');
      expect(f.verdict.word, 'RED');
      expect(f.verdict.headline, '3 tests are failing');
      expect(f.verdict.rail, '3 of 16 failing');
      expect(f.rowDetail, '3 of 16 tests failing in lib/shipping.test.ts');
      expect(f.rowAction, 'Send failures to agent');
      expect(f.lookAt.pending.where((i) => i.isFailure), hasLength(3));
    });

    test('red with one failing test uses singular copy', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateRed, run: redRun(failed: 1)),
      );
      expect(f.verdict.headline, '1 test is failing');
      expect(f.blockers.single.text, '1 failing test');
    });

    test('green, nothing open', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateGreen, run: run()),
      );
      expect(f.displayState, DisplayState.green);
      expect(f.triageGroup, TriageGroup.readyToShip);
      expect(lines(f), [
        'done · 14m',
        '21 files · +367 −130',
        'green · 594 passed',
        'ready to merge',
      ]);
      expect(f.nextAction.kind, NextActionKind.reviewAndShip);
      expect(f.nextAction.label, 'Review & ship');
      expect(f.nextAction.step, StepKey.ship);
      expect(f.defaultStep, StepKey.verify);
      expect(ticks(f), 'ddgo');
      expect(f.verdict.word, 'GREEN');
      expect(f.verdict.headline, 'All 594 tests pass');
      expect(f.verdict.sub, 'This branch is mergeable. Nothing is flagged.');
      expect(f.verdict.rail, '594 / 594 passed · mergeable');
      expect(f.rowDetail, '594 passed · nothing to look at');
      expect(f.rowAction, 'Merge');
      expect(f.openLookCount, 0);
      expect(f.tamper, isNull);
    });

    test('green with open look-at items needs you', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          run: run(
            unchecked: [
              untestedRow('lib/rates.ts', 1),
              untestedRow('lib/ship.ts', 1),
            ],
          ),
        ),
      );
      expect(f.displayState, DisplayState.green);
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(f.openLookCount, 2);
      expect(f.lookAt.pending.map((i) => i.label), [
        'NO TEST RAN',
        'NO TEST RAN',
      ]);
      expect(f.rowDetail, '594 passed · 2 lines no test ran');
      expect(f.rowAction, 'Review & ship');
      expect(f.nextAction.label, 'Review & ship');
      expect(
        f.verdict.sub,
        contains('2 changed spots weren’t exercised by any test'),
      );
    });

    test(
      'a secret_found row counts in the rail and never blocks the merge',
      () {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            run: run(unchecked: [secretRow('src/config.ts', 12)]),
          ),
        );
        expect(f.displayState, DisplayState.green);
        expect(f.blockers, isEmpty);
        expect(f.openLookCount, 1);
        expect(f.lookAt.railItems.single.shortFile, 'config.ts');
        expect(f.nextAction.kind, NextActionKind.reviewAndShip);
        expect(f.verdict.sub, contains('worth a look'));
      },
    );

    test(
      'ticking every open item off returns the workspace to ready to ship',
      () {
        final rows = [
          untestedRow('lib/rates.ts', 1),
          untestedRow('lib/ship.ts', 1),
        ];
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            run: run(unchecked: rows),
            checked: [rows[0]['key'] as String, rows[1]['key'] as String],
          ),
        );
        expect(f.triageGroup, TriageGroup.readyToShip);
        expect(f.lookAt.done, hasLength(2));
        expect(f.openLookCount, 0);
      },
    );

    test('merged', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.merged, run: run(), pr: 232),
      );
      expect(f.displayState, DisplayState.merged);
      expect(f.triageGroup, TriageGroup.merged);
      expect(lines(f), [
        'done · 14m',
        '21 files · +367 −130',
        'green · 594 passed',
        'merged · #232',
      ]);
      expect(f.nextAction.kind, NextActionKind.continueOnNewBranch);
      expect(f.nextAction.label, 'Continue on a new branch');
      expect(f.defaultStep, StepKey.ship);
      expect(ticks(f), 'dddm');
      expect(f.verdict.word, 'MERGED');
      expect(f.verdict.headline, 'Merged into origin/main');
      expect(f.verdict.sub, startsWith('PR #232 merged on a green gate.'));
      expect(f.verdict.rail, '#232 · merged on green');
      expect(f.rowDetail, 'Merged #232 into main on green');
      expect(f.rowAction, 'Archive');
    });

    test('merged without a known PR number', () {
      final f = deriveWorkspaceFlow(input(WorkspaceStatus.merged, run: run()));
      expect(f.step(StepKey.ship).line, 'merged');
      expect(f.rowDetail, 'Merged into main on green');
    });
  });

  group('plan and agent', () {
    test('plan ready to approve', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.idle,
          planReady: true,
          diff: const DiffStatsEmpty().value,
          planText: 'Plan:\n1. add helper\n2. add tests\n3. wire it\n- note',
        ),
      );
      expect(f.displayState, DisplayState.plan);
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(f.step(StepKey.agent).line, 'plan ready');
      expect(f.nextAction.kind, NextActionKind.reviewPlan);
      expect(f.nextAction.label, 'Review plan');
      expect(f.defaultStep, StepKey.agent);
      expect(ticks(f), 'cooo');
      expect(f.rowDetail, 'Plan ready to approve · 3 steps');
      expect(f.rowAction, 'Review plan');
    });

    test('plan ready without countable steps', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.idle, planReady: true, planText: 'just prose'),
      );
      expect(f.rowDetail, 'Plan ready to approve');
    });

    test('agent working', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.agentRunning,
          agent: AgentPhase.running,
          elapsed: const Duration(minutes: 3),
          diff: const DiffStatsEmpty().value,
          activityFile: 'lib/rates.ts',
        ),
      );
      expect(f.displayState, DisplayState.agent);
      expect(f.triageGroup, TriageGroup.running);
      expect(f.step(StepKey.agent).line, 'working · 3m');
      expect(f.step(StepKey.verify).line, 'runs when agent finishes');
      expect(f.nextAction.kind, NextActionKind.agentRunning);
      expect(f.nextAction.enabled, isFalse);
      expect(f.defaultStep, StepKey.agent);
      expect(ticks(f), 'cooo');
      expect(f.rowDetail, 'Agent editing lib/rates.ts · 3m in');
      expect(f.rowAction, 'Open');
    });

    test('agent working while edits already exist keeps code pending', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.agentRunning, agent: AgentPhase.running),
      );
      expect(f.step(StepKey.code).status, StepStatus.pending);
      expect(f.step(StepKey.code).line, '21 files · +367 −130');
    });

    test('agent waiting on input needs you', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.agentRunning,
          agent: AgentPhase.running,
          waiting: true,
        ),
      );
      expect(f.displayState, DisplayState.agent);
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(f.waitingOnInput, isTrue);
      expect(f.step(StepKey.agent).line, 'waiting for you');
      expect(f.nextAction.kind, NextActionKind.answerAgent);
      expect(f.nextAction.enabled, isTrue);
      expect(f.rowDetail, 'Agent waiting for your answer');
      expect(f.rowAction, 'Answer agent');
    });

    test('waiting flag is ignored when no agent is live', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateGreen, run: run(), waiting: true),
      );
      expect(f.waitingOnInput, isFalse);
    });

    test('a queued run reads as agent even while setup is running', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.settingUp,
          agent: AgentPhase.queued,
          diff: const DiffStatsEmpty().value,
        ),
      );
      expect(f.displayState, DisplayState.agent);
      expect(f.triageGroup, TriageGroup.running);
    });

    test('a stopped or errored last run is stated on the agent step', () {
      expect(
        deriveWorkspaceFlow(
          input(WorkspaceStatus.idle, agent: AgentPhase.error),
        ).step(StepKey.agent).line,
        'errored',
      );
      expect(
        deriveWorkspaceFlow(
          input(WorkspaceStatus.idle, agent: AgentPhase.stopped),
        ).step(StepKey.agent).line,
        'stopped',
      );
    });
  });

  group('idle with changes', () {
    test('agent finished, gate never ran: next action is Run gate', () {
      final f = deriveWorkspaceFlow(input(WorkspaceStatus.idle));
      expect(f.displayState, DisplayState.idle);
      expect(f.step(StepKey.verify).line, 'not run');
      expect(f.nextAction.kind, NextActionKind.runGate);
      expect(f.nextAction.label, 'Run gate');
      expect(f.rowDetail, 'Changes not gated yet');
    });
  });

  group('tamper alarm', () {
    test('green with a removed test is starred and needs you', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateGreen, run: run(tamper: [removedTest])),
      );
      expect(f.displayState, DisplayState.green);
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(f.verdict.word, 'GREEN*');
      expect(f.step(StepKey.verify).line, 'green* · 594 passed');
      expect(f.tamper, isNotNull);
      expect(
        f.tamper!.headline,
        'The agent deleted a test that covered this change.',
      );
      expect(f.tamper!.blocked, isFalse);
      expect(f.tamper!.firstRemoved!.test, contains('boundary'));
      expect(f.verdict.sub, contains('tamper alarm'));
      expect(f.lookAt.pending.single.label, 'TEST REMOVED');
      expect(f.lookAt.pending.single.blocking, isFalse);
      expect(f.rowDetail, '594 passed · 1 removed');
    });

    test(
      'vacuous-only run is a plain green with an advisory needs-your-eyes row',
      () {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            run: run(
              unchecked: [
                vacuousRow('lib/dates.test.ts', 'weekdays add nothing'),
              ],
            ),
          ),
        );
        expect(f.displayState, DisplayState.green);
        expect(f.tamper, isNull);
        expect(f.verdict.word, 'GREEN');
        expect(f.blockers, isEmpty);
        expect(f.openLookCount, 1);
        final item = f.lookAt.pending.single;
        expect(item.label, 'NEW TEST ALREADY PASSES');
        expect(item.blocking, isFalse);
        expect(item.rawKind, 'vacuous_test');
        expect(item.detail, contains('weekdays add nothing'));
        expect(
          item.detail,
          contains('guards existing behaviour, not this change'),
        );
        expect(item.review.text, contains('guards existing behaviour'));
      },
    );

    test(
      'vacuous row beside a blocking removed test: only the removal blocks',
      () {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateRed,
            run: run(
              unchecked: [
                vacuousRow('lib/dates.test.ts', 'weekdays add nothing'),
              ],
              tamper: [removedTest],
              overrides: {'tamper_blocked': true},
            ),
          ),
        );
        expect(f.displayState, DisplayState.red);
        expect(f.blockers.map((b) => b.kind), [BlockerKind.tamperBlocked]);
        expect(f.tamper!.count, 1);
        final byKind = {for (final i in f.lookAt.pending) i.rawKind: i};
        expect(byKind['removed']!.blocking, isTrue);
        expect(byKind['vacuous_test']!.blocking, isFalse);
      },
    );

    test('headlines for xfail, weakened and timeout findings', () {
      String headline(String kind, int n) {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            run: run(
              tamper: [
                for (var i = 0; i < n; i++)
                  {'kind': kind, 'file': 'tests/test_a.py', 'detail': 'd'},
              ],
            ),
          ),
        );
        return f.tamper!.headline;
      }

      expect(
        headline('xfail', 1),
        'The agent marked a test as an expected failure.',
      );
      expect(
        headline('xfail', 2),
        'The agent marked tests as expected failures.',
      );
      expect(headline('weakened', 1), 'The agent loosened an assertion.');
      expect(headline('weakened', 2), 'The agent loosened assertions.');
      expect(headline('timeout', 1), 'The agent raised a test timeout.');
      expect(headline('timeout', 2), 'The agent raised test timeouts.');
    });

    test(
      'red with a removed test still shows the alarm alongside the failures',
      () {
        final f = deriveWorkspaceFlow(
          input(WorkspaceStatus.gateRed, run: redRun(tamper: [removedTest])),
        );
        expect(f.tamper, isNotNull);
        expect(f.lookAt.pending.map((i) => i.label), [
          'FAILED',
          'FAILED',
          'FAILED',
          'TEST REMOVED',
        ]);
      },
    );

    test(
      'block mode: tamper turns the gate red and the fix is Restore tests',
      () {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateRed,
            run: run(
              status: 'failed',
              unchecked: null,
              tamper: [removedTest],
              overrides: {'tamper_blocked': true},
            ),
          ),
        );
        expect(f.displayState, DisplayState.red);
        expect(f.blockers.first.kind, BlockerKind.tamperBlocked);
        expect(f.nextAction.kind, NextActionKind.restoreTests);
        expect(f.nextAction.label, 'Restore tests');
        expect(f.step(StepKey.verify).line, 'red · tamper alarm');
        expect(f.verdict.headline, 'The test suite was weakened');
        expect(f.lookAt.pending.single.blocking, isTrue);
      },
    );

    test('multiple different kinds get the generic headline', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          run: run(
            tamper: [
              removedTest,
              {
                'kind': 'skip',
                'file': 'a.test.ts',
                'detail': '.skip added',
                'test': 'x',
              },
            ],
          ),
        ),
      );
      expect(
        f.tamper!.headline,
        'The agent weakened the test suite in 2 places.',
      );
    });
  });

  group('other red causes', () {
    test('degraded green is not shippable: red with Re-run gate', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          run: run(
            overrides: {
              'degraded_reasons': ['coverage tool missing'],
            },
          ),
        ),
      );
      expect(f.displayState, DisplayState.red);
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(f.nextAction.kind, NextActionKind.rerunGate);
      expect(f.step(StepKey.verify).line, 'red · a check didn’t run');
      expect(f.verdict.headline, 'The gate couldn’t check everything');
      expect(f.step(StepKey.ship).line, 'blocked');
    });

    test('dashboard card: a red summary with passing tests and tamper is the tamper block', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          summary: GateSummary.fromJson({
            ...gateSummaryJson(unchecked: 0, tamperCount: 2),
            'tamper_note': '1 removed',
          }),
        ),
      );
      expect(f.displayState, DisplayState.red);
      expect(f.blockers.first.kind, BlockerKind.tamperBlocked);
      expect(f.nextAction.kind, NextActionKind.restoreTests);
    });

    test('gate error (setup) is NOT RUN with the framing copy', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          run: run(
            status: 'error',
            total: 0,
            passed: 0,
            unchecked: null,
            overrides: {'error_kind': 'setup'},
          ),
        ),
      );
      expect(f.displayState, DisplayState.red);
      expect(f.verdict.word, 'NOT RUN');
      expect(f.verdict.headline, 'The gate couldn’t run: setup failed');
      expect(f.step(StepKey.verify).line, 'red · didn’t run');
      expect(f.nextAction.label, 'Re-run gate');
      expect(f.rowDetail, 'The gate couldn’t run: setup failed');
    });

    test('adopted worktree with a setup error re-runs setup', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          kind: WorkspaceKind.adopted,
          run: run(
            status: 'error',
            total: 0,
            passed: 0,
            unchecked: null,
            overrides: {'error_kind': 'setup'},
          ),
        ),
      );
      expect(f.nextAction.kind, NextActionKind.rerunSetup);
      expect(f.verdict.headline, 'Environment, not code');
    });

    test('merge conflict and coverage guard have their own copy', () {
      final conflict = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          run: run(
            status: 'failed',
            unchecked: null,
            overrides: {
              'merge_conflict': true,
              'merge_note': 'conflict in a.ts',
            },
          ),
        ),
      );
      expect(
        conflict.verdict.headline,
        'The base branch doesn’t merge cleanly',
      );
      expect(conflict.nextAction.label, 'Send conflict to agent');
      expect(conflict.step(StepKey.verify).line, 'red · merge conflict');

      final cov = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          run: run(
            status: 'failed',
            unchecked: null,
            overrides: {
              'coverage_blocked': true,
              'coverage_note': 'coverage fell 4.2%',
              'coverage_delta': -4.2,
            },
          ),
        ),
      );
      expect(cov.nextAction.kind, NextActionKind.openGateSettings);
      expect(cov.nextAction.label, 'Relax coverage guard');
      expect(cov.verdict.headline, 'Coverage dropped below the guard');
    });

    test('red with no identifiable cause falls back to Re-run gate', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          run: run(status: 'failed', unchecked: null),
        ),
      );
      expect(f.blockers, isEmpty);
      expect(f.nextAction.kind, NextActionKind.rerunGate);
      expect(f.step(StepKey.verify).line, 'red · blocked');
    });

    test('broken worktree needs you', () {
      final f = deriveWorkspaceFlow(input(WorkspaceStatus.broken));
      expect(f.displayState, DisplayState.red);
      expect(f.triageGroup, TriageGroup.needsYou);
    });
  });

  group('sources of gate truth', () {
    test('dashboard card: summary only, no run loaded', () {
      final red = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateRed,
          summary: GateSummary.fromJson(
            gateSummaryJson(status: 'failed', total: 16, passed: 13, failed: 3),
          ),
        ),
      );
      expect(red.rowDetail, '3 of 16 tests failing');
      expect(red.step(StepKey.verify).line, 'red · 3 failing');
      expect(red.nextAction.kind, NextActionKind.sendFailures);

      final greenOpen = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          summary: GateSummary.fromJson(gateSummaryJson(unchecked: 2)),
        ),
      );
      expect(greenOpen.triageGroup, TriageGroup.needsYou);
      expect(greenOpen.openLookCount, 2);
      expect(greenOpen.rowDetail, '594 passed · 2 to look at');

      final greenClean = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          summary: GateSummary.fromJson(gateSummaryJson(unchecked: 0)),
        ),
      );
      expect(greenClean.triageGroup, TriageGroup.readyToShip);

      final starred = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          summary: GateSummary.fromJson(
            gateSummaryJson(tamperCount: 1, unchecked: 0),
          ),
        ),
      );
      expect(starred.triageGroup, TriageGroup.needsYou);
      expect(starred.step(StepKey.verify).line, 'green* · 594 passed');
      expect(starred.verdict.word, 'GREEN*');
    });

    test(
      'summary that never measured code-to-check does not invent a count',
      () {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            summary: GateSummary.fromJson(gateSummaryJson(unchecked: null)),
          ),
        );
        expect(f.openLookCount, 0);
      },
    );

    test('a watch run is never used as the verdict', () {
      final watch = run(
        status: 'failed',
        failed: 5,
        unchecked: null,
        overrides: {'trigger': 'watch'},
      );
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateGreen, run: watch),
      );
      expect(f.displayState, DisplayState.green);
      expect(f.blockers, isEmpty);
      expect(f.step(StepKey.verify).line, 'green');
    });

    test('a loaded run wins over the summary', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.gateGreen,
          run: run(passed: 600, total: 600),
          summary: GateSummary.fromJson(gateSummaryJson(passed: 1)),
        ),
      );
      expect(f.step(StepKey.verify).line, 'green · 600 passed');
    });

    test(
      'fresh open: failures come from stored cases when no cells streamed',
      () {
        final f = deriveWorkspaceFlow(
          input(WorkspaceStatus.gateRed, run: redRun(failed: 2)),
        );
        expect(f.lookAt.pending.where((i) => i.isFailure), hasLength(2));
      },
    );
  });

  test('FlowInput.fromWorkspace wires the workspace fields through', () {
    final ws = Workspace.fromJson(
      workspaceJson(
        status: 'merged',
        gate: gateSummaryJson(),
        overrides: {'last_pr_number': 232, 'base_ref': 'origin/main'},
      ),
    );
    final f = deriveWorkspaceFlow(
      FlowInput.fromWorkspace(ws, agent: AgentPhase.done, diff: bigDiff),
    );
    expect(f.displayState, DisplayState.merged);
    expect(f.step(StepKey.ship).line, 'merged · #232');
    expect(f.step(StepKey.verify).line, 'green · 594 passed');
  });

  group('status edge cases', () {
    test('unknown and archived statuses fall back to idle', () {
      expect(
        deriveWorkspaceFlow(
          input(WorkspaceStatus.unknown, diff: const DiffStatsEmpty().value),
        ).displayState,
        DisplayState.idle,
      );
      expect(
        deriveWorkspaceFlow(
          input(WorkspaceStatus.archived, diff: const DiffStatsEmpty().value),
        ).displayState,
        DisplayState.idle,
      );
    });

    test('gate_green with no run or summary still reads green', () {
      final f = deriveWorkspaceFlow(input(WorkspaceStatus.gateGreen));
      expect(f.displayState, DisplayState.green);
      expect(f.step(StepKey.verify).line, 'green');
    });

    test('adopted worktrees have no agent step and open on code', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.idle,
          kind: WorkspaceKind.adopted,
          activity: false,
          agent: AgentPhase.none,
        ),
      );
      expect(f.step(StepKey.agent).line, 'adopted, no agent');
      expect(f.step(StepKey.agent).status, StepStatus.pending);
      expect(f.defaultStep, StepKey.code);
    });

    test('there are always exactly four steps in order', () {
      for (final s in WorkspaceStatus.values) {
        final f = deriveWorkspaceFlow(input(s));
        expect(f.steps.map((x) => x.key), StepKey.values);
      }
    });

    test('exactly one primary action for every status', () {
      for (final s in WorkspaceStatus.values) {
        final f = deriveWorkspaceFlow(input(s, run: run()));
        expect(f.nextAction.label, isNotEmpty);
      }
    });

    test('no copy contains an em-dash', () {
      final all = <WorkspaceFlow>[
        for (final s in WorkspaceStatus.values)
          deriveWorkspaceFlow(input(s, run: run())),
        deriveWorkspaceFlow(
          input(WorkspaceStatus.gateRed, run: redRun(tamper: [removedTest])),
        ),
        deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateRed,
            run: run(
              status: 'error',
              unchecked: null,
              overrides: {'error_kind': 'runner'},
            ),
          ),
        ),
      ];
      for (final f in all) {
        final text = [
          ...lines(f),
          f.nextAction.label,
          f.rowDetail,
          f.rowAction,
          f.verdict.headline,
          f.verdict.sub,
          f.verdict.rail,
          f.tamper?.headline ?? '',
        ].join('\n');
        expect(text.contains('—'), isFalse, reason: text);
      }
    });
  });
}
