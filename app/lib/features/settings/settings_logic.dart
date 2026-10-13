import '../../api/models/models.dart';

/// A role is stored as `model:effort` (`opus:high`), `haiku`, or empty for "Agent default".
(String model, String effort) splitRole(String shorthand) {
  final i = shorthand.indexOf(':');
  if (i < 0) return (shorthand, '');
  return (shorthand.substring(0, i), shorthand.substring(i + 1));
}

/// Effort to carry over when the model changes. Haiku rejects `xhigh` and `max`.
String effortFor(String model, String effort) =>
    model == 'haiku' && (effort == 'xhigh' || effort == 'max')
    ? 'high'
    : effort;

String joinRole(String model, String effort) =>
    model.isEmpty ? '' : (effort.isEmpty ? model : '$model:$effort');

const roleDefaults = (plan: 'opus:high', build: 'sonnet:high', scout: 'haiku');

/// Turning roles on with nothing picked fills the sensible picks instead of leaving every
/// step on "Agent default".
RolesConfig enableRoles(RolesConfig c) {
  final empty = c.plan.isEmpty && c.build.isEmpty && c.scout.isEmpty;
  return RolesConfig.fromJson({
    ...c.toJson(),
    'enabled': true,
    if (empty) ...{
      'plan': roleDefaults.plan,
      'build': roleDefaults.build,
      'scout': roleDefaults.scout,
    },
  });
}

/// The `[roles]` block this config writes, for "View config".
String rolesToml(RolesConfig c) {
  String q(String s) => '"$s"';
  final lines = <String>[
    if (c.enabled) 'enabled = true',
    if (c.plan.isNotEmpty) 'plan = ${q(c.plan)}',
    if (c.build.isNotEmpty) 'build = ${q(c.build)}',
    if (c.review.isNotEmpty) 'review = ${q(c.review)}',
    if (c.scout.isNotEmpty) 'scout = ${q(c.scout)}',
    if (c.opencodePlan.isNotEmpty) 'opencode_plan = ${q(c.opencodePlan)}',
    if (c.opencodeBuild.isNotEmpty) 'opencode_build = ${q(c.opencodeBuild)}',
    if (c.opencodeReview.isNotEmpty) 'opencode_review = ${q(c.opencodeReview)}',
    if (c.opencodeScout.isNotEmpty) 'opencode_scout = ${q(c.opencodeScout)}',
  ];
  return lines.isEmpty ? '# [roles] off' : '[roles]\n${lines.join('\n')}';
}

String cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// "Resets in 2h 14m" / "Resets in 3d 4h" for a usage window; null when unknown.
String? resetLabel(String? iso, {DateTime? now}) {
  if (iso == null) return null;
  final at = DateTime.tryParse(iso);
  if (at == null) return null;
  final ms = at.difference(now ?? DateTime.now()).inMilliseconds;
  if (ms <= 0) return 'Resetting…';
  final m = ms ~/ 60000;
  final d = m ~/ 1440;
  final h = (m % 1440) ~/ 60;
  final mm = m % 60;
  if (d > 0) return 'Resets in ${d}d ${h}h';
  if (h > 0) return 'Resets in ${h}h ${mm}m';
  return 'Resets in ${mm}m';
}

/// Why Usage has nothing to show, in a sentence with a next step.
String usageUnavailable(String? reason) => switch (reason) {
  'no_credentials' => 'No Claude Code login found on this machine. Sign in with `claude` (or run an agent), then retry.',
  'token_expired' => 'Your Claude Code token has expired. Run any agent, or `claude` in a terminal, to refresh it, then retry.',
  _ => 'Could not reach the usage service. Check your connection, then retry.',
};
