import '../../api/models/models.dart';

/// What the Backlog tells you when haro could not bring the checkout level with origin by
/// itself, or null when there is nothing to say (up to date, just pulled, no remote, or no
/// sync has run yet). Plain sentences, each ending in what to do or what is going on.
String? syncNotice(ProjectSync? s) {
  if (s == null) return null;
  final def = s.defaultBranch;
  return switch (s.state) {
    'other_branch' when s.behind > 0 =>
      'Checkout is on ${s.branch}, ${s.behind} behind $def: ticks may be out of date.',
    'dirty' =>
      'The checkout has uncommitted changes, so haro did not update it from $def.',
    'diverged' =>
      '$def has ${s.ahead} ${s.ahead == 1 ? 'commit' : 'commits'} that are not on origin, so it cannot be fast-forwarded.',
    'blocked' => s.detail ?? 'Git refused to fast-forward the checkout.',
    'fetch_failed' =>
      s.detail == null || s.detail!.isEmpty
          ? 'Could not reach GitHub to check for updates.'
          : 'Could not reach GitHub: ${s.detail}',
    _ => null,
  };
}

/// Whether the notice can offer "Switch to the default branch and pull".
bool canSwitchToDefault(ProjectSync? s) =>
    s != null && s.state == 'other_branch' && s.behind > 0;
