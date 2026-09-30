import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/workspace_flow.dart';

import 'builders.dart';

NextAction base(
  WorkspaceStatus status, {
  WorkspaceMode mode = WorkspaceMode.agent,
  TestRun? run,
}) => deriveWorkspaceFlow(input(status, mode: mode, run: run)).nextAction;

void main() {
  group('withUnsavedEdits', () {
    test('leaves the action alone when nothing is unsaved', () {
      final a = base(WorkspaceStatus.gateGreen, run: run());
      expect(withUnsavedEdits(a, active: StepKey.code, dirty: false), same(a));
    });

    test('a green gate offers Save & run gate on the code step', () {
      final a = base(WorkspaceStatus.gateGreen, run: run());
      expect(a.kind, NextActionKind.reviewAndShip);
      final b = withUnsavedEdits(a, active: StepKey.code, dirty: true);
      expect(b.kind, NextActionKind.saveAndRunGate);
      expect(b.label, 'Save & run gate');
      expect(b.enabled, isTrue);
      expect(b.step, isNull, reason: 'stays on the code step');
    });

    test('a red gate and an ungated tree replace their gate actions too', () {
      final red = base(WorkspaceStatus.gateRed, run: redRun());
      final idle = base(WorkspaceStatus.idle);
      for (final a in [red, idle]) {
        expect(
          withUnsavedEdits(a, active: StepKey.code, dirty: true).kind,
          NextActionKind.saveAndRunGate,
          reason: a.kind.name,
        );
      }
    });

    test('a manual workspace starting to code gets it as well', () {
      final a = base(WorkspaceStatus.idle, mode: WorkspaceMode.manual);
      expect(
        withUnsavedEdits(a, active: StepKey.code, dirty: true).kind,
        NextActionKind.saveAndRunGate,
      );
    });

    test('only the code step is affected', () {
      final a = base(WorkspaceStatus.gateGreen, run: run());
      for (final step in [StepKey.agent, StepKey.verify, StepKey.ship]) {
        expect(withUnsavedEdits(a, active: step, dirty: true), same(a));
      }
    });

    test('a running gate or agent is never replaced', () {
      final gate = base(WorkspaceStatus.testsRunning);
      final agent = base(WorkspaceStatus.agentRunning);
      expect(
        withUnsavedEdits(gate, active: StepKey.code, dirty: true),
        same(gate),
      );
      expect(
        withUnsavedEdits(agent, active: StepKey.code, dirty: true),
        same(agent),
      );
    });

    test('answering the agent or reviewing a plan is never replaced', () {
      const answer = NextAction(
        NextActionKind.answerAgent,
        'Answer agent',
        step: StepKey.agent,
      );
      const plan = NextAction(
        NextActionKind.reviewPlan,
        'Review plan',
        step: StepKey.agent,
      );
      for (final a in [answer, plan]) {
        expect(withUnsavedEdits(a, active: StepKey.code, dirty: true), same(a));
      }
    });

    test('merged keeps Continue on a new branch', () {
      final a = base(WorkspaceStatus.merged, run: run());
      expect(withUnsavedEdits(a, active: StepKey.code, dirty: true), same(a));
    });
  });
}
