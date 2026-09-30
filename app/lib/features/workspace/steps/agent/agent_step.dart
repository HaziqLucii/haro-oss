import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../state/format.dart' show formatDuration;
import '../../../../state/test_first.dart';
import '../../../../state/workspace_flow.dart'
    show AgentPhase, NextAction, NextActionKind, StepKey;
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../workspace_ui.dart';
import 'acceptance_panel.dart';
import 'agent_tokens.dart';
import 'agent_transcript.dart';
import 'composer_state.dart';
import 'stream_rows.dart';

/// Step 1: the transcript as one centred column, or the empty state before any task. The page
/// gives it tight, bounded constraints and no scroll view, so it owns its own scrolling.
class AgentStep extends ConsumerStatefulWidget {
  const AgentStep(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<AgentStep> createState() => _AgentStepState();
}

class _AgentStepState extends ConsumerState<AgentStep> {
  final _scroll = ScrollController();
  bool _following = true;
  bool _snapQueued = false;
  bool _approving = false;
  String? _approveError;
  bool _actionBusy = false;
  String? _actionError;
  bool _leaveArmed = false;
  bool _approvingTest = false;
  String? _approveTestError;

  List<AgentEvent>? _rowsFor;
  bool _rowsRunning = false;
  bool _rowsWaiting = false;
  List<StreamRow> _rows = const [];

  String get _id => widget.workspaceId;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<StreamRow> _deriveRows(
    List<AgentEvent> events, {
    required bool running,
    required bool waiting,
    String? worktreePath,
  }) {
    if (!identical(_rowsFor, events) ||
        _rowsRunning != running ||
        _rowsWaiting != waiting) {
      _rowsFor = events;
      _rowsRunning = running;
      _rowsWaiting = waiting;
      _rows = deriveStreamRows(
        events,
        running: running,
        waiting: waiting,
        worktreePath: worktreePath,
      );
    }
    return _rows;
  }

  Future<void> _runStepAction(NextActionKind kind) async {
    if (_actionBusy) return;
    setState(() {
      _actionBusy = true;
      _actionError = null;
    });
    try {
      final actions = ref.read(workspaceActionsProvider(_id));
      if (kind == NextActionKind.restoreTests) {
        await actions.restoreTests();
      } else {
        await actions.sendFailuresToAgent();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _actionError = e is HaroApiException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Widget? _stepAction(NextAction? next) {
    if (next == null || next.step != StepKey.agent || !next.enabled) {
      return null;
    }
    final hint = switch (next.kind) {
      NextActionKind.sendFailures =>
        'The gate is red. Send the failing tests back to the agent.',
      NextActionKind.restoreTests =>
        'The agent removed or weakened a test. Ask it to restore it.',
      _ => null,
    };
    if (hint == null) return null;
    return StepAction(
      label: next.label,
      hint: hint,
      busy: _actionBusy,
      error: _actionError,
      onPressed: () => _runStepAction(next.kind),
    );
  }

  void _openCode() {
    GoRouter.maybeOf(context)?.go(workspaceStepPath(_id, StepKey.code));
  }

  Future<void> _approve() async {
    if (_approving) return;
    setState(() {
      _approving = true;
      _approveError = null;
    });
    try {
      final args = currentRunArgs(ref, _id);
      await ref
          .read(workspaceActionsProvider(_id))
          .approvePlan(
            model: args.model,
            effort: args.effort,
            adapter: args.adapter,
          );
    } catch (e) {
      if (mounted) {
        setState(
          () => _approveError = e is HaroApiException ? e.message : '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  Future<void> _leave() async {
    if (!_leaveArmed) {
      setState(() => _leaveArmed = true);
      return;
    }
    setState(() {
      _leaveArmed = false;
      _approveTestError = null;
    });
    try {
      await ref.read(workspaceActionsProvider(_id)).leaveTestFirst();
    } catch (e) {
      if (mounted) {
        setState(
          () => _approveTestError = e is HaroApiException ? e.message : '$e',
        );
      }
    }
  }

  Future<void> _approveTest() async {
    if (_approvingTest) return;
    setState(() {
      _approvingTest = true;
      _approveTestError = null;
    });
    try {
      final args = currentRunArgs(ref, _id);
      await ref
          .read(workspaceActionsProvider(_id))
          .approveTestFirst(model: args.model, effort: args.effort);
    } catch (e) {
      if (mounted) {
        setState(
          () => _approveTestError = e is HaroApiException ? e.message : '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _approvingTest = false);
    }
  }

  /// Keeps the newest output in view. jumpTo, not animateTo: nothing slides. A list builder
  /// only knows the extent of what it has laid out, so a jump can leave the true end just
  /// beyond it; a few extra frames close the gap.
  void _snapToEnd([int attempt = 0]) {
    if (_snapQueued || !_following) return;
    _snapQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _snapQueued = false;
      if (!mounted || !_following || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max - _scroll.offset > .5) {
        _scroll.jumpTo(max);
        if (attempt < 4) _snapToEnd(attempt + 1);
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final atEnd = n.metrics.extentAfter < AgentTokens.followSlack;
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      final delta = n is ScrollUpdateNotification ? (n.scrollDelta ?? 0) : 0;
      final following = atEnd ? true : (delta < 0 ? false : _following);
      if (following != _following) setState(() => _following = following);
    }
    return false;
  }

  void _jumpToLatest() {
    setState(() => _following = true);
    _snapToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final d = workspaceDetailProvider(_id);
    final events = ref.watch(d.select((s) => s.events));
    final loaded = ref.watch(d.select((s) => s.loaded));
    final workspace = ref.watch(d.select((s) => s.workspace));
    final signals = ref.watch(d.select((s) => s.signals));
    final phase = ref.watch(d.select((s) => s.agentPhase));
    final elapsed = ref.watch(d.select((s) => s.agentElapsed));
    final running =
        phase == AgentPhase.running ||
        workspace?.status == WorkspaceStatus.agentRunning;
    final rows = _deriveRows(
      events,
      running: running,
      waiting: running && signals.waitingOnInput,
      worktreePath: workspace?.worktreePath,
    );

    final next = ref.watch(workspaceFlowProvider(_id))?.nextAction;
    final tf = workspace?.testFirst;
    final diffText = testFirstNeedsYou(tf)
        ? ref.watch(d.select((s) => s.diff?.diff)) ?? ''
        : '';
    final Widget? action = running
        ? null
        : testFirstNeedsYou(tf)
        ? AcceptancePanel(
            state: tf!,
            diffLines: acceptanceDiffLines(diffText, tf.files),
            busy: _approvingTest,
            primary: next?.kind == NextActionKind.reviewAcceptance,
            error: _approveTestError,
            onApprove: _approveTest,
            onLeave: _leave,
            leaveArmed: _leaveArmed,
            onKeep: () => setState(() => _leaveArmed = false),
            onAskChanges: () =>
                ref.read(workspaceUiProvider.notifier).requestComposerFocus(),
          )
        : _stepAction(next);

    if (rows.isEmpty && !running) {
      if (!loaded) return const SizedBox.shrink();
      return _EmptyState(
        workspaceId: _id,
        projectId: workspace?.projectId,
        action: action,
      );
    }

    final now = ref.watch(agentClockProvider)();
    final lastFooter = rows.lastIndexWhere((r) => r is FooterRow);
    final planPending =
        signals.planReady &&
        !running &&
        lastFooter != -1 &&
        (rows[lastFooter] as FooterRow).planReady;
    final last = rows.isEmpty ? null : rows.last;
    final tail =
        running && !(last is ToolRow && last.running) && last is! QuestionRow;

    final count = rows.length + (tail ? 1 : 0) + (action == null ? 0 : 1);
    _snapToEnd();

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: SelectionArea(
            child: ListView.builder(
              controller: _scroll,
              padding: AgentTokens.padding,
              itemCount: count,
              itemBuilder: (context, i) {
                Widget child;
                double after = AgentTokens.gap;
                if (i >= rows.length + (tail ? 1 : 0)) {
                  child = action!;
                  after = 0;
                } else if (i >= rows.length) {
                  child = WorkingLine(
                    elapsed: elapsed == null ? null : formatDuration(elapsed),
                  );
                  after = 0;
                } else {
                  final row = rows[i];
                  child = StreamRowView(
                    row: row,
                    now: now,
                    onReviewCode: _openCode,
                    plan: planPending && i == lastFooter
                        ? PlanApproval(
                            onApprove: _approve,
                            busy: _approving,
                            primary: next?.kind == NextActionKind.reviewPlan,
                            error: _approveError,
                          )
                        : null,
                  );
                  final nextRow = i + 1 < rows.length ? rows[i + 1] : null;
                  if (row is ToolRow && nextRow is ToolRow) {
                    after = AgentTokens.toolGap;
                  } else if (nextRow == null && !tail && action == null) {
                    after = 0;
                  } else if (nextRow == null && tail && row is ToolRow) {
                    after = AgentTokens.toolGap;
                  }
                }
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AgentTokens.columnMax,
                    ),
                    child: Padding(
                      padding: EdgeInsets.only(bottom: after),
                      child: SizedBox(width: double.infinity, child: child),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (!_following)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: HaroPressable(
                onTap: _jumpToLatest,
                semanticLabel: 'Jump to latest',
                builder: (context, hovered) => DecoratedBox(
                  key: const ValueKey('jump-latest'),
                  decoration: BoxDecoration(
                    color: HaroTokens.panel,
                    border: Border.all(color: HaroTokens.line12),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      '↓ latest',
                      style: HaroText.mono(
                        size: 11.5,
                        color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                        tracking: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({
    required this.workspaceId,
    required this.projectId,
    this.action,
  });

  final String workspaceId;
  final String? projectId;
  final Widget? action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestions = projectId == null
        ? const <TaskSuggestion>[]
        : ref.watch(taskSuggestionsProvider(projectId!)).value ??
              const <TaskSuggestion>[];
    return SingleChildScrollView(
      padding: AgentTokens.padding,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AgentTokens.columnMax),
          child: Padding(
            padding: const EdgeInsets.only(top: 32, bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('STEP 1 · AGENT', style: AgentTokens.label()),
                const SizedBox(height: 12),
                Text(
                  'What should the agent do?',
                  key: const ValueKey('empty-title'),
                  style: HaroText.ui(
                    size: 30,
                    weight: FontWeight.w500,
                    height: 1.2,
                  ).copyWith(letterSpacing: -.6),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 540),
                  child: Text(
                    'Describe the task below. The agent works in its own copy of '
                    'the repo, and the gate runs by itself when it finishes. '
                    'Nothing merges until the tests are green.',
                    style: HaroText.ui(
                      size: 15,
                      color: HaroTokens.ink66,
                      height: 1.55,
                    ),
                  ),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Container(
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: HaroTokens.line12)),
                    ),
                    child: Column(
                      children: [
                        for (final (i, s) in suggestions.indexed)
                          _SuggestionRow(
                            key: ValueKey('suggestion-$i'),
                            suggestion: s,
                            onTap: () {
                              ref
                                  .read(
                                    composerDraftProvider(workspaceId).notifier,
                                  )
                                  .fill(s.text);
                              ref
                                  .read(workspaceUiProvider.notifier)
                                  .requestComposerFocus();
                            },
                          ),
                      ],
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 24), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    super.key,
    required this.suggestion,
    required this.onTap,
  });

  final TaskSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: suggestion.text,
    builder: (context, hovered) => Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              suggestion.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(
                size: 14,
                color: hovered ? HaroTokens.ink : HaroTokens.ink86,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            suggestion.source,
            maxLines: 1,
            style: HaroText.mono(
              size: 11,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        ],
      ),
    ),
  );
}
