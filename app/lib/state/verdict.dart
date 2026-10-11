import '../api/models/models.dart';
import 'display_state.dart';
import 'gate_facts.dart';
import 'look_at.dart';
import 'review_items.dart';

/// The verify step's Zone 1 copy (spec 5.6): a state word, a headline, one sentence of
/// consequence, and the rail's one-line summary. Never the words verified, proven or correct.
class VerdictCopy {
  const VerdictCopy({
    required this.word,
    required this.headline,
    required this.sub,
    required this.rail,
  });

  /// Mono uppercase state word: `GREEN`, `GREEN*`, `RED`, `RUNNING`, `NOT RUN`, `MERGED`.
  final String word;

  /// `All 594 tests pass`, `3 tests are failing`, `412 of 594 tests done`,
  /// `The gate hasn’t run on this tree.`, `Merged into origin/main`.
  final String headline;
  final String sub;

  /// Rail Gate section summary line.
  final String rail;
}

/// The tamper alarm banner: a test was removed or weakened on the way to green. The loudest
/// element in the app after a red verdict.
class TamperAlarm {
  const TamperAlarm({
    required this.count,
    required this.headline,
    this.note,
    this.blocked = false,
    this.findings = const [],
  });

  final int count;

  /// `The agent deleted a test that covered this change.`
  final String headline;
  final String? note;

  /// `[gate] tamper_alarm = "block"` turned the run red.
  final bool blocked;

  /// Empty when derived from a dashboard summary (findings live on the full run).
  final List<TamperFinding> findings;

  /// The first `removed` finding when there is one: what "See deletion" points at.
  TamperFinding? get firstRemoved {
    for (final f in findings) {
      if (f.kind == 'removed') return f;
    }
    return null;
  }
}

/// [manual] words the same findings without an actor: nobody but you wrote the code there,
/// so "The agent ..." would be wrong.
String _tamperHeadline(
  List<TamperFinding> findings,
  int count, {
  bool manual = false,
}) {
  final kinds = findings.map((f) => f.kind).toSet();
  if (findings.isEmpty || kinds.length > 1) {
    if (manual) {
      return count > 1
          ? 'The test suite was weakened in $count places.'
          : 'The test suite was weakened.';
    }
    return count > 1
        ? 'The agent weakened the test suite in $count places.'
        : 'The agent weakened the test suite.';
  }
  final plural = findings.length > 1;
  String pick(String agentOne, String agentMany, String one, String many) =>
      manual ? (plural ? many : one) : (plural ? agentMany : agentOne);
  return switch (kinds.single) {
    'removed' => pick(
      'The agent deleted a test that covered this change.',
      'The agent deleted ${findings.length} tests that covered this change.',
      'A test that covered this change was deleted.',
      '${findings.length} tests that covered this change were deleted.',
    ),
    'skip' => pick(
      'The agent skipped a test.',
      'The agent skipped tests.',
      'A test was skipped.',
      'Tests were skipped.',
    ),
    'xfail' => pick(
      'The agent marked a test as an expected failure.',
      'The agent marked tests as expected failures.',
      'A test was marked as an expected failure.',
      'Tests were marked as expected failures.',
    ),
    'weakened' => pick(
      'The agent loosened an assertion.',
      'The agent loosened assertions.',
      'An assertion was loosened.',
      'Assertions were loosened.',
    ),
    'timeout' => pick(
      'The agent raised a test timeout.',
      'The agent raised test timeouts.',
      'A test timeout was raised.',
      'Test timeouts were raised.',
    ),
    'only' =>
      manual
          ? '.only was added, so other tests stopped running.'
          : 'The agent added .only, so other tests stopped running.',
    'todo' =>
      manual
          ? 'Tests were turned into todos.'
          : 'The agent turned tests into todos.',
    'assertions' =>
      manual
          ? 'Assertions were removed from a test.'
          : 'The agent removed assertions from a test.',
    'snapshot' =>
      manual ? 'Snapshots were rewritten.' : 'The agent rewrote snapshots.',
    'config' => 'The test configuration changed.',
    'vacuous' => 'A new test already passes without the change.',
    'acceptance_changed' =>
      'The approved acceptance test changed after approval.',
    'acceptance_missing' =>
      'An approved acceptance test is missing from the run.',
    _ =>
      manual
          ? 'The test suite was weakened.'
          : 'The agent weakened the test suite.',
  };
}

TamperAlarm? deriveTamperAlarm(
  GateFacts f,
  TestRun? run, {
  bool manual = false,
}) {
  if (f.tamperCount == 0) return null;
  final findings = run?.tamperFindings ?? const <TamperFinding>[];
  return TamperAlarm(
    count: f.tamperCount,
    headline: _tamperHeadline(findings, f.tamperCount, manual: manual),
    note: f.tamperNote,
    blocked: f.tamperBlocked,
    findings: findings,
  );
}

String _testsWord(int n) => n == 1 ? 'test' : 'tests';

VerdictCopy deriveVerdictCopy({
  required DisplayState state,
  required GateFacts facts,
  required List<Blocker> blockers,
  required ({int done, int total}) progress,
  required int liveFailed,
  required LookAt lookAt,
  required int openLookCount,
  required bool starred,
  required String baseRef,
  int? prNumber,
  bool adopted = false,
  bool manual = false,
  bool autoGate = true,
}) {
  switch (state) {
    case DisplayState.merged:
      final pr = prNumber == null
          ? ''
          : 'PR #$prNumber merged on a green gate. ';
      return VerdictCopy(
        word: 'MERGED',
        headline: 'Merged into $baseRef',
        sub:
            '${pr.isEmpty ? 'Merged on a green gate. ' : pr}The worktree stays until you delete the workspace.',
        rail: prNumber == null
            ? 'merged on green'
            : '#$prNumber · merged on green',
      );

    case DisplayState.gate:
      final p = progress;
      final total = p.total;
      return VerdictCopy(
        word: 'RUNNING',
        headline: total > 0
            ? '${p.done} of $total ${_testsWord(total)} done'
            : 'Gate starting',
        sub: liveFailed == 0
            ? 'No failures so far. The first failure shows up here the moment it happens.'
            : '$liveFailed failing so far. This branch can’t merge until they pass.',
        rail: total > 0
            ? '${p.done} / $total · ${liveFailed == 0 ? 'no failures yet' : '$liveFailed failing'}'
            : 'starting',
      );

    case DisplayState.red:
      return _red(facts, blockers, adopted, manual);

    case DisplayState.green:
      final tests = facts.passed > 0 ? facts.passed : facts.total;
      final headline = tests > 0
          ? (tests == 1 ? '1 test passes' : 'All $tests tests pass')
          : 'The gate passed';
      final String sub;
      if (starred) {
        sub = 'The suite changed on the way to green. Check the tamper alarm before you ship.';
      } else if (openLookCount > 0) {
        final untestedOnly =
            lookAt.pending.isNotEmpty &&
            lookAt.pending.every(
              (i) =>
                  i.rawKind == 'untested_lines' || i.rawKind == 'no_test_file',
            );
        sub = untestedOnly
            ? 'This branch is mergeable. $openLookCount changed ${openLookCount == 1 ? 'spot wasn’t' : 'spots weren’t'} exercised by any test; take a look before you ship.'
            : 'This branch is mergeable. $openLookCount ${openLookCount == 1 ? 'thing is' : 'things are'} worth a look before you ship. They won’t block the merge.';
      } else {
        sub = 'This branch is mergeable. Nothing is flagged.';
      }
      return VerdictCopy(
        word: starred ? 'GREEN*' : 'GREEN',
        headline: headline,
        sub: sub,
        rail: tests > 0 ? '$tests / $tests passed · mergeable' : 'mergeable',
      );

    case DisplayState.idle:
    case DisplayState.plan:
    case DisplayState.agent:
      if (manual) {
        return const VerdictCopy(
          word: 'NOT RUN',
          headline: 'The gate hasn’t run on this tree.',
          sub: 'Run it whenever you want to check your changes. Nothing ships until it is green.',
          rail: 'Not run yet',
        );
      }
      if (!autoGate) {
        return const VerdictCopy(
          word: 'NOT RUN',
          headline: 'The gate hasn’t run on this tree.',
          sub: 'Run it when you are ready to check the changes. Nothing ships until it is green.',
          rail: 'Not run yet',
        );
      }
      return const VerdictCopy(
        word: 'NOT RUN',
        headline: 'The gate hasn’t run on this tree.',
        sub: 'It starts by itself when the agent finishes. Run it now if you changed files by hand.',
        rail: 'Runs when the agent finishes',
      );
  }
}

VerdictCopy _red(
  GateFacts f,
  List<Blocker> blockers,
  bool adopted,
  bool manual,
) {
  if (f.errored) {
    final framing = gateErrorFraming(f.errorKind, adopted: adopted);
    return VerdictCopy(
      word: 'NOT RUN',
      headline: framing.title,
      sub: framing.hint,
      rail: 'gate didn’t run',
    );
  }
  final first = blockers.isEmpty ? null : blockers.first;
  switch (first?.kind) {
    case BlockerKind.failingTests:
      final n = f.failed;
      return VerdictCopy(
        word: 'RED',
        headline: n == 1 ? '1 test is failing' : '$n tests are failing',
        sub: manual
            ? 'This branch can’t merge until they pass. Fix them in code.'
            : 'This branch can’t merge until they pass. Send the failures back to the agent, or fix them yourself in code.',
        rail: f.total > 0 ? '$n of ${f.total} failing' : '$n failing',
      );
    case BlockerKind.mergeConflict:
      return VerdictCopy(
        word: 'RED',
        headline: 'The base branch doesn’t merge cleanly',
        sub: '${first!.text}. Resolve it before this branch can merge.',
        rail: 'merge conflict',
      );
    case BlockerKind.tamperBlocked:
      return VerdictCopy(
        word: 'RED',
        headline: 'The test suite was weakened',
        sub: 'The tamper alarm blocks the merge. Restore the removed or weakened tests, or relax the alarm in gate settings.',
        rail: 'tamper alarm',
      );
    case BlockerKind.acceptanceBroken:
      return VerdictCopy(
        word: 'RED',
        headline: 'The acceptance test isn’t intact',
        sub:
            '${first!.text}. The approved test is the task’s contract, so this blocks the merge whatever the tamper alarm says.',
        rail: 'acceptance test',
      );
    case BlockerKind.coverageBlocked:
      return VerdictCopy(
        word: 'RED',
        headline: 'Coverage dropped below the guard',
        sub: '${first!.text}. Restore coverage or relax the guard to ship.',
        rail: 'coverage guard',
      );
    case BlockerKind.degraded:
      return const VerdictCopy(
        word: 'RED',
        headline: 'The gate couldn’t check everything',
        sub: 'A check the project asked for didn’t run, so a green here would cover less than it looks. Re-run the gate.',
        rail: 'a check didn’t run',
      );
    case BlockerKind.gateError:
    case null:
      return const VerdictCopy(
        word: 'RED',
        headline: 'This branch can’t merge',
        sub: 'The gate is red. Re-run it to see why.',
        rail: 'red',
      );
  }
}
