import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/first_run/first_run_model.dart';
import 'package:haro_app/features/first_run/first_run_providers.dart';
import 'package:haro_app/widgets/check_mark.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../creation_harness.dart';
import 'first_run_harness.dart';

const _green = BaselineResult(
  status: BaselineStatus.passed,
  passed: 128,
  total: 128,
  duration: Duration(milliseconds: 1400),
);

Future<void> _settleFor(WidgetTester tester, Duration d) async {
  await tester.pump(d);
  await tester.pump();
}

void _finish(FirstRunRig rig) => rig.container
    .read(firstRunBaselineLiveProvider(projectId).notifier)
    .apply(
      BaselineWsEvent(
        projectId: projectId,
        kind: 'done',
        result: const BaselineRun(status: 'passed', passed: 1, total: 1),
      ),
    );

void main() {
  setUpAll(loadBrandFonts);

  const wait = Duration(seconds: 5);

  group('never opens New workspace by itself', () {
    testWidgets('configured and green', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: _green,
      );
      expect(find.text('Gate ready.'), findsOneWidget);
      await _settleFor(tester, wait);
      expect(rig.commands.newWorkspace, isEmpty);
      expect(rig.writes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('fr-create')));
      expect(rig.commands.newWorkspace, [projectId]);
    });

    testWidgets('after a run started here finishes green', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          extra: {
            'GET /projects/$projectId/baseline': (_) =>
                jsonRes({'running': false, 'result': null}),
          },
        ),
        baselineFromBackend: true,
      );
      expect(rig.baselineStarts, hasLength(1));
      await _settleFor(tester, wait);
      expect(rig.commands.newWorkspace, isEmpty, reason: 'still running');

      _finish(rig);
      await tester.pump();
      expect(find.text('Gate ready.'), findsOneWidget);
      await _settleFor(tester, wait);
      expect(rig.commands.newWorkspace, isEmpty);
    });

    testWidgets('after the preset is written and the run is green', (
      tester,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
          extra: {
            'GET /projects/$projectId/baseline': (_) =>
                jsonRes({'running': false, 'result': null}),
            'POST /projects/$projectId/apply-preset': (_) =>
                jsonRes({'ok': true}),
          },
        ),
        baselineFromBackend: true,
      );
      expect(rig.baselineStarts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fr-write')));
      await tester.pumpAndSettle();
      expect(
        rig.baselineStarts,
        hasLength(1),
        reason: 'fresh run for the write',
      );
      expect(find.text('Checking main...'), findsOneWidget);

      _finish(rig);
      await tester.pump();
      expect(find.text('Gate ready.'), findsOneWidget);
      await _settleFor(tester, wait);
      expect(rig.commands.newWorkspace, isEmpty);
    });

    testWidgets('a run already in flight at the write is re-run, not trusted', (
      tester,
    ) async {
      var posts = 0;
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
          extra: {
            'GET /projects/$projectId/baseline': (_) =>
                jsonRes({'running': true, 'result': null}),
            'POST /projects/$projectId/apply-preset': (_) =>
                jsonRes({'ok': true}),
            'POST /projects/$projectId/baseline': (_) {
              posts++;
              return posts == 1
                  ? errorRes('a baseline run is already in progress')
                  : jsonRes({'running': true, 'result': null});
            },
          },
        ),
        baselineFromBackend: true,
      );
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fr-write')));
      await tester.pumpAndSettle();
      expect(posts, 1);

      _finish(rig);
      await tester.pump();
      await tester.pump();
      expect(posts, 2, reason: 're-run once the old-config run has ended');
      expect(find.text('Gate ready.'), findsNothing);

      _finish(rig);
      await tester.pump();
      await _settleFor(tester, wait);
      expect(posts, 2);
      expect(rig.commands.newWorkspace, isEmpty);
    });

    testWidgets('the written runner gets the tick once it is written', (
      tester,
    ) async {
      await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
          extra: {
            'POST /projects/$projectId/apply-preset': (_) =>
                jsonRes({'ok': true}),
          },
        ),
        baseline: _green,
      );
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fr-write')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('fr-row-runner')),
          matching: find.byType(CheckMark),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('fr-fix-runner')), findsNothing);
    });

    testWidgets('opening the preset preview neither writes nor opens it', (
      tester,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(runner: 'pytest', dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
        ),
        baseline: _green,
      );
      await _settleFor(tester, wait);
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      expect(rig.commands.newWorkspace, isEmpty);
      expect(rig.writes, isEmpty, reason: 'nothing written before the confirm');
    });
  });

  group('Create first workspace is never blocked', () {
    Future<void> createWorks(
      WidgetTester tester,
      BaselineResult baseline,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: baseline,
      );
      await _settleFor(tester, wait);
      expect(rig.commands.newWorkspace, isEmpty);
      final create = tester.widget<HaroButton>(
        find.byKey(const ValueKey('fr-create')),
      );
      expect(create.onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('fr-create')));
      expect(rig.commands.newWorkspace, [projectId]);
    }

    testWidgets('main is red', (tester) async {
      await createWorks(
        tester,
        const BaselineResult(
          status: BaselineStatus.failed,
          passed: 5,
          failed: 2,
          total: 7,
        ),
      );
      expect(find.text('main is already red (2 failing).'), findsOneWidget);
    });

    testWidgets('the gate could not run, and the advice says so', (
      tester,
    ) async {
      await createWorks(
        tester,
        const BaselineResult(
          status: BaselineStatus.error,
          error: 'gate command not found on PATH (exit 127)',
        ),
      );
      expect(find.text('The gate could not run on main.'), findsOneWidget);
      expect(
        find.textContaining('You can still create a workspace'),
        findsOneWidget,
      );
    });

    testWidgets('no tests on main', (tester) async {
      await createWorks(
        tester,
        const BaselineResult(status: BaselineStatus.noTests),
      );
    });
  });
}
