import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models/models.dart';
import '../../data/workspace_detail.dart';
import '../../state/workspace_flow.dart';
import 'workspace_ui.dart' show workspaceStepPath;

/// Opens [step] on behalf of an action (a Proceed, a Back, "send failures to the agent", "Go to
/// the agent"). A manual workspace has no agent step, so it lands on the code step. Plain
/// step-bar clicks are not a way here: only the current step is clickable there.
void moveToStep(WidgetRef ref, BuildContext context, String id, StepKey step) {
  final mode = ref.read(workspaceFlowProvider(id))?.mode ?? WorkspaceMode.agent;
  context.go(workspaceStepPath(id, clampStep(step, mode)));
}
