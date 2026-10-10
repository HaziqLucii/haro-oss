import '../../../../api/models/models.dart';
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

String _delta(double d, {bool words = false}) {
  final a = d.abs().toStringAsFixed(1);
  if (words) {
    if (d.abs() < .05) return 'same as main';
    return d > 0 ? 'up $a from main' : 'down $a from main';
  }
  if (d.abs() < .05) return '±0';
  return d > 0 ? '↑$a' : '↓$a';
}

String? coverageValue(TestRun? run) {
  final rd = run?.coverageDelta;
  return rd == null ? null : '${_delta(rd)} vs main';
}

/// The flaky count from the gate run itself, when the project enabled the re-run. Null when
/// nothing measured it.
int? flakyCount(TestRun? run, bool flakyRerun) =>
    flakyRerun && run != null && !run.running ? run.flakyTests.length : null;

/// Zone 1's metrics row. A number that was never measured says so, dimly; nothing here is
/// ever a placeholder standing in for a value.
List<Metric> deriveMetrics({
  required DisplayState state,
  required GateFacts facts,
  required TestRun? run,
  required ({int done, int total}) progress,
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
      Metric('Flaky', dash, MetricTone.dim),
    ];
  }

  Metric after(String label) => Metric(label, 'after run', MetricTone.dim);
  if (running) {
    return [
      Metric('Tests', '${progress.done} / ${progress.total}'),
      const Metric('Duration', dash, MetricTone.dim),
      after('Coverage'),
      after('Flaky'),
    ];
  }

  // A command or linter gate reports pass or fail, not a test count; "0 / 0" under a green
  // verdict reads like nothing ran.
  final countless =
      run != null &&
      !runnerReportsCounts(run.runner) &&
      facts.total == 0 &&
      facts.failed == 0;
  final tests = countless
      ? Metric(
          'Tests',
          'not counted',
          state == DisplayState.red ? MetricTone.fail : MetricTone.dim,
        )
      : Metric(
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

  final flaky = flakyCount(run, flakyRerun);
  return [
    tests,
    duration,
    measured('Coverage', coverageValue(run)),
    flaky == null
        ? const Metric('Flaky', 'not measured', MetricTone.dim)
        : Metric(
            'Flaky',
            '$flaky',
            flaky > 0 ? MetricTone.fail : MetricTone.ink,
          ),
  ];
}

// ---- needs your review ----

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
    s == DisplayState.red ? 'Failing & flagged' : 'Needs your review';

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
