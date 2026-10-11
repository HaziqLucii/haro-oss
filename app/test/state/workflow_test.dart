import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/workflow.dart';
import 'package:haro_app/state/workspace_flow.dart';

void main() {
  const runGate = NextAction(
    NextActionKind.runGate,
    'Run gate',
    step: StepKey.verify,
  );
  const rerun = NextAction(
    NextActionKind.rerunGate,
    'Re-run gate',
    step: StepKey.verify,
  );
  const ship = NextAction(
    NextActionKind.reviewAndShip,
    'Review & ship',
    step: StepKey.ship,
  );

  group('order', () {
    test('before and after follow the steps the workspace shows', () {
      expect(stepAfter(StepKey.agent, WorkspaceMode.agent), StepKey.code);
      expect(stepAfter(StepKey.ship, WorkspaceMode.agent), isNull);
      expect(stepBefore(StepKey.agent, WorkspaceMode.agent), isNull);
      expect(stepBefore(StepKey.code, WorkspaceMode.manual), isNull);
      expect(stepBefore(StepKey.ship, WorkspaceMode.agent), StepKey.verify);
    });

    test('review is what step three is called, the key stays verify', () {
      expect(stepLabel(StepKey.verify), 'review');
      expect(StepKey.verify.name, 'verify');
      expect(stepLabel(StepKey.agent), 'agent');
    });
  });

  group('withWorkflow', () {
    NextAction on(NextAction base, StepKey active) =>
        withWorkflow(base, active: active, mode: WorkspaceMode.agent);

    test('the gate and ship are only offered one step at a time', () {
      for (final base in [runGate, rerun, ship]) {
        expect(on(base, StepKey.agent).kind, NextActionKind.proceedToCode);
        expect(on(base, StepKey.code).kind, NextActionKind.proceedToReview);
      }
    });

    test('a red gate never leaves review out of reach from the code step', () {
      for (final kind in [
        NextActionKind.sendFailures,
        NextActionKind.restoreTests,
        NextActionKind.rerunSetup,
        NextActionKind.openGateSettings,
        NextActionKind.backToCode,
      ]) {
        final base = NextAction(kind, 'fix', step: StepKey.agent);
        expect(
          on(base, StepKey.code).kind,
          NextActionKind.proceedToReview,
          reason: '$kind from code',
        );
        expect(on(base, StepKey.verify), same(base), reason: '$kind on review');
      }
    });

    test("sending failures to the agent stays the agent step's own action", () {
      for (final kind in [
        NextActionKind.sendFailures,
        NextActionKind.restoreTests,
      ]) {
        final base = NextAction(kind, 'fix', step: StepKey.agent);
        expect(on(base, StepKey.agent), same(base), reason: '$kind');
      }
      const setup = NextAction(
        NextActionKind.rerunSetup,
        'Re-run setup',
        step: StepKey.verify,
      );
      expect(on(setup, StepKey.agent).kind, NextActionKind.proceedToCode);
    });

    test('an action that belongs to the step you are on is left alone', () {
      for (final kind in [
        NextActionKind.runAgent,
        NextActionKind.answerAgent,
        NextActionKind.reviewPlan,
        NextActionKind.agentRunning,
        NextActionKind.startCoding,
        NextActionKind.saveAndRunGate,
      ]) {
        final base = NextAction(kind, 'x', step: StepKey.agent);
        expect(on(base, StepKey.agent), same(base), reason: '$kind');
        expect(on(base, StepKey.code), same(base), reason: '$kind');
      }
    });

    test(
      'on review, ship is Proceed to ship and the gate is still the gate',
      () {
        final proceed = on(ship, StepKey.verify);
        expect(proceed.kind, NextActionKind.reviewAndShip);
        expect(proceed.label, 'Proceed to ship');
        expect(proceed.step, StepKey.ship);
        expect(on(runGate, StepKey.verify), same(runGate));
        expect(on(rerun, StepKey.verify), same(rerun));
      },
    );

    test('Proceed to ship stays disabled until the files are viewed', () {
      final a = withWorkflow(
        ship,
        active: StepKey.verify,
        mode: WorkspaceMode.agent,
        filesViewed: false,
      );
      expect(a.kind, NextActionKind.reviewAndShip);
      expect(a.enabled, isFalse);
      expect(on(ship, StepKey.verify).enabled, isTrue);
    });

    test('at the last step and for every other action nothing changes', () {
      expect(on(ship, StepKey.ship), same(ship));
      const answer = NextAction(
        NextActionKind.answerAgent,
        'Answer the agent',
        step: StepKey.agent,
      );
      expect(on(answer, StepKey.code), same(answer));
    });

    test(
      'a manual workspace starts at code and has no agent to proceed from',
      () {
        final a = withWorkflow(
          runGate,
          active: StepKey.code,
          mode: WorkspaceMode.manual,
        );
        expect(a.kind, NextActionKind.proceedToReview);
      },
    );

    test('a disabled action stays disabled when it becomes a Proceed', () {
      const off = NextAction(
        NextActionKind.runGate,
        'Run gate',
        enabled: false,
        step: StepKey.verify,
      );
      expect(on(off, StepKey.agent).enabled, isFalse);
    });
  });
}
