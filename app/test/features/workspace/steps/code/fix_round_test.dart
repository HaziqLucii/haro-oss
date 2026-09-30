import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/features/workspace/steps/code/code_buffers.dart';
import 'package:haro_app/features/workspace/steps/code/code_step.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart'
    show codeEditorHighlighting;
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

const _ts = '''import { zone } from './zones';

export class RateTable {
  rate(w: number) {
    return 1;
  }
}

export function other() {
  return 2;
}
''';

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeStep)));

EditorTabsNotifier tabs(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id).notifier);

EditorTabsState tabState(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id));

CodeBufferStore store(WidgetTester t) =>
    containerOf(t).read(codeBuffersProvider(id));

Finder key(String k) => find.byKey(ValueKey(k));

Finder treeRow(String path) => key('tree-row:$path');

CodeLineEditingController controllerOf(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor).first).controller!;

Map<String, FileContent> files() => {
  'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: _ts),
  'README.md': const FileContent(path: 'README.md', content: '# haro\nmore\n'),
  'lib/zones.ts': const FileContent(path: 'lib/zones.ts', content: 'z\n'),
};

final tree = [
  dir('lib', [file('lib/rates.ts'), file('lib/zones.ts')]),
  file('README.md'),
];

Future<void> primaryKey(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await t.sendKeyDownEvent(k);
  await t.sendKeyUpEvent(k);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

Future<void> rightClick(WidgetTester t, Finder f) async {
  await t.tap(f, buttons: kSecondaryButton);
  await t.pumpAndSettle();
}

/// Types into the active file's buffer. The Diff | Edit choice is shared by every pane, so it
/// is flipped once.
Future<void> editActive(WidgetTester t, String text) async {
  final path = tabState(t).activePath!;
  if (store(t).bufferFor(path) == null) {
    await t.tap(key('mode-edit').first);
    await t.pumpAndSettle();
  }
  store(t).bufferFor(path)!.controller!.text = text;
  await t.pump();
  await t.pumpAndSettle();
}

/// The detail notifier the "agent" nudges: a new diff object is what a gate or agent event's
/// refetch produces.
class RefetchDetail extends FixedDetail {
  RefetchDetail(super.id, super.value);

  void refetch() => state = state.copyWith(
    diff: DiffResponse(
      baseRef: state.diff?.baseRef ?? 'origin/main',
      diff: state.diff?.diff ?? '',
      filesChanged: state.diff?.filesChanged ?? 0,
    ),
  );
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('rename and delete keep the buffers honest', () {
    testWidgets('renaming a file with unsaved edits moves the edits with it', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree, files: files());
      await rig.pump(tester, step: 'code');
      await editActive(tester, 'edited\n');
      expect(store(tester).dirtyPaths, {'lib/rates.ts'});

      await rightClick(tester, treeRow('lib/rates.ts'));
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      await tester.enterText(key('dialog-input'), 'lib/renamed.ts');
      await tester.tap(key('dialog-confirm'));
      await tester.pumpAndSettle();

      expect(rig.ops, ['rename:lib/rates.ts:lib/renamed.ts']);
      final s = tabState(tester);
      expect(s.panes.single.tabs.map((t) => t.path), ['lib/renamed.ts']);
      expect(s.activePath, 'lib/renamed.ts');
      expect(s.focused.active!.dirty, isTrue);
      expect(store(tester).dirtyPaths, {'lib/renamed.ts'});
      expect(store(tester).bufferFor('lib/rates.ts'), isNull);
      expect(controllerOf(tester).text, 'edited\n');
      expect(rig.reads.where((p) => p == 'lib/renamed.ts'), isEmpty);

      rig.files['lib/renamed.ts'] = rig.files.remove('lib/rates.ts')!;
      await tester.tap(key('next-action'));
      await tester.pumpAndSettle();
      expect(rig.saves, [('lib/renamed.ts', 'edited\n')]);
    });

    testWidgets('renaming a folder moves every open tab and buffer below it', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree, files: files());
      await rig.pump(tester, step: 'code');
      tabs(tester).open('lib/zones.ts', preview: false);
      await tester.pumpAndSettle();
      await editActive(tester, 'zed\n');
      expect(store(tester).dirtyPaths, {'lib/zones.ts'});

      await rightClick(tester, treeRow('lib'));
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      await tester.enterText(key('dialog-input'), 'src');
      await tester.tap(key('dialog-confirm'));
      await tester.pumpAndSettle();

      final s = tabState(tester);
      expect(s.panes.single.tabs.map((t) => t.path), [
        'src/rates.ts',
        'src/zones.ts',
      ]);
      expect(s.activePath, 'src/zones.ts');
      expect(store(tester).dirtyPaths, {'src/zones.ts'});
      expect(store(tester).bufferFor('lib/zones.ts'), isNull);
    });

    testWidgets(
      'deleting a file with unsaved edits says so, then drops them for good',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files());
        await rig.pump(tester, step: 'code');
        await editActive(tester, 'edited\n');

        await rightClick(tester, treeRow('lib/rates.ts'));
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('1 unsaved file will be discarded'),
          findsOneWidget,
        );
        await tester.tap(key('dialog-cancel'));
        await tester.pumpAndSettle();
        expect(store(tester).dirtyPaths, {'lib/rates.ts'});

        await rightClick(tester, treeRow('lib/rates.ts'));
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(key('dialog-confirm'));
        await tester.pumpAndSettle();

        expect(rig.ops, ['delete:lib/rates.ts']);
        expect(tabState(tester).panes.single.tabs, isEmpty);
        expect(store(tester).dirtyPaths, isEmpty);
        expect(find.text('Save & run gate'), findsNothing);

        await saveDirtyBuffers(
          store(tester),
          containerOf(tester).read(workspaceActionsProvider(id)),
        );
        expect(rig.saves, isEmpty, reason: 'nothing resurrects the file');
      },
    );

    testWidgets('a file without unsaved edits gets the plain delete text', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree, files: files());
      await rig.pump(tester, step: 'code');
      await rightClick(tester, treeRow('lib/rates.ts'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('unsaved'), findsNothing);
      await tester.tap(key('dialog-cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'deleting a folder while the split panes both hold tabs under it does not crash',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files());
        await rig.pump(tester, step: 'code');
        tabs(tester)
          ..open('lib/rates.ts', preview: false)
          ..open('lib/zones.ts', preview: false, toSide: true)
          ..open('README.md', preview: false);
        await tester.pumpAndSettle();
        expect(tabState(tester).panes, hasLength(2));
        expect(tabState(tester).panes[0].tabs.map((t) => t.path), [
          'lib/rates.ts',
        ]);

        await tester.tap(treeRow('lib'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
        expect(find.text('Delete lib?'), findsOneWidget);
        await tester.tap(key('dialog-confirm'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(rig.ops, ['delete:lib']);
        final s = tabState(tester);
        expect(s.panes, hasLength(1));
        expect(s.panes.single.tabs.map((t) => t.path), ['README.md']);
      },
    );
  });

  group('a reveal-at-line jump fires exactly once', () {
    testWidgets('leaving the step and coming back does not replay it', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree, files: files());
      final router = await rig.pump(tester, step: 'code');
      tabs(tester).open('lib/rates.ts', line: 8, preview: false);
      await tester.pumpAndSettle();
      await tester.tap(key('mode-edit'));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).selection.baseIndex, 7);
      expect(tabState(tester).jump, isNull, reason: 'consumed by the editor');

      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      router.go('/w/$id/code');
      await tester.pumpAndSettle();
      await tester.tap(key('mode-edit'));
      await tester.pumpAndSettle();

      expect(tabState(tester).jump, isNull);
      expect(controllerOf(tester).selection.baseIndex, 0);
    });

    testWidgets(
      'a jump made while the file is still loading fires once it is up',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files());
        await rig.pump(tester, step: 'code');
        tabs(tester).open('README.md', line: 2, preview: false);
        await tester.pumpAndSettle();
        await tester.tap(key('mode-edit'));
        await tester.pumpAndSettle();
        expect(controllerOf(tester).selection.baseIndex, 1);
        expect(tabState(tester).jump, isNull);
      },
    );
  });

  group('the code step action and ⌘S are one behaviour', () {
    testWidgets(
      'an unsaved file in the other pane still turns the action into Save & run gate',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files());
        await rig.pump(tester, step: 'code');
        tabs(tester)
          ..open('lib/rates.ts', preview: false)
          ..open('lib/zones.ts', preview: false, toSide: true);
        await tester.pumpAndSettle();
        await editActive(tester, 'zed\n');
        tabs(tester).focusPane(0);
        await tester.pumpAndSettle();
        expect(tabState(tester).focusedPane, 0);
        expect(tabState(tester).focused.active!.dirty, isFalse);
        expect(find.text('Save & run gate'), findsOneWidget);
      },
    );

    testWidgets(
      'Run on save off: no ⌘S hint, ⌘S saves every unsaved file and starts no gate',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files());
        await rig.pump(tester, step: 'code');
        expect(find.text('⌘S'), findsNothing);
        await editActive(tester, 'one\n');
        tabs(tester).open('lib/zones.ts', preview: false, toSide: true);
        await tester.pumpAndSettle();
        await editActive(tester, 'two\n');
        expect(find.text('Save & run gate'), findsOneWidget);
        expect(
          find.descendant(of: key('next-action'), matching: find.text('⌘S')),
          findsNothing,
        );

        await primaryKey(tester, LogicalKeyboardKey.keyS);
        expect(rig.saves.toSet(), {
          ('lib/rates.ts', 'one\n'),
          ('lib/zones.ts', 'two\n'),
        });
        expect(rig.gateRuns, isEmpty);
        expect(store(tester).dirtyPaths, isEmpty);
      },
    );

    testWidgets(
      'Run on save off: the button saves everything then runs the gate',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files());
        await rig.pump(tester, step: 'code');
        await editActive(tester, 'one\n');
        await tester.tap(key('next-action'));
        await tester.pumpAndSettle();
        expect(rig.saves, [('lib/rates.ts', 'one\n')]);
        expect(rig.gateRuns, [false]);
      },
    );

    testWidgets(
      'Run on save on: the hint shows, ⌘S and the button both run the gate',
      (tester) async {
        final rig = CodeRig(tree: tree, files: files(), runOnSave: true);
        await rig.pump(tester, step: 'code');
        await editActive(tester, 'one\n');
        expect(
          find.descendant(of: key('next-action'), matching: find.text('⌘S')),
          findsOneWidget,
        );
        await primaryKey(tester, LogicalKeyboardKey.keyS);
        expect(rig.saves, [('lib/rates.ts', 'one\n')]);
        expect(rig.gateRuns, hasLength(1));
      },
    );

    testWidgets(
      'a click while a save is in flight waits for it instead of failing',
      (tester) async {
        final hold = Completer<void>();
        final rig = CodeRig(tree: tree, files: files(), saveWait: hold.future);
        await rig.pump(tester, step: 'code');
        await editActive(tester, 'one\n');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
        await tester.pump();
        expect(store(tester).bufferFor('lib/rates.ts')!.saving, isTrue);

        await tester.tap(key('next-action'));
        await tester.pump();
        hold.complete();
        await tester.pumpAndSettle();

        expect(find.textContaining('unknown error'), findsNothing);
        expect(find.textContaining('Could not save'), findsNothing);
        expect(rig.saves, [('lib/rates.ts', 'one\n')]);
        expect(rig.gateRuns, [false]);
      },
    );
  });

  group('the file changed on disk', () {
    testWidgets('a clean open file follows the disk when the diff refetches', (
      tester,
    ) async {
      late RefetchDetail detail;
      final rig = CodeRig(
        tree: tree,
        files: files(),
        makeDetail: (id, d) => detail = RefetchDetail(id, d),
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(key('mode-edit'));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, _ts);

      rig.files['lib/rates.ts'] = const FileContent(
        path: 'lib/rates.ts',
        content: 'agent wrote this\n',
      );
      detail.refetch();
      await tester.pumpAndSettle();

      expect(controllerOf(tester).text, 'agent wrote this\n');
      expect(store(tester).dirtyPaths, isEmpty);
    });

    testWidgets('a dirty file keeps the edits when the diff refetches', (
      tester,
    ) async {
      late RefetchDetail detail;
      final rig = CodeRig(
        tree: tree,
        files: files(),
        makeDetail: (id, d) => detail = RefetchDetail(id, d),
      );
      await rig.pump(tester, step: 'code');
      await editActive(tester, 'mine\n');
      rig.files['lib/rates.ts'] = const FileContent(
        path: 'lib/rates.ts',
        content: 'agent wrote this\n',
      );
      detail.refetch();
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, 'mine\n');
    });

    Future<CodeRig> changedUnderEdit(WidgetTester tester) async {
      final rig = CodeRig(tree: tree, files: files());
      await rig.pump(tester, step: 'code');
      await editActive(tester, 'mine\n');
      rig.files['lib/rates.ts'] = const FileContent(
        path: 'lib/rates.ts',
        content: 'agent wrote this\n',
      );
      return rig;
    }

    testWidgets('⌘S asks before overwriting; Overwrite writes', (tester) async {
      final rig = await changedUnderEdit(tester);
      await primaryKey(tester, LogicalKeyboardKey.keyS);
      expect(rig.saves, isEmpty);
      expect(
        find.text('This file changed on disk since you opened it.'),
        findsOneWidget,
      );
      await tester.tap(key('conflict-overwrite'));
      await tester.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', 'mine\n')]);
      expect(key('disk-conflict-bar'), findsNothing);
    });

    testWidgets('Reload takes the disk version and drops the edits', (
      tester,
    ) async {
      final rig = await changedUnderEdit(tester);
      await primaryKey(tester, LogicalKeyboardKey.keyS);
      await tester.tap(key('conflict-reload'));
      await tester.pumpAndSettle();
      expect(rig.saves, isEmpty);
      expect(controllerOf(tester).text, 'agent wrote this\n');
      expect(store(tester).dirtyPaths, isEmpty);
      expect(key('disk-conflict-bar'), findsNothing);
    });

    testWidgets('Cancel keeps the edits and writes nothing', (tester) async {
      final rig = await changedUnderEdit(tester);
      await primaryKey(tester, LogicalKeyboardKey.keyS);
      await tester.tap(key('conflict-cancel'));
      await tester.pumpAndSettle();
      expect(rig.saves, isEmpty);
      expect(controllerOf(tester).text, 'mine\n');
      expect(key('disk-conflict-bar'), findsNothing);
    });

    testWidgets('the step bar action refuses too, and points at the file', (
      tester,
    ) async {
      final rig = await changedUnderEdit(tester);
      await tester.tap(key('next-action'));
      await tester.pumpAndSettle();
      expect(rig.saves, isEmpty);
      expect(rig.gateRuns, isEmpty);
      expect(find.textContaining('changed on disk'), findsWidgets);
      expect(key('disk-conflict-bar'), findsOneWidget);
    });
  });
}
