import '../api/models/models.dart';
import 'review_items.dart';

enum LookAtKind { failedTest, codeToCheck, tamper, flaky, coverage }

/// One row of the verify step's "Needs your review" / "Failing & flagged" list and the rail's
/// short list. Failures and a blocked tamper/coverage guard are [blocking]; everything else
/// is advisory and never blocks the merge.
class LookAtItem {
  const LookAtItem({
    required this.kind,
    required this.key,
    required this.label,
    required this.title,
    this.file,
    this.line,
    this.detail = '',
    this.blocking = false,
    required this.review,
    this.rawKind = '',
    this.count = 0,
  });

  final LookAtKind kind;

  /// Stable across re-gates. For code-to-check rows this is the handle a tick-off is stored
  /// against (`POST /workspaces/{id}/checked`); the other kinds are UI-local.
  final String key;

  /// Mono uppercase kind tag: `FAILED`, `NO TEST RAN`, `NO TEST IMPORTS`, `TEST REMOVED`...
  final String label;

  /// Test name, or the path when there is no better title.
  final String title;
  final String? file;
  final int? line;
  final String detail;
  final bool blocking;

  /// The "Ask agent" / "Send N to agent" payload for this item.
  final ReviewItem review;

  /// The backend's own kind string (`untested_lines`, `removed`...), for callers that branch.
  final String rawKind;

  /// Line count for `untested_lines` rows, else 0.
  final int count;

  bool get isFailure => kind == LookAtKind.failedTest;

  /// A credential match: labelled red like an alarm, but still advisory.
  bool get isSecret => rawKind == 'secret_found';

  /// Rail glyph: a cross for failures, a hollow circle for everything else.
  String get glyph => isFailure ? '✕' : '○';

  /// `file`, or the last path segment for the rail (`✕ shipping.test.ts`).
  String get shortFile {
    final f = file ?? title;
    final i = f.lastIndexOf('/');
    return i < 0 ? f : f.substring(i + 1);
  }
}

class LookAt {
  const LookAt({this.pending = const [], this.done = const []});

  static const empty = LookAt();

  /// Open items, in fixed order: failures, code to check, tamper, flaky, coverage.
  final List<LookAtItem> pending;

  /// Ticked-off items. Only code-to-check rows are tickable.
  final List<LookAtItem> done;

  int get openCount => pending.length;
  int get blockingCount => pending.where((i) => i.blocking).length;
  List<LookAtItem> get railItems => pending.take(3).toList();
}

String _tamperLabel(String kind) => switch (kind) {
  'removed' => 'TEST REMOVED',
  'skip' => 'TEST SKIPPED',
  'xfail' => 'TEST MARKED XFAIL',
  'weakened' => 'ASSERTION WEAKENED',
  'timeout' => 'TIMEOUT WIDENED',
  'only' => 'TEST .ONLY ADDED',
  'todo' => 'TEST TODO',
  'assertions' => 'ASSERTIONS REMOVED',
  'snapshot' => 'SNAPSHOT REWRITTEN',
  'config' => 'TEST CONFIG CHANGED',
  // Fallback for a run saved before vacuous stopped being a tamper kind.
  'vacuous' => 'NEW TEST ALREADY PASSES',
  _ => kind.toUpperCase(),
};

String _firstLine(String? s) {
  if (s == null) return '';
  final t = s.trim();
  final i = t.indexOf('\n');
  return i < 0 ? t : t.substring(0, i).trim();
}

/// Failing tests, in grid order. Prefers the live [cells]; falls back to a settled run's
/// stored cases (a freshly opened workspace has no streamed cells).
List<Cell> failedCells(List<Cell> cells, TestRun? run) {
  final source = cells.isNotEmpty
      ? cells
      : [
          if (run != null)
            for (final (i, c) in run.cases.indexed) c.toCell(i),
        ];
  return source.where((c) => c.status == CellStatus.failed).toList();
}

/// Everything worth a human's eyes, ported from `verdict.ts lookAt` and reshaped for the
/// redesign: failures now share the list (the red state's "Failing & flagged"), and tamper
/// findings stay in it even when blocked, flagged via [LookAtItem.blocking].
///
/// The Double Gate (`quality`, plan gaps, code review) rows are dropped with the feature.
LookAt deriveLookAt({
  TestRun? run,
  List<Cell> cells = const [],
  List<String> checkedKeys = const [],
  bool codeToCheckEnabled = true,
}) {
  final pending = <LookAtItem>[];
  final done = <LookAtItem>[];

  final runDone = run != null && !run.running;
  if (runDone && run.status != TestRunStatus.error) {
    for (final c in failedCells(cells, run)) {
      pending.add(
        LookAtItem(
          kind: LookAtKind.failedTest,
          key: 'failed:${c.file}:${c.name}',
          label: 'FAILED',
          title: c.name,
          file: c.file.isEmpty ? null : c.file,
          detail: _firstLine(c.message),
          blocking: true,
          review: failureReviewItem(c),
          rawKind: 'failed',
        ),
      );
    }
  }

  if (runDone) {
    // The secrets scan has its own switch, so its rows survive `code_to_check = off`.
    final rows = codeToCheckEnabled
        ? run.uncheckedItems
        : run.uncheckedItems?.where((r) => r.kind == 'secret_found').toList();
    final state = deriveUncheckedState(
      enabled: codeToCheckEnabled || (rows?.isNotEmpty ?? false),
      rows: rows,
      coveredFiles: run.uncheckedCoveredFiles,
      checkedKeys: checkedKeys,
      status: run.status,
      scope: run.scope,
    );
    if (state is UncheckedRows) {
      LookAtItem toItem(UncheckedRow r) => LookAtItem(
        kind: LookAtKind.codeToCheck,
        key: r.key,
        label: uncheckedKindLabel(r.kind).toUpperCase(),
        title: r.file.isEmpty
            ? uncheckedKindLabel(r.kind)
            : (r.line == null ? r.file : '${r.file}:${r.line}'),
        file: r.file.isEmpty ? null : r.file,
        line: r.line,
        detail: r.rule == null || r.rule!.isEmpty
            ? r.detail
            : '${r.detail} · ${r.rule}',
        review: uncheckedReviewItem(r),
        rawKind: r.kind,
        count: r.count,
      );
      pending.addAll(state.pending.map(toItem));
      done.addAll(state.done.map(toItem));
    }
  }

  if (run != null) {
    for (final f in run.tamperFindings) {
      final where = (f.test != null && f.test!.isNotEmpty) ? f.test! : f.file;
      pending.add(
        LookAtItem(
          kind: LookAtKind.tamper,
          key: 'tamper:${f.kind}:${f.file}:${f.test ?? ''}',
          label: _tamperLabel(f.kind),
          title: where.isEmpty ? tamperKindLabel(f.kind) : where,
          file: f.file.isEmpty ? null : f.file,
          detail: f.detail,
          blocking: run.tamperBlocked,
          review: tamperReviewItem(f),
          rawKind: f.kind,
        ),
      );
    }

    for (final name in run.flakyTests) {
      pending.add(
        LookAtItem(
          kind: LookAtKind.flaky,
          key: 'flaky:$name',
          label: 'FLAKY',
          title: name,
          detail: 'failed then passed on re-run',
          review: flakyReviewItem(name),
          rawKind: 'flaky',
        ),
      );
    }

    final note = run.coverageNote;
    if (note != null && note.isNotEmpty) {
      pending.add(
        LookAtItem(
          kind: LookAtKind.coverage,
          key: 'coverage',
          label: 'COVERAGE DROP',
          title: note,
          detail: note,
          blocking: run.coverageBlocked,
          review: coverageReviewItem(note),
          rawKind: 'coverage',
        ),
      );
    }
  }

  return LookAt(pending: pending, done: done);
}

// ---- code to check: what the pane is entitled to say ----

/// Resolved in one place so a widget only renders it. An empty list is not a clean bill of
/// health unless something looked: the old pane said "every changed line ran" over a red
/// gate, an impacted-only run, and a diff the coverage map never contained.
sealed class UncheckedState {
  const UncheckedState();
}

class UncheckedOff extends UncheckedState {
  const UncheckedOff();
}

/// Nothing measured the diff on this run; [reason] says which of the several whys.
class UncheckedUnmeasured extends UncheckedState {
  const UncheckedUnmeasured(this.reason);
  final String reason;
}

/// Measured, nothing outstanding, and coverage really watched [files] files run.
class UncheckedClean extends UncheckedState {
  const UncheckedClean(this.files);
  final int files;
}

/// Measured, nothing outstanding, but coverage could not speak about this diff.
class UncheckedQuiet extends UncheckedState {
  const UncheckedQuiet(this.reason);
  final String reason;
}

class UncheckedRows extends UncheckedState {
  const UncheckedRows({
    required this.pending,
    required this.done,
    this.coverage,
  });
  final List<UncheckedRow> pending;
  final List<UncheckedRow> done;

  /// Caveat under the summary when the coverage half was blind.
  final String? coverage;
}

String? uncheckedCoverageNote(int? coveredFiles) {
  if (coveredFiles == null) {
    return 'no coverage data for this run, so only the risk checks ran';
  }
  if (coveredFiles == 0) {
    return 'the suite executed none of the changed files, so only the risk checks ran';
  }
  return null;
}

UncheckedState deriveUncheckedState({
  required bool enabled,
  List<UncheckedRow>? rows,
  int? coveredFiles,
  List<String> checkedKeys = const [],
  TestRunStatus? status,
  TestScope? scope,
}) {
  if (!enabled) return const UncheckedOff();
  if (status == null || status == TestRunStatus.running) {
    return const UncheckedUnmeasured(
      'run the gate to see what nothing checked',
    );
  }
  if (rows == null) {
    final reason = status == TestRunStatus.failed
        ? 'the gate is red, so nothing has looked at the diff yet. get it green first'
        : (scope != null && scope != TestScope.all)
        ? 'this was an impacted-only run, so run the full gate to check the diff'
        : 'this run did not measure the diff';
    return UncheckedUnmeasured(reason);
  }
  final checked = checkedKeys.toSet();
  final pending = rows.where((r) => !checked.contains(r.key)).toList();
  final done = rows.where((r) => checked.contains(r.key)).toList();
  if (rows.isEmpty) {
    final blind = uncheckedCoverageNote(coveredFiles);
    return blind != null
        ? UncheckedQuiet(blind)
        : UncheckedClean(coveredFiles ?? 0);
  }
  return UncheckedRows(
    pending: pending,
    done: done,
    coverage: uncheckedCoverageNote(coveredFiles),
  );
}
