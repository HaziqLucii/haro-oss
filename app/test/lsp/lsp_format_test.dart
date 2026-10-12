import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_edits.dart';
import 'package:haro_app/lsp/lsp_format.dart';
import 'package:re_editor/re_editor.dart';

import 'fake_lsp.dart';

const _root = '/work/tree';
const _uri = 'file:///work/tree/src/a.ts';

Map<String, Object?> _edit(int sl, int sc, int el, int ec, String text) => {
  'range': {
    'start': {'line': sl, 'character': sc},
    'end': {'line': el, 'character': ec},
  },
  'newText': text,
};

List<LspTextEdit> _edits(List<Map<String, Object?>> raw) =>
    parseTextEdits(raw)!;

CodeLineEditingController _controller(String text) =>
    CodeLineEditingController.fromText(text);

void main() {
  group('applyFormatEdits', () {
    test('several edits land correctly regardless of their order', () {
      final c = _controller('const a  =  1;\nlet b=2\n');
      addTearDown(c.dispose);
      final ok = applyFormatEdits(
        c,
        _edits([
          _edit(0, 7, 0, 9, ' '),
          _edit(0, 10, 0, 12, ' '),
          _edit(1, 5, 1, 5, ' '),
          _edit(1, 6, 1, 6, ' '),
          _edit(1, 7, 1, 7, ';'),
        ]),
      );
      expect(ok, isTrue);
      expect(c.text, 'const a = 1;\nlet b = 2;\n');
    });

    test('inserts at one position keep their array order', () {
      final c = _controller('x\n');
      addTearDown(c.dispose);
      applyFormatEdits(
        c,
        _edits([_edit(0, 1, 0, 1, 'a'), _edit(0, 1, 0, 1, 'b')]),
      );
      expect(c.text, 'xab\n');
    });

    test('a multi-line replacement and a deleted line', () {
      final c = _controller('a\nb\nc\nd\n');
      addTearDown(c.dispose);
      applyFormatEdits(
        c,
        _edits([_edit(0, 1, 1, 1, '\n\n'), _edit(2, 0, 3, 0, '')]),
      );
      expect(c.text, 'a\n\n\nd\n');
    });

    test('one undo step reverts the whole format', () {
      final c = _controller('const a  =  1;\nlet b=2\nend\n');
      addTearDown(c.dispose);
      final before = c.text;
      applyFormatEdits(
        c,
        _edits([
          _edit(0, 7, 0, 9, ' '),
          _edit(0, 10, 0, 12, ' '),
          _edit(1, 5, 1, 5, ' '),
          _edit(1, 6, 1, 6, ' '),
        ]),
      );
      expect(c.text, isNot(before));
      c.undo();
      expect(c.text, before);
      expect(c.canUndo, isFalse);
    });

    test('the cursor stays on the same text', () {
      final c = _controller('const a  =  1;\nlet b=2\n');
      addTearDown(c.dispose);
      c.selection = CodeLineSelection.collapsed(index: 1, offset: 7);
      applyFormatEdits(
        c,
        _edits([
          _edit(0, 7, 0, 9, ' '),
          _edit(0, 10, 0, 12, ' '),
          _edit(1, 5, 1, 5, ' '),
          _edit(1, 6, 1, 6, ' '),
        ]),
      );
      expect(c.text, 'const a = 1;\nlet b = 2\n');
      expect(c.selection.extentIndex, 1);
      expect(c.selection.extentOffset, 9);
    });

    test('a line inserted above pushes the cursor down with its text', () {
      final c = _controller('b\n');
      addTearDown(c.dispose);
      c.selection = CodeLineSelection.collapsed(index: 0, offset: 1);
      applyFormatEdits(c, _edits([_edit(0, 0, 0, 0, 'a\n')]));
      expect(c.text, 'a\nb\n');
      expect(c.selection.extentIndex, 1);
      expect(c.selection.extentOffset, 1);
    });

    test('a cursor inside a replaced span lands inside the replacement', () {
      final c = _controller('abcdef');
      addTearDown(c.dispose);
      c.selection = CodeLineSelection.collapsed(index: 0, offset: 4);
      applyFormatEdits(c, _edits([_edit(0, 2, 0, 6, 'XY')]));
      expect(c.text, 'abXY');
      expect(c.selection.extentOffset, 4);
    });

    test('CRLF files stay CRLF', () {
      final c = CodeLineEditingController.fromText(
        'a  b\r\nc\r\n',
        const CodeLineOptions(lineBreak: TextLineBreak.crlf),
      );
      addTearDown(c.dispose);
      applyFormatEdits(c, _edits([_edit(0, 1, 0, 3, ' ')]));
      expect(c.text, 'a b\r\nc\r\n');
    });

    test('edits that overlap, or end before they start, skip the batch', () {
      final c = _controller('abcdef\n');
      addTearDown(c.dispose);
      expect(
        applyFormatEdits(
          c,
          _edits([_edit(0, 0, 0, 4, 'x'), _edit(0, 2, 0, 5, 'y')]),
        ),
        isFalse,
      );
      expect(applyFormatEdits(c, _edits([_edit(0, 4, 0, 1, 'x')])), isFalse);
      expect(c.text, 'abcdef\n');
    });

    test('positions past the end clamp instead of corrupting', () {
      final c = _controller('a\n');
      addTearDown(c.dispose);
      applyFormatEdits(c, _edits([_edit(5, 0, 5, 0, '// end\n')]));
      expect(c.text, 'a\n// end\n');
    });

    test('edits that change nothing report no change', () {
      final c = _controller('a b\n');
      addTearDown(c.dispose);
      expect(applyFormatEdits(c, _edits([_edit(0, 1, 0, 2, ' ')])), isFalse);
      expect(c.canUndo, isFalse);
    });
  });

  group('folds', () {
    const text = 'function f() {\n  a;\n  b;\n}\nconst  x = 1;\n';

    CodeLineEditingController folded() {
      final c = _controller(text)..collapseChunk(0, 3);
      addTearDown(c.dispose);
      expect(c.lineCount, 6);
      expect(c.codeLines.length, 4);
      return c;
    }

    test('edits are not applied, nothing throws, the text is untouched', () {
      final c = folded();
      expect(applyFormatEdits(c, _edits([_edit(4, 5, 4, 7, ' ')])), isFalse);
      expect(c.text, text);
    });

    test('no formatting request is sent for a folded buffer', () async {
      final s = FakeLspServer();
      final client = LspClient(connect: () => s, rootPath: _root);
      addTearDown(client.dispose);
      client.openDocument(_uri, 'typescript', text);
      await pumpEventQueue(times: 50);
      s.formats.add([_edit(4, 5, 4, 7, ' ')]);
      final c = folded();
      expect(
        await formatBuffer(client: client, uri: _uri, controller: c, unit: 2),
        isFalse,
      );
      expect(s.formatCalls, 0);
      expect(c.text, text);
    });
  });

  group('formatOptionsFor', () {
    test('spaces at the detected step by default', () {
      expect(formatOptionsFor(['a', '    b'], 4), (
        tabSize: 4,
        insertSpaces: true,
      ));
    });

    test('a tab-indented file asks for tabs', () {
      expect(formatOptionsFor(['a {', '\tb'], 2), (
        tabSize: 2,
        insertSpaces: false,
      ));
    });
  });

  group('formatBuffer', () {
    Future<(LspClient, FakeLspServer)> ready(String text) async {
      final s = FakeLspServer();
      final c = LspClient(connect: () => s, rootPath: _root);
      addTearDown(c.dispose);
      c.openDocument(_uri, 'typescript', text);
      await pumpEventQueue(times: 50);
      return (c, s);
    }

    test('sends the editor options and applies the answer', () async {
      final (c, s) = await ready('let  a=1\n');
      final ctl = _controller('let  a=1\n');
      addTearDown(ctl.dispose);
      s.formats.add([_edit(0, 3, 0, 5, ' '), _edit(0, 6, 0, 6, ' ')]);
      final changed = await formatBuffer(
        client: c,
        uri: _uri,
        controller: ctl,
        unit: 4,
      );
      expect(changed, isTrue);
      expect(ctl.text, 'let a =1\n');
      expect(s.byMethod('textDocument/formatting').single['params'], {
        'textDocument': {'uri': _uri},
        'options': {'tabSize': 4, 'insertSpaces': true},
      });
    });

    test('a server error leaves the text alone', () async {
      final (c, s) = await ready('a  b\n');
      s.formatError = {'code': -32603, 'message': 'boom'};
      final ctl = _controller('a  b\n');
      addTearDown(ctl.dispose);
      expect(
        await formatBuffer(client: c, uri: _uri, controller: ctl, unit: 2),
        isFalse,
      );
      expect(ctl.text, 'a  b\n');
    });

    test('no edits, or malformed ones, leave the text alone', () async {
      final (c, s) = await ready('a  b\n');
      final ctl = _controller('a  b\n');
      addTearDown(ctl.dispose);
      s.formats.addAll([null, const <Object?>[], 'nonsense']);
      for (var i = 0; i < 3; i++) {
        expect(
          await formatBuffer(client: c, uri: _uri, controller: ctl, unit: 2),
          isFalse,
        );
      }
      expect(ctl.text, 'a  b\n');
    });

    test('a buffer that changed while waiting is not touched', () async {
      final (c, s) = await ready('a  b\n');
      final ctl = _controller('a  b\n');
      addTearDown(ctl.dispose);
      s.formats.add([_edit(0, 1, 0, 3, ' ')]);
      final release = s.holdFormat();
      final pending = formatBuffer(
        client: c,
        uri: _uri,
        controller: ctl,
        unit: 2,
      );
      await pumpEventQueue(times: 20);
      c.changeDocument(_uri, 'a  b!\n');
      release();
      expect(await pending, isFalse);
      expect(ctl.text, 'a  b\n');
    });

    test('an unavailable server sends nothing', () async {
      final s = FakeLspServer(
        initializeError: {'code': -32603, 'message': 'x'},
      );
      final c = LspClient(connect: () => s, rootPath: _root);
      addTearDown(c.dispose);
      c.openDocument(_uri, 'typescript', 'a');
      await pumpEventQueue(times: 50);
      final ctl = _controller('a  b\n');
      addTearDown(ctl.dispose);
      expect(
        await formatBuffer(client: c, uri: _uri, controller: ctl, unit: 2),
        isFalse,
      );
      expect(s.formatCalls, 0);
    });

    test('a document the server does not hold sends nothing', () async {
      final (c, s) = await ready('a\n');
      final ctl = _controller('a  b\n');
      addTearDown(ctl.dispose);
      expect(
        await formatBuffer(
          client: c,
          uri: 'file:///work/tree/other.ts',
          controller: ctl,
          unit: 2,
        ),
        isFalse,
      );
      expect(s.formatCalls, 0);
    });

    test('a silent server is given up on at the timeout', () async {
      final (c, s) = await ready('a  b\n');
      final ctl = _controller('a  b\n');
      addTearDown(ctl.dispose);
      s.formats.add([_edit(0, 1, 0, 3, ' ')]);
      s.holdFormat();
      final watch = Stopwatch()..start();
      final result = await formatBuffer(
        client: c,
        uri: _uri,
        controller: ctl,
        unit: 2,
        timeout: const Duration(milliseconds: 30),
      );
      expect(result, isFalse);
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(ctl.text, 'a  b\n');
    });
    test('the default timeout is two seconds', () {
      expect(formatTimeout, const Duration(seconds: 2));
    });
  });
}
