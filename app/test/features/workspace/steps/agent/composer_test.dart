import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_step.dart';
import 'package:haro_app/features/workspace/workspace_ui.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/widgets/haro_button.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

Finder run() => find.byKey(const ValueKey('composer-run'));
Finder stop() => find.byKey(const ValueKey('composer-stop'));

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(field(), text);
  await tester.pumpAndSettle();
}

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey mod,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(mod);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(mod);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadBrandFonts);

  group('submit', () {
    testWidgets('Run agent starts a build with the role, not a model', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      // Idle: the step bar steps aside, so this is the primary; with nothing typed it
      // just puts the caret in the field.
      expect(
        tester.widget<HaroButton>(run()).variant,
        HaroButtonVariant.primary,
      );
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field()).focusNode!.hasFocus, isTrue);
      expect(rig.agent.starts, isEmpty);
      await type(tester, 'add a shipping calculator');
      await tester.tap(run());
      await tester.pumpAndSettle();

      expect(rig.agent.starts, hasLength(1));
      final c = rig.agent.starts.single;
      expect(c.task, 'add a shipping calculator');
      expect(c.plan, isFalse);
      expect(c.role, 'build');
      expect(c.model, isNull);
      expect(c.effort, isNull);
      expect(c.adapter, 'claude-code');
      expect(fieldText(tester), '');
    });

    testWidgets('plan first runs the plan role', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      expect(find.text('○ plan first'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('plan-first')));
      await tester.pumpAndSettle();
      expect(find.text('● plan first'), findsOneWidget);
      expect(find.textContaining('plan · opus · high'), findsOneWidget);
      await type(tester, 'design it');
      await tester.tap(run());
      await tester.pumpAndSettle();
      final c = rig.agent.starts.single;
      expect((c.plan, c.role, c.model), (true, 'plan', null));
    });

    testWidgets('roles off: the picked model and effort are sent', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle, backend: backend(rolesOn: false));
      await rig.pump(tester, step: 'agent');
      expect(find.textContaining('opus · high ▾'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('role-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('picker-model-haiku')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('picker-effort-low')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(700, 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('haiku · low ▾'), findsOneWidget);
      await type(tester, 'quick one');
      await tester.tap(run());
      await tester.pumpAndSettle();
      final c = rig.agent.starts.single;
      expect((c.model, c.effort, c.role), ('haiku', 'low', 'build'));
    });

    testWidgets('⌘↵ and Ctrl+↵ submit, plain Enter adds a line', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await type(tester, 'first');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(rig.agent.starts, isEmpty);

      await tester.enterText(field(), 'one');
      await tester.pumpAndSettle();
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.enter,
      );
      expect(rig.agent.starts.map((s) => s.task), ['one']);

      await type(tester, 'two');
      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.enter,
      );
      expect(rig.agent.starts.map((s) => s.task), ['one', 'two']);
    });

    testWidgets('an empty composer does not submit', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await tester.tap(field());
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.enter,
      );
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(rig.agent.starts, isEmpty);
    });

    testWidgets('a failed start shows inline and keeps the text', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      rig.agent.startFails = const HaroApiException(
        409,
        'this session already has an agent running',
      );
      await rig.pump(tester, step: 'agent');
      await type(tester, 'again');
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(
        find.text('this session already has an agent running'),
        findsOneWidget,
      );
      expect(fieldText(tester), 'again');
      expect(run(), findsOneWidget);
    });

    testWidgets('the gate running blocks a new run', (tester) async {
      final rig = AgentRig(Preview.idle, status: WorkspaceStatus.testsRunning);
      await rig.pump(tester, step: 'agent');
      await type(tester, 'wait');
      await tester.tap(run());
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.enter,
      );
      expect(rig.agent.starts, isEmpty);
    });
  });

  group('while the agent runs', () {
    testWidgets('the button is Stop and stops the run', (tester) async {
      final rig = AgentRig(
        Preview.idle,
        status: WorkspaceStatus.agentRunning,
        events: [userEv('go'), metaEv(), toolEv('Read', 'a')],
      );
      await rig.pump(tester, step: 'agent');
      expect(run(), findsNothing);
      expect(stop(), findsOneWidget);
      await type(tester, 'follow up');
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.enter,
      );
      expect(rig.agent.starts, isEmpty);
      await tester.tap(stop());
      await tester.pumpAndSettle();
      expect(rig.agent.stops, hasLength(1));
    });
  });

  group('autocomplete', () {
    testWidgets('@ completes worktree files with Tab', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await type(tester, 'look at @rat');
      final menu = find.byKey(const ValueKey('completion-menu'));
      expect(menu, findsOneWidget);
      expect(
        find.descendant(of: menu, matching: find.text('src/lib/rates.ts')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: menu, matching: find.text('README.md')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'look at @src/lib/rates.ts ');
      expect(menu, findsNothing);
      expect(rig.agent.starts, isEmpty);
    });

    testWidgets('arrow keys move, Enter picks, and it does not submit', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await type(tester, '@');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fieldText(tester), '@src/lib/rates.ts ');
      expect(rig.agent.starts, isEmpty);
    });

    testWidgets('/ lists commands at the start, Esc dismisses', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await type(tester, '/re');
      expect(find.text('/review'), findsOneWidget);
      expect(find.text('Review a pull request'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('completion-menu')), findsNothing);
      expect(fieldText(tester), '/re');
      await type(tester, '/rev');
      expect(find.byKey(const ValueKey('completion-menu')), findsOneWidget);
    });

    testWidgets('clicking an item completes it', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await type(tester, '/mod');
      await tester.tap(find.text('/model'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), '/model ');
    });
  });

  group('role picker', () {
    testWidgets(
      'offers plan and build for the next run, links to Roles settings',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        SettingsTab? opened;
        containerOf(tester)
            .read(appCommandsProvider.notifier)
            .register((c) => c.copyWith(openSettings: (t) => opened = t));

        expect(find.textContaining('build · sonnet · high ▾'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('role-picker')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('role-picker-panel')), findsOneWidget);
        expect(find.byKey(const ValueKey('picker-plan')), findsOneWidget);
        expect(find.byKey(const ValueKey('picker-build')), findsOneWidget);
        expect(find.text('opus · high'), findsWidgets);
        expect(find.byKey(const ValueKey('picker-review')), findsNothing);
        expect(find.byKey(const ValueKey('picker-scout')), findsNothing);
        expect(
          find.text('haiku'),
          findsNothing,
          reason: 'scout is Settings only',
        );

        await tester.tap(find.byKey(const ValueKey('picker-plan')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('role-picker-panel')), findsNothing);
        expect(find.text('● plan first'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('role-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('role-picker-settings')));
        await tester.pumpAndSettle();
        expect(opened, SettingsTab.roles);
        expect(find.byKey(const ValueKey('role-picker-panel')), findsNothing);
      },
    );
  });

  group('attachments', () {
    testWidgets('a large paste becomes a .context file mention', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await type(tester, 'fix this: ');
      final big = List.filled(30, 'stack frame').join('\n');
      await tester.enterText(field(), 'fix this: $big');
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'fix this: ');
      expect(
        find.byKey(const ValueKey('attachment-.context/pasted-ab12.txt')),
        findsOneWidget,
      );
      expect(find.textContaining('30 lines'), findsOneWidget);
      final post = rig.api.where('POST', '/workspaces/$id/context');
      expect(post, hasLength(1));
      expect(post.single.body!['content'], big);

      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(
        rig.agent.starts.single.task,
        'fix this:\n\n@.context/pasted-ab12.txt',
      );
      expect(find.textContaining('pasted-ab12.txt'), findsNothing);
    });

    testWidgets('an attachment alone is a valid task and can be removed', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await tester.enterText(field(), List.filled(25, 'x').join('\n'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('×'));
      await tester.pumpAndSettle();
      expect(find.textContaining('pasted-ab12.txt'), findsNothing);
    });

    testWidgets('+ attach takes the clipboard text', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'copied log line'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('attach')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('attachment-.context/pasted-ab12.txt')),
        findsOneWidget,
      );
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(rig.agent.starts.single.task, '@.context/pasted-ab12.txt');
    });
  });

  group('field state', () {
    testWidgets('composerFocusRequest focuses the field', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      final c = containerOf(tester);
      expect(tester.widget<TextField>(field()).focusNode!.hasFocus, isFalse);
      c.read(workspaceUiProvider.notifier).requestComposerFocus();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field()).focusNode!.hasFocus, isTrue);
    });

    testWidgets('the draft survives a trip to another step', (tester) async {
      final rig = AgentRig(Preview.idle);
      final router = await rig.pump(tester, step: 'agent');
      await type(tester, 'half written');
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      expect(field(), findsNothing);
      router.go('/w/$id/agent');
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'half written');
    });

    testWidgets('context usage shows when known and is omitted otherwise', (
      tester,
    ) async {
      final known = AgentRig(Preview.idle, events: prototypeTranscript());
      await known.pump(tester, step: 'agent');
      expect(find.text('21% context'), findsOneWidget);
      expect(find.text('/ commands · @ files'), findsOneWidget);

      final unknown = AgentRig(Preview.idle);
      await unknown.pump(tester, step: 'agent');
      expect(find.byKey(const ValueKey('composer-context')), findsNothing);
    });

    testWidgets('narrow columns drop the hint before anything else', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle, events: prototypeTranscript());
      await rig.pump(tester, size: const Size(900, 640), step: 'agent');
      expect(find.text('/ commands · @ files'), findsNothing);
      expect(find.byKey(const ValueKey('composer-run')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(AgentStep), findsOneWidget);
    });
  });
}
