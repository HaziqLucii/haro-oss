import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_view.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/quick_open.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

Finder row(String path) => find.byKey(ValueKey('file-row:$path'));

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

/// The path of the focused pane's active tab.
String headerPath(WidgetTester t) =>
    containerOf(t).read(editorTabsProvider(id)).activePath!;

Finder dirtyDot(String path) => find.byKey(ValueKey('tab-dirty:$path'));

Color? proofFill(WidgetTester t, String path) {
  final box =
      t
              .widget<Container>(
                find.descendant(
                  of: find.byKey(ValueKey('proof:$path')),
                  matching: find.byType(Container),
                ),
              )
              .decoration!
          as BoxDecoration;
  return box.color;
}

Border proofBorder(WidgetTester t, String path) {
  final box =
      t
              .widget<Container>(
                find.descendant(
                  of: find.byKey(ValueKey('proof:$path')),
                  matching: find.byType(Container),
                ),
              )
              .decoration!
          as BoxDecoration;
  return box.border! as Border;
}

CodeLineEditingController controllerOf(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

Future<void> primaryKey(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await t.sendKeyDownEvent(key);
  await t.sendKeyUpEvent(key);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  testWidgets(
    'changes scope: counts, grouped rows, +a -d, letters, first file open',
    (tester) async {
      final rig = CodeRig(proof: verified());
      await rig.pump(tester, step: 'code');

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('explorer-scope:changes')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      expect(headerPath(tester), 'lib/rates.ts');

      await showChanges(tester);
      expect(find.byKey(const ValueKey('group-row:#lib')), findsOneWidget);
      for (final p in [
        'lib/rates.ts',
        'README.md',
        'lib/zones.ts',
        'lib/old.ts',
      ]) {
        expect(row(p), findsOneWidget);
      }
      expect(
        find.descendant(
          of: row('lib/rates.ts'),
          matching: find.textContaining('+3'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row('lib/rates.ts'),
          matching: find.textContaining('−1'),
        ),
        findsOneWidget,
      );
      String letter(String p) =>
          tester.widget<Text>(find.byKey(ValueKey('letter:$p'))).data!;
      expect(letter('lib/rates.ts'), 'M');
      expect(letter('lib/old.ts'), 'D');
    },
  );

  testWidgets('proof squares: green ran, hollow ink partial, dim no data', (
    tester,
  ) async {
    await CodeRig(proof: verified()).pump(tester, step: 'code');
    await showChanges(tester);
    expect(proofFill(tester, 'lib/zones.ts'), HaroTokens.gate);
    expect(proofFill(tester, 'lib/rates.ts'), HaroTokens.transparent);
    expect(proofBorder(tester, 'lib/rates.ts').top.color, HaroTokens.ink);
    expect(proofBorder(tester, 'README.md').top.color, HaroTokens.ink);
    expect(proofFill(tester, 'lib/old.ts'), HaroTokens.line20);
  });

  testWidgets('with no proof data every square is dim and there is no legend', (
    tester,
  ) async {
    await CodeRig().pump(tester, step: 'code');
    await showChanges(tester);
    for (final p in ['lib/rates.ts', 'lib/zones.ts', 'README.md']) {
      expect(proofFill(tester, p), HaroTokens.line20);
    }
    expect(find.byKey(const ValueKey('proof-legend')), findsNothing);
    expect(find.byKey(const ValueKey('marker-hit')), findsNothing);
    expect(find.byKey(const ValueKey('marker-cold')), findsNothing);
  });

  testWidgets('diff: marker column and legend when the gate left line data', (
    tester,
  ) async {
    await CodeRig(proof: verified()).pump(tester, step: 'code');
    expect(find.byKey(const ValueKey('proof-legend')), findsOneWidget);
    expect(find.textContaining('ran in green suite'), findsOneWidget);
    expect(find.textContaining('never ran'), findsWidgets);

    final hit = tester.widget<Text>(find.byKey(const ValueKey('marker-hit')));
    expect(hit.data, '●');
    expect(hit.style!.color, HaroTokens.gate);
    final cold = tester.widget<Text>(find.byKey(const ValueKey('marker-cold')));
    expect(cold.data, '○');
    expect(cold.style!.color, HaroTokens.ink42);
    // line 4 is a comment (not coverable): 3 added lines, only 2 carry a marker
    expect(find.byKey(const ValueKey('marker-hit')), findsOneWidget);
    expect(find.byKey(const ValueKey('marker-cold')), findsOneWidget);
  });

  testWidgets('diff rows: add and delete tints, signs, hunk header', (
    tester,
  ) async {
    await CodeRig(proof: verified()).pump(tester, step: 'code');
    final rows = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(DiffRow),
        matching: find.byType(ColoredBox),
      ),
    );
    final colors = rows.map((b) => b.color).toSet();
    expect(colors, contains(HaroTokens.diffAddBg));
    expect(colors, contains(HaroTokens.diffDelBg));
    expect(find.textContaining('@@ -1,5 +1,7 @@'), findsOneWidget);
    expect(find.text('+'), findsWidgets);
    expect(find.text('−'), findsWidgets);
    expect(find.textContaining('1 of 3 added lines never ran'), findsOneWidget);
  });

  testWidgets(
    'selecting a row switches the file, marks it open and raises it',
    (tester) async {
      await CodeRig(proof: verified()).pump(tester, step: 'code');
      await showChanges(tester);
      Color? fill(String p) =>
          (tester.widget<Container>(row(p)).decoration! as BoxDecoration).color;
      Color? bar(String p) =>
          ((tester.widget<Container>(row(p)).decoration! as BoxDecoration)
                      .border!
                  as Border)
              .left
              .color;
      expect(bar('lib/rates.ts'), HaroTokens.ink);
      expect(bar('README.md'), HaroTokens.transparent);
      expect(fill('README.md'), isNot(HaroTokens.raised));

      await tester.tap(row('README.md'));
      await tester.pumpAndSettle();
      expect(headerPath(tester), 'README.md');
      expect(fill('README.md'), HaroTokens.raised);
      expect(bar('README.md'), HaroTokens.ink);
      expect(bar('lib/rates.ts'), HaroTokens.transparent);
      expect(find.textContaining('more docs'), findsOneWidget);
    },
  );

  testWidgets('deleted, binary and rename-only files', (tester) async {
    const raw = '''diff --git a/gone.ts b/gone.ts
deleted file mode 100644
index 1111111..0000000
--- a/gone.ts
+++ /dev/null
@@ -1 +0,0 @@
-x
diff --git a/pic.png b/pic.png
index 1111111..2222222 100644
Binary files a/pic.png and b/pic.png differ
diff --git a/a.ts b/b.ts
similarity index 100%
rename from a.ts
rename to b.ts
''';
    await CodeRig(diff: raw).pump(tester, step: 'code');
    await showChanges(tester);
    expect(find.text('DELETED'), findsOneWidget);
    await tester.tap(row('pic.png'));
    await tester.pumpAndSettle();
    expect(find.text('Binary file · not shown'), findsOneWidget);
    await tester.tap(row('b.ts'));
    await tester.pumpAndSettle();
    expect(find.text('RENAMED FROM a.ts'), findsOneWidget);
    expect(headerPath(tester), 'b.ts');
    expect(find.text('No line changes.'), findsOneWidget);
  });

  testWidgets('Diff | Edit toggle loads the file and shows the editor', (
    tester,
  ) async {
    final rig = CodeRig(
      files: {
        'lib/rates.ts': const FileContent(
          path: 'lib/rates.ts',
          content: 'const base = 2;\n',
        ),
      },
    );
    await rig.pump(tester, step: 'code');
    expect(find.byType(CodeEditor), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    expect(rig.reads, ['lib/rates.ts']);
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(controllerOf(tester).text, 'const base = 2;\n');
    expect(find.text('Save'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mode-diff')));
    await tester.pumpAndSettle();
    expect(find.byType(CodeEditor), findsNothing);
    expect(find.byType(DiffRow), findsWidgets);
  });

  testWidgets('guarded files show a note instead of an editor', (tester) async {
    final rig = CodeRig(
      files: {
        'lib/rates.ts': const FileContent(
          path: 'lib/rates.ts',
          error: 'file too large',
          size: 9000000,
        ),
      },
    );
    await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    expect(find.byType(CodeEditor), findsNothing);
    expect(find.textContaining('file too large'), findsOneWidget);
  });

  testWidgets('cmd+S in the editor saves through saveFile', (tester) async {
    final rig = CodeRig(
      files: {
        'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: 'a\n'),
      },
    );
    await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();

    expect(dirtyDot('lib/rates.ts'), findsNothing);
    controllerOf(tester).text = 'a\nb\n';
    await tester.pump();
    expect(dirtyDot('lib/rates.ts'), findsOneWidget);
    expect(find.text('● unsaved'), findsOneWidget);

    await tester.tap(find.byType(CodeEditor));
    await tester.pump();
    await primaryKey(tester, LogicalKeyboardKey.keyS);
    expect(rig.saves, [('lib/rates.ts', 'a\nb\n')]);
    expect(find.text('saved'), findsOneWidget);
    expect(dirtyDot('lib/rates.ts'), findsNothing);
  });

  testWidgets('the Save button saves too, and a failed save shows the error', (
    tester,
  ) async {
    final rig = CodeRig(
      files: {
        'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: 'a\n'),
      },
      saveError: const HaroApiException(500, 'disk full'),
    );
    await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    controllerOf(tester).text = 'changed\n';
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(rig.saves, hasLength(1));
    expect(find.text('Save failed: disk full'), findsOneWidget);
    expect(dirtyDot('lib/rates.ts'), findsOneWidget);
  });

  testWidgets('undoing back to the original clears the unsaved state', (
    tester,
  ) async {
    final rig = CodeRig(
      files: {
        'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: 'a\n'),
      },
    );
    await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    controllerOf(tester).text = 'x\n';
    await tester.pump();
    expect(dirtyDot('lib/rates.ts'), findsOneWidget);
    controllerOf(tester).text = 'a\n';
    await tester.pump();
    expect(dirtyDot('lib/rates.ts'), findsNothing);
  });

  group('unsaved edits and tabs', () {
    Future<CodeRig> dirtyRig(WidgetTester tester) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\n',
          ),
          'README.md': const FileContent(path: 'README.md', content: 'doc\n'),
        },
      );
      await rig.pump(tester, step: 'code');
      await showChanges(tester);
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      return rig;
    }

    testWidgets('switching files never asks and the edits stay in their tab', (
      tester,
    ) async {
      await dirtyRig(tester);
      await tester.tap(row('README.md'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);
      expect(headerPath(tester), 'README.md');
      expect(dirtyDot('lib/rates.ts'), findsOneWidget);
      expect(find.byKey(const ValueKey('tab:lib/rates.ts')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tab:lib/rates.ts')));
      await tester.pumpAndSettle();
      expect(headerPath(tester), 'lib/rates.ts');
      expect(controllerOf(tester).text, 'edited\n');
    });

    testWidgets('coming back never re-reads the file', (tester) async {
      final rig = await dirtyRig(tester);
      await tester.tap(row('README.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab:lib/rates.ts')));
      await tester.pumpAndSettle();
      expect(rig.reads.where((p) => p == 'lib/rates.ts'), hasLength(1));
    });

    testWidgets('closing a dirty tab asks first and keeps it until answered', (
      tester,
    ) async {
      await dirtyRig(tester);
      await tester.tap(find.byKey(const ValueKey('tab-close:lib/rates.ts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unsaved-bar')), findsOneWidget);
      expect(find.text('Unsaved changes in rates.ts.'), findsOneWidget);
      expect(controllerOf(tester).text, 'edited\n');
    });

    testWidgets('keep editing dismisses the question', (tester) async {
      await dirtyRig(tester);
      await tester.tap(find.byKey(const ValueKey('tab-close:lib/rates.ts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('unsaved-keep')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);
      expect(find.byKey(const ValueKey('tab:lib/rates.ts')), findsOneWidget);
      expect(controllerOf(tester).text, 'edited\n');
    });

    testWidgets('discard closes without saving and drops the edits', (
      tester,
    ) async {
      final rig = await dirtyRig(tester);
      await tester.tap(find.byKey(const ValueKey('tab-close:lib/rates.ts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('unsaved-discard')));
      await tester.pumpAndSettle();
      expect(rig.saves, isEmpty);
      expect(find.byKey(const ValueKey('tab:lib/rates.ts')), findsNothing);
      expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);
      expect(dirtyDot('lib/rates.ts'), findsNothing);
    });

    testWidgets('save and close saves then closes', (tester) async {
      final rig = await dirtyRig(tester);
      await tester.tap(find.byKey(const ValueKey('tab-close:lib/rates.ts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('unsaved-save')));
      await tester.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', 'edited\n')]);
      expect(find.byKey(const ValueKey('tab:lib/rates.ts')), findsNothing);
    });

    testWidgets('a failed save keeps the tab and says why', (tester) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\n',
          ),
        },
        saveError: const HaroApiException(500, 'read-only'),
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tab-close:lib/rates.ts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('unsaved-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tab:lib/rates.ts')), findsOneWidget);
      expect(find.text('Save failed: read-only'), findsWidgets);
    });

    testWidgets('closing a clean tab does not ask', (tester) async {
      final rig = CodeRig(
        files: {
          'README.md': const FileContent(path: 'README.md', content: 'doc\n'),
        },
      );
      await rig.pump(tester, step: 'code');
      await showChanges(tester);
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-close:lib/rates.ts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);
      expect(find.byKey(const ValueKey('tab:lib/rates.ts')), findsNothing);
    });

    testWidgets('unsaved edits survive a trip to the Diff tab', (tester) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mode-diff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, 'edited\n');
      expect(rig.reads, ['lib/rates.ts']);
    });
  });

  group('all files', () {
    final tree = [
      dir('lib', [file('lib/rates.ts'), file('lib/util.ts')]),
      file('package.json'),
    ];

    testWidgets('a lazy tree that opens on the file the step showed', (
      tester,
    ) async {
      final rig = CodeRig(
        tree: tree,
        files: {
          'package.json': const FileContent(
            path: 'package.json',
            content: '{}\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      // The first changed file is open, so the folders above it are too.
      expect(find.byKey(const ValueKey('tree-row:lib')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tree-row:lib/rates.ts')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tree-row:lib/util.ts')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('letter:lib'))).data,
        '•',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('letter:lib/rates.ts')))
            .data,
        'M',
      );

      await tester.tap(find.byKey(const ValueKey('tree-row:lib')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tree-row:lib/util.ts')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tree-row:lib')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tree-row:lib/util.ts')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('tree-row:package.json')));
      await tester.pumpAndSettle();
      expect(headerPath(tester), 'package.json');
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(rig.reads, ['package.json']);
    });
  });

  group('go to file', () {
    testWidgets('cmd+P opens quick open, fuzzy pick selects the file', (
      tester,
    ) async {
      final rig = CodeRig(
        tree: [
          dir('lib', [file('lib/rates.ts'), file('lib/util.ts')]),
          file('package.json'),
        ],
        files: {
          'lib/util.ts': const FileContent(path: 'lib/util.ts', content: 'u\n'),
        },
      );
      await rig.pump(tester, step: 'code');
      await primaryKey(tester, LogicalKeyboardKey.keyP);
      expect(find.text('Go to file…'), findsOneWidget);
      expect(find.text('CHANGED'), findsWidgets);

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

      expect(find.text('Go to file…'), findsNothing);
      expect(headerPath(tester), 'lib/util.ts');
      expect(find.byType(CodeEditor), findsOneWidget);
    });

    testWidgets('esc closes without changing the file', (tester) async {
      await CodeRig().pump(tester, step: 'code');
      await primaryKey(tester, LogicalKeyboardKey.keyP);
      expect(find.text('Go to file…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Go to file…'), findsNothing);
      expect(headerPath(tester), 'lib/rates.ts');
    });
  });

  testWidgets('empty state: mono line and a link to the agent step', (
    tester,
  ) async {
    final rig = CodeRig(diff: '');
    final router = await rig.pump(tester, step: 'code');
    expect(find.text('No changes yet.'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('explorer-scope:changes')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('code-empty-agent')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/agent');
  });

  testWidgets('a huge diff is virtualized', (tester) async {
    final b = StringBuffer(
      'diff --git a/big.ts b/big.ts\n--- a/big.ts\n+++ b/big.ts\n@@ -0,0 +1,20000 @@\n',
    );
    for (var i = 0; i < 20000; i++) {
      b.writeln('+const v$i = $i;');
    }
    await CodeRig(diff: b.toString()).pump(tester, step: 'code');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('explorer-scope:changes')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(find.byType(DiffRow).evaluate().length, lessThan(60));
  });

  testWidgets('no overflow at 900x640 with the terminal open', (tester) async {
    final long = 'x' * 600;
    final raw =
        '''diff --git a/a/very/deep/path/to/a/component/with/a/long/name.tsx b/a/very/deep/path/to/a/component/with/a/long/name.tsx
--- a/a/very/deep/path/to/a/component/with/a/long/name.tsx
+++ b/a/very/deep/path/to/a/component/with/a/long/name.tsx
@@ -1,2 +1,3 @@ function veryLongSectionName(withArguments, andMoreArguments)
 const a = 1;
-const b = "$long";
+const b = "$long!";
+const c = 3;
''';
    final rig = CodeRig(diff: raw, proof: verified());
    await rig.pump(tester, size: const Size(900, 640), step: 'code');
    await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DiffRow), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 900x640 with the terminal open, edit mode', (
    tester,
  ) async {
    final rig = CodeRig(
      files: {
        'lib/rates.ts': FileContent(path: 'lib/rates.ts', content: 'a\n' * 200),
      },
    );
    await rig.pump(tester, size: const Size(900, 640), step: 'code');
    await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(CodeEditor), findsOneWidget);
  });
}
