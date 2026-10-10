import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../api/fixtures.dart';
import 'builders.dart';

WorkspaceFlow manual(
  WorkspaceStatus status, {
  TestRun? run,
  bool planReady = false,
  TestFirstState? testFirst,
  AgentPhase agent = AgentPhase.none,
  bool noChanges = false,
}) => deriveWorkspaceFlow(
  input(
    status,
    mode: WorkspaceMode.manual,
    agent: agent,
    activity: false,
    elapsed: null,
    run: run,
    planReady: planReady,
    testFirst: testFirst,
    diff: noChanges ? const DiffStatsEmpty().value : bigDiff,
  ),
);

const _agentKinds = {
  NextActionKind.runAgent,
  NextActionKind.agentRunning,
  NextActionKind.answerAgent,
  NextActionKind.reviewPlan,
  NextActionKind.reviewAcceptance,
  NextActionKind.sendFailures,
  NextActionKind.restoreTests,
};

void main() {
  group('step helpers', () {
    test('manual shows code, verify, ship; agent shows all four', () {
      expect(visibleSteps(WorkspaceMode.manual), [
        StepKey.code,
        StepKey.verify,
        StepKey.ship,
      ]);
      expect(visibleSteps(WorkspaceMode.agent), StepKey.values);
    });

    test('a hidden step falls back to the home step', () {
      expect(clampStep(StepKey.agent, WorkspaceMode.manual), StepKey.code);
      expect(clampStep(StepKey.ship, WorkspaceMode.manual), StepKey.ship);
      expect(clampStep(StepKey.agent, WorkspaceMode.agent), StepKey.agent);
      expect(homeStep(WorkspaceMode.manual), StepKey.code);
      expect(homeStep(WorkspaceMode.agent), StepKey.agent);
    });
  });

  group('manual flow', () {
    test(
      'idle with nothing written: code is current, next is Start coding',
      () {
        final f = manual(WorkspaceStatus.idle, noChanges: true);
        expect(f.mode, WorkspaceMode.manual);
        expect(f.steps.map((s) => s.key), [
          StepKey.code,
          StepKey.verify,
          StepKey.ship,
        ]);
        expect(lines(f), ['no changes yet', 'not run', 'blocked']);
        expect(f.step(StepKey.code).status, StepStatus.current);
        expect(f.defaultStep, StepKey.code);
        expect(f.nextAction.kind, NextActionKind.startCoding);
        expect(f.nextAction.label, 'Start coding');
        expect(f.nextAction.step, StepKey.code);
        expect(f.rowAction, 'Start coding');
        expect(f.rowDetail, 'No changes yet');
        expect(ticks(f), 'ooo');
        expect(f.verdict.rail, 'Not run yet');
        expect(f.verdict.sub, isNot(contains('agent')));
      },
    );

    test('there is no agent step to ask for', () {
      final f = manual(WorkspaceStatus.idle);
      expect(() => f.step(StepKey.agent), throwsStateError);
    });

    test('idle with changes: run the gate', () {
      final f = manual(WorkspaceStatus.idle);
      expect(f.nextAction.kind, NextActionKind.runGate);
      expect(f.step(StepKey.code).status, StepStatus.done);
      expect(f.step(StepKey.verify).line, 'not run');
      expect(f.rowDetail, 'Changes not gated yet');
      expect(f.defaultStep, StepKey.code);
    });

    test('a stale agent_running status does not bring the agent back', () {
      final f = manual(WorkspaceStatus.agentRunning, agent: AgentPhase.running);
      expect(f.displayState, DisplayState.idle);
      expect(f.steps.any((s) => s.key == StepKey.agent), isFalse);
    });

    test('a leftover plan or test-first state is ignored', () {
      final plan = manual(WorkspaceStatus.idle, planReady: true);
      expect(plan.displayState, DisplayState.idle);
      expect(plan.nextAction.kind, NextActionKind.runGate);

      final tf = manual(
        WorkspaceStatus.idle,
        testFirst: TestFirstState.fromJson({'phase': 'review', 'task': 't'}),
      );
      expect(tf.displayState, DisplayState.idle);
      expect(tf.acceptanceReview, isFalse);
      expect(tf.nextAction.kind, NextActionKind.runGate);
    });

    test('red on failing tests: Back to code, never send to the agent', () {
      final f = manual(WorkspaceStatus.gateRed, run: redRun());
      expect(f.displayState, DisplayState.red);
      expect(f.nextAction.kind, NextActionKind.backToCode);
      expect(f.nextAction.label, 'Back to code');
      expect(f.nextAction.step, StepKey.code);
      expect(f.rowAction, 'Back to code');
      expect(
        f.verdict.sub,
        'This branch can’t merge until they pass. Fix them in code.',
      );
    });

    test('a conflict and a tamper block also send you to code', () {
      final conflict = manual(
        WorkspaceStatus.gateRed,
        run: run(
          status: 'failed',
          unchecked: null,
          overrides: {'merge_conflict': true, 'merge_note': 'conflict in a.ts'},
        ),
      );
      expect(conflict.nextAction.kind, NextActionKind.backToCode);

      final tamper = manual(
        WorkspaceStatus.gateRed,
        run: run(
          status: 'failed',
          unchecked: null,
          tamper: [removedTest],
          overrides: {'tamper_blocked': true},
        ),
      );
      expect(tamper.nextAction.kind, NextActionKind.backToCode);
    });

    test('green ships and merged continues, same as agent mode', () {
      expect(
        manual(WorkspaceStatus.gateGreen, run: run()).nextAction.kind,
        NextActionKind.reviewAndShip,
      );
      expect(
        manual(WorkspaceStatus.merged, run: run()).nextAction.kind,
        NextActionKind.continueOnNewBranch,
      );
      final merged = manual(WorkspaceStatus.merged, run: run());
      expect(merged.defaultStep, StepKey.ship);
    });

    test('gate states keep their default step', () {
      expect(
        manual(WorkspaceStatus.testsRunning, run: run()).defaultStep,
        StepKey.verify,
      );
      expect(
        manual(WorkspaceStatus.gateRed, run: redRun()).defaultStep,
        StepKey.verify,
      );
    });

    test('no state offers an action that runs the agent', () {
      final runs = <TestRun?>[
        null,
        run(),
        redRun(),
        run(
          status: 'failed',
          unchecked: null,
          overrides: {'merge_conflict': true, 'merge_note': 'x'},
        ),
        run(
          status: 'failed',
          unchecked: null,
          tamper: [removedTest],
          overrides: {'tamper_blocked': true},
        ),
        run(
          status: 'error',
          unchecked: null,
          overrides: {'error_kind': 'runner'},
        ),
      ];
      for (final status in WorkspaceStatus.values) {
        for (final r in runs) {
          for (final noChanges in [false, true]) {
            final f = manual(
              status,
              run: r,
              noChanges: noChanges,
              agent: AgentPhase.running,
              planReady: true,
            );
            expect(
              _agentKinds.contains(f.nextAction.kind),
              isFalse,
              reason:
                  '$status ${r?.status} noChanges=$noChanges -> ${f.nextAction.kind}',
            );
            expect(f.displayState, isNot(DisplayState.agent));
            expect(f.displayState, isNot(DisplayState.plan));
          }
        }
      }
    });

    group('tamper wording', () {
      const kinds = [
        'removed',
        'skip',
        'xfail',
        'weakened',
        'timeout',
        'only',
        'todo',
        'assertions',
        'snapshot',
        'mystery',
      ];

      String? headline(String kind, int n, WorkspaceMode mode) {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            mode: mode,
            run: run(
              tamper: [
                for (var i = 0; i < n; i++)
                  {'kind': kind, 'file': 'tests/test_a.py', 'detail': 'd'},
              ],
            ),
          ),
        );
        return f.tamper?.headline;
      }

      test('no finding kind blames the agent in a manual workspace', () {
        for (final kind in kinds) {
          for (final n in [1, 2]) {
            final h = headline(kind, n, WorkspaceMode.manual)!;
            expect(
              h.toLowerCase(),
              isNot(contains('agent')),
              reason: '$kind x$n',
            );
            expect(h, isNot(contains('You ')), reason: '$kind x$n');
          }
        }
      });

      test('the same findings still name the agent in agent mode', () {
        for (final kind in kinds) {
          expect(
            headline(kind, 1, WorkspaceMode.agent),
            startsWith('The agent '),
          );
        }
      });

      test('manual headlines read as plain statements', () {
        expect(
          headline('removed', 1, WorkspaceMode.manual),
          'A test that covered this change was deleted.',
        );
        expect(
          headline('removed', 3, WorkspaceMode.manual),
          '3 tests that covered this change were deleted.',
        );
        expect(
          headline('xfail', 2, WorkspaceMode.manual),
          'Tests were marked as expected failures.',
        );
        expect(
          headline('mystery', 1, WorkspaceMode.manual),
          'The test suite was weakened.',
        );
      });

      test('mixed and unknown findings say the suite was weakened', () {
        final f = deriveWorkspaceFlow(
          input(
            WorkspaceStatus.gateGreen,
            mode: WorkspaceMode.manual,
            run: run(
              tamper: [
                {'kind': 'skip', 'file': 'a', 'detail': 'd'},
                {'kind': 'removed', 'file': 'a', 'detail': 'd'},
              ],
            ),
          ),
        );
        expect(f.tamper!.headline, 'The test suite was weakened in 2 places.');
      });

      test('manual gate copy never mentions the agent', () {
        final flows = [
          manual(WorkspaceStatus.idle, noChanges: true),
          manual(WorkspaceStatus.idle),
          manual(WorkspaceStatus.gateRed, run: redRun()),
          manual(WorkspaceStatus.gateGreen, run: run(tamper: [removedTest])),
          manual(WorkspaceStatus.merged, run: run()),
        ];
        for (final f in flows) {
          final copy = [
            f.verdict.headline,
            f.verdict.sub,
            f.verdict.rail,
            f.rowDetail,
            f.rowAction,
            f.nextAction.label,
            ...f.steps.map((s) => s.line),
            ?f.tamper?.headline,
          ].join(' | ').toLowerCase();
          expect(copy, isNot(contains('agent')), reason: copy);
        }
      });
    });

    test('agent mode is untouched: four steps, agent actions', () {
      final f = deriveWorkspaceFlow(
        input(WorkspaceStatus.gateRed, run: redRun()),
      );
      expect(f.mode, WorkspaceMode.agent);
      expect(f.steps, hasLength(4));
      expect(f.nextAction.kind, NextActionKind.sendFailures);
    });

    test('FlowInput.fromWorkspace carries the workspace mode', () {
      final ws = Workspace.fromJson(
        workspaceJson(overrides: {'mode': 'manual'}),
      );
      final f = deriveWorkspaceFlow(FlowInput.fromWorkspace(ws));
      expect(f.manual, isTrue);
      expect(f.steps, hasLength(3));
    });
  });
}
