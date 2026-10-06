import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/editor_prefs_provider.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/go_to_line.dart';
import 'package:haro_app/features/workspace/steps/code/syntax.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

const _src = 'one\ntwo\nthree\nfour\nfive\n';

const _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Map<String, FileContent> _files() => {
  'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: _src),
  'README.md': const FileContent(path: 'README.md', content: '# haro\n'),
};

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

CodeEditor _editor(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor).first);

Future<void> _openEdit(WidgetTester t, CodeRig rig) async {
  await rig.pump(t, step: 'code');
  await t.tap(find.byKey(const ValueKey('mode-edit')));
  await t.pumpAndSettle();
}

/// Stands in for the isolate search, which cannot complete under the test clock.
void _fakeMatches(
  CodeFindController fc,
  CodeLineEditingController c,
  List<(int, int)> hits,
) {
  fc.value = fc.value!.copyWith(
    searching: false,
    result: CodeFindResult(
      index: 0,
      option: fc.value!.option,
      codeLines: c.codeLines,
      dirty: false,
      matches: [
        for (final (line, col) in hits)
          CodeLineSelection(
            baseIndex: line,
            baseOffset: col,
            extentIndex: line,
            extentOffset: col + 1,
          ),
      ],
    ),
  );
}

Future<void> _chord(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await t.sendKeyDownEvent(key);
  await t.sendKeyUpEvent(key);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

class _RelatedApi extends HaroApi {
  _RelatedApi() : super(Uri.parse('http://127.0.0.1:1'));

  final calls = <String>[];

  @override
  Future<void> runRelated(String wsId, String path) async => calls.add(path);
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('comment syntax', () {
    test('delimiters per language', () {
      expect(commentSyntaxFor('typescript')?.line, '//');
      expect(commentSyntaxFor('typescript')?.blockOpen, '/*');
      expect(commentSyntaxFor('python')?.line, '#');
      expect(commentSyntaxFor('python')?.blockOpen, isNull);
      expect(commentSyntaxFor('yaml')?.line, '#');
      expect(commentSyntaxFor('sql')?.line, '--');
      expect(commentSyntaxFor('css')?.line, isNull);
      expect(commentSyntaxFor('css')?.blockOpen, '/*');
      expect(commentSyntaxFor('xml')?.blockOpen, '<!--');
      expect(commentSyntaxFor('xml')?.blockClose, '-->');
      expect(commentSyntaxFor('markdown')?.blockClose, '-->');
      expect(commentSyntaxFor('json'), isNull);
      expect(commentSyntaxFor(null), isNull);
    });

    test('every highlight language is either given delimiters or JSON', () {
      for (final lang in [
        'typescript',
        'javascript',
        'python',
        'ruby',
        'bash',
        'go',
        'rust',
        'java',
        'dart',
        'yaml',
        'ini',
        'sql',
        'lua',
        'php',
        'swift',
        'kotlin',
      ]) {
        expect(commentSyntaxFor(lang), isNotNull, reason: lang);
      }
    });

    CodeLineEditingValue run(String? lang, String text, {bool single = true}) {
      final value = CodeLineEditingValue(
        codeLines: CodeLines.fromText(text),
        selection: CodeLineSelection(
          baseIndex: 0,
          baseOffset: 0,
          extentIndex: 0,
          extentOffset: text.length,
        ),
      );
      return commentFormatterFor(lang)!.format(value, '  ', single);
    }

    test('toggles a line comment on and off with the language prefix', () {
      expect(run('typescript', 'let a;').codeLines.first.text, '// let a;');
      expect(run('python', 'x = 1').codeLines.first.text, '# x = 1');
      expect(run('sql', 'select 1').codeLines.first.text, '-- select 1');
      expect(run('typescript', '// let a;').codeLines.first.text, 'let a;');
    });

    test('block comment wraps the selection in the language delimiters', () {
      expect(
        run('xml', '<p>x</p>', single: false).codeLines.first.text,
        '<!-- <p>x</p> -->',
      );
      expect(
        run('css', 'a {}', single: false).codeLines.first.text,
        '/* a {} */',
      );
    });

    test('a language without comments gets no formatter', () {
      expect(commentFormatterFor('json'), isNull);
      expect(commentFormatterFor(null), isNull);
    });

    test('line-only languages leave a block toggle alone', () {
      expect(run('python', 'x', single: false).codeLines.first.text, 'x');
    });
  });

  group('go to line parsing', () {
    test(':n jumps in the active file, path:n names a file', () {
      expect(parseQuickOpenQuery(':42'), const QuickOpenTarget(null, 42));
      expect(parseQuickOpenQuery(' : 7 '), const QuickOpenTarget(null, 7));
      expect(
        parseQuickOpenQuery('lib/rates.ts:12'),
        const QuickOpenTarget('lib/rates.ts', 12),
      );
      expect(
        parseQuickOpenQuery('rates : 3'),
        const QuickOpenTarget('rates', 3),
      );
    });

    test('ordinary searches are not targets', () {
      expect(parseQuickOpenQuery(''), isNull);
      expect(parseQuickOpenQuery('rates'), isNull);
      expect(parseQuickOpenQuery(':'), isNull);
      expect(parseQuickOpenQuery(':abc'), isNull);
      expect(parseQuickOpenQuery('a:b'), isNull);
      expect(parseQuickOpenQuery('rates.ts:'), isNull);
    });

    test('the footer field accepts a number with or without a colon', () {
      expect(parseLineNumber('12'), 12);
      expect(parseLineNumber(':12'), 12);
      expect(parseLineNumber(' 3 '), 3);
      expect(parseLineNumber(''), isNull);
      expect(parseLineNumber('x'), isNull);
      expect(parseLineNumber('-4'), isNull);
    });

    test('a line past the end lands on the last line, zero on the first', () {
      expect(lineIndexFor(3, 10), 2);
      expect(lineIndexFor(99, 10), 9);
      expect(lineIndexFor(0, 10), 0);
      expect(lineIndexFor(5, 0), 0);
    });

    test('image paths: raster only, svg stays text', () {
      for (final p in ['a.png', 'x/b.JPG', 'c.jpeg', 'd.gif', 'e.webp']) {
        expect(isImagePath(p), isTrue, reason: p);
      }
      expect(isImagePath('f.bmp'), isTrue);
      expect(isImagePath('g.ico'), isTrue);
      expect(isImagePath('logo.svg'), isFalse);
      expect(isImagePath('png'), isFalse);
      expect(isImagePath('notes.txt'), isFalse);
    });
  });

  group('word wrap pref', () {
    test('defaults off and round trips through json', () {
      expect(const EditorPrefs().wordWrap, isFalse);
      final back = EditorPrefs.fromJson(
        const EditorPrefs(wordWrap: true).toJson(),
      );
      expect(back.wordWrap, isTrue);
      expect(back.fontSize, 13);
      expect(EditorPrefs.fromJson(const {}).wordWrap, isFalse);
      expect(const EditorPrefs().copyWith(wordWrap: true).minimap, isTrue);
    });

    testWidgets('is handed to the editor and follows Settings', (t) async {
      await _openEdit(t, CodeRig(files: _files()));
      expect(_editor(t).wordWrap, isFalse);
      _container(t)
          .read(editorPrefsProvider.notifier)
          .set(const EditorPrefs(wordWrap: true));
      await t.pumpAndSettle();
      expect(_editor(t).wordWrap, isTrue);
    });
  });

  group('find and replace', () {
    Future<(CodeFindController, CodeLineEditingController)> openFind(
      WidgetTester t,
    ) async {
      await _openEdit(t, CodeRig(files: _files()));
      final fc = _editor(t).findController!;
      fc.findMode();
      await t.pumpAndSettle();
      return (fc, _editor(t).controller!);
    }

    testWidgets('the bar is one row until replace mode is on', (t) async {
      final (fc, _) = await openFind(t);
      expect(fc.value!.replaceMode, isFalse);
      expect(_key('replace-input'), findsNothing);
      await t.tap(_key('find-toggle-replace'));
      await t.pumpAndSettle();
      expect(fc.value!.replaceMode, isTrue);
      expect(_key('replace-input'), findsOneWidget);
      expect(t.getSize(find.byType(FindBar)).height, FindBar.replaceHeight);
    });

    testWidgets('replace changes the current match only', (t) async {
      final (fc, c) = await openFind(t);
      await t.tap(_key('find-toggle-replace'));
      await t.pumpAndSettle();
      await t.enterText(_key('find-input'), 'o');
      await t.pumpAndSettle();
      _fakeMatches(fc, c, [(0, 1 - 1), (1, 2), (3, 1)]);
      await t.pumpAndSettle();
      await t.enterText(_key('replace-input'), '0');
      await t.pumpAndSettle();
      await t.tap(_key('find-replace'));
      await t.pumpAndSettle();
      expect(c.text.split('\n').take(4), ['0ne', 'two', 'three', 'four']);
    });

    testWidgets('replace all rewrites every match', (t) async {
      final (fc, c) = await openFind(t);
      await t.tap(_key('find-toggle-replace'));
      await t.pumpAndSettle();
      await t.enterText(_key('find-input'), 'o');
      await t.pumpAndSettle();
      _fakeMatches(fc, c, [(0, 1 - 1), (1, 2), (3, 1)]);
      await t.pumpAndSettle();
      await t.enterText(_key('replace-input'), '0');
      await t.pumpAndSettle();
      await t.tap(_key('find-replace-all'));
      await t.pumpAndSettle();
      expect(c.text.split('\n').take(4), ['0ne', 'tw0', 'three', 'f0ur']);
    });
  });

  group('go to line', () {
    testWidgets('the palette command opens a footer field that jumps', (
      t,
    ) async {
      await _openEdit(t, CodeRig(files: _files()));
      expect(find.byKey(const ValueKey('go-to-line-field')), findsNothing);
      _container(t).read(appCommandsProvider).goToLine();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('go-to-line-field')), findsOneWidget);

      await t.enterText(find.byKey(const ValueKey('go-to-line-field')), '4');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('go-to-line-field')), findsNothing);
      expect(_editor(t).controller!.selection.baseIndex, 3);
    });

    testWidgets('a number past the end lands on the last line; junk stays', (
      t,
    ) async {
      await _openEdit(t, CodeRig(files: _files()));
      _container(t).read(appCommandsProvider).goToLine();
      await t.pumpAndSettle();
      final field = find.byKey(const ValueKey('go-to-line-field'));
      await t.enterText(field, 'x');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(field, findsOneWidget);

      await t.enterText(field, ':999');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      final lines = _editor(t).controller!.codeLines.length;
      expect(_editor(t).controller!.selection.baseIndex, lines - 1);
    });

    testWidgets('esc closes the field', (t) async {
      await _openEdit(t, CodeRig(files: _files()));
      _container(t).read(appCommandsProvider).goToLine();
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('go-to-line-field')), findsNothing);
    });

    testWidgets('cmd+P with :3 jumps the active file and opens nothing', (
      t,
    ) async {
      await _openEdit(t, CodeRig(files: _files()));
      await _chord(t, LogicalKeyboardKey.keyP);
      await t.enterText(find.byType(TextField).last, ':3');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-open-line')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-open-line')), findsNothing);
      expect(_editor(t).controller!.selection.baseIndex, 2);
      final tabs = _container(t).read(editorTabsProvider(id));
      expect(tabs.activePath, 'lib/rates.ts');
    });

    testWidgets('cmd+P with path:line opens that file at the line', (t) async {
      await _openEdit(
        t,
        CodeRig(
          files: _files(),
          tree: [
            dir('lib', [file('lib/rates.ts')]),
            file('README.md'),
          ],
        ),
      );
      await _chord(t, LogicalKeyboardKey.keyP);
      await t.enterText(find.byType(TextField).last, 'README:1');
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      final tabs = _container(t).read(editorTabsProvider(id));
      expect(tabs.activePath, 'README.md');
    });
  });

  group('palette: run the tests touching this file', () {
    Future<(_RelatedApi, CodeRig)> rigFor(
      WidgetTester t, {
      required bool supported,
    }) async {
      final api = _RelatedApi();
      final rig = CodeRig(files: _files())
        ..extra.addAll([
          haroApiProvider.overrideWithValue(api),
          workspaceImpactProvider.overrideWith(
            (ref, id) async =>
                ImpactResponse(baseRef: 'main', supported: supported),
          ),
        ]);
      await _openEdit(t, rig);
      return (api, rig);
    }

    testWidgets('runs the active source file and opens the Gate tab', (
      t,
    ) async {
      final (api, _) = await rigFor(t, supported: true);
      _container(t).read(appCommandsProvider).runRelatedTests();
      await t.pumpAndSettle();
      expect(api.calls, ['lib/rates.ts']);
      expect(
        _container(t).read(bottomPanelProvider(id)).showing(BottomTab.gate),
        isTrue,
      );
    });

    testWidgets('a runner that cannot do it says so and starts nothing', (
      t,
    ) async {
      final (api, _) = await rigFor(t, supported: false);
      _container(t).read(appCommandsProvider).runRelatedTests();
      await t.pumpAndSettle();
      expect(api.calls, isEmpty);
      expect(
        find.text('No test run is available for this file.'),
        findsOneWidget,
      );
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
    });
  });

  group('image preview', () {
    final guardedPng = FileContent(
      path: 'assets/logo.png',
      error: 'binary file',
      size: 2048,
      etag: 'abc',
    );

    setUp(() {
      imageProviderFor = (url) => MemoryImage(base64Decode(_tinyPng));
    });
    tearDown(() => imageProviderFor = NetworkImage.new);

    testWidgets('a guarded png shows the picture and a size caption', (
      t,
    ) async {
      final rig = CodeRig(files: {'assets/logo.png': guardedPng});
      await rig.pump(t, step: 'code');
      _container(t)
          .read(editorTabsProvider(id).notifier)
          .open('assets/logo.png', preview: false);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('mode-edit')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-preview')), findsOneWidget);
      expect(find.textContaining('Not opened'), findsNothing);
      expect(
        t.widget<Text>(find.byKey(const ValueKey('image-caption'))).data,
        'logo.png · 2 KB',
      );
    });

    testWidgets('the url carries a version so a rewrite is not served stale', (
      t,
    ) async {
      final urls = <String>[];
      imageProviderFor = (url) {
        urls.add(url);
        return MemoryImage(base64Decode(_tinyPng));
      };
      final rig = CodeRig(files: {'assets/logo.png': guardedPng});
      await rig.pump(t, step: 'code');
      _container(t)
          .read(editorTabsProvider(id).notifier)
          .open('assets/logo.png', preview: false);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('mode-edit')));
      await t.pumpAndSettle();
      expect(urls, isNotEmpty);
      expect(urls.last, contains('/raw'));
      expect(urls.last, contains('path=assets%2Flogo.png'));
      expect(urls.last, contains('v='));
    });

    testWidgets('another guarded file keeps the not-opened note', (t) async {
      final rig = CodeRig(
        files: {
          'dist/app.zip': const FileContent(
            path: 'dist/app.zip',
            error: 'binary file',
            size: 10,
          ),
          'logo.svg': const FileContent(
            path: 'logo.svg',
            error: 'too large',
            size: 99,
          ),
        },
      );
      await rig.pump(t, step: 'code');
      final tabs = _container(t).read(editorTabsProvider(id).notifier);
      tabs.open('dist/app.zip', preview: false);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('mode-edit')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-preview')), findsNothing);
      expect(find.textContaining('Not opened: binary file'), findsOneWidget);

      tabs.open('logo.svg', preview: false);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-preview')), findsNothing);
      expect(find.textContaining('Not opened: too large'), findsOneWidget);
    });
  });
}

Finder _key(String k) => find.byKey(ValueKey(k));
