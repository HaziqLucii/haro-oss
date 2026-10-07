import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_store.dart';
import '../../../../data/xp_store.dart';
import '../../../../state/manual_rail.dart';

/// The `assist` channel of one workspace. A provider so tests can feed events without a socket.
/// Auto-disposed so every read follows the current workspace notifier: one rebuilt after the
/// workspace was left for a while has a new stream, and the old one is closed.
final assistEventsProvider = Provider.autoDispose
    .family<Stream<AssistEvent>, String>(
      (ref, id) => ref.read(workspaceDetailProvider(id).notifier).assistEvents,
    );

/// Fires when the workspace socket reconnects (the `assist` channel is not replayed).
final assistResyncProvider = Provider.autoDispose.family<Stream<void>, String>(
  (ref, id) => ref.read(workspaceDetailProvider(id).notifier).assistResync,
);

final manualRailProvider =
    NotifierProvider.family<ManualRailController, ManualState, String>(
      ManualRailController.new,
    );

const _unset = Object();

class ManualState {
  const ManualState({
    this.tab = ManualTab.plan,
    this.plans = const [],
    this.activePlanId,
    this.planRunning = false,
    this.planQueued = false,
    this.runText = '',
    this.planError,
    this.model,
    this.effort,
    this.searching = false,
    this.searched = false,
    this.rows = const [],
    this.answer,
    this.note,
    this.searchError,
    this.searchGuardNote,
    this.searchBlocked = const [],
    this.recent = const [],
    this.pinned = const [],
    this.pinnedLoaded = false,
    this.manPages = const [],
    this.selectedDoc,
    this.docError,
  });

  final ManualTab tab;
  final List<ManualPlan> plans;
  final String? activePlanId;
  final bool planRunning;
  final bool planQueued;
  final String runText;
  final String? planError;

  /// Per-run picks for the assistant; null means the project default.
  final String? model;
  final String? effort;

  final bool searching;
  final bool searched;
  final List<ResearchRow> rows;
  final String? answer;
  final String? note;
  final String? searchError;

  /// The shown `ask` answer's run could not be checked by the backend's file guard.
  final String? searchGuardNote;
  final List<String> searchBlocked;

  /// Past `ask` answers of this workspace, newest first, at most [maxRecentAsks].
  final List<RecentAsk> recent;

  final List<PinnedDoc> pinned;
  final bool pinnedLoaded;
  final List<ManPage> manPages;
  final DocRef? selectedDoc;
  final String? docError;

  ManualPlan? get activePlan {
    for (final p in plans) {
      if (p.id == activePlanId) return p;
    }
    return null;
  }

  PlanPhase get phase => planPhase(running: planRunning, active: activePlan);

  /// Whether the footer's "AI edits: 0" would be a claim nobody checked: the plan on screen,
  /// or the answer on screen, came from a run the backend's file guard could not check.
  bool get unverified =>
      (activePlan?.guardNote != null) ||
      (searchGuardNote != null && searchGuardNote!.isNotEmpty);

  ManualState copyWith({
    ManualTab? tab,
    List<ManualPlan>? plans,
    Object? activePlanId = _unset,
    bool? planRunning,
    bool? planQueued,
    String? runText,
    Object? planError = _unset,
    Object? model = _unset,
    Object? effort = _unset,
    bool? searching,
    bool? searched,
    List<ResearchRow>? rows,
    Object? answer = _unset,
    Object? note = _unset,
    Object? searchError = _unset,
    Object? searchGuardNote = _unset,
    List<String>? searchBlocked,
    List<RecentAsk>? recent,
    List<PinnedDoc>? pinned,
    bool? pinnedLoaded,
    List<ManPage>? manPages,
    Object? selectedDoc = _unset,
    Object? docError = _unset,
  }) => ManualState(
    tab: tab ?? this.tab,
    plans: plans ?? this.plans,
    activePlanId: identical(activePlanId, _unset)
        ? this.activePlanId
        : activePlanId as String?,
    planRunning: planRunning ?? this.planRunning,
    planQueued: planQueued ?? this.planQueued,
    runText: runText ?? this.runText,
    planError: identical(planError, _unset)
        ? this.planError
        : planError as String?,
    model: identical(model, _unset) ? this.model : model as String?,
    effort: identical(effort, _unset) ? this.effort : effort as String?,
    searching: searching ?? this.searching,
    searched: searched ?? this.searched,
    rows: rows ?? this.rows,
    answer: identical(answer, _unset) ? this.answer : answer as String?,
    note: identical(note, _unset) ? this.note : note as String?,
    searchError: identical(searchError, _unset)
        ? this.searchError
        : searchError as String?,
    searchGuardNote: identical(searchGuardNote, _unset)
        ? this.searchGuardNote
        : searchGuardNote as String?,
    searchBlocked: searchBlocked ?? this.searchBlocked,
    recent: recent ?? this.recent,
    pinned: pinned ?? this.pinned,
    pinnedLoaded: pinnedLoaded ?? this.pinnedLoaded,
    manPages: manPages ?? this.manPages,
    selectedDoc: identical(selectedDoc, _unset)
        ? this.selectedDoc
        : selectedDoc as DocRef?,
    docError: identical(docError, _unset) ? this.docError : docError as String?,
  );
}

/// State and actions of the manual rail for one workspace. Plans are seeded from the
/// workspace once (no request on mount); everything after that goes through the API and the
/// `assist` channel.
class ManualRailController extends Notifier<ManualState> {
  ManualRailController(this.id);

  final String id;

  HaroApi get _api => ref.read(haroApiProvider);

  // The workspace notifier the subscriptions hang off. `.stream` returns a fresh wrapper on
  // every read, so the notifier instance is the stable key.
  Object? _boundTo;
  StreamSubscription<AssistEvent>? _eventSub;
  StreamSubscription<void>? _resyncSub;

  // The job `runText` belongs to: text from another job is never mixed into it.
  String? _runJobId;

  // The question of the `ask` in flight, so its `done` (which carries no query) can be listed.
  String? _askQuery;

  // Bumped by every start and every settled job; a `GET /assist` that began before a bump
  // describes a world that has moved on and is dropped.
  int _epoch = 0;
  int _starting = 0;
  final _settledJobs = <String>{};

  @override
  ManualState build() {
    _bind();
    ref.onDispose(() {
      unawaited(_eventSub?.cancel());
      unawaited(_resyncSub?.cancel());
    });
    final ws = ref.read(workspaceDetailProvider(id)).workspace;
    final plans = ws?.plans ?? const <ManualPlan>[];
    return ManualState(
      plans: plans,
      activePlanId: plans.isEmpty ? null : plans.last.id,
      recent: ws?.recentAsks ?? const [],
    );
  }

  /// (Re)attaches to the workspace's live streams. The notifier behind them is replaced when
  /// the workspace was left long enough to be disposed, so this runs on every mount.
  void _bind() {
    final detail = ref.read(workspaceDetailProvider(id).notifier);
    if (identical(detail, _boundTo)) return;
    _boundTo = detail;
    unawaited(_eventSub?.cancel());
    unawaited(_resyncSub?.cancel());
    _eventSub = ref.read(assistEventsProvider(id)).listen(_onEvent);
    _resyncSub = ref
        .read(assistResyncProvider(id))
        .listen((_) => unawaited(resync()));
  }

  String? get _projectId =>
      ref.read(workspaceDetailProvider(id)).workspace?.projectId;

  String _msg(Object e) => e is HaroApiException ? e.message : '$e';

  void setTab(ManualTab tab) {
    state = state.copyWith(tab: tab);
    if (tab == ManualTab.docs && !state.pinnedLoaded) unawaited(loadPinned());
  }

  void setModel(String? m) => state = state.copyWith(model: m);
  void setEffort(String? e) => state = state.copyWith(effort: e);

  // ---- plan ----

  Future<void> startPlan(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty || state.planRunning) return;
    _beginStart();
    _runJobId = null;
    state = state.copyWith(
      planRunning: true,
      planQueued: false,
      runText: '',
      planError: null,
    );
    try {
      await _api.assistPlan(id, text, model: state.model, effort: state.effort);
    } on HaroApiException catch (e) {
      state = state.copyWith(planRunning: false, planError: e.message);
    } catch (e) {
      state = state.copyWith(planRunning: false, planError: _msg(e));
    } finally {
      _endStart();
    }
  }

  void _beginStart() {
    _epoch++;
    _starting++;
  }

  void _endStart() {
    _epoch++;
    if (_starting > 0) _starting--;
  }

  Future<void> stop() async {
    try {
      await _api.stopAssist(id);
    } catch (e) {
      if (state.planRunning) state = state.copyWith(planError: _msg(e));
    }
  }

  void newPlan() => state = state.copyWith(activePlanId: null, planError: null);

  void showPlan(String planId) =>
      state = state.copyWith(activePlanId: planId, tab: ManualTab.plan);

  ManualPlan? _plan(String planId) {
    for (final p in state.plans) {
      if (p.id == planId) return p;
    }
    return null;
  }

  void _put(ManualPlan plan) => state = state.copyWith(
    plans: [for (final p in state.plans) p.id == plan.id ? plan : p],
  );

  // Per plan: the newest tick request, the steps the server last confirmed, and the chain
  // that sends ticks in order. Each request carries the whole list, so a failed early tick
  // must not be rolled back over a later one the server already saved.
  final _tickSerial = <String, int>{};
  final _confirmed = <String, List<PlanStep>>{};
  final _tickChain = <String, Future<void>>{};

  /// Ticks a step. Optimistic and sent in order. If the newest save fails, the list goes back
  /// to what the server holds; a failure that a newer tick has already superseded only reports.
  Future<void> toggleStep(String planId, int index) {
    final before = _plan(planId);
    if (before == null || index < 0 || index >= before.steps.length) {
      return Future.value();
    }
    _confirmed.putIfAbsent(planId, () => before.steps);
    final steps = [
      for (final (i, s) in before.steps.indexed)
        i == index ? s.copyWith(done: !s.done) : s,
    ];
    _put(before.copyWith(steps: steps));
    final serial = _tickSerial[planId] = (_tickSerial[planId] ?? 0) + 1;

    Future<void> send() async {
      try {
        final saved = await _api.patchPlan(id, planId, steps: steps);
        _confirmed[planId] = saved.steps;
        if (_tickSerial[planId] == serial && ref.mounted) _put(saved);
      } catch (e) {
        if (!ref.mounted) return;
        if (_tickSerial[planId] == serial) {
          final now = _plan(planId);
          final server = _confirmed[planId];
          if (now != null && server != null) {
            _put(now.copyWith(steps: server));
          }
        }
        state = state.copyWith(planError: _msg(e));
      }
    }

    final run = (_tickChain[planId] ?? Future<void>.value()).then(
      (_) => send(),
    );
    _tickChain[planId] = run;
    return run;
  }

  /// Saves an edited title and step list (Edit on the review screen).
  Future<bool> saveEdits(
    String planId, {
    required String title,
    required List<PlanStep> steps,
  }) async {
    try {
      final updated = await _api.patchPlan(
        id,
        planId,
        title: title,
        steps: steps,
      );
      _confirmed[planId] = updated.steps;
      _put(updated);
      state = state.copyWith(planError: null);
      return true;
    } catch (e) {
      state = state.copyWith(planError: _msg(e));
      return false;
    }
  }

  /// "Finish plan, save to Docs".
  Future<void> finishPlan(String planId) async {
    try {
      final saved = await _api.patchPlan(id, planId, saved: true);
      _confirmed[planId] = saved.steps;
      _put(saved);
      state = state.copyWith(planError: null);
    } catch (e) {
      state = state.copyWith(planError: _msg(e));
    }
  }

  Future<void> deletePlan(String planId) async {
    try {
      await _api.deletePlan(id, planId);
    } catch (e) {
      state = state.copyWith(planError: _msg(e));
      return;
    }
    final left = [
      for (final p in state.plans)
        if (p.id != planId) p,
    ];
    state = state.copyWith(
      plans: left,
      activePlanId: state.activePlanId == planId ? null : state.activePlanId,
      selectedDoc: state.selectedDoc == DocRef(DocKind.plan, planId)
          ? null
          : state.selectedDoc,
    );
  }

  // ---- search ----

  Future<void> ask(String query) async {
    final q = query.trim();
    if (q.isEmpty || state.searching) return;
    _beginStart();
    _askQuery = q;
    state = state.copyWith(
      searching: true,
      searched: true,
      rows: const [],
      answer: null,
      note: null,
      searchError: null,
      searchGuardNote: null,
      searchBlocked: const [],
    );
    try {
      final res = await _api.assistResearch(
        id,
        q,
        model: state.model,
        effort: state.effort,
      );
      if (res.jobId != null) return;
      state = state.copyWith(
        searching: false,
        rows: res.rows,
        answer: res.answer,
        note: res.note,
      );
    } catch (e) {
      state = state.copyWith(searching: false, searchError: _msg(e));
    } finally {
      _endStart();
    }
  }

  /// Reopens a past answer exactly as a fresh one renders (sources, guard note, blocked
  /// calls, and the footer that follows the guard note).
  void openRecent(RecentAsk ask) {
    if (state.searching) return;
    state = state.copyWith(
      searched: true,
      rows: ask.rows,
      answer: ask.answer,
      note: ask.note,
      searchError: null,
      searchGuardNote: ask.guardNote,
      searchBlocked: ask.blockedCalls,
    );
  }

  void _pushRecent(RecentAsk ask) {
    final top = state.recent.isEmpty ? null : state.recent.first;
    if (top != null && top.query == ask.query && top.answer == ask.answer) {
      return;
    }
    state = state.copyWith(
      recent: [ask, ...state.recent].take(maxRecentAsks).toList(),
    );
  }

  // ---- docs ----

  Future<void> loadPinned() async {
    final pid = _projectId;
    if (pid == null) return;
    try {
      final docs = await _api.getPinnedDocs(pid);
      state = state.copyWith(pinned: docs, pinnedLoaded: true, docError: null);
    } catch (e) {
      state = state.copyWith(pinnedLoaded: true, docError: _msg(e));
    }
  }

  Future<bool> pin(String url, {String title = ''}) async {
    final pid = _projectId;
    final u = url.trim();
    if (pid == null || !isPinnableUrl(u)) {
      state = state.copyWith(
        docError: 'Only http and https links can be pinned',
      );
      return false;
    }
    try {
      final docs = await _api.setPinnedDocs(pid, [
        ...state.pinned,
        PinnedDoc(title: title, url: u),
      ]);
      state = state.copyWith(pinned: docs, docError: null);
      return true;
    } catch (e) {
      state = state.copyWith(docError: _msg(e));
      return false;
    }
  }

  Future<void> unpin(String url) async {
    final pid = _projectId;
    if (pid == null) return;
    try {
      final docs = await _api.setPinnedDocs(pid, [
        for (final d in state.pinned)
          if (d.url != url) d,
      ]);
      state = state.copyWith(
        pinned: docs,
        docError: null,
        selectedDoc: state.selectedDoc == DocRef(DocKind.pinned, url)
            ? null
            : state.selectedDoc,
      );
    } catch (e) {
      state = state.copyWith(docError: _msg(e));
    }
  }

  /// A Docs read is opening a plan, a pinned doc or a man page in the reader.
  void _docsRead() => ref.read(xpReporterProvider).docsRead(id);

  void selectDoc(DocRef? ref) {
    state = state.copyWith(selectedDoc: ref);
    if (ref != null) _docsRead();
  }

  void selectDocAndShow(DocRef ref) {
    state = state.copyWith(selectedDoc: ref);
    setTab(ManualTab.docs);
    _docsRead();
  }

  Future<void> openMan(String page) async {
    state = state.copyWith(tab: ManualTab.docs, docError: null);
    if (!state.pinnedLoaded) unawaited(loadPinned());
    if (state.manPages.any((m) => m.page == page)) {
      state = state.copyWith(selectedDoc: DocRef(DocKind.man, page));
      _docsRead();
      return;
    }
    try {
      final m = await _api.getManPage(page);
      state = state.copyWith(
        manPages: [...state.manPages, m],
        selectedDoc: DocRef(DocKind.man, page),
      );
      _docsRead();
    } catch (e) {
      state = state.copyWith(docError: _msg(e));
    }
  }

  // ---- reattach ----

  /// Reads `GET /assist` and makes the rail agree with it: a job still running shows as
  /// running (with its text so far and Stop), a finished one the client never saw surfaces its
  /// result, and a "running" the server no longer has is cleared. Runs on mount and on every
  /// socket reconnect. A failed read changes nothing.
  Future<void> resync() async {
    _bind();
    final epoch = _epoch;
    AssistJob? job;
    Workspace? ws;
    try {
      // Plans live on the workspace and the rail seeds them once, so a plan saved while this
      // client was away (or the backend restarted, leaving no job) is read here too.
      final results = await Future.wait<Object?>([
        _api.getAssistJob(id),
        _api
            .getWorkspace(id)
            .then<Workspace?>((w) => w)
            .catchError((_) => null),
      ]);
      job = results[0] as AssistJob?;
      ws = results[1] as Workspace?;
    } catch (_) {
      return;
    }
    if (!ref.mounted) return;
    if (ws != null) _mergePlans(ws, recentFresh: epoch == _epoch);
    if (epoch != _epoch || _starting > 0) return;

    final localRunning = state.planRunning || state.searching;
    if (job != null && job.active) return _adoptRunning(job);

    if (job != null && !_settledJobs.contains(job.id)) {
      switch ((job.kind, job.status)) {
        case ('plan', 'done'):
          _settledJobs.add(job.id);
          _surfacePlan(job);
        case ('research', 'done') when !state.searched || state.searching:
          _settledJobs.add(job.id);
          _surfaceAnswer(job);
        case (_, 'error') when localRunning:
          _settledJobs.add(job.id);
          if (job.kind == 'plan') {
            state = state.copyWith(planError: job.error);
          } else {
            state = state.copyWith(searchError: job.error);
          }
      }
    }
    if (state.planRunning || state.searching) {
      _runJobId = null;
      state = state.copyWith(
        planRunning: false,
        planQueued: false,
        runText: '',
        searching: false,
      );
    }
  }

  /// Adds plans the server has and the rail does not. Plans the rail already holds keep their
  /// local copy (a tick may be in flight).
  ///
  /// The fetch began at `epoch`; when a job settled since ([recentFresh] false) the server's
  /// Recent list may predate that answer, so it is left alone. Otherwise it is merged, never
  /// swapped in: an answer the rail already listed survives a list that lacks it.
  void _mergePlans(Workspace ws, {required bool recentFresh}) {
    ref.read(workspaceStoreProvider.notifier).updateWorkspace(ws);
    if (recentFresh && ws.recentAsks.isNotEmpty) {
      state = state.copyWith(recent: _mergeRecent(state.recent, ws.recentAsks));
    }
    final have = {for (final p in state.plans) p.id};
    final fresh = [
      for (final p in ws.plans)
        if (!have.contains(p.id)) p,
    ];
    if (fresh.isEmpty) return;
    state = state.copyWith(
      plans: [...state.plans, ...fresh],
      activePlanId: state.activePlanId ?? fresh.last.id,
    );
  }

  List<RecentAsk> _mergeRecent(List<RecentAsk> local, List<RecentAsk> server) {
    final merged = [...server];
    for (final l in local) {
      final known = merged.any(
        (m) => m.query == l.query && m.answer == l.answer,
      );
      if (!known) merged.add(l);
    }
    final order = {for (final (i, m) in merged.indexed) m: i};
    merged.sort((a, b) {
      final byTime = (b.at ?? 0).compareTo(a.at ?? 0);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    return merged.take(maxRecentAsks).toList();
  }

  void _adoptRunning(AssistJob job) {
    // Longest wins only within one job (a live token may beat the fetch); another job's
    // leftover text is dropped for the server's.
    final sameJob = job.id == _runJobId;
    final text = sameJob && state.runText.length > job.text.length
        ? state.runText
        : job.text;
    _runJobId = job.id;
    if (job.kind == 'plan') {
      state = state.copyWith(
        planRunning: true,
        planQueued: job.status == 'queued',
        runText: text,
        planError: null,
        searching: false,
      );
    } else {
      if (job.query.isNotEmpty) _askQuery = job.query;
      state = state.copyWith(
        searching: true,
        searched: true,
        searchError: null,
        planRunning: false,
        planQueued: false,
      );
    }
  }

  /// A plan that finished while this client was away is already merged in by [resync]:
  /// make it the plan on screen once, and end the wait for it.
  void _surfacePlan(AssistJob job) {
    final planId = job.planId;
    if (planId == null || !state.plans.any((p) => p.id == planId)) {
      _settledJobs.remove(job.id);
      return;
    }
    _runJobId = null;
    state = state.copyWith(
      activePlanId: planId,
      planRunning: false,
      planQueued: false,
      runText: '',
    );
  }

  void _surfaceAnswer(AssistJob job) {
    state = state.copyWith(
      searching: false,
      searched: true,
      rows: job.rows,
      answer: job.answer,
      note: job.note,
      searchError: null,
      searchGuardNote: job.guardNote,
      searchBlocked: job.blockedCalls,
    );
    if (job.query.isNotEmpty) {
      _pushRecent(
        RecentAsk(
          query: job.query,
          answer: job.answer ?? '',
          at: _nowEpoch(),
          rows: job.rows,
          note: job.note,
          guardNote: job.guardNote,
          blockedCalls: job.blockedCalls,
        ),
      );
    }
  }

  double _nowEpoch() => DateTime.now().millisecondsSinceEpoch / 1000;

  // ---- assist channel ----

  void _onEvent(AssistEvent e) {
    if (e.kind == 'done' || e.kind == 'error' || e.kind == 'stopped') {
      _epoch++;
      final jobId = e.jobId;
      if (jobId != null) _settledJobs.add(jobId);
    }
    if (e.job == 'plan') {
      switch (e.kind) {
        case 'queued':
          state = state.copyWith(planQueued: true);
        case 'started':
          state = state.copyWith(planQueued: false);
        case 'token':
          final jobId = e.jobId;
          final other =
              jobId != null && _runJobId != null && jobId != _runJobId;
          if (jobId != null) _runJobId = jobId;
          state = state.copyWith(
            runText: (other ? '' : state.runText) + e.text,
          );
        case 'done':
          _runJobId = null;
          final plan = e.plan;
          if (plan == null) {
            state = state.copyWith(planRunning: false, runText: '');
            return;
          }
          // The event carries the plan as first written; one the rail already holds has
          // newer ticks (a replayed `done` must not roll them back), so it only adds.
          state = state.copyWith(
            plans: _plan(plan.id) != null ? null : [...state.plans, plan],
            activePlanId: plan.id,
            planRunning: false,
            planQueued: false,
            runText: '',
          );
        case 'error':
          state = state.copyWith(
            planRunning: false,
            planQueued: false,
            runText: '',
            planError: e.message,
          );
          _runJobId = null;
        case 'stopped':
          _runJobId = null;
          state = state.copyWith(
            planRunning: false,
            planQueued: false,
            runText: '',
          );
      }
      return;
    }
    if (e.job == 'research' && state.searching) {
      switch (e.kind) {
        case 'done':
          state = state.copyWith(
            searching: false,
            rows: e.rows,
            answer: e.answer,
            note: e.note,
            searchGuardNote: e.guardNote,
            searchBlocked: e.blockedCalls,
          );
          final q = _askQuery;
          if (q != null) {
            _pushRecent(
              RecentAsk(
                query: q,
                answer: e.answer ?? '',
                at: _nowEpoch(),
                rows: e.rows,
                note: e.note,
                guardNote: e.guardNote,
                blockedCalls: e.blockedCalls,
              ),
            );
          }
        case 'error':
          state = state.copyWith(searching: false, searchError: e.message);
        case 'stopped':
          state = state.copyWith(searching: false);
      }
    }
  }
}
