import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/terminal/selectable_terminal.dart';
import 'package:xterm/xterm.dart';

/// 200 numbered lines in a view 8 lines tall: the output of a long command cannot be selected
/// on one screen.
Future<(Terminal, TerminalController)> pump(
  WidgetTester tester, {
  bool mouseMode = false,
  bool readOnly = true,
}) async {
  final terminal = Terminal(maxLines: 1000);
  terminal.resize(40, 8);
  for (var i = 1; i <= 200; i++) {
    terminal.write('line ${i.toString().padLeft(3, '0')}\r\n');
  }
  if (mouseMode) terminal.write('\x1b[?1000h');
  final controller = TerminalController();
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 160,
          child: SelectableTerminal(
            terminal,
            controller: controller,
            readOnly: readOnly,
            textStyle: const TerminalStyle(fontSize: 14),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (terminal, controller);
}

Future<TestGesture> mouseDown(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  return g;
}

void main() {
  testWidgets('a drag inside the view selects what it covers', (tester) async {
    final (terminal, controller) = await pump(tester);
    final g = await mouseDown(tester, const Offset(8, 20));
    await g.moveTo(const Offset(80, 60));
    await tester.pump();
    final sel = controller.selection;
    expect(sel, isNotNull);
    expect(terminal.buffer.getText(sel).split('\n').length, greaterThan(1));
    await g.up();
  });

  testWidgets(
    'holding the pointer above the view scrolls and keeps selecting',
    (tester) async {
      final (terminal, controller) = await pump(tester);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final start = scroll.pixels;
      // Press near the bottom of the output, as when copying the end of a long command's output.
      final g = await mouseDown(tester, const Offset(8, 140));
      await g.moveTo(const Offset(80, 100));
      await tester.pump();
      // Hold the pointer above the view: it scrolls back through the output, selecting as it goes.
      await g.moveTo(const Offset(80, -120));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await g.up();
      expect(scroll.pixels, lessThan(start), reason: 'the view scrolled up');
      final sel = controller.selection!;
      expect(
        (sel.end.y - sel.begin.y).abs(),
        greaterThan(8),
        reason: 'more than one screen of lines is selected',
      );
      expect(terminal.buffer.getText(sel).split('\n').length, greaterThan(8));
    },
  );

  testWidgets('a program that asked for the mouse gets no auto-scroll', (
    tester,
  ) async {
    await pump(tester, mouseMode: true, readOnly: false);
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final start = scroll.pixels;
    final g = await mouseDown(tester, const Offset(8, 140));
    await g.moveTo(const Offset(80, 100));
    await g.moveTo(const Offset(80, -120));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await g.up();
    expect(scroll.pixels, start);
  });

  testWidgets('an upward drag keeps the character it started on', (
    tester,
  ) async {
    final (_, controller) = await pump(tester);
    final pressed = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal
        .getCellOffset(const Offset(62, 130));
    final g = await mouseDown(tester, const Offset(62, 130));
    await g.moveTo(const Offset(62, 100));
    await g.moveTo(const Offset(8, 40));
    await tester.pump();
    await g.up();
    final sel = controller.selection!;
    // A backward selection starts at the press: its base is one past the pressed cell.
    expect(
      sel.begin,
      CellOffset(pressed.x + 1, pressed.y),
      reason: 'the selection runs through the pressed cell, inclusive',
    );
  });

  testWidgets(
    'the drag ends with the press, even when no up reaches the view',
    (tester) async {
      await pump(tester);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final g = await mouseDown(tester, const Offset(8, 140));
      await g.moveTo(const Offset(80, 100));
      await g.moveTo(const Offset(80, -120));
      await tester.pump(const Duration(milliseconds: 120));
      await g.up();
      final after = scroll.pixels;
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        scroll.pixels,
        after,
        reason: 'no auto-scroll after the button is up',
      );
    },
  );

  testWidgets('a plain click selects nothing', (tester) async {
    final (_, controller) = await pump(tester);
    final g = await mouseDown(tester, const Offset(8, 20));
    await g.up();
    await tester.pump(
      const Duration(milliseconds: 500),
    ); // the double-tap window closes
    expect(controller.selection, isNull);
  });

  group('a read-only view copies with plain Ctrl+C', () {
    Future<(Terminal, TerminalController)> pumpLog(WidgetTester tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(40, 8);
      terminal.write('first line\r\nsecond line\r\n');
      final controller = TerminalController();
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 160,
              child: SelectableTerminal(
                terminal,
                controller: controller,
                readOnly: true,
                shortcuts: readOnlyTerminalShortcuts,
                textStyle: const TerminalStyle(fontSize: 14),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return (terminal, controller);
    }

    testWidgets('a drag selects and Ctrl+C puts it on the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (_, controller) = await pumpLog(tester);
      final g = await mouseDown(tester, const Offset(8, 10));
      await g.moveTo(const Offset(150, 10));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.selection, isNotNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(copied, isNotNull);
      expect(copied, contains('first'));
    });
  });
}
