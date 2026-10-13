import '../../api/models/models.dart';

enum PullTone { ok, note, fail }

/// The one-line answer the Projects table gives for a project's checkout, from the project
/// and the newest sync result. [detail] is the longer explanation for a tooltip.
({String text, PullTone tone, String? detail}) pullStatus(
  Project p,
  ProjectSync? s,
) {
  if (p.remoteUrl == null) {
    return (text: 'local only', tone: PullTone.note, detail: null);
  }
  final state = s?.state;
  if (state == null) {
    return (text: 'not checked yet', tone: PullTone.note, detail: null);
  }
  final target = s!.defaultBranch;
  return switch (state) {
    'up_to_date' => (
      text: 'up to date',
      tone: PullTone.ok,
      detail: 'On $target, level with origin.',
    ),
    'pulled' => (
      text: 'pulled ${s.pulled} ${s.pulled == 1 ? 'commit' : 'commits'}',
      tone: PullTone.ok,
      detail: 'Fast-forwarded $target to origin.',
    ),
    'other_branch' => (
      text: s.behind > 0
          ? 'on ${s.branch}, ${s.behind} behind'
          : 'on ${s.branch}',
      tone: PullTone.note,
      detail:
          'The checkout is on ${s.branch}, not $target, so haro left it alone.',
    ),
    'dirty' => (
      text: 'uncommitted changes',
      tone: PullTone.note,
      detail: 'Commit or stash them, then pull again.',
    ),
    'diverged' => (
      text: 'diverged from origin',
      tone: PullTone.fail,
      detail:
          '$target has ${s.ahead} ${s.ahead == 1 ? 'commit' : 'commits'} that are not on origin, so it cannot be fast-forwarded.',
    ),
    'blocked' => (
      text: 'blocked',
      tone: PullTone.fail,
      detail: s.detail ?? 'Git refused to fast-forward the checkout.',
    ),
    'fetch_failed' => (
      text: "can't reach origin",
      tone: PullTone.fail,
      detail: s.detail,
    ),
    'branch_missing' => (
      text: 'no such branch on origin',
      tone: PullTone.fail,
      detail: s.detail,
    ),
    'no_remote' => (text: 'local only', tone: PullTone.note, detail: null),
    _ => (text: state, tone: PullTone.note, detail: null),
  };
}
