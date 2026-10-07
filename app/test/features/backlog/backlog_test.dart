import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:haro_app/features/open_in/open_in_notice.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/backlog/backlog_model.dart';
import 'package:haro_app/features/backlog/backlog_overlay.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../creation_harness.dart';

Map<String, dynamic> itemJson(
  String text, {
  bool done = false,
  String? seeded,
  String? stage,
  String heading = 'Build',
  String? body,
}) => {
  'kind': 'item',
  'heading': heading,
  'text': text,
  'done': done,
  'body': body ?? text,
  'seed_key': 'k::$text',
  'seeded_workspace': seeded,
  'stage': stage,
};

Map<String, dynamic> fileJson(
  String path,
  List<Map<String, dynamic>> items, {
  String? title,
  String? summary,
}) => {
  'path': path,
  'label': path.split('/').last,
  'items': items,
  'blocks': [
    if (title != null)
      {
        'kind': 'note',
        'md':
            '# TODO - $title\n\n'
            '${summary == null ? '' : '> $summary\n\n'}## Build',
      },
    ...items,
  ],
  'content': '',
  'done': items.where((i) => i['done'] == true).length,
  'pending': items.where((i) => i['done'] != true).length,
};

final todoBody = {
  'files': [
    fileJson('backlog/agent-modes.md', [
      itemJson('Plan flag', done: true),
      itemJson('Approval UI', done: true),
    ], title: 'Agent modes'),
    fileJson('backlog/desktop.md', [
      itemJson('Tray icon'),
      itemJson('Auto update'),
    ], title: 'Desktop'),
    fileJson(
      'backlog/live-gate.md',
      [
        itemJson('Stream **cells** as tests finish', done: true),
        itemJson(
          'Show the first `failure` at once',
          body: 'Full brief\n```dart\ncode\n```',
        ),
        itemJson('Second open item'),
        itemJson('Already running', seeded: 'ws_9', stage: 'green'),
      ],
      title: 'Live gate: stream results as tests finish',
      summary:
          '**Today** the verdict appears only when the whole suite is done.',
    ),
  ],
  'orphaned': <Object>[],
};

Map<String, dynamic> issue(
  int n,
  String title, {
  List<String> labels = const [],
  String state = 'open',
  String body = '',
  String? seeded,
}) => {
  'number': n,
  'title': title,
  'body': body,
  'state': state,
  'labels': labels,
  'url': 'https://github.com/o/r/issues/$n',
  'seed_key': 'issue-$n',
  'seeded_workspace': seeded,
  'stage': null,
};

MockBackend backend({
  Map<String, dynamic>? todo,
  Map<String, dynamic> Function(Call)? issues,
  Map<String, dynamic>? sync,
}) => MockBackend({
  'GET /projects/p1/todo': (_) => jsonRes(todo ?? todoBody),
  if (sync != null) 'POST /projects/p1/sync': (_) => jsonRes(sync),
  if (sync != null)
    'POST /projects/p1/sync/switch': (_) => jsonRes({
      ...sync,
      'state': 'pulled',
      'branch': 'main',
      'pulled': 17,
      'behind': 0,
    }),
  'GET /projects/p1/issues': (c) => jsonRes(
    (issues ??
        (c) => {
          'available': true,
          'issues': c.query['state'] == 'closed'
              ? [issue(3, 'Old thing', state: 'closed')]
              : [
                  issue(
                    41,
                    'Fix: shipping total rounds down',
                    labels: ['bug'],
                    body: 'Half cents.',
                  ),
                  issue(12, '[MO] - ACUVUE pop-up', labels: ['ui', 'bug']),
                  issue(7, 'Docs for gate', labels: ['docs']),
                ],
        })(c),
  ),
  'GET /projects/p1/issues/*': (c) => jsonRes(
    c.path.endsWith('/41')
        ? {
            'available': true,
            'number': 41,
            'title': 'Fix: shipping total rounds down',
            'body': 'Half cents.',
            'state': 'open',
            'url': 'https://github.com/o/r/issues/41',
            'labels': ['bug'],
            'comments': [
              {
                'author': 'ana',
                'body': 'Reproduced on main.',
                'created_at': '2026-09-01',
              },
            ],
          }
        : {'available': true, 'number': 0, 'comments': []},
  ),
  'GET /projects/p1/branches': (_) => jsonRes({
    'branches': ['origin/main'],
    'default': 'origin/main',
  }),
  'POST /projects/p1/workspaces': (_) => jsonRes(createdWorkspace()),
});

Future<Harness> open(WidgetTester tester, MockBackend b) => pumpCreation(
  tester,
  backend: b,
  projects: [project('p1', 'haro')],
  open: (c) => showBacklog(c),
);

TodoFile fileOf(List<Map<String, dynamic>> items) =>
    TodoFile.fromJson(fileJson('backlog/x.md', items));

double barWidth(WidgetTester tester, String path) => tester
    .widget<FractionallySizedBox>(
      find.descendant(
        of: find.byKey(Key('bl-bar-$path')),
        matching: find.byType(FractionallySizedBox),
      ),
    )
    .widthFactor!;

void main() {
  setUpAll(loadBrandFonts);

  group('model', () {
    test('category: none done, some done, all done', () {
      expect(
        categoryOf(fileOf([itemJson('a'), itemJson('b')])),
        TodoCategory.todo,
      );
      expect(
        categoryOf(fileOf([itemJson('a', done: true), itemJson('b')])),
        TodoCategory.active,
      );
      expect(
        categoryOf(fileOf([itemJson('a', done: true)])),
        TodoCategory.done,
      );
      expect(categoryOf(fileOf(const [])), TodoCategory.todo);
    });

    test('progress is done over total, zero for an empty file', () {
      expect(
        progressOf(
          fileOf([
            itemJson('a', done: true),
            itemJson('b'),
            itemJson('c'),
            itemJson('d'),
          ]),
        ),
        .25,
      );
      expect(progressOf(fileOf(const [])), 0);
    });

    test('groups keep the order In progress, Not started, Done and drop empty ones', () {
      final files = TodoResponse.fromJson(todoBody).files;
      final groups = groupTodoFiles(files);
      expect(groups.map((g) => g.category), [
        TodoCategory.active,
        TodoCategory.todo,
        TodoCategory.done,
      ]);
      expect(groups.first.files.single.label, 'live-gate.md');
      expect(groupTodoFiles([files.last]).map((g) => g.category), [
        TodoCategory.active,
      ]);
    });

    test('next startable skips done, seeded and unkeyed items', () {
      final f = fileOf([
        itemJson('done', done: true),
        itemJson('running', seeded: 'ws'),
        itemJson('open'),
      ]);
      expect(nextStartable(f)!.text, 'open');
      expect(nextStartable(fileOf([itemJson('x', done: true)])), isNull);
    });

    test('title drops the TODO lead, summary is the first paragraph', () {
      final f = TodoFile.fromJson(
        fileJson(
          'backlog/a.md',
          const [],
          title: 'Live gate',
          summary: 'Why it exists.',
        ),
      );
      expect(fileTitle(f), 'Live gate');
      expect(fileSummary(f), 'Why it exists.');
      expect(fileTitle(fileOf(const [])), 'x');
      final dashed = TodoFile.fromJson({
        ...fileJson('backlog/b.md', const []),
        'blocks': [
          {'kind': 'note', 'md': '# TODO \u2014 Agent modes\n\nBody.'},
        ],
      });
      expect(fileTitle(dashed), 'Agent modes');
      expect(fileSummary(fileOf(const [])), '');
    });

    test(
      'todo prefill: short title, full body plus the file reference, seed key',
      () {
        final item = TodoItem.fromJson(
          itemJson('**Adapter flag** - add a param', body: 'Full body'),
        );
        final p = todoPrefill(item, 'backlog/agent-modes.md');
        expect(p.title, 'Adapter flag');
        expect(p.task, 'Full body\n\nReference: backlog/agent-modes.md');
        expect(p.seedKey, item.seedKey);
      },
    );

    test('issue prefill strips a leading [TAG] and references the number', () {
      final p = issuePrefill(
        IssueItem.fromJson(issue(12, '[MO] - ACUVUE pop-up', body: 'Body')),
      );
      expect(p.title, 'ACUVUE pop-up');
      expect(p.task, 'Body\n\nReference: #12');
      expect(p.seedKey, 'issue-12');
      expect(issueSeedName('[MO]'), '[MO]');
    });

    test('issue filters: query over number, title and label; label chips', () {
      final all = [
        IssueItem.fromJson(issue(41, 'Gate flake', labels: ['bug', 'ci'])),
        IssueItem.fromJson(issue(7, 'Docs', labels: ['docs'])),
        IssueItem.fromJson(issue(8, 'More bugs', labels: ['bug'])),
      ];
      expect(filterIssues(all, query: 'FLAKE').map((i) => i.number), [41]);
      expect(filterIssues(all, query: '7').map((i) => i.number), [7]);
      expect(filterIssues(all, query: 'ci').map((i) => i.number), [41]);
      expect(filterIssues(all, label: 'bug').map((i) => i.number), [41, 8]);
      expect(labelCountsOf(all), [('bug', 2), ('ci', 1), ('docs', 1)]);
    });
  });

  testWidgets(
    'todo tab: groups, bars, counts, and the first open file selected',
    (tester) async {
      final b = backend();
      await open(tester, b);
      expect(tester.takeException(), isNull);

      expect(find.text('IN PROGRESS'), findsWidgets);
      expect(find.text('NOT STARTED'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('Todo files 3'), findsOneWidget);
      expect(find.text('3 / 8 ITEMS DONE'), findsOneWidget);

      final order = ['live-gate.md', 'desktop.md', 'agent-modes.md'];
      final ys = [for (final n in order) tester.getTopLeft(find.text(n)).dy];
      expect(ys, [...ys]..sort());

      expect(barWidth(tester, 'backlog/live-gate.md'), .25);
      expect(barWidth(tester, 'backlog/desktop.md'), 0);
      expect(barWidth(tester, 'backlog/agent-modes.md'), 1);

      expect(
        find.text('Live gate: stream results as tests finish'),
        findsOneWidget,
      );
      expect(find.text('backlog/live-gate.md · 1 of 4 done'), findsOneWidget);
      expect(find.text('edit in your editor ↗'), findsOneWidget);
    },
  );

  group('checkout sync notice', () {
    final behind = {
      'state': 'other_branch',
      'branch': 'docs/client-planning',
      'default_branch': 'main',
      'behind': 17,
      'ahead': 0,
      'pulled': 0,
    };

    testWidgets(
      'asks the backend to sync on open and shows nothing when level',
      (tester) async {
        final b = backend(
          sync: {'state': 'up_to_date', 'default_branch': 'main'},
        );
        await open(tester, b);
        expect(b.where('POST', '/projects/p1/sync'), hasLength(1));
        expect(find.byKey(const ValueKey('bl-sync-notice')), findsNothing);
      },
    );

    testWidgets('another branch: says how far behind and offers the switch', (
      tester,
    ) async {
      final b = backend(sync: behind);
      await open(tester, b);
      expect(find.byKey(const ValueKey('bl-sync-notice')), findsOneWidget);
      expect(
        find.text(
          'Checkout is on docs/client-planning, 17 behind main: ticks may be out of date.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('bl-sync-switch')));
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/sync/switch'), hasLength(1));
      expect(find.byKey(const ValueKey('bl-sync-notice')), findsNothing);
    });

    testWidgets('a dirty checkout is described with no button', (tester) async {
      final b = backend(sync: {'state': 'dirty', 'default_branch': 'main'});
      await open(tester, b);
      expect(find.textContaining('uncommitted changes'), findsOneWidget);
      expect(find.byKey(const ValueKey('bl-sync-switch')), findsNothing);
    });
  });

  testWidgets(
    'selecting a file swaps the pane; the edit link goes to the editor',
    (tester) async {
      await open(tester, backend());
      await tester.tap(find.text('desktop.md'));
      await tester.pumpAndSettle();
      expect(find.text('backlog/desktop.md · 0 of 2 done'), findsOneWidget);
      await tester.tap(find.text('edit in your editor ↗'));
      await tester.pumpAndSettle();
      // This backend has no /editors route, so the launcher reports it beside the link
      // for the file that was clicked.
      expect(
        find.byKey(const ValueKey('open-in-notice-project:backlog/desktop.md')),
        findsOneWidget,
      );
      await tester.pump(openInNoticeDuration);
    },
  );

  testWidgets(
    'Start as workspace opens New workspace pre-filled and seeds the create',
    (tester) async {
      final b = backend();
      final h = await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-start')));
      await tester.pumpAndSettle();

      expect(find.text('Backlog'), findsNothing);
      final task = tester.widget<TextField>(find.byKey(const Key('nw-task')));
      expect(task.controller!.text, 'Show the first failure at once');

      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();

      final post = b.where('POST', '/projects/p1/workspaces').single;
      expect(post.body!['seed_key'], 'k::Show the first `failure` at once');
      expect(post.body!['name'], 'Show the first failure at once');
      expect(
        h.started.single.$2,
        'Full brief\n```dart\ncode\n```\n\nReference: backlog/live-gate.md',
      );
      expect(h.location, '/w/ws_new/agent');
    },
  );

  testWidgets('picking a different open item changes what gets started', (
    tester,
  ) async {
    await open(tester, backend());
    await tester.tap(find.text('Second open item'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bl-start')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('nw-task')))
          .controller!
          .text,
      'Second open item',
    );
  });

  testWidgets('a file with nothing left to start disables the action', (
    tester,
  ) async {
    await open(tester, backend());
    await tester.tap(find.text('agent-modes.md'));
    await tester.pumpAndSettle();
    final button = tester.widget<HaroButton>(find.byKey(const Key('bl-start')));
    expect(button.onPressed, isNull);
  });

  testWidgets('issues tab: fetches open issues, filters, refetches by state', (
    tester,
  ) async {
    final b = backend();
    await open(tester, b);
    expect(b.where('GET', '/projects/p1/issues'), isEmpty);

    await tester.tap(find.text('GitHub issues'));
    await tester.pumpAndSettle();
    expect(b.where('GET', '/projects/p1/issues').single.query['state'], 'open');
    expect(find.text('GitHub issues 3'), findsOneWidget);
    expect(find.text('Fix: shipping total rounds down'), findsWidgets);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('bl-search')),
        matching: find.byType(TextField),
      ),
      'acuvue',
    );
    await tester.pump();
    expect(find.text('Docs for gate'), findsNothing);
    expect(find.text('[MO] - ACUVUE pop-up'), findsWidgets);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('bl-search')),
        matching: find.byType(TextField),
      ),
      '',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('bl-label-docs')));
    await tester.pump();
    expect(find.text('Fix: shipping total rounds down'), findsNothing);
    expect(find.text('Docs for gate'), findsWidgets);
    await tester.tap(find.byKey(const Key('bl-label-docs')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('bl-state-closed')));
    await tester.pumpAndSettle();
    expect(b.where('GET', '/projects/p1/issues').last.query['state'], 'closed');
    expect(find.text('Old thing'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'issue detail shows the discussion; Start as workspace pre-fills from it',
    (tester) async {
      final b = backend();
      await open(tester, b);
      await tester.tap(find.text('GitHub issues'));
      await tester.pumpAndSettle();

      expect(find.text('Reproduced on main.'), findsOneWidget);
      expect(find.text('1 COMMENT'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bl-start')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('nw-task')))
            .controller!
            .text,
        'Fix: shipping total rounds down',
      );
    },
  );

  testWidgets('issues without gh or a remote say so', (tester) async {
    final b = backend(
      issues: (_) => {'available': false, 'reason': 'no-gh', 'issues': []},
    );
    await open(tester, b);
    await tester.tap(find.text('GitHub issues'));
    await tester.pumpAndSettle();
    expect(
      find.text('Install the GitHub CLI (gh) to pull issues.'),
      findsOneWidget,
    );
  });

  group('wrong-account hint on a failed issues load', () {
    const graphql =
        "GraphQL: Could not resolve to a Repository with the name 'acme/widgets'.";

    MockBackend failing(
      String reason, {
      http.Response Function(Call)? account,
    }) => MockBackend({
      'GET /projects/p1/todo': (_) => jsonRes(todoBody),
      'GET /projects/p1/issues': (_) =>
          jsonRes({'available': false, 'reason': reason, 'issues': []}),
      'GET /projects/p1/gh-account': ?account,
    });

    testWidgets('names the account that was used', (tester) async {
      final b = failing(
        graphql,
        account: (_) => jsonRes({
          'override': null,
          'resolved': 'HaziqLucii',
          'source': 'default',
        }),
      );
      await open(tester, b);
      await tester.tap(find.text('GitHub issues'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't load issues"), findsOneWidget);
      expect(
        find.text(
          'Signed in as HaziqLucii. Switch account from the avatar menu.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('still points at the menu when the account lookup fails', (
      tester,
    ) async {
      final b = failing(graphql, account: (_) => errorRes('nope', 500));
      await open(tester, b);
      await tester.tap(find.text('GitHub issues'));
      await tester.pumpAndSettle();
      expect(find.text('Switch account from the avatar menu.'), findsOneWidget);
    });

    testWidgets('an HTTP 404 error gets the hint too', (tester) async {
      final b = MockBackend({
        'GET /projects/p1/todo': (_) => jsonRes(todoBody),
        'GET /projects/p1/issues': (_) => errorRes('HTTP 404: Not Found', 404),
        'GET /projects/p1/gh-account': (_) =>
            jsonRes({'resolved': 'work', 'source': 'auto'}),
      });
      await open(tester, b);
      await tester.tap(find.text('GitHub issues'));
      await tester.pumpAndSettle();
      expect(
        find.text('Signed in as work. Switch account from the avatar menu.'),
        findsOneWidget,
      );
    });

    testWidgets('other failures get no hint and no account lookup', (
      tester,
    ) async {
      final b = failing('rate limit exceeded');
      await open(tester, b);
      await tester.tap(find.text('GitHub issues'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't load issues"), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-hint')), findsNothing);
      expect(b.where('GET', '/projects/p1/gh-account'), isEmpty);
    });
  });

  testWidgets('no overflow at 960x640 on either tab', (tester) async {
    await open(tester, backend());
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('GitHub issues'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
