import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_document.dart';

import 'fake_lsp.dart';

const _root = '/work/tree';
const _uri = 'file:///work/tree/src/a.ts';

LspClient _client(FakeLspServer s) =>
    LspClient(connect: () => s, rootPath: _root);

Future<void> _flush() => pumpEventQueue(times: 50);

void main() {
  test('handshake: initialize, initialized, then the held didOpen', () async {
    final s = FakeLspServer();
    final c = _client(s);
    expect(c.status, LspStatus.idle);
    c.openDocument(_uri, 'typescript', 'const a = 1;');
    expect(c.status, LspStatus.starting);
    await _flush();

    expect(c.status, LspStatus.ready);
    expect(
      [for (final m in s.received) m['method']],
      ['initialize', 'initialized', 'textDocument/didOpen'],
    );
    final init = s.byMethod('initialize').single['params'] as Map;
    expect(init['rootUri'], 'file:///work/tree');
    final caps = init['capabilities'] as Map;
    expect(caps['workspace'], {'configuration': false});
    final td = caps['textDocument'] as Map;
    expect(td['synchronization'], isNotNull);
    expect(td['publishDiagnostics'], {'versionSupport': true});
    expect(
      ((td['completion'] as Map)['completionItem'] as Map)['snippetSupport'],
      false,
    );
    final open = s.byMethod('textDocument/didOpen').single['params'] as Map;
    expect(open['textDocument'], {
      'uri': _uri,
      'languageId': 'typescript',
      'version': 1,
      'text': 'const a = 1;',
    });
  });

  test(
    'a document changed during the handshake opens with its latest text',
    () async {
      final s = FakeLspServer();
      final c = _client(s);
      c.openDocument(_uri, 'typescript', 'a');
      c.changeDocument(_uri, 'ab');
      await _flush();
      final open = s.byMethod('textDocument/didOpen').single['params'] as Map;
      expect((open['textDocument'] as Map)['text'], 'ab');
      expect((open['textDocument'] as Map)['version'], 2);
      expect(s.byMethod('textDocument/didChange'), isEmpty);
    },
  );

  test(
    'didChange sends full text with a rising version; didClose forgets it',
    () async {
      final s = FakeLspServer();
      final c = _client(s);
      c.openDocument(_uri, 'typescript', 'a');
      await _flush();
      c.changeDocument(_uri, 'ab');
      c.changeDocument(_uri, 'ab');
      c.changeDocument(_uri, 'abc');
      await _flush();
      final changes = s.byMethod('textDocument/didChange');
      expect(changes, hasLength(2));
      final last = changes.last['params'] as Map;
      expect(last['textDocument'], {'uri': _uri, 'version': 3});
      expect(last['contentChanges'], [
        {'text': 'abc'},
      ]);
      expect(c.versionOf(_uri), 3);

      c.closeDocument(_uri);
      await _flush();
      expect(s.byMethod('textDocument/didClose'), hasLength(1));
      expect(c.versionOf(_uri), isNull);
      c.changeDocument(_uri, 'zzz');
      await _flush();
      expect(s.byMethod('textDocument/didChange'), hasLength(2));
    },
  );

  test('requests pair with their responses by id', () async {
    final s = FakeLspServer()
      ..completions.addAll([
        [item('one')],
        [item('two')],
      ]);
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    final a = c.completion(_uri, 0, 1);
    final b = c.completion(_uri, 0, 1, triggerCharacter: '.');
    expect((await a as List).single['label'], 'one');
    expect((await b as List).single['label'], 'two');
    final ctx = [
      for (final m in s.byMethod('textDocument/completion'))
        (m['params'] as Map)['context'],
    ];
    expect(ctx, [
      {'triggerKind': 1},
      {'triggerKind': 2, 'triggerCharacter': '.'},
    ]);
  });

  test('resolve returns the server item', () async {
    final s = FakeLspServer()
      ..resolved['useState'] = {'label': 'useState', ...importEdit};
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    final r = await c.resolveCompletionItem({'label': 'useState'});
    expect(r!['additionalTextEdits'], isNotEmpty);
  });

  test('server requests are answered with a null result', () async {
    final s = FakeLspServer();
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    for (final (id, method) in [
      (90, 'client/registerCapability'),
      (91, 'workspace/configuration'),
      (92, 'window/workDoneProgress/create'),
    ]) {
      s.push({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': {}});
    }
    s.push({
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': {},
    });
    await _flush();
    final replies = [
      for (final m in s.received)
        if (!m.containsKey('method')) m,
    ];
    expect([for (final r in replies) r['id']], [90, 91, 92]);
    expect(
      replies.every((r) => r.containsKey('result') && r['result'] == null),
      isTrue,
    );
    expect(c.status, LspStatus.ready);
  });

  test(
    'an initialize error means unavailable, and nothing throws afterwards',
    () async {
      final s = FakeLspServer(
        initializeError: {
          'code': -32603,
          'message': 'Could not find tsserver.js',
        },
      );
      final c = _client(s);
      c.openDocument(_uri, 'typescript', 'x');
      await _flush();
      expect(c.status, LspStatus.unavailable);
      expect(c.unavailableReason, contains('Could not find tsserver.js'));
      expect(await c.completion(_uri, 0, 1), isNull);
      expect(await c.resolveCompletionItem({'label': 'a'}), isNull);
      c.changeDocument(_uri, 'y');
      c.openDocument(_uri, 'typescript', 'y');
      c.closeDocument(_uri);
      expect(s.byMethod('textDocument/didOpen'), isEmpty);
      expect(c.takeNotice(), isTrue);
      expect(c.takeNotice(), isFalse);
    },
  );

  test('lsp_unavailable not_installed carries the install hint', () async {
    final s = FakeLspServer();
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    s.push({'haro': 'lsp_unavailable', 'reason': 'not_installed'});
    await _flush();
    expect(c.status, LspStatus.unavailable);
    expect(c.unavailableReason, lspInstallHint);
    expect(c.unavailableReason, contains('typescript-language-server'));
    expect(await c.completion(_uri, 0, 1), isNull);
  });

  test('lsp_exited and a dropped socket end a ready client', () async {
    final s = FakeLspServer();
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    final pending = c.completion(_uri, 0, 1);
    s.push({'haro': 'lsp_exited', 'code': 1});
    expect(await pending, isNull);
    expect(c.status, LspStatus.unavailable);
    expect(c.unavailableReason, contains('stopped'));

    final s2 = FakeLspServer();
    final c2 = _client(s2);
    c2.openDocument(_uri, 'typescript', 'x');
    await _flush();
    await s2.drop();
    await _flush();
    expect(c2.status, LspStatus.unavailable);
    expect(c2.unavailableReason, contains('disconnected'));
  });

  test('a connect that throws is unavailable, not an exception', () async {
    final c = LspClient(
      connect: () => throw StateError('no network'),
      rootPath: _root,
    );
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    expect(c.status, LspStatus.unavailable);
    expect(c.unavailableReason, isNotEmpty);
  });

  test('a response nobody waits for is ignored', () async {
    final s = FakeLspServer();
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    s.push({'jsonrpc': '2.0', 'id': 4242, 'result': []});
    s.push({'jsonrpc': '2.0', 'id': 'weird', 'result': []});
    await _flush();
    expect(c.status, LspStatus.ready);
  });

  test('no worktree means unavailable without connecting', () async {
    var connects = 0;
    final c = LspClient(
      connect: () {
        connects++;
        return FakeLspServer();
      },
      rootPath: '',
    );
    c.openDocument(_uri, 'typescript', 'x');
    expect(c.status, LspStatus.unavailable);
    expect(connects, 0);
  });

  test('dispose shuts the server down and closes the socket', () async {
    final s = FakeLspServer();
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    c.dispose();
    await _flush();
    expect(s.byMethod('shutdown'), hasLength(1));
    expect(s.byMethod('exit'), hasLength(1));
    expect(s.closed, isTrue);
  });

  test(
    'two editors on one file: one didOpen, didClose only on the last',
    () async {
      final s = FakeLspServer();
      final c = _client(s);
      final a = CodeLineEditingController.fromText('x');
      final b = CodeLineEditingController.fromText('x');
      LspDocument doc(CodeLineEditingController k) => LspDocument(
        client: c,
        uri: _uri,
        languageId: 'typescript',
        controller: k,
      );
      final d1 = doc(a)..open();
      final d2 = doc(b)..open();
      await _flush();
      expect(s.byMethod('textDocument/didOpen'), hasLength(1));
      d1.close();
      await _flush();
      expect(c.versionOf(_uri), isNotNull);
      expect(s.byMethod('textDocument/didClose'), isEmpty);
      a.text = 'ignored after close';
      b.text = 'xy';
      await _flush();
      expect(s.byMethod('textDocument/didChange'), hasLength(1));
      d2.close();
      await _flush();
      expect(c.versionOf(_uri), isNull);
      expect(s.byMethod('textDocument/didClose'), hasLength(1));
    },
  );

  test('a disposed client is unavailable and answers promptly', () async {
    final s = FakeLspServer();
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    final hold = s.holdNextCompletion();
    final inFlight = c.completion(_uri, 0, 1);
    await _flush();
    c.dispose();
    expect(c.status, LspStatus.unavailable);
    expect(c.unavailableReason, 'disposed');
    expect(await inFlight.timeout(const Duration(seconds: 1)), isNull);
    expect(
      await c.completion(_uri, 0, 1).timeout(const Duration(seconds: 1)),
      isNull,
    );
    expect(c.takeNotice(), isFalse);
    hold();
  });

  test('an unavailable client answers requests at once', () async {
    final s = FakeLspServer(initializeError: {'code': -32603, 'message': 'x'});
    final c = _client(s);
    c.openDocument(_uri, 'typescript', 'x');
    await _flush();
    expect(
      await c
          .resolveCompletionItem({'label': 'a'})
          .timeout(const Duration(seconds: 1)),
      isNull,
    );
  });

  group('paths', () {
    test('language ids cover the TS and JS family only', () {
      expect(lspLanguageId('a/b.ts'), 'typescript');
      expect(lspLanguageId('a/b.tsx'), 'typescriptreact');
      expect(lspLanguageId('a/b.js'), 'javascript');
      expect(lspLanguageId('a/b.mjs'), 'javascript');
      expect(lspLanguageId('a/b.cjs'), 'javascript');
      expect(lspLanguageId('a/b.jsx'), 'javascriptreact');
      expect(lspLanguageId('a/B.TS'), 'typescript');
      expect(lspLanguageId('README.md'), isNull);
      expect(lspLanguageId('Makefile'), isNull);
      expect(lspLanguageId('a/b.json'), isNull);
    });

    test('document uri is a file uri under the worktree', () {
      expect(
        lspDocumentUri('/work/tree', 'src/a.ts'),
        'file:///work/tree/src/a.ts',
      );
      expect(
        lspDocumentUri('/work/tree/', 'src/a.ts'),
        'file:///work/tree/src/a.ts',
      );
      expect(
        lspDocumentUri('/my work', 'a b.ts'),
        'file:///my%20work/a%20b.ts',
      );
    });
  });
}
