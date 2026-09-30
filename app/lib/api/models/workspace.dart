import 'assist.dart';
import 'json_util.dart';
import 'test_first.dart';

/// Backend `WorkspaceStatus`. `unknown` keeps a future status from crashing the client.
enum WorkspaceStatus {
  settingUp('setting_up'),
  idle('idle'),
  agentRunning('agent_running'),
  testsRunning('tests_running'),
  gateGreen('gate_green'),
  gateRed('gate_red'),
  merged('merged'),
  archived('archived'),
  broken('broken'),
  unknown('');

  const WorkspaceStatus(this.wire);
  final String wire;

  static WorkspaceStatus parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

enum WorkspaceKind {
  managed('managed'),
  adopted('adopted');

  const WorkspaceKind(this.wire);
  final String wire;

  static WorkspaceKind parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, managed);
}

/// Who writes the code. Missing or unknown on the wire reads as `agent`, which is what every
/// snapshot written before the field existed means.
enum WorkspaceMode {
  agent('agent'),
  manual('manual');

  const WorkspaceMode(this.wire);
  final String wire;

  static WorkspaceMode parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, agent);
}

/// One agent/manual flip, oldest first on [Workspace.modeSwitches].
class ModeSwitch {
  const ModeSwitch({required this.to, this.at, this.sha = ''});

  final WorkspaceMode to;
  final DateTime? at;

  /// HEAD after the checkpoint commit that separates the before and after segments.
  final String sha;

  factory ModeSwitch.fromJson(Json j) => ModeSwitch(
    to: WorkspaceMode.parse(j['to']),
    at: DateTime.tryParse(jStr(j, 'at'))?.toLocal(),
    sha: jStr(j, 'sha'),
  );
}

enum AgentRunStatus {
  queued('queued'),
  running('running'),
  done('done'),
  error('error'),
  stopped('stopped'),
  unknown('');

  const AgentRunStatus(this.wire);
  final String wire;

  static AgentRunStatus parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

enum TestRunStatus {
  running('running'),
  passed('passed'),
  failed('failed'),
  error('error'),
  unknown('');

  const TestRunStatus(this.wire);
  final String wire;

  static TestRunStatus parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

enum TestScope {
  all('all'),
  impacted('impacted'),
  failed('failed');

  const TestScope(this.wire);
  final String wire;

  static TestScope parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, all);
}

/// Why a gate could not run at all (`status == error`), as opposed to tests failing.
enum GateErrorKind {
  setup('setup'),
  noTests('no_tests'),
  runner('runner');

  const GateErrorKind(this.wire);
  final String wire;

  static GateErrorKind? parse(Object? raw) {
    if (raw is! String) return null;
    for (final v in values) {
      if (v.wire == raw) return v;
    }
    return GateErrorKind.runner;
  }
}

/// Denormalized latest-gate result carried on the workspace, so a dashboard card renders
/// off the coarse status feed with no fetch per card. Double Gate `quality_*` and refuter
/// `review_*` glance fields are intentionally not parsed (the redesign drops them).
class GateSummary {
  const GateSummary({
    required this.status,
    this.total = 0,
    this.passed = 0,
    this.failed = 0,
    this.scope = TestScope.all,
    this.errorKind,
    this.endedAt,
    this.tamperCount = 0,
    this.tamperNote,
    this.uncheckedCount,
    this.degraded = false,
  });

  final TestRunStatus status;
  final int total;
  final int passed;
  final int failed;
  final TestScope scope;
  final GateErrorKind? errorKind;
  final double? endedAt;

  /// A green with `tamperCount > 0` is the `green*` verdict.
  final int tamperCount;
  final String? tamperNote;

  /// Rows still awaiting a look. `null` means the pass never ran, which is not zero.
  final int? uncheckedCount;

  /// A check the project asked for could not run, so this green covers less than it reads.
  final bool degraded;

  factory GateSummary.fromJson(Json j) => GateSummary(
    status: TestRunStatus.parse(j['status']),
    total: jInt(j, 'total'),
    passed: jInt(j, 'passed'),
    failed: jInt(j, 'failed'),
    scope: TestScope.parse(j['scope']),
    errorKind: GateErrorKind.parse(j['error_kind']),
    endedAt: jDoubleN(j, 'ended_at'),
    tamperCount: jInt(j, 'tamper_count'),
    tamperNote: jStrN(j, 'tamper_note'),
    uncheckedCount: jIntN(j, 'unchecked_count'),
    degraded: jBool(j, 'degraded'),
  );
}

/// Compact autonomy-ladder summary. The full `TrustReport` (a superset) can arrive in its
/// place on the status feed and parses into this too.
class TrustSummary {
  const TrustSummary({
    this.enabled = false,
    this.streak = 0,
    this.streakRequired = 3,
    this.autoAction = 'off',
    this.met = false,
    this.armed = false,
  });

  final bool enabled;
  final int streak;
  final int streakRequired;
  final String autoAction;
  final bool met;
  final bool armed;

  factory TrustSummary.fromJson(Json j) => TrustSummary(
    enabled: jBool(j, 'enabled'),
    streak: jInt(j, 'streak'),
    streakRequired: jInt(j, 'streak_required', 3),
    autoAction: jStr(j, 'auto_action', 'off'),
    met: jBool(j, 'met'),
    armed: jBool(j, 'armed'),
  );
}

class Workspace {
  const Workspace({
    required this.id,
    required this.projectId,
    required this.name,
    required this.branch,
    required this.worktreePath,
    required this.baseRef,
    this.port,
    this.status = WorkspaceStatus.idle,
    this.statusRaw = 'idle',
    this.kind = WorkspaceKind.managed,
    this.source,
    this.gate,
    this.trust,
    this.priorPrs = const [],
    this.lastPrNumber,
    this.seedKey,
    this.checkedRows = const [],
    this.planText,
    this.testFirst,
    this.mode = WorkspaceMode.agent,
    this.modeSwitches = const [],
    this.plans = const [],
    this.researchLookups = 0,
    this.recentAsks = const [],
    this.createdAt,
  });

  final String id;
  final String projectId;
  final String name;
  final String branch;
  final String worktreePath;
  final String baseRef;
  final int? port;
  final WorkspaceStatus status;

  /// The wire string, kept so an `unknown` status is still displayable and debuggable.
  final String statusRaw;
  final WorkspaceKind kind;
  final String? source;
  final GateSummary? gate;
  final TrustSummary? trust;
  final List<int> priorPrs;
  final int? lastPrNumber;
  final String? seedKey;
  final List<String> checkedRows;
  final String? planText;

  /// The test-first task's lifecycle; null for an ordinary workspace.
  final TestFirstState? testFirst;

  final WorkspaceMode mode;
  final List<ModeSwitch> modeSwitches;

  /// Manual-rail plans the read-only assistant wrote.
  final List<ManualPlan> plans;

  /// How many research lookups the manual rail has made on this workspace.
  final int researchLookups;

  /// The `ask` answers the backend kept (at most ten), newest first.
  final List<RecentAsk> recentAsks;

  /// Epoch seconds.
  final double? createdAt;

  bool get adopted => kind == WorkspaceKind.adopted;
  bool get manual => mode == WorkspaceMode.manual;

  factory Workspace.fromJson(Json j) {
    final gate = j['gate'];
    final trust = j['trust'];
    final testFirst = j['test_first'];
    return Workspace(
      id: jStr(j, 'id'),
      projectId: jStr(j, 'project_id'),
      name: jStr(j, 'name'),
      branch: jStr(j, 'branch'),
      worktreePath: jStr(j, 'worktree_path'),
      baseRef: jStr(j, 'base_ref'),
      port: jIntN(j, 'port'),
      status: WorkspaceStatus.parse(j['status']),
      statusRaw: jStr(j, 'status', 'idle'),
      kind: WorkspaceKind.parse(j['kind']),
      source: jStrN(j, 'source'),
      gate: gate is Map ? GateSummary.fromJson(asJson(gate)) : null,
      trust: trust is Map ? TrustSummary.fromJson(asJson(trust)) : null,
      priorPrs: jIntList(j, 'prior_prs'),
      lastPrNumber: jIntN(j, 'last_pr_number'),
      seedKey: jStrN(j, 'seed_key'),
      checkedRows: jStrList(j, 'checked_rows'),
      planText: jStrN(j, 'plan_text'),
      testFirst: testFirst is Map
          ? TestFirstState.fromJson(asJson(testFirst))
          : null,
      mode: WorkspaceMode.parse(j['mode']),
      modeSwitches: jList(j, 'mode_switches', ModeSwitch.fromJson),
      plans: jList(j, 'plans', ManualPlan.fromJson),
      researchLookups: jInt(asJson(j['research_log']), 'count'),
      recentAsks: RecentAsk.fromLog(asJson(j['research_log'])),
      createdAt: jDoubleN(j, 'created_at'),
    );
  }

  Workspace copyWith({
    WorkspaceStatus? status,
    String? statusRaw,
    GateSummary? gate,
    TrustSummary? trust,
    List<String>? checkedRows,
    String? name,
    String? branch,
    TestFirstState? testFirst,
    WorkspaceMode? mode,
    List<ModeSwitch>? modeSwitches,
  }) => Workspace(
    id: id,
    projectId: projectId,
    name: name ?? this.name,
    branch: branch ?? this.branch,
    worktreePath: worktreePath,
    baseRef: baseRef,
    port: port,
    status: status ?? this.status,
    statusRaw: statusRaw ?? this.statusRaw,
    kind: kind,
    source: source,
    gate: gate ?? this.gate,
    trust: trust ?? this.trust,
    priorPrs: priorPrs,
    lastPrNumber: lastPrNumber,
    seedKey: seedKey,
    checkedRows: checkedRows ?? this.checkedRows,
    planText: planText,
    testFirst: testFirst ?? this.testFirst,
    mode: mode ?? this.mode,
    modeSwitches: modeSwitches ?? this.modeSwitches,
    plans: plans,
    researchLookups: researchLookups,
    recentAsks: recentAsks,
    createdAt: createdAt,
  );
}

class AgentRun {
  const AgentRun({
    required this.id,
    required this.workspaceId,
    this.adapter = '',
    this.model,
    this.effort,
    this.task = '',
    this.plan = false,
    this.role = '',
    this.status = AgentRunStatus.running,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.costUsd,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String workspaceId;
  final String adapter;
  final String? model;
  final String? effort;
  final String task;

  /// A Plan-Mode run: the agent planned and edited nothing.
  final bool plan;

  /// `plan` | `build` | empty when `[roles]` is off.
  final String role;
  final AgentRunStatus status;
  final int tokensIn;
  final int tokensOut;
  final double? costUsd;
  final double? startedAt;
  final double? endedAt;

  factory AgentRun.fromJson(Json j) => AgentRun(
    id: jStr(j, 'id'),
    workspaceId: jStr(j, 'workspace_id'),
    adapter: jStr(j, 'adapter'),
    model: jStrN(j, 'model'),
    effort: jStrN(j, 'effort'),
    task: jStr(j, 'task'),
    plan: jBool(j, 'plan'),
    role: jStr(j, 'role'),
    status: AgentRunStatus.parse(j['status']),
    tokensIn: jInt(j, 'tokens_in'),
    tokensOut: jInt(j, 'tokens_out'),
    costUsd: jDoubleN(j, 'cost_usd'),
    startedAt: jDoubleN(j, 'started_at'),
    endedAt: jDoubleN(j, 'ended_at'),
  );
}

enum AgentEventType {
  token('token'),
  toolCall('tool_call'),
  fileEdit('file_edit'),
  done('done'),
  error('error'),

  /// Client-injected turn marker (echoes the prompt); also persisted in transcripts.
  user('user'),
  unknown('');

  const AgentEventType(this.wire);
  final String wire;

  static AgentEventType parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

class AgentEvent {
  const AgentEvent({
    required this.runId,
    required this.workspaceId,
    required this.ts,
    required this.type,
    this.payload = const {},
    this.turn,
  });

  final String runId;
  final String workspaceId;
  final double ts;
  final AgentEventType type;
  final Json payload;

  /// Per-workspace turn ordinal. Absent on transcripts persisted before markers existed.
  final int? turn;

  factory AgentEvent.fromJson(Json j) => AgentEvent(
    runId: jStr(j, 'run_id'),
    workspaceId: jStr(j, 'workspace_id'),
    ts: jDouble(j, 'ts'),
    type: AgentEventType.parse(j['type']),
    payload: asJson(j['payload']),
    turn: jIntN(j, 'turn'),
  );

  /// `token` text, `user` prompt echo.
  String get text => jStr(payload, 'text');

  /// `tool_call` tool name / `file_edit` tool name.
  String get tool => jStr(payload, 'tool');

  /// `file_edit` path (absolute or worktree-relative depending on the adapter).
  String? get path => jStrN(payload, 'path');

  /// A `done` event closing a Plan-Mode run: the transcript's plan-ready marker.
  bool get isPlanDone => type == AgentEventType.done && payload['plan'] == true;
}

/// A rewindable turn boundary, one per `user` event.
class TurnMarker {
  const TurnMarker({
    required this.turn,
    required this.runId,
    required this.ts,
    required this.prompt,
    required this.kind,
  });

  final int turn;
  final String runId;
  final double ts;
  final String prompt;

  /// `user` | `autofix` | `reviewfix`. The last two are platform-authored and dimmed in the UI.
  final String kind;

  factory TurnMarker.fromJson(Json j) => TurnMarker(
    turn: jInt(j, 'turn'),
    runId: jStr(j, 'run_id'),
    ts: jDouble(j, 'ts'),
    prompt: jStr(j, 'prompt'),
    kind: jStr(j, 'kind', 'user'),
  );

  /// Client-side derivation from a loaded transcript, same rule as the backend.
  static List<TurnMarker> derive(List<AgentEvent> events) => [
    for (final e in events)
      if (e.type == AgentEventType.user && e.turn != null)
        TurnMarker(
          turn: e.turn!,
          runId: e.runId,
          ts: e.ts,
          prompt: e.text,
          kind: e.runId == 'autofix'
              ? 'autofix'
              : e.runId == 'reviewfix'
              ? 'reviewfix'
              : 'user',
        ),
  ];
}

class RewindResponse {
  const RewindResponse({
    required this.turn,
    required this.prompt,
    required this.dropped,
    this.checkpoint,
  });

  final int turn;
  final String prompt;
  final int dropped;
  final String? checkpoint;

  factory RewindResponse.fromJson(Json j) => RewindResponse(
    turn: jInt(j, 'turn'),
    prompt: jStr(j, 'prompt'),
    dropped: jInt(j, 'dropped'),
    checkpoint: jStrN(j, 'checkpoint'),
  );
}

class DiffResponse {
  const DiffResponse({
    required this.baseRef,
    required this.diff,
    required this.filesChanged,
    this.commit,
  });

  final String baseRef;

  /// Unified diff text.
  final String diff;
  final int filesChanged;
  final String? commit;

  factory DiffResponse.fromJson(Json j) => DiffResponse(
    baseRef: jStr(j, 'base_ref'),
    diff: jStr(j, 'diff'),
    filesChanged: jInt(j, 'files_changed'),
    commit: jStrN(j, 'commit'),
  );
}
