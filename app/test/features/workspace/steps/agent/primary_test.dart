import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/widgets/haro_button.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

/// Enabled bone-filled buttons anywhere in the page: step bar, step and composer.
List<HaroButton> primaries(WidgetTester tester) => [
  for (final b in tester.widgetList<HaroButton>(
    find.descendant(
      of: find.byType(WorkspacePage),
      matching: find.byType(HaroButton),
    ),
  ))
    if (b.variant == HaroButtonVariant.primary && b.onPressed != null) b,
];

void main() {
  setUpAll(loadBrandFonts);

  final transcript = prototypeTranscript();
  final states = <String, ({AgentRig Function() rig, int expected})>{
    'idle': (rig: () => AgentRig(Preview.idle), expected: 1),
    'idle with a diff': (
      rig: () => AgentRig(Preview.idleWithChanges, events: transcript),
      expected: 1,
    ),
    'plan ready': (
      rig: () => AgentRig(
        Preview.idle,
        planReady: true,
        events: [userEv('p'), tokEv('the plan'), doneEv(plan: true)],
      ),
      expected: 1,
    ),
    'agent running': (
      rig: () => AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: [userEv('go'), metaEv(), toolEv('Read', 'a')],
      ),
      expected: 0,
    ),
    'gate running': (
      rig: () => AgentRig(Preview.running, events: transcript),
      expected: 0,
    ),
    'red': (rig: () => AgentRig(Preview.red, events: transcript), expected: 1),
    'green': (
      rig: () => AgentRig(Preview.green, events: transcript),
      expected: 1,
    ),
    'merged': (
      rig: () => AgentRig(Preview.merged, events: transcript),
      expected: 1,
    ),
  };

  for (final size in const [Size(1400, 900), Size(900, 640)]) {
    for (final e in states.entries) {
      testWidgets('${e.key} at ${size.width.toInt()}x${size.height.toInt()}: '
          '${e.value.expected} primary on the agent step', (tester) async {
        await e.value.rig().pump(tester, size: size, step: 'agent');
        expect(tester.takeException(), isNull);
        final found = primaries(tester);
        expect(
          found.map((b) => b.label ?? '<child>'),
          hasLength(e.value.expected),
        );
      });
    }
  }

  testWidgets('plan ready: Approve plan is the primary, Run agent is not', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      planReady: true,
      events: [userEv('p'), tokEv('the plan'), doneEv(plan: true)],
    );
    await rig.pump(tester, step: 'agent');
    expect(primaries(tester).single.label, 'Approve plan');
    expect(
      tester
          .widget<HaroButton>(find.byKey(const ValueKey('composer-run')))
          .variant,
      HaroButtonVariant.secondary,
    );
    await tester.tap(find.byKey(const ValueKey('approve-plan')));
    await tester.pumpAndSettle();
    // Roles are on in the fixture config, so the composer sends no model or effort.
    expect(rig.agent.approveArgs, [(null, null, 'claude-code')]);
  });

  testWidgets('approving with roles off passes the composer picks', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      backend: backend(rolesOn: false),
      planReady: true,
      events: [userEv('p'), tokEv('the plan'), doneEv(plan: true)],
    );
    await rig.pump(tester, step: 'agent');
    await tester.tap(find.byKey(const ValueKey('role-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-model-haiku')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approve-plan')));
    await tester.pumpAndSettle();
    expect(rig.agent.approveArgs, [('haiku', null, 'claude-code')]);
  });

  testWidgets('red: the step renders Send failures as the primary', (
    tester,
  ) async {
    final rig = AgentRig(Preview.red, events: prototypeTranscript());
    await rig.pump(tester, step: 'agent');
    final b = primaries(tester).single;
    expect(b.label, startsWith('Send failures'));
    await tester.tap(find.byKey(const ValueKey('step-action')));
    await tester.pumpAndSettle();
    expect(rig.agent.sentFailures, 1);
    expect(
      tester
          .widget<HaroButton>(find.byKey(const ValueKey('composer-run')))
          .variant,
      HaroButtonVariant.secondary,
    );
  });

  testWidgets('a disabled Run agent is never bone-filled', (tester) async {
    final rig = AgentRig(Preview.green, events: prototypeTranscript());
    await rig.pump(tester, step: 'agent');
    final run = tester.widget<HaroButton>(
      find.byKey(const ValueKey('composer-run')),
    );
    expect(run.onPressed, isNull);
    expect(run.variant, HaroButtonVariant.secondary);
  });

  testWidgets('⌘↵ cannot start a second run while one is queued or running', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      status: WorkspaceStatus.agentRunning,
      events: [userEv('go'), metaEv()],
    );
    await rig.pump(tester, step: 'agent');
    await tester.enterText(field(), 'second');
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(rig.agent.starts, isEmpty);
  });
}
