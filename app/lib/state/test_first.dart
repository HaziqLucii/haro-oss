import '../api/models/models.dart';

// Test-first tasks (backlog/test-first.md), derived as plain functions like the rest of the
// flow: the agent drafts an acceptance test, the backend proves it fails on base, the dev
// approves it, and the gate holds the build to it. The verdicts (red on base, unchanged,
// passing) all come from the backend running real code; nothing here decides green or red.

/// The phases where the dev has to act: the proven-red test awaits approval, or the draft
/// was rejected and needs a redraft.
bool testFirstNeedsYou(TestFirstState? tf) =>
    tf != null &&
    (tf.phase == TestFirstPhase.review || tf.phase == TestFirstPhase.rejected);

/// Drafting or proving: the backend is working, nothing for the dev to do.
bool testFirstRunning(TestFirstState? tf) =>
    tf != null &&
    (tf.phase == TestFirstPhase.drafting || tf.phase == TestFirstPhase.proving);

bool testFirstApproved(TestFirstState? tf) =>
    tf != null && tf.phase == TestFirstPhase.approved;

String _tests(int n) => n == 1 ? 'test' : 'tests';

/// `2 tests, every one failing on base`.
String redProofHeadline(TestFirstState tf) {
  final n = tf.cases.length;
  return n == 1
      ? '1 test, failing on base'
      : '$n ${_tests(n)}, every one failing on base';
}

/// The sentence that opens a rejection reason, for a triage row.
String shortRejectReason(String? reason) {
  final r = (reason ?? '').trim();
  if (r.isEmpty) return 'the draft was rejected';
  final end = r.indexOf(RegExp(r'[.:]\s'));
  return end == -1 ? r : r.substring(0, end);
}

/// The triage row's detail line for a test-first workspace that needs the dev, or null.
String? acceptanceRowDetail(TestFirstState? tf) {
  if (tf == null) return null;
  return switch (tf.phase) {
    TestFirstPhase.review =>
      'Acceptance test ready to approve · ${tf.cases.length} red on base',
    TestFirstPhase.rejected =>
      'Acceptance draft rejected · ${shortRejectReason(tf.rejectReason)}',
    _ => null,
  };
}

/// The agent step's status line while test-first owns the step.
String? acceptanceStepLine(TestFirstState? tf, {Duration? elapsed}) {
  if (tf == null) return null;
  final t = elapsed == null ? '' : ' · ${_dur(elapsed)}';
  return switch (tf.phase) {
    TestFirstPhase.drafting => 'drafting test$t',
    TestFirstPhase.proving => 'proving test is red',
    TestFirstPhase.review => 'test ready',
    TestFirstPhase.rejected => 'test rejected',
    _ => null,
  };
}

String _dur(Duration d) => d.inMinutes >= 1
    ? '${d.inMinutes}m'
    : '${d.inSeconds < 0 ? 0 : d.inSeconds}s';

String _clock(double epochSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).round())
      .toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

/// `Acceptance test (approved 14:32): 2/2 passing, unchanged.` Mirrors the backend receipt.
String? acceptanceReceiptLine(AcceptanceCheck? c) {
  if (c == null) return null;
  final when = c.approvedAt == null ? '?' : _clock(c.approvedAt!);
  final head =
      'Acceptance test (approved $when): ${c.passing}/${c.total} passing';
  if (c.ok) return '$head, unchanged.';
  final bits = [
    if (c.changed.isNotEmpty) 'file changed: ${c.changed.join(', ')}',
    if (c.missing.isNotEmpty) 'missing: ${c.missing.join(', ')}',
    if (c.failing.isNotEmpty) 'failing: ${c.failing.join(', ')}',
  ];
  return '$head, ${bits.join('; ')}.';
}

/// What the ship blocker says when the approved acceptance test is why the gate is red.
String acceptanceBlockText(AcceptanceCheck? c) {
  if (c == null) return 'the approved acceptance test is not intact';
  if (c.changed.isNotEmpty) {
    return 'the approved acceptance test changed after approval (${c.changed.join(', ')})';
  }
  if (c.missing.isNotEmpty) {
    return 'the approved acceptance test is missing from the run (${c.missing.join(', ')})';
  }
  if (c.failing.isNotEmpty) {
    return 'the approved acceptance test is failing (${c.failing.join(', ')})';
  }
  return 'the approved acceptance test is not intact';
}

/// The added lines of each drafted file, read from the unified diff. The draft is a new file,
/// so every line is an addition; a file the diff does not show yet maps to an empty list.
Map<String, List<String>> acceptanceDiffLines(
  String diffText,
  List<AcceptanceFile> files,
) {
  final wanted = {for (final f in files) f.path};
  final out = {for (final f in files) f.path: <String>[]};
  String? current;
  var inHunk = false;
  for (final line in diffText.split('\n')) {
    if (line.startsWith('diff --git ')) {
      current = null;
      inHunk = false;
    } else if (line.startsWith('+++ ')) {
      final p = line.substring(4).trim();
      final path = p.startsWith('b/') ? p.substring(2) : p;
      current = wanted.contains(path) ? path : null;
    } else if (line.startsWith('@@')) {
      inHunk = true;
    } else if (inHunk && current != null && line.startsWith('+')) {
      out[current]!.add(line.substring(1));
    }
  }
  return out;
}
