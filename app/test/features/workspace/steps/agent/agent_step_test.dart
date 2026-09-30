import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_step.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/status_square.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

Finder inStep(Finder f) =>
    find.descendant(of: find.byType(AgentStep), matching: f);

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('renders the prototype stream', (tester) async {
    final rig = AgentRig(Preview.idle, events: prototypeTranscript());
    await rig.pump(tester, step: 'agent');
    expect(tester.takeException(), isNull);

    expect(find.byKey(const ValueKey('user-label')).evaluate(), isNotEmpty);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('user-label'))).data,
      'YOU · 14M AGO',
    );
    expect(
      find.textContaining('Make the desktop app start faster'),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('agent-label'))).data,
      'AGENT · BUILD · SONNET-5 · HIGH',
    );
    expect(find.text('desktop/main.js'), findsWidgets);
    expect(find.text('+211'), findsOneWidget);
    expect(find.text('−134'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('turn-footer'))).data,
      'done in 14m 1s · 3 files · \$9.89',
    );
    expect(find.text('Review changes in code →'), findsOneWidget);
    expect(find.textContaining('Boot takes 3.4s'), findsOneWidget);
  });

  testWidgets('tool squares are never green and hollow only while running', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: [
        userEv('go'),
        metaEv(),
        toolEv('Read', 'a.ts'),
        toolEv('Bash', 'npm test'),
      ],
    );
    await rig.pump(tester, step: 'agent');
    final squares = tester
        .widgetList<StatusSquare>(inStep(find.byType(StatusSquare)))
        .toList();
    expect(squares.any((s) => s.color == HaroTokens.gate), isFalse);
    // Read is done (filled), Bash is in flight (hollow).
    expect(squares.map((s) => s.filled), [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Review changes in code navigates to the code step', (
    tester,
  ) async {
    final rig = AgentRig(Preview.idle, events: prototypeTranscript());
    final router = await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('review-in-code')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/code');
  });

  testWidgets('plan ready: Approve plan is the only approve action', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      planReady: true,
      events: [
        userEv('plan it'),
        metaEv(role: 'plan'),
        tokEv('1. do a\n2. do b'),
        doneEv(plan: true, durationMs: 75000, cost: 4.67),
      ],
    );
    await rig.pump(tester, step: 'agent');
    expect(find.byKey(const ValueKey('approve-plan')), findsOneWidget);
    expect(find.text('Review changes in code →'), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('turn-footer'))).data,
      'plan ready in 1m 15s · \$4.67',
    );
    await tester.tap(find.byKey(const ValueKey('approve-plan')));
    await tester.pumpAndSettle();
    expect(rig.agent.approvals, 1);
  });

  testWidgets('a superseded plan does not offer approval', (tester) async {
    final rig = AgentRig(
      Preview.idle,
      events: [
        userEv('plan it'),
        tokEv('plan'),
        doneEv(plan: true),
        userEv('build', turn: 2),
        tokEv('built', turn: 2),
        doneEv(turn: 2),
      ],
    );
    await rig.pump(tester, step: 'agent');
    expect(find.byKey(const ValueKey('approve-plan')), findsNothing);
  });

  testWidgets('waiting on input shows the question', (tester) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      waiting: true,
      events: [
        userEv('go'),
        metaEv(),
        toolEv(
          'AskUserQuestion',
          '{"questions":[{"question":"Postgres or SQLite?"}]}',
        ),
      ],
    );
    await rig.pump(tester, step: 'agent');
    expect(find.byKey(const ValueKey('agent-question')), findsOneWidget);
    expect(find.text('Postgres or SQLite?'), findsOneWidget);
    expect(find.text('WAITING FOR YOUR ANSWER'), findsOneWidget);
  });

  testWidgets('errors show inline', (tester) async {
    final rig = AgentRig(
      Preview.idle,
      events: [userEv('go'), errorEv('rate limited')],
    );
    await rig.pump(tester, step: 'agent');
    expect(find.text('rate limited'), findsOneWidget);
  });

  group('empty state', () {
    testWidgets('three open backlog items fill the composer', (tester) async {
      final rig = AgentRig(
        Preview.idle,
        backend: backend(
          todoFiles: [
            todoFile('live-gate.md', [
              'Stream results as tests finish',
              'Second',
              'Third',
            ]),
            todoFile('desktop.md', ['Fourth is not shown']),
          ],
        ),
      );
      await rig.pump(tester, step: 'agent');
      expect(find.text('What should the agent do?'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-3')), findsNothing);
      expect(find.text('live-gate.md'), findsNWidgets(3));

      expect(fieldText(tester), '');
      await tester.tap(find.byKey(const ValueKey('suggestion-1')));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Second');
      final focus = Focus.of(tester.element(field()));
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('no backlog: title and line, no suggestions', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      expect(find.text('What should the agent do?'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-0')), findsNothing);
    });
  });

  group('scrolling', () {
    List<AgentEvent> many(int n) => [
      userEv('go'),
      metaEv(),
      for (var i = 0; i < n; i++) toolEv('Bash', 'command number $i'),
    ];

    ScrollPosition position(WidgetTester tester) => tester
        .state<ScrollableState>(inStep(find.byType(Scrollable)).first)
        .position;

    testWidgets('follows the stream, stops when scrolled up, resumes', (
      tester,
    ) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: many(60),
      );
      await rig.pump(tester, size: const Size(1400, 700), step: 'agent');
      var p = position(tester);
      expect(p.maxScrollExtent, greaterThan(0));
      expect(p.extentAfter, lessThan(2));
      expect(find.byKey(const ValueKey('jump-latest')), findsNothing);

      pushEvents(tester, rig, many(90));
      await tester.pumpAndSettle();
      p = position(tester);
      expect(p.extentAfter, lessThan(2), reason: 'still pinned to the end');

      await tester.drag(inStep(find.byType(ListView)), const Offset(0, 400));
      await tester.pumpAndSettle();
      p = position(tester);
      final held = p.pixels;
      expect(p.extentAfter, greaterThan(100));
      expect(find.byKey(const ValueKey('jump-latest')), findsOneWidget);

      pushEvents(tester, rig, many(120));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, held, reason: 'reader is left alone');
      expect(find.byKey(const ValueKey('jump-latest')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('jump-latest')));
      await tester.pumpAndSettle();
      expect(position(tester).extentAfter, lessThan(2));
      expect(find.byKey(const ValueKey('jump-latest')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a running agent with no output yet shows the working line', (
      tester,
    ) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        elapsed: const Duration(seconds: 14),
        events: [userEv('go')],
      );
      await rig.pump(tester, step: 'agent');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('working-line'))).data,
        'working · 14s',
      );
    });
  });

  testWidgets('markdown prose does not use green', (tester) async {
    final rig = AgentRig(
      Preview.idle,
      events: [
        userEv('go'),
        tokEv(
          'Use `foo()` here.\n\n```dart\nfinal a = 1;\n```\n\n- one\n- two',
        ),
        doneEv(),
      ],
    );
    await rig.pump(tester, step: 'agent');
    expect(
      find.textContaining('final a = 1;', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('no overflow at 900x640 with the terminal open', () {
    Future<void> check(WidgetTester tester, AgentRig rig) async {
      await rig.pump(tester, size: const Size(900, 640), step: 'agent');
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('composer')), findsOneWidget);
    }

    testWidgets(
      'idle empty',
      (tester) => check(tester, AgentRig(Preview.idle)),
    );
    testWidgets(
      'done with a footer',
      (tester) =>
          check(tester, AgentRig(Preview.green, events: prototypeTranscript())),
    );
    testWidgets(
      'running',
      (tester) => check(
        tester,
        AgentRig(
          Preview.idle,
          status: WorkspaceStatus.agentRunning,
          events: [userEv('go'), metaEv(), toolEv('Read', 'a.ts')],
        ),
      ),
    );
    testWidgets(
      'plan ready',
      (tester) => check(
        tester,
        AgentRig(
          Preview.idle,
          planReady: true,
          events: [userEv('p'), tokEv('the plan'), doneEv(plan: true)],
        ),
      ),
    );

    testWidgets('a long draft, an attachment and an error still fit', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await check(tester, rig);
      await tester.enterText(field(), List.filled(12, 'line').join('\n'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(field(), List.filled(30, 'pasted').join('\n'));
      await tester.pumpAndSettle();
      expect(find.textContaining('pasted-ab12.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('composer-run')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
