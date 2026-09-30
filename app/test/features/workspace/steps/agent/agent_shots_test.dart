import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

/// Local visual check, not part of the suite:
///   HARO_SHOTS=/some/dir flutter test test/features/workspace/steps/agent/agent_shots_test.dart
final _out = Platform.environment['HARO_SHOTS'];

void main() {
  final key = GlobalKey();

  Future<void> shot(
    WidgetTester tester,
    String name,
    AgentRig rig, {
    Size size = const Size(1400, 900),
    bool terminal = false,
    String? draft,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final router = buildRouter(initialLocation: '/w/$id/agent');
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: rig.overrides,
        child: RepaintBoundary(
          key: key,
          child: HaroApp(router: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/w/$id/agent');
    await tester.pumpAndSettle();
    if (terminal) {
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
    }
    if (draft != null) {
      await tester.enterText(field(), draft);
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/agent-$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  List<AgentEvent> longRun() => [
    ...prototypeTranscript().take(8),
    tokEv(
      'Here is what I found:\n\n'
      '1. The `PATH` scrape blocks the main process for about **1s**.\n'
      '2. The health timeout hides crashes.\n\n'
      '```js\nconst env = await resolveShellEnv();\n```\n\n'
      '> The gate confirms this at the end.',
    ),
  ];

  testWidgets('render agent states', (tester) async {
    await loadBrandFonts();
    Directory(_out!).createSync(recursive: true);
    final todo = backend(
      todoFiles: [
        todoFile('live-gate.md', [
          'Stream test results into the gate grid as they finish',
          'Show which added lines the green suite executed',
        ]),
        todoFile('desktop.md', ['Spawn the backend from the Flutter app']),
      ],
    );

    await shot(tester, 'idle-empty', AgentRig(Preview.idle, backend: todo));
    await shot(
      tester,
      'idle-draft',
      AgentRig(Preview.idle, backend: todo),
      draft: 'Make the desktop app start faster @desktop/ma',
    );
    await shot(
      tester,
      'running',
      AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        elapsed: const Duration(minutes: 3, seconds: 12),
        events: longRun(),
      ),
    );
    await shot(
      tester,
      'done',
      AgentRig(Preview.green, events: prototypeTranscript()),
    );
    await shot(
      tester,
      'plan-ready',
      AgentRig(
        Preview.idle,
        planReady: true,
        events: [
          userEv('Plan the shipping calculator.'),
          metaEv(role: 'plan', model: 'claude-opus-5'),
          toolEv('Read', 'lib/shipping.ts'),
          tokEv(
            'The plan:\n\n1. Add `calculateShipping` to `lib/shipping.ts`.\n'
            '2. Cover the free-shipping boundary in tests.\n3. Wire it into checkout.',
          ),
          doneEv(plan: true, durationMs: 75000, cost: 4.67),
        ],
      ),
    );
    await shot(
      tester,
      'waiting',
      AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        waiting: true,
        events: [
          userEv('Add a database layer.'),
          metaEv(),
          toolEv(
            'AskUserQuestion',
            '{"questions":[{"question":"Postgres or SQLite?","options":[{"label":"Postgres"},{"label":"SQLite"}]}]}',
          ),
        ],
      ),
    );
    await shot(
      tester,
      'narrow-terminal',
      AgentRig(Preview.green, events: prototypeTranscript()),
      size: const Size(900, 640),
      terminal: true,
    );
  }, skip: _out == null);
}
