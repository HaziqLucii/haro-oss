import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/state/live_gate.dart';
import 'package:haro_app/state/look_at.dart';
import 'package:haro_app/state/review_items.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../../../../api/fixtures.dart';
import '../../../../state/builders.dart';
import '../../harness.dart';

/// A run that ended [ago] before now, so the meta line reads `4m ago`. The extra seconds
/// keep the truncated minute count from ticking down mid-test.
Map<String, dynamic> endedAgo(Duration ago) => {
  'ended_at': DateTime.now().millisecondsSinceEpoch / 1000 - ago.inSeconds - 5,
};

TestRun greenRun({
  List<Map<String, dynamic>> unchecked = const [],
  List<Map<String, dynamic>> tamper = const [],
  Map<String, dynamic>? overrides,
}) => run(
  unchecked: unchecked,
  tamper: tamper,
  overrides: {...endedAgo(const Duration(minutes: 4)), ...?overrides},
);

TestRun failingRun({
  List<Map<String, dynamic>> tamper = const [],
  Map<String, dynamic>? overrides,
}) {
  final base = redRun(tamper: tamper);
  return run(
    status: 'failed',
    total: base.total,
    passed: base.passed,
    failed: base.failed,
    unchecked: null,
    tamper: tamper,
    cases: [
      for (var i = 0; i < base.failed; i++)
        caseJson(
          'calculateShipping › case $i',
          'failed',
          file: 'lib/shipping.test.ts',
          message: 'expected 0, received 499\n  at line',
        ),
      caseJson('ok', 'passed', file: 'lib/shipping.test.ts'),
    ],
    overrides: {...endedAgo(const Duration(minutes: 2)), ...?overrides},
  );
}

/// A `WorkspaceDetail` for the verify step with a flow derived from its own pieces.
WorkspaceDetail verifyDetail(
  WorkspaceStatus status, {
  TestRun? run,
  List<Cell> cells = const [],
  WorkspaceAnalysis analysis = WorkspaceAnalysis.none,
  GateConfig? config,
  int? expectedTotal,
  List<String> checked = const [],
  int? pr,
}) {
  final ws = Workspace.fromJson(
    workspaceJson(
      id: id,
      status: status.wire,
      overrides: {
        'project_id': 'p1',
        'name': 'electron optimization',
        'branch': 'feat/electron-optimization',
        'checked_rows': checked,
      },
    ),
  );
  final flow = deriveWorkspaceFlow(
    input(
      status,
      run: run,
      cells: cells,
      expectedTotal: expectedTotal,
      checked: checked,
      pr: pr,
    ),
  );
  return WorkspaceDetail(
    id: id,
    loaded: true,
    workspace: ws,
    flow: flow,
    gate: LiveGate(cells: cells, run: run),
    analysis: analysis,
    gateConfig: config,
    diff: const DiffResponse(
      baseRef: 'origin/main',
      diff: sampleDiff,
      filesChanged: 2,
    ),
  );
}

class VerifyActions extends WorkspaceActions {
  VerifyActions(super.ref, super.workspaceId, this.calls, this.prompts);

  final List<String> calls;

  /// The follow-up prompt each `sendLookAtToAgent` would have started an agent run with.
  final List<String> prompts;

  @override
  Future<TestRun> runGate({
    bool impacted = false,
    bool failedOnly = false,
  }) async {
    calls.add(impacted ? 'runGate:impacted' : 'runGate');
    return run();
  }

  @override
  Future<AgentRun?> sendFailuresToAgent() async {
    calls.add('sendFailures');
    return null;
  }

  @override
  Future<AgentRun?> restoreTests({List<TamperFinding>? findings}) async {
    calls.add('restoreTests');
    return null;
  }

  @override
  Future<AgentRun?> sendLookAtToAgent(List<LookAtItem> items) async {
    calls.add('send:${items.length}');
    prompts.add(buildFollowUpPrompt([for (final i in items) i.review]));
    return null;
  }

  @override
  Future<int> addToBacklog(List<LookAtItem> items) async {
    calls.add('backlog:${items.length}');
    return items.length;
  }

  @override
  Future<List<String>> toggleChecked(String rowKey, {bool? checked}) async {
    calls.add('toggle:$rowKey:$checked');
    return const [];
  }

  @override
  Future<MutationResponse> runMutation() async {
    calls.add('runMutation');
    return const MutationResponse(baseRef: 'main');
  }

  @override
  Future<CoverageResponse> measureCoverage() async {
    calls.add('measureCoverage');
    return const CoverageResponse(supported: false);
  }

  @override
  Future<FlakyResponse> checkFlaky({int runs = 5}) async {
    calls.add('checkFlaky');
    return const FlakyResponse();
  }
}

/// [Rig] plus the lazy providers the verify step reads, and an actions recorder that knows
/// the verify calls.
class VerifyRig extends Rig {
  VerifyRig(
    super.preview, {
    required WorkspaceDetail state,
    this.hunks,
    this.receipt,
    this.impact,
    this.blame,
  }) : super(detail: state);

  final VerifiedHunksResponse? hunks;
  final ReceiptResponse? receipt;
  final ImpactResponse? impact;
  final BlameResponse? blame;

  GoRouter? router;
  final impactCalls = <String>[];
  final prompts = <String>[];

  // Same overrides as `Rig`, minus its actions recorder: a family can only be overridden
  // once per container.
  @override
  List<Override> get overrides => [
    devicePrefsStoreProvider.overrideWithValue(prefs),
    workspaceDetailProvider.overrideWith2((wsId) => FixedDetail(wsId, detail!)),
    workspaceGitStatusProvider.overrideWith(
      (ref, wsId) async => const GitStatusResponse(
        branch: 'feat/electron-optimization',
        baseRef: 'origin/main',
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
    workspaceUrlOpenerProvider.overrideWithValue((uri) async {
      opened.add(uri);
      return true;
    }),
    workspaceActionsProvider.overrideWith(
      (ref, wsId) => VerifyActions(ref, wsId, calls, prompts),
    ),
    workspaceVerifiedHunksProvider.overrideWith((ref, wsId) async => hunks),
    workspaceReceiptProvider.overrideWith((ref, wsId) async => receipt),
    workspaceBlameProvider.overrideWith((ref, wsId) async => blame),
    workspaceImpactProvider.overrideWith((ref, wsId) async {
      impactCalls.add(wsId);
      final i = impact;
      if (i == null) throw HaroApiException(0, 'no impact');
      return i;
    }),
  ];
}

const sampleDiff = '''
diff --git a/frontend/src/components/AgentStream.tsx b/frontend/src/components/AgentStream.tsx
--- a/frontend/src/components/AgentStream.tsx
+++ b/frontend/src/components/AgentStream.tsx
@@ -209,3 +209,5 @@ export function AgentStream() {
   const x = 1;
+  const y = 2;
+  if (evt.kind === 'retry') return
   return x;
diff --git a/desktop/main.js b/desktop/main.js
--- a/desktop/main.js
+++ b/desktop/main.js
@@ -202,2 +204,3 @@
   const a = 1;
+  return 0 // OS-assigned fallback
''';

VerifiedHunksResponse sampleHunks() => VerifiedHunksResponse(
  baseRef: 'main',
  supported: true,
  files: [
    const VerifiedFile(
      path: 'frontend/src/components/AgentStream.tsx',
      inMap: true,
      added: 2,
      executed: 1,
      unexecuted: 1,
      lines: {210: 3, 211: 0},
    ),
    const VerifiedFile(
      path: 'frontend/src/components/ProjectSettingsModal.tsx',
      added: 5,
      unexecuted: 5,
    ),
    const VerifiedFile(
      path: 'desktop/main.js',
      inMap: true,
      added: 1,
      unexecuted: 1,
      lines: {205: 0},
    ),
  ],
);

MutationResponse sampleMutation() => const MutationResponse(
  baseRef: 'main',
  supported: true,
  score: 82,
  killed: 41,
  survived: 9,
  survivors: [
    MutationSurvivor(path: 'desktop/main.js', line: 206, operator: '|| → &&'),
    MutationSurvivor(
      path: 'desktop/main.js',
      line: 231,
      operator: 'timeout 3000 → 0',
    ),
  ],
);

ImpactResponse sampleImpact() => const ImpactResponse(
  baseRef: 'main',
  supported: true,
  totalTests: 594,
  totalTestFiles: 40,
  changedFiles: [ChangedFile(path: 'desktop/main.js', added: 12, removed: 3)],
  impactedTests: [
    ImpactTest(file: 'desktop/main.test.js', name: 'a'),
    ImpactTest(file: 'desktop/main.test.js', name: 'b'),
    ImpactTest(file: 'frontend/src/App.test.tsx', name: 'c'),
  ],
  impactedFiles: ['desktop/main.test.js', 'frontend/src/App.test.tsx'],
);
