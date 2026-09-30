import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_store.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_detail_lazy.dart';
import '../../../../shortcuts/app_commands.dart';
import '../../../../state/display_state.dart';
import '../../../../state/gate_facts.dart';
import '../../../../state/look_at.dart';
import '../../../../state/test_first.dart';
import '../../../../state/workspace_flow.dart';
import '../../step_bar/next_action.dart';
import '../../workspace_ui.dart';
import 'evidence_section.dart';
import 'look_at_section.dart';
import 'tamper_banner.dart';
import 'verdict_block.dart';
import 'verify_model.dart';

/// The verify step (spec 5.6): verdict, then what needs a human, then evidence on demand, in
/// that order. The page gives it tight bounds and no scroll view, so it scrolls itself.
///
/// Spec 5.1 wants one bone-filled button on screen. The step bar carries it unless the next
/// action lands on this step (a gate run), where the bar steps down and the verdict block's
/// copy of the action takes the fill. Every other button here is secondary or tertiary.
class VerifyStep extends ConsumerStatefulWidget {
  const VerifyStep(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<VerifyStep> createState() => _VerifyStepState();
}

class _VerifyStepState extends ConsumerState<VerifyStep> {
  final Set<String> _localReviewed = {};
  bool _busy = false;
  String? _error;
  String? _note;

  String get _id => widget.workspaceId;
  WorkspaceActions get _actions => ref.read(workspaceActionsProvider(_id));

  void _report(Object e) {
    if (!mounted) return;
    setState(() => _error = e is HaroApiException ? e.message : e.toString());
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      await f();
    } catch (e) {
      _report(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goStep(StepKey step) {
    if (mounted) context.go(workspaceStepPath(_id, step));
  }

  Future<void> _next(NextAction action) => _guard(
    () => performNextAction(
      action,
      NextActionEnv(
        actions: _actions,
        goToStep: _goStep,
        focusComposer: () {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref.read(workspaceUiProvider.notifier).requestComposerFocus();
            }
          });
        },
        openGateSettings: () =>
            ref.read(appCommandsProvider).openSettings(SettingsTab.gate),
        rerunSetup: () => ref.read(haroApiProvider).rerunSetup(_id),
        home: homeStep(
          ref.read(workspaceFlowProvider(_id))?.mode ?? WorkspaceMode.agent,
        ),
      ),
    ),
  );

  Future<void> _runGate({bool impacted = false}) =>
      _guard(() => _actions.runGate(impacted: impacted));

  Future<void> _toggle(ReviewRow row) async {
    if (!row.remote) {
      setState(() {
        if (!_localReviewed.remove(row.item.key)) {
          _localReviewed.add(row.item.key);
        }
      });
      return;
    }
    try {
      await _actions.toggleChecked(row.item.key, checked: !row.reviewed);
    } catch (e) {
      _report(e);
    }
  }

  /// A failing test opens where the change that broke it lives when blame knows it, else at
  /// the test file.
  (String?, int?) _target(LookAtItem item) {
    var file = item.file;
    var line = item.line;
    if (item.isFailure) {
      final blame = ref.read(workspaceBlameProvider(_id)).value;
      for (final e in blame?.entries ?? const []) {
        if (e.file == item.file && e.name == item.title && e.hunks.isNotEmpty) {
          file = e.hunks.first.file;
          line = e.hunks.first.line;
          break;
        }
      }
    }
    return (file, line);
  }

  void _open(LookAtItem item) {
    final (file, line) = _target(item);
    context.go(codePath(_id, file: file, line: line));
  }

  (String, int?)? _editorTarget(LookAtItem item) {
    final (file, line) = _target(item);
    return file == null ? null : (file, line);
  }

  Future<void> _ask(List<LookAtItem> items) => _guard(() async {
    await _actions.sendLookAtToAgent(items);
    _goStep(StepKey.agent);
  });

  Future<void> _backlog(List<LookAtItem> items) => _guard(() async {
    final n = await _actions.addToBacklog(items);
    if (mounted) setState(() => _note = 'Added $n to backlog');
  });

  Future<void> _restore() => _guard(() async {
    await _actions.restoreTests();
    _goStep(StepKey.agent);
  });

  @override
  Widget build(BuildContext context) {
    final d = workspaceDetailProvider(_id);
    final flow = ref.watch(workspaceFlowProvider(_id));
    if (flow == null) return const SizedBox.shrink();

    final run = ref.watch(d.select((x) => x.gate.run));
    final cells = ref.watch(d.select((x) => x.gate.cells));
    final summary = ref.watch(d.select((x) => x.workspace?.gate));
    final tfApproved = ref.watch(
      d.select((x) => testFirstApproved(x.workspace?.testFirst)),
    );
    final config = ref.watch(d.select((x) => x.gateConfig));
    final analysis = ref.watch(d.select((x) => x.analysis));

    final state = flow.displayState;
    final settled = state.settled;
    final running = state == DisplayState.gate;
    if (state == DisplayState.red) ref.watch(workspaceBlameProvider(_id));
    final receipt = settled
        ? ref.watch(workspaceReceiptProvider(_id)).value
        : null;

    final expected = run?.total ?? summary?.total ?? 0;
    final progress = gateProgress(
      cells,
      expectedTotal: expected > 0 ? expected : null,
    );
    final facts = running ? GateFacts.none : GateFacts.resolve(run, summary);
    final metrics = deriveMetrics(
      state: state,
      facts: facts,
      run: run,
      progress: progress,
      analysis: analysis,
      mutation: mutationView(analysis.mutation, receipt?.receipt.mutation),
      flakyRerun: config?.flakyRerun ?? false,
    );
    final rows = reviewRows(flow.lookAt, _localReviewed);
    final open = [
      for (final r in rows)
        if (!r.reviewed) r.item,
    ];
    final tamper = flow.tamper;
    final next = flow.nextAction;
    final reruns =
        next.kind == NextActionKind.runGate ||
        next.kind == NextActionKind.rerunGate;

    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth < 700 ? 24.0 : 32.0;
        return SingleChildScrollView(
          key: const ValueKey('verify-scroll'),
          padding: EdgeInsets.fromLTRB(side, 36, side, 72),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  VerdictBlock(
                    state: state,
                    verdict: flow.verdict,
                    meta: verdictMeta(
                      state: state,
                      run: run,
                      summary: summary,
                      config: config,
                      now: DateTime.now(),
                    ),
                    metrics: metrics,
                    progress: running && progress.total > 0
                        ? progress.done / progress.total
                        : running
                        ? 0.0
                        : null,
                    next: next,
                    nextIsPrimary: next.step == StepKey.verify,
                    busy: _busy,
                    onNext: () => _next(next),
                    showRerun: state != DisplayState.merged,
                    hideRerunButton: reruns,
                    rerunEnabled:
                        state != DisplayState.gate &&
                        state != DisplayState.agent,
                    rerunLabel: run == null && summary == null
                        ? 'Run gate'
                        : 'Run again',
                    onRerun: _runGate,
                    onImpacted: () => _runGate(impacted: true),
                    error: _error,
                    acceptanceLine: state == DisplayState.gate
                        ? null
                        : (tfApproved
                              ? acceptanceReceiptLine(run?.acceptance)
                              : null),
                  ),
                  if (tamper != null) ...[
                    const SizedBox(height: 40),
                    TamperBanner(
                      alarm: tamper,
                      busy: _busy,
                      onSee: () {
                        final f =
                            tamper.firstRemoved ??
                            (tamper.findings.isEmpty
                                ? null
                                : tamper.findings.first);
                        context.go(codePath(_id, file: f?.file));
                      },
                      onRestore: state == DisplayState.merged || flow.manual
                          ? null
                          : _restore,
                    ),
                  ],
                  const SizedBox(height: 56),
                  LookAtSection(
                    workspaceId: _id,
                    editorTarget: _editorTarget,
                    state: state,
                    rows: rows,
                    busy: _busy,
                    note: _note,
                    onToggle: _toggle,
                    onOpen: _open,
                    onAsk: flow.manual ? null : (item) => _ask([item]),
                    onBacklog: () => _backlog(open),
                    onSendAll: flow.manual ? null : () => _ask(open),
                  ),
                  const SizedBox(height: 56),
                  EvidenceSection(workspaceId: _id),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
