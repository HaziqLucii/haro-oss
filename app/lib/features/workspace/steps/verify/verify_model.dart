import 'dart:math' as math;

import '../../../../api/models/models.dart';
import '../../../../data/workspace_detail_models.dart';
import '../../../../state/display_state.dart';
import '../../../../state/format.dart';
import '../../../../state/gate_facts.dart';
import '../../../../state/look_at.dart';
import '../../../../state/verdict.dart';

// Pure derivations for the verify step (spec 5.6). Nothing here touches a widget, so the
// wording that decides what the page may claim is testable on its own.

enum MetricTone { ink, dim, gate, fail }

class Metric {
  const Metric(this.label, this.value, [this.tone = MetricTone.ink]);

  final String label;
  final String value;
  final MetricTone tone;
}

String percent(double v) => '${v.toStringAsFixed(1)}%';

String scopeLabel(TestScope s) => switch (s) {
  TestScope.all => 'all tests',
  TestScope.impacted => 'impacted tests',
  TestScope.failed => 'failed tests',
};

/// `4m ago`, `just now`.
String agoLabel(double epochSeconds, DateTime now) {
  final ago = relativeAgo(epochSeconds, now);
  return ago == 'now' ? 'just now' : '$ago ago';
}

/// `vitest · frontend/ · all tests · 4m ago · 2.0s`. A running gate has no scope or age of
/// its own yet (the run in hand is the previous one), so it says `running` instead.
String verdictMeta({
  required DisplayState state,
  required TestRun? run,
  required GateSummary? summary,
  required GateConfig? config,
  required DateTime now,
}) {
  final parts = <String>[];
  final runner = run?.runner.isNotEmpty == true
      ? run!.runner
      : (config?.runner ?? '');
  if (runner.isNotEmpty) parts.add(runner);
  var dir = config?.gateDir ?? '';
  if (dir.isNotEmpty) {
    if (!dir.endsWith('/')) dir = '$dir/';
    parts.add(dir);
  }
  if (state == DisplayState.gate) {
    parts.add('running');
    return parts.join(' · ');
  }
  final scope =
      run?.scope ??
      summary?.scope ??
      TestScope.parse(config?.defaultScope ?? 'all');
  parts.add(scopeLabel(scope));
  final ended = run?.endedAt ?? summary?.endedAt;
  if (ended == null) {
    parts.add('never run');
  } else {
    parts.add(agoLabel(ended, now));
    final ms = run?.wallMs ?? run?.durationMs;
    if (ms != null) parts.add(formatMs(ms));
  }
  return parts.join(' · ');
}

/// The mutation score as the page may show it: a fresh answer, or the one the backend
/// cached for this gate (from the receipt) so a restart does not read "not measured".
class MutationView {
  const MutationView({
    required this.supported,
    this.score,
    this.killed,
    this.survived,
    this.skipped = 0,
    this.budgetCapped = false,
    this.survivors = const [],
    this.note,
  });

  final bool supported;
  final double? score;

  /// Null when the view comes from the receipt, which carries only the score.
  final int? killed;
  final int? survived;
  final int skipped;
  final bool budgetCapped;
  final List<MutationSurvivor> survivors;
  final String? note;

  int? get total =>
      killed == null || survived == null ? null : killed! + survived!;
}

MutationView? mutationView(MutationResponse? live, ReceiptMutation? cached) {
  if (live != null) {
    return MutationView(
      supported: live.supported,
      score: live.score,
      killed: live.killed,
      survived: live.survived,
      skipped: live.skipped,
      budgetCapped: live.budgetCapped,
      survivors: live.survivors,
      note: live.note,
    );
  }
  if (cached != null && cached.supported && cached.ran && !cached.stale) {
    return MutationView(
      supported: true,
      score: cached.score,
      survivors: cached.survivors,
      note: cached.note,
    );
  }
  return null;
}

String? mutationValue(MutationView? m) {
  if (m == null || !m.supported || m.score == null) return null;
  return '${m.score!.round()}%';
}

String mutationMeta(MutationView? m, {required bool running}) {
  if (running) return 'running…';
  if (m == null) return 'not measured';
  if (!m.supported) return 'unavailable';
  if (m.score == null) return 'no runnable mutants';
  final total = m.total;
  if (total != null) {
    return '${m.score!.round()}% · ${m.killed} of $total mistakes caught';
  }
  return '${m.score!.round()}%';
}

String _delta(double d, {bool words = false}) {
  final a = d.abs().toStringAsFixed(1);
  if (words) {
    if (d.abs() < .05) return 'same as main';
    return d > 0 ? 'up $a from main' : 'down $a from main';
  }
  if (d.abs() < .05) return '±0';
  return d > 0 ? '↑$a' : '↓$a';
}

String? coverageValue(CoverageResponse? c, TestRun? run) {
  final lines = c?.current?.lines;
  if (c != null && c.supported && lines != null) {
    final d = c.delta?.lines;
    return d == null ? percent(lines) : '${percent(lines)} ${_delta(d)}';
  }
  final rd = run?.coverageDelta;
  return rd == null ? null : '${_delta(rd)} vs main';
}

String coverageMeta(CoverageResponse? c, {required bool running}) {
  if (running) return 'measuring…';
  if (c == null) return 'not measured';
  final lines = c.current?.lines;
  if (!c.supported || lines == null) return 'unavailable';
  final d = c.delta?.lines;
  return d == null
      ? percent(lines)
      : '${percent(lines)} · ${_delta(d, words: true)}';
}

/// The flaky answer, from the on-demand check or (when the project enabled the re-run) the
/// gate run itself. Null when nothing measured it.
({int count, int runs})? flakyFacts(
  FlakyResponse? f,
  TestRun? run,
  bool flakyRerun,
) {
  if (f != null) return (count: f.flaky.length, runs: f.runs);
  if (flakyRerun && run != null && !run.running) {
    return (count: run.flakyTests.length, runs: 1);
  }
  return null;
}

String flakyMeta(
  FlakyResponse? f,
  TestRun? run,
  bool flakyRerun, {
  required bool running,
}) {
  if (running) return 're-running…';
  final facts = flakyFacts(f, run, flakyRerun);
  if (facts == null) return 'not measured';
  if (f == null) {
    return facts.count == 0
        ? 'none flagged on the last run'
        : '${facts.count} flagged on the last run';
  }
  return facts.count == 0
      ? 'none in the last ${facts.runs} runs'
      : '${facts.count} flaky in ${facts.runs} runs';
}

/// Zone 1's metrics row. A number that was never measured says so, dimly; nothing here is
/// ever a placeholder standing in for a value.
List<Metric> deriveMetrics({
  required DisplayState state,
  required GateFacts facts,
  required TestRun? run,
  required ({int done, int total}) progress,
  required WorkspaceAnalysis analysis,
  required MutationView? mutation,
  required bool flakyRerun,
}) {
  const dash = '–';
  final running = state == DisplayState.gate;
  final settled = state.settled && facts.measured && !facts.errored;

  if (!running && !settled) {
    return const [
      Metric('Tests', dash, MetricTone.dim),
      Metric('Duration', dash, MetricTone.dim),
      Metric('Coverage', dash, MetricTone.dim),
      Metric('Mutation', dash, MetricTone.dim),
      Metric('Flaky', dash, MetricTone.dim),
    ];
  }

  Metric after(String label) => Metric(label, 'after run', MetricTone.dim);
  if (running) {
    return [
      Metric('Tests', '${progress.done} / ${progress.total}'),
      const Metric('Duration', dash, MetricTone.dim),
      after('Coverage'),
      after('Mutation'),
      after('Flaky'),
    ];
  }

  final tests = Metric(
    'Tests',
    '${facts.passed} / ${facts.total}',
    facts.failed > 0 ? MetricTone.fail : MetricTone.gate,
  );
  final ms = run?.wallMs ?? run?.durationMs;
  final duration = ms == null
      ? const Metric('Duration', dash, MetricTone.dim)
      : Metric('Duration', formatMs(ms));

  Metric measured(String label, String? value) => value == null
      ? Metric(label, 'not measured', MetricTone.dim)
      : Metric(label, value);

  final flaky = flakyFacts(analysis.flaky, run, flakyRerun);
  return [
    tests,
    duration,
    analysis.isRunning(AnalysisKind.coverage)
        ? Metric('Coverage', 'measuring…', MetricTone.dim)
        : measured('Coverage', coverageValue(analysis.coverage, run)),
    analysis.isRunning(AnalysisKind.mutation)
        ? Metric('Mutation', 'running…', MetricTone.dim)
        : measured('Mutation', mutationValue(mutation)),
    flaky == null
        ? Metric(
            'Flaky',
            analysis.isRunning(AnalysisKind.flaky)
                ? 're-running…'
                : 'not measured',
            MetricTone.dim,
          )
        : Metric(
            'Flaky',
            '${flaky.count}',
            flaky.count > 0 ? MetricTone.fail : MetricTone.ink,
          ),
  ];
}

// ---- needs your eyes ----

class ReviewRow {
  const ReviewRow(this.item, {required this.reviewed, required this.remote});

  final LookAtItem item;
  final bool reviewed;

  /// Ticks persist on the backend (code-to-check rows); every other kind is local to this
  /// page, as `LookAtItem.key` documents.
  final bool remote;
}

/// Open rows first, ticked ones after them, so ticking a row never leaves a gap above it.
List<ReviewRow> reviewRows(LookAt lookAt, Set<String> localReviewed) {
  bool remote(LookAtItem i) => i.kind == LookAtKind.codeToCheck;
  final open = <ReviewRow>[];
  final ticked = <ReviewRow>[];
  for (final i in lookAt.pending) {
    final row = ReviewRow(
      i,
      reviewed: localReviewed.contains(i.key),
      remote: remote(i),
    );
    (row.reviewed ? ticked : open).add(row);
  }
  for (final i in lookAt.done) {
    ticked.add(ReviewRow(i, reviewed: true, remote: remote(i)));
  }
  return [...open, ...ticked];
}

String emptyLookAtText(DisplayState state) => switch (state) {
  DisplayState.gate => 'Appears when the run finishes.',
  DisplayState.red ||
  DisplayState.green ||
  DisplayState.merged => 'Nothing flagged on this run.',
  _ => 'Nothing to review until the gate has run.',
};

String lookAtTitle(DisplayState s) =>
    s == DisplayState.red ? 'Failing & flagged' : 'Needs your eyes';

String lookAtHint(DisplayState s) => s == DisplayState.red
    ? 'Failures block the merge'
    : 'Advisory · never blocks the merge';

// ---- tamper banner ----

/// The sentence under the alarm headline: which test, in which file. The first finding
/// speaks for the rest; the count says how many more there are.
String tamperDetail(TamperAlarm alarm) {
  final findings = alarm.findings;
  if (findings.isEmpty) {
    return alarm.note ?? 'A passing suite would now prove less than before.';
  }
  final f = alarm.firstRemoved ?? findings.first;
  final more = findings.length > 1 ? ' and ${findings.length - 1} more' : '';
  if (f.kind == 'removed' && (f.test?.isNotEmpty ?? false)) {
    return '“${f.test}” is gone from ${f.file}$more. A passing suite would now prove less than before.';
  }
  final where = f.file.isEmpty ? '' : ' · ${f.file}';
  final what = (f.test?.isNotEmpty ?? false) ? '“${f.test}”. ' : '';
  return '$what${f.detail}$where$more';
}

// ---- lines no test ran ----

class UntestedSpot {
  const UntestedSpot({
    required this.path,
    this.start,
    this.end,
    required this.lines,
    this.code,
    this.unmapped = false,
  });

  final String path;
  final int? start;
  final int? end;
  final int lines;

  /// First never-run line as written in the diff, when the diff has it.
  final String? code;

  /// The coverage map held nothing for this file.
  final bool unmapped;

  String get label {
    final base = path.split('/').last;
    if (start == null) return base;
    return end == null || end == start ? '$base:$start' : '$base:$start–$end';
  }
}

class UntestedSummary {
  const UntestedSummary({
    this.spots = const [],
    this.unexecuted = 0,
    this.added = 0,
    this.available = false,
    this.stale = false,
    this.note,
  });

  static const none = UntestedSummary();

  final List<UntestedSpot> spots;
  final int unexecuted;
  final int added;

  /// The backend had a per-line map to read.
  final bool available;
  final bool stale;
  final String? note;

  String get meta {
    if (!available) return 'not measured';
    if (stale) return 'out of date, run the gate again';
    return '$unexecuted of $added added lines';
  }
}

/// Added line contents by file and new-file line number, so a never-run line can be shown
/// as the code that was written.
Map<String, Map<int, String>> parseAddedLines(String diff) {
  final out = <String, Map<int, String>>{};
  Map<int, String>? current;
  var inHunk = false;
  var line = 0;
  final hunk = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)');
  for (final raw in diff.split('\n')) {
    if (raw.startsWith('diff --git ')) {
      inHunk = false;
      current = null;
    } else if (!inHunk && raw.startsWith('+++ ')) {
      final p = raw.substring(4).trim();
      current = p == '/dev/null'
          ? null
          : out.putIfAbsent(p.startsWith('b/') ? p.substring(2) : p, () => {});
    } else if (raw.startsWith('@@')) {
      final m = hunk.firstMatch(raw);
      if (m != null) {
        line = int.parse(m.group(1)!);
        inHunk = true;
      }
    } else if (inHunk) {
      if (raw.startsWith('+')) {
        current?[line] = raw.substring(1);
        line++;
      } else if (raw.startsWith(' ')) {
        line++;
      }
    }
  }
  return out;
}

UntestedSummary deriveUntested(VerifiedHunksResponse? v, String diff) {
  if (v == null || !v.supported) {
    return UntestedSummary(note: v?.note);
  }
  final added = <String, Map<int, String>>{};
  var parsed = false;
  Map<int, String> addedFor(String path) {
    if (!parsed) {
      added.addAll(parseAddedLines(diff));
      parsed = true;
    }
    return added[path] ?? const {};
  }

  final spots = <UntestedSpot>[];
  var unexecuted = 0;
  var addedTotal = 0;
  for (final f in v.files) {
    addedTotal += f.added;
    if (f.stale) continue;
    unexecuted += f.unexecuted;
    if (f.unexecuted == 0) continue;
    if (!f.inMap) {
      spots.add(UntestedSpot(path: f.path, lines: f.added, unmapped: true));
      continue;
    }
    final cold = [
      for (final e in f.lines.entries)
        if (e.value == 0) e.key,
    ]..sort();
    final code = addedFor(f.path);
    var i = 0;
    while (i < cold.length) {
      var j = i;
      while (j + 1 < cold.length && cold[j + 1] - cold[j] <= 1) {
        j++;
      }
      final text = code[cold[i]]?.trim();
      spots.add(
        UntestedSpot(
          path: f.path,
          start: cold[i],
          end: cold[j],
          lines: j - i + 1,
          code: text == null || text.isEmpty ? null : text,
        ),
      );
      i = j + 1;
    }
  }
  spots.sort((a, b) => b.lines.compareTo(a.lines));
  return UntestedSummary(
    spots: spots,
    unexecuted: unexecuted,
    added: addedTotal,
    available: true,
    stale: v.stale,
    note: v.note,
  );
}

// ---- test grid ----

enum SquareState { passed, failed, running, skipped, pending }

class GridSquare {
  const GridSquare(this.state, this.label, this.group, {this.retried = false});

  final SquareState state;

  /// Holds a test that only passed on the gate's known-flaky retry.
  final bool retried;
  final String label;

  /// Index of the file group, or -1 for tests that have not started yet.
  final int group;
}

const int cellsPerSquare = 3;

/// One square per [cellsPerSquare] tests of the same file. A square shows its worst test:
/// failed, then still running, then passed. Tests the last run knew about but this one has
/// not started yet fill the tail as empty squares.
List<GridSquare> gridSquares(
  List<Cell> cells, {
  int expectedTotal = 0,
  Set<String> retried = const {},
}) {
  final byFile = <String, List<Cell>>{};
  for (final c in cells) {
    byFile.putIfAbsent(c.file, () => []).add(c);
  }
  final out = <GridSquare>[];
  var group = 0;
  for (final e in byFile.entries) {
    final list = e.value;
    for (var i = 0; i < list.length; i += cellsPerSquare) {
      final chunk = list.sublist(i, math.min(i + cellsPerSquare, list.length));
      final state = _worst(chunk);
      final file = e.key.isEmpty ? 'tests' : e.key;
      final hasRetried = chunk.any(
        (c) => retried.contains('${c.file}::${c.name}'),
      );
      final label =
          (chunk.length == 1
              ? '$file · ${chunk.first.name}'
              : '$file · ${chunk.length} tests') +
          (hasRetried ? ' · retried' : '');
      out.add(GridSquare(state, label, group, retried: hasRetried));
    }
    group++;
  }
  final missing = expectedTotal - cells.length;
  if (missing > 0) {
    final n = (missing / cellsPerSquare).ceil();
    for (var i = 0; i < n; i++) {
      out.add(const GridSquare(SquareState.pending, 'not started', -1));
    }
  }
  return out;
}

SquareState _worst(List<Cell> cells) {
  var running = false;
  var passed = false;
  for (final c in cells) {
    switch (c.status) {
      case CellStatus.failed:
        return SquareState.failed;
      case CellStatus.running:
        running = true;
      case CellStatus.passed:
        passed = true;
      case CellStatus.skipped:
      case CellStatus.unknown:
        break;
    }
  }
  if (running) return SquareState.running;
  return passed ? SquareState.passed : SquareState.skipped;
}

class GridLayout {
  const GridLayout(this.positions, this.height);

  final List<({double x, double y})> positions;
  final double height;
}

/// Left-to-right wrap; a change of file group opens a wider gap so files read as clusters.
GridLayout layoutGrid(
  List<GridSquare> squares, {
  required double width,
  double size = 9,
  double gap = 3,
  double groupGap = 6,
}) {
  final positions = <({double x, double y})>[];
  var x = 0.0;
  var y = 0.0;
  int? last;
  for (final s in squares) {
    if (last != null && s.group != last) x += groupGap;
    if (x + size > width && x > 0) {
      x = 0;
      y += size + gap;
    }
    positions.add((x: x, y: y));
    x += size + gap;
    last = s.group;
  }
  return GridLayout(positions, squares.isEmpty ? 0 : y + size);
}

// ---- impact ----

String impactMeta(ImpactResponse? i) {
  if (i == null) return 'tests that touch the change';
  if (!i.supported) return 'not supported by this runner';
  if (i.error != null) return 'unavailable';
  final n = i.impactedTests.length;
  return '$n ${n == 1 ? 'test touches' : 'tests touch'} this change';
}

/// `path -> tests` counts for the impacted files, most tests first.
List<({String file, int tests})> impactByFile(ImpactResponse i) {
  final counts = <String, int>{};
  for (final t in i.impactedTests) {
    counts[t.file] = (counts[t.file] ?? 0) + 1;
  }
  for (final f in i.impactedFiles) {
    counts.putIfAbsent(f, () => 0);
  }
  return [for (final e in counts.entries) (file: e.key, tests: e.value)]
    ..sort((a, b) => b.tests.compareTo(a.tests));
}

/// `/w/:id/code?file=…&line=…`. The code step may or may not read the query yet.
String codePath(String workspaceId, {String? file, int? line}) {
  final query = {
    if (file != null && file.isNotEmpty) 'file': file,
    if (line != null) 'line': '$line',
  };
  return Uri(
    path: '/w/$workspaceId/code',
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}
