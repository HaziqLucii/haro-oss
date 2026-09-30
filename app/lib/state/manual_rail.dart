import '../api/models/models.dart';
import 'format.dart' show relativeAgo;

/// Derivation for the manual rail (Plan, Search, Docs). Plain Dart so it stays testable.

/// The footer of the manual rail. "AI edits: 0" is provable (the assistant has read-only
/// tools and a git guard); a claim about lines of code in its text would not be.
const manualFooter = 'AI: plan and research only · AI edits: 0';

/// The same footer when the backend could not check the worktree during the run that made
/// the plan (or answer) on screen: 0 would be a claim nobody verified.
const manualFooterUnverified =
    'AI: plan and research only · AI edits: unverified';

String manualFooterFor({required bool unverified}) =>
    unverified ? manualFooterUnverified : manualFooter;

/// `tried Write, Bash: not available to haro's assistant`, or null when nothing was tried.
String? blockedCallsLine(List<String> calls) {
  final seen = <String>[];
  for (final c in calls) {
    if (c.isNotEmpty && !seen.contains(c)) seen.add(c);
  }
  if (seen.isEmpty) return null;
  return "tried ${seen.join(', ')}: not available to haro's assistant";
}

enum ManualTab {
  plan('Plan'),
  search('Search'),
  docs('Docs');

  const ManualTab(this.label);
  final String label;
}

enum PlanPhase { empty, running, review, saved }

PlanPhase planPhase({required bool running, ManualPlan? active}) {
  if (running) return PlanPhase.running;
  if (active == null) return PlanPhase.empty;
  return active.saved ? PlanPhase.saved : PlanPhase.review;
}

/// `3 / 6`.
String planProgress(ManualPlan plan) =>
    '${plan.doneCount} / ${plan.steps.length}';

/// The tab badge: progress of the shown plan, blank when there is none.
String planTabBadge(ManualPlan? plan) => plan == null || plan.steps.isEmpty
    ? ''
    : '${plan.doneCount}/${plan.steps.length}';

/// `dedupe-stripe-webhooks.md`: the name a saved plan has in the Docs list.
String planFileName(ManualPlan plan) {
  final slug = plan.title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final clipped = slug.length > 40 ? slug.substring(0, 40) : slug;
  final base = clipped.replaceAll(RegExp(r'-+$'), '');
  return '${base.isEmpty ? 'plan' : base}.md';
}

/// How many past `ask` answers the Search tab lists (the backend keeps the same ten).
const maxRecentAsks = 10;

/// `4m ago`, `just now`: the meta beside a past question.
String recentAskAgo(double epochSeconds, DateTime now) {
  final r = relativeAgo(epochSeconds, now);
  return r == 'now' ? 'just now' : '$r ago';
}

/// Left label of a result row.
String sourceLabel(String source) => switch (source) {
  'repo' => 'YOUR REPO',
  'git' => 'GIT',
  'man' => 'MAN · OFFLINE',
  'web' => 'WEB',
  'doc' => 'DOCS',
  _ => source.toUpperCase(),
};

/// Right label of a result row.
String howLabel(String action) => switch (action) {
  'open' => 'open ↗',
  'jump' => 'jump',
  'read' => 'read',
  _ => action,
};

class ResearchGroup {
  const ResearchGroup(this.source, this.rows);
  final String source;
  final List<ResearchRow> rows;
}

const _groupOrder = ['repo', 'git', 'man', 'doc', 'web'];

/// Rows grouped by source in a fixed order; order inside a group is kept.
List<ResearchGroup> groupRows(List<ResearchRow> rows) {
  final by = <String, List<ResearchRow>>{};
  for (final r in rows) {
    (by[r.source] ??= []).add(r);
  }
  final known = [
    for (final s in _groupOrder)
      if (by[s] != null) ResearchGroup(s, by[s]!),
  ];
  final rest = [
    for (final e in by.entries)
      if (!_groupOrder.contains(e.key)) ResearchGroup(e.key, e.value),
  ];
  return [...known, ...rest];
}

/// `src/a.ts:12` -> (`src/a.ts`, 12). A bare path has no line.
({String path, int? line}) parseTarget(String target) {
  final m = RegExp(r'^(.*?):(\d+)$').firstMatch(target);
  if (m == null) return (path: target, line: null);
  return (path: m.group(1)!, line: int.tryParse(m.group(2)!));
}

enum DocKind { plan, pinned, man }

class DocRef {
  const DocRef(this.kind, this.id);
  final DocKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is DocRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

class DocItem {
  const DocItem({required this.ref, required this.name, required this.meta});
  final DocRef ref;
  final String name;
  final String meta;
}

/// The Docs list: saved plans ("yours"), pinned links, man pages opened this session.
List<DocItem> docItems({
  required List<ManualPlan> plans,
  required List<PinnedDoc> pinned,
  required List<ManPage> manPages,
}) => [
  for (final p in plans)
    if (p.saved)
      DocItem(
        ref: DocRef(DocKind.plan, p.id),
        name: planFileName(p),
        meta: 'yours',
      ),
  for (final d in pinned)
    DocItem(
      ref: DocRef(DocKind.pinned, d.url),
      name: d.title,
      meta: 'web · pinned',
    ),
  for (final m in manPages)
    DocItem(ref: DocRef(DocKind.man, m.page), name: m.page, meta: 'offline'),
];

/// Only http(s) links can be pinned.
bool isPinnableUrl(String url) =>
    RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(url.trim());

/// Ship receipt row: `haro AI · 6 steps · AI edits: 0`.
String receiptPlanText(ReceiptPlan p) =>
    'haro AI · ${p.steps} step${p.steps == 1 ? '' : 's'}'
    ' · AI edits: ${p.unverified ? 'unverified' : p.aiEdits}';

String receiptResearchText(int lookups, {bool unverified = false}) =>
    '$lookups lookup${lookups == 1 ? '' : 's'}'
    '${unverified ? ' · AI edits: unverified' : ''}';
