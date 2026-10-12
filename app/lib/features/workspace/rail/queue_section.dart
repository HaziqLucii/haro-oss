import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/haro_api.dart';
import '../../../api/models/models.dart';
import '../../../data/workspace_actions.dart';
import '../../../data/workspace_detail.dart';
import '../../../overlays/toast.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/shell_icons.dart';
import '../steps/agent/composer_state.dart' show canQueuePrompt;

TextStyle _label() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

/// Prompts typed while the agent was busy. They start by themselves, one run each, when the
/// current run finishes; clicking one sends it now: into the running agent at its next step
/// (steering, nothing is stopped), or as a new run when nothing is running. Not shown when
/// there is nothing queued.
class QueueSection extends ConsumerWidget {
  const QueueSection({super.key, required this.workspaceId});

  final String workspaceId;

  Future<void> _send(
    BuildContext context,
    WidgetRef ref,
    QueuedPrompt q,
  ) async {
    try {
      await ref
          .read(workspaceActionsProvider(workspaceId))
          .sendQueuedPrompt(q.id);
    } on HaroApiException catch (e) {
      if (context.mounted) showHaroToast(context, e.message);
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    QueuedPrompt q,
  ) async {
    try {
      await ref.read(workspaceActionsProvider(workspaceId)).unqueuePrompt(q.id);
    } on HaroApiException catch (e) {
      if (context.mounted) showHaroToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(
      workspaceDetailProvider(workspaceId)
          .select((d) => d.workspace?.queuedPrompts ?? const <QueuedPrompt>[]),
    );
    final running = ref.watch(
      workspaceDetailProvider(workspaceId).select(
        (d) => canQueuePrompt(
          status: d.workspace?.status,
          phase: d.agentPhase,
          sending: false,
        ),
      ),
    );
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('rail-queue'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('QUEUE', style: _label()),
              Text(
                '${items.length}',
                key: const ValueKey('rail-queue-count'),
                style: _label(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            running
                ? 'Each starts when this run ends. Click one to steer it in now.'
                : 'The run ended. Click one to start it.',
            key: const ValueKey('rail-queue-hint'),
            style: HaroText.mono(
              size: 10.5,
              tracking: 0,
              color: HaroTokens.ink42,
            ),
          ),
          const SizedBox(height: 8),
          for (final q in items)
            HaroPressable(
              onTap: () => _send(context, ref, q),
              semanticLabel: running ? 'Steer: ${q.text}' : 'Start: ${q.text}',
              builder: (context, hovered) => Container(
                key: ValueKey('queue-row-${q.id}'),
                padding: const EdgeInsets.symmetric(vertical: 7),
                color: hovered ? HaroTokens.panel : HaroTokens.transparent,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        q.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.ui(
                          size: 13,
                          color: HaroTokens.ink86,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: AnimatedOpacity(
                        opacity: hovered ? 1 : 0,
                        duration: HaroTokens.fadeFast,
                        child: Text(
                          running ? 'STEER' : 'START',
                          key: ValueKey('queue-send-${q.id}'),
                          style: _label().copyWith(color: HaroTokens.ink),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    ShellIconButton(
                      key: ValueKey('queue-remove-${q.id}'),
                      icon: ShellIcon.close,
                      tooltip: 'Remove from the queue',
                      width: 22,
                      height: 22,
                      iconSize: 12,
                      onTap: () => _remove(context, ref, q),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
