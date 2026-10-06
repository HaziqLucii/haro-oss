import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_gutter.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/proof_marks.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_providers.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../data/detail_harness.dart' show FakeChannel;
import '../../harness.dart';
import 'code_harness.dart';

Map<String, FileContent> _files() => {
  'lib/rates.ts': const FileContent(
    path: 'lib/rates.ts',
    content: 'one\ntwo\n',
  ),
  'lib/zones.ts': const FileContent(path: 'lib/zones.ts', content: 'z\n'),
  'README.md': const FileContent(path: 'README.md', content: '# haro\n'),
};

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

Future<CodeRig> _open(WidgetTester t, String path) async {
  final rig = CodeRig(files: _files());
  await rig.pump(t, step: 'code');
  await _openMore(t, path);
  await t.tap(find.byKey(const ValueKey('mode-edit')));
  await t.pumpAndSettle();
  return rig;
}

Future<void> _openMore(WidgetTester t, String path) async {
  _container(t)
      .read(editorTabsProvider(id).notifier)
      .open(path, preview: false);
  await t.pumpAndSettle();
}

List<FakeChannel> _lspSockets(CodeRig rig) => [
  for (var i = 0; i < rig.net.uris.length; i++)
    if (rig.net.uris[i].path == '/ws/workspaces/$id/lsp') rig.net.channels[i],
];

List<Map<String, dynamic>> _sent(FakeChannel c, String method) => [
  for (final s in c.sent)
    if ((jsonDecode(s as String) as Map)['method'] == method)
      jsonDecode(s) as Map<String, dynamic>,
];

void _type(CodeLineEditingController c, String text) {
  final sel = c.selection;
  final line = c.codeLines[sel.extentIndex].text;
  final at = sel.extentOffset;
  for (var id = 1; id < 600; id++) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemChannels.textInput.name,
          SystemChannels.textInput.codec.encodeMethodCall(
            MethodCall(
              'TextInputClient.updateEditingStateWithDeltas',
              <dynamic>[
                id,
                <String, dynamic>{
                  'deltas': [
                    {
                      'oldText': line,
                      'deltaText': text,
                      'deltaStart': at,
                      'deltaEnd': at,
                      'selectionBase': at + text.length,
                      'selectionExtent': at + text.length,
                      'selectionAffinity': 'TextAffinity.downstream',
                      'selectionIsDirectional': false,
                      'composingBase': -1,
                      'composingExtent': -1,
                    },
                  ],
                },
              ],
            ),
          ),
          (_) {},
        );
  }
}

Future<CodeLineEditingController> _typeWord(WidgetTester t, String w) async {
  await t.tap(find.byType(CodeEditor).first);
  await t.pumpAndSettle();
  final c = t.widget<EditPane>(find.byType(EditPane)).buffer.controller!;
  c.selection = CodeLineSelection.collapsed(index: c.lineCount - 1, offset: 0);
  await t.pumpAndSettle();
  _type(c, w);
  await t.pump();
  await t.pump(const Duration(milliseconds: 120));
  await t.pump(const Duration(milliseconds: 10));
  return c;
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);
  final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets('a .ts buffer opens the workspace socket and shows the list', (
    t,
  ) async {
    final rig = await _open(t, 'lib/rates.ts');
    final sockets = _lspSockets(rig);
    expect(sockets, hasLength(1));
    final ch = sockets.single;
    final init = _sent(ch, 'initialize').single;
    expect((init['params'] as Map)['rootUri'], startsWith('file:///'));
    ch.deliver({
      'jsonrpc': '2.0',
      'id': init['id'],
      'result': {'capabilities': {}},
    });
    await t.pumpAndSettle();
    final open = _sent(ch, 'textDocument/didOpen').single['params'] as Map;
    expect((open['textDocument'] as Map)['uri'], endsWith('/lib/rates.ts'));
    expect(find.byType(CodeAutocomplete), findsOneWidget);

    await _typeWord(t, 'useSt');
    final req = _sent(ch, 'textDocument/completion').single;
    ch.deliver({
      'jsonrpc': '2.0',
      'id': req['id'],
      'result': [
        {'label': 'useState', 'kind': 6, 'sortText': '11'},
      ],
    });
    await t.pump(const Duration(milliseconds: 10));
    expect(find.byKey(const ValueKey('lsp-completion')), findsOneWidget);
    expect(find.text('useState'), findsOneWidget);
  }, variant: mac);

  testWidgets('a .md buffer gets no socket and no overlay', (t) async {
    final rig = await _open(t, 'README.md');
    expect(_lspSockets(rig), isEmpty);
    expect(find.byType(CodeAutocomplete), findsNothing);
    await _typeWord(t, 'useSt');
    expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
    expect(_lspSockets(rig), isEmpty);
  }, variant: mac);

  testWidgets('one socket per workspace however many ts files open', (t) async {
    final rig = await _open(t, 'lib/rates.ts');
    await _openMore(t, 'lib/zones.ts');
    await _openMore(t, 'lib/rates.ts');
    expect(_lspSockets(rig), hasLength(1));
  }, variant: mac);

  testWidgets('an unavailable server says so once and the editor stays plain', (
    t,
  ) async {
    final rig = await _open(t, 'lib/rates.ts');
    final ch = _lspSockets(rig).single;
    ch.deliver({'haro': 'lsp_unavailable', 'reason': 'not_installed'});
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text(lspInstallHint), findsOneWidget);

    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(find.text(lspInstallHint), findsNothing);
    await _openMore(t, 'lib/zones.ts');
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text(lspInstallHint), findsNothing);

    await _typeWord(t, 'useSt');
    expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
    expect(_sent(ch, 'textDocument/completion'), isEmpty);
  }, variant: mac);

  group('diagnostics', () {
    EditorGutter gutter(WidgetTester t) =>
        t.widget<EditorGutter>(find.byType(EditorGutter));

    const message = "Type 'string' is not assignable to type 'number'.";

    Map<String, Object?> error({int line = 1}) => {
      'range': {
        'start': {'line': line, 'character': 2},
        'end': {'line': line, 'character': 5},
      },
      'severity': 1,
      'code': 2322,
      'source': 'typescript',
      'message': message,
    };

    /// Opens [path], finishes the handshake, and returns its socket and document uri.
    Future<(FakeChannel, String)> openReady(WidgetTester t, String path) async {
      final rig = await _open(t, path);
      final ch = _lspSockets(rig).single;
      final init = _sent(ch, 'initialize').single;
      ch.deliver({
        'jsonrpc': '2.0',
        'id': init['id'],
        'result': {'capabilities': {}},
      });
      await t.pumpAndSettle();
      final open = _sent(ch, 'textDocument/didOpen').single['params'] as Map;
      return (ch, (open['textDocument'] as Map)['uri'] as String);
    }

    Future<void> publish(
      WidgetTester t,
      FakeChannel ch,
      String uri,
      List<Map<String, Object?>> items, {
      int? version,
    }) async {
      ch.deliver({
        'jsonrpc': '2.0',
        'method': 'textDocument/publishDiagnostics',
        'params': {'uri': uri, 'version': ?version, 'diagnostics': items},
      });
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
    }

    testWidgets('a publish puts a mark with the message on the gutter', (
      t,
    ) async {
      final (ch, uri) = await openReady(t, 'lib/rates.ts');
      expect(gutter(t).proof, isEmpty);
      await publish(t, ch, uri, [error()]);

      final marks = gutter(t).proof;
      expect(marks.keys, [2]);
      expect(marks[2]!.single.kind, ProofMarkKind.error);
      expect(marks[2]!.single.blocking, isFalse);
      expect(marks[2]!.single.text, 'ERROR TS2322 · $message');

      final box = t.getTopLeft(find.byType(EditorGutter));
      final g = await t.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: const Offset(1, 1));
      addTearDown(g.removePointer);
      Offset? hit;
      for (var dy = 4.0; dy < 120 && hit == null; dy += 4) {
        final p = box + Offset(GutterMetrics.bar + 4, dy);
        await g.moveTo(p);
        await t.pump();
        if (find
            .byKey(const ValueKey('gutter-proof-label'))
            .evaluate()
            .isNotEmpty) {
          hit = p;
        }
      }
      expect(hit, isNotNull);
      expect(find.text('ERROR TS2322 · $message'), findsOneWidget);

      await t.tapAt(hit!);
      await t.pumpAndSettle();
      expect(
        _container(t).read(bottomPanelProvider(id)).showing(BottomTab.problems),
        isTrue,
      );
      expect(_container(t).read(problemsFocusProvider(id))?.line, 2);
    }, variant: mac);

    testWidgets('Problems lists them under TYPESCRIPT and a click jumps', (
      t,
    ) async {
      final (ch, uri) = await openReady(t, 'lib/rates.ts');
      await publish(t, ch, uri, [error(line: 0), error(line: 1)]);
      _container(t)
          .read(bottomPanelProvider(id).notifier)
          .show(BottomTab.problems);
      await t.pumpAndSettle();

      expect(find.text('TYPESCRIPT · 2'), findsOneWidget);
      expect(find.text('rates.ts:2:3'), findsOneWidget);
      expect(find.text('ERROR TS2322'), findsNWidgets(2));
      expect(find.text(message), findsNWidgets(2));

      await t.tap(find.text('rates.ts:2:3'));
      await t.pumpAndSettle();
      final tabs = _container(t).read(editorTabsProvider(id));
      expect(tabs.activePath, 'lib/rates.ts');
      final c = t.widget<EditPane>(find.byType(EditPane)).buffer.controller!;
      expect(c.selection.extentIndex + 1, 2);
    }, variant: mac);

    testWidgets('a publish for an older version is ignored', (t) async {
      final (ch, uri) = await openReady(t, 'lib/rates.ts');
      final c = t.widget<EditPane>(find.byType(EditPane)).buffer.controller!;
      c.text = 'one\ntwo\nthree\n';
      await t.pumpAndSettle();
      await publish(t, ch, uri, [error()], version: 1);
      expect(gutter(t).proof, isEmpty);
      await publish(t, ch, uri, [error()], version: 2);
      expect(gutter(t).proof.keys, [2]);
    }, variant: mac);

    testWidgets('marks follow the live buffer, unlike the saved-line marks', (
      t,
    ) async {
      final (ch, uri) = await openReady(t, 'lib/rates.ts');
      await publish(t, ch, uri, [error()]);
      t.widget<EditPane>(find.byType(EditPane)).buffer.controller!.text =
          'edited\nlines\n';
      await t.pump();
      expect(gutter(t).proof.keys, [2]);
      await publish(t, ch, uri, const []);
      expect(gutter(t).proof, isEmpty);
    }, variant: mac);

    testWidgets('the server stopping clears the mark and the list', (t) async {
      final (ch, uri) = await openReady(t, 'lib/rates.ts');
      await publish(t, ch, uri, [error()]);
      expect(gutter(t).proof, isNotEmpty);
      ch.deliver({'haro': 'lsp_exited', 'code': 1});
      await t.pump();
      await t.pump(const Duration(milliseconds: 10));
      expect(gutter(t).proof, isEmpty);
      expect(_container(t).read(lspDiagnosticsProvider(id)), isEmpty);
      await t.pump(const Duration(seconds: 5));
    }, variant: mac);

    testWidgets(
      'leaving the TS file closes its document and clears its marks; a non-TS buffer has none',
      (t) async {
        final (ch, uri) = await openReady(t, 'lib/rates.ts');
        await publish(t, ch, uri, [error()]);
        await _openMore(t, 'README.md');
        await t.pump(const Duration(milliseconds: 200));
        expect(gutter(t).proof, isEmpty);
        expect(_container(t).read(lspDiagnosticsProvider(id)), isEmpty);
        expect(
          t.widget<EditPane>(find.byType(EditPane)).buffer.path,
          'README.md',
        );
      },
      variant: mac,
    );
  });
}
