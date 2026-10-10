import '../../../api/models/models.dart';
import '../../../lsp/lsp_diagnostics.dart';
import '../../../state/display_state.dart';
import '../../../state/live_gate.dart' show LiveWatch, tally;
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
    this.severity,
  });

  final String key;

  /// Mono uppercase kind tag (`NO TEST RAN`, `FAILED`).
  final String label;
  final String title;
  final String detail;

  /// Where a click goes; null rows (a coverage note) are not clickable.
  final String? path;
  final int? line;
  final bool blocking;

  /// Set on language-server rows, which pick their mark by severity.
  final DiagnosticSeverity? severity;
}

/// One server's diagnostics in the Problems tab (`TYPESCRIPT` for the TS server).
class DiagnosticSection {
  const DiagnosticSection(this.title, this.count, this.rows);

  final String title;

  /// Every diagnostic, even when [rows] is capped.
  final int count;
  final List<ProblemRow> rows;
}

const maxDiagnosticRows = 200;

/// The language server's diagnostics as Problems rows, one section per `source`, errors first.
/// Advisory: this never feeds the gate, the verdict or any step state.
List<DiagnosticSection> deriveDiagnosticSections(List<FileDiagnostics> files) {
  final bySource = <String, List<(String, LspDiagnostic)>>{};
  for (final f in files) {
    for (final d in f.items) {
      if (!d.shown) continue;
      final source = d.isTypeScript ? 'TYPESCRIPT' : d.source.toUpperCase();
      (bySource[source] ??= []).add((f.path, d));
    }
  }
  return [
    for (final e in bySource.entries)
      () {
        final all = e.value
          ..sort((a, b) {
            final c = compareDiagnostics(a.$2, b.$2);
            return c != 0 ? c : a.$1.compareTo(b.$1);
          });
        return DiagnosticSection(e.key, all.length, [
          for (final (i, (path, d)) in all.take(maxDiagnosticRows).indexed)
            ProblemRow(
              key: 'lsp:$path:${d.line}:${d.character}:$i',
              label: [
                switch (d.severity) {
                  DiagnosticSeverity.error => 'ERROR',
                  DiagnosticSeverity.warning => 'WARNING',
                  _ => 'INFO',
                },
                ?d.codeLabel,
              ].join(' '),
              title: '${path.split('/').last}:${d.line + 1}:${d.character + 1}',
              detail: d.headline,
              path: path,
              line: d.line + 1,
              severity: d.severity,
            ),
        ]);
      }(),
  ];
}

class ProblemsView {
  const ProblemsView({this.eyes = const []});

  static const none = ProblemsView();

  final List<ProblemRow> eyes;

  bool get isEmpty => eyes.isEmpty;
  int get count => eyes.length;
}

/// The open needs-your-eyes items. There are no lint or type errors: lint was cut from the
/// gate.
ProblemsView deriveProblems(LookAt lookAt) {
  return ProblemsView(
    eyes: [
      for (final i in lookAt.pending)
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

/// Paths of the files in a unified diff (the new side), for "is this file changed".
Set<String> changedPaths(String diff) => parseAddedLines(diff).keys.toSet();

/// Test files by name or folder, across the runners haro knows. A test file is not a source
/// file for "run the tests touching this file": it already is the test.
bool isTestPath(String path) {
  final p = path.toLowerCase();
  final name = p.split('/').last;
  return RegExp(r'\.(test|spec)\.[a-z0-9]+$').hasMatch(name) ||
      RegExp(r'^test_.*\.py$|_test\.(py|go)$').hasMatch(name) ||
      p.split('/').any((d) => d == '__tests__' || d == 'tests' || d == 'test');
}

const _relatedExtensions = {
  'ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs', 'vue', //
};

/// Whether the Gate tab offers "Run the tests touching this file": the runner answers Impact
/// (so it can name tests at all), and [path] is a script source file that is not itself a test.
bool canRunRelated(String? path, ImpactResponse? impact) {
  if (path == null || impact == null) return false;
  if (!impact.supported || impact.error != null) return false;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || !_relatedExtensions.contains(path.substring(dot + 1))) {
    return false;
  }
  return !isTestPath(path);
}

/// The advisory (Live Gate channel) run as one plain line, or null before any run. It is a
/// separate line from the verdict above it on purpose: it can never turn the gate green.
/// [staleRunId] is the settled run that was already there when the caller started its own: it
/// is not that caller's result, so it is skipped.
String? advisoryRunLine(LiveWatch watch, {String? staleRunId}) {
  final t = tally(watch.cells);
  if (t.inflight > 0) return 'Related run: ${t.done} of ${t.total} done.';
  final r = watch.run;
  if (r == null || r.id == staleRunId) return null;
  if (r.failed > 0) {
    return 'Related run: ${r.failed} failed, ${r.passed} passed.';
  }
  return 'Related run: ${r.passed} passed.';
}
