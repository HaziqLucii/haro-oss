import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_definition.dart';

import 'fake_lsp.dart';

const _root = '/work/tree';
const _uri = 'file:///work/tree/src/a.ts';

Map<String, Object?> _loc(String uri, int line, int character) => {
  'uri': uri,
  'range': {
    'start': {'line': line, 'character': character},
    'end': {'line': line, 'character': character + 3},
  },
};

Future<(LspClient, FakeLspServer)> _ready() async {
  final s = FakeLspServer();
  final c = LspClient(connect: () => s, rootPath: _root);
  addTearDown(c.dispose);
  c.openDocument(_uri, 'typescript', 'const a = b;');
  await pumpEventQueue(times: 50);
  return (c, s);
}

String? _same(String p) => p;

DefinitionJump _jump(String uri, {RealPath real = _same}) =>
    jumpForDefinition(_root, DefinitionTarget(uri, 4, 9), realPath: real);

void main() {
  group('request', () {
    test('sends the uri and the 0-based position', () async {
      final (c, s) = await _ready();
      s.definitions.add(_loc('file:///work/tree/src/b.ts', 2, 7));
      await resolveDefinition(c, _uri, 3, 11, realPath: _same);
      final params = s.byMethod('textDocument/definition').single['params'];
      expect(params, {
        'textDocument': {'uri': _uri},
        'position': {'line': 3, 'character': 11},
      });
    });

    test('a worktree file opens at its 1-based line and column', () async {
      final (c, s) = await _ready();
      s.definitions.add(_loc('file:///work/tree/src/b%20c.ts', 2, 7));
      final j = await resolveDefinition(c, _uri, 0, 10, realPath: _same);
      expect(j, isA<OpenDefinition>());
      final open = j! as OpenDefinition;
      expect((open.path, open.line, open.column), ('src/b c.ts', 3, 8));
    });

    test('several locations: the first wins', () async {
      final (c, s) = await _ready();
      s.definitions.add([
        _loc('file:///work/tree/src/first.ts', 0, 0),
        _loc('file:///work/tree/src/second.ts', 9, 9),
      ]);
      final j = await resolveDefinition(c, _uri, 0, 10, realPath: _same);
      expect((j! as OpenDefinition).path, 'src/first.ts');
    });

    test('no result, or an empty list, is nothing to do', () async {
      final (c, s) = await _ready();
      expect(await resolveDefinition(c, _uri, 0, 10), isNull);
      s.definitions.add(const []);
      expect(await resolveDefinition(c, _uri, 0, 10), isNull);
    });

    test('an unavailable server is a quiet null', () async {
      final s = FakeLspServer(
        initializeError: {'code': -32603, 'message': 'x'},
      );
      final c = LspClient(connect: () => s, rootPath: _root);
      addTearDown(c.dispose);
      c.openDocument(_uri, 'typescript', 'a');
      await pumpEventQueue(times: 50);
      expect(c.status, LspStatus.unavailable);
      expect(await resolveDefinition(c, _uri, 0, 0), isNull);
      expect(s.byMethod('textDocument/definition'), isEmpty);
    });

    test('advertises definition and hover in the handshake', () async {
      final (_, s) = await _ready();
      final init = s.byMethod('initialize').single['params'] as Map;
      final td = (init['capabilities'] as Map)['textDocument'] as Map;
      expect(td['definition'], isNotNull);
      expect((td['hover'] as Map)['contentFormat'], contains('markdown'));
    });
  });

  group('firstDefinition', () {
    test('reads a Location, a LocationLink, and rejects junk', () {
      final loc = firstDefinition(_loc('file:///a.ts', 1, 2))!;
      expect((loc.uri, loc.line, loc.character), ('file:///a.ts', 1, 2));

      final link = firstDefinition([
        {
          'targetUri': 'file:///b.ts',
          'targetRange': {
            'start': {'line': 0, 'character': 0},
          },
          'targetSelectionRange': {
            'start': {'line': 5, 'character': 6},
          },
        },
      ])!;
      expect((link.uri, link.line, link.character), ('file:///b.ts', 5, 6));

      expect(firstDefinition(null), isNull);
      expect(firstDefinition('x'), isNull);
      expect(firstDefinition({'uri': 'file:///a.ts'}), isNull);
      expect(firstDefinition(_loc('file:///a.ts', -1, 0)), isNull);
    });
  });

  group('jumpForDefinition', () {
    test('a file under the worktree maps to its relative path', () {
      final j = _jump('file:///work/tree/lib/x.ts') as OpenDefinition;
      expect((j.path, j.line, j.column), ('lib/x.ts', 5, 10));
    });

    test('a path that only shares the root as a string prefix is outside', () {
      final j = _jump('file:///work/tree-other/x.ts');
      expect(j, isA<OutsideDefinition>());
    });

    test('a dependency reported at its real path is outside, by name', () {
      final j = _jump(
        'file:///project/node_modules/@types/react/index.d.ts',
      ) as OutsideDefinition;
      expect(j.label, 'node_modules/@types/react/index.d.ts');
    });

    test('node_modules under the worktree that links out is outside', () {
      String? real(String p) =>
          p.replaceFirst('/work/tree/node_modules', '/project/node_modules');
      final j = _jump(
        'file:///work/tree/node_modules/react/index.d.ts',
        real: real,
      );
      expect(j, isA<OutsideDefinition>());
    });

    test('node_modules that really lives in the worktree opens', () {
      final j = _jump('file:///work/tree/node_modules/react/index.d.ts');
      expect((j as OpenDefinition).path, 'node_modules/react/index.d.ts');
    });

    test('a symlinked worktree root is matched by its real path', () {
      String? real(String p) =>
          p.startsWith('/work/tree') ? p.replaceFirst('/work', '/real') : p;
      final j = _jump('file:///real/tree/src/b.ts', real: real);
      expect((j as OpenDefinition).path, 'src/b.ts');
    });

    test('a non-file uri is outside', () {
      expect(_jump('zipfile:///a.zip!/x.d.ts'), isA<OutsideDefinition>());
    });
  });
}
