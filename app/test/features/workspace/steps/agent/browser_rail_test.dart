import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';

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
}
