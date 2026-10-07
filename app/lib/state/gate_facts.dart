import '../api/models/models.dart';
import 'live_gate.dart';
import 'review_items.dart';
import 'test_first.dart';

/// The gate facts the derivation needs, from whichever source exists: a full [TestRun]
/// (workspace open), a [GateSummary] (dashboard, off the coarse status feed), or nothing.
/// Fields a summary cannot carry (`tamperBlocked`, `mergeConflict`, `coverageBlocked`) read
/// as false there.
class GateFacts {
  const GateFacts({
    this.measured = false,
    this.status = TestRunStatus.unknown,
    this.total = 0,
    this.passed = 0,
    this.failed = 0,
    this.errorKind,
    this.tamperCount = 0,
    this.tamperNote,
    this.tamperBlocked = false,
    this.acceptanceBlocked = false,
    this.acceptance,
    this.degraded = false,
    this.mergeConflict = false,
    this.mergeNote,
    this.coverageBlocked = false,
    this.coverageNote,
    this.uncheckedCount,
    this.endedAt,
    this.wallMs,
  });

  static const none = GateFacts();

  /// A run or summary existed.
  final bool measured;
  final TestRunStatus status;
  final int total;
  final int passed;
  final int failed;
  final GateErrorKind? errorKind;
  final int tamperCount;
  final String? tamperNote;
  final bool tamperBlocked;

  /// The approved acceptance test changed, went missing or fails (test-first).
  final bool acceptanceBlocked;
  final AcceptanceCheck? acceptance;
  final bool degraded;
  final bool mergeConflict;
  final String? mergeNote;
  final bool coverageBlocked;
  final String? coverageNote;

  /// Rows awaiting a look; `null` = the pass never ran.
  final int? uncheckedCount;
  final double? endedAt;
  final double? wallMs;

  bool get errored => status == TestRunStatus.error;

  factory GateFacts.fromRun(TestRun r) => GateFacts(
    measured: true,
    status: r.status,
    total: r.total,
    passed: r.passed,
    failed: r.failed,
    errorKind: r.errorKind,
    tamperCount: r.tamperFindings.length,
    tamperNote: r.tamperNote,
    tamperBlocked: r.tamperBlocked,
    acceptanceBlocked: r.acceptanceBlocked,
    acceptance: r.acceptance,
    degraded: r.degraded,
    mergeConflict: r.mergeConflict,
    mergeNote: r.mergeNote,
    coverageBlocked: r.coverageBlocked,
    coverageNote: r.coverageNote,
    uncheckedCount: r.uncheckedItems?.length,
    endedAt: r.endedAt,
    wallMs: r.wallMs,
  );

  /// A summary has no `tamper_blocked` field. A red workspace whose summary shows every
  /// test passing and tamper findings can only be red because block mode caught them.
  factory GateFacts.fromSummary(GateSummary s, {WorkspaceStatus? status}) =>
      GateFacts(
        tamperBlocked:
            status == WorkspaceStatus.gateRed &&
            s.status == TestRunStatus.passed &&
            s.failed == 0 &&
            s.tamperCount > 0 &&
            !s.degraded,
        measured: true,
        status: s.status,
        total: s.total,
        passed: s.passed,
        failed: s.failed,
        errorKind: s.errorKind,
        tamperCount: s.tamperCount,
        tamperNote: s.tamperNote,
        degraded: s.degraded,
        uncheckedCount: s.uncheckedCount,
        endedAt: s.endedAt,
      );

  /// A `watch` run is advisory and never a verdict, so it is ignored here.
  static GateFacts resolve(
    TestRun? run,
    GateSummary? summary, {
    WorkspaceStatus? status,
  }) {
    if (run != null && run.trigger != 'watch') return GateFacts.fromRun(run);
    if (summary != null) return GateFacts.fromSummary(summary, status: status);
    return GateFacts.none;
  }
}

enum BlockerKind {
  gateError,
  failingTests,
  mergeConflict,
  tamperBlocked,
  acceptanceBroken,
  coverageBlocked,
  degraded,
}

/// What a blocker's fix button does. The UI maps each to a concrete call.
enum FixAction {
  sendFailures,
  restoreTests,
  rerunGate,
  rerunSetup,
  openGateSettings,
}

class Blocker {
  const Blocker(this.kind, this.text, this.fixLabel, this.fix);

  final BlockerKind kind;
  final String text;
  final String fixLabel;
  final FixAction fix;
}

/// Coverage has two different fixes, told apart by whether a number exists: a measured drop
/// asks you to restore coverage, an unmeasured one asks you to fix the measurement.
String coverageBlockHint(bool hasDelta) =>
    hasDelta ? 'Relax coverage guard' : 'Fix coverage reporting';

/// Every reason this gate refuses to ship, in a fixed order so the first is always "the real
/// one". A gate error stops the list: there is nothing to judge if the gate never ran.
List<Blocker> deriveBlockers(
  GateFacts f, {
  bool adopted = false,
  bool coverageHasDelta = true,
}) {
  if (!f.measured) return const [];

  if (f.errored) {
    final framing = gateErrorFraming(f.errorKind, adopted: adopted);
    final setupAdopted = f.errorKind == GateErrorKind.setup && adopted;
    return [
      Blocker(
        BlockerKind.gateError,
        framing.title,
        setupAdopted ? 'Re-run setup' : 'Re-run gate',
        setupAdopted ? FixAction.rerunSetup : FixAction.rerunGate,
      ),
    ];
  }

  final out = <Blocker>[];
  if (f.failed > 0) {
    out.add(
      Blocker(
        BlockerKind.failingTests,
        '${f.failed} failing ${f.failed == 1 ? 'test' : 'tests'}',
        'Send failures to agent',
        FixAction.sendFailures,
      ),
    );
  }
  if (f.mergeConflict) {
    out.add(
      Blocker(
        BlockerKind.mergeConflict,
        f.mergeNote ?? 'can’t merge the base branch into this workspace',
        'Send conflict to agent',
        FixAction.sendFailures,
      ),
    );
  }
  if (f.acceptanceBlocked) {
    out.add(
      Blocker(
        BlockerKind.acceptanceBroken,
        acceptanceBlockText(f.acceptance),
        'Restore acceptance test',
        FixAction.restoreTests,
      ),
    );
  }
  if (f.tamperBlocked) {
    out.add(
      Blocker(
        BlockerKind.tamperBlocked,
        tamperCountSummary(f.tamperCount, f.tamperNote),
        'Restore tests',
        FixAction.restoreTests,
      ),
    );
  }
  if (f.coverageBlocked) {
    out.add(
      Blocker(
        BlockerKind.coverageBlocked,
        f.coverageNote ?? 'coverage dropped below the guard',
        coverageBlockHint(coverageHasDelta),
        FixAction.openGateSettings,
      ),
    );
  }
  if (f.degraded) {
    out.add(
      const Blocker(
        BlockerKind.degraded,
        'a check didn’t run',
        'Re-run gate',
        FixAction.rerunGate,
      ),
    );
  }
  return out;
}

/// True when the gate cannot honestly ship: red, or an otherwise-green run that is degraded
/// (a check the project asked for didn't run). Mirrors the backend's ship preflight.
bool isCantShip(WorkspaceStatus status, GateFacts f) =>
    status == WorkspaceStatus.gateRed ||
    (status == WorkspaceStatus.gateGreen && f.degraded);

/// Live progress of a running gate: `done / total`, where total is the larger of the cells
/// seen so far and the last known run's total (cells only appear as they start).
({int done, int total}) gateProgress(List<Cell> cells, {int? expectedTotal}) {
  final t = tally(cells);
  final total = (expectedTotal != null && expectedTotal > t.total)
      ? expectedTotal
      : t.total;
  return (done: t.done, total: total);
}
