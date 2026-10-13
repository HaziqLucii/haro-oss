import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/add_project/add_project_overlay.dart';

import 'dart:async';
import 'dart:io';

import 'package:haro_app/features/add_project/clone_path.dart';
import 'package:haro_app/features/add_project/clone_runner.dart';

import '../creation_harness.dart';

Map<String, dynamic> fsJson(
  String path, {
  String? parent,
  bool git = false,
  List<Map<String, dynamic>> entries = const [],
}) => {
  'root': '/home/dev',
  'path': path,
  'parent': parent,
  'is_git_repo': git,
  'entries': entries,
};

Map<String, dynamic> dir(String parent, String name, {bool git = false}) => {
  'name': name,
  'path': '$parent/$name',
  'is_git_repo': git,
};

Map<String, dynamic> projectJson(String id, String path) => {
  'id': id,
  'name': path.split('/').last,
  'path': path,
  'default_branch': 'main',
  'remote_url': null,
  'stack': <String>[],
};

MockBackend backend({Map<String, Handler> more = const {}}) => MockBackend({
  'GET /fs': (c) => switch (c.query['path']) {
    null || '/home/dev' => jsonRes(
      fsJson(
        '/home/dev',
        entries: [
          dir('/home/dev', 'code'),
          dir('/home/dev', 'shop-api', git: true),
        ],
      ),
    ),
    '/home/dev/code' => jsonRes(
      fsJson(
        '/home/dev/code',
        parent: '/home/dev',
        entries: [dir('/home/dev/code', 'blog', git: true)],
      ),
    ),
    _ => jsonRes(fsJson(c.query['path']!, parent: '/home/dev')),
  },
  'POST /projects': (c) =>
      jsonRes(projectJson('proj_new', c.body!['path'] as String)),
  ...more,
});

Future<Harness> open(
  WidgetTester tester,
  MockBackend b, {
  CloneRunner? clone,
  TargetProbe? probe,
  String home = '/home/dev',
}) async {
  return pumpCreation(
    tester,
    backend: b,
    cloneRunner: clone,
    targetProbe: probe ?? (_) async => TargetState.missing,
    homeDir: home,
    open: (c) => showAddProject(c),
  );
}

void main() {
  setUpAll(loadBrandFonts);

  test('clone helpers', () {
    expect(
      normalizeCloneUrl('owner/repo'),
      'https://github.com/owner/repo.git',
    );
    expect(
      normalizeCloneUrl(' git@github.com:o/r.git '),
      'git@github.com:o/r.git',
    );
    expect(repoFolderName('https://github.com/o/repo.git'), 'repo');
    expect(repoFolderName('git@github.com:o/repo.git'), 'repo');
    expect(repoFolderName('https://github.com/o/repo/'), 'repo');
    expect(repoFolderName(''), '');
  });

  testWidgets('shows the three ways in, no request until one is picked', (
    tester,
  ) async {
    final b = backend();
    await open(tester, b);
    expect(find.text('Open a folder on disk'), findsOneWidget);
    expect(find.text('Clone from GitHub'), findsOneWidget);
    expect(find.text('Start a new project'), findsOneWidget);
    expect(b.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open a folder: browse, add a repo, land on first run', (
    tester,
  ) async {
    final b = backend();
    final h = await open(tester, b);
    await tester.tap(find.text('Open a folder on disk'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fp-add-shop-api')), findsOneWidget);
    expect(find.byKey(const Key('fp-add-code')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('code'));
    await tester.pumpAndSettle();
    expect(b.calls.last.query['path'], '/home/dev/code');
    expect(find.byKey(const Key('fp-add-blog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('fp-up')));
    await tester.pumpAndSettle();
    expect(b.calls.last.query['path'], '/home/dev');

    await tester.tap(find.byKey(const Key('fp-add-shop-api')));
    await tester.pumpAndSettle();

    final post = b.where('POST', '/projects').single;
    expect(post.body!['path'], '/home/dev/shop-api');
    expect(post.body!['init'], false);
    expect(h.store.reloads, 1);
    expect(h.location, '/first-run?project=proj_new');
    expect(find.byKey(const Key('fp-path')), findsNothing);
  });

  testWidgets('open a folder: a failure from the backend stays inline', (
    tester,
  ) async {
    final b = backend(
      more: {'POST /projects': (_) => errorRes('not a git repository', 400)},
    );
    final h = await open(tester, b);
    await tester.tap(find.text('Open a folder on disk'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fp-add-shop-api')));
    await tester.pumpAndSettle();
    expect(find.text('not a git repository'), findsOneWidget);
    expect(h.location, '/');
  });

  testWidgets(
    'start a new project: init, name and remote go to POST /projects',
    (tester) async {
      final b = backend();
      final h = await open(tester, b);
      await tester.tap(find.text('Start a new project'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'my app');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 10));
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        '/home/dev',
      );
      await tester.enterText(fields.at(2), 'https://github.com/me/my-app.git');
      await tester.pump();
      expect(find.text('Creates /home/dev/my-app'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ap-submit')));
      await tester.pumpAndSettle();

      final post = b.where('POST', '/projects').single;
      expect(post.body, {
        'path': '/home/dev/my-app',
        'name': 'my app',
        'init': true,
        'remote_url': 'https://github.com/me/my-app.git',
      });
      expect(h.location, '/first-run?project=proj_new');
    },
  );

  testWidgets('new project: browse for the parent and make a folder there', (
    tester,
  ) async {
    final b = backend(
      more: {
        'POST /fs/mkdir': (c) => jsonRes({
          'path': '/home/dev/projects',
          'name': c.body!['name'],
          'parent': c.body!['parent'],
        }),
      },
    );
    await open(tester, b);
    await tester.tap(find.text('Start a new project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ap-browse-parent-folder')));
    await tester.pumpAndSettle();
    expect(find.text('Choose location'), findsOneWidget);
    expect(find.byKey(const Key('fp-add-shop-api')), findsNothing);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('fp-newname')),
        matching: find.byType(TextField),
      ),
      'projects',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('fp-mkdir')));
    await tester.pumpAndSettle();
    expect(b.where('POST', '/fs/mkdir').single.body, {
      'parent': '/home/dev',
      'name': 'projects',
    });

    await tester.tap(find.text('code'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fp-use')));
    await tester.pumpAndSettle();
    expect(find.text('Start a new project'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      '/home/dev/code',
    );
  });

  testWidgets('clone: runs git into <parent>/<repo>, then registers it', (
    tester,
  ) async {
    final b = backend();
    final cloned = <(String, String)>[];
    final h = await open(
      tester,
      b,
      clone: (url, dest, handle) async {
        cloned.add((url, dest));
      },
    );
    await tester.tap(find.text('Clone from GitHub'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'me/shop-api');
    await tester.pumpAndSettle();
    expect(find.text('Clones to /home/dev/shop-api'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pumpAndSettle();

    expect(cloned, [
      ('https://github.com/me/shop-api.git', '/home/dev/shop-api'),
    ]);
    final post = b.where('POST', '/projects').single;
    expect(post.body!['path'], '/home/dev/shop-api');
    expect(post.body!['init'], false);
    expect(h.location, '/first-run?project=proj_new');
  });

  testWidgets('clone: a git failure is shown and nothing is registered', (
    tester,
  ) async {
    final b = backend();
    final h = await open(
      tester,
      b,
      clone: (url, dest, handle) async {
        throw const CloneException('fatal: repository not found');
      },
    );
    await tester.tap(find.text('Clone from GitHub'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'me/missing');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pumpAndSettle();

    expect(find.text('fatal: repository not found'), findsOneWidget);
    expect(b.where('POST', '/projects'), isEmpty);
    expect(h.location, '/');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 960x640 in any stage', (tester) async {
    final b = backend();
    await open(tester, b);
    for (final row in [
      'Open a folder on disk',
      'Clone from GitHub',
      'Start a new project',
    ]) {
      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: row);
      await tester.tap(
        find.byKey(
          row.startsWith('Open') ? const Key('fp-back') : const Key('ap-back'),
        ),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Start a new project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ap-browse-parent-folder')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('clone target', () {
    test('expands ~, folds . and .., needs an absolute path', () {
      String r(
        String parent, {
        String folder = 'repo',
        String? home = '/home/dev',
      }) => resolveCloneTarget(parent: parent, folder: folder, home: home);
      expect(r('~/code'), '/home/dev/code/repo');
      expect(r('~'), '/home/dev/repo');
      expect(r('/a/b/../c/./d/'), '/a/c/d/repo');
      expect(r('/a//b'), '/a/b/repo');
      expect(r('/..'), '/repo');
      expect(() => r('code'), throwsA(isA<ClonePathException>()));
      expect(() => r('./code'), throwsA(isA<ClonePathException>()));
      expect(() => r('~/x', home: null), throwsA(isA<ClonePathException>()));
      expect(() => r('/a', folder: '..'), throwsA(isA<ClonePathException>()));
      expect(() => r('/a', folder: ''), throwsA(isA<ClonePathException>()));
    });

    test('probeTarget tells missing, empty and non-empty apart', () async {
      final dir = Directory.systemTemp.createTempSync('haro_probe');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await probeTarget('${dir.path}/nope'), TargetState.missing);
      expect(await probeTarget(dir.path), TargetState.empty);
      File('${dir.path}/f').writeAsStringSync('x');
      expect(await probeTarget(dir.path), TargetState.notEmpty);
      expect(await probeTarget('${dir.path}/f'), TargetState.notEmpty);
    });
  });

  group('git environment and process', () {
    test(
      'never prompts: terminal prompt off, ssh in batch mode unless configured',
      () {
        expect(cloneEnvironment({}), {
          'GIT_TERMINAL_PROMPT': '0',
          'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes',
        });
        expect(
          cloneEnvironment({'GIT_SSH_COMMAND': ''})['GIT_SSH_COMMAND'],
          'ssh -o BatchMode=yes',
        );
        expect(cloneEnvironment({'GIT_SSH_COMMAND': 'ssh -i key'}), {
          'GIT_TERMINAL_PROMPT': '0',
        });
      },
    );

    test('CloneHandle kills on cancel, or on attach when cancelled first', () {
      var kills = 0;
      final a = CloneHandle()..attach(() => kills++);
      expect(kills, 0);
      a.cancel();
      expect(kills, 1);
      expect(a.cancelled, isTrue);
      CloneHandle()
        ..cancel()
        ..attach(() => kills++);
      expect(kills, 2);
    });

    test('gitClone clones a local repo and reports a failure', () async {
      final tmp = Directory.systemTemp.createTempSync('haro_clone');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final src = '${tmp.path}/src';
      Directory(src).createSync();
      for (final args in [
        ['init', '-q'],
        [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          'commit',
          '-q',
          '--allow-empty',
          '-m',
          'x',
        ],
      ]) {
        expect(
          (await Process.run('git', args, workingDirectory: src)).exitCode,
          0,
        );
      }
      await gitClone(src, '${tmp.path}/dst', CloneHandle());
      expect(Directory('${tmp.path}/dst/.git').existsSync(), isTrue);
      await expectLater(
        gitClone('${tmp.path}/missing', '${tmp.path}/dst2', CloneHandle()),
        throwsA(isA<CloneException>()),
      );
      final cancelled = CloneHandle()..cancel();
      await expectLater(
        gitClone(src, '${tmp.path}/dst3', cancelled),
        throwsA(isA<CloneCancelled>()),
      );
    });
  });

  Future<Harness> cloneForm(
    WidgetTester tester,
    MockBackend b, {
    required CloneRunner clone,
    TargetProbe? probe,
  }) async {
    final h = await open(tester, b, clone: clone, probe: probe);
    await tester.tap(find.text('Clone from GitHub'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'me/shop-api');
    await tester.pumpAndSettle();
    return h;
  }

  Future<void> setDest(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).at(1), text);
    await tester.pumpAndSettle();
  }

  testWidgets('clone: ~ expands like the backend and both sides get one path', (
    tester,
  ) async {
    final b = backend();
    final cloned = <String>[];
    final h = await cloneForm(
      tester,
      b,
      clone: (url, dest, handle) async => cloned.add(dest),
    );
    await setDest(tester, '~/code/../code');
    expect(find.text('Clones to /home/dev/code/shop-api'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pumpAndSettle();
    expect(cloned, ['/home/dev/code/shop-api']);
    expect(
      b.where('POST', '/projects').single.body!['path'],
      '/home/dev/code/shop-api',
    );
    expect(h.location, '/first-run?project=proj_new');
  });

  testWidgets('clone: a relative destination is refused before git runs', (
    tester,
  ) async {
    final b = backend();
    var ran = false;
    await cloneForm(tester, b, clone: (u, d, h) async => ran = true);
    await setDest(tester, 'code');
    expect(
      find.text('Enter a full folder path (starting with / or ~).'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pumpAndSettle();
    expect(ran, isFalse);
    expect(b.where('POST', '/projects'), isEmpty);
  });

  testWidgets(
    'clone: a non-empty target is refused before git runs, an empty one is fine',
    (tester) async {
      final b = backend();
      var state = TargetState.notEmpty;
      var runs = 0;
      await cloneForm(
        tester,
        b,
        clone: (u, d, h) async => runs++,
        probe: (_) async => state,
      );
      await setDest(tester, '/srv/code');
      await tester.tap(find.byKey(const Key('ap-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('/srv/code/shop-api already exists and is not empty.'),
        findsOneWidget,
      );
      expect(runs, 0);
      expect(b.where('POST', '/projects'), isEmpty);

      state = TargetState.empty;
      await tester.tap(find.byKey(const Key('ap-submit')));
      await tester.pumpAndSettle();
      expect(runs, 1);
      expect(b.where('POST', '/projects'), hasLength(1));
    },
  );

  testWidgets('clone: after a registration failure, retry skips git', (
    tester,
  ) async {
    var posts = 0;
    final b = backend(
      more: {
        'POST /projects': (c) => posts++ == 0
            ? errorRes('backend hiccup', 500)
            : jsonRes(projectJson('proj_new', c.body!['path'] as String)),
      },
    );
    var runs = 0;
    var target = TargetState.missing;
    final h = await cloneForm(
      tester,
      b,
      clone: (u, d, h) async {
        runs++;
        target = TargetState.notEmpty;
      },
      probe: (_) async => target,
    );
    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pumpAndSettle();
    expect(find.text('backend hiccup'), findsOneWidget);
    expect(runs, 1);

    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pumpAndSettle();
    expect(runs, 1);
    expect(b.where('POST', '/projects'), hasLength(2));
    expect(h.location, '/first-run?project=proj_new');
  });

  testWidgets('clone: Cancel clone kills git and leaves the form usable', (
    tester,
  ) async {
    final b = backend();
    late CloneHandle seen;
    final gate = Completer<void>();
    await cloneForm(
      tester,
      b,
      clone: (u, d, handle) async {
        seen = handle;
        await gate.future;
        if (handle.cancelled) throw const CloneCancelled();
      },
    );
    await tester.tap(find.byKey(const Key('ap-submit')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('ap-cancel-clone')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ap-cancel-clone')));
    gate.complete();
    await tester.pumpAndSettle();
    expect(seen.cancelled, isTrue);
    expect(find.byKey(const Key('ap-cancel-clone')), findsNothing);
    expect(find.byKey(const Key('ap-submit')), findsOneWidget);
    expect(b.where('POST', '/projects'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'clone: closing the overlay mid-clone kills git and never registers',
    (tester) async {
      final b = backend();
      late CloneHandle seen;
      final gate = Completer<void>();
      final h = await cloneForm(
        tester,
        b,
        clone: (u, d, handle) async {
          seen = handle;
          await gate.future;
          if (handle.cancelled) throw const CloneCancelled();
        },
      );
      await tester.tap(find.byKey(const Key('ap-submit')));
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(seen.cancelled, isTrue);
      gate.complete();
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects'), isEmpty);
      expect(h.location, '/');
      expect(tester.takeException(), isNull);
    },
  );
}
