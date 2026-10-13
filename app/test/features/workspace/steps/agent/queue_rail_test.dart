import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

const _two = [
  QueuedPrompt(id: 'q1', text: 'then add tests for the parser'),
  QueuedPrompt(id: 'q2', text: 'and update the changelog'),
];

AgentRig rig({
  WorkspaceStatus status = WorkspaceStatus.agentRunning,
  List<QueuedPrompt> queued = _two,
}) => AgentRig(
  Preview.idle,
  status: status,
  queued: queued,
  events: [userEv('go'), metaEv(), toolEv('Read', 'a.ts')],
);

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('nothing queued means no QUEUE section', (tester) async {
    await rig(queued: const []).pump(tester, step: 'agent');
    expect(find.byKey(const ValueKey('rail-queue')), findsNothing);
  });

  testWidgets('the section lists each prompt and says what a click does', (
    tester,
  ) async {
    await rig().pump(tester, step: 'agent');
    expect(find.byKey(const ValueKey('rail-queue')), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(find.text('then add tests for the parser'), findsOneWidget);
    expect(find.text('and update the changelog'), findsOneWidget);
    expect(
      find.text('Each starts when this run ends. Click one to send it in now.'),
      findsOneWidget,
    );
  });

  testWidgets('clicking a prompt sends it (steer)', (tester) async {
    final r = rig();
    await r.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('queue-row-q2')));
    await tester.pumpAndSettle();
    expect(r.agent.sent, ['q2']);
    expect(r.agent.unqueued, isEmpty);
  });

  testWidgets('the x removes one without sending it', (tester) async {
    final r = rig();
    await r.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('queue-remove-q1')));
    await tester.pumpAndSettle();
    expect(r.agent.unqueued, ['q1']);
    expect(r.agent.sent, isEmpty);
  });

  testWidgets('with no run going the hint says a click starts it', (
    tester,
  ) async {
    final r = rig(status: WorkspaceStatus.idle);
    await r.pump(tester, step: 'agent');
    expect(find.text('The run ended. Click one to start it.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queue-row-q1')));
    await tester.pumpAndSettle();
    expect(r.agent.sent, ['q1']);
  });

  testWidgets('a run that is not listening says so and keeps the prompt', (
    tester,
  ) async {
    final r = rig();
    r.agent.sendFails = const HaroApiException(
      409,
      'the run is not taking messages right now; it will go next',
    );
    await r.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('queue-row-q1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('will go next'), findsOneWidget);
    expect(find.text('then add tests for the parser'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a steered message reads as such in the stream', (tester) async {
    final r = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: [
        userEv('go'),
        metaEv(),
        toolEv('Read', 'a.ts'),
        AgentEvent(
          runId: 'user',
          workspaceId: 'ws',
          ts: 1,
          type: AgentEventType.user,
          payload: const {'text': 'use the other table', 'steer': true},
        ),
      ],
    );
    await r.pump(tester, step: 'agent');
    expect(find.textContaining('YOU, MID-RUN'), findsOneWidget);
    expect(find.text('use the other table'), findsOneWidget);
  });
}
