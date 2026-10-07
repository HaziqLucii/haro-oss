import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/archive_workspace/archive_workspace_overlay.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/status_square.dart';

import 'harness.dart';

Finder inPage(Finder f) =>
    find.descendant(of: find.byType(WorkspacePage), matching: f);

Finder step(String name) => find.byKey(ValueKey('step-$name'));

bool isActive(WidgetTester tester, String name) {
  final box =
      tester.widget<AnimatedContainer>(step(name)).decoration as BoxDecoration;
  return (box.border as Border).top.color == HaroTokens.ink;
}

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
        next: 'Review & ship →',
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

  group('step bar dots are filled squircles in the status colour', () {
    Future<StatusSquare> dot(
      WidgetTester tester,
      Preview p,
      String name,
    ) async {
      await Rig(p).pump(tester);
      return tester.widget<StatusSquare>(
        find.descendant(of: step(name), matching: find.byType(StatusSquare)),
      );
    }

    final cases = <(Preview, String, Color)>[
      (Preview.idle, 'agent', HaroTokens.ink),
      (Preview.idle, 'ship', HaroTokens.line12),
      (Preview.red, 'code', HaroTokens.ink42),
      (Preview.red, 'verify', HaroTokens.fail),
      (Preview.green, 'verify', HaroTokens.gate),
      (Preview.merged, 'ship', HaroTokens.merged),
    ];
    for (final (preview, name, color) in cases) {
      testWidgets('${preview.name} $name', (tester) async {
        final sq = await dot(tester, preview, name);
        expect(sq.size, HaroTokens.markStepBar);
        expect(sq.color, color);
        expect(sq.filled, isTrue);
        final deco =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: find.byWidget(sq),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as ShapeDecoration;
        expect(deco.shape, isA<RoundedSuperellipseBorder>());
        expect(deco.color, color);
      });
    }
  });

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

  testWidgets('clicking a step navigates to it', (tester) async {
    final router = await Rig(Preview.green).pump(tester, step: 'verify');
    await tester.tap(inPage(find.text('code')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/code');
    expect(isActive(tester, 'code'), isTrue);
    await tester.tap(inPage(find.text('ship')));
    await tester.pumpAndSettle();
    expect(pathOf(router), '/w/$id/ship');
    expect(isActive(tester, 'ship'), isTrue);
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

    testWidgets('idle with changes: Run gate runs it on verify', (
      tester,
    ) async {
      final rig = Rig(Preview.idleWithChanges);
      final router = await rig.pump(tester, step: 'agent');
      expect(find.text('Run gate →'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(rig.calls, ['runGate']);
      expect(pathOf(router), '/w/$id/verify');
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
            .widget<Text>(find.byKey(const ValueKey('rail-app-status')))
            .textSpan!
            .toPlainText(),
        ':4500 · stopped',
      );
      expect(
        tester
            .widget<HaroButton>(find.byKey(const ValueKey('rail-app-open')))
            .onPressed,
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
            .widget<HaroButton>(find.byKey(const ValueKey('rail-app-toggle')))
            .onPressed,
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
            .widget<HaroButton>(find.byKey(const ValueKey('rail-app-toggle')))
            .onPressed,
        isNotNull,
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
      expect(find.text('Stop'), findsOneWidget);
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
