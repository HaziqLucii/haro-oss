import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/add_project/clone_runner.dart';
import 'package:haro_app/features/remove_project/remove_project_overlay.dart';
import 'package:haro_app/overlays/command_palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/haro_text_field.dart';
import 'package:http/testing.dart';

import '../../shortcuts/app_harness.dart';
import '../../api/fixtures.dart';
import '../creation_harness.dart';

const _unmergedNote = "has work that isn't merged: its worktree is deleted";

Workspace ws(String id, String name, String projectId, {String? status}) =>
    Workspace.fromJson(
      workspaceJson(
        id: id,
        status: status ?? 'idle',
        overrides: {'project_id': projectId, 'name': name},
      ),
    );

final _haro = Project(
  id: 'p1',
  name: 'haro',
  path: '/home/dev/code/haro',
  defaultBranch: 'main',
);

MockBackend backend({Handler? remove}) => MockBackend({
  'DELETE /projects/p1': remove ?? (c) => jsonRes({'removed': 'p1'}),
});

Map<String, List<Workspace>> mixed() => {
  'p1': [
    ws('ws_a', 'shipping threshold', 'p1'),
    ws('ws_b', 'old experiment', 'p1', status: 'merged'),
    ws('ws_c', 'live gate', 'p1', status: 'error'),
  ],
  'p2': [ws('ws_z', 'sandbox thing', 'p2')],
};

Map<String, List<Workspace>> allMerged() => {
  'p1': [
    ws('ws_a', 'one', 'p1', status: 'merged'),
    ws('ws_b', 'two', 'p1', status: 'merged'),
  ],
  'p2': [ws('ws_z', 'sandbox thing', 'p2')],
};

Future<Harness> open(
  WidgetTester tester,
  MockBackend b, {
  Map<String, List<Workspace>>? workspaces,
  String initialLocation = '/',
  Size size = const Size(960, 640),
}) => pumpCreation(
  tester,
  backend: b,
  homeDir: '/home/dev',
  projects: [_haro, project('p2', 'sandbox')],
  workspaces: workspaces ?? mixed(),
  initialLocation: initialLocation,
  size: size,
  open: (c) => showRemoveProject(c, projectId: 'p1'),
);

Finder _removeButton() => find.byWidgetPredicate(
  (w) =>
      w is HaroButton &&
      (w.label == 'Remove project' || w.label == 'Removing…'),
);

VoidCallback? _removeAction(WidgetTester tester) =>
    tester.widget<HaroButton>(_removeButton()).onPressed;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

void main() {
  group('confirm content', () {
    testWidgets('title, path with ~, workspaces, unmerged flagged in red', (
      tester,
    ) async {
      final b = backend();
      await open(tester, b);
      expect(find.text('Remove haro from haro?'), findsOneWidget);
      expect(find.textContaining('~/code/haro', findRichText: true), findsOne);
      expect(
        find.textContaining(
          'stays on disk and can be added again',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('shipping threshold'), findsOneWidget);
      expect(find.text('old experiment'), findsOneWidget);
      expect(find.text('live gate'), findsOneWidget);
      expect(find.text('sandbox thing'), findsNothing);
      expect(find.text('3 WORKSPACES WILL BE TORN DOWN'), findsOneWidget);
      // idle and error are unmerged, merged is not.
      expect(find.text(_unmergedNote), findsNWidgets(2));
      final note = tester.widget<Text>(find.text(_unmergedNote).first);
      expect(note.style!.color, HaroTokens.fail);
      expect(find.text('merged'), findsOneWidget);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });

    testWidgets('a project with no workspaces is a plain confirm', (
      tester,
    ) async {
      final b = backend();
      await open(tester, b, workspaces: const {});
      expect(find.byType(HaroTextField), findsNothing);
      expect(find.textContaining('WILL BE TORN DOWN'), findsNothing);
      expect(_removeAction(tester), isNotNull);
    });

    testWidgets('the destructive button is red-bordered, never bone or green', (
      tester,
    ) async {
      await open(tester, backend(), workspaces: allMerged());
      final label = tester.widget<Text>(find.text('Remove project'));
      final fg = tester
          .widget<AnimatedDefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Remove project'),
                  matching: find.byType(AnimatedDefaultTextStyle),
                )
                .first,
          )
          .style
          .color;
      expect(label.data, 'Remove project');
      expect(fg, HaroTokens.fail);
      final box =
          tester
                  .widget<AnimatedContainer>(
                    find
                        .ancestor(
                          of: find.text('Remove project'),
                          matching: find.byType(AnimatedContainer),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect((box.border! as Border).top.color, HaroTokens.fail);
      expect(box.color, HaroTokens.transparent);
    });
  });

  group('name gate', () {
    testWidgets('enabled only on the exact project name', (tester) async {
      final b = backend();
      await open(tester, b);
      expect(find.byType(HaroTextField), findsOneWidget);
      expect(_removeAction(tester), isNull);
      await _type(tester, 'har');
      expect(_removeAction(tester), isNull);
      await _type(tester, 'Haro');
      expect(_removeAction(tester), isNull);
      await _type(tester, 'haro!');
      expect(_removeAction(tester), isNull);
      await _type(tester, 'haro');
      expect(_removeAction(tester), isNotNull);
      await _type(tester, 'hero');
      expect(_removeAction(tester), isNull);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });

    testWidgets('all merged: no field, button enabled at once', (tester) async {
      await open(tester, backend(), workspaces: allMerged());
      expect(find.byType(HaroTextField), findsNothing);
      expect(find.text(_unmergedNote), findsNothing);
      expect(_removeAction(tester), isNotNull);
    });
  });

  group('removing', () {
    testWidgets('no DELETE until confirmed; then once, reload, close', (
      tester,
    ) async {
      final b = backend();
      final h = await open(tester, b);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
      expect(find.byType(RemoveProjectOverlay), findsNothing);

      await tester.tap(find.text('open overlay'));
      await tester.pumpAndSettle();
      await _type(tester, 'haro');
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/projects/p1'), hasLength(1));
      expect(b.calls, hasLength(1));
      expect(h.store.reloads, 1);
      expect(find.byType(RemoveProjectOverlay), findsNothing);
      expect(h.location, '/');
    });

    testWidgets('Enter in the name field removes when it matches', (
      tester,
    ) async {
      final b = backend();
      await open(tester, b);
      await _type(tester, 'haro');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/projects/p1'), hasLength(1));
    });

    testWidgets('leaves a workspace route of that project', (tester) async {
      final b = backend();
      final h = await open(
        tester,
        b,
        workspaces: allMerged(),
        initialLocation: '/w/ws_a/agent',
      );
      expect(h.location, '/w/ws_a/agent');
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(h.location, '/');
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('leaves First run of that project', (tester) async {
      final h = await open(
        tester,
        backend(),
        workspaces: allMerged(),
        initialLocation: '/first-run?project=p1',
      );
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(h.location, '/');
    });

    testWidgets('stays put on another project route', (tester) async {
      final other = await open(
        tester,
        backend(),
        workspaces: allMerged(),
        initialLocation: '/w/ws_z/agent',
      );
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(other.location, '/w/ws_z/agent');
      expect(other.store.reloads, 1);
    });

    testWidgets('error shows inline, keeps the overlay, allows a retry', (
      tester,
    ) async {
      var fail = true;
      final b = backend(
        remove: (c) => fail ? errorRes('worktree is busy', 500) : jsonRes({}),
      );
      final h = await open(tester, b);
      await _type(tester, 'haro');
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(find.text('worktree is busy'), findsOneWidget);
      expect(find.byType(RemoveProjectOverlay), findsOneWidget);
      expect(_removeAction(tester), isNotNull);
      expect(h.location, '/');
      fail = false;
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(b.where('DELETE', '/projects/p1'), hasLength(2));
      expect(find.byType(RemoveProjectOverlay), findsNothing);
    });

    testWidgets('a project that vanished mid-request keeps the overlay drawn', (
      tester,
    ) async {
      final b = backend();
      final h = await open(tester, b, workspaces: allMerged());
      // ignore: invalid_use_of_protected_member
      h.store.state = snapshotOf([project('p2', 'sandbox')]);
      await tester.pump();
      expect(find.text('Remove haro from haro?'), findsOneWidget);
    });
  });

  group('busy', () {
    testWidgets('locks Esc, backdrop, Cancel and close until it answers', (
      tester,
    ) async {
      final gate = Completer<void>();
      final b = _GatedBackend(gate.future);
      final h = await pumpCreation(
        tester,
        backend: b,
        homeDir: '/home/dev',
        projects: [_haro, project('p2', 'sandbox')],
        workspaces: allMerged(),
        open: (c) => showRemoveProject(c, projectId: 'p1'),
      );
      await tester.tap(find.text('Remove project'));
      await tester.pump();
      expect(find.text('Removing…'), findsOneWidget);
      expect(_removeAction(tester), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(RemoveProjectOverlay), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(RemoveProjectOverlay), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.tap(find.text('✕'));
      await tester.pumpAndSettle();
      expect(find.byType(RemoveProjectOverlay), findsOneWidget);
      expect(b.where('DELETE', '/projects/p1'), hasLength(1));

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RemoveProjectOverlay), findsNothing);
      expect(h.store.reloads, 1);
    });

    testWidgets('Esc and a backdrop click close it when idle', (tester) async {
      final b = backend();
      await open(tester, b);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(RemoveProjectOverlay), findsNothing);

      await tester.tap(find.text('open overlay'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(RemoveProjectOverlay), findsNothing);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });
  });

  group('layout', () {
    testWidgets('no overflow at 960x640 with many long unmerged rows', (
      tester,
    ) async {
      await loadBrandFonts();
      final many = {
        'p1': [
          for (var i = 0; i < 14; i++)
            ws(
              'ws_$i',
              'a very long workspace name that has to truncate ($i) ' * 2,
              'p1',
            ),
        ],
      };
      final b = backend(remove: (c) => errorRes('x' * 200, 500));
      await open(tester, b, workspaces: many);
      await _type(tester, 'haro');
      await tester.tap(find.text('Remove project'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(RemoveProjectOverlay), findsOneWidget);
    });
  });

  group('entry points', () {
    Future<(GoRouter, ProviderContainer, MockBackend)> app(
      WidgetTester tester,
    ) async {
      final b = backend();
      final store = FakeStore(
        snapshotOf(
          [
            Project(
              id: 'haro',
              name: 'haro',
              path: '/home/dev/code/haro',
              defaultBranch: 'main',
            ),
            project('gate-sandbox', 'gate-sandbox'),
          ],
          {
            'haro': [ws('linux-attraction', 'linux attraction', 'haro')],
          },
        ),
      );
      final (router, container) = await pumpApp(
        tester,
        overrides: [
          haroApiProvider.overrideWithValue(b.api),
          workspaceStoreProvider.overrideWith(() => store),
          homeDirProvider.overrideWithValue('/home/dev'),
        ],
      );
      return (router, container, b);
    }

    testWidgets('right-click on a project header opens the menu', (
      tester,
    ) async {
      final (_, _, b) = await app(tester);
      expect(find.text('Remove project…'), findsNothing);
      await tester.tap(find.text('HARO'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('New workspace'), findsWidgets);
      expect(find.text('Project settings'), findsOneWidget);
      expect(find.text('Remove project…'), findsOneWidget);
      final remove = tester.widget<Text>(find.text('Remove project…'));
      expect(remove.style!.color, HaroTokens.fail);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);

      await tester.tap(find.text('Remove project…'));
      await tester.pumpAndSettle();
      expect(find.text('Remove haro from haro?'), findsOneWidget);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });

    testWidgets('Esc closes the menu; a left click does not open it', (
      tester,
    ) async {
      await app(tester);
      await tester.tap(find.text('HARO'));
      await tester.pumpAndSettle();
      expect(find.text('Project settings'), findsNothing);
      await tester.tap(find.text('HARO'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Project settings'), findsNothing);
    });

    testWidgets('the palette has a Remove project entry per project', (
      tester,
    ) async {
      final (_, container, b) = await app(tester);
      container.read(appCommandsProvider).openPalette();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(CommandPalette),
          matching: find.byType(TextField),
        ),
        'remove project',
      );
      await tester.pumpAndSettle();
      expect(find.text('Remove project · haro'), findsOneWidget);
      expect(find.text('Remove project · gate-sandbox'), findsOneWidget);
      await tester.tap(find.text('Remove project · haro'));
      await tester.pumpAndSettle();
      expect(find.text('Remove haro from haro?'), findsOneWidget);
      expect(b.calls.where((c) => c.path != '/review-queue'), isEmpty);
    });
  });
}

class _GatedBackend extends MockBackend {
  _GatedBackend(this.gate) : super({});

  final Future<void> gate;

  @override
  // ignore: overridden_fields
  late final client = MockClient((req) async {
    calls.add(Call(req.method, req.url.path, req.url.queryParameters, null));
    await gate;
    return jsonRes({'removed': 'p1'});
  });

  @override
  // ignore: overridden_fields
  late final api = HaroApi(Uri.parse('http://test'), client: client);
}
