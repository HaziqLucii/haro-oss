import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_hover.dart';

import 'fake_lsp.dart';

const _uri = 'file:///work/tree/src/a.ts';
const _delay = Duration(milliseconds: 30);

HoverSpot _spot(int line, int character) => HoverSpot(
  line: line,
  character: character,
  rect: const Rect.fromLTWH(10, 20, 30, 16),
);

Map<String, Object?> _md(String value) => {
  'contents': {'kind': 'markdown', 'value': value},
};

Future<(LspHoverController, FakeLspServer)> _ready() async {
  final s = FakeLspServer();
  final c = LspClient(connect: () => s, rootPath: '/work/tree');
  c.openDocument(_uri, 'typescript', 'const a = b;');
  await pumpEventQueue(times: 50);
  final h = LspHoverController(client: c, uri: _uri, delay: _delay);
  addTearDown(() {
    h.dispose();
    c.dispose();
  });
  return (h, s);
}

Future<void> _past() => Future<void>.delayed(_delay * 3);

void main() {
  group('hoverText', () {
    test('markdown: the first fenced block, fences stripped', () {
      expect(
        hoverText(
          _md(
            '```typescript\n(alias) function useState<S>(s: S): [S]\nimport useState\n```\n---\nReturns a stateful value.',
          ),
        ),
        '(alias) function useState<S>(s: S): [S]\nimport useState',
      );
    });

    test('the real server shape: leading newline, fence, then prose', () {
      expect(
        hoverText(
          _md(
            '\n```typescript\n(alias) useState<number>(initialState: number): [number]\nimport useState\n```\nReturns a stateful value.\n\n*@version* 16.8.0',
          ),
        ),
        '(alias) useState<number>(initialState: number): [number]\nimport useState',
      );
    });

    test('markdown without a fence: the first paragraph', () {
      expect(
        hoverText(_md('Adds `two` numbers.\nSecond line.\n\nMore docs.')),
        'Adds two numbers.\nSecond line.',
      );
    });

    test('a plain string, a MarkedString and a list of them', () {
      expect(hoverText({'contents': 'const a: number'}), 'const a: number');
      expect(
        hoverText({
          'contents': {'language': 'ts', 'value': 'let a: string'},
        }),
        'let a: string',
      );
      expect(
        hoverText({
          'contents': [
            {'language': 'ts', 'value': 'let a: string'},
            'docs',
          ],
        }),
        'let a: string',
      );
    });

    test('nothing to show is null', () {
      expect(hoverText(null), isNull);
      expect(hoverText({'contents': ''}), isNull);
      expect(hoverText({'contents': []}), isNull);
      expect(hoverText({'contents': 3}), isNull);
      expect(hoverText(_md('```ts\n```')), isNull);
    });

    test('a very long signature is cut', () {
      final t = hoverText({'contents': 'x' * 2000})!;
      expect(t.length, lessThan(900));
      expect(t, endsWith('...'));
    });
  });

  group('controller', () {
    test('asks once after the pointer rests, then shows the tip', () async {
      final (h, s) = await _ready();
      s.hovers.add(_md('```ts\nconst b: number\n```'));
      var notified = 0;
      h.addListener(() => notified++);
      h.rest(_spot(0, 10));
      expect(s.hoverCalls, 0);
      await Future<void>.delayed(_delay ~/ 2);
      h.rest(_spot(0, 10));
      await _past();
      await pumpEventQueue(times: 20);

      expect(s.hoverCalls, 1);
      expect(h.tip?.text, 'const b: number');
      expect(notified, 1);
      final params = s.byMethod('textDocument/hover').single['params'];
      expect(params, {
        'textDocument': {'uri': _uri},
        'position': {'line': 0, 'character': 10},
      });
    });

    test('moving to another word restarts the wait', () async {
      final (h, s) = await _ready();
      s.hovers.add(_md('```ts\nx\n```'));
      h.rest(_spot(0, 6));
      await Future<void>.delayed(_delay ~/ 2);
      h.rest(_spot(0, 10));
      await Future<void>.delayed(_delay ~/ 2 + const Duration(milliseconds: 5));
      expect(s.hoverCalls, 0);
      await _past();
      await pumpEventQueue(times: 20);
      expect(s.hoverCalls, 1);
      expect(
        s.byMethod('textDocument/hover').single['params'],
        containsPair('position', {'line': 0, 'character': 10}),
      );
    });

    test('dismiss before the timer fires asks nothing', () async {
      final (h, s) = await _ready();
      s.hovers.add(_md('```ts\nx\n```'));
      h.rest(_spot(0, 6));
      h.dismiss();
      await _past();
      expect(s.hoverCalls, 0);
      expect(h.tip, isNull);
    });

    test('an answer arriving after a dismiss is dropped', () async {
      final (h, s) = await _ready();
      s.hovers.add(_md('```ts\nx\n```'));
      h.rest(_spot(0, 6));
      await Future<void>.delayed(_delay + const Duration(milliseconds: 5));
      h.dismiss();
      await pumpEventQueue(times: 20);
      expect(s.hoverCalls, 1);
      expect(h.tip, isNull);
    });

    test('dismiss clears a shown tip and tells listeners', () async {
      final (h, s) = await _ready();
      s.hovers.add(_md('```ts\nx\n```'));
      h.rest(_spot(0, 6));
      await _past();
      await pumpEventQueue(times: 20);
      expect(h.tip, isNotNull);
      var notified = 0;
      h.addListener(() => notified++);
      h.dismiss();
      expect(h.tip, isNull);
      expect(notified, 1);
      h.dismiss();
      expect(notified, 1);
    });

    test('no hover info shows nothing', () async {
      final (h, s) = await _ready();
      h.rest(_spot(0, 6));
      await _past();
      await pumpEventQueue(times: 20);
      expect(s.hoverCalls, 1);
      expect(h.tip, isNull);
    });
  });

  group('placeTip', () {
    const size = Size(800, 400);

    test('under a word in the upper part, above one in the lower', () {
      final up = placeTip(const Rect.fromLTWH(100, 50, 40, 16), size);
      expect(up.top, 68);
      expect(up.bottom, isNull);
      final down = placeTip(const Rect.fromLTWH(100, 350, 40, 16), size);
      expect(down.top, isNull);
      expect(down.bottom, 52);
    });

    test('stays inside the width', () {
      expect(placeTip(const Rect.fromLTWH(700, 50, 40, 16), size).left, 320);
      expect(
        placeTip(
          const Rect.fromLTWH(100, 50, 40, 16),
          const Size(300, 400),
        ).left,
        0,
      );
    });
  });
}
