import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/editor_prefs_provider.dart';
import 'package:haro_app/features/workspace/steps/code/diff_view.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_gutter.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_marks.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/editor/minimap.dart';
import 'package:haro_app/theme/tokens.dart';
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

const _newFile = '''diff --git a/src/new.ts b/src/new.ts
new file mode 100644
--- /dev/null
+++ b/src/new.ts
@@ -0,0 +1,2 @@
+export const a = 1;
+export const b = 2;
diff --git a/src/old.ts b/src/old.ts
--- a/src/old.ts
+++ b/src/old.ts
@@ -1 +1,2 @@
 keep
+more
''';

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

EditorTabsNotifier tabs(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id).notifier);

EditorTabsState tabState(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id));

Finder tab(String path) => find.byKey(ValueKey('tab:$path'));

CodeLineEditingController controllerOf(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor).first).controller!;

FontStyle? tabFont(WidgetTester t, String path) => t
    .widget<Text>(
      find.descendant(of: tab(path), matching: find.byType(Text)).first,
    )
    .style!
    .fontStyle;

Future<void> chord(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await t.sendKeyDownEvent(key);
  await t.sendKeyUpEvent(key);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

Map<String, FileContent> files() => {
  'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: _ts),
  'README.md': const FileContent(path: 'README.md', content: '# haro\nmore\n'),
  'lib/zones.ts': const FileContent(path: 'lib/zones.ts', content: 'z\n'),
};

/// Records what the Diff view tells the XP reporter instead of calling a backend.
class RecordingReporter extends XpReporter {
  RecordingReporter()
    : super(() => throw StateError('no backend in this test'));

  final shown = <(String, String, List<String>)>[];

  @override
  void diffShown(String workspaceId, String path, Iterable<String> changed) =>
      shown.add((workspaceId, path, changed.toList()));
}

CodeRig withReporter(RecordingReporter r, {Map<String, FileContent>? files_}) =>
    CodeRig(files: files_ ?? files())
      ..extra.add(xpReporterProvider.overrideWithValue(r));

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('XP: diff review', () {
    const changed = ['lib/rates.ts', 'README.md', 'lib/zones.ts', 'lib/old.ts'];

    testWidgets(
      'a changed file drawn as a diff is reported with every changed path',
      (tester) async {
        final r = RecordingReporter();
        await withReporter(r).pump(tester, step: 'code');
        expect(r.shown, isNotEmpty);
        expect(r.shown.first.$1, id);
        expect(r.shown.first.$2, 'lib/rates.ts');
        expect(r.shown.first.$3, unorderedEquals(changed));
      },
    );

    testWidgets('opening another changed file reports that one too', (
      tester,
    ) async {
      final r = RecordingReporter();
      await withReporter(r).pump(tester, step: 'code');
      tabs(tester).open('README.md', preview: false);
      await tester.pumpAndSettle();
      expect(r.shown.map((s) => s.$2).toSet(), {'lib/rates.ts', 'README.md'});
    });

    testWidgets('the editor body is not a diff review', (tester) async {
      final r = RecordingReporter();
      await withReporter(r).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      r.shown.clear();
      tabs(tester).open('README.md', preview: false);
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(r.shown, isEmpty);
    });

    testWidgets('a file with no changes is never reported', (tester) async {
      final r = RecordingReporter();
      await withReporter(r).pump(tester, step: 'code');
      r.shown.clear();
      tabs(tester).open('lib/unchanged.ts', preview: false);
      await tester.pumpAndSettle();
      expect(r.shown.where((s) => s.$2 == 'lib/unchanged.ts'), isEmpty);
    });
  });

  group('tab strip', () {
    testWidgets(
      'a single click opens an italic preview the next one replaces',
      (tester) async {
        await CodeRig(files: files()).pump(tester, step: 'code');
        expect(tabFont(tester, 'lib/rates.ts'), FontStyle.italic);

        await showChanges(tester);
        await tester.tap(find.byKey(const ValueKey('file-row:README.md')));
        await tester.pumpAndSettle();
        expect(tab('lib/rates.ts'), findsNothing);
        expect(tabFont(tester, 'README.md'), FontStyle.italic);
      },
    );

    testWidgets('a double click pins it, so the next open adds a tab', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(tab('lib/rates.ts'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(tab('lib/rates.ts'));
      await tester.pumpAndSettle();
      expect(tabFont(tester, 'lib/rates.ts'), FontStyle.normal);

      await showChanges(tester);
      await tester.tap(find.byKey(const ValueKey('file-row:README.md')));
      await tester.pumpAndSettle();
      expect(tab('lib/rates.ts'), findsOneWidget);
      expect(tab('README.md'), findsOneWidget);
    });

    testWidgets('editing pins the tab and shows the unsaved dot', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'changed\n';
      await tester.pump();
      expect(tabFont(tester, 'lib/rates.ts'), FontStyle.normal);
      expect(
        find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        findsOneWidget,
      );
    });

    testWidgets('A for a new file, M for a changed one', (tester) async {
      await CodeRig(diff: _newFile).pump(tester, step: 'code');
      tabs(tester)
        ..open('src/new.ts', preview: false)
        ..open('src/old.ts', preview: false);
      await tester.pumpAndSettle();
      Text letter(String path) => tester.widget<Text>(
        find.descendant(of: tab(path), matching: find.byType(Text)).at(1),
      );
      expect(letter('src/new.ts').data, 'A');
      expect(letter('src/new.ts').style!.color, HaroTokens.gate);
      expect(letter('src/old.ts').data, 'M');
      expect(letter('src/old.ts').style!.color, isNot(HaroTokens.gate));
    });

    testWidgets('a middle click closes the tab', (tester) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      final gesture = await tester.startGesture(
        tester.getCenter(tab('lib/rates.ts')),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tab('lib/rates.ts'), findsNothing);
    });

    testWidgets('Diff | Edit is one choice for every tab', (tester) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);

      tabs(tester).open('README.md', preview: false);
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget, reason: 'still Edit');

      await tester.tap(find.byKey(const ValueKey('mode-diff')));
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsNothing);
      tabs(tester).activate('lib/rates.ts');
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsNothing);
    });

    testWidgets('a file with no changes always opens in the editor', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      tabs(tester).open('lib/unchanged.ts', preview: false);
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byType(DiffView), findsNothing);
    });
  });

  group('breadcrumbs', () {
    testWidgets('path segments, then the declaration around the cursor', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      String crumbs() => [
        for (final t in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(Row),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.key is ValueKey &&
                  '${(w.key! as ValueKey).value}'.startsWith('crumb-'),
            ),
          ),
        ))
          t.data!,
      ].join(' > ');

      expect(crumbs(), 'lib > rates.ts');

      controllerOf(tester).selection = const CodeLineSelection.collapsed(
        index: 4,
        offset: 2,
      );
      await tester.pump();
      expect(crumbs(), 'lib > rates.ts > RateTable > rate');

      controllerOf(tester).selection = const CodeLineSelection.collapsed(
        index: 9,
        offset: 2,
      );
      await tester.pump();
      expect(crumbs(), 'lib > rates.ts > other');
    });

    testWidgets('a diff view shows the path only', (tester) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('crumb-file')), findsOneWidget);
      expect(find.byKey(const ValueKey('crumb-symbol-0')), findsNothing);
    });
  });

  group('split panes', () {
    testWidgets('cmd+backslash opens an empty pane, again folds back', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('pane-1')), findsNothing);

      await chord(tester, LogicalKeyboardKey.backslash);
      expect(find.byKey(const ValueKey('pane-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane-1')), findsOneWidget);
      expect(tabState(tester).focusedPane, 1);
      expect(
        find.text('Open a file here to read it beside the other one.'),
        findsOneWidget,
      );

      await chord(tester, LogicalKeyboardKey.backslash);
      expect(find.byKey(const ValueKey('pane-1')), findsNothing);
    });

    testWidgets('each pane keeps its own tabs; the close button folds it', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('split-button')));
      await tester.pumpAndSettle();
      tabs(tester).open('README.md', preview: false);
      await tester.pumpAndSettle();
      expect(tabState(tester).panes[0].tabs.map((t) => t.path), [
        'lib/rates.ts',
      ]);
      expect(tabState(tester).panes[1].tabs.map((t) => t.path), ['README.md']);

      await tester.tap(find.byKey(const ValueKey('close-split')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane-1')), findsNothing);
      expect(tabState(tester).panes.single.tabs.map((t) => t.path), [
        'lib/rates.ts',
        'README.md',
      ]);
    });

    testWidgets('a file held by the other pane is shown there, not twice', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.backslash);
      tabs(tester).open('lib/rates.ts');
      await tester.pumpAndSettle();
      expect(tabState(tester).focusedPane, 0);
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening to the side moves the tab and its unsaved edits', (
      tester,
    ) async {
      final rig = CodeRig(files: files());
      await rig.pump(tester, step: 'code');
      tabs(tester).open('lib/zones.ts', preview: false);
      tabs(tester).open('lib/rates.ts', preview: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'kept\n';
      await tester.pump();

      tabs(tester).open('lib/rates.ts', toSide: true);
      await tester.pumpAndSettle();
      expect(tabState(tester).panes[1].tabs.map((t) => t.path), [
        'lib/rates.ts',
      ]);
      expect(
        tester
            .widget<CodeEditor>(
              find.descendant(
                of: find.byKey(const ValueKey('pane-1')),
                matching: find.byType(CodeEditor),
              ),
            )
            .controller!
            .text,
        'kept\n',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pane-1')),
          matching: find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        ),
        findsOneWidget,
      );
      expect(rig.reads.where((p) => p == 'lib/rates.ts'), hasLength(1));
    });

    testWidgets('closing the last tab of the side pane collapses it', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await chord(tester, LogicalKeyboardKey.backslash);
      tabs(tester).open('README.md', preview: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-close:README.md')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane-1')), findsNothing);
      expect(tabState(tester).focusedPane, 0);
    });
  });

  group('editor chrome', () {
    testWidgets('minimap follows the Settings toggle', (tester) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(find.byType(Minimap), findsOneWidget);

      containerOf(tester)
          .read(editorPrefsProvider.notifier)
          .set(const EditorPrefs(minimap: false));
      await tester.pumpAndSettle();
      expect(find.byType(Minimap), findsNothing);
    });

    testWidgets('font size follows Settings', (tester) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      double size() =>
          tester.widget<CodeEditor>(find.byType(CodeEditor)).style!.fontSize!;
      expect(size(), 13);
      containerOf(tester)
          .read(editorPrefsProvider.notifier)
          .set(const EditorPrefs(fontSize: 15));
      await tester.pumpAndSettle();
      expect(size(), 15);
    });

    testWidgets('opening at a line reveals it with the cursor there', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      tabs(tester).open('lib/rates.ts', line: 9);
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(controllerOf(tester).selection.extentIndex, 8);

      tabs(tester).open('lib/rates.ts', line: 3);
      await tester.pumpAndSettle();
      expect(controllerOf(tester).selection.extentIndex, 2);
    });

    testWidgets('a jump is used once, not again when the tab comes back', (
      tester,
    ) async {
      await CodeRig(files: files()).pump(tester, step: 'code');
      tabs(tester).open('lib/rates.ts', line: 9);
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 0,
      );
      tabs(tester).open('lib/zones.ts', preview: false);
      await tester.pumpAndSettle();
      tabs(tester).activate('lib/rates.ts');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).selection.extentIndex, 1);
    });

    testWidgets('gutter marks and line-ran dots, only while green and saved', (
      tester,
    ) async {
      final rig = CodeRig(proof: verified(), files: files());
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      EditorGutter gutter() =>
          tester.widget<EditorGutter>(find.byType(EditorGutter));
      expect(gutter().marks[2], ChangeMark.modified);
      expect(gutter().marks[3], ChangeMark.added);
      expect(gutter().ran, {
        2,
      }, reason: 'line 3 never ran, line 4 is a comment');

      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      expect(gutter().marks, isEmpty);
      expect(gutter().ran, isEmpty);
    });

    testWidgets('no line-ran dots when the gate is red', (tester) async {
      final rig = CodeRig(
        proof: verified(),
        files: files(),
        preview: Preview.red,
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      final g = tester.widget<EditorGutter>(find.byType(EditorGutter));
      expect(g.marks, isNotEmpty);
      expect(g.ran, isEmpty);
    });

    testWidgets('a scroll position survives a tab switch', (tester) async {
      final long = List.generate(300, (i) => 'line $i').join('\n');
      await CodeRig(
        files: {
          'lib/rates.ts': FileContent(path: 'lib/rates.ts', content: long),
          'lib/zones.ts': const FileContent(path: 'lib/zones.ts', content: 'z'),
        },
      ).pump(tester, step: 'code');
      tabs(tester).open('lib/rates.ts', line: 200, preview: false);
      await tester.pumpAndSettle();
      final first = tester.widget<EditPane>(find.byType(EditPane));
      final offset = first.buffer.scrollOffset;
      tabs(tester).open('lib/zones.ts', preview: false);
      await tester.pumpAndSettle();
      tabs(tester).activate('lib/rates.ts');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditPane>(find.byType(EditPane)).buffer.scrollOffset,
        greaterThan(0),
      );
      expect(offset, greaterThanOrEqualTo(0));
    });
  });

  group('save', () {
    testWidgets(
      'cmd+S saves and does not run the gate when the setting is off',
      (tester) async {
        final rig = CodeRig(files: files());
        await rig.pump(tester, step: 'code');
        await tester.tap(find.byKey(const ValueKey('mode-edit')));
        await tester.pumpAndSettle();
        controllerOf(tester).text = 'saved\n';
        await tester.pump();
        await chord(tester, LogicalKeyboardKey.keyS);
        expect(rig.saves, [('lib/rates.ts', 'saved\n')]);
        expect(rig.gateRuns, isEmpty);
      },
    );

    testWidgets('cmd+S runs the gate after saving when Run on save is on', (
      tester,
    ) async {
      final rig = CodeRig(files: files(), runOnSave: true);
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'saved\n';
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(rig.saves, hasLength(1));
      expect(rig.gateRuns, hasLength(1));
    });

    testWidgets('cmd+S with nothing to save does nothing', (tester) async {
      final rig = CodeRig(files: files(), runOnSave: true);
      await rig.pump(tester, step: 'code');
      await chord(tester, LogicalKeyboardKey.keyS);
      expect(rig.saves, isEmpty);
      expect(rig.gateRuns, isEmpty);
    });
  });

  group('step bar action', () {
    testWidgets('reads Save & run gate while the active file is unsaved', (
      tester,
    ) async {
      final rig = CodeRig(files: files());
      await rig.pump(tester, step: 'code');
      expect(find.text('Review & ship →'), findsOneWidget);
      expect(find.text('Save & run gate'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Save & run gate'), findsOneWidget);
      expect(find.text('Review & ship →'), findsNothing);
    });

    testWidgets('pressing it saves every unsaved file, then runs the gate', (
      tester,
    ) async {
      final rig = CodeRig(files: files());
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', 'edited\n')]);
      expect(rig.gateRuns, [false]);
      expect(find.text('Save & run gate'), findsNothing);
    });

    testWidgets('a failed save does not start the gate and says why', (
      tester,
    ) async {
      final rig = CodeRig(
        files: files(),
        saveError: const HaroApiException(500, 'disk full'),
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.gateRuns, isEmpty);
      expect(find.textContaining('disk full'), findsWidgets);
    });

    testWidgets('other steps are untouched by unsaved edits', (tester) async {
      final rig = CodeRig(files: files());
      final router = await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      expect(find.text('Save & run gate'), findsNothing);
    });
  });
}
