import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/haro_api.dart';
import '../../../data/sub_agents_provider.dart';
import '../../../data/workspace_store.dart' show haroApiProvider;
import '../../../overlays/overlay.dart';
import '../../../state/format.dart' show formatDuration;
import '../../../state/sub_agents.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/dither_square.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/shell_icons.dart';
import '../../../widgets/status_square.dart';
import '../steps/agent/agent_markdown.dart' show AgentProse;

TextStyle _label() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

/// How long a sub-agent has been going (running: to now, ticking) or took (settled).
String agentElapsed(SubAgent a, DateTime now) {
  final end = a.endedAt != null
      ? DateTime.fromMillisecondsSinceEpoch((a.endedAt! * 1000).round())
      : now;
  final start = DateTime.fromMillisecondsSinceEpoch(
    (a.startedAt * 1000).round(),
  );
  final d = end.difference(start);
  return formatDuration(d.isNegative ? Duration.zero : d);
}

String agentStatusWord(SubAgentStatus s) => switch (s) {
  SubAgentStatus.running => 'running',
  SubAgentStatus.done => 'done',
  SubAgentStatus.error => 'failed',
  SubAgentStatus.stopped => 'stopped',
};

class _Marker extends StatelessWidget {
  const _Marker(this.status);

  final SubAgentStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    SubAgentStatus.running => const DitherSquare(
      size: HaroTokens.markAgentRow,
      layoutSize: HaroTokens.markAgentRow,
    ),
    SubAgentStatus.done => const StatusSquare(
      size: HaroTokens.markAgentRow,
      color: HaroTokens.gate,
      filled: true,
    ),
    SubAgentStatus.error => const StatusSquare(
      size: HaroTokens.markAgentRow,
      color: HaroTokens.fail,
      filled: true,
    ),
    SubAgentStatus.stopped => const StatusSquare(
      size: HaroTokens.markAgentRow,
      color: HaroTokens.ink42,
      filled: false,
    ),
  };
}

/// Re-renders each second while [agent] is running, so its clock moves.
class _Elapsed extends StatefulWidget {
  const _Elapsed(this.agent, {this.style});

  final SubAgent agent;
  final TextStyle? style;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Elapsed old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.agent.running && _timer == null) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    } else if (!widget.agent.running) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(agentElapsed(widget.agent, DateTime.now()), style: widget.style);
}

/// The rail's AGENTS section: one line per delegated sub-agent, newest last. Hidden until the
/// agent has delegated something. Clicking a line opens that sub-agent in full.
class AgentsSection extends ConsumerWidget {
  const AgentsSection({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(visibleSubAgentsProvider(workspaceId));
    if (agents.isEmpty) return const SizedBox.shrink();
    final running = agents.where((a) => a.running).length;
    final canClear = agents.any((a) => !a.running);
    return Container(
      key: const ValueKey('rail-agents'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('AGENTS', style: _label()),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canClear) ...[
                    HaroPressable(
                      onTap: () => ref
                          .read(clearedSubAgentsProvider(workspaceId).notifier)
                          .clearSettled(agents),
                      semanticLabel: 'Clear finished agents',
                      builder: (context, hovered) => Text(
                        'CLEAR',
                        key: const ValueKey('rail-agents-clear'),
                        style: _label().copyWith(
                          color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                          decoration: TextDecoration.underline,
                          decorationColor: HaroTokens.line20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Text(
                    running > 0 ? '$running running' : '${agents.length}',
                    key: const ValueKey('rail-agents-count'),
                    style: _label().copyWith(
                      color: running > 0 ? HaroTokens.ink : HaroTokens.ink42,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final a in agents)
            _AgentRow(
              agent: a,
              onTap: () => ref
                  .read(selectedSubAgentProvider(workspaceId).notifier)
                  .select(a.id),
            ),
        ],
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent, required this.onTap});

  final SubAgent agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = agent.running
        ? (agent.isShell ? agent.description : agent.latestTool ?? 'starting…')
        : (agent.description.isEmpty
              ? agentStatusWord(agent.status)
              : agent.description);
    return HaroPressable(
      onTap: onTap,
      semanticLabel: 'Open ${agent.type}',
      builder: (context, hovered) => Container(
        key: ValueKey('agent-row-${agent.id}'),
        padding: const EdgeInsets.symmetric(vertical: 6),
        color: hovered ? HaroTokens.panel : HaroTokens.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: _Marker(agent.status),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          agent.type,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.mono(
                            size: 11.5,
                            color: HaroTokens.ink,
                            tracking: 0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _Elapsed(
                        agent,
                        style: HaroText.mono(
                          size: 10.5,
                          color: HaroTokens.ink42,
                          tracking: 0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(
                      size: 10.5,
                      color: HaroTokens.ink66,
                      tracking: 0,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One sub-agent in full, filling the rail: what it was asked, then everything it has done,
/// newest at the bottom, following along while it runs.
/// Opens one sub-agent edge to edge over the window, following it live. It closes itself if
/// the agent is cleared.
Future<void> showSubAgentFullscreen(
  BuildContext context,
  String workspaceId,
  String agentId,
) {
  // Every way out (exit row, CLEAR, the agent vanishing from the list) funnels here, and the
  // close must happen once: a second pop would take the page beneath.
  var closing = false;
  void close(BuildContext c) {
    if (closing || !c.mounted) return;
    closing = true;
    closeHaroOverlay(c);
  }

  return showHaroOverlay<void>(
    context,
    width: 0,
    fullscreen: true,
    child: Consumer(
      builder: (context, ref, _) {
        final agent = ref
            .watch(subAgentsProvider(workspaceId))
            .where((a) => a.id == agentId)
            .firstOrNull;
        if (agent == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => close(context));
          return const SizedBox.shrink();
        }
        return SubAgentDetail(
          key: ValueKey('agent-full-$agentId'),
          workspaceId: workspaceId,
          agent: agent,
          expanded: true,
          onClose: () => close(context),
        );
      },
    ),
  );
}

class SubAgentDetail extends ConsumerStatefulWidget {
  const SubAgentDetail({
    super.key,
    required this.workspaceId,
    required this.agent,
    this.expanded = false,
    this.onClose,
  });

  final String workspaceId;
  final SubAgent agent;

  /// Shown fullscreen over the window instead of in the rail: no back row (Esc or the exit
  /// row closes it) and wider margins.
  final bool expanded;

  /// Closes the fullscreen view; set only with [expanded].
  final VoidCallback? onClose;

  @override
  ConsumerState<SubAgentDetail> createState() => _SubAgentDetailState();
}

class _SubAgentDetailState extends ConsumerState<SubAgentDetail> {
  final _scroll = ScrollController();
  int _seen = 0;
  bool _stopping = false;
  String? _stopError;

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() {
      _stopping = true;
      _stopError = null;
    });
    try {
      await ref
          .read(haroApiProvider)
          .stopSubAgent(widget.workspaceId, widget.agent.id);
    } on HaroApiException catch (e) {
      if (mounted) {
        setState(() {
          _stopping = false;
          _stopError = e.message;
        });
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Follows new steps only while the reader is already at the bottom, so scrolling up to
  /// read something is never yanked away.
  void _follow(int count) {
    if (count == _seen) return;
    final wasAtEnd =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 48;
    _seen = count;
    if (!wasAtEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.agent;
    final gutter = widget.expanded ? 40.0 : 20.0;
    _follow(a.steps.length);
    return Column(
      key: const ValueKey('agent-detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HaroPressable(
          onTap: () => widget.expanded
              ? widget.onClose?.call()
              : ref
                    .read(selectedSubAgentProvider(widget.workspaceId).notifier)
                    .select(null),
          semanticLabel: widget.expanded
              ? 'Exit fullscreen'
              : 'Back to the agents list',
          builder: (context, hovered) => Container(
            key: const ValueKey('agent-detail-back'),
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 12),
            color: hovered ? HaroTokens.panel : HaroTokens.transparent,
            child: Text(
              widget.expanded ? '‹  EXIT FULLSCREEN  ESC' : '‹  AGENTS',
              style: _label().copyWith(
                color: hovered ? HaroTokens.ink : HaroTokens.ink42,
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Marker(a.status),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      a.type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.mono(
                        size: 13,
                        weight: FontWeight.w700,
                        color: HaroTokens.ink,
                        tracking: 0,
                      ),
                    ),
                  ),
                  Text(
                    agentStatusWord(a.status),
                    key: const ValueKey('agent-detail-status'),
                    style: _label().copyWith(
                      color: a.status == SubAgentStatus.error
                          ? HaroTokens.fail
                          : HaroTokens.ink66,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Elapsed(
                    a,
                    style: HaroText.mono(
                      size: 10.5,
                      color: HaroTokens.ink42,
                      tracking: 0,
                    ),
                  ),
                  if (a.running) ...[
                    const SizedBox(width: 12),
                    HaroPressable(
                      onTap: _stopping ? () {} : _stop,
                      semanticLabel: 'Stop this agent',
                      builder: (context, hovered) => Text(
                        _stopping ? 'STOPPING…' : 'STOP',
                        key: const ValueKey('agent-detail-stop'),
                        style: _label().copyWith(
                          color: hovered && !_stopping
                              ? HaroTokens.ink
                              : HaroTokens.ink66,
                          decoration: TextDecoration.underline,
                          decorationColor: HaroTokens.line20,
                        ),
                      ),
                    ),
                  ],
                  if (!a.running) ...[
                    const SizedBox(width: 12),
                    HaroPressable(
                      onTap: () {
                        ref
                            .read(
                              clearedSubAgentsProvider(widget.workspaceId)
                                  .notifier,
                            )
                            .clear(a.id);
                        ref
                            .read(
                              selectedSubAgentProvider(widget.workspaceId)
                                  .notifier,
                            )
                            .select(null);
                        if (widget.expanded) widget.onClose?.call();
                      },
                      semanticLabel: 'Clear this agent',
                      builder: (context, hovered) => Text(
                        'CLEAR',
                        key: const ValueKey('agent-detail-clear'),
                        style: _label().copyWith(
                          color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                          decoration: TextDecoration.underline,
                          decorationColor: HaroTokens.line20,
                        ),
                      ),
                    ),
                  ],
                  if (!widget.expanded) ...[
                    const SizedBox(width: 8),
                    ShellIconButton(
                      key: const ValueKey('agent-detail-fullscreen'),
                      icon: ShellIcon.expand,
                      tooltip: 'Fullscreen',
                      width: 24,
                      height: 24,
                      iconSize: 14,
                      onTap: () => showSubAgentFullscreen(
                        context,
                        widget.workspaceId,
                        a.id,
                      ),
                    ),
                  ],
                ],
              ),
              if (_stopError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _stopError!,
                  key: const ValueKey('agent-detail-stop-error'),
                  style: HaroText.mono(
                    size: 11,
                    color: HaroTokens.fail,
                    tracking: 0,
                  ),
                ),
              ],
              if (a.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  a.description,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(size: 13, color: HaroTokens.ink86),
                ),
              ],
            ],
          ),
        ),
        Container(height: 1, color: HaroTokens.line12),
        Expanded(
          child: a.steps.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    a.isShell
                        ? 'Output is not shown here.'
                        : a.running
                        ? 'Starting…'
                        : 'Nothing was recorded for this agent.',
                    style: HaroText.ui(size: 13, color: HaroTokens.ink42),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 16),
                  itemCount: a.steps.length,
                  itemBuilder: (context, i) => _Step(a.steps[i]),
                ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.step);

  final SubAgentStep step;

  @override
  Widget build(BuildContext context) {
    if (step.prose) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AgentProse(step.text.trim(), compact: true),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              step.tool,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.ink,
                tracking: 0,
              ),
            ),
          ),
          Expanded(
            child: Text(
              step.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.ink66,
                tracking: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
