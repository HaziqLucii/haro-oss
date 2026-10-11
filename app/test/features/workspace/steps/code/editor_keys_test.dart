import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:re_editor/re_editor.dart';

import 'code_harness.dart';

// re_editor wires keyboard shortcuts and symbol pairing off mobile only, and reads the platform
// once per process: this file runs every editor on macOS, apart from editor_floor_test.dart.
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

CodeRig _rig() => CodeRig(
  files: {
    'lib/rates.ts': const FileContent(
      path: 'lib/rates.ts',
      content: 'one\ntwo\nthree\n',
    ),
  },
);

Future<CodeEditor> _openEditor(WidgetTester t) async {
  await _rig().pump(t, step: 'code');
  await t.tap(find.byKey(const ValueKey('mode-edit')));
  await t.pumpAndSettle();
  await t.tap(find.byType(CodeEditor));
  await t.pumpAndSettle();
  return t.widget<CodeEditor>(find.byType(CodeEditor));
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  // re_editor pairs brackets from text-input deltas, which the test input cannot send, so this
  // pins the switch rather than the keystroke.
  testWidgets('brackets auto-close and a comment formatter are on', (t) async {
    final e = await _openEditor(t);
    expect(e.autocompleteSymbols, isTrue);
    expect(e.commentFormatter, isNotNull);
  }, variant: _mac);

  testWidgets('cmd+/ comments the line and again uncomments it', (t) async {
    final c = (await _openEditor(t)).controller!;
    c.selection = const CodeLineSelection.collapsed(index: 1, offset: 0);
    await t.pump();
    for (final expected in ['// two', 'two']) {
      await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await t.sendKeyDownEvent(LogicalKeyboardKey.slash);
      await t.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await t.pumpAndSettle();
      expect(c.codeLines[1].text, expected);
    }
  }, variant: _mac);
}
