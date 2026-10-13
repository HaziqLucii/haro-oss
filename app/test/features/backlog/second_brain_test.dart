import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/backlog_jump.dart';
import 'package:haro_app/features/backlog/backlog_page.dart';
import 'package:haro_app/features/backlog/quick_switcher.dart';

import '../creation_harness.dart';
import 'backlog_test.dart' show backend, fileJson, itemJson;

Map<String, dynamic> meta(
  Map<String, dynamic> item, {
  String? id,
  List<String> tags = const [],
  bool pinned = false,
  bool blocked = false,
  String snooze = '',
}) => {
  ...item,
  'id': id,
  'tags': tags,
  'depends': <String>[],
  'pinned': pinned,
  'snooze': snooze,
  'snoozed': false,
  'archived': false,
  'blocked': blocked,
  'blocked_by': <String>[],
};

final tagged = {
  'files': [
    fileJson('backlog/desktop.md', [
      meta(itemJson('Tray icon'), id: 'aa11bb', tags: ['ui']),
      meta(itemJson('Auto update'), tags: ['infra']),
    ], title: 'Desktop'),
    fileJson('backlog/inbox.md', [
      meta(itemJson('Look at the flaky gate', heading: 'Inbox')),
      meta(itemJson('Tray icon colours', heading: 'Inbox')),
    ], title: 'Inbox'),
  ],
  'orphaned': <Object>[],
};

MockBackend withMeta() => backend(todo: tagged)
  ..routes['POST /projects/p1/todo/meta'] = ((_) => jsonRes({
    'ok': true,
    'entry': {'id': 'zz99yy'},
  }))
  ..routes['POST /projects/p1/todo/item'] = ((_) => jsonRes({'ok': true}))
  ..routes['PUT /projects/p1/backlog/views'] = ((c) => jsonRes({
    'views': [
      for (final v in (c.body!['views'] as List)) {...v as Map, 'id': 'v1'},
    ],
  }));

/// Wide enough that the test font (wider than the real ones when run alone) does not overflow.
Future<Harness> open(WidgetTester tester, MockBackend b) => pumpCreation(
  tester,
  backend: b,
  projects: [project('p1', 'haro')],
  size: const Size(1500, 1000),
  open: (c) => Navigator.of(c).push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: BacklogPage()),
    ),
  ),
);

Future<void> bigWindow(WidgetTester tester) async {}

void main() {
  group('filter, board and metadata', () {
    testWidgets('a tag shows on its row and the filter narrows by it', (
      tester,
    ) async {
      await bigWindow(tester);
      await open(tester, withMeta());
      await tester.tap(find.text('Desktop').first);
      await tester.pumpAndSettle();
      expect(find.text('#ui'), findsWidgets);
      await tester.enterText(find.byKey(const Key('bl-find')), 'tag:ui');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bl-results')), findsOneWidget);
      expect(
        find.byKey(const Key('bl-hit-backlog/desktop.md#0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('bl-hit-backlog/desktop.md#1')),
        findsNothing,
      );
    });

    testWidgets('a filter that matches nothing says so', (tester) async {
      await bigWindow(tester);
      await open(tester, withMeta());
      await tester.enterText(find.byKey(const Key('bl-find')), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bl-results-empty')), findsOneWidget);
    });

    testWidgets('Board lays the items out by stage', (tester) async {
      await bigWindow(tester);
      await open(tester, withMeta());
      await tester.tap(find.byKey(const Key('bl-layout-board')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bl-board')), findsOneWidget);
      expect(find.byKey(const Key('bl-col-ready')), findsOneWidget);
      expect(
        find.byKey(const Key('bl-card-backlog/desktop.md#0')),
        findsOneWidget,
      );
    });

    testWidgets('Pin to the top writes the metadata, not the file', (
      tester,
    ) async {
      await bigWindow(tester);
      final b = withMeta();
      await open(tester, b);
      await tester.tap(find.text('Desktop').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bl-menu-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to the top'));
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/meta').single;
      expect(post.body!['file'], 'backlog/desktop.md');
      expect(post.body!['index'], 0);
      expect(post.body!['pinned'], true);
      expect(b.where('POST', '/projects/p1/todo/item'), isEmpty);
    });

    testWidgets('Save this view sends the filter and the layout', (
      tester,
    ) async {
      await bigWindow(tester);
      final b = withMeta();
      await open(tester, b);
      await tester.enterText(find.byKey(const Key('bl-find')), 'tag:ui');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bl-views')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save this view…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, 'UI work');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final put = b.where('PUT', '/projects/p1/backlog/views').single;
      final v = (put.body!['views'] as List).single as Map;
      expect(v['name'], 'UI work');
      expect(v['query'], 'tag:ui');
      expect(v['layout'], 'list');
    });
  });

  group('sort inbox', () {
    Future<MockBackend> openSortInbox(WidgetTester tester) async {
      await bigWindow(tester);
      final b = withMeta();
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-sort-inbox')));
      await tester.pumpAndSettle();
      return b;
    }

    testWidgets('shows the first inbox item', (tester) async {
      await openSortInbox(tester);
      expect(find.byKey(const Key('sort-item')), findsOneWidget);
      expect(find.text('Look at the flaky gate'), findsOneWidget);
      expect(find.byKey(const Key('sort-count')), findsOneWidget);
    });

    testWidgets('J moves on, and a look-alike elsewhere is pointed out', (
      tester,
    ) async {
      await openSortInbox(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pumpAndSettle();
      expect(find.text('Tray icon colours'), findsOneWidget);
      expect(find.byKey(const Key('sort-similar')), findsOneWidget);
    });

    testWidgets('D discards the item with a delete op', (tester) async {
      final b = await openSortInbox(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/item').single;
      expect(post.body!['op'], 'delete');
      expect(post.body!['file'], 'backlog/inbox.md');
      expect(post.body!['expect'], 'Look at the flaky gate');
    });

    testWidgets('P then a file promotes by moving the item', (tester) async {
      final b = await openSortInbox(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sort-choice-backlog/desktop.md')));
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/item').single;
      expect(post.body!['op'], 'move');
      expect(post.body!['to_file'], 'backlog/desktop.md');
    });

    testWidgets('a letter with Cmd held is not a sort-inbox action', (
      tester,
    ) async {
      final b = await openSortInbox(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/todo/item'), isEmpty);
    });

    testWidgets('S snoozes a week through the metadata', (tester) async {
      final b = await openSortInbox(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/todo/meta').single;
      expect(post.body!['expect'], 'Look at the flaky gate');
      expect(post.body!['snooze'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    testWidgets('an empty inbox says so', (tester) async {
      await bigWindow(tester);
      await open(tester, backend());
      await tester.tap(find.byKey(const Key('bl-sort-inbox')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sort-empty')), findsOneWidget);
    });
  });

  group('review', () {
    testWidgets('lists what the backend computed, each row opens its item', (
      tester,
    ) async {
      await bigWindow(tester);
      final b = backend()
        ..routes['GET /projects/p1/review'] = ((_) => jsonRes({
          'stale': [
            {
              'file': 'backlog/desktop.md',
              'index': 0,
              'text': 'Tray icon',
              'days': 30,
            },
          ],
          'stale_days': 14,
          'not_started': <Object>[],
          'unlinked_notes': [
            {'path': 'ideas.md', 'title': 'Ideas', 'days': 3},
          ],
          'orphaned': [
            {'workspace_id': 'w', 'seed_key': 'k'},
          ],
          'resurface': null,
          'note_tasks': 2,
        }));
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-review')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('review-stale')), findsOneWidget);
      expect(find.byKey(const Key('review-unlinked')), findsOneWidget);
      expect(find.byKey(const Key('review-orphaned-count')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('review-stale-backlog/desktop.md#0')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('review-stale')), findsNothing);
    });
  });

  group('quick switcher', () {
    testWidgets('searches, and Enter sets the jump and opens the Backlog', (
      tester,
    ) async {
      final b = backend()
        ..routes['GET /projects/p1/find'] = ((c) => jsonRes({
          'results': [
            {
              'kind': 'note',
              'title': 'Caching ideas',
              'subtitle': 'ideas.md',
              'path': 'ideas.md',
              'tags': <String>[],
            },
            {
              'kind': 'todo',
              'title': 'Tray icon',
              'file': 'backlog/desktop.md',
              'index': 0,
              'tags': ['ui'],
            },
          ],
        }));
      final h = await pumpCreation(
        tester,
        backend: b,
        projects: [project('p1', 'haro')],
        open: (c) => showQuickSwitcher(c),
      );
      await tester.enterText(find.byKey(const Key('switcher-field')), 'cach');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(b.where('GET', '/projects/p1/find').last.query['q'], 'cach');
      expect(find.text('Caching ideas'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final jump = h.container.read(backlogJumpProvider);
      expect(jump?.kind, 'todo');
      expect(jump?.file, 'backlog/desktop.md');
      expect(h.location, startsWith('/backlog'));
    });
  });

  group('quick switcher timing', () {
    testWidgets('Enter right after typing opens a result of that text', (
      tester,
    ) async {
      final b = backend()
        ..routes['GET /projects/p1/find'] = ((c) => jsonRes({
          'results': [
            {
              'kind': 'note',
              'title': c.query['q'] == 'cart' ? 'Cart note' : 'Older note',
              'path': c.query['q'] == 'cart' ? 'cart.md' : 'old.md',
              'tags': <String>[],
            },
          ],
        }));
      final h = await pumpCreation(
        tester,
        backend: b,
        projects: [project('p1', 'haro')],
        open: (c) => showQuickSwitcher(c),
      );
      await tester.enterText(find.byKey(const Key('switcher-field')), 'cart');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(h.container.read(backlogJumpProvider)?.path, 'cart.md');
    });
  });

  group('notes', () {
    MockBackend notesBackend({
      String content = '# Ideas\n\n- cache it\n',
    }) => withMeta()
      ..routes['GET /projects/p1/notes'] = ((_) => jsonRes({
        'notes': [
          {
            'path': 'ideas.md',
            'title': 'Ideas',
            'modified': DateTime.now().millisecondsSinceEpoch / 1000,
            'size': 30,
            'snippets': <String>[],
          },
        ],
      }))
      ..routes['GET /projects/p1/notes/links'] = ((c) => jsonRes({
        'path': c.query['path'],
        'tags': <String>[],
        'outgoing': [
          {
            'target': 'todo:aa11bb Tray icon',
            'path': null,
            'todo': {
              'text': 'Tray icon',
              'done': false,
              'path': 'backlog/desktop.md',
            },
          },
          {
            'target': 'todo:dead00 Gone',
            'path': null,
            'todo': {'text': null, 'done': false, 'path': null},
          },
        ],
        'backlinks': <Map<String, dynamic>>[],
        'mentions': <Map<String, dynamic>>[],
      }))
      ..routes['GET /projects/p1/notes/file'] = ((c) => jsonRes({
        'path': c.query['path'],
        'content': c.query['path'] == 'daily/2026-10-12.md'
            ? '# 2026-10-12\n'
            : content,
        'etag': 'e1',
      }))
      ..routes['PUT /projects/p1/notes/file'] = ((_) =>
          jsonRes({'ok': true, 'path': 'ideas.md', 'etag': 'e2'}))
      ..routes['POST /projects/p1/notes/daily'] = ((_) =>
          jsonRes({'path': 'daily/2026-10-12.md'}))
      ..routes['GET /projects/p1/notes/tasks'] = ((_) => jsonRes({
        'tasks': [
          {'path': 'ideas.md', 'title': 'Ideas', 'line': 3, 'text': 'cache it'},
        ],
      }))
      ..routes['GET /projects/p1/notes/templates'] = ((_) => jsonRes({
        'templates': [
          {'id': 'decision', 'name': 'Decision record', 'source': 'built-in'},
        ],
      }))
      ..routes['POST /projects/p1/notes/from-template'] = ((_) =>
          jsonRes({'path': 'pick-a-db.md'}))
      ..routes['GET /projects/p1/notes/history'] = ((_) => jsonRes({
        'commits': [
          {
            'sha': 'abc123',
            'date': 1760000000,
            'author': 'Haziq',
            'subject': 'notes: ideas',
          },
        ],
      }))
      ..routes['GET /projects/p1/notes/revision'] = ((_) => jsonRes({
        'sha': 'abc123',
        'content': '# Old ideas\n',
        'diff': '-old\n+new',
      }));

    Future<MockBackend> openNotes(
      WidgetTester tester, {
      String content = '# Ideas\n\n- cache it\n',
    }) async {
      final b = notesBackend(content: content);
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      return b;
    }

    testWidgets('TODAY opens the daily note the backend made', (tester) async {
      final b = await openNotes(tester);
      await tester.tap(find.byKey(const Key('notes-today')));
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/notes/daily'), hasLength(1));
      expect(
        b.where('GET', '/projects/p1/notes/file').last.query['path'],
        'daily/2026-10-12.md',
      );
    });

    testWidgets('TASKS lists the open tasks, pressing one opens its note', (
      tester,
    ) async {
      final b = await openNotes(tester);
      await tester.tap(find.byKey(const Key('notes-tasks')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes-task-list')), findsOneWidget);
      await tester.tap(find.text('cache it'));
      await tester.pumpAndSettle();
      expect(
        b.where('GET', '/projects/p1/notes/file').last.query['path'],
        'ideas.md',
      );
    });

    testWidgets('a template makes the note from its id and the name typed', (
      tester,
    ) async {
      final b = await openNotes(tester);
      await tester.tap(find.byKey(const Key('notes-template')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decision record'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, 'pick a db');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final post = b.where('POST', '/projects/p1/notes/from-template').single;
      expect(post.body!['template'], 'decision');
      expect(post.body!['path'], 'pick-a-db.md');
      expect(post.body!['title'], 'pick a db');
    });

    testWidgets('History shows the diff, Restore puts that text back', (
      tester,
    ) async {
      final b = await openNotes(tester);
      await tester.tap(find.byKey(const Key('note-ideas.md')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('history-diff')), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-restore')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('history-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-restore')));
      await tester.pumpAndSettle();
      final put = b.where('PUT', '/projects/p1/notes/file').last;
      expect(put.body!['content'], '# Old ideas\n');
    });

    testWidgets('a todo link jumps to the todo, a lost one says so', (
      tester,
    ) async {
      final h = await open(
        tester,
        notesBackend(
          content: 'do [[todo:aa11bb Tray icon]] and [[todo:dead00 Gone]]',
        ),
      );
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-ideas.md')));
      await tester.pumpAndSettle();
      await tester.tapOnText(find.textRange.ofSubstring('Gone'));
      await tester.pumpAndSettle();
      expect(find.textContaining('That todo is gone'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.tapOnText(find.textRange.ofSubstring('Tray icon'));
      await tester.pumpAndSettle();
      expect(h.container.read(backlogJumpProvider), isNull);
      expect(find.byKey(const Key('bl-find')), findsOneWidget);
    });
  });
}
