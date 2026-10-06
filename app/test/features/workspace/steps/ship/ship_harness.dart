import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
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
import 'package:haro_app/features/workspace/steps/ship/ship_step.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/state/diff_stats.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../../../data/detail_harness.dart' show FakeWsNet;
import '../../harness.dart';

export '../../harness.dart';

const shipDiff = DiffStats(files: 21, added: 367, removed: 130);

GitStatusResponse gitStatus({
  int ahead = 1,
  int behind = 0,
  int dirty = 0,
  String mergeMode = 'both',
  bool worktreeMissing = false,
}) => GitStatusResponse(
  branch: 'feat/electron-optimization',
  baseRef: 'origin/main',
  ahead: ahead,
  behind: behind,
  dirty: dirty,
  mergeMode: mergeMode,
  worktreeMissing: worktreeMissing,
);

PrStatusResponse noPr({bool supported = true}) =>
    PrStatusResponse(supported: supported);

PrStatusResponse openPr({
  int number = 232,
  bool merged = false,
  String? mergeable,
}) => PrStatusResponse(
  supported: true,
  exists: true,
  number: number,
  title: 'perf(desktop): stable port, async PATH scrape, lazy panels',
  state: merged ? 'MERGED' : 'OPEN',
  workspaceMerged: merged,
  url: 'https://github.com/HaziqLucii/haro/pull/$number',
  mergeable: mergeable,
);

const commitA = GitCommit(
  sha: 'a41f0c2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  short: 'a41f0c2',
  author: 'HaziqLucii',
  when: '14 minutes ago',
  subject: 'perf(desktop): stable port, async PATH scrape…',
  own: true,
);

Receipt receipt({
  String verdict = 'green',
  int total = 594,
  int passed = 594,
  int failed = 0,
  bool tamperClean = true,
  bool tamperProtected = false,
  String? gateSha,
  double? mutationScore,
  int survivors = 0,
  List<String> flakyRetried = const [],
  String writtenBy = '',
  String? xp,
}) => Receipt(
  workspaceId: id,
  writtenBy: writtenBy,
  xp: xp,
  branch: 'feat/electron-optimization',
  baseRef: 'origin/main',
  verdict: verdict,
  gateSha: gateSha,
  suite: ReceiptSuite(
    runner: 'vitest',
    scope: 'all',
    total: total,
    passed: passed,
    failed: failed,
    flakyRetried: flakyRetried,
  ),
  tamper: ReceiptTamper(
    measured: true,
    clean: tamperClean,
    findingsCount: tamperClean ? 0 : 1,
    note: tamperClean ? null : '1 removed',
    protected: tamperProtected,
  ),
  verifiedHunks: const ReceiptVerifiedHunks(supported: true, percentage: 98.1),
  mutation: ReceiptMutation(
    supported: mutationScore != null,
    ran: mutationScore != null,
    score: mutationScore,
    survivors: [
      for (var i = 0; i < survivors; i++)
        MutationSurvivor(path: 'lib/a.ts', line: i + 1, operator: 'eq'),
    ],
  ),
  agent: const ReceiptAgent(model: 'sonnet-5', effort: 'high', costUsd: 9.89),
);

VerifiedHunksResponse hunks() => const VerifiedHunksResponse(
  baseRef: 'origin/main',
  supported: true,
  files: [
    VerifiedFile(path: 'a.ts', added: 200, executed: 190, unexecuted: 4),
    VerifiedFile(path: 'b.ts', added: 170, executed: 171, unexecuted: 2),
  ],
);

/// Every call the ship step can make, recorded. `mergeResult` decides what merge returns.
class ShipActions extends WorkspaceActions {
  ShipActions(
    super.ref,
    super.workspaceId,
    this.calls, {
    this.mergeResult = const MergeResult(merged: true, method: 'gh'),
    this.failMerge,
    this.postResult = 'https://github.com/x/pull/232#c1',
    this.commitResult = const CommitResult(committed: 'b7c8d9e0f1'),
    this.onReview,
  });

  final List<String> calls;
  final MergeResult mergeResult;
  final HaroApiException? failMerge;
  final String? postResult;
  final CommitResult commitResult;
  final Future<AiReview> Function()? onReview;

  @override
  Future<AiReview> runReview({String? model}) async {
    calls.add('review');
    return onReview == null
        ? const ReviewResult(ranAt: 1790000000, model: 'sonnet')
        : onReview!();
  }

  @override
  Future<MergeResult> merge({String? message}) async {
    calls.add('merge');
    if (failMerge != null) throw failMerge!;
    return mergeResult;
  }

  @override
  Future<CommitResult> commit(String message) async {
    calls.add('commit:$message');
    return commitResult;
  }

  @override
  Future<CreatePrResult> openPr() async {
    calls.add('openPr');
    return const CreatePrResult(
      created: true,
      url: 'https://github.com/x/pull/9',
    );
  }

  @override
  Future<ContinueResult> continueOnNewBranch() async {
    calls.add('continue');
    return const ContinueResult();
  }

  @override
  Future<String?> postReceiptToPr() async {
    calls.add('post');
    return postResult;
  }
}

/// The overrides for one ship-step scenario, on top of the workspace [Rig] state.
class ShipRig {
  ShipRig(
    this.preview, {
    GitStatusResponse? git,
    PrStatusResponse? pr,
    Receipt? receiptValue,
    this.commits = const [commitA],
    this.mergeResult = const MergeResult(merged: true, method: 'gh'),
    this.failMerge,
    this.postResult = 'https://github.com/x/pull/232#c1',
    this.noReceipt = false,
    this.onReview,
    this.diff = shipDiff,
    this.mode = WorkspaceMode.agent,
    this.prApi,
    this.gitGate,
    this.prGate,
    this.logGate,
    this.receiptGate,
    Json? prefs,
  }) : prefs = MemoryDevicePrefsStore(prefs),
       git = git ?? gitStatus(),
       pr = pr ?? noPr(),
       receiptValue =
           receiptValue ??
           receipt(
             verdict: preview == Preview.red ? 'red' : 'green',
             failed: preview == Preview.red ? 3 : 0,
             passed: preview == Preview.red ? 591 : 594,
           ),
       net = FakeWsNet(),
       opened = [],
       calls = [];

  final Preview preview;
  final WorkspaceMode mode;
  final MemoryDevicePrefsStore prefs;
  final GitStatusResponse git;
  final PrStatusResponse pr;
  final Receipt receiptValue;
  final List<GitCommit> commits;
  final MergeResult mergeResult;
  final HaroApiException? failMerge;
  final String? postResult;
  final bool noReceipt;
  final Future<AiReview> Function()? onReview;
  final DiffStats diff;

  /// When set, the real `workspacePrProvider` (with its poll) runs against this instead of
  /// the fixed `pr`.
  final HaroApi? prApi;

  /// When set, that source stays loading until the completer completes (or errors).
  final Completer<GitStatusResponse>? gitGate;
  final Completer<PrStatusResponse>? prGate;
  final Completer<List<GitCommit>>? logGate;
  final Completer<ReceiptResponse?>? receiptGate;
  final FakeWsNet net;
  final List<Uri> opened;
  final List<String> calls;

  WorkspaceDetail get detail {
    final base = detailFor(preview, mode: mode);
    return WorkspaceDetail(
      id: id,
      loaded: true,
      workspace: base.workspace,
      flow: base.flow,
      gate: base.gate,
      diffStats: diff,
    );
  }

  // Same shell wiring as Rig, minus the providers this step overrides itself: a family can
  // only be overridden once per container.
  List<Override> get overrides => [
    devicePrefsStoreProvider.overrideWithValue(prefs),
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
    workspaceDetailProvider.overrideWith2((wsId) => FixedDetail(wsId, detail)),
    workspaceActionsProvider.overrideWith(
      (ref, wsId) => ShipActions(
        ref,
        wsId,
        calls,
        mergeResult: mergeResult,
        failMerge: failMerge,
        postResult: postResult,
        onReview: onReview,
      ),
    ),
    workspaceGitStatusProvider.overrideWith(
      (ref, wsId) => gitGate != null ? gitGate!.future : Future.value(git),
    ),
    if (prApi != null)
      haroApiProvider.overrideWithValue(prApi!)
    else
      workspacePrProvider.overrideWith(
        (ref, wsId) => prGate != null ? prGate!.future : Future.value(pr),
      ),
    workspaceGitLogProvider.overrideWith(
      (ref, wsId) => logGate != null ? logGate!.future : Future.value(commits),
    ),
    workspaceReceiptProvider.overrideWith(
      (ref, wsId) => receiptGate != null
          ? receiptGate!.future
          : Future.value(
              noReceipt
                  ? null
                  : ReceiptResponse(
                      receipt: receiptValue,
                      markdown: 'backend md',
                    ),
            ),
    ),
    workspaceVerifiedHunksProvider.overrideWith((ref, wsId) async => hunks()),
  ];

  /// The step alone, inside a router that knows the workspace step paths.
  Future<GoRouter> pumpStep(
    WidgetTester tester, {
    Size size = const Size(1000, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/w/$id/ship',
      routes: [
        GoRoute(
          path: '/w/:id/:step',
          builder: (context, state) => state.pathParameters['step'] == 'ship'
              ? SizedBox(
                  width: size.width,
                  height: size.height,
                  child: ShipStep(state.pathParameters['id']!),
                )
              : Text('at ${state.pathParameters['step']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: overrides,
        child: MaterialApp.router(
          theme: buildHaroTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// The whole app (frame, step bar, rail) on `/w/ws_1/ship`.
  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    bool terminal = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter(initialLocation: '/w/$id/ship');
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: overrides,
        child: HaroApp(router: router),
      ),
    );
    router.go('/w/$id/ship');
    await tester.pumpAndSettle();
    if (terminal) {
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
    }
    return router;
  }
}

/// Bone-filled buttons inside the ship step.
int primaryButtons(WidgetTester tester) {
  final scope = find.byType(ShipStep);
  return tester
      .widgetList<HaroButton>(
        find.descendant(of: scope, matching: find.byType(HaroButton)),
      )
      .where((b) => b.variant == HaroButtonVariant.primary)
      .length;
}

/// Captures `Clipboard.setData` calls; returns the list they land in.
List<String> mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}
