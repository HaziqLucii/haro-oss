import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/code_step.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart'
    show codeEditorHighlighting;
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/fs_sync.dart'
    show fsTreeDebounce;
import 'package:haro_app/features/workspace/steps/code/quick_open.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/search_model.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_state.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../../harness.dart';
import '../code_harness.dart';

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeStep)));

EditorTabsState tabs(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id));

WorkbenchState wb(WidgetTester t) => containerOf(t).read(workbenchProvider(id));

Finder key(String k) => find.byKey(ValueKey(k));

class FsTicker extends FixedDetail {
  FsTicker(super.id, super.value);

  void tick() => state = state.copyWith(
    fsRevision: state.fsRevision + 1,
    lastFs: FsEvent(
      'changed',
      workspaceId: id,
      paths: [FsPathChange('lib/zones.ts', FsChange.modified)],
      truncated: false,
    ),
  );
}

Finder treeRow(String path) => key('tree-row:$path');

final tree = [
  dir('lib', [file('lib/rates.ts'), file('lib/zones.ts'), file('lib/util.ts')]),
  file('README.md'),
  file('package.json'),
];

Future<void> primary(WidgetTester t, LogicalKeyboardKey k) async {
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

GitFileStatus status(String path, {String index = '', String work = ''}) =>
    GitFileStatus(
      path: path,
      index: index,
      work: work,
      staged: index.isNotEmpty,
    );

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('activity bar', () {
    testWidgets(
      'four icons; the active one is marked and clicking it closes the panel',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        for (final k in ['files', 'search', 'changes', 'gate']) {
          expect(key('activity:$k'), findsOneWidget);
        }
        expect(
          find.descendant(
            of: key('activity:files'),
            matching: key('activity-marker'),
          ),
          findsOneWidget,
        );
        expect(key('side-panel'), findsOneWidget);

        await tester.tap(key('activity:files'));
        await tester.pumpAndSettle();
        expect(key('side-panel'), findsNothing);
        expect(wb(tester).sideOpen, isFalse);

        await tester.tap(key('activity:search'));
        await tester.pumpAndSettle();
        expect(key('side-panel'), findsOneWidget);
        expect(find.text('SEARCH'), findsOneWidget);
        expect(
          find.descendant(
            of: key('activity:search'),
            matching: key('activity-marker'),
          ),
          findsOneWidget,
        );

        await tester.tap(key('activity:changes'));
        await tester.pumpAndSettle();
        expect(find.text('CHANGES · 0'), findsOneWidget);
      },
    );

    testWidgets('the Changes icon carries the count of changed files', (
      tester,
    ) async {
      await CodeRig(
        tree: tree,
        gitFiles: [
          status('lib/rates.ts', work: 'modified'),
          status('new.ts', work: 'untracked'),
        ],
      ).pump(tester, step: 'code');
      expect(
        find.descendant(
          of: key('activity-badge:changes'),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'the Gate icon opens the bottom panel on its Gate tab and toggles it',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        await tester.tap(key('activity:gate'));
        await tester.pumpAndSettle();
        final c = containerOf(tester);
        expect(c.read(bottomPanelProvider(id)).showing(BottomTab.gate), isTrue);
        expect(
          find.descendant(
            of: key('activity:gate'),
            matching: key('activity-marker'),
          ),
          findsOneWidget,
        );
        await tester.tap(key('activity:gate'));
        await tester.pumpAndSettle();
        expect(c.read(bottomPanelProvider(id)).open, isFalse);
      },
    );

    testWidgets('the bar and the panel both run the full height of the step', (
      tester,
    ) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      final bar = tester.getSize(key('activity-bar')).height;
      expect(bar, tester.getSize(key('side-panel')).height);
      expect(bar, greaterThan(300));
    });

    testWidgets('cmd+B toggles the side panel', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await primary(tester, LogicalKeyboardKey.keyB);
      expect(key('side-panel'), findsNothing);
      await primary(tester, LogicalKeyboardKey.keyB);
      expect(key('side-panel'), findsOneWidget);
    });

    testWidgets('dragging the edge resizes within 220 to 460', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      expect(tester.getSize(key('side-panel')).width, 250);
      await tester.drag(key('side-resize'), const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(key('side-panel')).width,
        inInclusiveRange(285, 310),
      );
      await tester.drag(key('side-resize'), const Offset(900, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(key('side-panel')).width, 460);
      await tester.drag(key('side-resize'), const Offset(-900, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(key('side-panel')).width, 220);
    });
  });

  group('explorer', () {
    testWidgets(
      'the step opens the first changed file as a preview and opens its folders',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        expect(tabs(tester).activePath, 'lib/rates.ts');
        expect(tabs(tester).focused.tabs.single.preview, isTrue);
        expect(treeRow('lib/zones.ts'), findsOneWidget);
      },
    );

    testWidgets(
      'a click previews, a second quick click pins, both replace the preview',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        await tester.tap(treeRow('README.md'));
        await tester.pumpAndSettle();
        var t = tabs(tester).focused.tabs;
        expect([for (final x in t) x.path], ['README.md']);
        expect(t.single.preview, isTrue);

        await tester.tap(treeRow('lib/zones.ts'));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(treeRow('lib/zones.ts'));
        await tester.pumpAndSettle();
        t = tabs(tester).focused.tabs;
        expect([for (final x in t) x.path], ['lib/zones.ts']);
        expect(t.single.preview, isFalse);
      },
    );

    testWidgets('a folder row toggles open and closed', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await tester.tap(treeRow('lib'));
      await tester.pumpAndSettle();
      expect(treeRow('lib/zones.ts'), findsNothing);
      await tester.tap(treeRow('lib'));
      await tester.pumpAndSettle();
      expect(treeRow('lib/zones.ts'), findsOneWidget);
    });

    testWidgets('arrows move the row, Right/Left fold, Enter opens pinned', (
      tester,
    ) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await tester.tap(treeRow('lib'));
      await tester.pumpAndSettle();
      expect(wb(tester).cursor, 'lib');
      expect(treeRow('lib/zones.ts'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(treeRow('lib/zones.ts'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(wb(tester).cursor, 'lib/util.ts');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(wb(tester).cursor, 'lib');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tabs(tester).activePath, 'lib/rates.ts');
      expect(
        tabs(tester).focused.tabs
            .singleWhere((x) => x.path == 'lib/rates.ts')
            .preview,
        isFalse,
      );
    });

    testWidgets(
      'the filter narrows the tree to matches and the folders above',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        await tester.enterText(key('explorer-filter'), 'util');
        await tester.pumpAndSettle();
        expect(treeRow('lib'), findsOneWidget);
        expect(treeRow('lib/util.ts'), findsOneWidget);
        expect(treeRow('lib/zones.ts'), findsNothing);
        expect(treeRow('README.md'), findsNothing);

        await tester.enterText(key('explorer-filter'), 'nothing-here');
        await tester.pumpAndSettle();
        expect(find.text('No files match.'), findsOneWidget);
      },
    );

    testWidgets('collapse all folds every folder', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await tester.tap(key('explorer-collapse'));
      await tester.pumpAndSettle();
      expect(treeRow('lib/zones.ts'), findsNothing);
      expect(treeRow('lib'), findsOneWidget);
    });

    testWidgets('reveal finds the open file after the tree was folded', (
      tester,
    ) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await tester.tap(key('explorer-collapse'));
      await tester.pumpAndSettle();
      await tester.tap(key('explorer-reveal'));
      await tester.pumpAndSettle();
      expect(treeRow('lib/rates.ts'), findsOneWidget);
      expect(wb(tester).cursor, 'lib/rates.ts');
    });

    testWidgets(
      'git letters: A in green, M in ink, a dot on folders with changes',
      (tester) async {
        const raw = '''diff --git a/lib/new.ts b/lib/new.ts
new file mode 100644
--- /dev/null
+++ b/lib/new.ts
@@ -0,0 +1 @@
+x
diff --git a/lib/rates.ts b/lib/rates.ts
--- a/lib/rates.ts
+++ b/lib/rates.ts
@@ -1 +1 @@
-a
+b
''';
        await CodeRig(
          diff: raw,
          tree: [
            dir('lib', [file('lib/new.ts'), file('lib/rates.ts')]),
          ],
        ).pump(tester, step: 'code');
        Text letter(String p) => tester.widget<Text>(key('letter:$p'));
        expect(letter('lib/new.ts').data, 'A');
        expect(letter('lib/new.ts').style!.color, HaroTokens.gate);
        expect(letter('lib/rates.ts').data, 'M');
        expect(letter('lib/rates.ts').style!.color, HaroTokens.ink);
        expect(letter('lib').data, '•');
      },
    );

    testWidgets('the legend and the also-open-in control sit under the list', (
      tester,
    ) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      expect(key('side-legend'), findsOneWidget);
      expect(find.textContaining('has changes'), findsOneWidget);
      expect(key('also-open-in'), findsOneWidget);
    });

    testWidgets('the Changes scope keeps the proof squares and +/- counts', (
      tester,
    ) async {
      await CodeRig(tree: tree, proof: verified()).pump(tester, step: 'code');
      await showChanges(tester);
      expect(key('proof:lib/zones.ts'), findsOneWidget);
      expect(
        find.descendant(
          of: key('file-row:lib/rates.ts'),
          matching: find.textContaining('+3'),
        ),
        findsOneWidget,
      );
    });
  });

  group('context menu', () {
    testWidgets(
      'a changed file: open, side, rename, copy, diff, also open in, delete',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        await rightClick(tester, treeRow('lib/zones.ts'));
        for (final l in [
          'Open',
          'Open to the side',
          'Rename',
          'Copy path',
          'Copy relative path',
          'Show diff',
          'Delete',
        ]) {
          expect(find.text(l).last, findsOneWidget, reason: l);
        }
        expect(find.textContaining('Also open in'), findsWidgets);
        expect(find.text('F2'), findsOneWidget);
      },
    );

    testWidgets('an unchanged file has no Show diff', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await rightClick(tester, treeRow('lib/util.ts'));
      expect(find.text('Show diff'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets(
      'a folder: new file here, new folder, rename, copy path, reveal, open folder in',
      (tester) async {
        await CodeRig(tree: tree).pump(tester, step: 'code');
        await rightClick(tester, treeRow('lib'));
        for (final l in [
          'New file here',
          'New folder',
          'Rename',
          'Copy path',
          'Reveal in file manager',
        ]) {
          expect(find.text(l).last, findsOneWidget, reason: l);
        }
        expect(find.textContaining('Open folder in'), findsOneWidget);
        expect(find.text('Delete'), findsNothing);
      },
    );

    testWidgets('Open to the side splits the editor and pins the file there', (
      tester,
    ) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await rightClick(tester, treeRow('lib/zones.ts'));
      await tester.tap(find.text('Open to the side'));
      await tester.pumpAndSettle();
      final s = tabs(tester);
      expect(s.panes, hasLength(2));
      expect(s.focusedPane, 1);
      expect(s.panes[1].tabs.single.path, 'lib/zones.ts');
      expect(s.panes[1].tabs.single.preview, isFalse);
    });

    testWidgets('Rename asks for the new path and renames', (tester) async {
      final rig = CodeRig(tree: tree);
      await rig.pump(tester, step: 'code');
      await rightClick(tester, treeRow('lib/util.ts'));
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      await tester.enterText(key('dialog-input'), 'lib/helpers.ts');
      await tester.tap(key('dialog-confirm'));
      await tester.pumpAndSettle();
      expect(rig.ops, ['rename:lib/util.ts:lib/helpers.ts']);
      expect(key('workbench-dialog'), findsNothing);
    });

    testWidgets('Delete confirms first, then deletes and closes the tab', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree);
      await rig.pump(tester, step: 'code');
      expect(tabs(tester).activePath, 'lib/rates.ts');
      await rightClick(tester, treeRow('lib/rates.ts'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete rates.ts?'), findsOneWidget);
      expect(rig.ops, isEmpty);

      await tester.tap(key('dialog-cancel'));
      await tester.pumpAndSettle();
      expect(rig.ops, isEmpty);
      expect(tabs(tester).activePath, 'lib/rates.ts');

      await rightClick(tester, treeRow('lib/rates.ts'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(key('dialog-confirm'));
      await tester.pumpAndSettle();
      expect(rig.ops, ['delete:lib/rates.ts']);
      expect(tabs(tester).activePath, isNull);
    });

    testWidgets('New file here starts in the folder and opens the new file', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree);
      await rig.pump(tester, step: 'code');
      await rightClick(tester, treeRow('lib'));
      await tester.tap(find.text('New file here'));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.descendant(
          of: key('dialog-input'),
          matching: find.byType(TextField),
        ),
      );
      expect(input.controller!.text, 'lib/');
      await tester.enterText(key('dialog-input'), 'lib/fresh.ts');
      await tester.tap(key('dialog-confirm'));
      await tester.pumpAndSettle();
      expect(rig.ops, ['create:lib/fresh.ts:file']);
      expect(tabs(tester).activePath, 'lib/fresh.ts');
    });

    testWidgets('the header + button creates in the cursor folder', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree);
      await rig.pump(tester, step: 'code');
      await tester.tap(treeRow('lib/util.ts'));
      await tester.pumpAndSettle();
      await tester.tap(key('explorer-new-file'));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.descendant(
          of: key('dialog-input'),
          matching: find.byType(TextField),
        ),
      );
      expect(input.controller!.text, 'lib/');
    });
  });

  group('search', () {
    List<Override> results() => [
      workspaceSearchProvider.overrideWith(
        (ref, k) async => SearchResult(
          matches: k.$2 == 'rate'
              ? const [
                  SearchMatch(
                    file: 'lib/rates.ts',
                    line: 3,
                    text: '  const rate = 1;',
                  ),
                  SearchMatch(
                    file: 'lib/rates.ts',
                    line: 9,
                    text: 'export function rate() {',
                  ),
                  SearchMatch(file: 'README.md', line: 1, text: 'rate limits'),
                ]
              : const [],
        ),
      ),
    ];

    testWidgets(
      'results group by file with a count line, and a click opens the line',
      (tester) async {
        final rig = CodeRig(tree: tree)..extra.addAll(results());
        await rig.pump(tester, step: 'code');
        await tester.tap(key('activity:search'));
        await tester.pumpAndSettle();
        await tester.enterText(key('search-query'), 'rate');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(find.text('3 results in 2 files'), findsOneWidget);
        expect(key('search-file:lib/rates.ts'), findsOneWidget);
        expect(key('search-file:README.md'), findsOneWidget);
        expect(key('search-hit:lib/rates.ts:3'), findsOneWidget);

        final jumps = <EditorJump>[];
        containerOf(tester).listen(editorTabsProvider(id), (_, next) {
          if (next.jump != null) jumps.add(next.jump!);
        });
        await tester.tap(key('search-hit:lib/rates.ts:9'));
        await tester.pumpAndSettle();
        final s = tabs(tester);
        expect(s.activePath, 'lib/rates.ts');
        expect(jumps.single.path, 'lib/rates.ts');
        expect(jumps.single.line, 9);
        expect(s.jump, isNull, reason: 'the editor consumed it');
        expect(s.focused.tabs.single.preview, isFalse);
      },
    );

    testWidgets(
      'a group folds; no hits says so; one character searches nothing',
      (tester) async {
        final rig = CodeRig(tree: tree)..extra.addAll(results());
        await rig.pump(tester, step: 'code');
        await tester.tap(key('activity:search'));
        await tester.pumpAndSettle();
        await tester.enterText(key('search-query'), 'r');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.textContaining('result'), findsNothing);

        await tester.enterText(key('search-query'), 'rate');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        await tester.tap(key('search-file:lib/rates.ts'));
        await tester.pumpAndSettle();
        expect(key('search-hit:lib/rates.ts:3'), findsNothing);
        expect(key('search-hit:README.md:1'), findsOneWidget);

        await tester.enterText(key('search-query'), 'zzz');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('No results'), findsOneWidget);
      },
    );

    testWidgets('cmd+shift+F opens the Search panel', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await tester.tap(key('activity:files'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pumpAndSettle();
      expect(wb(tester).view, WorkbenchView.search);
      expect(key('search-query'), findsOneWidget);
    });
  });

  group('changes panel', () {
    final files = [
      status('lib/rates.ts', index: 'modified'),
      status('lib/zones.ts', work: 'modified'),
      status('new.ts', work: 'untracked'),
    ];

    Future<CodeRig> open(WidgetTester tester) async {
      final rig = CodeRig(tree: tree, gitFiles: files);
      await rig.pump(tester, step: 'code');
      await tester.tap(key('activity:changes'));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('lists git changes with checkboxes, staged count and letters', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('CHANGES · 3'), findsOneWidget);
      expect(find.text('1 staged'), findsOneWidget);
      for (final p in ['lib/rates.ts', 'lib/zones.ts', 'new.ts']) {
        expect(key('change-row:$p'), findsOneWidget);
      }
      expect(
        find.descendant(of: key('change-row:new.ts'), matching: find.text('A')),
        findsOneWidget,
      );
    });

    testWidgets('opening the code step refetches a status that predates it', (
      tester,
    ) async {
      final live = <GitFileStatus>[];
      final rig = CodeRig(tree: tree, gitFiles: live);
      await rig.pump(tester);
      expect(rig.statusLoads, 1);
      live.add(status('lib/zones.ts', work: 'modified'));
      await tester.tap(key('step-back'));
      await tester.pumpAndSettle();
      expect(rig.statusLoads, 2);
      expect(key('activity-badge:changes'), findsOneWidget);
    });

    testWidgets('a code step that is the first page loads the status once', (
      tester,
    ) async {
      final rig = CodeRig(tree: tree, gitFiles: [files.first]);
      await rig.pump(tester, step: 'code');
      await tester.pumpAndSettle();
      expect(rig.statusLoads, 1);
    });

    testWidgets(
      'a file edited while another panel is open reaches the badge and the list',
      (tester) async {
        final live = <GitFileStatus>[];
        late FsTicker ticker;
        final rig = CodeRig(
          tree: tree,
          gitFiles: live,
          makeDetail: (i, d) => ticker = FsTicker(i, d),
        );
        await rig.pump(tester, step: 'code');
        await tester.pumpAndSettle();
        expect(key('activity-badge:changes'), findsNothing);

        live.add(status('lib/zones.ts', work: 'modified'));
        ticker.tick();
        await tester.pump(fsTreeDebounce - const Duration(milliseconds: 100));
        expect(key('activity-badge:changes'), findsNothing);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(key('activity-badge:changes'), findsOneWidget);

        await tester.tap(key('activity:changes'));
        await tester.pumpAndSettle();
        expect(find.text('CHANGES · 1'), findsOneWidget);
        expect(key('change-row:lib/zones.ts'), findsOneWidget);
      },
    );

    testWidgets('a checkbox stages or unstages that file', (tester) async {
      final rig = await open(tester);
      await tester.tap(key('stage:lib/zones.ts'));
      await tester.pumpAndSettle();
      await tester.tap(key('stage:lib/rates.ts'));
      await tester.pumpAndSettle();
      expect(rig.ops, ['stage:lib/zones.ts', 'unstage:lib/rates.ts']);
    });

    testWidgets(
      'a partly staged file shows a dash and a click stages the rest',
      (tester) async {
        final rig = CodeRig(
          tree: tree,
          gitFiles: [
            const GitFileStatus(
              path: 'lib/rates.ts',
              index: 'modified',
              work: 'modified',
              staged: true,
              partial: true,
            ),
            status('lib/zones.ts', index: 'modified'),
          ],
        );
        await rig.pump(tester, step: 'code');
        await tester.tap(key('activity:changes'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: key('stage:lib/rates.ts'),
            matching: key('partial-mark'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: key('stage:lib/zones.ts'),
            matching: key('partial-mark'),
          ),
          findsNothing,
        );
        expect(find.text('2 staged'), findsOneWidget);

        await tester.tap(key('stage:lib/rates.ts'));
        await tester.pumpAndSettle();
        expect(rig.ops, ['stage:lib/rates.ts']);
      },
    );

    testWidgets(
      'Stage all still stages while some file is only partly staged',
      (tester) async {
        final rig = CodeRig(
          tree: tree,
          gitFiles: [
            const GitFileStatus(
              path: 'a.ts',
              index: 'modified',
              work: 'modified',
              staged: true,
              partial: true,
            ),
            status('b.ts', index: 'modified'),
          ],
        );
        await rig.pump(tester, step: 'code');
        await tester.tap(key('activity:changes'));
        await tester.pumpAndSettle();
        await tester.tap(key('changes-stage-all'));
        await tester.pumpAndSettle();
        expect(rig.ops, ['stage:a.ts,b.ts']);
      },
    );

    testWidgets('the header tick stages everything, then unstages everything', (
      tester,
    ) async {
      final rig = CodeRig(
        tree: tree,
        gitFiles: [
          status('a.ts', index: 'modified'),
          status('b.ts', work: 'modified'),
        ],
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(key('activity:changes'));
      await tester.pumpAndSettle();
      await tester.tap(key('changes-stage-all'));
      await tester.pumpAndSettle();
      expect(rig.ops, ['stage:a.ts,b.ts']);
    });

    testWidgets(
      'Commit needs a message and something staged, then commits the index',
      (tester) async {
        final rig = await open(tester);
        bool enabled() =>
            tester.widget<HaroButton>(key('commit-button')).onPressed != null;

        expect(enabled(), isFalse);
        await tester.enterText(key('commit-message'), 'fix rates');
        await tester.pump();
        expect(enabled(), isTrue);

        await tester.tap(key('commit-button'));
        await tester.pumpAndSettle();
        expect(rig.commits, ['fix rates']);
        expect(
          tester.widget<TextField>(key('commit-message')).controller!.text,
          isEmpty,
        );
      },
    );

    testWidgets('cmd+Enter in the message box commits too', (tester) async {
      final rig = await open(tester);
      await tester.enterText(key('commit-message'), 'via keyboard');
      await tester.pump();
      await primary(tester, LogicalKeyboardKey.enter);
      expect(rig.commits, ['via keyboard']);
    });

    testWidgets('with nothing staged the button stays off', (tester) async {
      final rig = CodeRig(
        tree: tree,
        gitFiles: [status('a.ts', work: 'modified')],
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(key('activity:changes'));
      await tester.pumpAndSettle();
      await tester.enterText(key('commit-message'), 'msg');
      await tester.pump();
      await tester.tap(key('commit-button'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(rig.commits, isEmpty);
    });

    testWidgets('a row opens the file pinned', (tester) async {
      await open(tester);
      await tester.tap(key('change-row:lib/zones.ts'));
      await tester.pumpAndSettle();
      expect(tabs(tester).activePath, 'lib/zones.ts');
      expect(tabs(tester).focused.tabs.last.preview, isFalse);
    });

    testWidgets('no changes says so', (tester) async {
      await CodeRig(tree: tree).pump(tester, step: 'code');
      await tester.tap(key('activity:changes'));
      await tester.pumpAndSettle();
      expect(find.text('No changes.'), findsOneWidget);
    });
  });

  group('go to file', () {
    testWidgets('a pick opens the file pinned and reveals it in the tree', (
      tester,
    ) async {
      await CodeRig(
        tree: tree,
        files: {
          'lib/util.ts': const FileContent(path: 'lib/util.ts', content: 'u\n'),
        },
      ).pump(tester, step: 'code');
      await tester.tap(key('explorer-collapse'));
      await tester.pumpAndSettle();
      await primary(tester, LogicalKeyboardKey.keyP);
      await tester.enterText(
        find.descendant(
          of: find.byType(QuickOpen),
          matching: find.byType(TextField),
        ),
        'util',
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tabs(tester).activePath, 'lib/util.ts');
      expect(tabs(tester).focused.tabs.last.preview, isFalse);
      expect(treeRow('lib/util.ts'), findsOneWidget);
    });
  });
}
