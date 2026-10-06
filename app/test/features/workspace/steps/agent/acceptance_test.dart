import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/agent/acceptance_panel.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

TestFirstState state(String phase, {String? reason, int cases = 2}) =>
    TestFirstState.fromJson({
      'phase': phase,
      'task': 'add a shipping calculator',
      'reject_reason': reason,
      'files': [
        {
          'path': 'tests/test_ship.py',
          'file': 'tests/test_ship.py',
          'sha256': 'ab',
        },
      ],
      'cases': [
        for (var i = 0; i < cases; i++)
          {
            'file': 'tests/test_ship.py',
            'name': 'ships free over 100 ($i)',
            'message': 'ImportError: no module named shipping',
          },
      ],
    });

List<HaroButton> primaries(WidgetTester tester) => [
  for (final b in tester.widgetList<HaroButton>(
    find.descendant(
      of: find.byType(WorkspacePage),
      matching: find.byType(HaroButton),
    ),
  ))
    if (b.variant == HaroButtonVariant.primary && b.onPressed != null) b,
];

AgentRig reviewRig({TestFirstState? tf}) => AgentRig(
  Preview.idle,
  testFirst: tf ?? state('review'),
  events: [
    userEv('add a shipping calculator'),
    tokEv('Drafted the test.'),
    doneEv(),
  ],
);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(
    backgroundColor: HaroTokens.bg,
    body: SingleChildScrollView(child: child),
  ),
);

void main() {
  setUpAll(loadBrandFonts);

  group('panel', () {
    testWidgets('shows the red proof, the drafted lines and one primary', (
      tester,
    ) async {
      var approved = 0;
      await tester.pumpWidget(
        host(
          AcceptancePanel(
            state: state('review'),
            diffLines: const {
              'tests/test_ship.py': [
                'def test_ships_free():',
                '    from shipping import ship',
              ],
            },
            onApprove: () => approved++,
            onAskChanges: () {},
          ),
        ),
      );
      expect(find.text('ACCEPTANCE TEST · PROVEN RED'), findsOneWidget);
      expect(find.text('2 tests, every one failing on base'), findsOneWidget);
      expect(find.byKey(const ValueKey('acceptance-case-1')), findsOneWidget);
      expect(find.textContaining('ImportError'), findsNWidgets(2));
      expect(find.text('+ def test_ships_free():'), findsOneWidget);
      final approve = tester.widget<HaroButton>(
        find.byKey(const ValueKey('approve-test')),
      );
      expect(approve.variant, HaroButtonVariant.primary);
      await tester.tap(find.byKey(const ValueKey('approve-test')));
      expect(approved, 1);
    });

    testWidgets(
      'approve drops to secondary where the step bar owns the primary',
      (tester) async {
        await tester.pumpWidget(
          host(
            AcceptancePanel(
              state: state('review'),
              diffLines: const {},
              primary: false,
              onApprove: () {},
              onAskChanges: () {},
            ),
          ),
        );
        expect(
          tester
              .widget<HaroButton>(find.byKey(const ValueKey('approve-test')))
              .variant,
          HaroButtonVariant.secondary,
        );
        expect(find.text('Diff not loaded yet.'), findsOneWidget);
      },
    );

    testWidgets('a rejected draft has no approve, only a redraft', (
      tester,
    ) async {
      var asked = 0;
      await tester.pumpWidget(
        host(
          AcceptancePanel(
            state: state(
              'rejected',
              reason: 'No tests were collected. Ask again.',
            ),
            diffLines: const {},
            onApprove: () {},
            onAskChanges: () => asked++,
          ),
        ),
      );
      expect(find.text('ACCEPTANCE TEST · REJECTED'), findsOneWidget);
      expect(find.byKey(const ValueKey('approve-test')), findsNothing);
      expect(find.text('No tests were collected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ask-changes')));
      expect(asked, 1);
    });

    testWidgets('leaving test-first takes two taps and can be undone', (
      tester,
    ) async {
      var leaves = 0;
      var keeps = 0;
      Widget panel({required bool armed}) => host(
        AcceptancePanel(
          state: state('review'),
          diffLines: const {},
          onApprove: () {},
          onAskChanges: () {},
          onLeave: () => leaves++,
          leaveArmed: armed,
          onKeep: () => keeps++,
        ),
      );
      await tester.pumpWidget(panel(armed: false));
      expect(find.text('Leave test-first'), findsOneWidget);
      expect(find.byKey(const ValueKey('keep-test-first')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('leave-test-first')));
      expect(leaves, 1);
      await tester.pumpWidget(panel(armed: true));
      expect(find.text('Confirm: leave test-first'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('keep-test-first')));
      expect(keeps, 1);
    });

    testWidgets('a busy approval disables the button', (tester) async {
      await tester.pumpWidget(
        host(
          AcceptancePanel(
            state: state('review'),
            diffLines: const {},
            busy: true,
            onApprove: () {},
            onAskChanges: () {},
          ),
        ),
      );
      expect(find.text('Approving…'), findsOneWidget);
      expect(
        tester
            .widget<HaroButton>(find.byKey(const ValueKey('approve-test')))
            .onPressed,
        isNull,
      );
    });
  });

  group('agent step', () {
    testWidgets(
      'review: Approve test is the single primary, the composer redrafts',
      (tester) async {
        final rig = reviewRig();
        await rig.pump(tester, step: 'agent');
        expect(tester.takeException(), isNull);
        expect(primaries(tester).map((b) => b.label), ['Approve test']);
        expect(
          tester
              .widget<HaroButton>(find.byKey(const ValueKey('composer-run')))
              .label,
          'Redraft test',
        );
        expect(find.byKey(const ValueKey('test-first')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('approve-test')));
        await tester.pumpAndSettle();
        expect(rig.agent.testFirstApprovals, 1);
      },
    );

    testWidgets('a rejected draft: Redraft test is the single primary', (
      tester,
    ) async {
      final rig = reviewRig(
        tf: state('rejected', reason: 'No tests were collected.'),
      );
      await rig.pump(tester, step: 'agent');
      expect(primaries(tester).map((b) => b.label), ['Redraft test']);
    });

    testWidgets('feedback in the composer is sent as a test-first redraft', (
      tester,
    ) async {
      final rig = reviewRig();
      await rig.pump(tester, step: 'agent');
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'also assert the error message',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-run')));
      await tester.pumpAndSettle();
      final c = rig.agent.starts.single;
      expect(c.task, 'also assert the error message');
      expect(c.testFirst, isTrue);
      expect(c.plan, isFalse);
    });

    testWidgets('no panel while the backend is proving or after approval', (
      tester,
    ) async {
      for (final phase in ['proving', 'approved']) {
        final rig = AgentRig(
          Preview.idle,
          testFirst: state(phase),
          status: phase == 'proving' ? WorkspaceStatus.agentRunning : null,
          events: [userEv('t'), tokEv('x'), doneEv()],
        );
        await rig.pump(tester, step: 'agent');
        expect(find.byKey(const ValueKey('acceptance-panel')), findsNothing);
      }
    });
  });

  group('composer toggle', () {
    testWidgets('test first starts a fresh task as a test-first draft', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('test-first')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'add a shipping calculator',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-run')));
      await tester.pumpAndSettle();
      expect(rig.agent.starts.single.testFirst, isTrue);
    });

    testWidgets('test first and plan first are exclusive', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await tester.tap(find.byKey(const ValueKey('plan-first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-first')));
      await tester.pumpAndSettle();
      expect(find.text('● test first'), findsOneWidget);
      expect(find.text('○ plan first'), findsOneWidget);
    });
  });
}
