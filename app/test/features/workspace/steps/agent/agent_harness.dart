import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/state/sub_agents.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_step.dart';
import 'package:haro_app/features/workspace/steps/agent/composer_state.dart';
import 'package:haro_app/state/agent_signals.dart';
import 'package:haro_app/state/diff_stats.dart';
import 'package:haro_app/state/workspace_flow.dart'
    show AgentPhase, deriveWorkspaceFlow;

import '../../../../state/builders.dart' show input;

import '../../../creation_harness.dart' as ch;
import '../../harness.dart';

export '../../../creation_harness.dart'
    show MockBackend, jsonRes, errorRes, loadBrandFonts;
export '../../harness.dart' show Preview, Rig, id, pathOf;

/// A detail whose value tests can replace to simulate the live stream.
class LiveDetail extends FixedDetail {
  LiveDetail(super.id, super.value);

  void set(WorkspaceDetail d) => state = d;
}

class StartCall {
  StartCall(
    this.task,
    this.plan,
    this.model,
    this.effort,
    this.role,
    this.adapter, [
    this.testFirst = false,
    this.scope,
  ]);

  final String task;
  final bool testFirst;
  final bool plan;
  final String? model;
  final String? effort;
  final String? role;
  final String? adapter;
  final List<String>? scope;

  @override
  String toString() => 'start($task, plan=$plan, $role, $model, $effort)';
}

class AgentCalls {
  final starts = <StartCall>[];
  final stops = <int>[];
  int approvals = 0;
  int testFirstApprovals = 0;
  int sentFailures = 0;
  int restores = 0;
  final approveArgs = <(String?, String?, String?)>[];
  final approveScopes = <List<String>?>[];
  HaroApiException? startFails;
}

class AgentActions extends WorkspaceActions {
  AgentActions(super.ref, super.workspaceId, this.calls);

  final AgentCalls calls;

  @override
  Future<AgentRun?> startAgent(
    String task, {
    bool plan = false,
    String? model,
    String? effort,
    String? role,
    String? adapter,
    bool testFirst = false,
    List<String>? scope,
  }) async {
    if (calls.startFails != null) throw calls.startFails!;
    calls.starts.add(
      StartCall(task, plan, model, effort, role, adapter, testFirst, scope),
    );
    return null;
  }

  @override
  Future<AgentRun> approveTestFirst({
    String? model,
    String? effort,
    List<String>? scope,
  }) async {
    calls.testFirstApprovals++;
    return AgentRun(id: 'run-tf', workspaceId: workspaceId);
  }

  @override
  Future<void> stopAgent() async => calls.stops.add(1);

  @override
  Future<AgentRun?> approvePlan({
    String? model,
    String? effort,
    String? adapter,
    String role = 'build',
    List<String>? scope,
  }) async {
    calls.approvals++;
    calls.approveScopes.add(scope);
    calls.approveArgs.add((model, effort, adapter));
    return null;
  }

  @override
  Future<AgentRun?> sendFailuresToAgent() async {
    calls.sentFailures++;
    return null;
  }

  @override
  Future<AgentRun?> restoreTests({List<TamperFinding>? findings}) async {
    calls.restores++;
    return null;
  }
}

/// Config and backlog answers the composer reads.
MockBackendBuilder backend({
  bool rolesOn = true,
  List<Map<String, dynamic>> todoFiles = const [],
  List<String> files = const ['src/App.tsx', 'src/lib/rates.ts', 'README.md'],
  dynamic Function()? stopResponse,
  dynamic Function()? restoreResponse,
}) => MockBackendBuilder(
  rolesOn: rolesOn,
  todoFiles: todoFiles,
  files: files,
  stopResponse: stopResponse,
  restoreResponse: restoreResponse,
);

class MockBackendBuilder {
  MockBackendBuilder({
    required this.rolesOn,
    required this.todoFiles,
    required this.files,
    this.stopResponse,
    this.restoreResponse,
  });

  /// Answer for restoring run_1's start (null: the route is absent, so a call 404s).
  final dynamic Function()? restoreResponse;

  /// Answer for stopping sub-agent t1 (null: the route is absent, so a call 404s).
  final dynamic Function()? stopResponse;

  final bool rolesOn;
  final List<Map<String, dynamic>> todoFiles;
  final List<String> files;

  late final ch.MockBackend mock = ch.MockBackend({
    'GET /projects/p1/roles': (_) => ch.jsonRes({
      'enabled': rolesOn,
      'plan': 'opus:high',
      'build': 'sonnet:high',
      'review': 'opus:high',
      'scout': 'haiku',
      'review_enforce': 'off',
      'review_max_rounds': 2,
    }),
    'GET /projects/p1/agent': (_) => ch.jsonRes({
      'default_model': 'opus',
      'default_effort': 'high',
      'adapter': 'claude-code',
    }),
    'GET /projects/p1/todo': (_) =>
        ch.jsonRes({'files': todoFiles, 'orphaned': []}),
    'GET /workspaces/$id/files': (_) => ch.jsonRes({
      'tree': [
        for (final f in files)
          {'name': f.split('/').last, 'path': f, 'dir': false},
      ],
    }),
    if (stopResponse != null)
      'POST /workspaces/$id/agents/t1/stop': (_) => stopResponse!(),
    if (restoreResponse != null)
      'POST /workspaces/$id/runs/run_1/restore-start': (_) =>
          restoreResponse!(),
    'POST /workspaces/$id/context': (call) => ch.jsonRes({
      'path': '.context/pasted-ab12.txt',
      'name': 'pasted-ab12.txt',
      'kind': 'text',
      'lines': (call.body?['content'] as String? ?? '').split('\n').length,
    }),
  });
}

Map<String, dynamic> todoFile(String label, List<String> open) => {
  'path': 'backlog/$label',
  'label': label,
  'items': [
    for (final (i, t) in open.indexed)
      {'text': t, 'body': t, 'done': false, 'seed_key': '$label-$i'},
  ],
};

/// Rig for the agent step: real shell and router, fake actions, scripted config.
class AgentRig extends Rig {
  AgentRig(
    super.preview, {
    this.events = const [],
    this.status,
    this.planReady = false,
    this.waiting = false,
    this.elapsed,
    this.testFirst,
    MockBackendBuilder? backend,
  }) : agent = AgentCalls(),
       api = (backend ?? _defaultBackend()).mock,
       super(detail: null);

  static MockBackendBuilder _defaultBackend() => backend();

  final AgentCalls agent;
  final ch.MockBackend api;
  final List<AgentEvent> events;
  final WorkspaceStatus? status;
  final bool planReady;
  final bool waiting;
  final Duration? elapsed;
  final TestFirstState? testFirst;

  WorkspaceDetail detailWith(List<AgentEvent> all) {
    // The store keeps a sub-agent's own steps apart from the driving agent's transcript.
    final (transcript, nested) = splitNested(all);
    final base = detailFor(
      preview,
      events: transcript,
    ).copyWith(subEvents: nested);
    final st = status ?? base.workspace!.status;
    final ws = base.workspace!.copyWith(status: st, testFirst: testFirst);
    final busy = st == WorkspaceStatus.agentRunning;
    var signals = deriveAgentSignals(
      transcript,
      busy: busy,
      worktreePath: ws.worktreePath,
    );
    if (planReady || waiting) {
      signals = AgentSignals(
        hasActivity: true,
        planReady: planReady,
        waitingOnInput: waiting,
      );
    }
    var flow = base.flow;
    if (planReady || waiting || busy || testFirst != null) {
      flow = deriveWorkspaceFlow(
        input(
          st,
          testFirst: testFirst,
          agent: busy ? AgentPhase.running : AgentPhase.done,
          planReady: planReady,
          waiting: waiting,
          diff: DiffStats.empty,
          elapsed: elapsed,
        ),
      );
    }
    return base.copyWith(
      flow: flow,
      workspace: ws,
      signals: signals,
      agentPhase: busy ? AgentPhase.running : AgentPhase.done,
      agentElapsed: elapsed,
    );
  }

  /// Rig's own list minus the two providers this rig replaces (a family cannot be
  /// overridden twice in one scope).
  @override
  List<Override> get overrides => [
    devicePrefsStoreProvider.overrideWithValue(prefs),
    workspaceDetailProvider.overrideWith2(
      (wsId) => LiveDetail(wsId, detailWith(events)),
    ),
    workspaceActionsProvider.overrideWith(
      (ref, wsId) => AgentActions(ref, wsId, agent),
    ),
    workspaceGitStatusProvider.overrideWith(
      (ref, wsId) async => const GitStatusResponse(
        branch: 'feat/electron-optimization',
        baseRef: 'origin/main',
        behind: 0,
      ),
    ),
    workspaceStoreProvider.overrideWith(
      () => FakeStore(
        WorkspaceSnapshot(
          loaded: true,
          projects: [project()],
          workspaces: {
            'p1': [workspaceFor(preview)],
          },
        ),
      ),
    ),
    haroWsProvider.overrideWithValue(
      HaroWs(Uri.parse('http://127.0.0.1:8000'), connector: net.connect),
    ),
    backendStatusProvider.overrideWith((ref) => Stream.value(BackendStatus.up)),
    workspaceUrlOpenerProvider.overrideWithValue((uri) async => true),
    haroApiProvider.overrideWithValue(api.api),
    agentClockProvider.overrideWithValue(
      () => DateTime.fromMillisecondsSinceEpoch(
        (1790000000 * 1000) + 14 * 60 * 1000,
        isUtc: true,
      ),
    ),
  ];
}

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AgentStep)));

/// Replaces the transcript the way the socket would.
void pushEvents(WidgetTester tester, AgentRig rig, List<AgentEvent> events) {
  final n = containerOf(
    tester,
  ).read(workspaceDetailProvider(id).notifier) as LiveDetail;
  n.set(rig.detailWith(events));
}

Finder field() => find.byKey(const ValueKey('composer-field'));

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(field()).controller!.text;
