import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/controls/select.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/triage/projects_table.dart';
import 'package:haro_app/features/triage/pull_status.dart';

import '../creation_harness.dart' as ch;

class _CountingStore extends WorkspaceStore {
  int reloads = 0;

  @override
  WorkspaceSnapshot build() => const WorkspaceSnapshot(loaded: true);

  @override
  Future<void> reload() async => reloads++;
}

Project linked({bool auto = true, String branch = ''}) => Project(
  id: 'p1',
  name: 'haro',
  path: '/x',
  defaultBranch: 'main',
  remoteUrl: 'git@github.com:o/r.git',
  autoPull: auto,
  pullBranch: branch,
);

const localOnly = Project(
  id: 'p2',
  name: 'sandbox',
  path: '/y',
  defaultBranch: 'main',
);

void main() {
  group('pullStatus', () {
    ProjectSync sync(
      String state, {
      int behind = 0,
      int ahead = 0,
      int pulled = 0,
    }) => ProjectSync(
      state: state,
      branch: 'docs/x',
      behind: behind,
      ahead: ahead,
      pulled: pulled,
      detail: 'why',
    );

    test('local only and not checked yet', () {
      expect(pullStatus(localOnly, null).text, 'local only');
      expect(pullStatus(linked(), null).text, 'not checked yet');
      expect(pullStatus(linked(), const ProjectSync()).text, 'not checked yet');
    });

    test('each sync state reads as one short line', () {
      String t(ProjectSync s) => pullStatus(linked(), s).text;
      expect(t(sync('up_to_date')), 'up to date');
      expect(t(sync('pulled', pulled: 1)), 'pulled 1 commit');
      expect(t(sync('pulled', pulled: 3)), 'pulled 3 commits');
      expect(t(sync('other_branch', behind: 2)), 'on docs/x, 2 behind');
      expect(t(sync('other_branch')), 'on docs/x');
      expect(t(sync('dirty')), 'uncommitted changes');
      expect(t(sync('diverged', ahead: 1)), 'diverged from origin');
      expect(t(sync('blocked')), 'blocked');
      expect(t(sync('fetch_failed')), "can't reach origin");
      expect(t(sync('branch_missing')), 'no such branch on origin');
    });

    test('only the failures are red', () {
      PullTone tone(String s) => pullStatus(linked(), sync(s)).tone;
      expect(tone('up_to_date'), PullTone.ok);
      expect(tone('dirty'), PullTone.note);
      expect(tone('diverged'), PullTone.fail);
      expect(tone('blocked'), PullTone.fail);
      expect(tone('fetch_failed'), PullTone.fail);
      expect(tone('branch_missing'), PullTone.fail);
    });
  });

  group('table', () {
    late ch.MockBackend backend;
    late _CountingStore store;

    Future<void> pump(
      WidgetTester tester,
      List<Project> projects, {
      String syncState = 'up_to_date',
      Map<String, ch.Handler> extra = const {},
      double width = 628,
    }) async {
      var last = <String, dynamic>{
        'state': syncState,
        'default_branch': 'main',
        'behind': 0,
      };
      backend = ch.MockBackend({
        'GET /projects/p1/sync': (_) => ch.jsonRes(last),
        'POST /projects/p1/sync': (_) => ch.jsonRes(
          last = {'state': 'pulled', 'default_branch': 'main', 'pulled': 2},
        ),
        'GET /projects/p1/branches': (_) => ch.jsonRes({
          'branches': ['origin/HEAD', 'origin/main', 'origin/release/1.x'],
          'default': 'origin/main',
        }),
        'PUT /projects/p1/pull-settings': (c) => ch.jsonRes({
          'id': 'p1',
          'name': 'haro',
          'path': '/x',
          'default_branch': 'main',
          'remote_url': 'git@github.com:o/r.git',
          'auto_pull': c.body?['auto_pull'] ?? true,
          'pull_branch': c.body?['pull_branch'] ?? '',
        }),
        ...extra,
      });
      store = _CountingStore();
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            haroApiProvider.overrideWithValue(backend.api),
            workspaceStoreProvider.overrideWith(() => store),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProjectsTable(projects: projects),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder toggle(String id) => find.byKey(ValueKey('auto-pull-$id'));
    Finder pullNow(String id) => find.byKey(ValueKey('pull-now-$id'));
    Finder branch(String id) => find.byKey(ValueKey('pull-branch-$id'));

    testWidgets(
      'lists a linked project and a local-only one with what each can do',
      (tester) async {
        await pump(tester, [linked(), localOnly]);
        expect(find.text('haro'), findsOneWidget);
        expect(find.text('sandbox'), findsOneWidget);
        expect(find.text('up to date'), findsOneWidget);
        expect(find.text('local only'), findsOneWidget);
        expect(tester.widget<SettingToggle>(toggle('p1')).onChanged, isNotNull);
        expect(tester.widget<SettingToggle>(toggle('p2')).onChanged, isNull);
        expect(tester.widget<SettingToggle>(toggle('p2')).value, isFalse);
        expect(
          tester.widget<SettingSelect<String>>(branch('p1')).onChanged,
          isNotNull,
        );
        expect(
          tester.widget<SettingSelect<String>>(branch('p2')).onChanged,
          isNull,
        );
        expect(find.text('default · main'), findsNWidgets(2));
      },
    );

    testWidgets('the switch saves auto pull and reloads the projects', (
      tester,
    ) async {
      await pump(tester, [linked()]);
      await tester.tap(toggle('p1'));
      await tester.pumpAndSettle();
      final put = backend.where('PUT', '/projects/p1/pull-settings').single;
      expect(put.body, {'auto_pull': false});
      expect(store.reloads, 1);
    });

    testWidgets(
      'the branch menu lists the default and the branches of origin, without HEAD',
      (tester) async {
        await pump(tester, [linked()]);
        await tester.tap(branch('p1'));
        await tester.pumpAndSettle();
        expect(find.text('release/1.x'), findsOneWidget);
        expect(find.text('main'), findsOneWidget);
        expect(find.text('HEAD'), findsNothing);
      },
    );

    testWidgets('picking a branch saves it and reloads the projects', (
      tester,
    ) async {
      await pump(tester, [linked()]);
      await tester.tap(branch('p1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('release/1.x'));
      await tester.pumpAndSettle();
      expect(backend.where('PUT', '/projects/p1/pull-settings').single.body, {
        'pull_branch': 'release/1.x',
      });
      expect(store.reloads, 1);
    });

    testWidgets('picking the default entry follows the default branch again', (
      tester,
    ) async {
      await pump(tester, [linked(branch: 'release/1.x')]);
      await tester.tap(branch('p1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('default · main').last);
      await tester.pumpAndSettle();
      expect(backend.where('PUT', '/projects/p1/pull-settings').single.body, {
        'pull_branch': '',
      });
    });

    testWidgets('a followed branch that origin no longer lists still shows', (
      tester,
    ) async {
      await pump(tester, [linked(branch: 'gone/x')]);
      expect(find.text('gone/x'), findsOneWidget);
    });

    testWidgets('a refused save shows the reason', (tester) async {
      await pump(
        tester,
        [linked()],
        extra: {
          'PUT /projects/p1/pull-settings': (_) =>
              ch.errorRes('not a valid branch name', 400),
        },
      );
      await tester.tap(branch('p1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('release/1.x'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pull-error-p1')), findsOneWidget);
    });

    testWidgets('Pull now syncs even with auto pull off', (tester) async {
      await pump(tester, [linked(auto: false)]);
      await tester.tap(pullNow('p1'));
      await tester.pumpAndSettle();
      expect(backend.where('POST', '/projects/p1/sync'), hasLength(1));
      expect(find.text('pulled 2 commits'), findsOneWidget);
    });

    testWidgets('a local-only project cannot be pulled or switched', (
      tester,
    ) async {
      await pump(tester, [localOnly]);
      await tester.tap(pullNow('p2'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.method != 'GET'), isEmpty);
    });

    testWidgets('fits the narrowest dashboard column without overflow', (
      tester,
    ) async {
      await pump(tester, [
        linked(branch: 'release/very-long-branch-name'),
        localOnly,
      ]);
      expect(tester.takeException(), isNull);
    });
  });
}
