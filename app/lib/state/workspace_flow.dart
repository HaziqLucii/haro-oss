import '../api/models/models.dart';
import 'agent_signals.dart';
import 'diff_stats.dart';
import 'display_state.dart';
import 'format.dart';
import 'gate_facts.dart';
import 'live_gate.dart';
import 'look_at.dart';
import 'review_items.dart';
import 'test_first.dart';
import 'verdict.dart';

// The workspace state machine (spec 9.3), derived client-side as pure functions from the
// facts the backend actually emits: workspace status, the agent transcript and the gate
// (`test` channel snapshot/cells or a `GateSummary`). The backend sends no `workspace_state`
// events. Ported from the React client's `flow.ts` / `verdict.ts`, mapped onto the redesign's
// four steps and seven display states.

enum StepKey { agent, code, verify, ship }

/// The steps a workspace shows, in order: manual has no agent step (plan section 4).
List<StepKey> visibleSteps(WorkspaceMode mode) => mode == WorkspaceMode.manual
    ? const [StepKey.code, StepKey.verify, StepKey.ship]
    : StepKey.values;

/// Where "start over" lands: the agent step, or the code step when no agent runs here.
StepKey homeStep(WorkspaceMode mode) =>
    mode == WorkspaceMode.manual ? StepKey.code : StepKey.agent;

/// The step ⌘1..⌘4 open. Numbers count the visible steps, so manual has only 1 to 3.
StepKey? stepForNumber(int n, WorkspaceMode mode) {
  final steps = visibleSteps(mode);
  return n >= 1 && n <= steps.length ? steps[n - 1] : null;
}

/// A step the workspace does not show falls back to [homeStep].
StepKey clampStep(StepKey step, WorkspaceMode mode) =>
    visibleSteps(mode).contains(step) ? step : homeStep(mode);

/// Drives both the step's square and its status-line colour, and the triage row's progress
/// tick: pending = hairline, current = ink, done = ink at .42, red/green/merged = outcome.
enum StepStatus { pending, current, done, red, green, merged }

class FlowStep {
  const FlowStep({
    required this.key,
    required this.status,
    required this.line,
    required this.tick,
  });

  final StepKey key;
  final StepStatus status;

  /// Status line under the step name (spec 5.1), e.g. `done · 14m`, `red · 3 failing`.
  final String line;

  /// The triage row's progress tick. Differs from [status] in two places (prototype ticks):
  /// while green, ship is the current step in the bar but its tick is still pending; once
  /// merged, verify's tick settles to done and only ship carries the outcome colour.
  final StepStatus tick;

  String get label => key.name;
}

enum NextActionKind {
  runAgent,
  agentRunning,
  answerAgent,
  reviewPlan,
  reviewAcceptance,
  gateRunning,
  runGate,
  sendFailures,
  restoreTests,
  rerunGate,
  rerunSetup,
  openGateSettings,
  reviewAndShip,
  continueOnNewBranch,

  /// Manual only: nothing written yet, or a red gate to fix by hand.
  startCoding,
  backToCode,

  /// Code step only, while an open file has unsaved edits: write them, then run the gate.
  saveAndRunGate,
}

/// The one primary action on screen for a workspace.
class NextAction {
  const NextAction(
    this.kind,
    this.label, {
    this.enabled = true,
    this.step,
    this.saveShortcut = false,
  });

  final NextActionKind kind;
  final String label;
  final bool enabled;

  /// The step to open when the action is taken (the prototype's `next()` handler).
  final StepKey? step;

  /// Show the save shortcut on the button: only true when ⌘S does what the button does
  /// (Run on save is on), so the hint never promises a gate run the shortcut will not start.
  final bool saveShortcut;
}

/// What the code step's primary action becomes while an open file has unsaved edits. The flow
/// itself stays server-derived; unsaved buffers are client state, so the page applies this on
/// top. Only actions that leave for the gate, the ship page or the agent's fix-up are replaced:
/// answering an agent or a plan review is never overridden by an edit.
const _replacedByUnsavedEdits = {
  NextActionKind.runGate,
  NextActionKind.rerunGate,
  NextActionKind.startCoding,
  NextActionKind.backToCode,
  NextActionKind.reviewAndShip,
  NextActionKind.sendFailures,
};

NextAction withUnsavedEdits(
  NextAction base, {
  required StepKey active,
  required bool dirty,
  bool runOnSave = false,
}) {
  if (!dirty || active != StepKey.code || !base.enabled) return base;
  if (!_replacedByUnsavedEdits.contains(base.kind)) return base;
  return NextAction(
    NextActionKind.saveAndRunGate,
    'Save & run gate',
    saveShortcut: runOnSave,
  );
}

/// Where the agent stands, from the newest run or from status alone.
enum AgentPhase { none, queued, running, done, error, stopped }

AgentPhase agentPhaseOf(AgentRunStatus? s) => switch (s) {
  null => AgentPhase.none,
  AgentRunStatus.queued => AgentPhase.queued,
  AgentRunStatus.running => AgentPhase.running,
  AgentRunStatus.done => AgentPhase.done,
  AgentRunStatus.error => AgentPhase.error,
  AgentRunStatus.stopped => AgentPhase.stopped,
  AgentRunStatus.unknown => AgentPhase.none,
};

class FlowInput {
  const FlowInput({
    required this.status,
    this.kind = WorkspaceKind.managed,
    this.agent = AgentPhase.none,
    this.hasAgentActivity = false,
    this.planReady = false,
    this.waitingOnInput = false,
    this.agentElapsed,
    this.agentActivity,
    this.planText,
    this.testFirst,
    this.diff = DiffStats.empty,
    this.run,
    this.cells = const [],
    this.summary,
    this.expectedTotal,
    this.checkedKeys = const [],
    this.survivors,
    this.codeToCheckEnabled = true,
    this.prNumber,
    this.baseRef = 'origin/main',
    this.coverageHasDelta = true,
    this.mode = WorkspaceMode.agent,
  });

  /// Build from the model and the loaded/streamed pieces. Anything not loaded yet can be
  /// omitted: the derivation degrades to what it has (a dashboard card has only [summary]).
  factory FlowInput.fromWorkspace(
    Workspace ws, {
    AgentSignals? signals,
    AgentPhase? agent,
    Duration? agentElapsed,
    DiffStats diff = DiffStats.empty,
    TestRun? run,
    List<Cell> cells = const [],
    int? expectedTotal,
    List<MutationSurvivor>? survivors,
    bool codeToCheckEnabled = true,
  }) => FlowInput(
    status: ws.status,
    kind: ws.kind,
    agent: agent ?? AgentPhase.none,
    hasAgentActivity: signals?.hasActivity ?? false,
    planReady: signals?.planReady ?? false,
    waitingOnInput: signals?.waitingOnInput ?? false,
    agentElapsed: agentElapsed ?? signals?.lastRunDuration,
    agentActivity: signals?.lastEditedFile,
    planText: ws.planText,
    testFirst: ws.testFirst,
    diff: diff,
    run: run,
    cells: cells,
    summary: ws.gate,
    expectedTotal: expectedTotal,
    checkedKeys: ws.checkedRows,
    survivors: survivors,
    codeToCheckEnabled: codeToCheckEnabled,
    prNumber: ws.lastPrNumber,
    baseRef: ws.baseRef.isEmpty ? 'origin/main' : ws.baseRef,
    mode: ws.mode,
  );

  final WorkspaceStatus status;
  final WorkspaceKind kind;
  final AgentPhase agent;

  /// Any agent transcript exists.
  final bool hasAgentActivity;

  /// A Plan-Mode run finished and nothing has superseded it.
  final bool planReady;
  final bool waitingOnInput;

  /// Elapsed time of a live run, or duration of the last finished one.
  final Duration? agentElapsed;

  /// Last file the agent edited, for the triage detail line.
  final String? agentActivity;
  final String? planText;

  /// The test-first task's state; null for an ordinary workspace.
  final TestFirstState? testFirst;
  final DiffStats diff;

  /// The authoritative gate run (never a `watch` run) and the live grid cells.
  final TestRun? run;
  final List<Cell> cells;

  /// Denormalized gate result off the workspace, used when no [run] is loaded.
  final GateSummary? summary;

  /// Last known total, so a running gate can show `412 / 594` before every cell has appeared.
  final int? expectedTotal;
  final List<String> checkedKeys;
  final List<MutationSurvivor>? survivors;
  final bool codeToCheckEnabled;
  final int? prNumber;
  final String baseRef;

  /// Whether a coverage delta exists (picks the coverage-guard fix wording).
  final bool coverageHasDelta;

  /// Manual switches the agent off: no agent step, no action that runs an agent.
  final WorkspaceMode mode;

  bool get manual => mode == WorkspaceMode.manual;
}

class WorkspaceFlow {
  const WorkspaceFlow({
    required this.displayState,
    required this.triageGroup,
    required this.steps,
    required this.nextAction,
    required this.defaultStep,
    required this.lookAt,
    required this.openLookCount,
    required this.blockers,
    required this.verdict,
    required this.tamper,
    required this.rowDetail,
    required this.rowAction,
    required this.waitingOnInput,
    this.acceptanceReview = false,
    this.mode = WorkspaceMode.agent,
  });

  final DisplayState displayState;
  final TriageGroup triageGroup;

  /// In order: agent, code, verify, ship; manual drops the agent step.
  final List<FlowStep> steps;
  final NextAction nextAction;

  /// The step opened when the workspace is entered.
  final StepKey defaultStep;
  final LookAt lookAt;

  /// Open look-at items. From [lookAt] when a run is loaded, else estimated from the summary.
  final int openLookCount;
  final List<Blocker> blockers;
  final VerdictCopy verdict;
  final TamperAlarm? tamper;

  /// One-line detail for a triage row.
  final String rowDetail;

  /// Label of a triage row's action button. Primary (bone) when [triageGroup] is needsYou.
  final String rowAction;
  final bool waitingOnInput;

  /// Test-first: the proven-red acceptance test (or a rejected draft) waits for the dev.
  /// The display state is [DisplayState.plan] then, the same "approve before the build" slot.
  final bool acceptanceReview;

  /// The state word for sidebar and triage: `test` while an acceptance test awaits the dev,
  /// otherwise the display state's own word.
  String get stateWord => acceptanceReview ? 'test' : displayState.word;

  final WorkspaceMode mode;

  bool get manual => mode == WorkspaceMode.manual;

  FlowStep step(StepKey k) => steps.firstWhere(
    (s) => s.key == k,
    orElse: () => throw StateError('no ${k.name} step in $mode mode'),
  );
  bool get needsYou => triageGroup == TriageGroup.needsYou;
}

WorkspaceFlow deriveWorkspaceFlow(FlowInput i) {
  final gateRunning = i.status == WorkspaceStatus.testsRunning;
  final gateRun = (i.run != null && i.run!.trigger != 'watch') ? i.run : null;
  final settledRun = gateRunning ? null : gateRun;

  final facts = gateRunning
      ? GateFacts.none
      : GateFacts.resolve(gateRun, i.summary, status: i.status);
  final adopted = i.kind == WorkspaceKind.adopted;

  final state = _displayState(i, facts);
  final agentLive = state == DisplayState.agent;
  final waiting = agentLive && i.waitingOnInput;

  final lookAt = deriveLookAt(
    run: settledRun,
    cells: gateRunning ? const [] : i.cells,
    checkedKeys: i.checkedKeys,
    survivors: settledRun == null ? null : i.survivors,
    codeToCheckEnabled: i.codeToCheckEnabled,
  );
  final openLook = settledRun != null
      ? lookAt.openCount
      : (facts.uncheckedCount ?? 0) + facts.tamperCount;

  final blockers = state == DisplayState.red
      ? deriveBlockers(
          facts,
          adopted: adopted,
          coverageHasDelta: i.coverageHasDelta,
        )
      : const <Blocker>[];

  final progress = gateProgress(i.cells, expectedTotal: i.expectedTotal);
  final liveFailed = tally(i.cells).failed;
  final starred = facts.tamperCount > 0;

  final verdict = deriveVerdictCopy(
    state: state,
    facts: facts,
    blockers: blockers,
    progress: progress,
    liveFailed: liveFailed,
    lookAt: lookAt,
    openLookCount: openLook,
    starred: starred,
    baseRef: i.baseRef,
    prNumber: i.prNumber,
    adopted: adopted,
    manual: i.manual,
  );

  final group = _triageGroup(state, waiting, openLook);
  final steps = _steps(
    i,
    state,
    facts,
    blockers,
    progress,
    liveFailed,
    starred,
    waiting,
  );
  final next = _nextAction(i, state, blockers, waiting);

  return WorkspaceFlow(
    displayState: state,
    triageGroup: group,
    steps: steps,
    nextAction: next,
    defaultStep: _defaultStep(i, state),
    lookAt: lookAt,
    openLookCount: openLook,
    blockers: blockers,
    verdict: verdict,
    tamper:
        (state == DisplayState.green ||
            state == DisplayState.red ||
            state == DisplayState.merged)
        ? deriveTamperAlarm(facts, settledRun, manual: i.manual)
        : null,
    rowDetail: _rowDetail(
      i,
      state,
      facts,
      lookAt,
      openLook,
      progress,
      liveFailed,
      waiting,
      settledRun,
    ),
    rowAction: _rowAction(state, group, next, waiting, i.manual),
    waitingOnInput: waiting,
    acceptanceReview:
        state == DisplayState.plan && testFirstNeedsYou(i.testFirst),
    mode: i.mode,
  );
}

DisplayState _displayState(FlowInput i, GateFacts facts) {
  switch (i.status) {
    case WorkspaceStatus.merged:
      return DisplayState.merged;
    case WorkspaceStatus.testsRunning:
      return DisplayState.gate;
    case WorkspaceStatus.gateRed:
      return DisplayState.red;
    case WorkspaceStatus.gateGreen:
      // A green that could not run every check it was asked to is not shippable, so it
      // reads red rather than promising a merge the backend's ship preflight will refuse.
      return isCantShip(i.status, facts)
          ? DisplayState.red
          : DisplayState.green;
    case WorkspaceStatus.agentRunning:
      // A manual workspace cannot have a running agent; a stale status must not bring the
      // agent step back.
      return i.manual ? DisplayState.idle : DisplayState.agent;
    case WorkspaceStatus.broken:
      return DisplayState.red;
    case WorkspaceStatus.settingUp:
    case WorkspaceStatus.idle:
    case WorkspaceStatus.archived:
    case WorkspaceStatus.unknown:
      if (i.manual) return DisplayState.idle;
      if (i.agent == AgentPhase.running || i.agent == AgentPhase.queued) {
        return DisplayState.agent;
      }
      if (i.planReady || testFirstNeedsYou(i.testFirst)) {
        return DisplayState.plan;
      }
      return DisplayState.idle;
  }
}

TriageGroup _triageGroup(DisplayState s, bool waiting, int openLook) =>
    switch (s) {
      DisplayState.red || DisplayState.plan => TriageGroup.needsYou,
      DisplayState.gate => TriageGroup.running,
      DisplayState.agent =>
        waiting ? TriageGroup.needsYou : TriageGroup.running,
      DisplayState.green =>
        openLook > 0 ? TriageGroup.needsYou : TriageGroup.readyToShip,
      DisplayState.idle => TriageGroup.idle,
      DisplayState.merged => TriageGroup.merged,
    };

StepKey _defaultStep(FlowInput i, DisplayState s) => switch (s) {
  DisplayState.idle =>
    i.kind == WorkspaceKind.adopted || i.manual ? StepKey.code : StepKey.agent,
  DisplayState.plan || DisplayState.agent => StepKey.agent,
  DisplayState.gate || DisplayState.red || DisplayState.green => StepKey.verify,
  DisplayState.merged => StepKey.ship,
};

String _codeLine(DiffStats d) {
  if (d.files == 0) return 'no changes yet';
  return '${d.files} ${plural(d.files, 'file')} · +${d.added} −${d.removed}';
}

String _blockerShort(List<Blocker> blockers, GateFacts f) {
  if (f.errored) return 'didn’t run';
  if (f.failed > 0) return '${f.failed} failing';
  switch (blockers.isEmpty ? null : blockers.first.kind) {
    case BlockerKind.mergeConflict:
      return 'merge conflict';
    case BlockerKind.tamperBlocked:
      return 'tamper alarm';
    case BlockerKind.coverageBlocked:
      return 'coverage dropped';
    case BlockerKind.degraded:
      return 'a check didn’t run';
    default:
      return 'blocked';
  }
}

List<FlowStep> _steps(
  FlowInput i,
  DisplayState s,
  GateFacts f,
  List<Blocker> blockers,
  ({int done, int total}) progress,
  int liveFailed,
  bool starred,
  bool waiting,
) {
  final adopted = i.kind == WorkspaceKind.adopted;
  final elapsed = i.agentElapsed;
  final agentDone = elapsed == null
      ? 'done'
      : 'done · ${formatDuration(elapsed)}';
  final agentInProgress = s == DisplayState.agent || s == DisplayState.plan;

  // agent
  final FlowStep agent;
  if (i.manual) {
    agent = const FlowStep(
      key: StepKey.agent,
      status: StepStatus.pending,
      line: 'off',
      tick: StepStatus.pending,
    );
  } else if (adopted) {
    agent = const FlowStep(
      key: StepKey.agent,
      status: StepStatus.pending,
      line: 'adopted, no agent',
      tick: StepStatus.pending,
    );
  } else if (s == DisplayState.agent) {
    final line = waiting
        ? 'waiting for you'
        : (testFirstRunning(i.testFirst)
              ? acceptanceStepLine(i.testFirst, elapsed: elapsed)!
              : (elapsed == null
                    ? 'working'
                    : 'working · ${formatDuration(elapsed)}'));
    agent = FlowStep(
      key: StepKey.agent,
      status: StepStatus.current,
      line: line,
      tick: StepStatus.current,
    );
  } else if (s == DisplayState.plan) {
    agent = FlowStep(
      key: StepKey.agent,
      status: StepStatus.current,
      line: acceptanceStepLine(i.testFirst) ?? 'plan ready',
      tick: StepStatus.current,
    );
  } else if (!i.hasAgentActivity && i.agent == AgentPhase.none) {
    agent = const FlowStep(
      key: StepKey.agent,
      status: StepStatus.current,
      line: 'ready for a task',
      tick: StepStatus.pending,
    );
  } else {
    final line = switch (i.agent) {
      AgentPhase.error => 'errored',
      AgentPhase.stopped => 'stopped',
      _ => agentDone,
    };
    agent = FlowStep(
      key: StepKey.agent,
      status: StepStatus.done,
      line: line,
      tick: StepStatus.done,
    );
  }

  // code
  final hasChanges = i.diff.files > 0;
  final codeSettled = hasChanges && !agentInProgress;
  final code = FlowStep(
    key: StepKey.code,
    status: codeSettled
        ? StepStatus.done
        : (i.manual ? StepStatus.current : StepStatus.pending),
    line: _codeLine(i.diff),
    tick: codeSettled ? StepStatus.done : StepStatus.pending,
  );

  // verify
  final FlowStep verify;
  switch (s) {
    case DisplayState.gate:
      verify = FlowStep(
        key: StepKey.verify,
        status: StepStatus.current,
        line: progress.total > 0
            ? 'running · ${progress.done} / ${progress.total}'
            : 'running',
        tick: StepStatus.current,
      );
    case DisplayState.red:
      verify = FlowStep(
        key: StepKey.verify,
        status: StepStatus.red,
        line: 'red · ${_blockerShort(blockers, f)}',
        tick: StepStatus.red,
      );
    case DisplayState.green:
    case DisplayState.merged:
      final n = f.passed > 0 ? f.passed : f.total;
      final word = starred ? 'green*' : 'green';
      verify = FlowStep(
        key: StepKey.verify,
        status: StepStatus.green,
        line: n > 0 ? '$word · $n passed' : word,
        tick: s == DisplayState.merged ? StepStatus.done : StepStatus.green,
      );
    case DisplayState.idle:
    case DisplayState.plan:
    case DisplayState.agent:
      final ungated = s == DisplayState.idle && (hasChanges || i.manual);
      verify = FlowStep(
        key: StepKey.verify,
        status: StepStatus.pending,
        line: ungated ? 'not run' : 'runs when agent finishes',
        tick: StepStatus.pending,
      );
  }

  // ship
  final FlowStep ship;
  switch (s) {
    case DisplayState.merged:
      ship = FlowStep(
        key: StepKey.ship,
        status: StepStatus.merged,
        line: i.prNumber == null ? 'merged' : 'merged · #${i.prNumber}',
        tick: StepStatus.merged,
      );
    case DisplayState.green:
      ship = const FlowStep(
        key: StepKey.ship,
        status: StepStatus.current,
        line: 'ready to merge',
        tick: StepStatus.pending,
      );
    case DisplayState.gate:
      ship = const FlowStep(
        key: StepKey.ship,
        status: StepStatus.pending,
        line: 'waits for green',
        tick: StepStatus.pending,
      );
    case DisplayState.red:
    case DisplayState.idle:
    case DisplayState.plan:
    case DisplayState.agent:
      ship = const FlowStep(
        key: StepKey.ship,
        status: StepStatus.pending,
        line: 'blocked',
        tick: StepStatus.pending,
      );
  }

  return i.manual ? [code, verify, ship] : [agent, code, verify, ship];
}

NextAction _nextAction(
  FlowInput i,
  DisplayState s,
  List<Blocker> blockers,
  bool waiting,
) {
  switch (s) {
    case DisplayState.idle:
      if (i.diff.files > 0) {
        return const NextAction(
          NextActionKind.runGate,
          'Run gate',
          step: StepKey.verify,
        );
      }
      if (i.manual) {
        return const NextAction(
          NextActionKind.startCoding,
          'Start coding',
          step: StepKey.code,
        );
      }
      return const NextAction(
        NextActionKind.runAgent,
        'Run agent',
        step: StepKey.agent,
      );
    case DisplayState.plan:
      if (testFirstNeedsYou(i.testFirst)) {
        return NextAction(
          NextActionKind.reviewAcceptance,
          i.testFirst!.phase == TestFirstPhase.review
              ? 'Review acceptance test'
              : 'Redraft acceptance test',
          step: StepKey.agent,
        );
      }
      return const NextAction(
        NextActionKind.reviewPlan,
        'Review plan',
        step: StepKey.agent,
      );
    case DisplayState.agent:
      if (i.testFirst?.phase == TestFirstPhase.proving) {
        return const NextAction(
          NextActionKind.agentRunning,
          'Proving test',
          enabled: false,
        );
      }
      return waiting
          ? const NextAction(
              NextActionKind.answerAgent,
              'Answer agent',
              step: StepKey.agent,
            )
          : const NextAction(
              NextActionKind.agentRunning,
              'Agent running',
              enabled: false,
            );
    case DisplayState.gate:
      return const NextAction(
        NextActionKind.gateRunning,
        'Gate running',
        enabled: false,
      );
    case DisplayState.red:
      if (blockers.isEmpty) {
        return const NextAction(
          NextActionKind.rerunGate,
          'Re-run gate',
          step: StepKey.verify,
        );
      }
      final b = blockers.first;
      if (i.manual &&
          (b.fix == FixAction.sendFailures ||
              b.fix == FixAction.restoreTests)) {
        return const NextAction(
          NextActionKind.backToCode,
          'Back to code',
          step: StepKey.code,
        );
      }
      return switch (b.fix) {
        FixAction.sendFailures => NextAction(
          NextActionKind.sendFailures,
          b.fixLabel,
          step: StepKey.agent,
        ),
        FixAction.restoreTests => NextAction(
          NextActionKind.restoreTests,
          b.fixLabel,
          step: StepKey.agent,
        ),
        FixAction.rerunGate => NextAction(
          NextActionKind.rerunGate,
          b.fixLabel,
          step: StepKey.verify,
        ),
        FixAction.rerunSetup => NextAction(
          NextActionKind.rerunSetup,
          b.fixLabel,
          step: StepKey.verify,
        ),
        FixAction.openGateSettings => NextAction(
          NextActionKind.openGateSettings,
          b.fixLabel,
        ),
      };
    case DisplayState.green:
      return const NextAction(
        NextActionKind.reviewAndShip,
        'Review & ship',
        step: StepKey.ship,
      );
    case DisplayState.merged:
      return const NextAction(
        NextActionKind.continueOnNewBranch,
        'Continue on a new branch',
      );
  }
}

String _rowAction(
  DisplayState s,
  TriageGroup group,
  NextAction next,
  bool waiting,
  bool manual,
) => switch (s) {
  DisplayState.red || DisplayState.plan => next.label,
  DisplayState.agent => waiting ? 'Answer agent' : 'Open',
  DisplayState.gate => 'Watch',
  DisplayState.green =>
    group == TriageGroup.needsYou ? 'Review & ship' : 'Merge',
  DisplayState.idle => manual ? 'Start coding' : 'Write a task',
  DisplayState.merged => 'Archive',
};

String _shortBase(String baseRef) =>
    baseRef.startsWith('origin/') ? baseRef.substring(7) : baseRef;

/// Numbered plan items (`1. ...`), the only list shape reliable enough to count as steps.
int _planSteps(String? text) {
  if (text == null) return 0;
  final re = RegExp(r'^\s*\d+[.)]\s+\S', multiLine: true);
  return re.allMatches(text).length;
}

String _rowDetail(
  FlowInput i,
  DisplayState s,
  GateFacts f,
  LookAt lookAt,
  int openLook,
  ({int done, int total}) progress,
  int liveFailed,
  bool waiting,
  TestRun? settledRun,
) {
  switch (s) {
    case DisplayState.red:
      if (f.errored) {
        return gateErrorFraming(
          f.errorKind,
          adopted: i.kind == WorkspaceKind.adopted,
        ).title;
      }
      if (f.failed > 0) {
        final failedFiles = failedCells(
          i.cells,
          settledRun,
        ).map((c) => c.file).where((p) => p.isNotEmpty).toSet();
        final head = f.total > 0
            ? '${f.failed} of ${f.total} tests failing'
            : '${f.failed} ${plural(f.failed, 'test')} failing';
        if (failedFiles.length == 1) return '$head in ${failedFiles.single}';
        if (failedFiles.length > 1) {
          return '$head across ${failedFiles.length} files';
        }
        return head;
      }
      final blockers = deriveBlockers(f);
      return blockers.isEmpty ? 'Gate is red' : blockers.first.text;

    case DisplayState.plan:
      final acceptance = acceptanceRowDetail(i.testFirst);
      if (acceptance != null) return acceptance;
      final steps = _planSteps(i.planText);
      return steps > 0
          ? 'Plan ready to approve · $steps steps'
          : 'Plan ready to approve';

    case DisplayState.green:
      final parts = <String>[
        if (f.passed > 0)
          '${f.passed} passed'
        else if (f.total > 0)
          '${f.total} passed',
      ];
      if (f.tamperCount > 0) {
        parts.add(f.tamperNote ?? 'test suite changed');
      }
      final tamperItems = lookAt.pending
          .where((p) => p.kind == LookAtKind.tamper)
          .length;
      final other =
          openLook - (settledRun != null ? tamperItems : f.tamperCount);
      if (other > 0) {
        final untested = lookAt.pending
            .where((p) => p.rawKind == 'untested_lines')
            .fold<int>(0, (a, p) => a + p.count);
        final onlyUntested =
            settledRun != null &&
            lookAt.pending
                .where((p) => p.kind != LookAtKind.tamper)
                .every((p) => p.rawKind == 'untested_lines');
        parts.add(
          onlyUntested && untested > 0
              ? '$untested ${plural(untested, 'line')} no test ran'
              : '$other to look at',
        );
      } else if (f.tamperCount == 0) {
        parts.add('nothing to look at');
      }
      return parts.isEmpty ? 'Gate is green' : parts.join(' · ');

    case DisplayState.agent:
      if (waiting) return 'Agent waiting for your answer';
      if (i.testFirst?.phase == TestFirstPhase.proving) {
        return 'Proving the acceptance test fails on base';
      }
      if (i.testFirst?.phase == TestFirstPhase.drafting) {
        return 'Agent drafting the acceptance test';
      }
      final since = i.agentElapsed == null
          ? ''
          : ' · ${formatDuration(i.agentElapsed!)} in';
      final what = i.agentActivity == null
          ? 'Agent working'
          : 'Agent editing ${i.agentActivity}';
      return '$what$since';

    case DisplayState.gate:
      final p = progress;
      final counts = p.total > 0 ? ' ${p.done} / ${p.total}' : '';
      return 'Gate$counts · ${liveFailed == 0 ? 'no failures yet' : '$liveFailed failing so far'}';

    case DisplayState.idle:
      if (i.diff.files > 0) return 'Changes not gated yet';
      return i.manual ? 'No changes yet' : 'No task yet';

    case DisplayState.merged:
      final pr = i.prNumber == null ? '' : ' #${i.prNumber}';
      return 'Merged$pr into ${_shortBase(i.baseRef)} on green';
  }
}
