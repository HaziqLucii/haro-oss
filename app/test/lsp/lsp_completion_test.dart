import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/editor/lsp_completion_view.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_completion.dart';
import 'package:haro_app/lsp/lsp_document.dart';
import 'package:re_editor/re_editor.dart';

import 'fake_lsp.dart';

const _uri = 'file:///work/tree/src/a.ts';

void main() {
  group('trigger', () {
    test('an identifier or a member dot opens a list; nothing else does', () {
      expect(completionTrigger('  useSt', 7), (word: 'useSt', dot: false));
      expect(completionTrigger('a.b', 3), (word: 'b', dot: false));
      expect(completionTrigger('foo.', 4), (word: '', dot: true));
      expect(completionTrigger('x = \$el', 7), (word: r'$el', dot: false));
      expect(completionTrigger('  ', 2), isNull);
      expect(completionTrigger('', 0), isNull);
      expect(completionTrigger('x = 12', 6), isNull);
      expect(completionTrigger('1.', 2), isNull);
      expect(completionTrigger('[...', 4), isNull);
      expect(completionTrigger('f(', 2), isNull);
      expect(completionTrigger('useState', 3), (word: 'use', dot: false));
    });
  });

  group('ranking', () {
    List<LspItem> rank(Object? r, {String word = 'use', int cap = 50}) =>
        rankCompletionItems(
          r,
          word: word,
          line: 3,
          cursor: 5 + word.length,
          cap: cap,
        );

    test('filters by the typed prefix and keeps the server sortText order', () {
      final out = rank([
        item('useRef', sortText: '12'),
        item('other', sortText: '00'),
        item('useState', sortText: '11'),
        item('USEFUL', sortText: '13'),
      ]);
      expect([for (final i in out) i.label], ['useState', 'useRef', 'USEFUL']);
    });

    test(
      'equal sortText keeps arrival order; a missing one sorts by label',
      () {
        final out = rank([
          item('useB', sortText: '1'),
          item('useA', sortText: '1'),
          item('useC'),
        ]);
        expect([for (final i in out) i.label], ['useB', 'useA', 'useC']);
      },
    );

    test('dedupes by label, keeping the best-sorted entry', () {
      final out = rank([
        item('useState', sortText: '2', extra: {'detail': 'late'}),
        item('useState', sortText: '1', extra: {'detail': 'early'}),
      ]);
      expect(out, hasLength(1));
      expect(out.single.raw['detail'], 'early');
    });

    test('caps the list', () {
      final many = [
        for (var i = 0; i < 200; i++) item('use$i', sortText: '${1000 + i}'),
      ];
      expect(rank(many), hasLength(50));
      expect(rank(many, cap: 5), hasLength(5));
      expect(rank(many).first.label, 'use0');
    });

    test('takes a CompletionList map and ignores junk', () {
      expect(
        rank({
          'isIncomplete': false,
          'items': [item('useX')],
        }),
        hasLength(1),
      );
      expect(rank(null), isEmpty);
      expect(rank('nope'), isEmpty);
      expect(
        rank([
          1,
          {'kind': 3},
          {'label': ''},
        ]),
        isEmpty,
      );
    });

    test('inserts insertText, else the label; a textEdit must be the plain word replacement', () {
      Map<String, Object?> edit(
        int sc,
        int ec, {
        int line = 3,
        String text = 'useFoo',
      }) => {
        'range': {
          'start': {'line': line, 'character': sc},
          'end': {'line': line, 'character': ec},
        },
        'newText': text,
      };
      final out = rank([
        item('useA', extra: {'insertText': 'useA2'}),
        item('useB'),
        item('useC', extra: {'textEdit': edit(5, 8)}),
        item('useD', extra: {'textEdit': edit(4, 8)}),
        item('useE', extra: {'textEdit': edit(5, 9)}),
        item('useF', extra: {'textEdit': edit(5, 8, line: 2)}),
      ]);
      expect(
        {for (final i in out) i.label: i.insertText},
        {'useA': 'useA2', 'useB': 'useB', 'useC': 'useFoo'},
      );
    });
  });

  group('additional edits', () {
    const imp = {
      'range': {
        'start': {'line': 0, 'character': 0},
        'end': {'line': 0, 'character': 0},
      },
      'newText': 'import x from "x";\n',
    };

    CodeLineEditingController at(String text, int line, int col) =>
        CodeLineEditingController.fromText(text)
          ..selection = CodeLineSelection.collapsed(index: line, offset: col);

    test('a folded buffer takes no auto-import and does not throw', () {
      final c = at('function f() {\n  a;\n  b;\n}\nuseState', 2, 8)
        ..collapseChunk(0, 3);
      expect(c.lineCount, isNot(c.codeLines.length));
      final before = c.text;
      expect(applyAdditionalEdits(c, [imp]), isFalse);
      expect(c.text, before);
    });

    test('inserts above the cursor and moves it down with its text', () {
      final c = at('const a = 1;\nuseState', 1, 8);
      expect(applyAdditionalEdits(c, [imp]), isTrue);
      expect(c.text, 'import x from "x";\nconst a = 1;\nuseState');
      expect(
        c.selection,
        const CodeLineSelection.collapsed(index: 2, offset: 8),
      );
    });

    test(
      'first-line cursor: the import lands above and the cursor follows',
      () {
        final c = at('useState', 0, 8);
        expect(applyAdditionalEdits(c, [imp]), isTrue);
        expect(c.text, 'import x from "x";\nuseState');
        expect(
          c.selection,
          const CodeLineSelection.collapsed(index: 1, offset: 8),
        );
      },
    );

    test(
      'inserts at one position keep array order (type-only import merge)',
      () {
        Map<String, Object> edit(int sc, int ec, String t) => {
          'range': {
            'start': {'line': 0, 'character': sc},
            'end': {'line': 0, 'character': ec},
          },
          'newText': t,
        };
        final c = at('import type { FC } from "react";\n\nuseState', 2, 8);
        final edits = [
          edit(6, 11, ''),
          edit(14, 14, 'useState, '),
          edit(14, 14, 'type '),
        ];
        expect(applyAdditionalEdits(c, edits), isTrue);
        expect(
          c.text,
          'import { useState, type FC } from "react";\n\nuseState',
        );
      },
    );

    test('a merge into an existing import applies in place', () {
      final c = at('import React from "react";\n\nuseState', 2, 8);
      final edits = [
        {
          'range': {
            'start': {'line': 0, 'character': 12},
            'end': {'line': 0, 'character': 12},
          },
          'newText': ', { useState }',
        },
      ];
      expect(applyAdditionalEdits(c, edits), isTrue);
      expect(c.text, 'import React, { useState } from "react";\n\nuseState');
      expect(c.selection.extentIndex, 2);
    });

    test('several edits apply bottom-up in one undo step', () {
      final c = at('import { a } from "x";\nb;\nuse', 2, 3);
      final base = c.text;
      final edits = [
        {
          'range': {
            'start': {'line': 0, 'character': 9},
            'end': {'line': 0, 'character': 9},
          },
          'newText': ' b,',
        },
        imp,
      ];
      expect(applyAdditionalEdits(c, edits), isTrue);
      expect(c.text, 'import x from "x";\nimport {  b,a } from "x";\nb;\nuse');
      expect(c.selection.extentIndex, 3);
      c.undo();
      c.undo();
      expect(c.text, base);
    });

    test('out-of-range, malformed or cursor-line edits change nothing', () {
      for (final bad in <Object?>[
        [
          {
            'range': {
              'start': {'line': 9, 'character': 0},
              'end': {'line': 9, 'character': 0},
            },
            'newText': 'x\n',
          },
        ],
        [
          {
            'range': {
              'start': {'line': 0, 'character': 99},
              'end': {'line': 0, 'character': 99},
            },
            'newText': 'x\n',
          },
        ],
        [
          {
            'range': {
              'start': {'line': 1, 'character': 0},
              'end': {'line': 1, 'character': 2},
            },
            'newText': 'x',
          },
        ],
        [
          {'newText': 'x'},
        ],
        'nope',
        <Object?>[],
        null,
      ]) {
        final c = at('const a = 1;\nuseState', 1, 8);
        expect(applyAdditionalEdits(c, bad), isFalse, reason: '$bad');
        expect(c.text, 'const a = 1;\nuseState');
      }
    });
  });

  group('overlay', () {
    late CodeLineEditingController controller;
    late FakeLspServer server;
    late LspClient client;
    late LspDocument doc;
    late LspCompletionController completion;

    Future<void> pumpEditor(
      WidgetTester tester, {
      String text = 'const a = 1;\n',
      int line = 1,
      int col = 0,
      Duration retryDelay = const Duration(milliseconds: 700),
    }) async {
      server = FakeLspServer();
      client = LspClient(connect: () => server, rootPath: '/work/tree');
      controller = CodeLineEditingController.fromText(text);
      doc = LspDocument(
        client: client,
        uri: _uri,
        languageId: 'typescript',
        controller: controller,
      )..open();
      completion = LspCompletionController(
        client: client,
        uri: _uri,
        controller: controller,
        retryDelay: retryDelay,
      );
      addTearDown(() {
        doc.close();
        completion.dispose();
        client.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: lspAutocomplete(
              completion,
              CodeEditor(
                controller: controller,
                focusNode: FocusNode(),
                autofocus: true,
                style: CodeEditorStyle(fontSize: 14),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.selection = CodeLineSelection.collapsed(
        index: line,
        offset: col,
      );
      await tester.pumpAndSettle();
    }

    void type(String text) {
      final sel = controller.selection;
      final line = controller.codeLines[sel.extentIndex].text;
      final at = sel.extentOffset;
      for (var id = 1; id < 40; id++) {
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

    /// Past re_editor's 50ms delay before it asks for prompts, then the server's answer.
    Future<void> settle(WidgetTester tester, [int ms = 120]) async {
      await tester.pump();
      await tester.pump(Duration(milliseconds: ms));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
    }

    Future<void> typeAndAnswer(WidgetTester tester, String text) async {
      type(text);
      await settle(tester);
    }

    String flat() => controller.text.replaceAll('\n', '|');

    final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

    Finder row(String label) => find.byKey(ValueKey('lsp-item-$label'));

    void serve() {
      server.completions.add([
        item('useStore', sortText: '12'),
        item('useState', sortText: '11'),
        item('userId', sortText: '13'),
      ]);
      server.resolved['useState'] = {'label': 'useState', ...importEdit};
    }

    testWidgets('lists the server items in sortText order', (tester) async {
      await pumpEditor(tester);
      serve();
      await typeAndAnswer(tester, 'useSt');
      expect(find.byKey(const ValueKey('lsp-completion')), findsOneWidget);
      expect(row('useState'), findsOneWidget);
      expect(row('useStore'), findsOneWidget);
      expect(row('userId'), findsNothing, reason: 'does not match useSt');
      expect(
        tester.getTopLeft(row('useState')).dy,
        lessThan(tester.getTopLeft(row('useStore')).dy),
      );
      final req =
          server.byMethod('textDocument/completion').single['params'] as Map;
      expect(req['position'], {'line': 1, 'character': 5});
    }, variant: mac);

    testWidgets(
      'asks the server for the full-file line when lines are folded',
      (tester) async {
        await pumpEditor(
          tester,
          text: 'function f() {\n  a;\n  b;\n}\n',
          line: 4,
        );
        controller.collapseChunk(0, 3);
        await tester.pumpAndSettle();
        expect(controller.codeLines.length, 3);
        expect(controller.selection.extentIndex, 2);
        serve();
        await typeAndAnswer(tester, 'useSt');
        final req =
            server.byMethod('textDocument/completion').single['params'] as Map;
        expect(req['position'], {'line': 4, 'character': 5});
        expect(row('useState'), findsOneWidget);
      },
      variant: mac,
    );

    testWidgets('accepting in a folded buffer inserts the word, no import', (
      tester,
    ) async {
      await pumpEditor(
        tester,
        text: 'function f() {\n  a;\n  b;\n}\n',
        line: 4,
      );
      controller.collapseChunk(0, 3);
      await tester.pumpAndSettle();
      serve();
      await typeAndAnswer(tester, 'useSt');
      await tester.tap(row('useState'));
      await settle(tester, 20);
      expect(flat(), 'function f() {|  a;|  b;|}|useState');
      expect(server.resolveCalls, 0);
    }, variant: mac);

    testWidgets('the server always holds the full text, folded or not', (
      tester,
    ) async {
      await pumpEditor(tester, text: 'function f() {\n  a;\n  b;\n}\nx\n');
      controller.collapseChunk(0, 3);
      await tester.pumpAndSettle();
      controller.replaceSelection(
        'y',
        const CodeLineSelection.collapsed(index: 2, offset: 1),
      );
      await tester.pumpAndSettle();
      final changes = server.byMethod('textDocument/didChange');
      final last = (changes.last['params'] as Map)['contentChanges'] as List;
      expect(
        (last.single as Map)['text'],
        'function f() {\n  a;\n  b;\n}\nxy\n',
      );
    }, variant: mac);

    testWidgets('nothing is visible while the server has not answered', (
      tester,
    ) async {
      await pumpEditor(tester);
      serve();
      final release = server.holdNextCompletion();
      await typeAndAnswer(tester, 'useSt');
      expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
      release();
      await settle(tester, 10);
      expect(row('useState'), findsOneWidget);
    }, variant: mac);

    testWidgets('Enter accepts, then the import is added once', (tester) async {
      await pumpEditor(tester);
      serve();
      await typeAndAnswer(tester, 'useSt');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      expect(flat(), 'import { useState } from "react";|const a = 1;|useState');
      expect(server.resolveCalls, 1);
      expect(
        controller.selection,
        const CodeLineSelection.collapsed(index: 2, offset: 8),
      );
      expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
      await settle(tester, 800);
      expect(server.resolveCalls, 1);
      expect(controller.text.split('import {'), hasLength(2));
    }, variant: mac);

    testWidgets('a click accepts, then the import is added once', (
      tester,
    ) async {
      await pumpEditor(tester);
      serve();
      await typeAndAnswer(tester, 'useSt');
      await tester.tap(row('useState'));
      await settle(tester, 20);
      expect(flat(), 'import { useState } from "react";|const a = 1;|useState');
      expect(server.resolveCalls, 1);
      expect(
        controller.selection,
        const CodeLineSelection.collapsed(index: 2, offset: 8),
      );
    }, variant: mac);

    testWidgets('an item with no additional edits only inserts the word', (
      tester,
    ) async {
      await pumpEditor(tester);
      serve();
      await typeAndAnswer(tester, 'useSt');
      await tester.tap(row('useStore'));
      await settle(tester, 20);
      expect(flat(), 'const a = 1;|useStore');
      expect(server.resolveCalls, 1);
    }, variant: mac);

    testWidgets('typing after accept still gets the import, once', (
      tester,
    ) async {
      await pumpEditor(tester);
      serve();
      await typeAndAnswer(tester, 'useSt');
      final release = server.holdResolve();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      expect(flat(), 'const a = 1;|useState');
      type('(');
      await tester.pump(const Duration(milliseconds: 10));
      release();
      await settle(tester, 20);
      expect(
        flat(),
        'import { useState } from "react";|const a = 1;|useState()',
      );
      expect(controller.selection.extentIndex, 2);
      expect(server.resolveCalls, 1);
    }, variant: mac);

    testWidgets('lines inserted above before the reply shift the import down', (
      tester,
    ) async {
      await pumpEditor(tester, text: 'const a = 1;\nconst b = 2;\n', line: 2);
      server.completions.add([item('useState', sortText: '1')]);
      server.resolved['useState'] = {
        'label': 'useState',
        'additionalTextEdits': [
          {
            'range': {
              'start': {'line': 1, 'character': 0},
              'end': {'line': 1, 'character': 0},
            },
            'newText': 'import x from "x";\n',
          },
        ],
      };
      await typeAndAnswer(tester, 'useSt');
      final release = server.holdResolve();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 0,
      );
      controller.replaceSelection('// top\n');
      controller.selection = const CodeLineSelection.collapsed(
        index: 3,
        offset: 8,
      );
      release();
      await settle(tester, 20);
      expect(
        flat(),
        '// top|const a = 1;|import x from "x";|const b = 2;|useState',
      );
    }, variant: mac);

    testWidgets('editing a line the import touches before the reply skips it', (
      tester,
    ) async {
      await pumpEditor(tester);
      serve();
      await typeAndAnswer(tester, 'useSt');
      final release = server.holdResolve();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 0,
      );
      controller.replaceSelection('x');
      release();
      await settle(tester, 20);
      expect(flat(), 'xconst a = 1;|useState');
    }, variant: mac);

    testWidgets('arrows move the cursor while the server has not answered', (
      tester,
    ) async {
      await pumpEditor(tester, text: 'const a = 1;\nconst b = 2;\n', line: 2);
      serve();
      server.holdNextCompletion();
      await typeAndAnswer(tester, 'useSt');
      expect(controller.selection.extentIndex, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(controller.selection.extentIndex, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(controller.selection.extentIndex, 2);
    }, variant: mac);

    testWidgets('arrows move the list once rows are showing', (tester) async {
      await pumpEditor(tester, text: 'const a = 1;\nconst b = 2;\n', line: 2);
      serve();
      await typeAndAnswer(tester, 'useSt');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(controller.selection.extentIndex, 2, reason: 'cursor stays');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      expect(controller.text.endsWith('useStore'), isTrue);
    }, variant: mac);

    testWidgets(
      'an empty first answer is asked again later, at most three times',
      (tester) async {
        await pumpEditor(tester);
        server.completions.addAll([null, null, null, null, null]);
        await typeAndAnswer(tester, 'useSt');
        expect(server.completionCalls, 1);
        await settle(tester, 700);
        expect(server.completionCalls, 2);
        await settle(tester, 700);
        expect(server.completionCalls, 3);
        await settle(tester, 2000);
        expect(server.completionCalls, 3, reason: 'bounded');
        expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
      },
      variant: mac,
    );

    testWidgets(
      'a re-request that finds the exports shows them, confirms once, stops',
      (tester) async {
        await pumpEditor(tester);
        server.completions.addAll([
          [item('const', sortText: '1')],
          [item('useState', sortText: '1')],
        ]);
        await typeAndAnswer(tester, 'useSt');
        expect(row('useState'), findsNothing);
        await settle(tester, 700);
        expect(row('useState'), findsOneWidget);
        await settle(tester, 2000);
        expect(server.completionCalls, 3);
      },
      variant: mac,
    );

    testWidgets(
      'a non-empty first answer is re-asked and a better list replaces it',
      (tester) async {
        await pumpEditor(tester);
        server.completions.addAll([
          [item('useStyleRegistry', sortText: '1')],
          [
            item('useStyleRegistry', sortText: '1'),
            item('useState', sortText: '2'),
          ],
          [
            item('useStyleRegistry', sortText: '1'),
            item('useState', sortText: '2'),
          ],
        ]);
        await typeAndAnswer(tester, 'useSt');
        expect(row('useStyleRegistry'), findsOneWidget);
        expect(row('useState'), findsNothing);
        await settle(tester, 700);
        expect(row('useState'), findsOneWidget);
        await settle(tester, 2000);
        expect(server.completionCalls, 3);
      },
      variant: mac,
    );

    testWidgets('typing again ends the retries of the older request', (
      tester,
    ) async {
      await pumpEditor(tester);
      server.completions.addAll([null, null, null, null, null, null]);
      await typeAndAnswer(tester, 'useS');
      expect(server.completionCalls, 1);
      await typeAndAnswer(tester, 't');
      expect(server.completionCalls, 2);
      await settle(tester, 700);
      expect(
        server.completionCalls,
        3,
        reason: 'only the newest request retries',
      );
      await settle(tester, 700);
      expect(server.completionCalls, 4);
      await settle(tester, 2000);
      expect(server.completionCalls, 4);
    }, variant: mac);

    testWidgets('once warm, an empty answer is final', (tester) async {
      await pumpEditor(tester);
      server.completions.addAll([
        [item('useState')],
        [item('useState')],
        null,
        null,
      ]);
      await typeAndAnswer(tester, 'use');
      await settle(tester, 2000);
      expect(row('useState'), findsOneWidget);
      final before = server.completionCalls;
      await typeAndAnswer(tester, 'Q');
      await settle(tester, 2000);
      expect(server.completionCalls, before + 1);
    }, variant: mac);

    testWidgets('a late reply for an older keystroke is dropped', (
      tester,
    ) async {
      await pumpEditor(tester);
      final late = server.holdNextCompletion();
      server.completions.addAll([
        [item('usOld')],
        [item('useNew')],
      ]);
      await typeAndAnswer(tester, 'us');
      await typeAndAnswer(tester, 'e');
      expect(server.completionCalls, 2);
      expect(row('useNew'), findsOneWidget);
      late();
      await settle(tester, 20);
      expect(row('usOld'), findsNothing);
      expect(row('useNew'), findsOneWidget);
    }, variant: mac);

    testWidgets('Enter before the server answers still breaks the line', (
      tester,
    ) async {
      await pumpEditor(tester);
      serve();
      server.holdNextCompletion();
      await typeAndAnswer(tester, 'useSt');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      expect(flat(), 'const a = 1;|useSt|');
    }, variant: mac);

    testWidgets(
      'no match dismisses the overlay: Enter breaks the line, nothing else changes',
      (tester) async {
        await pumpEditor(tester);
        server.completions.addAll([
          [item('useState')],
          null,
        ]);
        await typeAndAnswer(tester, 'use');
        expect(row('useState'), findsOneWidget);
        await typeAndAnswer(tester, 'Z');
        expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
        expect(flat(), 'const a = 1;|useZ');
        final cursor = controller.selection;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(controller.selection.extentIndex, 0, reason: 'arrows are free');
        controller.selection = cursor;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester, 20);
        expect(flat(), 'const a = 1;|useZ|');
        expect(server.resolveCalls, 0);
        controller.undo();
        expect(
          flat(),
          'const a = 1;|useZ',
          reason: 'dismissal left no edit behind',
        );
      },
      variant: mac,
    );

    testWidgets('unavailable server: no overlay, no requests', (tester) async {
      await pumpEditor(tester);
      server.push({'haro': 'lsp_unavailable', 'reason': 'not_installed'});
      await tester.pump(const Duration(milliseconds: 10));
      await typeAndAnswer(tester, 'useSt');
      expect(find.byKey(const ValueKey('lsp-completion')), findsNothing);
      expect(server.completionCalls, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester, 20);
      expect(flat(), 'const a = 1;|useSt|');
    }, variant: mac);
  });
}
