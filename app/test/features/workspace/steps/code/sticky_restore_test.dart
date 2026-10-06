import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_sticky.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_state.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

EditorTabsState tabState(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id));

final tree = [
  dir('lib', [file('lib/rates.ts'), file('lib/zones.ts')]),
  file('README.md'),
];

MemoryDevicePrefsStore prefsWith(StickyEditorState s) =>
    MemoryDevicePrefsStore({
      'display': {'density': 'compact'},
      'code_sticky': {id: s.toJson()},
    });

StickyEditorState saved(List<String> paths, {String? active}) =>
    StickyEditorState(
      panes: [
        StickyPane(
          tabs: [for (final p in paths) StickyTab(path: p, preview: false)],
          active: active ?? paths.last,
        ),
      ],
      viewMode: CodeMode.edit,
      places: {
        for (final p in paths) p: const EditorPlace(line: 3, col: 2, scroll: 0),
      },
      side: const StickySide(
        view: WorkbenchView.changes,
        open: true,
        width: 300,
        scope: ExplorerScope.changes,
      ),
      savedAt: 1,
    );

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  testWidgets('saved tabs come back and the first changed file stays shut', (
    tester,
  ) async {
    final rig = CodeRig(tree: tree)
      ..prefs = prefsWith(saved(['lib/zones.ts', 'README.md']));
    await rig.pump(tester, step: 'code');

    final s = tabState(tester);
    expect(s.openPaths, {'lib/zones.ts', 'README.md'});
    expect(s.activePath, 'README.md');
    expect(s.viewMode, CodeMode.edit);
    expect(s.dirtyPaths, isEmpty);
    expect(s.jump, isNull);
    expect(
      s.openPaths.contains('lib/rates.ts'),
      isFalse,
      reason: 'the first changed file is not opened over a restore',
    );
    final wb = containerOf(tester).read(workbenchProvider(id));
    expect(wb.view, WorkbenchView.changes);
    expect(wb.scope, ExplorerScope.changes);
    expect(wb.sideWidth, 300);
  });

  testWidgets('a file that no longer exists is dropped', (tester) async {
    final rig = CodeRig(tree: tree)
      ..prefs = prefsWith(saved(['lib/gone.ts', 'lib/zones.ts']));
    await rig.pump(tester, step: 'code');
    expect(tabState(tester).openPaths, {'lib/zones.ts'});
    expect(tabState(tester).places.keys, ['lib/zones.ts']);
  });

  testWidgets('a deleted but changed file survives through the diff', (
    tester,
  ) async {
    final rig = CodeRig(tree: tree)
      ..prefs = prefsWith(saved(['lib/old.ts', 'lib/zones.ts']));
    await rig.pump(tester, step: 'code');
    expect(tabState(tester).openPaths, {'lib/old.ts', 'lib/zones.ts'});
  });

  testWidgets('with nothing left the first changed file opens as before', (
    tester,
  ) async {
    final rig = CodeRig(tree: tree)
      ..prefs = prefsWith(saved(['lib/gone.ts', 'lib/also-gone.ts']));
    await rig.pump(tester, step: 'code');
    expect(tabState(tester).openPaths, {'lib/rates.ts'});
    expect(
      containerOf(tester).read(workbenchProvider(id)).view,
      WorkbenchView.files,
      reason: 'the side panel is only restored with the tabs',
    );
  });

  testWidgets('garbage in the file is no sticky state', (tester) async {
    final rig = CodeRig(tree: tree)
      ..prefs = MemoryDevicePrefsStore({
        'code_sticky': {
          id: {
            'tabs': [
              {'path': 'lib/zones.ts'},
            ],
          },
        },
      });
    await rig.pump(tester, step: 'code');
    expect(tabState(tester).openPaths, {'lib/rates.ts'});
  });

  testWidgets('coming back to the step keeps what is open', (tester) async {
    final rig = CodeRig(tree: tree)..prefs = prefsWith(saved(['lib/zones.ts']));
    final router = await rig.pump(tester, step: 'code');
    containerOf(tester)
        .read(editorTabsProvider(id).notifier)
        .open('README.md', preview: false);
    await tester.pumpAndSettle();
    router.go('/w/$id/verify');
    await tester.pumpAndSettle();
    router.go('/w/$id/code');
    await tester.pumpAndSettle();
    expect(tabState(tester).openPaths, {'lib/zones.ts', 'README.md'});
  });

  group('saving', () {
    testWidgets('a change is written after 500 ms, other keys kept', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree);
      rig.prefs = MemoryDevicePrefsStore({
        'display': {'density': 'compact'},
      });
      await rig.pump(tester, step: 'code');
      containerOf(tester)
          .read(editorTabsProvider(id).notifier)
          .open('lib/zones.ts', preview: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.prefs.data.containsKey('code_sticky'), isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      final stored = parseStickyMap(rig.prefs.data['code_sticky'])[id]!;
      expect(stored.paths, contains('lib/zones.ts'));
      expect(rig.prefs.data['display'], {'density': 'compact'});
    });

    testWidgets('leaving the step flushes a pending write', (tester) async {
      final rig = CodeRig(tree: tree);
      final router = await rig.pump(tester, step: 'code');
      containerOf(tester)
          .read(editorTabsProvider(id).notifier)
          .open('lib/zones.ts', preview: false);
      await tester.pump(const Duration(milliseconds: 50));
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      final stored = parseStickyMap(rig.prefs.data['code_sticky'])[id]!;
      expect(stored.paths, contains('lib/zones.ts'));
    });

    testWidgets('buffer text and the dirty flag are never stored', (
      tester,
    ) async {
      final rig = CodeRig(
        tree: tree,
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'secret text\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text =
          'typed text\n';
      await tester.pump(const Duration(seconds: 1));
      final text = rig.prefs.data['code_sticky'].toString();
      expect(text, contains('lib/rates.ts'));
      expect(text, isNot(contains('typed text')));
      expect(text, isNot(contains('secret text')));
      expect(text, isNot(contains('dirty')));
    });
  });

  testWidgets('cursor and scroll are back after leaving and re-entering', (
    tester,
  ) async {
    final long = List.generate(300, (i) => 'line $i').join('\n');
    final rig = CodeRig(
      tree: tree,
      files: {'lib/rates.ts': FileContent(path: 'lib/rates.ts', content: long)},
    );
    final router = await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();

    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.selection = const CodeLineSelection.collapsed(
      index: 49,
      offset: 3,
    );
    await tester.pumpAndSettle();
    editor.scrollController!.verticalScroller.jumpTo(600);
    await tester.pumpAndSettle();
    final scrolled = tester
        .widget<EditPane>(find.byType(EditPane))
        .buffer
        .scrollOffset;
    expect(scrolled, greaterThan(0));

    router.go('/w/$id/verify');
    await tester.pumpAndSettle();
    router.go('/w/$id/code');
    await tester.pumpAndSettle();
    if (find.byType(CodeEditor).evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
    }

    final back = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final sel = back.controller!.selection;
    expect(sel.extentIndex, 49);
    expect(sel.extentOffset, 3);
    expect(
      tester.widget<EditPane>(find.byType(EditPane)).buffer.scrollOffset,
      closeTo(scrolled, 1),
    );
  });
}
