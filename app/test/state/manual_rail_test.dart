import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/manual_rail.dart';

ManualPlan plan({
  String id = 'plan_1',
  String title = 'Dedupe Stripe webhooks!',
  List<bool> done = const [true, false, false],
  bool saved = false,
}) => ManualPlan(
  id: id,
  title: title,
  saved: saved,
  steps: [
    for (final (i, d) in done.indexed) PlanStep(text: 'step $i', done: d),
  ],
);

void main() {
  group('plan phase', () {
    test('running wins, then the plan decides', () {
      expect(planPhase(running: false), PlanPhase.empty);
      expect(planPhase(running: true, active: plan()), PlanPhase.running);
      expect(planPhase(running: false, active: plan()), PlanPhase.review);
      expect(
        planPhase(running: false, active: plan(saved: true)),
        PlanPhase.saved,
      );
    });

    test('progress and tab badge', () {
      expect(planProgress(plan()), '1 / 3');
      expect(planTabBadge(plan()), '1/3');
      expect(planTabBadge(null), '');
      expect(planTabBadge(plan(done: const [])), '');
    });

    test('file name is a slug with .md', () {
      expect(planFileName(plan()), 'dedupe-stripe-webhooks.md');
      expect(planFileName(plan(title: '  !!  ')), 'plan.md');
      expect(planFileName(plan(title: 'a' * 80)).length, 43);
    });
  });

  group('search rows', () {
    const rows = [
      ResearchRow(
        source: 'web',
        title: 'w',
        target: 'https://x',
        action: 'open',
      ),
      ResearchRow(
        source: 'repo',
        title: 'r1',
        target: 'a.ts:1',
        action: 'jump',
      ),
      ResearchRow(source: 'man', title: 'm', target: 'ls(1)', action: 'read'),
      ResearchRow(
        source: 'repo',
        title: 'r2',
        target: 'b.ts:2',
        action: 'jump',
      ),
      ResearchRow(source: 'git', title: 'g', target: 'a.ts', action: 'jump'),
      ResearchRow(source: 'zzz', title: 'z', target: 'z'),
    ];

    test('groups by source in a fixed order, keeping order inside a group', () {
      final g = groupRows(rows);
      expect(
        [for (final x in g) x.source],
        ['repo', 'git', 'man', 'web', 'zzz'],
      );
      expect([for (final r in g.first.rows) r.title], ['r1', 'r2']);
      expect(groupRows(const []), isEmpty);
    });

    test('labels match the design', () {
      expect(sourceLabel('repo'), 'YOUR REPO');
      expect(sourceLabel('man'), 'MAN · OFFLINE');
      expect(howLabel('open'), 'open ↗');
      expect(howLabel('jump'), 'jump');
      expect(howLabel('read'), 'read');
    });

    test('a target splits into path and line', () {
      expect(parseTarget('src/a.ts:12'), (path: 'src/a.ts', line: 12));
      expect(parseTarget('src/a.ts'), (path: 'src/a.ts', line: null));
      expect(parseTarget('a:b.ts:3'), (path: 'a:b.ts', line: 3));
    });
  });

  group('docs list', () {
    test('saved plans, pinned links and man pages, never an unsaved plan', () {
      final items = docItems(
        plans: [
          plan(saved: true),
          plan(id: 'plan_2', title: 'draft'),
        ],
        pinned: const [PinnedDoc(title: 'Stripe API', url: 'https://s.io')],
        manPages: const [ManPage(page: 'ls(1)', text: 'x')],
      );
      expect(
        [for (final i in items) i.name],
        ['dedupe-stripe-webhooks.md', 'Stripe API', 'ls(1)'],
      );
      expect(
        [for (final i in items) i.meta],
        ['yours', 'web · pinned', 'offline'],
      );
      expect(items.first.ref, const DocRef(DocKind.plan, 'plan_1'));
    });

    test('only http and https links can be pinned', () {
      expect(isPinnableUrl('https://docs.stripe.com/api'), isTrue);
      expect(isPinnableUrl(' http://x.io '), isTrue);
      expect(isPinnableUrl('javascript:alert(1)'), isFalse);
      expect(isPinnableUrl('file:///etc/passwd'), isFalse);
      expect(isPinnableUrl('https://a b'), isFalse);
    });
  });

  test('footer says what the assistant did and did not do', () {
    expect(manualFooter, 'AI: plan and research only · AI edits: 0');
    expect(manualFooter.toLowerCase(), isNot(contains('agent')));
    expect(manualFooter.toLowerCase(), isNot(contains('lines of code')));
  });

  test('unverified footer and blocked-call line', () {
    expect(manualFooterFor(unverified: false), manualFooter);
    expect(
      manualFooterFor(unverified: true),
      'AI: plan and research only \u00b7 AI edits: unverified',
    );
    expect(blockedCallsLine(const []), isNull);
    expect(
      blockedCallsLine(const ['Write', 'Bash', 'Write']),
      "tried Write, Bash: not available to haro's assistant",
    );
  });

  test('an unverified receipt never says 0', () {
    expect(
      receiptPlanText(const ReceiptPlan(plans: 1, steps: 6, unverified: true)),
      'haro AI \u00b7 6 steps \u00b7 AI edits: unverified',
    );
    expect(
      receiptResearchText(2, unverified: true),
      '2 lookups \u00b7 AI edits: unverified',
    );
    expect(receiptResearchText(2), '2 lookups');
  });

  test('receipt lines', () {
    expect(
      receiptPlanText(const ReceiptPlan(plans: 1, steps: 6)),
      'haro AI · 6 steps · AI edits: 0',
    );
    expect(
      receiptPlanText(const ReceiptPlan(plans: 1, steps: 1)),
      'haro AI · 1 step · AI edits: 0',
    );
    expect(receiptResearchText(1), '1 lookup');
    expect(receiptResearchText(4), '4 lookups');
  });
}
