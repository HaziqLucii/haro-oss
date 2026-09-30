import '../../api/models/models.dart';
import '../../state/format.dart';

/// How a row reads (§0): a green tick = a gate check passed, hollow ink = found but not
/// applied or running, hollow dim = nothing to report, red = failed.
enum RowMark { gate, progress, idle, fail }

class RowFix {
  const RowFix({required this.label, required this.preset});

  final String label;

  /// The preset the click would write. Nothing is written until the user confirms.
  final StackPreset preset;
}

class DetectionRow {
  const DetectionRow({
    required this.id,
    required this.label,
    required this.finding,
    required this.mark,
    this.fix,
    this.details = const [],
    this.action,
  });

  final String id;
  final String label;
  final String finding;
  final RowMark mark;
  final RowFix? fix;

  /// Extra mono lines under the finding (failing test ids, an error's first line).
  final List<String> details;

  /// A button that runs something (the baseline), as opposed to [fix], which writes config.
  final String? action;
}

enum BaselineStatus { running, passed, failed, noTests, error }

/// The suite run once on main (`POST /projects/{id}/baseline`), or the live state of that
/// run. While [status] is running, the counts are the tests finished so far.
class BaselineResult {
  const BaselineResult({
    required this.status,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.total = 0,
    this.duration = Duration.zero,
    this.coveragePct,
    this.failingIds = const [],
    this.error,
    this.note,
  });

  const BaselineResult.running({
    int passed = 0,
    int failed = 0,
    int skipped = 0,
  }) : this(
         status: BaselineStatus.running,
         passed: passed,
         failed: failed,
         skipped: skipped,
         total: passed + failed + skipped,
       );

  factory BaselineResult.fromRun(BaselineRun r) => BaselineResult(
    status: switch (r.status) {
      'passed' => BaselineStatus.passed,
      'failed' => BaselineStatus.failed,
      'no_tests' => BaselineStatus.noTests,
      _ => BaselineStatus.error,
    },
    passed: r.passed,
    failed: r.failed,
    skipped: r.skipped,
    total: r.total,
    duration: Duration(milliseconds: ((r.durationS ?? 0) * 1000).round()),
    coveragePct: r.coveragePct,
    failingIds: r.failingIds,
    error: r.error,
    note: r.note,
  );

  final BaselineStatus status;
  final int passed;
  final int failed;
  final int skipped;
  final int total;
  final Duration duration;

  /// Line coverage on main; null means the runner could not measure it.
  final double? coveragePct;
  final List<String> failingIds;
  final String? error;
  final String? note;

  bool get running => status == BaselineStatus.running;

  /// Red even with no failing case: a non-zero exit from an unhandled error still means the
  /// gate would start red.
  bool get red => status == BaselineStatus.failed;

  /// The suite size, only once a run has finished and counted it.
  int? get knownTotal =>
      (status == BaselineStatus.passed || status == BaselineStatus.failed) &&
          total > 0
      ? total
      : null;
}

class RunnerInputs {
  const RunnerInputs({required this.gate, this.stack, this.scripts});

  final GateConfig gate;
  final StackDetection? stack;
  final ScriptsConfig? scripts;
}

String displayRunner(String runner) => switch (runner) {
  'vitest' => 'Vitest',
  'pytest' => 'pytest',
  _ => runner,
};

/// What the gate config says, without lying about defaults: the backend reports `vitest`
/// with an empty dir for an unconfigured project, so a runner only counts as known when a
/// dir or command is set, or detection agrees with it. Known is "the gate would run this";
/// [configured] is "someone wrote it down": detection agreeing with the default is not
/// enough for a tick.
class RunnerFacts {
  const RunnerFacts({
    required this.known,
    required this.configured,
    required this.runner,
    required this.dir,
    required this.command,
    this.proposal,
    this.offerFix = false,
  });

  final bool known;
  final bool configured;
  final String runner;

  /// Empty means the project root.
  final String dir;
  final String command;
  final StackCandidate? proposal;
  final bool offerFix;

  bool get usesCommand => runner == 'command' || runner == 'offense';
}

/// [written] is this page's own successful preset write: the gate config reads the same
/// before and after it when the preset is the default runner at the project root.
RunnerFacts runnerFacts(RunnerInputs i, {bool written = false}) {
  final g = i.gate;
  final proposal = i.stack?.proposal;
  final usesCommand = g.runner == 'command' || g.runner == 'offense';
  final known = usesCommand
      ? g.command.trim().isNotEmpty
      : g.gateDir.isNotEmpty || proposal?.preset.gate['runner'] == g.runner;
  final scriptsEmpty =
      (i.scripts?.setup ?? '').trim().isEmpty &&
      (i.scripts?.run ?? '').trim().isEmpty;
  final configured =
      known &&
      (written ||
          (usesCommand
              ? g.command.trim().isNotEmpty
              : g.gateDir.isNotEmpty || g.runner != 'vitest') ||
          !scriptsEmpty);
  return RunnerFacts(
    known: known,
    configured: configured,
    runner: g.runner,
    dir: g.gateDir,
    command: g.command.trim(),
    proposal: proposal,
    offerFix: proposal != null && !written && (!known || scriptsEmpty),
  );
}

String _dirLabel(String dir) => dir.isEmpty ? 'project root' : '$dir/';

DetectionRow runnerRow(RunnerFacts f, {BaselineResult? baseline}) {
  final fix = f.offerFix
      ? RowFix(
          label: 'Use ${f.proposal!.preset.label}',
          preset: f.proposal!.preset,
        )
      : null;
  if (!f.configured) {
    return DetectionRow(
      id: 'runner',
      label: 'Test runner',
      finding: f.proposal != null
          ? '${f.proposal!.preset.label} detected · not written yet'
          : 'Nothing detected',
      mark: f.proposal != null ? RowMark.progress : RowMark.idle,
      fix: fix,
    );
  }
  final total = baseline?.knownTotal;
  final where = f.usesCommand
      ? f.command
      : '${displayRunner(f.runner)} in ${_dirLabel(f.dir)}';
  return DetectionRow(
    id: 'runner',
    label: 'Test runner',
    finding: total == null ? where : '$where · $total tests',
    mark: RowMark.gate,
    fix: fix,
  );
}

const _maxFailingShown = 5;
const _runBaseline = 'Run baseline';
const _runAgain = 'Run again';

/// [startError] is the reason the last "Run baseline" click could not start a run.
DetectionRow baselineRow(BaselineResult? b, {String? startError}) {
  final row = _baselineRow(b, startError: startError);
  final note = b?.note;
  if (b == null || b.running || note == null || note.isEmpty) return row;
  return DetectionRow(
    id: row.id,
    label: row.label,
    finding: row.finding,
    mark: row.mark,
    action: row.action,
    details: [...row.details, note],
  );
}

DetectionRow _baselineRow(BaselineResult? b, {String? startError}) {
  const label = 'Baseline run';
  if (b == null) {
    return DetectionRow(
      id: 'baseline',
      label: label,
      finding: 'not run yet: one full run of the suite on main',
      mark: RowMark.idle,
      action: _runBaseline,
      details: [?startError],
    );
  }
  final secs = formatMs(b.duration.inMilliseconds.toDouble());
  return switch (b.status) {
    BaselineStatus.running => DetectionRow(
      id: 'baseline',
      label: label,
      finding: b.total == 0
          ? 'running the suite on main'
          : 'running the suite on main · ${b.total} '
                '${plural(b.total, 'test')} done'
                '${b.failed > 0 ? ' · ${b.failed} failing' : ''}',
      mark: RowMark.progress,
    ),
    BaselineStatus.passed => DetectionRow(
      id: 'baseline',
      label: label,
      finding:
          '${b.passed} passed on main, the gate has a green starting point · '
          '$secs',
      mark: RowMark.gate,
      action: _runAgain,
      details: [?startError],
    ),
    BaselineStatus.failed => DetectionRow(
      id: 'baseline',
      label: label,
      finding: b.failed == 0
          ? 'the suite failed on main without a failing test (unhandled error '
                'or setup problem) · $secs'
          : '${b.failed} failing on main before any agent touches it: fix '
                'these first or the gate will be red from the start · $secs',
      mark: RowMark.fail,
      action: _runAgain,
      details: [
        ...b.failingIds.take(_maxFailingShown),
        if (b.failed > _maxFailingShown) '+${b.failed - _maxFailingShown} more',
        if (b.failed == 0) ?_firstLine(b.error),
        ?startError,
      ],
    ),
    BaselineStatus.noTests => DetectionRow(
      id: 'baseline',
      label: label,
      finding: 'no tests found on main, so the gate has nothing to run',
      mark: RowMark.idle,
      action: _runAgain,
      details: [?startError],
    ),
    BaselineStatus.error => DetectionRow(
      id: 'baseline',
      label: label,
      finding: 'could not run the suite on main',
      mark: RowMark.fail,
      action: _runAgain,
      details: [?_firstLine(b.error), ?startError],
    ),
  };
}

String? _firstLine(String? text) {
  final line = (text ?? '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .firstOrNull;
  if (line == null) return null;
  return line.length > 160 ? '${line.substring(0, 160)}...' : line;
}

enum ResultKind { ready, missing, checking, baselineRed, baselineError }

class ResultLine {
  const ResultLine(this.kind, this.headline, this.detail);

  final ResultKind kind;
  final String headline;
  final String detail;
}

/// [acknowledged] is the user's "Continue anyway" on a red baseline. Green ("ready") only
/// when the baseline passed (or the user accepted a red one); an errored, running or
/// never-run baseline never reads as ready. Null when there is nothing honest to say yet.
ResultLine? resultLine(
  RunnerFacts f, {
  BaselineResult? baseline,
  bool acknowledged = false,
}) {
  if (!f.configured) {
    return ResultLine(
      ResultKind.missing,
      'Gate not ready.',
      f.proposal != null
          ? 'Confirm the detected test runner above so green means something.'
          : 'No test runner found. Set one in gate settings so green means '
                'something.',
    );
  }
  final b = baseline;
  if (b == null) return null;
  switch (b.status) {
    case BaselineStatus.running:
      return const ResultLine(ResultKind.checking, 'Checking main...', '');
    case BaselineStatus.noTests:
      return const ResultLine(
        ResultKind.missing,
        'Gate not ready.',
        'The suite has no tests on main. Point the gate at the right folder or '
            'add one.',
      );
    case BaselineStatus.error:
      return ResultLine(
        ResultKind.baselineError,
        'The gate could not run on main.',
        _firstLine(b.error) ?? '',
      );
    case BaselineStatus.failed when !acknowledged:
      return ResultLine(
        ResultKind.baselineRed,
        b.failed == 0
            ? 'main is already red (the suite failed).'
            : 'main is already red (${b.failed} failing).',
        '',
      );
    case BaselineStatus.failed:
      return ResultLine(
        ResultKind.ready,
        'Gate ready.',
        b.failed == 0
            ? 'The gate compares against the suite already failing on main.'
            : 'The gate compares against the ${b.failed} '
                  '${plural(b.failed, 'test')} already failing on main.',
      );
    case BaselineStatus.passed:
      break;
  }
  final known = b.knownTotal;
  final n = known != null ? '$known ' : '';
  final detail = f.usesCommand
      ? 'Green means ${f.command} passes.'
      : 'Green means all $n${displayRunner(f.runner)} tests in '
            '${f.dir.isEmpty ? 'the project root' : '${f.dir}/'} pass.';
  return ResultLine(ResultKind.ready, 'Gate ready.', detail);
}

String tildify(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  return path.startsWith('$home/') ? '~${path.substring(home.length)}' : path;
}
