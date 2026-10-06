import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_actions.dart';
import '../../overlays/overlay.dart';
import '../../overlays/toast.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';

const manualOnToast = 'Manual: the agent is off for this workspace';
const agentOnToast = 'Agent: the agent can write in this workspace again';

const switchToAgentTitle = 'Switch this workspace to Agent?';
const switchToAgentRows = [
  ('→', 'The agent picks up the worktree and the red gate.'),
  ('·', 'Your hand-written work is committed as a checkpoint and stays yours.'),
  ('·', 'Nothing about the gate changes. It still has to be green to merge.'),
];
const switchToAgentFooter = 'You can switch back any time.';

/// The palette action that switches a workspace to [target].
String switchModeLabel(WorkspaceMode target) => target == WorkspaceMode.manual
    ? 'Switch to Manual mode'
    : 'Switch to Agent mode';

/// Confirm before handing a manual workspace to the agent (Manual Journey, step 15).
/// Resolves true only for "Switch to Agent".
Future<bool> confirmSwitchToAgent(BuildContext context) async =>
    await showHaroOverlay<bool>(
      context,
      width: 520,
      child: const _SwitchToAgentDialog(),
    ) ??
    false;

/// One flow for the top bar and the palette. Going to manual is immediate; going to agent
/// asks first. A refusal from the backend (an agent or a gate run is live) shows as a toast.
Future<void> requestWorkspaceModeSwitch(
  BuildContext context,
  WidgetRef ref, {
  required String workspaceId,
  required WorkspaceMode target,
}) async {
  if (target == WorkspaceMode.agent && !await confirmSwitchToAgent(context)) {
    return;
  }
  try {
    await ref.read(workspaceActionsProvider(workspaceId)).setMode(target);
    if (context.mounted) {
      showHaroToast(
        context,
        target == WorkspaceMode.manual ? manualOnToast : agentOnToast,
      );
    }
  } on HaroApiException catch (e) {
    if (context.mounted) showHaroToast(context, e.message);
  }
}

class _SwitchToAgentDialog extends StatelessWidget {
  const _SwitchToAgentDialog();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              switchToAgentTitle,
              key: const ValueKey('mode-confirm-title'),
              style: HaroText.ui(size: 21, weight: FontWeight.w500),
            ),
            const SizedBox(height: 14),
            DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: HaroTokens.line12)),
              ),
              child: Column(
                children: [
                  for (final (marker, text) in switchToAgentRows)
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: HaroTokens.line08),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 26,
                              child: Text(
                                marker,
                                style: HaroText.mono(
                                  size: 13,
                                  color: HaroTokens.ink42,
                                  tracking: 0,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                text,
                                style: HaroText.ui(size: 13.5, height: 1.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HaroTokens.line12)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                switchToAgentFooter,
                style: HaroText.ui(size: 12, color: HaroTokens.ink42),
              ),
            ),
            HaroButton(
              key: const ValueKey('mode-confirm-keep'),
              label: 'Keep writing',
              height: 34,
              fontSize: 13.5,
              onPressed: () => closeHaroOverlay(context, false),
            ),
            const SizedBox(width: 8),
            HaroButton(
              key: const ValueKey('mode-confirm-switch'),
              label: 'Switch to Agent',
              height: 34,
              fontSize: 13.5,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              variant: HaroButtonVariant.primary,
              onPressed: () => closeHaroOverlay(context, true),
            ),
          ],
        ),
      ),
    ],
  );
}
