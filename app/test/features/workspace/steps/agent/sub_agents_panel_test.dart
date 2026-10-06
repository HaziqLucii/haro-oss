import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';

import '../../../creation_harness.dart' as ch;

import 'package:haro_app/features/workspace/steps/agent/agent_step.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

Finder inStep(Finder f) =>
    find.descendant(of: find.byType(AgentStep), matching: f);

List<AgentEvent> transcript({bool done = false, bool fail = false}) => [
  userEv('please plan'),
  metaEv(),
  tokEv('Mapping first.'),
  delegateStartEv('t1', 'Explore', 'Map the Flutter code stage'),
  delegateStartEv('t2', 'scout', 'Find the routes'),
  nestedToolEv('t1', 'Read', 'lib/code_step.dart'),
  nestedToolEv('t1', 'Grep', 'EditPane'),
  nestedTokEv('t1', 'The code step has **three** panes.'),
  nestedToolEv('t2', 'Glob', 'lib/**/router*.dart'),
  if (done) delegateDoneEv('t1', 'Explore'),
  if (fail) delegateDoneEv('t2', 'scout', status: 'error'),
];

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('no delegation means no AGENTS section', (tester) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: [userEv('go'), metaEv(), toolEv('Read', 'a.ts')],
    );
    await rig.pump(tester, step: 'agent');
    expect(find.byKey(const ValueKey('rail-agents')), findsNothing);
  });

  testWidgets(
    'sub-agents are listed in the rail, their steps stay out of the stream',
    (tester) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: transcript(),
      );
      await rig.pump(tester, step: 'agent');
      expect(find.byKey(const ValueKey('rail-agents')), findsOneWidget);
      expect(find.text('2 running'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-row-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-row-t2')), findsOneWidget);
      // Each row shows what its sub-agent is doing right now.
      expect(find.text('Grep EditPane'), findsOneWidget);
      // None of a sub-agent's own steps leak into the driving agent's stream.
      expect(inStep(find.textContaining('EditPane')), findsNothing);
      expect(
        inStep(find.textContaining('code step has three panes')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'opening an agent shows its whole feed, back returns to the list',
    (tester) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: transcript(),
      );
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-detail')), findsOneWidget);
      expect(find.text('Explore'), findsWidgets);
      expect(find.text('Map the Flutter code stage'), findsWidgets);
      expect(find.text('lib/code_step.dart'), findsOneWidget);
      expect(find.text('EditPane'), findsOneWidget);
      expect(
        find.textContaining('**three**', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining(
          'The code step has three panes.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('running'), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-gate')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('agent-detail-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-detail')), findsNothing);
      expect(find.byKey(const ValueKey('rail-agents')), findsOneWidget);
    },
  );

  testWidgets('clicking the delegation row in the stream opens that agent', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: transcript(),
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(inStep(find.textContaining('↳ scout: Find the routes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-detail')), findsOneWidget);
    expect(find.text('lib/**/router*.dart'), findsOneWidget);
  });

  testWidgets('settled agents say done or failed', (tester) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: transcript(done: true, fail: true),
    );
    await rig.pump(tester, step: 'agent');
    expect(find.text('0 running'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-detail-status')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('agent-detail-status')))
          .data,
      'done',
    );
    await tester.tap(find.byKey(const ValueKey('agent-detail-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-row-t2')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('agent-detail-status')))
          .data,
      'failed',
    );
  });

  testWidgets(
    'Clear drops settled agents from the list and keeps running ones',
    (tester) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: transcript(done: true),
      );
      await rig.pump(tester, step: 'agent');
      expect(find.byKey(const ValueKey('agent-row-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-row-t2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rail-agents-clear')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-row-t1')),
        findsNothing,
        reason: 'done',
      );
      expect(
        find.byKey(const ValueKey('agent-row-t2')),
        findsOneWidget,
        reason: 'still running',
      );
      expect(find.byKey(const ValueKey('rail-agents-clear')), findsNothing);
    },
  );

  testWidgets('the section disappears once everything is cleared', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: [
        userEv('go'),
        metaEv(),
        delegateStartEv('t1', 'Explore', 'Map it'),
        delegateDoneEv('t1', 'Explore'),
      ],
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('rail-agents-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-agents')), findsNothing);
  });

  testWidgets(
    'a running agent offers no Clear; a settled one clears itself from its detail',
    (tester) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: transcript(done: true),
      );
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('agent-row-t2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-detail-clear')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('agent-detail-back')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-detail-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-detail')), findsNothing);
      expect(find.byKey(const ValueKey('agent-row-t1')), findsNothing);
      expect(find.byKey(const ValueKey('agent-row-t2')), findsOneWidget);
    },
  );

  testWidgets('opening a cleared agent from the stream brings its line back', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: transcript(done: true),
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('rail-agents-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-row-t1')), findsNothing);
    await tester.tap(
      inStep(find.textContaining('↳ Explore: Map the Flutter code stage')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-detail')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-row-t1')), findsOneWidget);
  });

  group('stop', () {
    testWidgets('a running sub-agent can be stopped; a settled one cannot', (
      tester,
    ) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: transcript(done: true),
        backend: backend(stopResponse: () => ch.jsonRes({'stopping': true})),
      );
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-detail-stop')),
        findsNothing,
        reason: 't1 is done',
      );
      await tester.tap(find.byKey(const ValueKey('agent-detail-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-row-t2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-detail-stop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-detail-clear')),
        findsNothing,
        reason: 'running',
      );
    });

    testWidgets(
      'STOP posts for that delegation and reads stopping until it settles',
      (tester) async {
        final rig = AgentRig(
          Preview.idle,
          status: WorkspaceStatus.agentRunning,
          events: [
            userEv('go'),
            metaEv(),
            delegateStartEv('t1', 'Explore', 'Map it'),
            nestedToolEv('t1', 'Read', 'a.dart'),
          ],
          backend: backend(stopResponse: () => ch.jsonRes({'stopping': true})),
        );
        await rig.pump(tester, step: 'agent');
        await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('agent-detail-stop')));
        await tester.pumpAndSettle();
        expect(
          rig.api.where('POST', '/workspaces/ws_1/agents/t1/stop'),
          hasLength(1),
        );
        expect(find.text('STOPPING…'), findsOneWidget);
      },
    );

    testWidgets('a refusal from the backend is shown and STOP comes back', (
      tester,
    ) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: [
          userEv('go'),
          metaEv(),
          delegateStartEv('t1', 'Explore', 'Map it'),
        ],
        backend: backend(
          stopResponse: () => ch.errorRes(
            'that sub-agent is not running (it may have just finished)',
            409,
          ),
        ),
      );
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-detail-stop')));
      await tester.pumpAndSettle();
      expect(
        find.text('that sub-agent is not running (it may have just finished)'),
        findsOneWidget,
      );
      expect(find.text('STOP'), findsOneWidget);
    });
  });

  testWidgets('a wide table in a sub-agent scrolls sideways', (tester) async {
    final wide =
        '| name | what it does |\n| --- | --- |\n'
        '| a | ${'a very long cell that cannot fit the rail ' * 6} |';
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: [
        userEv('go'),
        metaEv(),
        delegateStartEv('t1', 'Explore', 'Map it'),
        nestedTokEv('t1', wide),
      ],
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
    await tester.pumpAndSettle();
    final scroll = find.byKey(const ValueKey('agent-table-scroll'));
    expect(scroll, findsOneWidget);
    final pos = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    expect(pos.maxScrollExtent, greaterThan(0));
    await tester.drag(scroll, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(pos.pixels, greaterThan(0));
  });

  testWidgets('fullscreen opens the agent over the window, Esc closes it', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: transcript(),
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-full-t1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('agent-detail-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-full-t1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agent-full-t1')),
        matching: find.byKey(const ValueKey('agent-detail-fullscreen')),
      ),
      findsNothing,
    );
    expect(find.text('lib/code_step.dart'), findsNWidgets(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-full-t1')), findsNothing);
    expect(find.byKey(const ValueKey('agent-detail')), findsOneWidget);
  });

  testWidgets(
    'the exit row closes fullscreen and leaves the rail on the agent',
    (tester) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: transcript(),
      );
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-detail-fullscreen')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('agent-full-t1')),
          matching: find.byKey(const ValueKey('agent-detail-back')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-full-t1')), findsNothing);
      expect(find.byKey(const ValueKey('agent-detail')), findsOneWidget);
    },
  );

  testWidgets('CLEAR in fullscreen closes it once and leaves the page up', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: transcript(done: true),
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('agent-row-t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-detail-fullscreen')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('agent-full-t1')),
        matching: find.byKey(const ValueKey('agent-detail-clear')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-full-t1')), findsNothing);
    expect(find.byKey(const ValueKey('agent-detail')), findsNothing);
    expect(find.byType(AgentStep), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-row-t2')), findsOneWidget);
  });
}
