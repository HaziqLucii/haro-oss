import '../../../data/workspace_actions.dart';
import '../../../state/workspace_flow.dart';

/// What the page lends the next-action button: navigation and the few things that are not a
/// `WorkspaceActions` call.
class NextActionEnv {
  const NextActionEnv({
    required this.actions,
    required this.goToStep,
    required this.focusComposer,
    required this.openGateSettings,
    required this.rerunSetup,
    this.home = StepKey.agent,
    this.saveEdits,
  });

  final WorkspaceActions actions;
  final void Function(StepKey step) goToStep;
  final void Function() focusComposer;
  final void Function() openGateSettings;
  final Future<void> Function() rerunSetup;

  /// Writes every open file with unsaved edits (throws if one cannot be saved). The code step's
  /// "Save & run gate" needs it; null elsewhere.
  final Future<void> Function()? saveEdits;

  /// Where a fresh start lands: the agent step, or code in a manual workspace.
  final StepKey home;
}

/// Maps the one primary action to its effect (the prototype's `next()`, wired to the real
/// backend). Navigation happens first where the result streams in on the destination step, so
/// the click never feels stuck behind a multi-second request; a failure is rethrown for the
/// page to show.
Future<void> performNextAction(NextAction action, NextActionEnv env) async {
  if (!action.enabled) return;
  switch (action.kind) {
    case NextActionKind.agentRunning:
    case NextActionKind.gateRunning:
      return;
    case NextActionKind.runAgent:
    case NextActionKind.answerAgent:
      env.goToStep(StepKey.agent);
      env.focusComposer();
    case NextActionKind.reviewPlan:
    case NextActionKind.reviewAcceptance:
      env.goToStep(StepKey.agent);
    case NextActionKind.runGate:
    case NextActionKind.rerunGate:
      env.goToStep(StepKey.verify);
      await env.actions.runGate();
    case NextActionKind.rerunSetup:
      env.goToStep(StepKey.verify);
      await env.rerunSetup();
    case NextActionKind.sendFailures:
      await env.actions.sendFailuresToAgent();
      env.goToStep(StepKey.agent);
    case NextActionKind.restoreTests:
      await env.actions.restoreTests();
      env.goToStep(StepKey.agent);
    case NextActionKind.openGateSettings:
      env.openGateSettings();
    case NextActionKind.reviewAndShip:
      env.goToStep(StepKey.ship);
    case NextActionKind.continueOnNewBranch:
      await env.actions.continueOnNewBranch();
      env.goToStep(env.home);
      if (env.home == StepKey.agent) env.focusComposer();
    case NextActionKind.startCoding:
    case NextActionKind.backToCode:
      env.goToStep(StepKey.code);
    case NextActionKind.saveAndRunGate:
      await env.saveEdits?.call();
      await env.actions.runGate();
  }
}
