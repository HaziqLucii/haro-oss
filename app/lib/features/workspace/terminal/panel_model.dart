import '../../../api/models/models.dart';
import '../../../state/display_state.dart';
import '../../../state/look_at.dart';
import '../steps/verify/verify_model.dart';

// Pure derivations for the bottom panel's Gate and Problems tabs. The wording decides what
// the panel may claim, so it lives here, testable without a widget.

/// The Gate tab's "This file:" line for the focused editor file. It claims a line ran only
/// when the gate is green: the per-line map is the last green run's, and a red or running
/// gate has nothing to certify.
String fileProofLine({
  required String? path,
  required DisplayState state,
  required VerifiedHunksResponse? proof,
  required Set<String> changed,
}) {
  if (path == null) return 'no file open';
  VerifiedFile? file;
  for (final f in proof?.files ?? const <VerifiedFile>[]) {
    if (f.path == path) file = f;
  }
  if (!changed.contains(path) && file == null) return 'unchanged';

  switch (state) {
    case DisplayState.gate:
      return 'the gate is running';
    case DisplayState.red:
      return 'the gate is red, no proof for this file yet';
    case DisplayState.green || DisplayState.merged:
      break;
    case DisplayState.idle || DisplayState.plan || DisplayState.agent:
      return 'the gate has not run on this tree';
  }

  if (proof == null || !proof.supported || file == null) return 'not measured';
  if (file.stale) return 'the gate ran on an older version of this file';
  if (!file.inMap) {
    return file.added > 0
        ? 'no test imports this file, ${_lines(file.added)} never ran'
        : 'no test imports this file';
  }
  if (file.unexecuted > 0) return '${_lines(file.unexecuted)} never ran';
  if (file.executed > 0) return 'every added line ran in the green suite';
  return 'not executable, no proof needed';
}

String _lines(int n) => '$n added ${n == 1 ? 'line' : 'lines'}';

/// The impact half of the Gate tab's last line. The Impact Map knows which tests the whole
/// change touches, not which tests touch one source file, so a source file gets the change's
/// count and a test file its own.
String? impactLine(String? path, ImpactResponse? impact) {
  if (path == null || impact == null) return null;
  if (!impact.supported || impact.error != null) return null;
  if (impact.impactedFiles.contains(path)) {
    final n = impact.impactedTests.where((t) => t.file == path).length;
    return 'Tests in this file: $n.';
  }
  final touched = impact.changedFiles.any((f) => f.path == path);
  return touched
      ? 'Tests touching this change: ${impact.impactedTests.length}.'
      : null;
}

String runOnSaveLine(bool enabled) => enabled
    ? 'The gate re-runs on save.'
    : 'Run on save is off (Settings, Gate).';

class ProblemRow {
  const ProblemRow({
    required this.key,
    required this.label,
    required this.title,
    this.detail = '',
    this.path,
    this.line,
    this.blocking = false,
    this.mutant = false,
  });

  final String key;

  /// Mono uppercase kind tag (`MUTANT SURVIVED`, `NO TEST RAN`, `FAILED`).
  final String label;
  final String title;
  final String detail;

  /// Where a click goes; null rows (a coverage note) are not clickable.
  final String? path;
  final int? line;
  final bool blocking;
  final bool mutant;
}

class ProblemsView {
  const ProblemsView({this.mutants = const [], this.eyes = const []});

  static const none = ProblemsView();

  final List<ProblemRow> mutants;
  final List<ProblemRow> eyes;

  bool get isEmpty => mutants.isEmpty && eyes.isEmpty;
  int get count => mutants.length + eyes.length;
}

/// Surviving mutants (the mutation run's or the receipt's) and the open needs-your-eyes
/// items. There are no lint or type errors: lint was cut from the gate.
ProblemsView deriveProblems(LookAt lookAt, List<MutationSurvivor> survivors) {
  return ProblemsView(
    mutants: [
      for (final s in survivors)
        ProblemRow(
          key: 'mutation:${s.path}:${s.line}',
          label: 'MUTANT SURVIVED',
          title: '${s.path.split('/').last}:${s.line}',
          detail: s.operator,
          path: s.path,
          line: s.line,
          mutant: true,
        ),
    ],
    eyes: [
      for (final i in lookAt.pending)
        if (i.kind != LookAtKind.mutation)
          ProblemRow(
            key: i.key,
            label: i.label,
            title: i.title,
            detail: i.detail,
            path: i.file,
            line: i.line,
            blocking: i.blocking,
          ),
    ],
  );
}

/// Plain words for an empty Problems tab. Nothing is claimed clean that nothing measured.
List<String> problemsEmptyLines(
  DisplayState state, {
  required bool mutationRan,
}) => [
  emptyLookAtText(state),
  if (!mutationRan)
    'Surviving mutants appear here after a mutation run (Verify, Evidence).',
];

/// Paths of the files in a unified diff (the new side), for "is this file changed".
Set<String> changedPaths(String diff) => parseAddedLines(diff).keys.toSet();
