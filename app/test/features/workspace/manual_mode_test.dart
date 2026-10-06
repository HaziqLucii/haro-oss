import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:haro_app/overlays/shortcuts_overlay.dart' show shortcutEntries;
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/shortcuts/platform_keys.dart';
import 'package:flutter_test/flutter_test.dart' as flutter show testWidgets;
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/mode_switch.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/overlays/overlay.dart' show haroOverlayDepth;
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

import 'harness.dart';

Finder step(String name) => find.byKey(ValueKey('step-$name'));

Future<void> settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(const Duration(seconds: 1));
}

Finder seg(String label) => find.byKey(ValueKey('mode-${label.toLowerCase()}'));

bool selected(WidgetTester tester, String label) {
  final box = tester.widget<AnimatedContainer>(
    find.descendant(of: seg(label), matching: find.byType(AnimatedContainer)),
  );
  return (box.decoration as BoxDecoration).color == HaroTokens.ink;
}

Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.sendKeyEvent(key, platform: 'macos');
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => haroOverlayDepth.value = 0);

  void testWidgets(String name, Future<void> Function(WidgetTester) body) =>
      flutter.testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  group('manual workspace frame', () {
    testWidgets('three steps, no agent step, numbered from 01', (tester) async {
      final rig = Rig(Preview.idleWithChanges, mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'code');
      expect(step('agent'), findsNothing);
      expect(step('code'), findsOneWidget);
      expect(step('verify'), findsOneWidget);
      expect(step('ship'), findsOneWidget);
      expect(
        find.descendant(of: step('code'), matching: find.text('01')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: step('ship'), matching: find.text('03')),
        findsOneWidget,
      );
    });

    testWidgets('an agent workspace still shows four steps', (tester) async {
      final rig = Rig(Preview.idleWithChanges);
      await rig.pump(tester, step: 'code');
      expect(step('agent'), findsOneWidget);
      expect(
        find.descendant(of: step('ship'), matching: find.text('04')),
        findsOneWidget,
      );
    });

    testWidgets('the agent route lands on code and shows no composer', (
      tester,
    ) async {
      final rig = Rig(Preview.idle, mode: WorkspaceMode.manual);
      final router = await rig.pump(tester, step: 'agent');
      expect(pathOf(router), '/w/$id/code');
      expect(find.byType(WorkspacePage), findsOneWidget);
      expect(find.byKey(const ValueKey('composer')), findsNothing);
    });

    testWidgets('an empty code step has no pointer to the agent', (
      tester,
    ) async {
      final manual = Rig(Preview.idle, mode: WorkspaceMode.manual);
      await manual.pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('code-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('code-empty-agent')), findsNothing);
    });

    testWidgets('red: the action is Back to code and sends nothing', (
      tester,
    ) async {
      final rig = Rig(Preview.red, mode: WorkspaceMode.manual);
      final router = await rig.pump(tester, step: 'verify');
      final button = tester.widget<HaroButton>(
        find.byKey(const ValueKey('next-action')),
      );
      expect(button.label, 'Back to code →');

      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/code');
      expect(rig.calls, isNot(contains('sendFailures')));
    });

    testWidgets('verify offers no way to ask the agent', (tester) async {
      final agent = Rig(Preview.green);
      await agent.pump(tester, step: 'verify');
      expect(find.byKey(const ValueKey('look-send')), findsOneWidget);
      expect(find.textContaining('Ask agent'), findsWidgets);

      final manual = Rig(Preview.green, mode: WorkspaceMode.manual);
      await manual.pump(tester, step: 'verify');
      expect(find.byKey(const ValueKey('look-send')), findsNothing);
      expect(find.textContaining('Ask agent'), findsNothing);
      expect(find.textContaining('to agent'), findsNothing);
      expect(find.byKey(const ValueKey('look-backlog')), findsOneWidget);
    });

    testWidgets('Command+1..3 open code, verify, ship; Command+4 nothing', (
      tester,
    ) async {
      final rig = Rig(Preview.green, mode: WorkspaceMode.manual);
      final router = await rig.pump(tester, step: 'code');

      await chord(tester, LogicalKeyboardKey.digit2);
      expect(pathOf(router), '/w/$id/verify');
      await chord(tester, LogicalKeyboardKey.digit3);
      expect(pathOf(router), '/w/$id/ship');
      await chord(tester, LogicalKeyboardKey.digit1);
      expect(pathOf(router), '/w/$id/code');
      await chord(tester, LogicalKeyboardKey.digit4);
      expect(pathOf(router), '/w/$id/code');
    });

    testWidgets('Command+1 is still the agent step in agent mode', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester, step: 'verify');
      await chord(tester, LogicalKeyboardKey.digit1);
      expect(pathOf(router), '/w/$id/agent');
    });
  });

  group('rail', () {
    final events = [
      AgentEvent(
        runId: 'r',
        workspaceId: id,
        ts: 1,
        type: AgentEventType.token,
        payload: const {'model': 'claude-sonnet-5', 'system': true},
      ),
    ];

    testWidgets('the last agent run shows in agent mode only', (tester) async {
      final agent = Rig(
        Preview.green,
        detail: detailFor(Preview.green, events: events),
      );
      await agent.pump(tester, step: 'verify');
      expect(find.byKey(const ValueKey('rail-run')), findsOneWidget);

      final manual = Rig(
        Preview.green,
        mode: WorkspaceMode.manual,
        detail: detailFor(
          Preview.green,
          events: events,
          mode: WorkspaceMode.manual,
        ),
      );
      await manual.pump(tester, step: 'verify');
      expect(find.byKey(const ValueKey('rail-run')), findsNothing);
      expect(find.byKey(const ValueKey('rail-gate')), findsOneWidget);
    });
  });

  group('mode toggle', () {
    testWidgets(
      'shows in a workspace with the current mode selected, no caption',
      (tester) async {
        final rig = Rig(Preview.green);
        await rig.pump(tester, step: 'verify');
        expect(find.text('WHO WRITES THE CODE'), findsNothing);
        expect(selected(tester, 'AGENT'), isTrue);
        expect(selected(tester, 'MANUAL'), isFalse);

        final manual = Rig(Preview.green, mode: WorkspaceMode.manual);
        await manual.pump(tester, step: 'verify');
        expect(selected(tester, 'MANUAL'), isTrue);
      },
    );

    testWidgets('is absent on the triage screen', (tester) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester, step: 'verify');
      router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('WHO WRITES THE CODE'), findsNothing);
    });

    testWidgets('agent to manual switches at once and toasts', (tester) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester, step: 'verify');
      await tester.tap(seg('MANUAL'));
      await tester.pumpAndSettle();

      expect(rig.calls, ['setMode:manual']);
      expect(find.byKey(const ValueKey('mode-confirm-title')), findsNothing);
      expect(find.text(manualOnToast), findsOneWidget);
      await settleToast(tester);
      expect(find.text(manualOnToast), findsNothing);
    });

    testWidgets('manual to agent asks first: Keep writing changes nothing', (
      tester,
    ) async {
      final rig = Rig(Preview.green, mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'verify');
      await tester.tap(seg('AGENT'));
      await tester.pumpAndSettle();

      expect(find.text(switchToAgentTitle), findsOneWidget);
      for (final (_, text) in switchToAgentRows) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text(switchToAgentFooter), findsOneWidget);
      expect(find.text('Keep writing'), findsOneWidget);
      expect(find.text('Switch to Agent'), findsOneWidget);
      expect(rig.calls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('mode-confirm-keep')));
      await tester.pumpAndSettle();
      expect(find.text(switchToAgentTitle), findsNothing);
      expect(rig.calls, isEmpty);
    });

    testWidgets('confirming switches to agent', (tester) async {
      final rig = Rig(Preview.green, mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'verify');
      await tester.tap(seg('AGENT'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mode-confirm-switch')));
      await tester.pumpAndSettle();

      expect(rig.calls, ['setMode:agent']);
      expect(find.text(agentOnToast), findsOneWidget);
      await settleToast(tester);
    });

    testWidgets('a backend refusal is shown as the toast', (tester) async {
      final rig = Rig(
        Preview.green,
        failWith: HaroApiException(409, 'stop the agent first'),
      );
      await rig.pump(tester, step: 'verify');
      await tester.tap(seg('MANUAL'));
      await tester.pumpAndSettle();

      expect(find.text('stop the agent first'), findsOneWidget);
      expect(find.text(manualOnToast), findsNothing);
      await settleToast(tester);
    });

    testWidgets('the palette offers the opposite switch', (tester) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester, step: 'verify');
      await chord(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byType(EditableText).last, 'switch');
      await tester.pumpAndSettle();
      expect(
        find.text('Switch to Manual mode', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('Switch to Agent mode', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('Switch to Manual mode', findRichText: true));
      await tester.pumpAndSettle();
      expect(rig.calls, ['setMode:manual']);
      await settleToast(tester);
    });

    testWidgets('the palette of a manual workspace offers Agent mode', (
      tester,
    ) async {
      final rig = Rig(Preview.green, mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'verify');
      await chord(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byType(EditableText).last, 'switch');
      await tester.pumpAndSettle();
      expect(
        find.text('Switch to Agent mode', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('Switch to Manual mode', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('Switch to Agent mode', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text(switchToAgentTitle), findsOneWidget);
      expect(rig.calls, isEmpty);
    });
  });

  group('shortcuts overlay', () {
    test('agent entries are unchanged', () {
      final e = shortcutEntries(modifier: PrimaryModifier.meta);
      expect(e, contains(('Go to step 1–4', '⌘1–4')));
      expect(e.map((x) => x.$1), contains('Focus the prompt'));
    });

    test('manual lists code, verify and ship on 1 to 3 and no prompt', () {
      final e = shortcutEntries(modifier: PrimaryModifier.meta, manual: true);
      expect(e, contains(('Go to code / verify / ship', '⌘1–3')));
      expect(e.map((x) => x.$1), isNot(contains('Focus the prompt')));
      expect(e.map((x) => x.$1), isNot(contains('Go to step 1–4')));
      expect(e.map((x) => x.$1), isNot(contains('Run agent / commit')));
    });

    testWidgets('the overlay of a manual workspace says so', (tester) async {
      final rig = Rig(Preview.green, mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'verify');
      final c = ProviderScope.containerOf(
        tester.element(find.byType(WorkspacePage)),
      );
      c.read(appCommandsProvider).openShortcuts();
      await tester.pumpAndSettle();
      expect(find.text('Go to code / verify / ship'), findsOneWidget);
      expect(find.text('Go to step 1–4'), findsNothing);
    });

    testWidgets('the overlay of an agent workspace keeps four steps', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester, step: 'verify');
      final c = ProviderScope.containerOf(
        tester.element(find.byType(WorkspacePage)),
      );
      c.read(appCommandsProvider).openShortcuts();
      await tester.pumpAndSettle();
      expect(find.text('Go to step 1–4'), findsOneWidget);
    });
  });

  group('sidebar and triage', () {
    testWidgets('a manual workspace is marked in the sidebar', (tester) async {
      final rig = Rig(Preview.green, mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'verify');
      expect(find.text('manual'), findsWidgets);
    });

    testWidgets('triage rows read project, mode, branch', (tester) async {
      final manual = Rig(Preview.green, mode: WorkspaceMode.manual);
      final router = await manual.pump(tester, step: 'verify');
      router.go('/');
      await tester.pumpAndSettle();
      expect(
        find.text('haro · manual · feat/electron-optimization'),
        findsOneWidget,
      );

      final agent = Rig(Preview.green);
      final r2 = await agent.pump(tester, step: 'verify');
      r2.go('/');
      await tester.pumpAndSettle();
      expect(
        find.text('haro · agent · feat/electron-optimization'),
        findsOneWidget,
      );
    });

    testWidgets('the triage screen carries no Japanese characters', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester, step: 'verify');
      router.go('/');
      await tester.pumpAndSettle();
      final japanese = RegExp(r'[぀-ヿ一-鿿]');
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        expect(
          japanese.hasMatch(t.data ?? t.textSpan?.toPlainText() ?? ''),
          isFalse,
        );
      }
    });
  });
}
