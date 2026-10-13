import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/rail/browser_activity.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

AgentRig rig() => AgentRig(
  Preview.idle,
  status: WorkspaceStatus.idle,
  events: [userEv('go'), metaEv()],
);

final _state = find.byKey(const ValueKey('rail-browser-state'));
final _toggle = find.byKey(const ValueKey('rail-browser-toggle'));

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('off: says so, offers to open it, and Open starts it', (
    tester,
  ) async {
    final r = rig();
    var running = false;
    final posts = <String>[];
    r.api.routes['GET /workspaces/ws_1/browser'] = (_) =>
        jsonRes({'running': running, 'starting': false, 'port': null});
    r.api.routes['POST /workspaces/ws_1/browser/start'] = (_) {
      posts.add('start');
      running = true;
      return jsonRes({'running': true, 'starting': false, 'port': 4123});
    };
    await r.pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(find.text('BROWSER'), findsOneWidget);
    expect(tester.widget<Text>(_state).data, 'OFF');
    expect(find.byTooltip('Open the browser'), findsOneWidget);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(posts, ['start']);
    expect(tester.widget<Text>(_state).data, 'ON');
    expect(find.byTooltip('Close the browser'), findsOneWidget);
  });

  testWidgets('on: Close stops it', (tester) async {
    final r = rig();
    var running = true;
    var stopped = 0;
    r.api.routes['GET /workspaces/ws_1/browser'] = (_) =>
        jsonRes({'running': running, 'starting': false, 'port': 4123});
    r.api.routes['POST /workspaces/ws_1/browser/stop'] = (_) {
      stopped++;
      running = false;
      return jsonRes({'running': false, 'starting': false, 'port': null});
    };
    await r.pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_state).data, 'ON');
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(stopped, 1);
    expect(tester.widget<Text>(_state).data, 'OFF');
  });

  testWidgets('a start that fails says why and stays off', (tester) async {
    final r = rig();
    r.api.routes['GET /workspaces/ws_1/browser'] = (_) =>
        jsonRes({'running': false, 'starting': false, 'port': null});
    r.api.routes['POST /workspaces/ws_1/browser/start'] = (_) => errorRes(
      'npx was not found on PATH: the shared browser needs Node.js',
      400,
    );
    await r.pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(find.textContaining('needs Node.js'), findsOneWidget);
    expect(tester.widget<Text>(_state).data, 'OFF');
    await tester.pump(const Duration(seconds: 6)); // the toast's own timer
  });

  testWidgets('a backend that cannot be read shows it off, never on', (
    tester,
  ) async {
    final r = rig();
    r.api.routes['GET /workspaces/ws_1/browser'] = (_) => errorRes('boom', 500);
    await r.pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_state).data, 'OFF');
  });

  group('browserInUse', () {
    final nav = toolEv('mcp__haro_browser__browser_navigate', 'https://x');
    test('the newest event is a browser call of a running agent', () {
      expect(browserInUse([userEv('go'), nav], running: true), 'navigate');
      expect(
        browserInUse([
          toolEv('mcp__haro_browser__browser_take_screenshot', ''),
        ], running: true),
        'take screenshot',
      );
    });

    test('not when the run ended, a later event came, or it is not the shared browser', () {
      expect(browserInUse([nav], running: false), isNull);
      expect(browserInUse([nav, tokEv('done with it')], running: true), isNull);
      expect(browserInUse([nav, toolEv('Read', 'a')], running: true), isNull);
      expect(
        browserInUse([
          toolEv('mcp__plugin_playwright_playwright__browser_click', ''),
        ], running: true),
        isNull,
      );
      expect(browserInUse(const [], running: true), isNull);
    });

    test(
      'a background agent using the browser counts, the newest event decides',
      () {
        final main = tokEv('A background agent is polling.');
        final sub = toolEv(
          'mcp__haro_browser__browser_run_code_unsafe',
          'poll',
        );
        expect(
          browserInUse([main], running: true, subEvents: [sub]),
          'run code unsafe',
        );
        final later = toolEv('Bash', 'sleep 30');
        expect(
          browserInUse([main], running: true, subEvents: [sub, later]),
          isNull,
          reason: 'the background agent moved on',
        );
        final spoke = tokEv('The page is loaded.');
        expect(
          browserInUse([main, spoke], running: true, subEvents: [sub]),
          isNull,
          reason: 'the main agent spoke after it',
        );
      },
    );
  });

  final inUse = find.byKey(const ValueKey('rail-browser-in-use'));
  final hint = find.byKey(const ValueKey('rail-browser-hint'));
  final palettes = <String, HaroPalette>{
    'haro': HaroPalette.haro,
    'material3': HaroPalette.material3,
    'paper': HaroPalette.paper,
  };

  for (final entry in palettes.entries) {
    group('the browser card while the agent works, ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      AgentRig working(List<AgentEvent> events, {WorkspaceStatus? status}) {
        final r = AgentRig(
          Preview.idle,
          status: status ?? WorkspaceStatus.agentRunning,
          events: [userEv('go'), metaEv(), ...events],
        );
        r.api.routes['GET /workspaces/ws_1/browser'] = (_) =>
            jsonRes({'running': true, 'starting': false, 'port': 4123});
        return r;
      }

      testWidgets('a badge and the step while a browser call is going', (
        tester,
      ) async {
        await working([
          toolEv('mcp__haro_browser__browser_navigate', 'https://x'),
        ]).pump(tester, step: 'agent');
        await tester.pumpAndSettle();
        expect(inUse, findsOneWidget);
        expect(find.text('IN USE'), findsOneWidget);
        expect(tester.widget<Text>(_state).data, 'ON');
        expect(
          tester.widget<Text>(hint).data,
          'The agent is using it now: navigate.',
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('no badge once the agent moved on, or when the run is over', (
        tester,
      ) async {
        await working([
          toolEv('mcp__haro_browser__browser_navigate', 'https://x'),
          tokEv('The page loaded.'),
        ]).pump(tester, step: 'agent');
        await tester.pumpAndSettle();
        expect(inUse, findsNothing);
        expect(tester.widget<Text>(hint).data, startsWith('Every run here'));

        await working([
          toolEv('mcp__haro_browser__browser_navigate', 'https://x'),
        ], status: WorkspaceStatus.idle).pump(tester, step: 'agent');
        await tester.pumpAndSettle();
        expect(inUse, findsNothing);
      });

      testWidgets('no badge when the browser is off', (tester) async {
        final r = working([
          toolEv('mcp__haro_browser__browser_navigate', 'https://x'),
        ]);
        r.api.routes['GET /workspaces/ws_1/browser'] = (_) =>
            jsonRes({'running': false, 'starting': false, 'port': null});
        await r.pump(tester, step: 'agent');
        await tester.pumpAndSettle();
        expect(inUse, findsNothing);
      });
    });
  }
}
