import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/add_project/clone_runner.dart';
import 'package:haro_app/features/archive_workspace/archive_workspace_model.dart';
import 'package:haro_app/features/archive_workspace/archive_workspace_overlay.dart';
import 'package:haro_app/features/rename_workspace/rename_workspace_overlay.dart';
import 'package:haro_app/features/workspace/mode_switch.dart';
import 'package:haro_app/overlays/shortcuts_overlay.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/shell/sidebar.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/theme/tokens.dart';

import '../api/fixtures.dart';
import '../features/creation_harness.dart';
import '../shortcuts/app_harness.dart';

/// The detail test double never initialises the tuning that a real rename patches through, so
/// rename goes straight to the API here; the real method is covered in workspace_actions_test.
class _ApiActions extends WorkspaceActions {
  _ApiActions(this._r, String id) : super(_r, id);

  final Ref _r;

  @override
  Future<Workspace> renameWorkspace({String? name, String? branch}) => _r
      .read(haroApiProvider)
      .renameWorkspace(workspaceId, name: name, branch: branch);
}

Workspace _ws(
  String id,
  String name, {
  String status = 'idle',
  String mode = 'agent',
}) => Workspace.fromJson(
  workspaceJson(
    id: id,
    status: status,
    overrides: {
      'project_id': 'p1',
      'name': name,
      'branch': 'feat/$id',
      'mode': mode,
      'base_ref': 'main',
    },
  ),
);

const _data = ShellData(
  triageCount: 3,
  backlogOpen: 0,
  needYouCount: 0,
  projects: [
    SidebarProject(
      id: 'p1',
      name: 'haro',
      workspaces: [
        SidebarWorkspace(
          id: 'ws_a',
          name: 'shipping threshold',
          state: DisplayState.green,
          branch: 'feat/ws_a',
        ),
        SidebarWorkspace(
          id: 'ws_m',
          name: 'manual thing',
          state: DisplayState.idle,
          branch: 'feat/ws_m',
          mode: WorkspaceMode.manual,
        ),
        SidebarWorkspace(
          id: 'ws_done',
          name: 'shipped one',
          state: DisplayState.merged,
          branch: 'feat/ws_done',
        ),
      ],
    ),
  ],
);

Map<String, dynamic> _gitJson({
  int ahead = 0,
  int dirty = 0,
  bool missing = false,
}) => {
  'branch': 'feat/x',
  'base_ref': 'main',
  'ahead': ahead,
  'behind': 0,
  'dirty': dirty,
  'files': <Object>[],
  'merge_mode': 'both',
  'worktree_missing': missing,
};

MockBackend _backend({
  Map<String, dynamic>? git,
  bool gitFails = false,
  Handler? patch,
}) => MockBackend({
  'PATCH /workspaces/ws_a':
      patch ??
      (c) => jsonRes(
        workspaceJson(
          id: 'ws_a',
          overrides: {'project_id': 'p1', 'name': c.body!['name']},
        ),
      ),
  'DELETE /workspaces/ws_a': (c) => jsonRes({'archived': 'ws_a'}),
  'GET /workspaces/ws_a/git/status': (c) =>
      gitFails ? errorRes('boom', 500) : jsonRes(git ?? _gitJson()),
  'GET /*': (c) => errorRes('not found', 404),
});

Future<(GoRouter, MockBackend)> _pump(
  WidgetTester tester, {
  MockBackend? backend,
  String initialLocation = '/',
  Workspace? archived,
}) async {
  final b = backend ?? _backend();
  final store = FakeStore(
    snapshotOf(
      [project('p1', 'haro')],
      {
        'p1': [
          archived ?? _ws('ws_a', 'shipping threshold', status: 'gate_green'),
          _ws('ws_m', 'manual thing', mode: 'manual'),
          _ws('ws_done', 'shipped one', status: 'merged'),
        ],
      },
    ),
  );
  final (router, _) = await pumpApp(
    tester,
    initialLocation: initialLocation,
    shellData: _data,
    overrides: [
      haroApiProvider.overrideWithValue(b.api),
      workspaceStoreProvider.overrideWith(() => store),
      homeDirProvider.overrideWithValue('/Users/dev'),
      workspaceActionsProvider.overrideWith((ref, id) => _ApiActions(ref, id)),
    ],
  );
  return (router, b);
}

Finder _row(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byType(SidebarWorkspaceRow),
);

Finder _name(String n) => find.descendant(of: _row(n), matching: find.text(n));

Finder _dots(Finder within) =>
    find.descendant(of: within, matching: find.byType(SidebarMoreButton));

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  return gesture;
}

double _opacityOf(WidgetTester tester, Finder button) => tester
    .widget<AnimatedOpacity>(
      find.descendant(of: button, matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

Future<void> _showMerged(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('merged-toggle-p1')));
  await tester.pumpAndSettle();
}

Future<void> _openArchive(
  WidgetTester tester, {
  String row = 'shipping threshold',
}) async {
  await _rightClick(tester, _name(row));
  await tester.tap(find.text('Delete workspace…'));
  await tester.pumpAndSettle();
}

void main() {
  group('workspace row menu', () {
    testWidgets('right-click lists the actions, Delete workspace in red', (
      tester,
    ) async {
      final (_, b) = await _pump(tester);
      expect(find.text('Rename…'), findsNothing);
      await _rightClick(tester, _name('shipping threshold'));
      for (final label in [
        'Open',
        'Rename…',
        'Copy branch name',
        'Switch to Manual',
        'Delete workspace…',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Switch to Agent'), findsNothing);
      expect(
        tester.widget<Text>(find.text('Delete workspace…')).style!.color,
        HaroTokens.fail,
      );
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });

    testWidgets('a merged workspace has no mode switch', (tester) async {
      await _pump(tester);
      await _showMerged(tester);
      await _rightClick(tester, _name('shipped one'));
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.textContaining('Switch to'), findsNothing);
      expect(find.text('Delete workspace…'), findsOneWidget);
    });

    testWidgets('a manual workspace offers Switch to Agent', (tester) async {
      await _pump(tester);
      await _rightClick(tester, _name('manual thing'));
      expect(find.text('Switch to Agent'), findsOneWidget);
      expect(find.text('Switch to Manual'), findsNothing);
    });

    testWidgets('a left click does not open it; Esc closes it', (tester) async {
      await _pump(tester);
      await tester.tap(_name('shipping threshold'));
      await tester.pumpAndSettle();
      expect(find.text('Rename…'), findsNothing);
      await _showMerged(tester);
      await _rightClick(tester, _name('shipped one'));
      expect(find.text('Rename…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Rename…'), findsNothing);
    });

    testWidgets('Open goes to the workspace on its default step', (
      tester,
    ) async {
      final (router, _) = await _pump(tester);
      await _rightClick(tester, _name('shipping threshold'));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        startsWith('/w/ws_a/'),
      );
    });

    testWidgets('Copy branch name puts the branch on the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester);
      await _rightClick(tester, _name('shipping threshold'));
      await tester.tap(find.text('Copy branch name'));
      await tester.pumpAndSettle();
      expect(copied, 'feat/ws_a');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Switch to Agent asks before it sends anything', (
      tester,
    ) async {
      final b = _backend();
      b.routes['POST /workspaces/ws_a/mode'] = (c) => jsonRes(
        workspaceJson(
          id: 'ws_a',
          overrides: {'project_id': 'p1', 'mode': 'manual'},
        ),
      );
      await _pump(tester, backend: b);
      await _rightClick(tester, _name('manual thing'));
      await tester.tap(find.text('Switch to Agent'));
      await tester.pumpAndSettle();
      expect(find.text(switchToAgentTitle), findsOneWidget);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });
  });

  group('hover ···', () {
    testWidgets('fades in on row hover and opens the same menu', (
      tester,
    ) async {
      await _pump(tester);
      final dots = _dots(_row('shipping threshold'));
      expect(_opacityOf(tester, dots), 0);
      final mouse = await _hover(tester, _name('shipping threshold'));
      expect(_opacityOf(tester, dots), 1);
      expect(_opacityOf(tester, _dots(_row('manual thing'))), 0);

      await mouse.moveTo(tester.getCenter(dots));
      await tester.pumpAndSettle();
      await mouse.down(tester.getCenter(dots));
      await mouse.up();
      await tester.pumpAndSettle();
      for (final label in [
        'Open',
        'Rename…',
        'Copy branch name',
        'Switch to Manual',
        'Delete workspace…',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await mouse.moveTo(Offset.zero);
    });

    testWidgets('leaving the row hides it again and the row does not resize', (
      tester,
    ) async {
      await _pump(tester);
      final before = tester.getSize(_row('shipping threshold'));
      final nameBefore = tester.getSize(_name('shipping threshold'));
      final mouse = await _hover(tester, _name('shipping threshold'));
      expect(tester.getSize(_row('shipping threshold')), before);
      expect(tester.getSize(_name('shipping threshold')), nameBefore);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, _dots(_row('shipping threshold'))), 0);
    });

    testWidgets('a project header shows it on hover and opens its menu', (
      tester,
    ) async {
      await _pump(tester);
      final dots = find.descendant(
        of: find.ancestor(
          of: find.text('HARO'),
          matching: find.byType(MouseRegion),
        ),
        matching: find.byType(SidebarMoreButton),
      );
      expect(_opacityOf(tester, dots.first), 0);
      final mouse = await _hover(tester, find.text('HARO'));
      expect(_opacityOf(tester, dots.first), 1);
      await mouse.moveTo(tester.getCenter(dots.first));
      await tester.pumpAndSettle();
      await mouse.down(tester.getCenter(dots.first));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('Project settings'), findsOneWidget);
      expect(find.text('Remove project…'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
    });
  });

  group('rename', () {
    testWidgets('Enter saves the new name with PATCH', (tester) async {
      final (_, b) = await _pump(tester);
      await _rightClick(tester, _name('shipping threshold'));
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      expect(find.byType(RenameWorkspaceOverlay), findsOneWidget);
      final field = tester.widget<TextField>(find.descendant(of: find.byType(RenameWorkspaceOverlay), matching: find.byType(TextField)));
      expect(field.controller!.text, 'shipping threshold');
      await tester.enterText(find.descendant(of: find.byType(RenameWorkspaceOverlay), matching: find.byType(TextField)), '  free shipping ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final patches = b.where('PATCH', '/workspaces/ws_a');
      expect(patches, hasLength(1));
      expect(patches.single.body, {'name': 'free shipping'});
      expect(find.byType(RenameWorkspaceOverlay), findsNothing);
    });

    testWidgets('Esc cancels without a request', (tester) async {
      final (_, b) = await _pump(tester);
      await _rightClick(tester, _name('shipping threshold'));
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byType(RenameWorkspaceOverlay), matching: find.byType(TextField)), 'something else');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(RenameWorkspaceOverlay), findsNothing);
      expect(b.where('PATCH', '/workspaces/ws_a'), isEmpty);
    });

    testWidgets('an unchanged or blank name closes without a request', (
      tester,
    ) async {
      final (_, b) = await _pump(tester);
      await _rightClick(tester, _name('shipping threshold'));
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(RenameWorkspaceOverlay), findsNothing);
      expect(b.where('PATCH', '/workspaces/ws_a'), isEmpty);
    });

    testWidgets('a failed save stays open with the error', (tester) async {
      final (_, b) = await _pump(
        tester,
        backend: _backend(patch: (c) => errorRes('name taken')),
      );
      await _rightClick(tester, _name('shipping threshold'));
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byType(RenameWorkspaceOverlay), matching: find.byType(TextField)), 'other');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(RenameWorkspaceOverlay), findsOneWidget);
      expect(find.text('name taken'), findsOneWidget);
      expect(b.where('PATCH', '/workspaces/ws_a'), hasLength(1));
    });
  });

  group('archive', () {
    testWidgets('asks first; DELETE only after confirm; not the open one', (
      tester,
    ) async {
      final (router, b) = await _pump(tester, initialLocation: '/w/ws_m/code');
      await _openArchive(tester);
      expect(find.byType(ArchiveWorkspaceOverlay), findsOneWidget);
      expect(find.text('Delete shipping threshold?'), findsOneWidget);
      expect(b.where('DELETE', '/workspaces/ws_a'), isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/workspaces/ws_a'), isEmpty);
      expect(find.byType(ArchiveWorkspaceOverlay), findsNothing);

      await _openArchive(tester);
      await tester.tap(find.text('Delete workspace'));
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/workspaces/ws_a'), hasLength(1));
      expect(find.byType(ArchiveWorkspaceOverlay), findsNothing);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/ws_m/code',
      );
    });

    testWidgets('archiving the open workspace goes to triage', (tester) async {
      final (router, b) = await _pump(
        tester,
        initialLocation: '/w/ws_a/verify',
      );
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/ws_a/verify',
      );
      await _openArchive(tester);
      await tester.tap(find.text('Delete workspace'));
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/workspaces/ws_a'), hasLength(1));
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    });

    testWidgets('unmerged and dirty: both warnings in red', (tester) async {
      final (_, b) = await _pump(
        tester,
        backend: _backend(git: _gitJson(ahead: 2, dirty: 3)),
      );
      await _openArchive(tester);
      final commits = find.text(
        '2 commits on feat/ws_a aren\'t merged into main and are deleted with the branch.',
      );
      final files = find.text(
        '3 uncommitted files in the worktree are deleted.',
      );
      expect(commits, findsOneWidget);
      expect(files, findsOneWidget);
      expect(tester.widget<Text>(commits).style!.color, HaroTokens.fail);
      expect(tester.widget<Text>(files).style!.color, HaroTokens.fail);
      expect(
        find.textContaining('the branch', findRichText: true),
        findsWidgets,
      );
      expect(b.where('DELETE', '/workspaces/ws_a'), isEmpty);
    });

    testWidgets('the header states the worktree and branch go', (tester) async {
      await _pump(tester);
      await _openArchive(tester);
      expect(
        find.textContaining('Deletes the worktree at', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('feat/ws_a', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('git status failing words it honestly, still archivable', (
      tester,
    ) async {
      final (_, b) = await _pump(tester, backend: _backend(gitFails: true));
      await _openArchive(tester);
      expect(
        find.text('Uncommitted changes, if any, are deleted too.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Not merged: commits on feat/ws_a'),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete workspace'));
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/workspaces/ws_a'), hasLength(1));
    });

    testWidgets('a failed DELETE stays open with the error', (tester) async {
      final b = _backend();
      b.routes['DELETE /workspaces/ws_a'] = (c) =>
          errorRes('teardown failed', 400);
      await _pump(tester, backend: b);
      await _openArchive(tester);
      await tester.tap(find.text('Delete workspace'));
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveWorkspaceOverlay), findsOneWidget);
      expect(find.text('teardown failed'), findsOneWidget);
    });

    testWidgets('merged and clean: found nothing, never "nothing is lost"', (
      tester,
    ) async {
      final b = MockBackend({
        'GET /workspaces/ws_done/git/status': (c) => jsonRes(_gitJson()),
        'GET /*': (c) => errorRes('not found', 404),
      });
      await _pump(tester, backend: b);
      await _showMerged(tester);
      await _openArchive(tester, row: 'shipped one');
      expect(
        find.text(
          'Merged into main. No unmerged commits or uncommitted files found.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('nothing is lost'), findsNothing);
    });

    testWidgets('merged but a commit landed after the merge: red warning', (
      tester,
    ) async {
      final b = MockBackend({
        'GET /workspaces/ws_done/git/status': (c) =>
            jsonRes(_gitJson(ahead: 1)),
        'GET /*': (c) => errorRes('not found', 404),
      });
      await _pump(tester, backend: b);
      await _showMerged(tester);
      await _openArchive(tester, row: 'shipped one');
      final line = find.text(
        '1 commit on feat/ws_done is not in main (new since the merge, or '
        'squash-merged copies) and is deleted with the branch.',
      );
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).style!.color, HaroTokens.fail);
      expect(find.textContaining('found.'), findsNothing);
    });
  });

  group('archiveConsequences', () {
    final idle = _ws('ws_x', 'x');
    final merged = _ws('ws_x', 'x', status: 'merged');

    GitStatusResponse git({
      int ahead = 0,
      int dirty = 0,
      bool missing = false,
    }) => GitStatusResponse.fromJson(
      _gitJson(ahead: ahead, dirty: dirty, missing: missing),
    );

    List<String> texts(List<ArchiveLine> l) => [for (final x in l) x.text];

    test('unknown git never claims clean or dirty', () {
      final lines = archiveConsequences(idle, null);
      expect(texts(lines), [
        'Not merged: commits on feat/ws_x that are not in main are deleted with the branch.',
        'Uncommitted changes, if any, are deleted too.',
      ]);
      expect(lines.first.warn, isTrue);
      expect(lines.last.warn, isFalse);
    });

    test('unmerged but nothing ahead and clean says nothing alarming', () {
      expect(archiveConsequences(idle, git()), isEmpty);
    });

    test('singular wording', () {
      expect(texts(archiveConsequences(idle, git(ahead: 1, dirty: 1))), [
        "1 commit on feat/ws_x isn't merged into main and is deleted with the branch.",
        '1 uncommitted file in the worktree is deleted.',
      ]);
    });

    test('merged with commits ahead warns and gives no all-clear', () {
      final lines = archiveConsequences(merged, git(ahead: 3));
      expect(texts(lines), [
        '3 commits on feat/ws_x are not in main (new since the merge, or '
            'squash-merged copies) and are deleted with the branch.',
      ]);
      expect(lines.single.warn, isTrue);
    });

    test('merged, ahead 0 and dirty 0 is the only all-clear', () {
      expect(texts(archiveConsequences(merged, git())), [
        'Merged into main. No unmerged commits or uncommitted files found.',
      ]);
    });

    test(
      'merged with counts the backend could not measure makes no all-clear',
      () {
        final unmeasured = GitStatusResponse.fromJson({
          ..._gitJson(ahead: 0, dirty: 0, missing: false),
          'counts_unknown': true,
        });
        final lines = texts(archiveConsequences(merged, unmeasured));
        expect(lines.any((l) => l.startsWith('Merged into')), isFalse);
        expect(
          lines,
          contains('Uncommitted changes, if any, are deleted too.'),
        );
      },
    );

    test('merged with git unknown makes no all-clear', () {
      final lines = archiveConsequences(merged, null);
      expect(texts(lines), [
        'Commits on feat/ws_x that are not in main, if any, are deleted with the branch.',
        'Uncommitted changes, if any, are deleted too.',
      ]);
      expect(lines.any((l) => l.warn), isFalse);
    });

    test('merged and dirty still warns about the files', () {
      final lines = archiveConsequences(merged, git(dirty: 2));
      expect(texts(lines), [
        '2 uncommitted files in the worktree are deleted.',
      ]);
      expect(lines.single.warn, isTrue);
    });

    test('missing worktree', () {
      expect(texts(archiveConsequences(merged, git(missing: true))), [
        'The worktree is already gone from disk.',
      ]);
    });

    test('a running agent is stopped', () {
      final running = _ws('ws_x', 'x', status: 'agent_running');
      expect(
        texts(archiveConsequences(running, git())),
        contains('The running agent is stopped.'),
      );
    });
  });

  test('the shortcuts sheet mentions right-click', () {
    expect(
      shortcutEntries().map((e) => e.$1),
      contains('More actions on a project or workspace'),
    );
    expect(shortcutEntries().last.$2, 'Right-click');
  });
}
