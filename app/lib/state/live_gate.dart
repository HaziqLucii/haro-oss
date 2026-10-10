import '../api/models/models.dart';

class Tally {
  const Tally({
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.inflight = 0,
    this.total = 0,
  });

  final int passed;
  final int failed;
  final int skipped;
  final int inflight;
  final int total;

  int get done => total - inflight;
}

/// Cell counts the rail, the step bar and the grid summary all draw from, so `3 of 9`
/// never disagrees with the grid it describes.
Tally tally(List<Cell> cells) {
  var passed = 0, failed = 0, skipped = 0, inflight = 0;
  for (final c in cells) {
    switch (c.status) {
      case CellStatus.passed:
        passed++;
      case CellStatus.failed:
        failed++;
      case CellStatus.skipped:
        skipped++;
      case CellStatus.running:
        inflight++;
      case CellStatus.unknown:
        break;
    }
  }
  return Tally(
    passed: passed,
    failed: failed,
    skipped: skipped,
    inflight: inflight,
    total: cells.length,
  );
}

List<Cell> _upsert(List<Cell> cells, Cell cell) {
  final i = cells.indexWhere((c) => c.id == cell.id);
  if (i == -1) return [...cells, cell];
  return [...cells]..[i] = cell;
}

/// The authoritative gate as the workspace socket streams it: the live grid plus the last
/// settled run. Only [TestEvent]s can be applied. The Live Gate has its own type
/// ([LiveWatch]) so an advisory watch run can never overwrite the state a merge rests on.
class LiveGate {
  const LiveGate({this.cells = const [], this.run});

  static const empty = LiveGate();

  final List<Cell> cells;
  final TestRun? run;

  LiveGate apply(TestEvent e) => switch (e) {
    TestRunStarted() => LiveGate(run: run),
    TestCellEvent(:final cell) => LiveGate(
      cells: _upsert(cells, cell),
      run: run,
    ),
    TestSnapshotEvent(run: final r) => LiveGate(cells: cells, run: r),
  };

  /// Seeds from `GET /workspaces/{id}/tests` on open: cells are rebuilt from the run's cases.
  factory LiveGate.fromRun(TestRun? run) => LiveGate(
    cells: [
      if (run != null)
        for (final (i, c) in run.cases.indexed) c.toCell(i),
    ],
    run: run,
  );
}

/// Live Gate (advisory, `[gate] watch`). Same shape as [LiveGate], separate type on purpose.
class LiveWatch {
  const LiveWatch({this.cells = const [], this.run});

  static const empty = LiveWatch();

  final List<Cell> cells;
  final TestRun? run;

  LiveWatch apply(WatchEvent e) => switch (e.inner) {
    TestRunStarted() => LiveWatch(run: run),
    TestCellEvent(:final cell) => LiveWatch(
      cells: _upsert(cells, cell),
      run: run,
    ),
    TestSnapshotEvent(run: final r) => LiveWatch(cells: cells, run: r),
  };
}
