import 'assist.dart';
import 'json_util.dart';
import 'test_first.dart';
import 'workspace.dart';

/// One test's status, both as a streamed grid cell and as a stored case result.
enum CellStatus {
  running('running'),
  passed('passed'),
  failed('failed'),
  skipped('skipped'),
  unknown('');

  const CellStatus(this.wire);
  final String wire;

  static CellStatus parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

/// A live grid cell: one test as it streams.
class Cell {
  const Cell({
    required this.id,
    required this.file,
    required this.name,
    required this.status,
    this.durationMs,
    this.message,
  });

  final String id;
  final String file;
  final String name;
  final CellStatus status;
  final double? durationMs;
  final String? message;

  factory Cell.fromJson(Json j) => Cell(
    id: jStr(j, 'id'),
    file: jStr(j, 'file'),
    name: jStr(j, 'name'),
    status: CellStatus.parse(j['status']),
    durationMs: jDoubleN(j, 'duration_ms'),
    message: jStrN(j, 'message'),
  );
}

class TestCaseResult {
  const TestCaseResult({
    required this.file,
    required this.name,
    required this.status,
    this.durationMs,
    this.message,
  });

  final String file;
  final String name;
  final CellStatus status;
  final double? durationMs;
  final String? message;

  factory TestCaseResult.fromJson(Json j) => TestCaseResult(
    file: jStr(j, 'file'),
    name: jStr(j, 'name'),
    status: CellStatus.parse(j['status']),
    durationMs: jDoubleN(j, 'duration_ms'),
    message: jStrN(j, 'message'),
  );

  /// Cases carry no id, so one is synthesized from file + name + index (stable per run).
  Cell toCell(int index) => Cell(
    id: '$file::$name::$index',
    file: file,
    name: name,
    status: status,
    durationMs: durationMs,
    message: message,
  );
}

/// One suspicious change to the test suite that turns a green gate into `green*`.
/// `kind`: removed | skip | xfail | only | todo | weakened | assertions | timeout | snapshot |
/// config | acceptance_changed | acceptance_missing. (`vacuous` is not a tamper kind: a new test
/// that already passes at base is an advisory `vacuous_test` code-to-check row.)
class TamperFinding {
  const TamperFinding({
    required this.kind,
    this.file = '',
    this.detail = '',
    this.test,
  });

  final String kind;
  final String file;
  final String detail;
  final String? test;

  factory TamperFinding.fromJson(Json j) => TamperFinding(
    kind: jStr(j, 'kind'),
    file: jStr(j, 'file'),
    detail: jStr(j, 'detail'),
    test: jStrN(j, 'test'),
  );
}

/// One "code to check" row. Says what was NOT observed; never that anything is proven.
/// `kind`: no_test_file | untested_lines | new_dep | secret | secret_found | deleted |
/// migration | suite_weakened | assertion_rewritten.
class UncheckedRow {
  const UncheckedRow({
    required this.kind,
    this.file = '',
    this.detail = '',
    this.count = 0,
    required this.key,
    this.line,
    this.rule,
  });

  final String kind;
  final String file;
  final String detail;
  final int count;

  /// `secret_found` rows only: 1-indexed line and the gitleaks rule id.
  final int? line;
  final String? rule;

  /// Stable across re-gates; the handle a tick-off is stored against.
  final String key;

  factory UncheckedRow.fromJson(Json j) => UncheckedRow(
    kind: jStr(j, 'kind'),
    file: jStr(j, 'file'),
    detail: jStr(j, 'detail'),
    count: jInt(j, 'count'),
    key: jStr(j, 'key'),
    line: jIntN(j, 'line'),
    rule: jStrN(j, 'rule'),
  );
}

/// A gate run. Double Gate `quality_*`, `plan_compliance` and code review `review` fields are
/// intentionally not parsed (dropped in the redesign).
class TestRun {
  const TestRun({
    required this.id,
    required this.workspaceId,
    this.runner = '',
    this.scope = TestScope.all,
    this.trigger,
    required this.status,
    this.total = 0,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.durationMs,
    this.wallMs,
    this.cases = const [],
    this.error,
    this.errorKind,
    this.flakyTests = const [],
    this.coverageDelta,
    this.coverageNote,
    this.coverageBlocked = false,
    this.tamperFindings = const [],
    this.tamperNote,
    this.tamperBlocked = false,
    this.acceptance,
    this.acceptanceBlocked = false,
    this.testsProtected = false,
    this.uncheckedItems,
    this.uncheckedNote,
    this.uncheckedCoveredFiles,
    this.degradedReasons = const [],
    this.mergeConflict = false,
    this.mergeNote,
    this.startedAt = 0,
    this.endedAt,
  });

  final String id;
  final String workspaceId;
  final String runner;
  final TestScope scope;

  /// `auto` | `manual` | `autofix` | `watch`. A `watch` run is advisory and never a verdict.
  final String? trigger;
  final TestRunStatus status;
  final int total;
  final int passed;
  final int failed;
  final int skipped;
  final double? durationMs;
  final double? wallMs;
  final List<TestCaseResult> cases;
  final String? error;
  final GateErrorKind? errorKind;
  final List<String> flakyTests;

  final double? coverageDelta;
  final String? coverageNote;
  final bool coverageBlocked;
  final List<TamperFinding> tamperFindings;
  final String? tamperNote;
  final bool tamperBlocked;

  /// Test-first contract result; null unless the workspace has an approved acceptance test.
  final AcceptanceCheck? acceptance;

  /// The approved acceptance test changed, went missing or fails: blocks whatever the tamper mode.
  final bool acceptanceBlocked;

  /// Existing tests were edit-protected for the agent on this run (a deny-rule speed bump).
  final bool testsProtected;

  /// Tri-state: `null` = the pass never ran (red gate, impacted-only run, crashed engine),
  /// empty = it ran and found nothing. Never normalize `null` to empty.
  final List<UncheckedRow>? uncheckedItems;
  final String? uncheckedNote;

  /// `null` = no per-line map existed; 0 = a map existed but held nothing from this diff.
  final int? uncheckedCoveredFiles;
  final List<String> degradedReasons;
  final bool mergeConflict;
  final String? mergeNote;
  final double startedAt;
  final double? endedAt;

  bool get degraded => degradedReasons.isNotEmpty;
  bool get running => status == TestRunStatus.running;

  factory TestRun.fromJson(Json j) => TestRun(
    id: jStr(j, 'id'),
    workspaceId: jStr(j, 'workspace_id'),
    runner: jStr(j, 'runner'),
    scope: TestScope.parse(j['scope']),
    trigger: jStrN(j, 'trigger'),
    status: TestRunStatus.parse(j['status']),
    total: jInt(j, 'total'),
    passed: jInt(j, 'passed'),
    failed: jInt(j, 'failed'),
    skipped: jInt(j, 'skipped'),
    durationMs: jDoubleN(j, 'duration_ms'),
    wallMs: jDoubleN(j, 'wall_ms'),
    cases: jList(j, 'cases', TestCaseResult.fromJson),
    error: jStrN(j, 'error'),
    errorKind: GateErrorKind.parse(j['error_kind']),
    flakyTests: jStrList(j, 'flaky_tests'),
    coverageDelta: jDoubleN(j, 'coverage_delta'),
    coverageNote: jStrN(j, 'coverage_note'),
    coverageBlocked: jBool(j, 'coverage_blocked'),
    tamperFindings: jList(j, 'tamper_findings', TamperFinding.fromJson),
    tamperNote: jStrN(j, 'tamper_note'),
    tamperBlocked: jBool(j, 'tamper_blocked'),
    acceptance: j['acceptance'] is Map
        ? AcceptanceCheck.fromJson(asJson(j['acceptance']))
        : null,
    acceptanceBlocked: jBool(j, 'acceptance_blocked'),
    testsProtected: jBool(j, 'tests_protected'),
    uncheckedItems: jListN(j, 'unchecked_items', UncheckedRow.fromJson),
    uncheckedNote: jStrN(j, 'unchecked_note'),
    uncheckedCoveredFiles: jIntN(j, 'unchecked_covered_files'),
    degradedReasons: jStrList(j, 'degraded_reasons'),
    mergeConflict: jBool(j, 'merge_conflict'),
    mergeNote: jStrN(j, 'merge_note'),
    startedAt: jDouble(j, 'started_at'),
    endedAt: jDoubleN(j, 'ended_at'),
  );
}

/// GET /workspaces/{id}/watch: the Live Gate's last advisory run. Never a ship verdict.
class WatchState {
  const WatchState({required this.enabled, this.run});

  final bool enabled;
  final TestRun? run;

  factory WatchState.fromJson(Json j) => WatchState(
    enabled: jBool(j, 'enabled'),
    run: j['run'] is Map ? TestRun.fromJson(asJson(j['run'])) : null,
  );
}

class ChangedFile {
  const ChangedFile({required this.path, this.added, this.removed});

  final String path;
  final int? added;
  final int? removed;

  factory ChangedFile.fromJson(Json j) => ChangedFile(
    path: jStr(j, 'path'),
    added: jIntN(j, 'added'),
    removed: jIntN(j, 'removed'),
  );
}

class ImpactTest {
  const ImpactTest({required this.file, required this.name});

  final String file;
  final String name;

  factory ImpactTest.fromJson(Json j) =>
      ImpactTest(file: jStr(j, 'file'), name: jStr(j, 'name'));
}

class ImpactResponse {
  const ImpactResponse({
    required this.baseRef,
    required this.supported,
    this.error,
    this.changedFiles = const [],
    this.totalTests = 0,
    this.totalTestFiles = 0,
    this.impactedTests = const [],
    this.impactedFiles = const [],
  });

  final String baseRef;
  final bool supported;
  final String? error;
  final List<ChangedFile> changedFiles;
  final int totalTests;
  final int totalTestFiles;
  final List<ImpactTest> impactedTests;
  final List<String> impactedFiles;

  factory ImpactResponse.fromJson(Json j) => ImpactResponse(
    baseRef: jStr(j, 'base_ref'),
    supported: jBool(j, 'supported'),
    error: jStrN(j, 'error'),
    changedFiles: jList(j, 'changed_files', ChangedFile.fromJson),
    totalTests: jInt(j, 'total_tests'),
    totalTestFiles: jInt(j, 'total_test_files'),
    impactedTests: jList(j, 'impacted_tests', ImpactTest.fromJson),
    impactedFiles: jStrList(j, 'impacted_files'),
  );
}

class BlameHunk {
  const BlameHunk({required this.file, this.line, this.code});

  final String file;

  /// `null` = file-level fallback (no single changed line matched).
  final int? line;
  final String? code;

  factory BlameHunk.fromJson(Json j) => BlameHunk(
    file: jStr(j, 'file'),
    line: jIntN(j, 'line'),
    code: jStrN(j, 'code'),
  );
}

class BlameEntry {
  const BlameEntry({
    required this.file,
    required this.name,
    this.hunks = const [],
  });

  final String file;
  final String name;
  final List<BlameHunk> hunks;

  factory BlameEntry.fromJson(Json j) => BlameEntry(
    file: jStr(j, 'file'),
    name: jStr(j, 'name'),
    hunks: jList(j, 'hunks', BlameHunk.fromJson),
  );
}

class BlameResponse {
  const BlameResponse({
    required this.baseRef,
    required this.supported,
    this.error,
    this.entries = const [],
  });

  final String baseRef;
  final bool supported;
  final String? error;
  final List<BlameEntry> entries;

  factory BlameResponse.fromJson(Json j) => BlameResponse(
    baseRef: jStr(j, 'base_ref'),
    supported: jBool(j, 'supported'),
    error: jStrN(j, 'error'),
    entries: jList(j, 'entries', BlameEntry.fromJson),
  );
}

/// What the last green gate can say about one file's added lines.
/// "Executed" never means verified or correct: it ran under a passing suite, nothing more.
class VerifiedFile {
  const VerifiedFile({
    required this.path,
    this.inMap = false,
    this.stale = false,
    this.added = 0,
    this.executed = 0,
    this.unexecuted = 0,
    this.noncoverable = 0,
    this.lines = const {},
  });

  final String path;
  final bool inMap;
  final bool stale;
  final int added;
  final int executed;
  final int unexecuted;
  final int noncoverable;

  /// Line number to hit count. A `null` value means the line is NOT COVERABLE (blank,
  /// comment, closing brace), which is not the same as untested. Empty = no per-line claim.
  final Map<int, int?> lines;

  factory VerifiedFile.fromJson(Json j) {
    final raw = asJson(j['lines']);
    final lines = <int, int?>{};
    raw.forEach((k, v) {
      final n = int.tryParse(k);
      if (n == null) return;
      lines[n] = v is num ? v.toInt() : null;
    });
    return VerifiedFile(
      path: jStr(j, 'path'),
      inMap: jBool(j, 'in_map'),
      stale: jBool(j, 'stale'),
      added: jInt(j, 'added'),
      executed: jInt(j, 'executed'),
      unexecuted: jInt(j, 'unexecuted'),
      noncoverable: jInt(j, 'noncoverable'),
      lines: lines,
    );
  }
}

class VerifiedHunksResponse {
  const VerifiedHunksResponse({
    required this.baseRef,
    this.gateSha,
    this.supported = false,
    this.stale = false,
    this.files = const [],
    this.note,
  });

  final String baseRef;
  final String? gateSha;
  final bool supported;
  final bool stale;
  final List<VerifiedFile> files;
  final String? note;

  factory VerifiedHunksResponse.fromJson(Json j) => VerifiedHunksResponse(
    baseRef: jStr(j, 'base_ref'),
    gateSha: jStrN(j, 'gate_sha'),
    supported: jBool(j, 'supported'),
    stale: jBool(j, 'stale'),
    files: jList(j, 'files', VerifiedFile.fromJson),
    note: jStrN(j, 'note'),
  );
}

// Gate Receipt. The `quality` and `review` sections are not parsed (Double Gate is dropped).

/// Whether a gate with this runner reports test counts. A shell command or a linter reports pass
/// or fail only, so zero counts there is normal; under vitest or pytest it means nothing ran.
bool runnerReportsCounts(String runner) =>
    runner != 'command' && runner != 'offense';

class ReceiptSuite {
  const ReceiptSuite({
    this.runner = '',
    this.scope = '',
    this.total = 0,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.impactedCount,
  });

  final String runner;
  final String scope;
  final int total;
  final int passed;
  final int failed;
  final int skipped;
  final int? impactedCount;

  factory ReceiptSuite.fromJson(Json j) => ReceiptSuite(
    runner: jStr(j, 'runner'),
    scope: jStr(j, 'scope'),
    total: jInt(j, 'total'),
    passed: jInt(j, 'passed'),
    failed: jInt(j, 'failed'),
    skipped: jInt(j, 'skipped'),
    impactedCount: jIntN(j, 'impacted_count'),
  );
}

class ReceiptTamper {
  const ReceiptTamper({
    this.measured = false,
    this.clean = true,
    this.findingsCount = 0,
    this.note,
    this.protected = false,
  });

  final bool measured;
  final bool clean;
  final int findingsCount;
  final String? note;
  final bool protected;

  factory ReceiptTamper.fromJson(Json j) => ReceiptTamper(
    measured: jBool(j, 'measured'),
    clean: jBool(j, 'clean', true),
    findingsCount: jInt(j, 'findings_count'),
    note: jStrN(j, 'note'),
    protected: jBool(j, 'protected'),
  );
}

/// The scope fence on the receipt. Empty [patterns] means no run was fenced.
class ReceiptScope {
  const ReceiptScope({
    this.patterns = const [],
    this.fencedRuns = 0,
    this.editingRuns = 0,
    this.reverted = const [],
    this.uncheckedRuns = 0,
    this.blocked = const [],
  });

  final List<String> patterns;
  final int fencedRuns;
  final int editingRuns;
  final List<String> reverted;
  final int uncheckedRuns;

  /// Paths a fenced run tried to edit and was refused before the write.
  final List<String> blocked;

  factory ReceiptScope.fromJson(Json j) => ReceiptScope(
    patterns: jStrList(j, 'patterns'),
    fencedRuns: jInt(j, 'fenced_runs'),
    editingRuns: jInt(j, 'editing_runs'),
    reverted: jStrList(j, 'reverted'),
    uncheckedRuns: jInt(j, 'unchecked_runs'),
    blocked: jStrList(j, 'blocked'),
  );
}

class ReceiptVerifiedHunks {
  const ReceiptVerifiedHunks({
    this.supported = false,
    this.percentage,
    this.untestedFiles = const [],
    this.note,
  });

  final bool supported;
  final double? percentage;
  final List<String> untestedFiles;
  final String? note;

  factory ReceiptVerifiedHunks.fromJson(Json j) => ReceiptVerifiedHunks(
    supported: jBool(j, 'supported'),
    percentage: jDoubleN(j, 'percentage'),
    untestedFiles: jStrList(j, 'untested_files'),
    note: jStrN(j, 'note'),
  );
}

class ReceiptAgent {
  const ReceiptAgent({this.model, this.effort, this.costUsd});

  final String? model;
  final String? effort;
  final double? costUsd;

  factory ReceiptAgent.fromJson(Json j) => ReceiptAgent(
    model: jStrN(j, 'model'),
    effort: jStrN(j, 'effort'),
    costUsd: jDoubleN(j, 'cost_usd'),
  );
}

/// A Viewed file open for less than this many seconds is counted as a quick view (the backend
/// uses the same cut, `QUICK_VIEW_SECONDS`).
const quickViewSeconds = 5;

/// What haro saw of the developer's reading of the diff: how many of the changed files were
/// marked Viewed, how long each stayed open, and the reason they typed at ship time. Facts about
/// the screen, never a verdict on the review.
class ReceiptReading {
  const ReceiptReading({
    this.recorded = false,
    this.files = 0,
    this.viewed = 0,
    this.medianSeconds,
    this.quickViews = 0,
    this.reason = '',
  });

  final bool recorded;
  final int files;
  final int viewed;
  final double? medianSeconds;

  /// Files marked Viewed in under [quickViewSeconds] seconds.
  final int quickViews;
  final String reason;

  factory ReceiptReading.fromJson(Json j) => ReceiptReading(
    recorded: jBool(j, 'recorded'),
    files: jInt(j, 'files'),
    viewed: jInt(j, 'viewed'),
    medianSeconds: jDoubleN(j, 'median_seconds'),
    quickViews: jInt(j, 'quick_views'),
    reason: jStr(j, 'reason'),
  );
}

/// Names a manifest has now and did not at the base ref. No registry is asked.
class ReceiptNewDependency {
  const ReceiptNewDependency({required this.path, this.names = const []});

  final String path;
  final List<String> names;

  factory ReceiptNewDependency.fromJson(Json j) =>
      ReceiptNewDependency(path: jStr(j, 'path'), names: jStrList(j, 'names'));
}

class Receipt {
  const Receipt({
    required this.workspaceId,
    this.branch = '',
    this.baseRef = '',
    this.verdict = 'none',
    this.gateSha,
    this.writtenBy = '',
    this.degradedReasons = const [],
    this.suite = const ReceiptSuite(),
    this.tamper = const ReceiptTamper(),
    this.scope = const ReceiptScope(),
    this.reading = const ReceiptReading(),
    this.guardRefused = const [],
    this.newDependencies = const [],
    this.verifiedHunks = const ReceiptVerifiedHunks(),
    this.agent = const ReceiptAgent(),
    this.plan,
    this.researchLookups,
    this.researchUnverified = false,
    this.xp,
    this.generatedAt,
  });

  final String workspaceId;
  final String branch;
  final String baseRef;

  /// `green` | `red` | `degraded` | `none`. Kept as a string: it is display data here.
  final String verdict;
  final String? gateSha;

  /// Plain-words authorship from the backend (a GitHub login or `you`, `agent · sonnet`, or
  /// `you and the agent (manual -> agent at 10:32)`). Empty from a backend that predates it.
  final String writtenBy;
  final List<String> degradedReasons;
  final ReceiptSuite suite;
  final ReceiptTamper tamper;
  final ReceiptScope scope;
  final ReceiptReading reading;

  /// What the command guard refused before it ran (a text match, not a complete list).
  final List<String> guardRefused;
  final List<ReceiptNewDependency> newDependencies;
  final ReceiptVerifiedHunks verifiedHunks;
  final ReceiptAgent agent;

  /// Saved manual-rail plans; null when none were saved.
  final ReceiptPlan? plan;

  /// Manual-rail research lookups; null when none were made.
  final int? researchLookups;

  /// An `ask` lookup ran while the backend could not check the worktree.
  final bool researchUnverified;

  /// `XP: +N (labels)` for this workspace's merge awards (a preview before the merge).
  final String? xp;
  final double? generatedAt;

  factory Receipt.fromJson(Json j) => Receipt(
    workspaceId: jStr(j, 'workspace_id'),
    branch: jStr(j, 'branch'),
    baseRef: jStr(j, 'base_ref'),
    verdict: jStr(j, 'verdict', 'none'),
    gateSha: jStrN(j, 'gate_sha'),
    writtenBy: jStr(j, 'written_by'),
    degradedReasons: jStrList(j, 'degraded_reasons'),
    suite: ReceiptSuite.fromJson(asJson(j['suite'])),
    tamper: ReceiptTamper.fromJson(asJson(j['tamper'])),
    scope: ReceiptScope.fromJson(asJson(j['scope'])),
    reading: ReceiptReading.fromJson(asJson(j['reading'])),
    guardRefused: jStrList(asJson(j['guard']), 'refused'),
    newDependencies: jList(
      j,
      'new_dependencies',
      ReceiptNewDependency.fromJson,
    ),
    verifiedHunks: ReceiptVerifiedHunks.fromJson(asJson(j['verified_hunks'])),
    agent: ReceiptAgent.fromJson(asJson(j['agent'])),
    plan: j['plan'] is Map ? ReceiptPlan.fromJson(asJson(j['plan'])) : null,
    researchLookups: j['research'] is Map
        ? jInt(asJson(j['research']), 'lookups')
        : null,
    researchUnverified: j['research'] is Map
        ? jBool(asJson(j['research']), 'unverified')
        : false,
    xp: jStrN(j, 'xp'),
    generatedAt: jDoubleN(j, 'generated_at'),
  );
}

class ReceiptResponse {
  const ReceiptResponse({required this.receipt, this.markdown = ''});

  final Receipt receipt;

  /// The shareable markdown rendering, ready for "Copy markdown" / "Post to PR".
  final String markdown;

  factory ReceiptResponse.fromJson(Json j) => ReceiptResponse(
    receipt: Receipt.fromJson(asJson(j['receipt'])),
    markdown: jStr(j, 'markdown'),
  );
}

class TrustCondition {
  const TrustCondition({
    required this.key,
    this.met = false,
    this.detail = '',
    this.required = true,
    this.fix,
  });

  final String key;
  final bool met;
  final String detail;
  final bool required;

  /// `gate_settings` | `run_full` | `ribbon` | `tamper`, or `null`.
  final String? fix;

  factory TrustCondition.fromJson(Json j) => TrustCondition(
    key: jStr(j, 'key'),
    met: jBool(j, 'met'),
    detail: jStr(j, 'detail'),
    required: jBool(j, 'required', true),
    fix: jStrN(j, 'fix'),
  );
}

/// Autonomy-ladder report. A superset of [TrustSummary] (which it also parses into).
class TrustReport {
  const TrustReport({
    this.enabled = false,
    this.conditions = const [],
    this.streak = 0,
    this.streakRequired = 3,
    this.autoAction = 'off',
    this.met = false,
    this.armed = false,
  });

  final bool enabled;
  final List<TrustCondition> conditions;
  final int streak;
  final int streakRequired;
  final String autoAction;
  final bool met;
  final bool armed;

  factory TrustReport.fromJson(Json j) => TrustReport(
    enabled: jBool(j, 'enabled'),
    conditions: jList(j, 'conditions', TrustCondition.fromJson),
    streak: jInt(j, 'streak'),
    streakRequired: jInt(j, 'streak_required', 3),
    autoAction: jStr(j, 'auto_action', 'off'),
    met: jBool(j, 'met'),
    armed: jBool(j, 'armed'),
  );

  TrustSummary get summary => TrustSummary(
    enabled: enabled,
    streak: streak,
    streakRequired: streakRequired,
    autoAction: autoAction,
    met: met,
    armed: armed,
  );
}

/// Answer of `POST /workspaces/{id}/runs/{run}/restore-start`.
class RestoreResult {
  const RestoreResult({
    this.restored = const [],
    this.failed = const [],
    this.savedRef,
    this.nothingToRestore = false,
  });

  final List<String> restored;
  final List<String> failed;

  /// Where the worktree was kept just before the restore.
  final String? savedRef;
  final bool nothingToRestore;

  factory RestoreResult.fromJson(Json j) => RestoreResult(
    restored: jStrList(j, 'restored'),
    failed: jStrList(j, 'failed'),
    savedRef: jStrN(j, 'saved_ref'),
    nothingToRestore: jBool(j, 'nothing_to_restore'),
  );
}
