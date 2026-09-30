import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/haro_api.dart';
import '../api/models/models.dart';
import '../state/look_at.dart';
import '../state/review_items.dart';
import 'workspace_detail.dart';
import 'workspace_store.dart';

/// Per-workspace mutations. Every method lets a failing request surface as a
/// [HaroApiException] (optimistic state is rolled back first). The refresh that follows a
/// mutation never turns a successful mutation into an exception.
///
/// Not auto-disposed: it is a handle (a `Ref` and an id) that reads the detail provider on
/// each call, so a screen may hold it past its own watch of the detail state.
final workspaceActionsProvider = Provider.family<WorkspaceActions, String>(
  (ref, id) => WorkspaceActions(ref, id),
);

class WorkspaceActions {
  WorkspaceActions(this._ref, this.workspaceId);

  final Ref _ref;
  final String workspaceId;

  HaroApi get _api => _ref.read(haroApiProvider);
  WorkspaceDetailNotifier get _n =>
      _ref.read(workspaceDetailProvider(workspaceId).notifier);
  WorkspaceDetail get _d => _ref.read(workspaceDetailProvider(workspaceId));
  WorkspaceStore get _store => _ref.read(workspaceStoreProvider.notifier);

  Workspace get _ws {
    final w = _d.workspace;
    if (w == null) {
      throw HaroApiException(0, 'workspace $workspaceId is not loaded');
    }
    return w;
  }

  Future<void> _refresh(Future<void> Function() f) async {
    try {
      await f();
    } on HaroApiException {
      // The mutation already happened; a stale view heals on the next event.
    }
  }

  // ---- agent ----

  /// Echoes the prompt into the transcript and flips the workspace to `agent_running`
  /// before the request, as the React client does; both roll back if it fails. [role]
  /// defaults to `plan` for a plan-first run and `build` otherwise (ignored server-side
  /// when `[roles]` is off). Returns null for a blank [task].
  Future<AgentRun?> startAgent(
    String task, {
    bool plan = false,
    String? model,
    String? effort,
    String? role,
    String? adapter,
    bool testFirst = false,
  }) async {
    final text = task.trim();
    if (text.isEmpty) return null;
    final n = _n;
    final echo = n.echoUser(text);
    final prior = n.optimisticStatus(WorkspaceStatus.agentRunning);
    try {
      return await _api.startAgent(
        workspaceId,
        text,
        adapter: adapter,
        model: model,
        effort: effort,
        plan: plan,
        role: role ?? (plan ? 'plan' : 'build'),
        testFirst: testFirst ? true : null,
      );
    } catch (_) {
      n.removeEvent(echo);
      n.restoreStatus(prior);
      rethrow;
    }
  }

  /// `409` from the backend when nothing is running.
  Future<void> stopAgent() => _api.stopAgent(workspaceId);

  /// Approve a finished Plan-Mode run: re-runs the same session with edits enabled.
  ///
  /// [model], [effort] and [adapter] are the composer's run arguments, as the React client
  /// passes them; with `[roles]` on the caller leaves model and effort out.
  Future<AgentRun?> approvePlan({
    String? model,
    String? effort,
    String? adapter,
    String role = 'build',
  }) => startAgent(
    'The plan above is approved. Implement it now. Make the changes in this worktree.',
    model: model,
    effort: effort,
    adapter: adapter,
    role: role,
  );

  /// Approves the proven-red acceptance test: the backend records its hashes and starts the
  /// build run. Unlike [startAgent] there is nothing to echo, the build prompt is server-made.
  Future<AgentRun> approveTestFirst({String? model, String? effort}) async {
    final n = _n;
    final prior = n.optimisticStatus(WorkspaceStatus.agentRunning);
    try {
      return await _api.approveTestFirst(
        workspaceId,
        model: model,
        effort: effort,
      );
    } catch (_) {
      n.restoreStatus(prior);
      rethrow;
    }
  }

  /// Leaves test-first mode so ordinary runs work again. The backend clears the state, so
  /// the workspace copy it returns replaces ours (a merge-style copy would keep the old one).
  Future<Workspace> leaveTestFirst({bool confirm = false}) async {
    final w = await _api.cancelTestFirst(workspaceId, confirm: confirm);
    _n.patchWorkspace(w);
    _store.updateWorkspace(w);
    return w;
  }

  /// One follow-up prompt with every failing test. Null when nothing is failing.
  Future<AgentRun?> sendFailuresToAgent() {
    final d = _d;
    var items = [
      for (final i in d.flow?.lookAt.pending ?? const <LookAtItem>[])
        if (i.isFailure) i.review,
    ];
    if (items.isEmpty) {
      items = failedCells(
        d.gate.cells,
        d.gate.run,
      ).map(failureReviewItem).toList();
    }
    return _sendItems(items);
  }

  /// "Send N to agent" / "Ask agent" from the needs-your-eyes list.
  Future<AgentRun?> sendLookAtToAgent(List<LookAtItem> items) =>
      _sendItems([for (final i in items) i.review]);

  /// The tamper alarm's "Restore test": every finding of the latest run by default, each
  /// with its restore instruction pre-written (the finding is the ask), sent as one prompt.
  Future<AgentRun?> restoreTests({List<TamperFinding>? findings}) {
    final list = findings ?? _d.gate.run?.tamperFindings ?? const [];
    return _sendItems([for (final f in list) tamperReviewItem(f)]);
  }

  Future<AgentRun?> _sendItems(List<ReviewItem> items) {
    if (items.isEmpty) return Future.value();
    return startAgent(buildFollowUpPrompt(items), role: 'build');
  }

  // ---- gate ----

  /// Resolves when the run finishes. The live cells stream over the socket meanwhile; the
  /// status flips to `tests_running` at once so the button locks.
  Future<TestRun> runGate({
    bool impacted = false,
    bool failedOnly = false,
  }) async {
    final n = _n;
    final prior = n.optimisticStatus(WorkspaceStatus.testsRunning);
    try {
      final run = await _api.runTests(
        workspaceId,
        scope: failedOnly
            ? TestScope.failed
            : impacted
            ? TestScope.impacted
            : TestScope.all,
      );
      n.applyGateRun(run);
      // The status was set optimistically; without a live socket nothing else settles it,
      // and the flow keeps reading `tests_running` as "gate still running".
      try {
        await n.reloadWorkspace();
      } on HaroApiException {
        n.optimisticStatus(switch (run.status) {
          TestRunStatus.passed => WorkspaceStatus.gateGreen,
          TestRunStatus.failed ||
          TestRunStatus.error => WorkspaceStatus.gateRed,
          _ => prior ?? WorkspaceStatus.idle,
        });
      }
      return run;
    } catch (_) {
      n.restoreStatus(prior);
      rethrow;
    }
  }

  /// Ticks a "code to check" row off or back on (optimistic, rolled back on failure).
  /// Omit [checked] to flip the current state.
  Future<List<String>> toggleChecked(String rowKey, {bool? checked}) async {
    final ws = _ws;
    final target = checked ?? !ws.checkedRows.contains(rowKey);
    final n = _n;
    n.patchWorkspace(
      ws.copyWith(checkedRows: _withKey(ws.checkedRows, rowKey, target)),
    );
    try {
      final keys = await _api.setRowChecked(
        workspaceId,
        rowKey,
        checked: target,
      );
      final w = _ws.copyWith(checkedRows: keys);
      n.patchWorkspace(w);
      _store.updateWorkspace(w);
      return keys;
    } catch (_) {
      n.patchWorkspace(_ws.copyWith(checkedRows: ws.checkedRows));
      rethrow;
    }
  }

  static List<String> _withKey(List<String> keys, String key, bool on) {
    final rest = [
      for (final k in keys)
        if (k != key) k,
    ];
    return on ? [...rest, key] : rest;
  }

  Future<MutationResponse> runMutation() => _analyze(
    AnalysisKind.mutation,
    () => _api.runMutation(workspaceId),
    (a, r) => a.finish(AnalysisKind.mutation, mutation: r),
  );

  Future<CoverageResponse> measureCoverage() => _analyze(
    AnalysisKind.coverage,
    () => _api.getCoverage(workspaceId),
    (a, r) => a.finish(AnalysisKind.coverage, coverage: r),
  );

  Future<FlakyResponse> checkFlaky({int runs = 5}) => _analyze(
    AnalysisKind.flaky,
    () => _api.runFlaky(workspaceId, runs: runs),
    (a, r) => a.finish(AnalysisKind.flaky, flaky: r),
  );

  Future<T> _analyze<T>(
    AnalysisKind kind,
    Future<T> Function() fetch,
    WorkspaceAnalysis Function(WorkspaceAnalysis, T) apply,
  ) async {
    final n = _n;
    n.setAnalysis(_d.analysis.begin(kind));
    try {
      final r = await fetch();
      n.setAnalysis(apply(_d.analysis, r));
      return r;
    } on HaroApiException catch (e) {
      n.setAnalysis(_d.analysis.finish(kind, error: e.message));
      rethrow;
    } catch (e) {
      n.setAnalysis(_d.analysis.finish(kind, error: '$e'));
      rethrow;
    }
  }

  /// Defers each item to `backlog/follow-ups.md`. Returns how many landed; throws only when
  /// every one failed.
  Future<int> addToBacklog(List<LookAtItem> items) async {
    if (items.isEmpty) return 0;
    final projectId = _ws.projectId;
    Object? firstError;
    var ok = 0;
    await Future.wait([
      for (final it in items)
        _api
            .addTodoItem(
              projectId,
              it.review.target,
              evidence: it.review.context ?? '',
            )
            .then<void>((_) => ok++)
            .catchError((Object e) {
              firstError ??= e;
            }),
    ]);
    if (ok == 0 && firstError != null) throw firstError!;
    return ok;
  }

  // ---- ship ----

  Future<CommitResult> commit(String message) async {
    final res = await _api.gitCommit(workspaceId, message.trim());
    _n.bumpGit();
    if (res.committed != null) _n.scheduleDiffRefresh();
    return res;
  }

  /// Commits only what is in the index: the code step's Changes panel.
  Future<CommitResult> commitStaged(String message) async {
    final res = await _api.gitCommit(
      workspaceId,
      message.trim(),
      stagedOnly: true,
    );
    _n.bumpGit();
    if (res.committed != null) _n.scheduleDiffRefresh();
    return res;
  }

  /// Idempotent: returns the existing PR when one is open.
  Future<CreatePrResult> openPr() async {
    final res = await _api.createPr(workspaceId);
    _n.bumpGit();
    return res;
  }

  /// Push, PR, merge: a multi-second round trip, so callers should guard against a
  /// double tap (duplicate PRs are what that produced in the React client).
  Future<MergeResult> merge({String? message}) async {
    final res = await _api.merge(workspaceId, message: message);
    final n = _n;
    if (res.merged) {
      n.patchWorkspace(_ws.copyWith(status: WorkspaceStatus.merged));
    }
    n.bumpGate();
    await _refresh(() async {
      await n.reloadWorkspace();
      await _store.reload();
    });
    return res;
  }

  /// A merged workspace continues on a fresh branch: same worktree and chat.
  Future<ContinueResult> continueOnNewBranch() async {
    final res = await _api.continueWorkspace(workspaceId);
    final n = _n;
    n.patchWorkspace(_ws.copyWith(status: WorkspaceStatus.idle));
    n.bumpGate();
    n.scheduleDiffRefresh();
    await _refresh(() async {
      await n.reloadWorkspace();
      await _store.reload();
    });
    return res;
  }

  /// Display name and/or git branch.
  Future<Workspace> renameWorkspace({String? name, String? branch}) async {
    final w = await _api.renameWorkspace(
      workspaceId,
      name: name,
      branch: branch,
    );
    _n.patchWorkspace(w);
    _store.updateWorkspace(w);
    if (branch != null) _n.bumpGit();
    return w;
  }

  /// Flips who writes the code. The backend checkpoint-commits a dirty tree first, so the
  /// git panel and the diff are stale afterwards.
  Future<Workspace> setMode(WorkspaceMode mode) async {
    final w = await _api.setWorkspaceMode(workspaceId, mode);
    _n.patchWorkspace(w);
    _store.updateWorkspace(w);
    _n.bumpGit();
    _n.scheduleDiffRefresh();
    return w;
  }

  Future<void> archiveWorkspace() async {
    await _api.archiveWorkspace(workspaceId);
    await _refresh(_store.reload);
  }

  /// Post the gate receipt as a PR comment. Returns the comment URL, or null when nothing
  /// was posted.
  Future<String?> postReceiptToPr() => _api.postReceiptPrComment(workspaceId);

  /// On-demand AI review of the diff. Advisory: the result never reaches the gate or the
  /// workspace state.
  Future<AiReview> runReview({String? model}) =>
      _api.runReview(workspaceId, model: model);

  // ---- dev server ----

  /// No [runId] starts the default run.
  Future<RunAppResult> startDevServer({String? runId}) async {
    final res = await _api.runApp(workspaceId, runId: runId);
    _n.applyRunResult(res, runId: runId ?? 'app');
    return res;
  }

  /// No [runId] stops every run in the workspace. The `run` channel reports the result.
  Future<void> stopDevServer({String? runId}) =>
      _api.stopApp(workspaceId, runId: runId);

  // ---- files ----

  Future<FileContent> readFile(String path) => _api.readFile(workspaceId, path);

  Future<void> saveFile(String path, String content) async {
    await _api.writeFile(workspaceId, path, content);
    _n.scheduleDiffRefresh();
  }
}
