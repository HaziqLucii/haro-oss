import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/edit_buffer.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

CodeLineEditingController controllerOf(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

/// Inside the workspace page; the shell's sidebar "New workspace" is a separate primary.
int enabledPrimaries(WidgetTester t) => t
    .widgetList<HaroButton>(
      find.descendant(
        of: find.byType(WorkspacePage),
        matching: find.byType(HaroButton),
      ),
    )
    .where((b) => b.variant == HaroButtonVariant.primary && b.onPressed != null)
    .length;

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('one primary per page', () {
    for (final p in [Preview.idle, Preview.red, Preview.green]) {
      testWidgets('edit mode, ${p.name}: only the step bar is bone-filled', (
        tester,
      ) async {
        final rig = CodeRig(
          preview: p,
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
        expect(find.text('Save'), findsOneWidget);
        expect(enabledPrimaries(tester), 1);

        controllerOf(tester).text = 'changed\n';
        await tester.pump();
        final save = tester.widget<HaroButton>(
          find.ancestor(
            of: find.text('Save'),
            matching: find.byType(HaroButton),
          ),
        );
        expect(save.onPressed, isNotNull);
        expect(save.variant, HaroButtonVariant.secondary);
        expect(enabledPrimaries(tester), 1);
      });
    }
  });

  group('line endings', () {
    test('detectLineEnding', () {
      expect(detectLineEnding(''), LineEnding.none);
      expect(detectLineEnding('a'), LineEnding.none);
      expect(detectLineEnding('a\nb\n'), LineEnding.lf);
      expect(detectLineEnding('a\r\nb\r\n'), LineEnding.crlf);
      expect(detectLineEnding('a\rb\r'), LineEnding.cr);
      expect(detectLineEnding('a\nb\nc\r\nd\n'), LineEnding.mixed);
      expect(detectLineEnding('a\r\nb\rc'), LineEnding.mixed);
      expect(detectLineEnding('a\r\n\r\n'), LineEnding.crlf);
    });

    testWidgets(
      'a mostly-LF file with one CRLF line is refused, not rewritten',
      (tester) async {
        final rig = CodeRig(
          files: {
            'lib/rates.ts': const FileContent(
              path: 'lib/rates.ts',
              content: 'a\nb\nc\r\nd\n',
            ),
          },
        );
        await rig.pump(tester, step: 'code');
        await tester.tap(find.byKey(const ValueKey('mode-edit')));
        await tester.pumpAndSettle();
        expect(
          find.text('Mixed line endings: edit in your editor'),
          findsOneWidget,
        );
        expect(find.byType(CodeEditor), findsNothing);
        expect(find.text('Save'), findsNothing);
        expect(rig.saves, isEmpty);
      },
    );

    testWidgets('a pure CRLF file round-trips as CRLF', (tester) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\r\nb\r\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        findsNothing,
      );
      controllerOf(tester).text = 'a\nb\nc\n';
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(rig.saves.single.$2, 'a\r\nb\r\nc\r\n');
    });

    testWidgets('a pure LF file saves as LF', (tester) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\nb\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'a\nb\nc\n';
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(rig.saves.single.$2, 'a\nb\nc\n');
    });
  });

  group('diff paths', () {
    test('unquoteGitPath decodes escapes and octal UTF-8 bytes', () {
      expect(unquoteGitPath(r'"a/caf\303\251.txt"'), 'a/café.txt');
      expect(unquoteGitPath(r'"tab\there"'), 'tab\there');
      expect(unquoteGitPath(r'"line\nbreak"'), 'line\nbreak');
      expect(unquoteGitPath(r'"say \"hi\""'), 'say "hi"');
      expect(unquoteGitPath(r'"back\\slash"'), r'back\slash');
      expect(unquoteGitPath(r'"\346\227\245\346\234\254.md"'), '日本.md');
      expect(unquoteGitPath('plain'), 'plain');
    });

    test('---/+++ tab suffix on names with spaces is stripped', () {
      const raw =
          'diff --git a/foo bar.txt b/foo bar.txt\n'
          'index 111..222 100644\n'
          '--- a/foo bar.txt\t\n'
          '+++ b/foo bar.txt\t\n'
          '@@ -1 +1 @@\n-a\n+b\n';
      final f = parseUnifiedDiff(raw).single;
      expect(f.path, 'foo bar.txt');
      expect(f.oldPath, 'foo bar.txt');
      expect(f.basename, 'foo bar.txt');
      expect(f.hunks.single.lines.map((l) => l.text), ['a', 'b']);
    });

    test('quoted paths in the header and on ---/+++', () {
      const raw =
          'diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"\n'
          'index 111..222 100644\n'
          '--- "a/caf\\303\\251.txt"\n'
          '+++ "b/caf\\303\\251.txt"\n'
          '@@ -1 +1 @@\n-a\n+b\n';
      final f = parseUnifiedDiff(raw).single;
      expect(f.path, 'café.txt');
    });

    test('rename between a plain and a quoted name, with spaces', () {
      const raw =
          'diff --git a/old name.txt "b/new caf\\303\\251.txt"\n'
          'similarity index 100%\n'
          'rename from old name.txt\n'
          'rename to "new caf\\303\\251.txt"\n';
      final f = parseUnifiedDiff(raw).single;
      expect(f.tag, DiffFileTag.renamed);
      expect(f.oldPath, 'old name.txt');
      expect(f.newPath, 'new café.txt');
      expect(f.display, 'old name.txt → new café.txt');
    });

    test('rename with spaces on both sides uses the rename lines', () {
      const raw =
          'diff --git a/a b.txt b/c d.txt\n'
          'similarity index 90%\n'
          'rename from a b.txt\n'
          'rename to c d.txt\n'
          'index 111..222 100644\n'
          '--- a/a b.txt\t\n'
          '+++ b/c d.txt\t\n'
          '@@ -1 +1 @@\n-x\n+y\n';
      final f = parseUnifiedDiff(raw).single;
      expect((f.oldPath, f.newPath), ('a b.txt', 'c d.txt'));
    });

    test('a new file: the /dev/null side never becomes a path', () {
      const raw =
          'diff --git a/new one.txt b/new one.txt\n'
          'new file mode 100644\n'
          'index 000..222\n'
          '--- /dev/null\n'
          '+++ b/new one.txt\t\n'
          '@@ -0,0 +1 @@\n+hi\n';
      final f = parseUnifiedDiff(raw).single;
      expect(f.tag, DiffFileTag.added);
      expect(f.path, 'new one.txt');
    });

    test('real git output for awkward names', () {
      final which = Process.runSync('git', ['--version']);
      if (which.exitCode != 0) return;
      final dir = Directory.systemTemp.createTempSync('haro-diff-');
      addTearDown(() => dir.deleteSync(recursive: true));
      String git(List<String> args) {
        final r = Process.runSync('git', [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          '-c',
          'core.quotepath=true',
          ...args,
        ], workingDirectory: dir.path);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return r.stdout as String;
      }

      git(['init', '-q']);
      File('${dir.path}/foo bar.txt').writeAsStringSync('one\n');
      File('${dir.path}/café.txt').writeAsStringSync('one\n');
      File('${dir.path}/rename me.txt').writeAsStringSync('same\nsame\nsame\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'init']);
      File('${dir.path}/foo bar.txt').writeAsStringSync('two\n');
      File('${dir.path}/café.txt').writeAsStringSync('two\n');
      git(['mv', 'rename me.txt', 'renamed café.txt']);
      File('${dir.path}/new "quoted".txt').writeAsStringSync('n\n');
      git(['add', '-A']);

      final files = parseUnifiedDiff(git(['diff', '--cached', '-M']));
      final byPath = {for (final f in files) f.path: f};
      expect(
        byPath.keys,
        containsAll(<String>[
          'foo bar.txt',
          'café.txt',
          'renamed café.txt',
          'new "quoted".txt',
        ]),
      );
      expect(byPath['foo bar.txt']!.additions, 1);
      expect(byPath['café.txt']!.deletions, 1);
      final renamed = byPath['renamed café.txt']!;
      expect(renamed.tag, DiffFileTag.renamed);
      expect(renamed.oldPath, 'rename me.txt');
      expect(byPath['new "quoted".txt']!.tag, DiffFileTag.added);
    });
  });

  group('unsaved edits outlive the step', () {
    testWidgets('edit, go to verify, come back: still there and dirty', (
      tester,
    ) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\n',
          ),
        },
      );
      final router = await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      expect(
        find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        findsOneWidget,
      );

      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsNothing);

      router.go('/w/$id/code');
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(controllerOf(tester).text, 'edited\n');
      expect(find.text('● unsaved'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        findsOneWidget,
      );
      expect(rig.reads, ['lib/rates.ts']);
    });

    testWidgets('a saved buffer is dropped and re-read on return', (
      tester,
    ) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\n',
          ),
        },
      );
      final router = await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      controllerOf(tester).text = 'edited\n';
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        findsNothing,
      );

      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      router.go('/w/$id/code');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tab-dirty:lib/rates.ts')),
        findsNothing,
      );
      expect(controllerOf(tester).text, 'edited\n');
      // Open, the disk check before the save, and the re-read on return.
      expect(rig.reads, ['lib/rates.ts', 'lib/rates.ts', 'lib/rates.ts']);
    });
  });
}
