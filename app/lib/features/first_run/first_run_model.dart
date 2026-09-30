import '../../api/models/models.dart';
import '../../state/format.dart';

/// How a row's square reads (§0): filled = settled, hollow ink = found but not applied or
/// running, hollow dim = nothing to report. Green is only for gate findings.
enum RowMark { gate, settled, progress, idle, fail }

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
/// dir or command is set, or detection agrees with it.
class RunnerFacts {
  const RunnerFacts({
    required this.known,
    required this.runner,
    required this.dir,
    required this.command,
    this.proposal,
    this.offerFix = false,
  });

  final bool known;
  final String runner;

  /// Empty means the project root.
  final String dir;
  final String command;
  final StackCandidate? proposal;
  final bool offerFix;

  bool get usesCommand => runner == 'command' || runner == 'offense';
}

RunnerFacts runnerFacts(RunnerInputs i) {
  final g = i.gate;
  final proposal = i.stack?.proposal;
  final usesCommand = g.runner == 'command' || g.runner == 'offense';
  final known = usesCommand
      ? g.command.trim().isNotEmpty
      : g.gateDir.isNotEmpty || proposal?.preset.gate['runner'] == g.runner;
  final scriptsEmpty =
      (i.scripts?.setup ?? '').trim().isEmpty &&
      (i.scripts?.run ?? '').trim().isEmpty;
  return RunnerFacts(
    known: known,
    runner: g.runner,
    dir: g.gateDir,
    command: g.command.trim(),
    proposal: proposal,
    offerFix: proposal != null && (!known || scriptsEmpty),
  );
}

String _dirLabel(String dir) => dir.isEmpty ? 'project root' : '$dir/';

DetectionRow gitRow(Project p) => DetectionRow(
  id: 'git',
  label: 'Git repository',
  finding:
      '${p.defaultBranch} · '
      '${(p.remoteUrl ?? '').isEmpty ? 'no remote linked' : 'origin linked'}',
  mark: RowMark.settled,
);

DetectionRow runnerRow(RunnerFacts f, {BaselineResult? baseline}) {
  final fix = f.offerFix
      ? RowFix(
          label: 'Use ${f.proposal!.preset.label}',
          preset: f.proposal!.preset,
        )
      : null;
  if (!f.known) {
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

/// Port only when a run is live and the backend reports its URL; the configured port range
/// is not part of the scripts payload.
DetectionRow devServerRow(ScriptsConfig s) {
  final run = (s.run ?? '').trim();
  if (run.isEmpty) {
    return const DetectionRow(
      id: 'dev',
      label: 'Dev server',
      finding: 'none configured',
      mark: RowMark.idle,
    );
  }
  final url = s.runs.where((r) => r.isDefault).firstOrNull?.url;
  final port = url == null ? null : Uri.tryParse(url)?.port;
  return DetectionRow(
    id: 'dev',
    label: 'Dev server',
    finding: port == null || port == 0 ? run : '$run · port $port',
    mark: RowMark.settled,
  );
}

/// Line coverage of main, measured with the baseline run (vitest only today). Anything
/// else, including before the baseline has run, reads "not measured".
DetectionRow coverageRow(BaselineResult? b) {
  final pct = b?.coveragePct;
  return DetectionRow(
    id: 'coverage',
    label: 'Coverage',
    finding: pct == null ? 'not measured' : '${_pct(pct)}% of lines on main',
    mark: pct == null ? RowMark.idle : RowMark.settled,
  );
}

String _pct(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

final _envLine = RegExp(r'^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=');

/// Variable count of the Environment seed. Values are never kept.
int envVariableCount(String content) =>
    content.split('\n').where(_envLine.hasMatch).length;

DetectionRow secretsRow(int variables) => DetectionRow(
  id: 'secrets',
  label: 'Secrets',
  finding: variables == 0
      ? 'Environment seed is empty'
      : '$variables ${plural(variables, 'variable')} in the Environment seed',
  mark: variables == 0 ? RowMark.idle : RowMark.settled,
);

enum ResultKind { ready, missing, baselineRed }

class ResultLine {
  const ResultLine(this.kind, this.headline, this.detail);

  final ResultKind kind;
  final String headline;
  final String detail;
}

/// [acknowledged] is the user's "Continue anyway" on a red baseline.
ResultLine resultLine(
  RunnerFacts f, {
  BaselineResult? baseline,
  bool acknowledged = false,
}) {
  if (!f.known) {
    return const ResultLine(
      ResultKind.missing,
      'Gate not ready.',
      'No test runner found. Set one in gate settings so green means something.',
    );
  }
  if (baseline?.status == BaselineStatus.noTests) {
    return const ResultLine(
      ResultKind.missing,
      'Gate not ready.',
      'The suite has no tests on main. Point the gate at the right folder or '
          'add one.',
    );
  }
  if (baseline != null && baseline.red && !acknowledged) {
    return ResultLine(
      ResultKind.baselineRed,
      baseline.failed == 0
          ? 'main is already red (the suite failed).'
          : 'main is already red (${baseline.failed} failing).',
      '',
    );
  }
  if (baseline != null && baseline.red) {
    return ResultLine(
      ResultKind.ready,
      'Gate ready.',
      baseline.failed == 0
          ? 'The gate compares against the suite already failing on main.'
          : 'The gate compares against the ${baseline.failed} '
                '${plural(baseline.failed, 'test')} already failing on main.',
    );
  }
  final known = baseline?.knownTotal;
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
