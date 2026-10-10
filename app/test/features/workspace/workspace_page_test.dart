import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haro_app/features/archive_workspace/archive_workspace_overlay.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/state/workspace_flow.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/shell_icons.dart';
import 'package:haro_app/widgets/status_square.dart';

import 'harness.dart';

Finder inPage(Finder f) =>
    find.descendant(of: find.byType(WorkspacePage), matching: f);

Finder step(String name) => find.byKey(ValueKey('step-$name'));

/// The step you are on has the panel fill and full opacity; the others are dimmed.
bool isActive(WidgetTester tester, String name) {
  final box =
      tester.widget<AnimatedContainer>(step(name)).decoration as BoxDecoration;
  return box.color == HaroTokens.panel;
}

Border cellBorder(WidgetTester tester, String name) =>
    (tester.widget<AnimatedContainer>(step(name)).decoration as BoxDecoration)
            .border
        as Border;

HaroButton nextButton(WidgetTester tester) =>
    tester.widget<HaroButton>(find.byKey(const ValueKey('next-action')));

void main() {
  group('step bar status lines', () {
    final cases = <Preview, ({List<String> lines, String next, bool enabled})>{
      Preview.idle: (
        lines: [
          'ready for a task',
          'no changes yet',
          'runs when agent finishes',
          'blocked',
        ],
        next: 'Run agent →',
        enabled: true,
      ),
      Preview.running: (
        lines: [
          'done · 14m',
          '21 files · +367 −130',
          'running · 412 / 594',
          'waits for green',
        ],
        next: 'Gate running →',
        enabled: false,
      ),
      Preview.red: (
        lines: [
          'done · 14m',
          '21 files · +367 −130',
          'red · 3 failing',
          'blocked',
        ],
        next: 'Send failures to agent →',
        enabled: true,
      ),
      Preview.green: (
        lines: [
          'done · 14m',
          '21 files · +367 −130',
          'green · 594 passed',
          'ready to merge',
        ],
        next: 'Proceed to ship →',
        enabled: true,
      ),
      Preview.merged: (
        lines: [
          'done · 14m',
          '21 files · +367 −130',
          'green · 594 passed',
          'merged · #232',
        ],
        next: 'Continue on a new branch →',
        enabled: true,
      ),
    };
    for (final e in cases.entries) {
      testWidgets(e.key.name, (tester) async {
        await Rig(e.key).pump(tester);
        for (final line in e.value.lines) {
          expect(find.text(line), findsOneWidget, reason: line);
        }
        expect(find.text(e.value.next), findsOneWidget);
        expect(nextButton(tester).onPressed != null, e.value.enabled);
        expect(
          inPage(find.byType(HaroButton)).evaluate().where((el) {
            final b = el.widget as HaroButton;
            return b.variant == HaroButtonVariant.primary;
          }),
          hasLength(e.value.enabled ? 1 : 0),
          reason: 'exactly one primary action, none while it is disabled',
        );
      });
    }
  });

  group(
    'step status shows in the label colour and the top line, no squircle',
    () {
      final cases = <(Preview, String, Color, Color)>[
        // (preview, step, top line, label)
        (Preview.idle, 'agent', HaroTokens.ink, HaroTokens.ink),
        (Preview.idle, 'ship', HaroTokens.line12, HaroTokens.ink42),
        (Preview.red, 'code', HaroTokens.ink42, HaroTokens.ink66),
        (Preview.red, 'verify', HaroTokens.fail, HaroTokens.fail),
        (Preview.green, 'verify', HaroTokens.gate, HaroTokens.gate),
        (Preview.merged, 'ship', HaroTokens.merged, HaroTokens.merged),
      ];
      for (final (preview, name, top, label) in cases) {
        testWidgets('${preview.name} $name', (tester) async {
          await Rig(preview).pump(tester);
          expect(cellBorder(tester, name).top.color, top, reason: 'top line');
          expect(cellBorder(tester, name).top.width, 2);
          final text = find.descendant(
            of: step(name),
            matching: find.text(stepLabel(StepKey.values.byName(name))),
          );
          expect(
            tester.widget<Text>(text).style!.color,
            label,
            reason: 'label',
          );
          expect(
            find.descendant(
              of: step(name),
              matching: find.byType(StatusSquare),
            ),
            findsNothing,
          );
        });
      }
    },
  );

  group('active step follows the route', () {
    for (final name in ['agent', 'code', 'verify', 'ship']) {
      testWidgets(name, (tester) async {
        await Rig(Preview.green).pump(tester, step: name);
        for (final other in ['agent', 'code', 'verify', 'ship']) {
          expect(isActive(tester, other), other == name, reason: other);
        }
      });
    }
  });

  testWidgets('the bar drops its action when the open step owns it', (
    tester,
  ) async {
    await Rig(Preview.merged).pump(tester, step: 'ship');
    expect(find.byKey(const ValueKey('next-action')), findsNothing);
    await Rig(Preview.green).pump(tester, step: 'ship');
    expect(find.byKey(const ValueKey('next-action')), findsNothing);
    await Rig(Preview.merged).pump(tester, step: 'code');
    expect(nextButton(tester).variant, HaroButtonVariant.primary);
  });

  testWidgets('only the current step is clickable: Back and Proceed move you', (
    tester,
  ) async {
    final router = await Rig(Preview.merged).pump(tester, step: 'verify');
    // Earlier and later steps are dimmed and do nothing.
    await tester.tap(inPage(find.text('agent')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/verify');
    await tester.tap(inPage(find.text('code')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/verify');
    await tester.tap(inPage(find.text('ship')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/verify');
    // Back goes one step, then again.
    await tester.tap(find.byKey(const ValueKey('step-back')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/code');
    expect(isActive(tester, 'code'), isTrue);
    await tester.tap(find.byKey(const ValueKey('step-back')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/agent');
  });

  group('next action', () {
    Future<Rig> press(
      WidgetTester tester,
      Preview p, {
      String at = 'verify',
      HaroApiException? failWith,
    }) async {
      final rig = Rig(p, failWith: failWith);
      await rig.pump(tester, step: at);
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('idle: Run agent opens the agent step', (tester) async {
      final rig = Rig(Preview.idle);
      final router = await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.calls, isEmpty);
      expect(pathOf(router), '/w/$id/agent');
    });

    testWidgets(
      'idle with changes: one step at a time, the gate waits on review',
      (tester) async {
        final rig = Rig(Preview.idleWithChanges);
        final router = await rig.pump(tester, step: 'agent');
        expect(find.text('Proceed to code →'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('next-action')));
        await tester.pumpAndSettle();
        expect(pathOf(router), '/w/$id/code');
        expect(rig.calls, isEmpty);

        expect(find.text('Proceed to review →'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('next-action')));
        await tester.pumpAndSettle();
        expect(pathOf(router), '/w/$id/verify');
        expect(rig.calls, isEmpty, reason: 'proceeding never starts the gate');

        await tester.tap(find.byKey(const ValueKey('verify-next')));
        await tester.pumpAndSettle();
        expect(rig.calls, ['runGate']);
      },
    );

    testWidgets('red, back on the code step: Proceed to review is offered', (
      tester,
    ) async {
      final rig = Rig(Preview.red);
      final router = await rig.pump(tester, step: 'code');
      expect(find.text('Proceed to review →'), findsOneWidget);
      expect(find.textContaining('Send failures'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/verify');
      expect(rig.calls, isEmpty, reason: 'proceeding sends nothing');
    });

    testWidgets('red: sends failures then opens the agent step', (
      tester,
    ) async {
      final rig = Rig(Preview.red);
      final router = await rig.pump(tester);
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.calls, ['sendFailures']);
      expect(pathOf(router), '/w/$id/agent');
    });

    testWidgets('green: Review & ship goes to ship, no request', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester);
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.calls, isEmpty);
      expect(pathOf(router), '/w/$id/ship');
    });

    testWidgets('merged: continues on a new branch', (tester) async {
      final rig = Rig(Preview.merged);
      final router = await rig.pump(tester, step: 'verify');
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.calls, ['continueOnNewBranch']);
      expect(pathOf(router), '/w/$id/agent');
    });

    testWidgets('running: disabled, does nothing', (tester) async {
      final rig = Rig(Preview.running);
      final router = await rig.pump(tester);
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.calls, isEmpty);
      expect(pathOf(router), '/w/$id/verify');
    });

    testWidgets('a failed request shows an inline error and stays put', (
      tester,
    ) async {
      final rig = await press(
        tester,
        Preview.red,
        failWith: const HaroApiException(409, 'an agent is already running'),
      );
      expect(rig.calls, ['sendFailures']);
      expect(find.text('an agent is already running'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('action-error-dismiss')));
      await tester.pumpAndSettle();
      expect(find.text('an agent is already running'), findsNothing);
    });
  });

  group('rail', () {
    testWidgets('green: verdict, summary, time and look-at items', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      expect(find.byKey(const ValueKey('rail-verdict')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('rail-verdict'))).data,
        'GREEN',
      );
      expect(find.text('594 / 594 passed · mergeable'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('rail-when'))).data,
        contains(' ago'),
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('rail-eyes-count'))).data,
        '2',
      );
      expect(find.text('○ rates.ts'), findsOneWidget);
      expect(find.text('○ zones.ts'), findsOneWidget);
    });

    testWidgets('red: failures listed with a cross', (tester) async {
      await Rig(Preview.red).pump(tester);
      expect(find.text('3 of 16 failing'), findsOneWidget);
      expect(find.text('✕ shipping.test.ts'), findsNWidgets(3));
    });

    testWidgets('idle: not run, nothing to look at', (tester) async {
      await Rig(Preview.idle).pump(tester, step: 'agent');
      expect(find.text('NOT RUN'), findsOneWidget);
      expect(find.text('Runs when the agent finishes'), findsOneWidget);
      expect(find.text('never run'), findsOneWidget);
      expect(find.text('Nothing yet'), findsOneWidget);
    });

    testWidgets('running: progress line, no time', (tester) async {
      await Rig(Preview.running).pump(tester);
      expect(find.text('RUNNING'), findsWidgets);
      expect(find.text('412 / 594 · no failures yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-when')), findsNothing);
    });

    testWidgets('running draws the dithered marker, a settled gate does not', (
      tester,
    ) async {
      await Rig(Preview.running).pump(tester);
      expect(find.byKey(const ValueKey('rail-gate-running')), findsOneWidget);
      await Rig(Preview.green).pump(tester);
      expect(find.byKey(const ValueKey('rail-gate-running')), findsNothing);
    });

    testWidgets('merged: lilac merged verdict', (tester) async {
      await Rig(Preview.merged).pump(tester, step: 'ship');
      expect(find.text('MERGED'), findsOneWidget);
      expect(find.text('#232 · merged on green'), findsOneWidget);
    });

    for (final step in ['agent', 'code', 'ship']) {
      testWidgets('is visible on the $step step', (tester) async {
        await Rig(Preview.green).pump(tester, step: step);
        expect(find.byKey(const ValueKey('rail-gate')), findsOneWidget);
      });
    }

    testWidgets('gate and needs-your-eyes open verify', (tester) async {
      final router = await Rig(Preview.green).pump(tester, step: 'ship');
      await tester.tap(find.byKey(const ValueKey('rail-gate')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/verify');
      await tester.tap(find.text('ship'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rail-eyes')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/verify');
    });

    testWidgets('app section: stopped, Run starts it, Open is disabled', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('rail-app-address')))
            .data,
        ':4500',
      );
      expect(
        tester
            .widget<ShellIconButton>(
              find.byKey(const ValueKey('rail-app-open')),
            )
            .onTap,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('rail-app-toggle')));
      await tester.pumpAndSettle();
      expect(rig.calls, ['startDevServer']);
    });

    testWidgets('app section: a missing script disables Run and says why', (
      tester,
    ) async {
      final rig = Rig(
        Preview.green,
        runProblem: 'no `dev` script in package.json',
      );
      await rig.pump(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('rail-app-problem')))
            .data,
        'no `dev` script in package.json',
      );
      expect(
        tester
            .widget<ShellIconButton>(
              find.byKey(const ValueKey('rail-app-toggle')),
            )
            .onTap,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('rail-app-toggle')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(rig.calls, isEmpty);
    });

    testWidgets('app section: nothing missing, no line and Run is live', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      expect(find.byKey(const ValueKey('rail-app-problem')), findsNothing);
      expect(
        tester
            .widget<ShellIconButton>(
              find.byKey(const ValueKey('rail-app-toggle')),
            )
            .onTap,
        isNotNull,
      );
    });

    testWidgets('app section: a configured url replaces the reserved port', (
      tester,
    ) async {
      final rig = Rig(Preview.green, runUrl: 'http://localhost:4200');
      await rig.pump(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('rail-app-address')))
            .data,
        ':4200',
        reason: 'not the reserved :4500: the app answers on :4200',
      );
    });

    testWidgets('app section: Open goes to the configured url once running', (
      tester,
    ) async {
      final rig = Rig(
        Preview.green,
        runUrl: 'http://localhost:4200',
        detail: detailFor(
          Preview.green,
          runs: const {'app': DevRun(running: true)},
        ),
      );
      await rig.pump(tester);
      await tester.tap(find.byKey(const ValueKey('rail-app-open')));
      await tester.pumpAndSettle();
      expect(rig.opened, [Uri.parse('http://localhost:4200')]);
    });

    testWidgets('app section: the icon buttons are the bone squircles', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      for (final key in ['rail-app-toggle', 'rail-app-open', 'rail-app-log']) {
        expect(
          tester.widget<ShellIconButton>(find.byKey(ValueKey(key))).filled,
          isTrue,
          reason: key,
        );
      }
    });

    testWidgets('app section: the state is a badge, hollow while stopped', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      final badge = find.byKey(const ValueKey('rail-app-badge'));
      expect(
        find.descendant(of: badge, matching: find.text('STOPPED')),
        findsOneWidget,
      );
      final deco =
          tester.widget<AnimatedContainer>(badge).decoration as BoxDecoration;
      expect(deco.color, HaroTokens.transparent);
    });

    testWidgets('app section: bone-filled badge while it runs', (tester) async {
      final rig = Rig(
        Preview.green,
        detail: detailFor(
          Preview.green,
          runs: const {'app': DevRun(running: true)},
        ),
      );
      await rig.pump(tester);
      final badge = find.byKey(const ValueKey('rail-app-badge'));
      expect(
        find.descendant(of: badge, matching: find.text('RUNNING')),
        findsOneWidget,
      );
      final deco =
          tester.widget<AnimatedContainer>(badge).decoration as BoxDecoration;
      expect(deco.color, HaroTokens.ink);
    });

    testWidgets('app section: three icon buttons, labelled by their tooltips', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      String tip(String key) =>
          tester.widget<ShellIconButton>(find.byKey(ValueKey(key))).tooltip;
      expect(tip('rail-app-toggle'), 'Run');
      expect(tip('rail-app-open'), 'Open in browser');
      expect(tip('rail-app-log'), 'Dev log');
      expect(find.text('Run'), findsNothing, reason: 'icons, not words');
      expect(find.text('Open ↗'), findsNothing);
    });

    testWidgets('app section: Dev log is off until there is output', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      expect(
        tester
            .widget<ShellIconButton>(find.byKey(const ValueKey('rail-app-log')))
            .onTap,
        isNull,
      );
    });

    testWidgets('app section: Dev log is on once the app has left output', (
      tester,
    ) async {
      final buffer = DevLogBuffer()..add('listening on :4200');
      final rig = Rig(
        Preview.green,
        detail: detailFor(Preview.green, devLog: buffer.snapshot()),
      );
      await rig.pump(tester);
      expect(
        tester
            .widget<ShellIconButton>(find.byKey(const ValueKey('rail-app-log')))
            .onTap,
        isNotNull,
        reason: 'not running, but there is output to read',
      );
    });

    testWidgets('app section: the Run button is lit while the app runs', (
      tester,
    ) async {
      final rig = Rig(
        Preview.green,
        detail: detailFor(
          Preview.green,
          runs: const {'app': DevRun(running: true)},
        ),
      );
      await rig.pump(tester);
      ShellIconButton toggle() => tester.widget<ShellIconButton>(
        find.byKey(const ValueKey('rail-app-toggle')),
      );
      expect(toggle().on, isTrue);
      expect(toggle().icon, ShellIcon.stop);
    });

    testWidgets('app section: Dev log opens the bottom panel on that tab', (
      tester,
    ) async {
      final rig = Rig(
        Preview.green,
        detail: detailFor(
          Preview.green,
          runs: const {'app': DevRun(running: true)},
        ),
      );
      await rig.pump(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkspacePage)),
      );
      expect(
        container.read(bottomPanelProvider(id)).showing(BottomTab.devLog),
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('rail-app-log')));
      await tester.pumpAndSettle();
      expect(
        container.read(bottomPanelProvider(id)).showing(BottomTab.devLog),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('rail-app-log')));
      await tester.pumpAndSettle();
      expect(
        container.read(bottomPanelProvider(id)).open,
        isFalse,
        reason: 'a second press hides it again',
      );
    });

    testWidgets('app section: running, Stop stops it, Open launches the URL', (
      tester,
    ) async {
      final rig = Rig(
        Preview.green,
        detail: detailFor(
          Preview.green,
          runs: const {
            'app': DevRun(running: true, url: 'http://localhost:4500'),
          },
        ),
      );
      await rig.pump(tester);
      expect(
        tester
            .widget<ShellIconButton>(
              find.byKey(const ValueKey('rail-app-toggle')),
            )
            .tooltip,
        'Stop',
      );
      await tester.tap(find.byKey(const ValueKey('rail-app-open')));
      await tester.pumpAndSettle();
      expect(rig.opened, [Uri.parse('http://localhost:4500')]);
      await tester.tap(find.byKey(const ValueKey('rail-app-toggle')));
      await tester.pumpAndSettle();
      expect(rig.calls, ['stopDevServer']);
    });
  });

  group('header', () {
    testWidgets('name, project, branch, base and behind', (tester) async {
      await Rig(Preview.green).pump(tester);
      expect(inPage(find.text('electron optimization')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('workspace-subline')))
            .data,
        'haro · feat/electron-optimization → main · 15 behind',
      );
    });

    testWidgets('no behind count when in sync', (tester) async {
      await Rig(Preview.green, behind: 0).pump(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('workspace-subline')))
            .data,
        'haro · feat/electron-optimization → main',
      );
    });

    testWidgets('rename edits inline and saves on enter', (tester) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      await tester.tap(find.byKey(const ValueKey('rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('rename-field')),
          matching: find.byType(EditableText),
        ),
        'faster electron',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(rig.calls, ['rename:faster electron']);
      expect(find.byKey(const ValueKey('rename-field')), findsNothing);
    });

    testWidgets('rename can be cancelled without a request', (tester) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      await tester.tap(find.byKey(const ValueKey('rename')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rename-cancel')));
      await tester.pumpAndSettle();
      expect(rig.calls, isEmpty);
      expect(find.byKey(const ValueKey('workspace-name')), findsOneWidget);
    });

    testWidgets('Delete... opens the confirm, it never deletes on its own', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      expect(find.text('Delete…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('archive')));
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveWorkspaceOverlay), findsOneWidget);
      expect(rig.calls, isEmpty);
    });

    testWidgets('the worktree menu hook is live', (tester) async {
      await Rig(Preview.green).pump(tester);
      expect(
        tester
            .widget<HaroButton>(find.byKey(const ValueKey('open-worktree')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('states', () {
    testWidgets('loading', (tester) async {
      final rig = Rig(
        Preview.green,
        detail: const WorkspaceDetailStub().loading,
      );
      await rig.pump(tester);
      expect(find.text('LOADING WORKSPACE'), findsOneWidget);
    });

    testWidgets('error shows the message and a retry', (tester) async {
      final rig = Rig(
        Preview.green,
        detail: const WorkspaceDetailStub().failed('workspace not found'),
      );
      await rig.pump(tester);
      expect(find.text('workspace not found'), findsOneWidget);
      expect(find.byKey(const ValueKey('load-retry')), findsOneWidget);
    });
  });
}
