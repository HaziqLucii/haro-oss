import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/editor/lsp_hover_layer.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_providers.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../lsp/fake_lsp.dart';
import '../../harness.dart';
import 'code_harness.dart';

const _root = '/work/tree';
const _src = 'const answer = 42;\nexport const other = answer;\n';

Map<String, FileContent> _files() => {
  'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: _src),
  'lib/zones.ts': const FileContent(
    path: 'lib/zones.ts',
    content:
        'export const z = 1;\nexport const zone = 2;\nexport const w = 3;\n',
  ),
  'README.md': const FileContent(path: 'README.md', content: '# haro\n'),
  'lib/fold.ts': const FileContent(path: 'lib/fold.ts', content: _folding),
};

const _folding = 'function f() {\n  a;\n  b;\n}\nconst x = 1;\n';

Map<String, Object?> _loc(String uri, int line, int character) => {
  'uri': uri,
  'range': {
    'start': {'line': line, 'character': character},
    'end': {'line': line, 'character': character + 1},
  },
};

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

Future<FakeLspServer> _open(WidgetTester t, String path) async {
  final server = FakeLspServer();
  final rig = CodeRig(files: _files())
    ..extra.add(
      lspClientProvider.overrideWith((ref, id) {
        final c = LspClient(connect: () => server, rootPath: _root);
        ref.onDispose(c.dispose);
        return c;
      }),
    );
  await rig.pump(t, step: 'code');
  _container(t)
      .read(editorTabsProvider(id).notifier)
      .open(path, preview: false, mode: CodeMode.edit);
  await t.pumpAndSettle();
  await _focusEditor(t);
  return server;
}

/// F12 is bound inside the editor, so the editor needs focus: a click in the empty area.
Future<void> _focusEditor(WidgetTester t) async {
  final box = find.byType(CodeEditor).first;
  await t.tapAt(t.getBottomRight(box) - const Offset(40, 40));
  await t.pumpAndSettle();
}

CodeLineEditingController _controller(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor).first).controller!;

EditorTabsState _tabs(WidgetTester t) =>
    _container(t).read(editorTabsProvider(id));

Future<void> _f12(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.f12);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('go to definition', () {
    testWidgets('F12 opens an in-workspace target at its line and column', (
      t,
    ) async {
      final server = await _open(t, 'lib/rates.ts');
      server.definitions.add(_loc('file:///work/tree/lib/zones.ts', 1, 13));
      _controller(t).selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 22,
      );
      await t.pumpAndSettle();
      await _f12(t);

      final params = server
          .byMethod('textDocument/definition')
          .single['params'];
      expect(params, {
        'textDocument': {'uri': 'file:///work/tree/lib/rates.ts'},
        'position': {'line': 1, 'character': 22},
      });
      expect(_tabs(t).activePath, 'lib/zones.ts');
      final sel = _controller(t).selection;
      expect((sel.extentIndex, sel.extentOffset), (1, 13));
    });

    testWidgets('a target in the same file moves the cursor there', (t) async {
      final server = await _open(t, 'lib/rates.ts');
      server.definitions.add(_loc('file:///work/tree/lib/rates.ts', 0, 6));
      _controller(t).selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 22,
      );
      await _f12(t);
      expect(_tabs(t).activePath, 'lib/rates.ts');
      final sel = _controller(t).selection;
      expect((sel.extentIndex, sel.extentOffset), (0, 6));
    });

    testWidgets('with a fold above, the request carries the full-file line', (
      t,
    ) async {
      final server = await _open(t, 'lib/fold.ts');
      final c = _controller(t);
      c.collapseChunk(0, 3);
      c.selection = const CodeLineSelection.collapsed(index: 2, offset: 6);
      await t.pumpAndSettle();
      expect(c.lineCount, isNot(c.codeLines.length));
      await _f12(t);
      final params = server
          .byMethod('textDocument/definition')
          .single['params'];
      expect((params as Map)['position'], {'line': 4, 'character': 6});
    });

    testWidgets('a target hidden in a fold unfolds it and lands on the line', (
      t,
    ) async {
      final server = await _open(t, 'lib/fold.ts');
      server.definitions.add(_loc('file:///work/tree/lib/fold.ts', 2, 2));
      final c = _controller(t);
      c.collapseChunk(0, 3);
      c.selection = const CodeLineSelection.collapsed(index: 2, offset: 6);
      await t.pumpAndSettle();
      await _f12(t);
      expect(c.lineCount, c.codeLines.length, reason: 'the fold opened');
      final sel = c.selection;
      expect((sel.extentIndex, sel.extentOffset), (2, 2));
    });

    testWidgets('a target below a fold lands on the right visible line', (
      t,
    ) async {
      final server = await _open(t, 'lib/fold.ts');
      server.definitions.add(_loc('file:///work/tree/lib/fold.ts', 4, 6));
      final c = _controller(t);
      c.collapseChunk(0, 3);
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
      await t.pumpAndSettle();
      await _f12(t);
      expect(c.lineCount, isNot(c.codeLines.length), reason: 'fold stays shut');
      final sel = c.selection;
      expect((sel.extentIndex, sel.extentOffset), (2, 6));
      expect(c.codeLines[2].text, 'const x = 1;');
    });

    testWidgets('the remembered place counts full-file lines', (t) async {
      await _open(t, 'lib/fold.ts');
      final c = _controller(t);
      c.collapseChunk(0, 3);
      c.selection = const CodeLineSelection.collapsed(index: 2, offset: 6);
      await t.pumpAndSettle();
      _container(t)
          .read(editorTabsProvider(id).notifier)
          .open('README.md', preview: false, mode: CodeMode.edit);
      await t.pumpAndSettle();
      final place = _tabs(t).places['lib/fold.ts']!;
      expect((place.line, place.col), (5, 7));
    });

    testWidgets('a dependency outside the worktree shows the toast', (t) async {
      final server = await _open(t, 'lib/rates.ts');
      server.definitions.add(
        _loc('file:///project/node_modules/@types/react/index.d.ts', 10, 2),
      );
      await _f12(t);
      expect(_tabs(t).activePath, 'lib/rates.ts');
      expect(
        find.text(
          'Definition is outside this workspace: node_modules/@types/react/index.d.ts',
        ),
        findsOneWidget,
      );
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('no definition does nothing', (t) async {
      final server = await _open(t, 'lib/rates.ts');
      final before = _controller(t).selection;
      await _f12(t);
      expect(server.definitionCalls, 1);
      expect(_tabs(t).activePath, 'lib/rates.ts');
      expect(_controller(t).selection, before);
      expect(find.textContaining('Definition is outside'), findsNothing);
    });

    testWidgets('an unavailable server is a quiet no-op', (t) async {
      final server = FakeLspServer(
        initializeError: {'code': -32603, 'message': 'no tsserver'},
      );
      final rig = CodeRig(files: _files())
        ..extra.add(
          lspClientProvider.overrideWith((ref, id) {
            final c = LspClient(connect: () => server, rootPath: _root);
            ref.onDispose(c.dispose);
            return c;
          }),
        );
      await rig.pump(t, step: 'code');
      _container(t)
          .read(editorTabsProvider(id).notifier)
          .open('lib/rates.ts', preview: false, mode: CodeMode.edit);
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 5));
      await _focusEditor(t);
      await _f12(t);
      expect(server.byMethod('textDocument/definition'), isEmpty);
      expect(_tabs(t).activePath, 'lib/rates.ts');
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('only a TS/JS buffer registers the command and binds F12', (
      t,
    ) async {
      final server = await _open(t, 'lib/rates.ts');
      var cmd = _container(t).read(appCommandsProvider);
      expect(
        cmd.goToDefinition,
        isNot(equals(const AppCommands().goToDefinition)),
      );

      _container(t)
          .read(editorTabsProvider(id).notifier)
          .open('README.md', preview: false, mode: CodeMode.edit);
      await t.pumpAndSettle();
      await _focusEditor(t);
      cmd = _container(t).read(appCommandsProvider);
      expect(cmd.goToDefinition, equals(const AppCommands().goToDefinition));

      server.definitions.add(_loc('file:///work/tree/lib/zones.ts', 0, 0));
      await _f12(t);
      expect(server.definitionCalls, 0);
      expect(_tabs(t).activePath, 'README.md');
    });

    testWidgets('a plain pane mounted beside a TS pane clears the command', (
      t,
    ) async {
      await _open(t, 'lib/rates.ts');
      // The palette offers the command exactly when it is registered (command_palette.dart).
      bool paletteOffers() =>
          _container(t).read(appCommandsProvider).goToDefinition !=
          const AppCommands().goToDefinition;

      expect(paletteOffers(), isTrue);
      final tabs = _container(t).read(editorTabsProvider(id).notifier);
      tabs.toggleSplit();
      tabs.open('README.md', preview: false, mode: CodeMode.edit);
      await t.pumpAndSettle();
      expect(find.byType(EditPane), findsNWidgets(2));
      expect(
        _container(t).read(appCommandsProvider).goToDefinition,
        equals(const AppCommands().goToDefinition),
      );
      expect(paletteOffers(), isFalse);
    });

    testWidgets('the palette command does the same jump', (t) async {
      final server = await _open(t, 'lib/rates.ts');
      server.definitions.add(_loc('file:///work/tree/lib/zones.ts', 2, 0));
      _container(t).read(appCommandsProvider).goToDefinition();
      await t.pumpAndSettle();
      expect(_tabs(t).activePath, 'lib/zones.ts');
      expect(_controller(t).selection.extentIndex, 2);
    });
  });

  group('identifierAt', () {
    test('finds the word under or right after the pointer column', () {
      const line = 'const answer = 42;';
      expect(identifierAt(line, 8), (start: 6, end: 12));
      expect(identifierAt(line, 12), (start: 6, end: 12));
      expect(identifierAt(line, 13), isNull);
      expect(identifierAt(r'a.$b_1', 4), (start: 2, end: 6));
      expect(identifierAt('', 0), isNull);
    });

    test('a long minified line gives the same answer from any column', () {
      final line = '${'a;' * 4000}needle ${'b;' * 4000}';
      final at = 8000 + 3;
      expect(identifierAt(line, at), (start: 8000, end: 8006));
      expect(identifierAt(line, 8000), (start: 8000, end: 8006));
      expect(identifierAt(line, 8006), (start: 8000, end: 8006));
    });

    test('a word longer than the window is still whole', () {
      final line = '; ${'w' * 900} ;';
      expect(identifierAt(line, 450), (start: 2, end: 902));
    });
  });

  group('hover', () {
    Future<(Offset, FakeLspServer)> wordPoint(WidgetTester t) async {
      final server = await _open(t, 'lib/rates.ts');
      server.hovers.add({
        'contents': {
          'kind': 'markdown',
          'value': '```typescript\nconst answer: 42\n```\n---\ndocs',
        },
      });
      final layer = t.widget<LspHoverLayer>(find.byType(LspHoverLayer));
      final p = layer.indicator.value!.paragraphs.first;
      final r = p.paragraph
          .getRangeRects(const TextRange(start: 6, end: 12))
          .first;
      final origin = t.getTopLeft(find.byType(LspHoverLayer));
      return (
        origin + Offset(layer.textLeft(), 0) + p.offset + r.center,
        server,
      );
    }

    testWidgets('the text area starts where the layer assumes', (t) async {
      await _open(t, 'lib/rates.ts');
      final layer = t.widget<LspHoverLayer>(find.byType(LspHoverLayer));
      final field = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CodeField',
      );
      expect(
        t.getTopLeft(field).dx - t.getTopLeft(find.byType(LspHoverLayer)).dx,
        closeTo(layer.textLeft(), 0.5),
      );
    });

    testWidgets('resting on a word shows the signature, a move off hides it', (
      t,
    ) async {
      final (point, server) = await wordPoint(t);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(point);
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsNothing);
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();

      expect(server.byMethod('textDocument/hover').single['params'], {
        'textDocument': {'uri': 'file:///work/tree/lib/rates.ts'},
        'position': {'line': 0, 'character': 6},
      });
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsOneWidget);
      expect(find.text('const answer: 42'), findsOneWidget);

      await mouse.moveTo(point + const Offset(0, 300));
      await t.pump();
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsNothing);
    });

    testWidgets('typing dismisses the tip', (t) async {
      final (point, _) = await wordPoint(t);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(point);
      await t.pump(const Duration(milliseconds: 450));
      await t.pump();
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsOneWidget);

      _controller(t).replaceSelection('x');
      await t.pump();
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsNothing);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('losing focus dismisses the tip', (t) async {
      final (point, _) = await wordPoint(t);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(point);
      await t.pump(const Duration(milliseconds: 450));
      await t.pump();
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsOneWidget);

      t.widget<CodeEditor>(find.byType(CodeEditor).first).focusNode!.unfocus();
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('lsp-hover-tip')), findsNothing);
    });

    testWidgets('no layer on a file the server does not handle', (t) async {
      await _open(t, 'README.md');
      expect(find.byType(LspHoverLayer), findsNothing);
    });
  });
}
