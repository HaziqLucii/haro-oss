import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../api/haro_ws.dart';
import '../api/models/models.dart';
import '../state/agent_signals.dart';
import '../state/diff_stats.dart';
import '../state/live_gate.dart';
import '../state/workspace_flow.dart';

/// State of one named dev run (`run` channel). `app` is the default run.
@immutable
class DevRun {
  const DevRun({this.running = false, this.url, this.error, this.exit});

  static const stopped = DevRun();

  final bool running;
  final String? url;
  final String? error;
  final int? exit;
}

/// Ring buffer for the Dev log tab. The list is shared and mutated in place (a per-line
/// copy of 5000 strings would be the hot path of a chatty dev server), so consumers detect
/// change through [revision], not list identity.
class DevLogBuffer {
  DevLogBuffer({this.cap = 5000, int? slack}) : _slack = slack ?? cap ~/ 10;

  final int cap;
  final int _slack;
  final _lines = <String>[];
  int _revision = 0;

  /// Trims a `slack` batch at a time so appends stay O(1) amortized while the visible
  /// length never exceeds [cap].
  void add(String line) {
    if (_lines.length >= cap) _lines.removeRange(0, _slack + 1);
    _lines.add(line);
    _revision++;
  }

  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    _revision++;
  }

  DevLog snapshot() => DevLog._(UnmodifiableListView(_lines), _revision);
}

@immutable
class DevLog {
  const DevLog._(this.lines, this.revision);

  static const empty = DevLog._(<String>[], 0);

  /// Live view of the buffer, oldest first.
  final List<String> lines;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is DevLog &&
      other.revision == revision &&
      identical(other.lines, lines);

  @override
  int get hashCode => Object.hash(revision, identityHashCode(lines));
}

enum AnalysisKind { mutation, coverage, flaky }

/// On-demand evidence. Each one re-runs the suite (slow, `409` while an agent is running),
/// so none is fetched automatically: the verify step asks through `WorkspaceActions`.
@immutable
class WorkspaceAnalysis {
  const WorkspaceAnalysis({
    this.mutation,
    this.coverage,
    this.flaky,
    this.running = const {},
    this.errors = const {},
  });

  static const none = WorkspaceAnalysis();

  final MutationResponse? mutation;
  final CoverageResponse? coverage;
  final FlakyResponse? flaky;
  final Set<AnalysisKind> running;

  /// Last failure message per kind, cleared when that kind is retried.
  final Map<AnalysisKind, String> errors;

  bool isRunning(AnalysisKind k) => running.contains(k);

  /// A new gate run invalidates a stale score (the React client does the same).
  WorkspaceAnalysis withoutMutation() => WorkspaceAnalysis(
    coverage: coverage,
    flaky: flaky,
    running: running,
    errors: {...errors}..remove(AnalysisKind.mutation),
  );

  WorkspaceAnalysis begin(AnalysisKind k) => WorkspaceAnalysis(
    mutation: mutation,
    coverage: coverage,
    flaky: flaky,
    running: {...running, k},
    errors: {...errors}..remove(k),
  );

  WorkspaceAnalysis finish(
    AnalysisKind k, {
    MutationResponse? mutation,
    CoverageResponse? coverage,
    FlakyResponse? flaky,
    String? error,
  }) => WorkspaceAnalysis(
    mutation: mutation ?? this.mutation,
    coverage: coverage ?? this.coverage,
    flaky: flaky ?? this.flaky,
    running: {...running}..remove(k),
    errors: error == null ? errors : {...errors, k: error},
  );
}

const Object _keep = Object();

/// Everything a workspace screen reads, in one immutable value. [workspace] and [flow] stay
/// null until the workspace has loaded (or [error] says why it could not).
@immutable
class WorkspaceDetail {
  const WorkspaceDetail({
    required this.id,
    this.loaded = false,
    this.error,
    this.workspace,
    this.gate = LiveGate.empty,
    this.watch = LiveWatch.empty,
    this.watchEnabled = false,
    this.events = const [],
    this.subEvents = const [],
    this.signals = AgentSignals.none,
    this.agentPhase = AgentPhase.none,
    this.agentStartedAt,
    this.agentElapsed,
    this.diff,
    this.diffStats = DiffStats.empty,
    this.runs = const {},
    this.devLog = DevLog.empty,
    this.setup,
    this.gateConfig,
    this.analysis = WorkspaceAnalysis.none,
    this.gateRevision = 0,
    this.gitRevision = 0,
    this.fsRevision = 0,
    this.lastFs,
    this.connection = WsConnectionState.connecting,
    this.flow,
  });

  final String id;

  /// The initial REST batch (transcript, gate, diff, ...) has settled.
  final bool loaded;
  final String? error;

  /// Kept in sync with `workspaceStoreProvider` and with this workspace's own socket.
  final Workspace? workspace;

  /// The authoritative gate: live grid cells plus the last settled run. Only `test`
  /// channel events ever reach it.
  final LiveGate gate;

  /// The advisory Live Gate. Separate type and separate field on purpose: never merged
  /// into [gate].
  final LiveWatch watch;
  final bool watchEnabled;

  /// Primary-session transcript, oldest first.
  final List<AgentEvent> events;

  /// A delegated sub-agent's own steps (tagged `payload.parent`), kept apart from [events] so
  /// nothing that reads the driving agent's transcript can mistake them for its work.
  final List<AgentEvent> subEvents;
  final AgentSignals signals;
  final AgentPhase agentPhase;

  /// Start of the newest turn (its `user` event), when the transcript has one.
  final DateTime? agentStartedAt;

  /// Live elapsed while a run is going, else the last finished run's duration.
  final Duration? agentElapsed;

  /// Latest `GET /diff`. Null until the first fetch lands.
  final DiffResponse? diff;
  final DiffStats diffStats;

  /// Dev runs by run id. Use [app] for the default one.
  final Map<String, DevRun> runs;
  final DevLog devLog;
  final SetupState? setup;
  final GateConfig? gateConfig;
  final WorkspaceAnalysis analysis;

  /// Bumped when the gate settled or the workspace went idle/merged: lazy verify and ship
  /// providers refetch on it.
  final int gateRevision;

  /// Bumped when git or PR facts may have changed (any status change, commit, PR, merge).
  final int gitRevision;

  /// Bumped on every worktree `fs` event, for the file tree and open editors.
  final int fsRevision;

  /// The latest `changed` fs event (a quiescent one never replaces it), so a listener sees
  /// which paths moved, not only that something did.
  final FsEvent? lastFs;
  final WsConnectionState connection;
  final WorkspaceFlow? flow;

  DevRun get app => runs['app'] ?? DevRun.stopped;

  /// The port the dev server is configured on (`:4500`), even while it is stopped.
  int? get port => workspace?.port;

  bool get hasAgentRun => events.isNotEmpty;

  WorkspaceDetail copyWith({
    bool? loaded,
    Object? error = _keep,
    Workspace? workspace,
    LiveGate? gate,
    LiveWatch? watch,
    bool? watchEnabled,
    List<AgentEvent>? events,
    List<AgentEvent>? subEvents,
    AgentSignals? signals,
    AgentPhase? agentPhase,
    Object? agentStartedAt = _keep,
    Object? agentElapsed = _keep,
    DiffResponse? diff,
    DiffStats? diffStats,
    Map<String, DevRun>? runs,
    DevLog? devLog,
    SetupState? setup,
    GateConfig? gateConfig,
    WorkspaceAnalysis? analysis,
    int? gateRevision,
    int? gitRevision,
    int? fsRevision,
    FsEvent? lastFs,
    WsConnectionState? connection,
    Object? flow = _keep,
  }) => WorkspaceDetail(
    id: id,
    loaded: loaded ?? this.loaded,
    error: identical(error, _keep) ? this.error : error as String?,
    workspace: workspace ?? this.workspace,
    gate: gate ?? this.gate,
    watch: watch ?? this.watch,
    watchEnabled: watchEnabled ?? this.watchEnabled,
    events: events ?? this.events,
    subEvents: subEvents ?? this.subEvents,
    signals: signals ?? this.signals,
    agentPhase: agentPhase ?? this.agentPhase,
    agentStartedAt: identical(agentStartedAt, _keep)
        ? this.agentStartedAt
        : agentStartedAt as DateTime?,
    agentElapsed: identical(agentElapsed, _keep)
        ? this.agentElapsed
        : agentElapsed as Duration?,
    diff: diff ?? this.diff,
    diffStats: diffStats ?? this.diffStats,
    runs: runs ?? this.runs,
    devLog: devLog ?? this.devLog,
    setup: setup ?? this.setup,
    gateConfig: gateConfig ?? this.gateConfig,
    analysis: analysis ?? this.analysis,
    gateRevision: gateRevision ?? this.gateRevision,
    gitRevision: gitRevision ?? this.gitRevision,
    fsRevision: fsRevision ?? this.fsRevision,
    lastFs: lastFs ?? this.lastFs,
    connection: connection ?? this.connection,
    flow: identical(flow, _keep) ? this.flow : flow as WorkspaceFlow?,
  );
}
