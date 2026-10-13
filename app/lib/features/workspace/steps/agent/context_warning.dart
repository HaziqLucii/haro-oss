import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_store.dart';
import '../../../../overlays/toast.dart';
import '../../../../state/workspace_flow.dart' show AgentPhase;
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/shell_icons.dart';
import '../../../new_workspace/new_workspace_overlay.dart';
import '../../../settings/notification_prefs_provider.dart';
import '../../rail/run_facts.dart';
import 'agent_tokens.dart';

/// `168k`, `1.2M`: a token count as a short figure.
String shortTokens(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    return '${m.toStringAsFixed(m == m.roundToDouble() ? 0 : 1)}M';
  }
  return n >= 1000 ? '${(n / 1000).round()}k' : '$n';
}

/// A strip above the composer once the session's context window passes the share set in
/// Settings > Notifications: clear it (the next run starts a fresh conversation) or start the
/// next piece of work in a new workspace. Nothing is blocked; dismissing hides it until the
/// next run reports a new figure.
class ContextWarning extends ConsumerStatefulWidget {
  const ContextWarning(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<ContextWarning> createState() => _ContextWarningState();
}

class _ContextWarningState extends ConsumerState<ContextWarning> {
  double? _hiddenAt;
  bool _clearing = false;

  Future<void> _clear(ContextUsage usage) async {
    setState(() => _clearing = true);
    try {
      await ref.read(haroApiProvider).clearContext(widget.workspaceId);
      if (mounted) setState(() => _hiddenAt = usage.ts);
    } catch (e) {
      if (mounted) showHaroToast(context, 'Could not clear the context: $e');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final threshold = ref.watch(
      notificationPrefsProvider.select((p) => p.contextWarnPercent),
    );
    final detail = workspaceDetailProvider(widget.workspaceId);
    final running = ref.watch(
      detail.select((d) => d.agentPhase == AgentPhase.running),
    );
    final events = ref.watch(detail.select((d) => d.events));
    final projectId = ref.watch(detail.select((d) => d.workspace?.projectId));
    final usage = contextUsage(events);
    if (threshold <= 0 ||
        running ||
        usage == null ||
        usage.percent < threshold ||
        _hiddenAt == usage.ts) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AgentTokens.columnMax),
          child: Container(
            key: const ValueKey('context-warning'),
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: BoxDecoration(
              color: HaroTokens.panel,
              border: Border.all(color: HaroTokens.line20),
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${usage.percent}%',
                          style: TextStyle(color: HaroTokens.warn),
                        ),
                        TextSpan(
                          text:
                              ' of the context is used (${shortTokens(usage.tokens)} of ${shortTokens(usage.window)} tokens). A long context costs more and answers worse.',
                        ),
                      ],
                    ),
                    style: HaroText.ui(size: 13, color: HaroTokens.ink66),
                  ),
                ),
                const SizedBox(width: 12),
                HaroButton(
                  key: const ValueKey('context-clear'),
                  label: 'Clear',
                  leading: ShellIcon.eraser,
                  height: 28,
                  fontSize: 12.5,
                  tooltip:
                      'The next run starts a fresh conversation. Files stay.',
                  onPressed: _clearing ? null : () => _clear(usage),
                ),
                const SizedBox(width: 6),
                HaroButton(
                  key: const ValueKey('context-new-workspace'),
                  label: 'Start in new workspace',
                  leading: ShellIcon.plus,
                  height: 28,
                  fontSize: 12.5,
                  onPressed: () =>
                      showNewWorkspace(context, projectId: projectId),
                ),
                const SizedBox(width: 6),
                ShellIconButton(
                  key: const ValueKey('context-dismiss'),
                  icon: ShellIcon.close,
                  tooltip: 'Dismiss',
                  width: 28,
                  height: 28,
                  iconSize: 14,
                  onTap: () => setState(() => _hiddenAt = usage.ts),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
