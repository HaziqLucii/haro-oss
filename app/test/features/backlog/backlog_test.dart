import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:haro_app/features/open_in/open_in_notice.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/backlog/backlog_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/features/backlog/backlog_page.dart';
import 'package:haro_app/features/backlog/capture_todo_overlay.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/haro_text_field.dart';

import '../creation_harness.dart';

Map<String, dynamic> itemJson(
  String text, {
  bool done = false,
  String? seeded,
  String? stage,
  String heading = 'Build',
  String? body,
  int depth = 0,
  int children = 0,
}) => {
  'kind': 'item',
  'heading': heading,
  'text': text,
  'done': done,
  'body': body ?? text,
  'seed_key': 'k::$text',
  'seeded_workspace': seeded,
  'stage': stage,
  'depth': depth,
  'children': children,
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
  open: (c) => Navigator.of(c).push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: BacklogPage()),
    ),
  ),
);

class _MutableStore extends WorkspaceStore {
  _MutableStore(this.initial);

  final WorkspaceSnapshot initial;

  @override
  WorkspaceSnapshot build() => initial;

  void set(WorkspaceSnapshot next) => state = next;

  @override
  Future<void> reload() async {}
}

/// The whole app (real router, shell and sidebar) on [location], for the page-level tests.
Future<GoRouter> pumpShell(
  WidgetTester tester,
  MockBackend b,
  List<Project> projects, {
  String location = '/',
  Size size = const Size(1280, 800),
  WorkspaceStore? store,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(initialLocation: location);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haroApiProvider.overrideWithValue(b.api),
        workspaceStoreProvider.overrideWith(
          () => store ?? FakeStore(snapshotOf(projects, {})),
        ),
        devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
        backendStatusProvider.overrideWith(
          (ref) => Stream.value(BackendStatus.up),
        ),
      ],
      child: HaroApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

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
      expect(
        find.descendant(
          of: find.byKey(const Key('bl-tab-todo')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
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

  testWidgets('the project pills list every project and switch the backlog', (
    tester,
  ) async {
    final b = backend();
    b.routes['GET /projects/p2/todo'] = (_) =>
        jsonRes({'files': [], 'orphaned': []});
    await pumpCreation(
      tester,
      backend: b,
      projects: [project('p1', 'haro'), project('p2', 'sandbox')],
      open: (c) => Navigator.of(c).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: BacklogPage()),
        ),
      ),
    );
    expect(find.byKey(const Key('bl-project-p1')), findsOneWidget);
    expect(find.byKey(const Key('bl-project-p2')), findsOneWidget);
    expect(b.where('GET', '/projects/p2/todo'), isEmpty);
    await tester.tap(find.byKey(const Key('bl-project-p2')));
    await tester.pumpAndSettle();
    expect(b.where('GET', '/projects/p2/todo'), hasLength(1));
    expect(find.text('No backlog files.'), findsOneWidget);
  });

  testWidgets('a project given in the URL is the one shown', (tester) async {
    final b = backend();
    b.routes['GET /projects/p2/todo'] = (_) =>
        jsonRes({'files': [], 'orphaned': []});
    await pumpShell(tester, b, [
      project('p1', 'haro'),
      project('p2', 'sandbox'),
    ], location: '/backlog?project=p2');
    expect(b.where('GET', '/projects/p2/todo'), hasLength(1));
    expect(b.where('GET', '/projects/p1/todo'), isEmpty);
  });

  testWidgets('a project that arrives after the page opened is picked up', (
    tester,
  ) async {
    final b = backend();
    final store = _MutableStore(snapshotOf([]));
    await pumpShell(tester, b, [], location: '/backlog', store: store);
    expect(find.text('No project yet.'), findsOneWidget);
    store.set(snapshotOf([project('p1', 'haro')]));
    await tester.pumpAndSettle();
    expect(b.where('GET', '/projects/p1/todo'), hasLength(1));
    expect(find.byKey(const Key('bl-project-p1')), findsOneWidget);
  });

  for (final size in [const Size(1600, 1000), const Size(960, 640)]) {
    testWidgets(
      'many projects and big counts do not overflow at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        final b = backend();
        await pumpShell(
          tester,
          b,
          [
            for (var i = 1; i <= 9; i++)
              project('p$i', i == 1 ? 'haro' : 'project-number-$i'),
          ],
          location: '/backlog',
          size: size,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('bl-tab-issues')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the sidebar row opens it as a page and Dashboard comes back', (
    tester,
  ) async {
    final b = backend();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          haroApiProvider.overrideWithValue(b.api),
          workspaceStoreProvider.overrideWith(
            () => FakeStore(snapshotOf([project('p1', 'haro')], {})),
          ),
          devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
          backendStatusProvider.overrideWith(
            (ref) => Stream.value(BackendStatus.up),
          ),
        ],
        child: HaroApp(router: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BacklogPage), findsNothing);

    await tester.tap(find.text('Backlog'));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/backlog');
    expect(find.byType(BacklogPage), findsOneWidget);
    expect(find.text('TODO FILES'), findsOneWidget);
    expect(find.text('BACKLOG'), findsWidgets);

    await tester.tap(find.text('Dashboard'));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(find.byType(BacklogPage), findsNothing);
  });

  testWidgets(
    'Start as workspace opens New workspace pre-filled and seeds the create',
    (tester) async {
      final b = backend();
      final h = await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-start')));
      await tester.pumpAndSettle();

      expect(find.byType(BacklogPage), findsOneWidget);
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

  group('notes', () {
    final listed = {
      'notes': [
        {
          'path': 'ideas.md',
          'title': 'Ideas',
          'modified': DateTime.now().millisecondsSinceEpoch / 1000,
          'size': 30,
          'snippets': <String>[],
        },
      ],
    };

    MockBackend withNotes({
      String content = '# Ideas\n\n- cache it\nsecond line\n',
    }) => backend()
      ..routes['GET /projects/p1/notes'] = ((c) => jsonRes(
        c.query['q'] == 'redis'
            ? {
                'notes': [
                  {
                    ...(listed['notes']! as List).first as Map<String, dynamic>,
                    'snippets': ['use a redis cache'],
                  },
                ],
              }
            : listed,
      ))
      ..routes['GET /projects/p1/notes/file'] = ((_) =>
          jsonRes({'path': 'ideas.md', 'content': content, 'etag': 'e1'}))
      ..routes['PUT /projects/p1/notes/file'] = ((_) =>
          jsonRes({'ok': true, 'path': 'ideas.md', 'etag': 'e2'}))
      ..routes['DELETE /projects/p1/notes/file'] = ((_) =>
          jsonRes({'ok': true}))
      ..routes['POST /projects/p1/todo/items'] = ((_) => jsonRes({'ok': true}));

    Future<void> openNote(WidgetTester tester, MockBackend b) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-ideas.md')));
      await tester.pumpAndSettle();
    }

    TextEditingController editor(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('notes-editor')))
        .controller!;

    testWidgets('the tab lists the notes and opens one in the editor', (
      tester,
    ) async {
      await openNote(tester, withNotes());
      expect(find.text('Ideas'), findsWidgets);
      expect(editor(tester).text, '# Ideas\n\n- cache it\nsecond line\n');
      expect(find.text('SAVED'), findsOneWidget);
    });

    testWidgets('typing saves by itself, quoting the etag it read', (
      tester,
    ) async {
      final b = withNotes();
      await openNote(tester, b);
      await tester.enterText(find.byKey(const Key('notes-editor')), 'new text');
      await tester.pump();
      expect(find.text('EDITING'), findsOneWidget);
      expect(b.where('PUT', '/projects/p1/notes/file'), isEmpty);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      final put = b.where('PUT', '/projects/p1/notes/file').single;
      expect(put.body, {
        'path': 'ideas.md',
        'content': 'new text',
        'etag': 'e1',
      });
      expect(find.text('SAVED'), findsOneWidget);
    });

    testWidgets(
      'leaving the tab right after typing still sends the last edit',
      (tester) async {
        final b = withNotes();
        await openNote(tester, b);
        await tester.enterText(
          find.byKey(const Key('notes-editor')),
          'typed just now',
        );
        await tester.tap(find.byKey(const Key('bl-tab-todo')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final put = b.where('PUT', '/projects/p1/notes/file').single;
        expect(put.body, {
          'path': 'ideas.md',
          'content': 'typed just now',
          'etag': 'e1',
        });
      },
    );

    testWidgets('each save quotes the etag the one before returned', (
      tester,
    ) async {
      final b = withNotes();
      await openNote(tester, b);
      await tester.enterText(find.byKey(const Key('notes-editor')), 'one');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('notes-editor')), 'one two');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      final etags = [
        for (final c in b.where('PUT', '/projects/p1/notes/file'))
          c.body!['etag'],
      ];
      expect(etags, ['e1', 'e2']);
      expect(find.byKey(const Key('notes-conflict')), findsNothing);
    });

    testWidgets('a new note never replaces one that exists', (tester) async {
      final b = withNotes()
        ..routes['PUT /projects/p1/notes/file'] = ((_) =>
            errorRes('ideas.md already exists', 400));
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes-new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('notes-name')), 'ideas');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('ideas.md already exists'), findsOneWidget);
      expect(find.byKey(const Key('notes-editor')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a changed file stops the save and offers Keep mine', (
      tester,
    ) async {
      final b = withNotes();
      await openNote(tester, b);
      b.routes['PUT /projects/p1/notes/file'] = ((c) =>
          c.body!.containsKey('etag')
          ? errorRes('changed', 409)
          : jsonRes({'ok': true, 'path': 'ideas.md', 'etag': 'e9'}));
      await tester.enterText(find.byKey(const Key('notes-editor')), 'mine');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes-conflict')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('notes-editor')),
        'mine, more',
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(b.where('PUT', '/projects/p1/notes/file'), hasLength(1));
      tester
          .widget<HaroButton>(find.byKey(const Key('notes-keep')))
          .onPressed!();
      await tester.pumpAndSettle();
      final puts = b.where('PUT', '/projects/p1/notes/file');
      expect(puts.last.body, {'path': 'ideas.md', 'content': 'mine, more'});
      expect(find.byKey(const Key('notes-conflict')), findsNothing);
    });

    testWidgets('Reload it drops my edit for the file on disk', (tester) async {
      final b = withNotes();
      await openNote(tester, b);
      b.routes['PUT /projects/p1/notes/file'] = ((_) =>
          errorRes('changed', 409));
      await tester.enterText(find.byKey(const Key('notes-editor')), 'mine');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      tester
          .widget<HaroButton>(find.byKey(const Key('notes-reload')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(editor(tester).text, '# Ideas\n\n- cache it\nsecond line\n');
      expect(find.byKey(const Key('notes-conflict')), findsNothing);
    });

    testWidgets(
      'Make todo files the cursor line into the inbox with its source',
      (tester) async {
        final b = withNotes();
        await openNote(tester, b);
        editor(tester).selection = const TextSelection.collapsed(offset: 14);
        tester
            .widget<HaroButton>(find.byKey(const Key('notes-make-todo')))
            .onPressed!();
        await tester.pumpAndSettle();
        final post = b.where('POST', '/projects/p1/todo/items').single;
        expect(post.body, {
          'title': 'cache it',
          'evidence': 'from notes/ideas.md',
          'inbox': true,
        });
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Make todo on a blank line says so and files nothing', (
      tester,
    ) async {
      final b = withNotes();
      await openNote(tester, b);
      editor(tester).selection = const TextSelection.collapsed(offset: 8);
      tester
          .widget<HaroButton>(find.byKey(const Key('notes-make-todo')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/todo/items'), isEmpty);
      expect(find.textContaining('Put the cursor on a line'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'Start as workspace opens New workspace prefilled from the line',
      (tester) async {
        final b = withNotes();
        await openNote(tester, b);
        editor(tester).selection = const TextSelection.collapsed(offset: 14);
        await tester.tap(find.byKey(const Key('notes-start')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('nw-task')))
              .controller!
              .text,
          'cache it',
        );
      },
    );

    testWidgets('+ NEW NOTE creates a titled file and opens it', (
      tester,
    ) async {
      final b = withNotes();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('notes-name')),
        'caching ideas',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final put = b.where('PUT', '/projects/p1/notes/file').first;
      expect(put.body, {
        'path': 'caching-ideas.md',
        'content': '# Caching ideas\n\n',
        'create': true,
      });
    });

    testWidgets('Delete asks first, then removes the file', (tester) async {
      final b = withNotes();
      await openNote(tester, b);
      await tester.tap(find.byKey(const Key('notes-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes-confirm-delete')), findsOneWidget);
      expect(b.where('DELETE', '/projects/p1/notes/file'), isEmpty);
      tester
          .widget<HaroButton>(find.byKey(const Key('notes-delete')))
          .onPressed!();
      await tester.pumpAndSettle();
      final del = b.where('DELETE', '/projects/p1/notes/file').single;
      expect(del.query['path'], 'ideas.md');
      expect(find.byKey(const Key('notes-editor')), findsNothing);
    });

    testWidgets('search asks the backend and shows the matching lines', (
      tester,
    ) async {
      final b = withNotes();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('notes-search')), 'redis');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(b.where('GET', '/projects/p1/notes').last.query['q'], 'redis');
      expect(find.text('use a redis cache'), findsOneWidget);
    });

    testWidgets('an empty project says how to start', (tester) async {
      final b = withNotes()
        ..routes['GET /projects/p1/notes'] = ((_) =>
            jsonRes({'notes': <Object>[]}));
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No notes yet'), findsOneWidget);
    });
  });

  group('quick capture', () {
    Future<MockBackend> openCapture(WidgetTester tester) async {
      final b = backend()
        ..routes['POST /projects/p1/todo/items'] = ((_) =>
            jsonRes({'ok': true}));
      await pumpCreation(
        tester,
        backend: b,
        projects: [project('p1', 'haro')],
        open: (c) => showCaptureTodo(c),
      );
      return b;
    }

    testWidgets('Enter files the line in the inbox and closes', (tester) async {
      final b = await openCapture(tester);
      expect(find.text('HARO · INBOX'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('capture-text')),
        '  look at the flaky gate  ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/items').single;
      expect(post.body, {
        'title': 'look at the flaky gate',
        'evidence': '',
        'inbox': true,
      });
      expect(find.byKey(const Key('capture-text')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('an empty line saves nothing', (tester) async {
      final b = await openCapture(tester);
      await tester.enterText(find.byKey(const Key('capture-text')), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/todo/items'), isEmpty);
      expect(find.byKey(const Key('capture-text')), findsOneWidget);
    });

    testWidgets('a failed save says why and keeps the text', (tester) async {
      final b = await openCapture(tester);
      b.routes['POST /projects/p1/todo/items'] = ((_) =>
          errorRes('read-only checkout', 500));
      await tester.enterText(find.byKey(const Key('capture-text')), 'keep me');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('read-only checkout'), findsOneWidget);
      expect(
        tester
            .widget<HaroTextField>(find.byKey(const Key('capture-text')))
            .controller!
            .text,
        'keep me',
      );
    });
  });

  group('editing the backlog', () {
    MockBackend editable() => backend()
      ..routes['POST /projects/p1/todo/item'] = ((_) => jsonRes({'ok': true}))
      ..routes['POST /projects/p1/todo/items'] = ((_) => jsonRes({'ok': true}))
      ..routes['POST /projects/p1/todo/rename'] = ((_) => jsonRes({'ok': true}))
      ..routes['PUT /projects/p1/todo'] = ((_) => jsonRes({'ok': true}));

    int todoLoads(MockBackend b) => b.where('GET', '/projects/p1/todo').length;

    testWidgets('the box checks an item by position and text, then reloads', (
      tester,
    ) async {
      final b = editable();
      await open(tester, b);
      final before = todoLoads(b);
      await tester.tap(find.byKey(const Key('bl-toggle-1')));
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/item').single;
      expect(post.body, {
        'file': 'backlog/live-gate.md',
        'index': 1,
        'expect': 'Show the first `failure` at once',
        'op': 'check',
      });
      expect(todoLoads(b), before + 1);
    });

    testWidgets('a done item is unchecked by the same box', (tester) async {
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-toggle-0')));
      await tester.pumpAndSettle();
      expect(
        b.where('POST', '/projects/p1/todo/item').single.body!['op'],
        'uncheck',
      );
    });

    testWidgets('the add line appends to the open file', (tester) async {
      final b = editable();
      await open(tester, b);
      await tester.enterText(find.byKey(const Key('bl-add')), 'Write the docs');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/items').single;
      expect(post.body!['title'], 'Write the docs');
      expect(post.body!['file'], 'backlog/live-gate.md');
    });

    testWidgets('the menu deletes and moves', (tester) async {
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bl-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      final ops = [
        for (final c in b.where('POST', '/projects/p1/todo/item'))
          '${c.body!['op']}:${c.body!['index']}',
      ];
      expect(ops, ['up:2', 'delete:2']);
    });

    testWidgets('the menu offers the other files to move to', (tester) async {
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('backlog/desktop.md'));
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/item').single;
      expect(post.body!['op'], 'move');
      expect(post.body!['to_file'], 'backlog/desktop.md');
    });

    testWidgets('Edit swaps the row for a field; Save sends the new text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bl-edit-field')),
        'Second item, reworded',
      );
      tester
          .widget<HaroButton>(find.byKey(const Key('bl-edit-save')))
          .onPressed!();
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/item').single;
      expect(post.body!['op'], 'edit');
      expect(post.body!['body'], 'Second item, reworded');
      expect(post.body!['expect'], 'Second open item');
    });

    testWidgets('Cancel leaves the file alone', (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      tester
          .widget<HaroButton>(find.byKey(const Key('bl-edit-cancel')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/todo/item'), isEmpty);
      expect(find.byKey(const Key('bl-edit-field')), findsNothing);
    });

    testWidgets('a cancelled draft does not come back on the next Edit', (
      tester,
    ) async {
      await open(tester, editable());
      Future<void> edit() async {
        await tester.tap(find.byKey(const Key('bl-menu-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
      }

      await edit();
      await tester.enterText(
        find.byKey(const Key('bl-edit-field')),
        'half typed',
      );
      tester
          .widget<HaroButton>(find.byKey(const Key('bl-edit-cancel')))
          .onPressed!();
      await tester.pumpAndSettle();
      await edit();
      final field = tester.widget<HaroTextField>(
        find.byKey(const Key('bl-edit-field')),
      );
      expect(field.controller!.text, 'Second open item');
    });

    testWidgets(
      'a parent says its delete takes the sub-items; they are indented',
      (tester) async {
        final b = editable()
          ..routes['GET /projects/p1/todo'] = ((_) => jsonRes({
            'files': [
              fileJson('backlog/a.md', [
                itemJson('Parent', children: 2),
                itemJson('Child one', depth: 1),
                itemJson('Child two', depth: 1),
              ]),
            ],
            'orphaned': <Object>[],
          }));
        await open(tester, b);
        final parent = tester.getTopLeft(find.text('Parent'));
        final child = tester.getTopLeft(find.text('Child one'));
        expect(child.dx - parent.dx, greaterThan(15));
        await tester.tap(find.byKey(const Key('bl-menu-0')));
        await tester.pumpAndSettle();
        expect(find.text('Delete with 2 sub-items'), findsOneWidget);
        await tester.tap(find.text('Delete with 2 sub-items'));
        await tester.pumpAndSettle();
        expect(
          b.where('POST', '/projects/p1/todo/item').single.body!['op'],
          'delete',
        );
        await tester.tap(find.byKey(const Key('bl-menu-1')));
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
      },
    );

    testWidgets('a 409 says the file changed and reloads', (tester) async {
      final b = editable()
        ..routes['POST /projects/p1/todo/item'] = ((_) =>
            errorRes('stale', 409));
      await open(tester, b);
      final before = todoLoads(b);
      await tester.tap(find.byKey(const Key('bl-toggle-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('The file changed'), findsOneWidget);
      expect(todoLoads(b), before + 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('+ NEW FILE creates a markdown file next to the others', (
      tester,
    ) async {
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-new-file')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('bl-name')), 'ideas');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final put = b.where('PUT', '/projects/p1/todo').single;
      expect(put.body, {'path': 'backlog/ideas.md', 'content': '# ideas\n\n'});
    });

    testWidgets('rename sends the old and new path', (tester) async {
      final b = editable();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bl-name')),
        'backlog/gate.md',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/todo/rename').single.body, {
        'path': 'backlog/live-gate.md',
        'new_path': 'backlog/gate.md',
      });
    });

    testWidgets('a project with no backlog files can still make one', (
      tester,
    ) async {
      final b = editable()
        ..routes['GET /projects/p1/todo'] = ((_) =>
            jsonRes({'files': <Object>[], 'orphaned': <Object>[]}));
      await open(tester, b);
      expect(find.byKey(const Key('bl-new-file')), findsOneWidget);
    });
  });

  testWidgets('issues tab: fetches open issues, filters, refetches by state', (
    tester,
  ) async {
    final b = backend();
    await open(tester, b);
    expect(b.where('GET', '/projects/p1/issues'), isEmpty);

    await tester.tap(find.byKey(const Key('bl-tab-issues')));
    await tester.pumpAndSettle();
    expect(b.where('GET', '/projects/p1/issues').single.query['state'], 'open');
    expect(
      find.descendant(
        of: find.byKey(const Key('bl-tab-issues')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
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
      await tester.tap(find.byKey(const Key('bl-tab-issues')));
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
    await tester.tap(find.byKey(const Key('bl-tab-issues')));
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
      await tester.tap(find.byKey(const Key('bl-tab-issues')));
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
      await tester.tap(find.byKey(const Key('bl-tab-issues')));
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
      await tester.tap(find.byKey(const Key('bl-tab-issues')));
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
      await tester.tap(find.byKey(const Key('bl-tab-issues')));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't load issues"), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-hint')), findsNothing);
      expect(b.where('GET', '/projects/p1/gh-account'), isEmpty);
    });
  });

  testWidgets('no overflow at 960x640 on either tab', (tester) async {
    await open(tester, backend());
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('bl-tab-issues')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
