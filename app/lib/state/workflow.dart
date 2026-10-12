import '../api/models/models.dart';
import 'workspace_flow.dart';

/// The step-by-step workflow: you work one step at a time. Only the step you are on is
/// clickable; every other step, earlier or later, is dimmed. **Proceed** opens the next step and
/// **Back to** the one before, so the steps are done in order and redone in order. This is only
/// a view over the facts: green stays green and red stays red, whatever is dimmed.

/// The step after [step] in this workspace, or null at the last one.
StepKey? stepAfter(StepKey step, WorkspaceMode mode) {
  final steps = visibleSteps(mode);
  final i = steps.indexOf(step);
  return i >= 0 && i + 1 < steps.length ? steps[i + 1] : null;
}

/// The step before [step] in this workspace, or null at the first one.
StepKey? stepBefore(StepKey step, WorkspaceMode mode) {
  final steps = visibleSteps(mode);
  final i = steps.indexOf(step);
  return i > 0 ? steps[i - 1] : null;
}

/// The actions the review step owns: run or re-run the gate, fix what failed, and ship. On the
/// steps before review the way on is Proceed instead.
const _reviewActions = {
  NextActionKind.runGate,
  NextActionKind.rerunGate,
  NextActionKind.reviewAndShip,
  NextActionKind.sendFailures,
  NextActionKind.restoreTests,
  NextActionKind.rerunSetup,
  NextActionKind.openGateSettings,
  NextActionKind.backToCode,
};

/// Turns the flow's actions into one step at a time. The flow words them for the state alone
/// (an idle workspace with a diff says "Run gate", a green one "Review & ship", a red one "Send
/// failures to the agent"). On the agent and code steps those become "Proceed to the step after
/// the one you are on", so review is always reachable and the gate is only ever started from
/// there. On review itself only the green action changes, to "Proceed to ship", which also waits
/// for every changed file to be marked viewed ([filesViewed]). Every action that
/// belongs to the step you are on (run the agent, answer it, write code) is left as it is.
NextAction withWorkflow(
  NextAction base, {
  required StepKey active,
  required WorkspaceMode mode,
  bool filesViewed = true,
}) {
  final next = stepAfter(active, mode);
  if (next == null) return base;
  if (next == StepKey.ship) {
    return base.kind == NextActionKind.reviewAndShip
        ? NextAction(
            NextActionKind.reviewAndShip,
            'Proceed to ship',
            enabled: base.enabled && filesViewed,
            step: base.step,
          )
        : base;
  }
  if (!_reviewActions.contains(base.kind)) return base;
  // Sending failures to the agent, or restoring tests, is the agent step's own action: on that
  // step it is the primary, and the step does not also offer a Proceed beside it.
  if (active == StepKey.agent &&
      (base.kind == NextActionKind.sendFailures ||
          base.kind == NextActionKind.restoreTests)) {
    return base;
  }
  return next == StepKey.verify
      ? NextAction(
          NextActionKind.proceedToReview,
          'Proceed to review',
          enabled: base.enabled,
          step: StepKey.verify,
        )
      : NextAction(
          NextActionKind.proceedToCode,
          'Proceed to code',
          enabled: base.enabled,
          step: StepKey.code,
        );
}
