import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/features/workspace/terminal/terminal_sessions.dart';
import 'package:xterm/xterm.dart';

import '../../data/detail_harness.dart' show FakeWsNet;
import 'harness.dart';

Finder toggle() => find.byKey(const ValueKey('rail-terminal-toggle'));

Iterable<Uri> shellUris(Rig rig) =>
    rig.net.uris.where((u) => u.path.contains('/terminal/'));

String textOf(WidgetTester tester, String key) => tester
    .widget<TerminalView>(find.byKey(ValueKey(key)))
    .terminal
    .buffer
    .getText();

void main() {
  group('drawer', () {
    testWidgets('closed by default, the rail toggle opens and hides it', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      expect(find.byKey(const ValueKey('term-tab-shell')), findsNothing);
      expect(shellUris(rig), isEmpty);
      expect(find.text('Terminal'), findsOneWidget);

      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('term-tab-shell')), findsOneWidget);
      expect(find.byKey(const ValueKey('term-tab-gate')), findsOneWidget);
      expect(find.byKey(const ValueKey('term-tab-problems')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('term-tab-devlog')),
        findsNothing,
        reason: 'no dev server has run, so no Dev log tab',
      );
      expect(find.text('Hide terminal'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('term-hide')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('term-tab-shell')), findsNothing);
    });

    testWidgets('the shell socket opens lazily on the Shell tab, once', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(shellUris(rig).map((u) => u.path), [
        '/ws/workspaces/$id/terminal/shell-0',
      ]);

      await tester.tap(find.byKey(const ValueKey('term-tab-problems')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('term-tab-shell')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('term-hide')));
      await tester.pumpAndSettle();
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(shellUris(rig), hasLength(1), reason: 'kept while the page lives');
    });

    testWidgets('shell output is shown and a closed socket offers Restart', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      final first = rig.net.latest;
      first.deliver({'prompt': 'haro on main'});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'shell-view'), contains('haro on main'));

      await first.dropFromServer();
      await tester.pumpAndSettle();
      expect(find.text('SHELL ENDED'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shell-restart')));
      await tester.pumpAndSettle();
      expect(shellUris(rig).map((u) => u.pathSegments.last), [
        'shell-0',
        'shell-1',
      ]);
      expect(find.text('SHELL ENDED'), findsNothing);
      expect(
        textOf(tester, 'shell-view'),
        isNot(contains('haro on main')),
        reason: 'restart starts on a clean screen',
      );
    });

    testWidgets('Dev log shows the workspace log lines', (tester) async {
      final log = DevLogBuffer()
        ..add('VITE v5 ready')
        ..add('  Local: http://localhost:4500/');
      final rig = Rig(
        Preview.green,
        detail: detailFor(Preview.green, devLog: log.snapshot()),
      );
      await rig.pump(tester);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('term-tab-devlog')));
      await tester.pumpAndSettle();
      final text = textOf(tester, 'devlog-view');
      expect(text, contains('VITE v5 ready'));
      expect(text, contains('http://localhost:4500/'));
    });

    testWidgets('leaving the page closes the shell socket', (tester) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(rig.net.latest.closed, isFalse);
      final shell = rig.net.latest;
      router.go('/');
      await tester.pumpAndSettle();
      await tester.runAsync(pumpEventQueue);
      expect(shell.closed, isTrue);
    });
  });

  group('ShellSession', () {
    test('forwards typing and resizes to the socket', () async {
      final net = FakeWsNet();
      final ws = HaroWs(Uri.parse('http://x:1'), connector: net.connect);
      final s = ShellSession(connect: (sid) => ws.terminal('w', sid));
      addTearDown(s.dispose);
      expect(s.phase, ShellPhase.idle);
      s.start();
      s.start();
      expect(net.channels, hasLength(1));
      expect(s.phase, ShellPhase.running);

      s.terminal.textInput('ls');
      s.terminal.resize(100, 30);
      await pumpEventQueue();
      final sent = net.latest.sent.map((m) => jsonDecode(m as String)).toList();
      expect(sent.any((m) => m['t'] == 'in' && m['d'] == 'ls'), isTrue);
      expect(
        sent.any((m) => m['t'] == 'resize' && m['c'] == 100 && m['r'] == 30),
        isTrue,
      );
    });

    test('dispose closes the socket', () async {
      final net = FakeWsNet();
      final ws = HaroWs(Uri.parse('http://x:1'), connector: net.connect);
      final s = ShellSession(connect: (sid) => ws.terminal('w', sid))..start();
      s.dispose();
      await pumpEventQueue();
      expect(net.latest.closed, isTrue);
    });
  });

  group('DevLogTerminal', () {
    test('appends only what is new and rewrites after a clear', () {
      final buf = DevLogBuffer();
      final t = DevLogTerminal();
      buf.add('one');
      t.sync(buf.snapshot());
      buf.add('two');
      buf.add('three');
      t.sync(buf.snapshot());
      var text = t.terminal.buffer.getText();
      expect(text, contains('one'));
      expect(text.indexOf('one'), text.lastIndexOf('one'));
      expect(text, contains('three'));

      buf.clear();
      buf.add('four');
      t.sync(buf.snapshot());
      text = t.terminal.buffer.getText();
      expect(text, contains('four'));
      expect(text, isNot(contains('one')));
    });
  });
}
