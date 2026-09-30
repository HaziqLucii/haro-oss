import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/haro_api.dart';
import '../api/haro_ws.dart';
import '../api/models/models.dart';
import '../backend/backend_health.dart';

final haroApiProvider = Provider<HaroApi>((ref) {
  final api = HaroApi(Uri.parse(ref.watch(backendConfigProvider).baseUrl));
  ref.onDispose(api.close);
  return api;
});

final haroWsProvider = Provider<HaroWs>(
  (ref) => HaroWs(Uri.parse(ref.watch(backendConfigProvider).baseUrl)),
);

@immutable
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    this.loaded = false,
    this.projects = const [],
    this.workspaces = const {},
    this.backlogOpen = 0,
    this.error,
  });

  final bool loaded;
  final List<Project> projects;

  /// Keyed by project id, in the order the backend returned them.
  final Map<String, List<Workspace>> workspaces;
  final int backlogOpen;
  final String? error;

  Iterable<Workspace> get all => workspaces.values.expand((l) => l);

  WorkspaceSnapshot patch(StatusEvent e) {
    var changed = false;
    final next = <String, List<Workspace>>{};
    for (final entry in workspaces.entries) {
      next[entry.key] = [
        for (final w in entry.value)
          if (w.id == e.workspaceId)
            () {
              changed = true;
              return w.copyWith(
                status: e.status,
                statusRaw: e.statusRaw,
                gate: e.gate,
                testFirst: e.testFirst,
                mode: e.mode,
              );
            }()
          else
            w,
      ];
    }
    if (!changed) return this;
    return WorkspaceSnapshot(
      loaded: loaded,
      projects: projects,
      workspaces: next,
      backlogOpen: backlogOpen,
    );
  }

  bool has(String workspaceId) => all.any((w) => w.id == workspaceId);
}

/// Projects and workspaces from REST, kept live by the global `/ws` status feed. The feed is
/// not replayed, so a reconnect, a backend coming back up, or a status for a workspace we
/// have never seen (created elsewhere) all trigger a full reload.
class WorkspaceStore extends Notifier<WorkspaceSnapshot> {
  HaroGlobalSocket? _socket;
  final _subs = <StreamSubscription<Object?>>[];
  final _xp = StreamController<XpWsEvent>.broadcast();

  /// Award events from the global feed, for the XP store. Lives as long as this store.
  Stream<XpWsEvent> get xpEvents => _xp.stream;

  final _baseline = StreamController<BaselineWsEvent>.broadcast();

  /// First-run baseline progress from the global feed, for the First run page.
  Stream<BaselineWsEvent> get baselineEvents => _baseline.stream;
  bool _loading = false;
  bool _reloadQueued = false;

  @override
  WorkspaceSnapshot build() {
    ref.listen(backendStatusProvider, (prev, next) {
      if (next.value == BackendStatus.up && prev?.value != BackendStatus.up) {
        _connect();
        _baselineResync();
        reload();
      }
    });
    ref.onDispose(() {
      _disconnect();
      unawaited(_xp.close());
      unawaited(_baseline.close());
    });
    return const WorkspaceSnapshot();
  }

  void _connect() {
    if (_socket != null) return;
    final socket = ref.read(haroWsProvider).global()..connect();
    _socket = socket;
    _subs
      ..add(socket.status.listen(_onStatus))
      ..add(
        socket.xp.listen((e) {
          if (!_xp.isClosed) _xp.add(e);
        }),
      )
      ..add(
        socket.baseline.listen((e) {
          if (!_baseline.isClosed) _baseline.add(e);
        }),
      )
      ..add(
        socket.reconnected.listen((_) {
          _baselineResync();
          reload();
        }),
      );
  }

  /// The feed is not replayed: a baseline event missed across a reconnect or a backend
  /// restart would leave a "running" row stuck, so listeners re-read the truth.
  void _baselineResync() {
    if (!_baseline.isClosed) {
      _baseline.add(const BaselineWsEvent(projectId: '*', kind: 'resync'));
    }
  }

  void _disconnect() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _socket?.dispose();
    _socket = null;
  }

  void _onStatus(StatusEvent e) {
    if (!state.has(e.workspaceId)) {
      reload();
      return;
    }
    state = state.patch(e);
  }

  /// Swaps in a fresher copy of a workspace this store already holds (rename, checked
  /// rows, continue), so the sidebar and the detail view agree before the next reload.
  void updateWorkspace(Workspace w) {
    var found = false;
    final next = <String, List<Workspace>>{};
    for (final entry in state.workspaces.entries) {
      next[entry.key] = [
        for (final old in entry.value)
          if (old.id == w.id)
            () {
              found = true;
              return w;
            }()
          else
            old,
      ];
    }
    if (!found) return;
    state = WorkspaceSnapshot(
      loaded: state.loaded,
      projects: state.projects,
      workspaces: next,
      backlogOpen: state.backlogOpen,
      error: state.error,
    );
  }

  Future<void> reload() async {
    if (_loading) {
      _reloadQueued = true;
      return;
    }
    _loading = true;
    try {
      final api = ref.read(haroApiProvider);
      final projects = await api.listProjects();
      final lists = await Future.wait(
        projects.map((p) => api.listWorkspaces(p.id)),
      );
      final backlog = await Future.wait(
        projects.map((p) => _openTodos(api, p)),
      );
      state = WorkspaceSnapshot(
        loaded: true,
        projects: projects,
        workspaces: {
          for (var i = 0; i < projects.length; i++)
            projects[i].id: [
              for (final w in lists[i])
                if (w.status != WorkspaceStatus.archived) w,
            ],
        },
        backlogOpen: backlog.fold(0, (a, b) => a + b),
      );
    } on HaroApiException catch (e) {
      state = WorkspaceSnapshot(
        loaded: state.loaded,
        projects: state.projects,
        workspaces: state.workspaces,
        backlogOpen: state.backlogOpen,
        error: e.message,
      );
    } finally {
      _loading = false;
      if (_reloadQueued) {
        _reloadQueued = false;
        unawaited(reload());
      }
    }
  }

  // Backlog is secondary: a project without a todo file must not break the sidebar.
  static Future<int> _openTodos(HaroApi api, Project p) async {
    try {
      final todo = await api.getTodo(p.id);
      return todo.files.expand((f) => f.items).where((i) => !i.done).length;
    } on HaroApiException {
      return 0;
    }
  }
}

final workspaceStoreProvider =
    NotifierProvider<WorkspaceStore, WorkspaceSnapshot>(WorkspaceStore.new);
