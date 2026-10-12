import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/steps/code/edit_buffer.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../data/detail_harness.dart' show FakeChannel;
import '../../harness.dart';
import 'code_harness.dart';

Map<String, FileContent> _files() => {
  'lib/rates.ts': const FileContent(
    path: 'lib/rates.ts',
    content: 'one\ntwo\n',
  ),
  'README.md': const FileContent(path: 'README.md', content: '# haro\n'),
};

const _typed = 'a  b\ntwo\n';
const _formatted = 'a b\ntwo\n';

final _spaceEdit = {
  'range': {
    'start': {'line': 0, 'character': 1},
    'end': {'line': 0, 'character': 3},
  },
  'newText': ' ',
};

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

List<Map<String, dynamic>> _sent(FakeChannel c, String method) => [
  for (final s in c.sent)
    if ((jsonDecode(s as String) as Map)['method'] == method)
      jsonDecode(s) as Map<String, dynamic>,
];

List<String> _methods(FakeChannel c) => [
  for (final s in c.sent) '${(jsonDecode(s as String) as Map)['method']}',
];

CodeLineEditingController _controller(WidgetTester t) =>
    t.widget<EditPane>(find.byType(EditPane)).buffer.controller!;

/// Opens [path] in the editor with Format on save [on], finishes the handshake when the file
/// gets a language server, and types [_typed] into it.
Future<(CodeRig, FakeChannel?)> _open(
  WidgetTester t,
  String path, {
  bool on = true,
}) async {
  final rig = CodeRig(files: _files());
  rig.prefs = MemoryDevicePrefsStore({
    'editor': {'format_on_save': on},
  });
  await rig.pump(t, step: 'code');
  _container(t)
      .read(editorTabsProvider(id).notifier)
      .open(path, preview: false);
  await t.pumpAndSettle();
  await t.tap(find.byKey(const ValueKey('mode-edit')));
  await t.pumpAndSettle();
  FakeChannel? ch;
  for (var i = 0; i < rig.net.uris.length; i++) {
    if (rig.net.uris[i].path == '/ws/workspaces/$id/lsp') {
      ch = rig.net.channels[i];
    }
  }
  if (ch != null) {
    final init = _sent(ch, 'initialize').single;
    ch.deliver({
      'jsonrpc': '2.0',
      'id': init['id'],
      'result': {'capabilities': {}},
    });
    await t.pumpAndSettle();
  }
  _controller(t).text = path.endsWith('.ts') ? _typed : '# haro\n\n';
  await t.pump();
  return (rig, ch);
}

Future<void> _save(WidgetTester t) async {
  await t.tap(
    find.descendant(of: find.byType(EditPane), matching: find.text('Save')),
  );
  await t.pump();
  await t.pump();
}

void _reply(FakeChannel ch, Object? result) {
  final req = _sent(ch, 'textDocument/formatting').last;
  ch.deliver({'jsonrpc': '2.0', 'id': req['id'], 'result': result});
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('Format on save, in the editor', () {
    testWidgets('formats first, then writes the formatted text', (t) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      await _save(t);
      final req = _sent(ch!, 'textDocument/formatting').single['params'] as Map;
      expect(req['options'], {'tabSize': 2, 'insertSpaces': true});
      expect(rig.saves, isEmpty, reason: 'nothing is written before the reply');

      _reply(ch, [_spaceEdit]);
      await t.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', _formatted)]);
      expect(_controller(t).text, _formatted);
      final methods = _methods(ch);
      expect(
        methods.lastIndexOf('textDocument/didChange'),
        greaterThan(methods.indexOf('textDocument/formatting')),
        reason: 'the server heard the formatted text too',
      );
    });

    testWidgets('one undo reverts the format and the saved text stays', (
      t,
    ) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      await _save(t);
      _reply(ch!, [_spaceEdit]);
      await t.pumpAndSettle();
      final c = _controller(t);
      expect(c.canUndo, isTrue);
      c.undo();
      expect(c.text, _typed);
      expect(rig.saves.single.$2, _formatted);
    });

    testWidgets('the setting off sends no formatting request at all', (
      t,
    ) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts', on: false);
      await _save(t);
      await t.pumpAndSettle();
      expect(_sent(ch!, 'textDocument/formatting'), isEmpty);
      expect(rig.saves, [('lib/rates.ts', _typed)]);
    });

    testWidgets('a silent server costs two seconds, then the save goes out', (
      t,
    ) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      await _save(t);
      await t.pump(const Duration(milliseconds: 1900));
      expect(rig.saves, isEmpty);
      await t.pump(const Duration(milliseconds: 200));
      await t.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', _typed)]);

      _reply(ch!, [_spaceEdit]);
      await t.pumpAndSettle();
      expect(_controller(t).text, _typed, reason: 'a late reply is ignored');
    });

    testWidgets('a server error saves the buffer as it was', (t) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      await _save(t);
      final req = _sent(ch!, 'textDocument/formatting').single;
      ch.deliver({
        'jsonrpc': '2.0',
        'id': req['id'],
        'error': {'code': -32603, 'message': 'boom'},
      });
      await t.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', _typed)]);
    });

    testWidgets('an empty answer saves the buffer as it was', (t) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      await _save(t);
      _reply(ch!, const []);
      await t.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', _typed)]);
    });

    testWidgets('typing while the server answers saves without formatting', (
      t,
    ) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      await _save(t);
      const later = 'a  b\ntwo\nthree\n';
      _controller(t).text = later;
      await t.pump();
      _reply(ch!, [_spaceEdit]);
      await t.pumpAndSettle();
      expect(rig.saves, [('lib/rates.ts', later)]);
    });

    testWidgets('an unavailable server never delays the save', (t) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      ch!.deliver({'haro': 'lsp_unavailable', 'reason': 'not_installed'});
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(seconds: 6));
      await _save(t);
      await t.pumpAndSettle();
      expect(_sent(ch, 'textDocument/formatting'), isEmpty);
      expect(rig.saves, [('lib/rates.ts', _typed)]);
    });

    testWidgets('a folded buffer saves unformatted and whole', (t) async {
      final (rig, ch) = await _open(t, 'lib/rates.ts');
      const text = 'function f() {\n  a;\n  b;\n}\nconst  x = 1;\n';
      final c = _controller(t);
      c.text = text;
      await t.pump();
      c.collapseChunk(0, 3);
      expect(c.lineCount, isNot(c.codeLines.length));
      await t.pump();
      await _save(t);
      await t.pumpAndSettle();
      expect(_sent(ch!, 'textDocument/formatting'), isEmpty);
      expect(rig.saves, [('lib/rates.ts', text)]);
    });

    testWidgets('a markdown file is never formatted', (t) async {
      final (rig, ch) = await _open(t, 'README.md');
      expect(ch, isNull);
      await _save(t);
      await t.pumpAndSettle();
      expect(rig.saves, [('README.md', '# haro\n\n')]);
    });
  });

  group('Format on save, in the buffer', () {
    Future<EditBuffer> loaded() async {
      final b = EditBuffer('a.ts');
      await b.load(() async => const FileContent(path: 'a.ts', content: 'x\n'));
      addTearDown(b.dispose);
      return b;
    }

    test('the hook runs before the write, on a dirty buffer', () async {
      final b = await loaded();
      final order = <String>[];
      b.addBeforeSave(() async {
        order.add('format');
        b.controller!.text = 'formatted\n';
      });
      b.controller!.text = 'typed\n';
      await b.save((content, _) async {
        order.add('write:$content');
        return null;
      });
      expect(order, ['format', 'write:formatted\n']);
    });

    test(
      'two editors on one buffer: the newest runs, removal is per hook',
      () async {
        final b = await loaded();
        final ran = <String>[];
        Future<void> a() async => ran.add('a');
        Future<void> c() async => ran.add('c');
        b
          ..addBeforeSave(a)
          ..addBeforeSave(c);
        b.controller!.text = 'one\n';
        await b.save((_, _) async => null);
        expect(ran, ['c']);

        b.removeBeforeSave(c);
        ran.clear();
        b.controller!.text = 'two\n';
        await b.save((_, _) async => null);
        expect(ran, ['a']);

        b.removeBeforeSave(a);
        ran.clear();
        b.controller!.text = 'three\n';
        await b.save((_, _) async => null);
        expect(ran, isEmpty);
      },
    );

    test('a clean buffer never runs the hook', () async {
      final b = await loaded();
      var ran = false;
      b.addBeforeSave(() async => ran = true);
      await b.save((_, _) async => null);
      expect(ran, isFalse);
    });

    test('a hook that throws still saves the buffer as it was', () async {
      final b = await loaded();
      b.addBeforeSave(() async => throw StateError('boom'));
      b.controller!.text = 'typed\n';
      String? written;
      final ok = await b.save((content, _) async {
        written = content;
        return null;
      });
      expect(ok, isTrue);
      expect(written, 'typed\n');
      expect(b.saveError, isNull);
    });

    test(
      'a second save waits for the hook and then finds nothing to do',
      () async {
        final b = await loaded();
        var hooks = 0;
        var writes = 0;
        b.addBeforeSave(() async {
          hooks++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        b.controller!.text = 'typed\n';
        Future<String?> write(String c, String? e) async {
          writes++;
          return null;
        }

        await Future.wait([b.save(write), b.save(write)]);
        expect((hooks, writes), (1, 1));
      },
    );
  });
}
