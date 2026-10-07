import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/haro_api.dart';
import '../api/haro_ws.dart';
import '../api/models/models.dart';
import '../state/agent_signals.dart';
import '../state/diff_stats.dart';
import '../state/live_gate.dart';
import '../state/sub_agents.dart';
import '../state/workspace_flow.dart';
import 'workspace_detail_models.dart';
import 'workspace_store.dart';

export 'workspace_detail_models.dart';

DateTime _systemNow() => DateTime.now();

/// Timings the notifier reads once, so tests can run the same code paths in milliseconds.
class WorkspaceDetailTuning {
  const WorkspaceDetailTuning({
    this.diffDebounce = const Duration(milliseconds: 400),
    this.liveFlush = const Duration(milliseconds: 50),
    this.keepAlive = const Duration(seconds: 20),
    this.tickElapsed = true,
    this.logCap = 5000,
    this.now = _systemNow,
  });

  /// Quiet time after the last agent edit, `fs` event or settle before `GET /diff` re-runs.
  final Duration diffDebounce;

  /// Agent tokens and gate cells arrive in bursts; they are applied (and the flow
  /// re-derived) once per this window instead of once per message. Zero applies each
  /// message synchronously.
  final Duration liveFlush;

  /// How long a workspace's socket and state outlive their last listener, so hopping
  /// between steps or workspaces does not reconnect.
  final Duration keepAlive;

  /// Re-derive once a second (then every 15s) while an agent runs so `working · 14s`
  /// advances.
  final bool tickElapsed;
  final int logCap;
  final DateTime Function() now;
}

final workspaceDetailTuningProvider = Provider<WorkspaceDetailTuning>(
  (ref) => const WorkspaceDetailTuning(),
);

/// One live view per open workspace. Owns the workspace's only [HaroWorkspaceSocket].
final workspaceDetailProvider = NotifierProvider.autoDispose
    .family<WorkspaceDetailNotifier, WorkspaceDetail, String>(
      WorkspaceDetailNotifier.new,
    );

/// Narrow selectors, so a widget that only needs the flow or the log does not rebuild on
/// every token or dev-log line.
final workspaceFlowProvider = Provider.autoDispose
    .family<WorkspaceFlow?, String>(
      (ref, id) => ref.watch(workspaceDetailProvider(id).select((d) => d.flow)),
    );

final workspaceDevLogProvider = Provider.autoDispose.family<DevLog, String>(
  (ref, id) => ref.watch(workspaceDetailProvider(id).select((d) => d.devLog)),
);

const _mainSession = 'main';

bool _settles(WorkspaceStatus s) =>
    s == WorkspaceStatus.gateGreen ||
    s == WorkspaceStatus.gateRed ||
    s == WorkspaceStatus.idle ||
    s == WorkspaceStatus.merged;

class WorkspaceDetailNotifier extends Notifier<WorkspaceDetail> {
  WorkspaceDetailNotifier(this.id);

  final String id;

  late final WorkspaceDetailTuning _tuning;
  late final DevLogBuffer _log;
  HaroWorkspaceSocket? _socket;
  final _assist = StreamController<AssistEvent>.broadcast();
  final _assistResync = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  final _pending = <WsEvent>[];
  Timer? _flushTimer;
  Timer? _diffTimer;
  Timer? _tickTimer;
  Timer? _keepAliveTimer;
  bool _diffInFlight = false;
  bool _diffQueued = false;
  bool _disposed = false;

  // The REST snapshot must not overwrite anything the socket already delivered.
  bool _liveTestSeen = false;
  bool _liveWatchSeen = false;

  @override
  WorkspaceDetail build() {
    _tuning = ref.read(workspaceDetailTuningProvider);
    _log = DevLogBuffer(cap: _tuning.logCap);

    // Riverpod pauses listeners under an opaque route and fires onResume, not
    // onAddListener, when they come back; a link closed during a pause must be retaken.
    void Function()? closeLink;
    void arm() {
      _keepAliveTimer?.cancel();
      final close = closeLink ??= ref.keepAlive().close;
      _keepAliveTimer = Timer(_tuning.keepAlive, () {
        close();
        if (identical(closeLink, close)) closeLink = null;
      });
    }

    void disarm() => _keepAliveTimer?.cancel();

    arm();
    ref.onAddListener(disarm);
    ref.onResume(disarm);
    ref.onCancel(arm);
    ref.onDispose(_teardown);

    ref.listen(workspaceStoreProvider.select((s) => _find(s, id)), (_, next) {
      if (next != null) _adoptWorkspace(next);
    });

    final socket = ref.read(haroWsProvider).workspace(id);
    _socket = socket;
    _subs
      ..add(socket.events.listen(_onEvent))
      ..add(socket.connectionStates.listen(_onConnection))
      ..add(socket.reconnected.listen((_) => _onReconnected()));

    final fromStore = _find(ref.read(workspaceStoreProvider), id);
    Future.microtask(_load);
    return _derive(WorkspaceDetail(id: id, workspace: fromStore));
  }

  static Workspace? _find(WorkspaceSnapshot s, String id) {
    for (final w in s.all) {
      if (w.id == id) return w;
    }
    return null;
  }

  /// Manual-rail assist progress (`assist` channel), kept off [WorkspaceDetail] so a streamed
  /// token never rebuilds the whole workspace.
  Stream<AssistEvent> get assistEvents => _assist.stream;

  /// Fires when the socket comes back: the `assist` channel is not replayed, so anything
  /// that mirrors a job re-reads `GET /assist`.
  Stream<void> get assistResync => _assistResync.stream;

  HaroApi get _api => ref.read(haroApiProvider);

  void _teardown() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _flushTimer?.cancel();
    _diffTimer?.cancel();
    _tickTimer?.cancel();
    _keepAliveTimer?.cancel();
    unawaited(_assist.close());
    unawaited(_assistResync.close());
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.dispose());
  }

  bool get _alive => !_disposed && ref.mounted;

  void _set(WorkspaceDetail d) {
    if (!_alive) return;
    state = d;
    _syncTick();
  }

  // ---- initial load ----

  Future<void> _load() async {
    if (!_alive) return;
    var ws = state.workspace;
    if (ws == null) {
      try {
        ws = await _api.getWorkspace(id);
      } on HaroApiException catch (e) {
        _set(state.copyWith(loaded: true, error: e.message));
        return;
      }
      if (!_alive) return;
      _adoptWorkspace(ws);
    }

    final projectId = ws.projectId;
    final results = await Future.wait<Object?>([
      _try<List<AgentEvent>>(() => _api.getEvents(id)),
      _try<TestRun?>(() => _api.getTests(id)),
      _try<DiffResponse>(() => _api.getDiff(id)),
      _try<WatchState>(() => _api.getWatch(id)),
      _try<SetupState>(() => _api.getSetup(id)),
      _try<GateConfig>(() => _api.getGate(projectId)),
    ]);
    if (!_alive) return;

    var d = state;
    final events = results[0] as List<AgentEvent>?;
    if (events != null) {
      final (main, nested) = splitNested(events);
      d = d.copyWith(
        events: _mergeTranscript(main, d.events),
        subEvents: _mergeTranscript(nested, d.subEvents),
      );
    }

    final test = results[1] as TestRun?;
    if (test != null && !_liveTestSeen) {
      d = d.copyWith(gate: LiveGate.fromRun(test));
    }

    final diff = results[2] as DiffResponse?;
    if (diff != null) {
      d = d.copyWith(diff: diff, diffStats: parseDiffStats(diff.diff));
    }

    final watch = results[3] as WatchState?;
    if (watch != null) {
      d = d.copyWith(watchEnabled: watch.enabled);
      final run = watch.run;
      if (run != null && !_liveWatchSeen) {
        d = d.copyWith(
          watch: LiveWatch(
            cells: [for (final (i, c) in run.cases.indexed) c.toCell(i)],
            run: run,
          ),
        );
      }
    }

    final setup = results[4] as SetupState?;
    if (setup != null) d = d.copyWith(setup: setup);
    final gateCfg = results[5] as GateConfig?;
    if (gateCfg != null) d = d.copyWith(gateConfig: gateCfg);

    _set(_derive(d.copyWith(loaded: true, error: null)));
  }

  /// A failed side load must not blank the workspace: the React client swallows each one.
  Future<T?> _try<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (_) {
      // One bad side load (HTTP or a payload the models can't parse) must not blank the
      // whole workspace.
      return null;
    }
  }

  // ---- workspace sync ----

  void _adoptWorkspace(Workspace w) {
    if (!_alive) return;
    _set(_derive(state.copyWith(workspace: w)));
  }

  /// Applies a fresher workspace copy locally. `WorkspaceActions` calls this after a
  /// mutation and mirrors it into the shared store.
  void patchWorkspace(Workspace w) => _adoptWorkspace(w);

  /// Flips the status before a request (the composer and gate button lock at once) and
  /// returns the value to restore if the request fails, since no status event will
  /// come to unstick it.
  WorkspaceStatus? optimisticStatus(WorkspaceStatus s) {
    if (!_alive) return null;
    final ws = state.workspace;
    if (ws == null) return null;
    final prev = ws.status;
    _set(_derive(state.copyWith(workspace: ws.copyWith(status: s))));
    return prev;
  }

  void restoreStatus(WorkspaceStatus? prev) {
    if (!_alive) return;
    final ws = state.workspace;
    if (prev == null || ws == null) return;
    _set(_derive(state.copyWith(workspace: ws.copyWith(status: prev))));
  }

  Future<Workspace> reloadWorkspace() async {
    final w = await _api.getWorkspace(id);
    if (_alive) {
      ref.read(workspaceStoreProvider.notifier).updateWorkspace(w);
      patchWorkspace(w);
    }
    return w;
  }

  // ---- socket ----

  void _onConnection(WsConnectionState c) {
    if (!_alive) return;
    _set(state.copyWith(connection: c));
  }

  void _onEvent(WsEvent e) {
    if (!_alive) return;
    switch (e) {
      case AgentStreamEvent(:final sessionId):
        if (sessionId != null && sessionId != _mainSession) return;
        _enqueue(e);
      case TestEvent():
        _liveTestSeen = true;
        _enqueue(e);
      case WatchEvent():
        _liveWatchSeen = true;
        _set(state.copyWith(watch: state.watch.apply(e)));
      case StatusEvent():
        _flush();
        _onStatus(e);
      case RunEvent():
        _onRun(e);
      case FsEvent():
        _set(
          state.copyWith(
            fsRevision: state.fsRevision + 1,
            lastFs: e.kind == 'changed' ? e : null,
          ),
        );
        _scheduleDiff();
      case AssistEvent():
        if (!_assist.isClosed) _assist.add(e);
      case NotifyEvent():
      case XpWsEvent():
      case BaselineWsEvent():
      case UnknownWsEvent():
        break;
    }
  }

  void _enqueue(WsEvent e) {
    _pending.add(e);
    if (_tuning.liveFlush == Duration.zero) {
      _flush();
    } else {
      _flushTimer ??= Timer(_tuning.liveFlush, _flush);
    }
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty || !_alive) return;
    final batch = List<WsEvent>.of(_pending);
    _pending.clear();

    var d = state;
    final events = List<AgentEvent>.of(d.events);
    final nested = List<AgentEvent>.of(d.subEvents);
    var gate = d.gate;
    var analysis = d.analysis;
    var onlyTokens = events.isNotEmpty;
    var diffTrigger = false;

    for (final e in batch) {
      switch (e) {
        case AgentStreamEvent(:final event) when isNestedEvent(event):
          // A sub-agent's own step: it changes nothing the flow reads, only the agents panel.
          nested.add(event);
        case AgentStreamEvent(:final event):
          events.add(event);
          if (event.type != AgentEventType.token) onlyTokens = false;
          if (event.type == AgentEventType.done ||
              event.type == AgentEventType.error ||
              event.type == AgentEventType.fileEdit) {
            diffTrigger = true;
          }
        case TestEvent():
          final prevEnd = gate.run?.endedAt;
          gate = gate.apply(e);
          if (e is TestSnapshotEvent && e.run.endedAt != prevEnd) {
            analysis = analysis.withoutMutation();
          }
          onlyTokens = false;
        default:
          break;
      }
    }

    d = d.copyWith(
      events: events,
      subEvents: nested,
      gate: gate,
      analysis: analysis,
    );
    // A token changes nothing the flow reads, and tokens are the bulk of the traffic.
    _set(onlyTokens ? d : _derive(d));
    if (diffTrigger) _scheduleDiff();
  }

  void _onStatus(StatusEvent e) {
    var d = state;
    if (e.setup != null) d = d.copyWith(setup: e.setup);
    final ws = d.workspace;
    final status = e.status;
    if (status != null && ws != null) {
      final changed = ws.status != status;
      d = d.copyWith(
        workspace: ws.copyWith(
          status: status,
          statusRaw: e.statusRaw,
          gate: e.gate,
          testFirst: e.testFirst,
          mode: e.mode,
        ),
        gitRevision: changed ? d.gitRevision + 1 : d.gitRevision,
        gateRevision: _settles(status) ? d.gateRevision + 1 : d.gateRevision,
      );
      if (_settles(status)) _scheduleDiff();
    }
    _set(_derive(d));
  }

  void _onRun(RunEvent e) {
    if (e.isLogLine) {
      _log.add(e.line!);
      _set(state.copyWith(devLog: _log.snapshot()));
      return;
    }
    final running = e.running ?? false;
    final prev = state.runs[e.runId];
    final runs = {
      ...state.runs,
      e.runId: DevRun(
        running: running,
        url: e.url,
        error: running ? null : (e.error ?? prev?.error),
        exit: e.exit,
      ),
    };
    if (running) _log.clear();
    _set(state.copyWith(runs: runs, devLog: _log.snapshot()));
  }

  /// Records the outcome of `POST /run` right away instead of waiting for the `run` event.
  void applyRunResult(RunAppResult r, {String runId = 'app'}) {
    if (!_alive) return;
    final prev = state.runs[runId];
    _set(
      state.copyWith(
        runs: {
          ...state.runs,
          runId: DevRun(running: r.running, url: r.url ?? prev?.url),
        },
      ),
    );
  }

  Future<void> _onReconnected() async {
    if (!_alive) return;
    // The backend replays test/status/run/fs history on connect but never agent events,
    // and replayed dev-log lines would double up what is already buffered.
    _log.clear();
    _set(
      state.copyWith(
        devLog: _log.snapshot(),
        gateRevision: state.gateRevision + 1,
        gitRevision: state.gitRevision + 1,
      ),
    );
    _scheduleDiff();
    if (!_assistResync.isClosed) _assistResync.add(null);
    await reloadTranscript();
  }

  // ---- transcript ----

  /// Re-reads the durable transcript. Live events newer than the snapshot's latest
  /// event survive, so a run that started while the GET was in flight is not lost.
  Future<void> reloadTranscript() async {
    if (!_alive) return;
    final events = await _try(() => _api.getEvents(id));
    if (events == null || !_alive) return;
    _flush();
    _set(_derive(_withTranscript(state, events)));
  }

  static WorkspaceDetail _withTranscript(
    WorkspaceDetail d,
    List<AgentEvent> snapshot,
  ) {
    final (main, nested) = splitNested(snapshot);
    return d.copyWith(
      events: _mergeTranscript(main, d.events),
      subEvents: _mergeTranscript(nested, d.subEvents),
    );
  }

  static List<AgentEvent> _mergeTranscript(
    List<AgentEvent> snapshot,
    List<AgentEvent> live,
  ) {
    var maxTs = 0.0;
    for (final e in snapshot) {
      maxTs = math.max(maxTs, e.ts);
    }
    return [...snapshot, ...live.where((e) => e.ts > maxTs)];
  }

  /// The backend persists the prompt but does not publish it, so the client echoes it
  /// (same as the React client). Its timestamp precedes the persisted copy's, so the
  /// merge rule above drops it once the durable transcript includes the real one.
  AgentEvent echoUser(String text) {
    if (!_alive) return _echo(text);
    final e = _echo(text);
    _flush();
    _set(_derive(state.copyWith(events: [...state.events, e])));
    return e;
  }

  AgentEvent _echo(String text) => AgentEvent(
    runId: 'user',
    workspaceId: id,
    ts: _tuning.now().millisecondsSinceEpoch / 1000,
    type: AgentEventType.user,
    payload: {'text': text},
  );

  void removeEvent(AgentEvent e) {
    if (!_alive) return;
    _set(
      _derive(
        state.copyWith(
          events: [
            for (final x in state.events)
              if (!identical(x, e)) x,
          ],
        ),
      ),
    );
  }

  // ---- diff ----

  void _scheduleDiff() {
    _diffTimer?.cancel();
    _diffTimer = Timer(_tuning.diffDebounce, () => unawaited(refreshDiff()));
  }

  /// Fetches the diff now. If one is already in flight, exactly one more runs after it, so
  /// an edit that lands mid-fetch is never missed.
  Future<void> refreshDiff() async {
    if (!_alive) return;
    _diffTimer?.cancel();
    if (_diffInFlight) {
      _diffQueued = true;
      return;
    }
    _diffInFlight = true;
    try {
      final diff = await _try(() => _api.getDiff(id));
      if (diff != null && _alive) {
        _set(
          _derive(
            state.copyWith(diff: diff, diffStats: parseDiffStats(diff.diff)),
          ),
        );
      }
    } finally {
      _diffInFlight = false;
      if (_diffQueued) {
        _diffQueued = false;
        unawaited(refreshDiff());
      }
    }
  }

  // ---- misc state written by WorkspaceActions ----

  /// Applies a gate result returned by `POST /tests`. The socket sends the same snapshot;
  /// applying it here keeps the flow correct if the socket is down.
  void applyGateRun(TestRun run) {
    if (!_alive || run.trigger == 'watch') return;
    _flush();
    final prevEnd = state.gate.run?.endedAt;
    _set(
      _derive(
        state.copyWith(
          gate: state.gate.apply(TestSnapshotEvent(run)),
          analysis: run.endedAt != prevEnd
              ? state.analysis.withoutMutation()
              : null,
        ),
      ),
    );
  }

  void setAnalysis(WorkspaceAnalysis a) {
    if (_alive) _set(_derive(state.copyWith(analysis: a)));
  }

  void bumpGit() {
    if (_alive) _set(state.copyWith(gitRevision: state.gitRevision + 1));
  }

  void bumpGate() {
    if (!_alive) return;
    _set(
      state.copyWith(
        gateRevision: state.gateRevision + 1,
        gitRevision: state.gitRevision + 1,
      ),
    );
  }

  void scheduleDiffRefresh() => _scheduleDiff();

  // ---- derivation ----

  WorkspaceDetail _derive(WorkspaceDetail d) {
    final ws = d.workspace;
    if (ws == null) return d;

    final busy = ws.status == WorkspaceStatus.agentRunning;
    final phase = _phaseOf(ws, d.events);
    final signals = deriveAgentSignals(
      d.events,
      busy: busy,
      worktreePath: ws.worktreePath,
    );
    final started = _startedAt(d.events);
    final live = phase == AgentPhase.running && started != null
        ? _tuning.now().difference(started)
        : null;

    final settledTotal = d.gate.run?.total ?? ws.gate?.total;
    final flow = deriveWorkspaceFlow(
      FlowInput.fromWorkspace(
        ws,
        signals: signals,
        agent: phase,
        agentElapsed: live,
        diff: d.diffStats,
        run: d.gate.run,
        cells: d.gate.cells,
        expectedTotal: (settledTotal ?? 0) > 0 ? settledTotal : null,
        survivors: d.analysis.mutation?.survivors,
        codeToCheckEnabled: d.gateConfig?.codeToCheck != 'off',
      ),
    );
    return d.copyWith(
      signals: signals,
      agentPhase: phase,
      agentStartedAt: started,
      agentElapsed: live ?? signals.lastRunDuration,
      flow: flow,
    );
  }

  static AgentPhase _phaseOf(Workspace ws, List<AgentEvent> events) {
    if (ws.status == WorkspaceStatus.agentRunning) return AgentPhase.running;
    for (var i = events.length - 1; i >= 0; i--) {
      switch (events[i].type) {
        case AgentEventType.done:
          return AgentPhase.done;
        case AgentEventType.error:
          return AgentPhase.error;
        case AgentEventType.user:
          return ws.status == WorkspaceStatus.settingUp
              ? AgentPhase.queued
              : AgentPhase.none;
        default:
          continue;
      }
    }
    return AgentPhase.none;
  }

  static DateTime? _startedAt(List<AgentEvent> events) {
    for (var i = events.length - 1; i >= 0; i--) {
      if (events[i].type == AgentEventType.user) {
        return DateTime.fromMillisecondsSinceEpoch(
          (events[i].ts * 1000).round(),
        );
      }
    }
    return null;
  }

  void _syncTick() {
    if (!_tuning.tickElapsed || _disposed) return;
    final running = state.agentPhase == AgentPhase.running;
    if (!running) {
      _tickTimer?.cancel();
      _tickTimer = null;
      return;
    }
    if (_tickTimer != null) return;
    final secs = (state.agentElapsed?.inSeconds ?? 0) < 60 ? 1 : 15;
    _tickTimer = Timer(Duration(seconds: secs), () {
      _tickTimer = null;
      if (_alive) _set(_derive(state));
    });
  }
}
