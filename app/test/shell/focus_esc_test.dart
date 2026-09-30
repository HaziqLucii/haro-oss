import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as flutter show testWidgets;
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:re_editor/re_editor.dart';

import '../features/workspace/steps/code/code_harness.dart';

// re_editor decides its platform-dependent key handling once, on first use, so this file
// runs the whole editor under macOS like manual_mode_test does.

final _focusTitle = find.byKey(const ValueKey('focus-title'));

Future<void> _chord(
  WidgetTester t,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  if (shift) {
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, platform: 'macos');
  }
  await t.sendKeyEvent(key, platform: 'macos');
  if (shift) {
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, platform: 'macos');
  }
  await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await t.pumpAndSettle();
}

Future<void> _focusChord(WidgetTester t) =>
    _chord(t, LogicalKeyboardKey.enter, shift: true);

Future<void> _esc(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);
  setUp(() => haroOverlayDepth.value = 0);

  void testWidgets(String name, Future<void> Function(WidgetTester) body) =>
      flutter.testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  group('focus mode Esc', () {
    testWidgets('Esc with the caret in the editor still leaves focus mode', (
      tester,
    ) async {
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
      await _focusChord(tester);
      await tester.tap(find.byType(CodeEditor));
      await tester.pump();
      await _esc(tester);
      expect(_focusTitle, findsNothing);
    });

    Future<CodeFindController> openFind(WidgetTester tester) async {
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
      await _focusChord(tester);
      await tester.tap(find.byType(CodeEditor));
      await tester.pump();
      final find_ = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .findController!;
      find_.findMode();
      await tester.pumpAndSettle();
      expect(find_.value, isNotNull);
      return find_;
    }

    testWidgets(
      'Esc while an IME is composing in the editor keeps focus mode',
      (tester) async {
        final rig = CodeRig(
          files: {
            'lib/rates.ts': const FileContent(
              path: 'lib/rates.ts',
              content: 'ab\n',
            ),
          },
        );
        await rig.pump(tester, step: 'code');
        await tester.tap(find.byKey(const ValueKey('mode-edit')));
        await tester.pumpAndSettle();
        await _focusChord(tester);
        await tester.tap(find.byType(CodeEditor));
        await tester.pump();
        final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
        editor.controller!.composing = const TextRange(start: 0, end: 1);
        expect(editor.controller!.isComposing, isTrue);
        await _esc(tester);
        expect(_focusTitle, findsOneWidget);
      },
    );

    testWidgets('Esc in the editor with find open closes find, keeps focus '
        'mode, and the next Esc leaves it', (tester) async {
      final find_ = await openFind(tester);
      await tester.tap(find.byType(CodeEditor));
      await tester.pump();

      await _esc(tester);
      expect(find_.value, isNull);
      expect(_focusTitle, findsOneWidget);

      await _esc(tester);
      expect(_focusTitle, findsNothing);
    });

    testWidgets('Esc typed in the find input never leaves focus mode', (
      tester,
    ) async {
      final find_ = await openFind(tester);
      find_.focusOnFindInput();
      await tester.pumpAndSettle();
      await _esc(tester);
      expect(_focusTitle, findsOneWidget);
    });

    testWidgets('Esc reaches the terminal instead of leaving focus mode', (
      tester,
    ) async {
      final rig = CodeRig();
      await rig.pump(tester, step: 'code');
      await _focusChord(tester);
      await tester.tap(find.byKey(const ValueKey('status-terminal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell-view')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-view')));
      await tester.pump(const Duration(milliseconds: 400));

      await _esc(tester);
      expect(_focusTitle, findsOneWidget);
      final sent = rig.net.latest.sent
          .map((m) => jsonDecode(m as String))
          .where((m) => m['t'] == 'in')
          .map((m) => m['d'])
          .toList();
      expect(sent, contains('\u001b'));
    });
  });
}
