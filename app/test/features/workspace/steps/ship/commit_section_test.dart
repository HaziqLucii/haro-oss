import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/ship/commit_section.dart';
import 'package:haro_app/widgets/haro_text_field.dart';

const _pasted =
    'feat: multi-line\n\nBody paragraph that is far longer than seventy-two '
    'characters so any hidden wrapping would show up here.\n\n\nCo-Authored-By: X';

class _Rig {
  final calls = <String>[];
  bool ok = true;
  final ignoredKeys = <LogicalKeyboardKey>[];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent) ignoredKeys.add(e.logicalKey);
              return KeyEventResult.ignored;
            },
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: CommitSection(
                  commits: const [],
                  dirty: 2,
                  ahead: 0,
                  onCommit: (m) async {
                    calls.add(m);
                    return ok;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _field = find.byKey(const ValueKey('commit-field'));
double _h(WidgetTester t) => t.getSize(_field).height;
String _text(WidgetTester t) => t
    .widget<TextField>(
      find.descendant(of: _field, matching: find.byType(TextField)),
    )
    .controller!
    .text;

Future<void> _enter(WidgetTester tester, {LogicalKeyboardKey? mod}) async {
  if (mod != null) await tester.sendKeyDownEvent(mod);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  if (mod != null) await tester.sendKeyUpEvent(mod);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('paste keeps newlines and Enter submits the whole string', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, _pasted);
    await tester.pump();
    expect(_text(tester), _pasted);
    await _enter(tester);
    expect(rig.calls, [_pasted]);
    expect(_text(tester), '');
  });

  testWidgets('Shift+Enter does not submit and reaches the text input', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, 'wip');
    await _enter(tester, mod: LogicalKeyboardKey.shiftLeft);
    expect(rig.calls, isEmpty);
    expect(rig.ignoredKeys, contains(LogicalKeyboardKey.enter));
    expect(_text(tester), 'wip');
  });

  testWidgets('Enter is swallowed so it never reaches the text input', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, 'wip');
    await _enter(tester);
    expect(rig.ignoredKeys, isNot(contains(LogicalKeyboardKey.enter)));
  });

  testWidgets('Cmd+Enter and Ctrl+Enter submit once each', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, 'a');
    await _enter(tester, mod: LogicalKeyboardKey.metaLeft);
    expect(rig.calls, ['a']);
    await tester.enterText(_field, 'b');
    await _enter(tester, mod: LogicalKeyboardKey.controlLeft);
    expect(rig.calls, ['a', 'b']);
  });

  testWidgets('whitespace-only does not submit and keeps focus', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, '  \n ');
    await _enter(tester);
    expect(rig.calls, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets('a failed commit keeps the text', (tester) async {
    final rig = _Rig()..ok = false;
    await rig.pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, 'keep me\n\nbody');
    await _enter(tester);
    expect(rig.calls, ['keep me\n\nbody']);
    expect(_text(tester), 'keep me\n\nbody');
  });

  testWidgets('height starts at one line, grows, caps near 10 lines, shrinks', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    expect(_h(tester), 36);
    await tester.tap(_field);
    await tester.enterText(_field, 'a\nb\nc');
    await tester.pump();
    final three = _h(tester);
    expect(three, greaterThan(36));
    await tester.enterText(_field, List.filled(10, 'x').join('\n'));
    await tester.pump();
    final ten = _h(tester);
    expect(ten, greaterThan(three));
    await tester.enterText(_field, List.filled(30, 'x').join('\n'));
    await tester.pump();
    expect(_h(tester), ten);
    await _enter(tester);
    expect(_h(tester), 36);
  });

  testWidgets('HaroTextField defaults stay a fixed single line', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: HaroTextField(height: 30))),
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, 1);
    expect(field.minLines, isNull);
    expect(tester.getSize(find.byType(HaroTextField)).height, 30);
  });
}
