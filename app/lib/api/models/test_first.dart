import 'json_util.dart';

/// Backend `TestFirstPhase`. `unknown` keeps a future phase from crashing the client.
enum TestFirstPhase {
  drafting('drafting'),
  proving('proving'),
  review('review'),
  rejected('rejected'),
  approved('approved'),
  unknown('');

  const TestFirstPhase(this.wire);
  final String wire;

  static TestFirstPhase parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

class AcceptanceFile {
  const AcceptanceFile({
    required this.path,
    required this.file,
    this.sha256 = '',
  });

  /// Repo-relative path.
  final String path;

  /// As the test runner reports it (relative to the gate directory).
  final String file;
  final String sha256;

  factory AcceptanceFile.fromJson(Json j) => AcceptanceFile(
    path: jStr(j, 'path'),
    file: jStr(j, 'file'),
    sha256: jStr(j, 'sha256'),
  );
}

/// One acceptance case and how it failed on base.
class AcceptanceCase {
  const AcceptanceCase({required this.file, required this.name, this.message});

  final String file;
  final String name;
  final String? message;

  factory AcceptanceCase.fromJson(Json j) => AcceptanceCase(
    file: jStr(j, 'file'),
    name: jStr(j, 'name'),
    message: jStrN(j, 'message'),
  );
}

/// `Workspace.test_first`: the test-first task's lifecycle. Also rides the `status` channel.
class TestFirstState {
  const TestFirstState({
    required this.phase,
    this.task = '',
    this.rejectReason,
    this.files = const [],
    this.cases = const [],
    this.provedAt,
    this.approvedAt,
    this.rounds = 1,
  });

  final TestFirstPhase phase;
  final String task;
  final String? rejectReason;
  final List<AcceptanceFile> files;
  final List<AcceptanceCase> cases;

  /// Epoch seconds.
  final double? provedAt;
  final double? approvedAt;
  final int rounds;

  factory TestFirstState.fromJson(Json j) => TestFirstState(
    phase: TestFirstPhase.parse(j['phase']),
    task: jStr(j, 'task'),
    rejectReason: jStrN(j, 'reject_reason'),
    files: jList(j, 'files', AcceptanceFile.fromJson),
    cases: jList(j, 'cases', AcceptanceCase.fromJson),
    provedAt: jDoubleN(j, 'proved_at'),
    approvedAt: jDoubleN(j, 'approved_at'),
    rounds: jInt(j, 'rounds', 1),
  );
}

/// `TestRun.acceptance`: what one gate run found about the approved acceptance test.
class AcceptanceCheck {
  const AcceptanceCheck({
    this.approvedAt,
    this.total = 0,
    this.passing = 0,
    this.changed = const [],
    this.missing = const [],
    this.failing = const [],
    this.ok = false,
  });

  final double? approvedAt;
  final int total;
  final int passing;
  final List<String> changed;
  final List<String> missing;
  final List<String> failing;
  final bool ok;

  factory AcceptanceCheck.fromJson(Json j) => AcceptanceCheck(
    approvedAt: jDoubleN(j, 'approved_at'),
    total: jInt(j, 'total'),
    passing: jInt(j, 'passing'),
    changed: jStrList(j, 'changed'),
    missing: jStrList(j, 'missing'),
    failing: jStrList(j, 'failing'),
    ok: jBool(j, 'ok'),
  );
}
