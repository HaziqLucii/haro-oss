import '../api/models/models.dart';
import 'format.dart';

/// One item of a "send to agent" batch. `target` locates it, `context` is the evidence,
/// `text` is the ask, prefilled so the batch is sendable without typing.
class ReviewItem {
  const ReviewItem({required this.target, this.context, required this.text});

  final String target;
  final String? context;
  final String text;
}

/// Short code-shaped tags for the tamper drill-down. An unknown kind (a signal added later)
/// falls through to its raw string.
const _tamperKindLabel = {
  'removed': 'removed',
  'skip': '.skip',
  'xfail': 'xfail',
  'only': '.only',
  'todo': '.todo',
  'weakened': 'weakened',
  'assertions': 'assertions',
  'timeout': 'timeout',
  'snapshot': 'snapshot',
  'config': 'config',
  'vacuous': 'new test already passes',
  'acceptance_changed': 'acceptance changed',
  'acceptance_missing': 'acceptance missing',
};

String tamperKindLabel(String kind) => _tamperKindLabel[kind] ?? kind;

/// The restore instruction per kind. For a tamper finding the finding IS the ask
/// (`.only added` means take it out), which is why "restore" is sendable untyped.
const _tamperFixHint = {
  'removed': 'restore this deleted test: re-add it with its original assertions, do not weaken it',
  'skip': 'remove the added .skip so this test runs again, and make it pass for real',
  'xfail': 'remove the added xfail so a failure of this test fails the gate again, and make it pass for real',
  'weakened': 'restore the original, stricter assertion here instead of the loosened one',
  'timeout': 'revert the raised timeout and fix why this test is slow or hangs',
  'only':
      'remove the added .only: it silently stops every other test from running',
  'todo': 'remove the added .todo and restore the real test body',
  'assertions': 'restore the expect() assertions removed from this file',
  'snapshot': 'reverify these snapshot rewrites and revert any that hide a real behaviour change',
  'config': "review this test-config change: confirm it doesn't quietly widen an exclude glob, retarget a test script, or otherwise change which tests run",
  'vacuous': 'this new test already passes on the base branch, so it guards existing behaviour, not this change. fine for a negative case; if it should fail without the change, strengthen its assertion',
  'acceptance_changed': 'restore the approved acceptance test file exactly as approved (git checkout the file) and change source code instead',
  'acceptance_missing': 'restore the approved acceptance test exactly as approved: it must be present and passing',
};

String tamperFixHint(String kind) =>
    _tamperFixHint[kind] ??
    'restore this weakened test to its pre-change strength';

/// The compact `green*` line: the backend's note (`3 removed · 2 skipped`) when it built
/// one, else a plain count.
String tamperCountSummary(int count, String? note) {
  if (note != null && note.isNotEmpty) return note;
  return '$count suspicious test ${plural(count, 'change')}';
}

const _uncheckedKindLabel = {
  'no_test_file': 'no test imports',
  'untested_lines': 'no test ran',
  'new_dep': 'new dependency',
  'secret': 'secret touched',
  'secret_found': 'possible secret',
  'deleted': 'file deleted',
  'migration': 'migration',
  'suite_weakened': 'suite weakened',
  'assertion_rewritten': 'assertion rewritten',
  'vacuous_test': 'new test already passes',
};

/// Rows state plainly what was NOT observed. Nothing here says proven or verified: a line
/// with a hit count was executed, which is not the same as asserted about.
String uncheckedKindLabel(String kind) => _uncheckedKindLabel[kind] ?? kind;

const _uncheckedFixHint = {
  'no_test_file': 'nothing imports this file in any test. add a test that exercises what changed here',
  'untested_lines': "these added lines never executed in the suite. cover them, or explain why they can't be",
  'new_dep':
      'confirm this dependency is needed, pinned, and from a source we trust',
  'secret': 'confirm nothing secret was committed and the value came from the environment',
  'secret_found': 'this looks like a credential. if it is real, rotate it, remove it from the diff and read it from the environment instead',
  'deleted':
      'confirm this deletion is intended and nothing still references it',
  'migration':
      'confirm this migration is reversible and safe to run on real data',
  'suite_weakened':
      'restore the weakened test rather than leaving the suite thinner',
  'assertion_rewritten': 'this test was retitled and now asserts something else. confirm the behaviour it checked at base is either still asserted somewhere or was meant to change',
  'vacuous_test': 'this new test already passes on the base branch, so it guards existing behaviour, not this change. fine for a negative case; if it should fail without the change, strengthen its assertion',
};

String uncheckedFixHint(String kind) =>
    _uncheckedFixHint[kind] ??
    'confirm this change is intended, since nothing checked it';

String _basename(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

ReviewItem failureReviewItem(Cell c) => ReviewItem(
  target: 'test: ${c.name}',
  context: c.message,
  text: 'make this test pass without weakening it',
);

ReviewItem tamperReviewItem(TamperFinding f) {
  final label = tamperKindLabel(f.kind);
  final where = (f.test != null && f.test!.isNotEmpty)
      ? f.test!
      : (f.file.isEmpty ? '' : _basename(f.file));
  final ctx = [f.detail, f.file].where((s) => s.isNotEmpty).join(' · ');
  return ReviewItem(
    target: where.isEmpty ? label : '$label: $where',
    context: ctx.isEmpty ? null : ctx,
    text: tamperFixHint(f.kind),
  );
}

ReviewItem uncheckedReviewItem(UncheckedRow r) {
  final label = uncheckedKindLabel(r.kind);
  final base = r.file.isEmpty ? '' : _basename(r.file);
  final ctx = [r.detail, r.file].where((s) => s.isNotEmpty).join(' · ');
  return ReviewItem(
    target: base.isEmpty ? label : '$label: $base',
    context: ctx.isEmpty ? null : ctx,
    text: uncheckedFixHint(r.kind),
  );
}

ReviewItem flakyReviewItem(String name) => ReviewItem(
  target: 'flaky: $name',
  text: 'this test failed then passed on re-run. find and fix the flake, or mark it skip with a reason',
);

ReviewItem coverageReviewItem(String note) => ReviewItem(
  target: 'coverage drop',
  context: note,
  text: 'add tests to restore the coverage guard, or explain why the drop is expected',
);

/// One follow-up prompt for "Send N to agent".
String buildFollowUpPrompt(List<ReviewItem> items) {
  final b = StringBuffer(
    items.length == 1
        ? 'Address this gate finding:\n'
        : 'Address these ${items.length} gate findings:\n',
  );
  for (final (i, it) in items.indexed) {
    b.writeln('\n${i + 1}. ${it.target}');
    if (it.context != null && it.context!.isNotEmpty) {
      b.writeln('   ${it.context}');
    }
    b.writeln('   ${it.text}');
  }
  return b.toString().trimRight();
}

/// Plain-language framing for a gate that could not run, so a setup problem never reads
/// like a test failure.
class GateErrorFraming {
  const GateErrorFraming(this.title, this.hint);
  final String title;
  final String hint;
}

GateErrorFraming gateErrorFraming(GateErrorKind? kind, {bool adopted = false}) {
  if (kind == GateErrorKind.setup && adopted) {
    return const GateErrorFraming(
      'Environment, not code',
      'This is an adopted worktree, and its deps and toolchain aren’t ready yet, so the gate never ran. This is not a test failure. Re-run setup to provision the worktree, then re-run the gate.',
    );
  }
  switch (kind) {
    case GateErrorKind.setup:
      return const GateErrorFraming(
        'The gate couldn’t run: setup failed',
        'The workspace’s deps or toolchain aren’t ready, or the configured gate command isn’t installed. Run the setup script or install the tool, then re-run the gate.',
      );
    case GateErrorKind.noTests:
      return const GateErrorFraming(
        'The gate ran, but found no tests',
        'No test files matched. Add tests or check the runner’s include config. An empty suite can’t gate a merge.',
      );
    case GateErrorKind.runner:
    case null:
      return const GateErrorFraming(
        'The gate crashed',
        'The test runner errored before finishing. The log has the details. Fix the cause and re-run.',
      );
  }
}
