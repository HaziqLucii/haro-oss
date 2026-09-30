import 'json_util.dart';

/// `Project.baseline` / `GET /projects/{id}/baseline`: the gate run once on the default
/// branch before any agent touched it (First run). Evidence only, never a merge verdict.
class BaselineRun {
  const BaselineRun({
    required this.status,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.total = 0,
    this.durationS,
    this.coveragePct,
    this.failingIds = const [],
    this.sha,
    this.runner,
    this.error,
    this.note,
  });

  /// `passed` | `failed` | `error` | `no_tests`.
  final String status;
  final int passed;
  final int failed;
  final int skipped;
  final int total;
  final double? durationS;

  /// Line coverage; `null` when the runner cannot measure it.
  final double? coveragePct;
  final List<String> failingIds;
  final String? sha;
  final String? runner;
  final String? error;

  /// A caveat about what the run covered (for example: the setup script was not run).
  final String? note;

  factory BaselineRun.fromJson(Json j) => BaselineRun(
    status: jStr(j, 'status', 'error'),
    passed: jInt(j, 'passed'),
    failed: jInt(j, 'failed'),
    skipped: jInt(j, 'skipped'),
    total: jInt(j, 'total'),
    durationS: jDoubleN(j, 'duration_s'),
    coveragePct: jDoubleN(j, 'coverage_pct'),
    failingIds: jStrList(j, 'failing_ids'),
    sha: jStrN(j, 'sha'),
    runner: jStrN(j, 'runner'),
    error: jStrN(j, 'error'),
    note: jStrN(j, 'note'),
  );
}

class BaselineState {
  const BaselineState({this.running = false, this.result});

  final bool running;
  final BaselineRun? result;

  factory BaselineState.fromJson(Json j) => BaselineState(
    running: jBool(j, 'running'),
    result: j['result'] is Map
        ? BaselineRun.fromJson(asJson(j['result']))
        : null,
  );
}
