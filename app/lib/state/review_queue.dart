import '../api/models/models.dart';
import 'format.dart';

String _lines(int n) {
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b changed ${plural(n, 'line')}';
}

/// `3 workspaces waiting for your review · 1,240 changed lines`, then whether the review limit is
/// reached or passed. Null when nothing waits. Counts only what is on disk against its base; it
/// says nothing about how good the work is.
String? reviewQueueLine(ReviewQueue q) {
  final n = q.workspaces.length;
  if (n == 0) return null;
  final base =
      '$n ${plural(n, 'workspace')} waiting for your review · ${_lines(q.totalLines)}';
  if (q.cap <= 0 || n < q.cap) return base;
  return n > q.cap
      ? '$base · over the review limit of ${q.cap}'
      : '$base · review limit of ${q.cap} reached';
}

/// What the line means, for its tooltip: what a changed line is, what the limit is and does, and
/// where to change it.
String reviewQueueHelp(ReviewQueue q) =>
    'Changed lines are the lines added plus removed in these workspaces, against their base '
    'branches: roughly how much there is to read. '
    '${q.cap > 0 ? 'The review limit is ${q.cap} waiting workspaces. Reaching it only adds a warning before another agent run; it never blocks one. ' : ''}'
    'Set the limit with review_cap under [agent] in ~/.haro/settings.toml (0 turns the warning off).';

/// The one-line warning under the composer before another run starts: other workspaces
/// already wait for review and the count has reached the limit. The workspace being typed in is
/// left out, since a follow-up there adds no new workspace to the pile. Null below the limit,
/// with the limit off, or with no queue.
String? reviewCapWarning(ReviewQueue? q, String workspaceId) {
  if (q == null || q.cap <= 0) return null;
  final others = [
    for (final w in q.workspaces)
      if (w.workspaceId != workspaceId) w,
  ];
  if (others.length < q.cap) return null;
  final lines = others.fold<int>(0, (a, w) => a + w.lines);
  final n = others.length;
  return '$n other ${plural(n, 'workspace')} already ${plural(n, 'waits', 'wait')} '
      'for your review (${_lines(lines)}). Another run adds to the pile.';
}
