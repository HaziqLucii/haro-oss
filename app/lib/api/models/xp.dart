import 'json_util.dart';

/// `GET /xp`: the dev's XP, rank and streak, derived on the backend from the ledger.
class XpStatus {
  const XpStatus({
    this.xp = 0,
    this.level = 1,
    this.rank = 'Novice',
    this.rankStart = 0,
    this.nextRankAt,
    this.streakDays = 0,
    this.streak = const [],
    this.todayDone = false,
    this.latest,
    this.badges = const [],
  });

  final int xp;
  final int level;
  final String rank;

  /// Where the current rank begins, so the bar can show progress inside the rank.
  final int rankStart;

  /// Where the next rank begins; null at the top rank.
  final int? nextRankAt;
  final int streakDays;

  /// The last 14 local days, oldest first; the last entry is today.
  final List<bool> streak;
  final bool todayDone;
  final XpLatest? latest;
  final List<XpBadge> badges;

  /// 0..1 progress to the next rank; full at the top.
  double get progress {
    final next = nextRankAt;
    if (next == null || next <= rankStart) return 1;
    return ((xp - rankStart) / (next - rankStart)).clamp(0.0, 1.0);
  }

  factory XpStatus.fromJson(Json j) => XpStatus(
    xp: jInt(j, 'xp'),
    level: jInt(j, 'level', 1),
    rank: jStr(j, 'rank', 'Novice'),
    rankStart: jInt(j, 'rank_start'),
    nextRankAt: jIntN(j, 'next_rank_at'),
    streakDays: jInt(j, 'streak_days'),
    streak: [
      for (final v in (j['streak'] is List ? j['streak'] as List : const []))
        v == true,
    ],
    todayDone: jBool(j, 'today_done'),
    latest: j['latest'] is Map ? XpLatest.fromJson(asJson(j['latest'])) : null,
    badges: jList(j, 'badges', XpBadge.fromJson),
  );
}

class XpLatest {
  const XpLatest({
    required this.kind,
    required this.amount,
    required this.label,
    this.at,
  });

  final String kind;
  final int amount;
  final String label;
  final double? at;

  factory XpLatest.fromJson(Json j) => XpLatest(
    kind: jStr(j, 'kind'),
    amount: jInt(j, 'amount'),
    label: jStr(j, 'label'),
    at: jDoubleN(j, 'at'),
  );
}

class XpBadge {
  const XpBadge({required this.kind, required this.label});

  final String kind;
  final String label;

  factory XpBadge.fromJson(Json j) =>
      XpBadge(kind: jStr(j, 'kind'), label: jStr(j, 'label'));
}

/// One row of the award table (`GET /xp/rules`). [manual] and [agent] are the XP in each mode;
/// null means the rule does not apply in that mode.
class XpRule {
  const XpRule({
    required this.kind,
    required this.group,
    required this.label,
    required this.text,
    this.manual,
    this.agent,
    this.cap,
  });

  final String kind;

  /// `daily` | `merge` | `manual` | `badge`.
  final String group;
  final String label;
  final String text;
  final int? manual;
  final int? agent;

  /// Per-item rules: the most items that pay.
  final int? cap;

  factory XpRule.fromJson(Json j) => XpRule(
    kind: jStr(j, 'kind'),
    group: jStr(j, 'group'),
    label: jStr(j, 'label'),
    text: jStr(j, 'text'),
    manual: jIntN(j, 'manual'),
    agent: jIntN(j, 'agent'),
    cap: jIntN(j, 'cap'),
  );
}

class XpRank {
  const XpRank({required this.name, required this.at});

  final String name;
  final int at;

  factory XpRank.fromJson(Json j) =>
      XpRank(name: jStr(j, 'name'), at: jInt(j, 'at'));
}

class XpRules {
  const XpRules({
    this.rules = const [],
    this.ranks = const [],
    this.levelXp = 180,
  });

  final List<XpRule> rules;
  final List<XpRank> ranks;
  final int levelXp;

  XpRule? rule(String kind) {
    for (final r in rules) {
      if (r.kind == kind) return r;
    }
    return null;
  }

  List<XpRule> inGroup(String group) => [
    for (final r in rules)
      if (r.group == group) r,
  ];

  factory XpRules.fromJson(Json j) => XpRules(
    rules: jList(j, 'rules', XpRule.fromJson),
    ranks: jList(j, 'ranks', XpRank.fromJson),
    levelXp: jInt(j, 'level_xp', 180),
  );
}

class XpAward {
  const XpAward({
    required this.kind,
    required this.amount,
    required this.label,
    this.badge = false,
  });

  final String kind;
  final int amount;
  final String label;
  final bool badge;

  factory XpAward.fromJson(Json j) => XpAward(
    kind: jStr(j, 'kind'),
    amount: jInt(j, 'amount'),
    label: jStr(j, 'label'),
    badge: jBool(j, 'badge'),
  );
}
