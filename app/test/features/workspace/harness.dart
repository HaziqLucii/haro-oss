import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/state/diff_stats.dart';
import 'package:haro_app/state/live_gate.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../../api/fixtures.dart';
import '../../data/detail_harness.dart' show FakeWsNet;
import '../../state/builders.dart';

const id = 'ws_1';

/// The five states of the prototype's Preview bar.
enum Preview { idle, idleWithChanges, running, red, green, merged }

Workspace workspaceFor(Preview p, {WorkspaceMode mode = WorkspaceMode.agent}) =>
    Workspace.fromJson(
      workspaceJson(
        id: id,
        status: switch (p) {
          Preview.idle || Preview.idleWithChanges => 'idle',
          Preview.running => 'tests_running',
          Preview.red => 'gate_red',
          Preview.green => 'gate_green',
          Preview.merged => 'merged',
        },
        overrides: {
          'project_id': 'p1',
          'name': 'electron optimization',
          'branch': 'feat/electron-optimization',
          'mode': mode.wire,
        },
      ),
    );

WorkspaceDetail detailFor(
  Preview p, {
  List<AgentEvent> events = const [],
  DevLog devLog = DevLog.empty,
  Map<String, DevRun> runs = const {},
  WorkspaceMode mode = WorkspaceMode.agent,
}) {
  final ws = workspaceFor(p, mode: mode);
  final TestRun? settled = switch (p) {
    Preview.red => redRun(),
    Preview.green => run(
      unchecked: [
        untestedRow('lib/rates.ts', 2),
        untestedRow('lib/zones.ts', 1),
      ],
    ),
    Preview.merged => run(),
    _ => null,
  };
  final liveCells = p == Preview.running ? cells(412, running: 8) : <Cell>[];
  final flow = deriveWorkspaceFlow(switch (p) {
    Preview.idle => input(
      WorkspaceStatus.idle,
      mode: mode,
      agent: AgentPhase.none,
      activity: false,
      diff: DiffStats.empty,
      elapsed: null,
    ),
    Preview.idleWithChanges => input(
      WorkspaceStatus.idle,
      mode: mode,
      agent: AgentPhase.none,
      activity: false,
      elapsed: null,
    ),
    Preview.running => input(
      WorkspaceStatus.testsRunning,
      mode: mode,
      cells: liveCells,
      expectedTotal: 594,
    ),
    Preview.red => input(WorkspaceStatus.gateRed, mode: mode, run: settled),
    Preview.green => input(WorkspaceStatus.gateGreen, mode: mode, run: settled),
    Preview.merged => input(
      WorkspaceStatus.merged,
      mode: mode,
      run: settled,
      pr: 232,
    ),
  });
  return WorkspaceDetail(
    id: id,
    loaded: true,
    workspace: ws,
    flow: flow,
    gate: LiveGate(cells: liveCells, run: settled),
    events: events,
    devLog: devLog,
    runs: runs,
  );
}

class FixedDetail extends WorkspaceDetailNotifier {
  FixedDetail(super.id, this.value);

  final WorkspaceDetail value;

  @override
  WorkspaceDetail build() => value;
}

class FakeStore extends WorkspaceStore {
  FakeStore(this.snapshot);

  final WorkspaceSnapshot snapshot;

  @override
  WorkspaceSnapshot build() => snapshot;
}

class RecordingActions extends WorkspaceActions {
  RecordingActions(super.ref, super.workspaceId, this.calls, {this.failWith});

  final List<String> calls;
  final HaroApiException? failWith;

  T _record<T>(String name, T value) {
    calls.add(name);
    if (failWith != null) throw failWith!;
    return value;
  }

  @override
  Future<TestRun> runGate({
    bool impacted = false,
    bool failedOnly = false,
  }) async => _record('runGate', run());

  @override
  Future<AgentRun?> sendFailuresToAgent() async =>
      _record('sendFailures', null);

  @override
  Future<AgentRun?> restoreTests({List<TamperFinding>? findings}) async =>
      _record('restoreTests', null);

  @override
  Future<ContinueResult> continueOnNewBranch() async =>
      _record('continueOnNewBranch', const ContinueResult());

  @override
  Future<RunAppResult> startDevServer({String? runId}) async =>
      _record('startDevServer', const RunAppResult(running: true));

  @override
  Future<void> stopDevServer({String? runId}) async =>
      _record('stopDevServer', null);

  @override
  Future<Workspace> renameWorkspace({String? name, String? branch}) async =>
      _record('rename:$name', workspaceFor(Preview.green));

  @override
  Future<void> archiveWorkspace() async => _record('archive', null);

  @override
  Future<Workspace> setMode(WorkspaceMode mode) async =>
      _record('setMode:${mode.wire}', workspaceFor(Preview.green, mode: mode));
}

Project project() =>
    const Project(id: 'p1', name: 'haro', path: '/x', defaultBranch: 'main');

class Rig {
  Rig(
    this.preview, {
    this.detail,
    this.behind = 15,
    this.failWith,
    this.mode = WorkspaceMode.agent,
    this.runProblem,
  }) : net = FakeWsNet(),
       calls = [],
       opened = [];

  final Preview preview;
  final WorkspaceDetail? detail;

  /// The device prefs file, in memory: collapse states and the like land here, never in
  /// the real `~/.haro`.
  MemoryDevicePrefsStore prefs = MemoryDevicePrefsStore();

  /// Who writes the code in the rig's workspace (store copy and derived flow).
  final WorkspaceMode mode;
  final int behind;

  /// What the static `package.json` check says about the default run script.
  final String? runProblem;
  final HaroApiException? failWith;
  final FakeWsNet net;
  final List<String> calls;
  final List<Uri> opened;

  /// Applied after [overrides], for a test that only adds providers no rig overrides.
  final List<Override> extra = [];

  List<Override> get overrides => [
    devicePrefsStoreProvider.overrideWithValue(prefs),
    workspaceDetailProvider.overrideWith2(
      (wsId) => FixedDetail(wsId, detail ?? detailFor(preview, mode: mode)),
    ),
    workspaceActionsProvider.overrideWith(
      (ref, wsId) => RecordingActions(ref, wsId, calls, failWith: failWith),
    ),
    workspaceRunProblemProvider.overrideWith((ref, wsId) async => runProblem),
    workspaceGitStatusProvider.overrideWith(
      (ref, wsId) async => GitStatusResponse(
        branch: 'feat/electron-optimization',
        baseRef: 'origin/main',
        behind: behind,
      ),
    ),
    workspaceStoreProvider.overrideWith(
      () => FakeStore(
        WorkspaceSnapshot(
          loaded: true,
          projects: [project()],
          workspaces: {
            'p1': [workspaceFor(preview, mode: mode)],
          },
        ),
      ),
    ),
    haroWsProvider.overrideWithValue(
      HaroWs(Uri.parse('http://127.0.0.1:8000'), connector: net.connect),
    ),
    backendStatusProvider.overrideWith((ref) => Stream.value(BackendStatus.up)),
    workspaceUrlOpenerProvider.overrideWithValue((uri) async {
      opened.add(uri);
      return true;
    }),
  ];

  /// Pumps the whole app (real shell, router) on the workspace route.
  Future<GoRouter> pump(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    String step = 'verify',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter(initialLocation: '/w/$id/$step');
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [...overrides, ...extra],
        child: HaroApp(router: router),
      ),
    );
    router.go('/w/$id/$step');
    await tester.pumpAndSettle();
    return router;
  }
}

String pathOf(GoRouter r) => r.routerDelegate.currentConfiguration.uri.path;

class WorkspaceDetailStub {
  const WorkspaceDetailStub();

  WorkspaceDetail get loading => const WorkspaceDetail(id: id);

  WorkspaceDetail failed(String message) =>
      WorkspaceDetail(id: id, loaded: true, error: message);
}
