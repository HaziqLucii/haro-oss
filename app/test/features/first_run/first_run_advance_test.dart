import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/first_run/first_run_model.dart';
import 'package:haro_app/features/first_run/first_run_providers.dart';
import 'package:haro_app/overlays/overlay.dart' show haroOverlayDepth;
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/check_mark.dart';

import '../creation_harness.dart';
import '../workspace/harness.dart' show Preview, workspaceFor;
import 'first_run_harness.dart';

const _green = BaselineResult(
  status: BaselineStatus.passed,
  passed: 128,
  total: 128,
  duration: Duration(milliseconds: 1400),
);

const _beat = HaroTokens.beat;
const _justBefore = Duration(milliseconds: 400);
const _after = Duration(milliseconds: 1000);

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

  test('the beat is a token of about a second', () {
    expect(_beat, const Duration(milliseconds: 1200));
  });

  group('fires', () {
    testWidgets('once, after the beat, when configured and green', (
      tester,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: _green,
      );
      expect(find.text('Gate ready.'), findsOneWidget);
      expect(rig.commands.newWorkspace, isEmpty);

      await _settleFor(tester, _justBefore);
      expect(rig.commands.newWorkspace, isEmpty);

      await _settleFor(tester, _after);
      expect(rig.commands.newWorkspace, [projectId]);

      await _settleFor(tester, const Duration(seconds: 5));
      expect(rig.commands.newWorkspace, [projectId]);
      expect(rig.writes, isEmpty);
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
      await _settleFor(tester, const Duration(seconds: 3));
      expect(rig.commands.newWorkspace, isEmpty, reason: 'still running');

      rig.container
          .read(firstRunBaselineLiveProvider(projectId).notifier)
          .apply(
            BaselineWsEvent(
              projectId: projectId,
              kind: 'done',
              result: const BaselineRun(status: 'passed', passed: 9, total: 9),
            ),
          );
      await tester.pump();
      await _settleFor(tester, _justBefore);
      expect(rig.commands.newWorkspace, isEmpty);
      await _settleFor(tester, _after);
      expect(rig.commands.newWorkspace, [projectId]);
    });

    testWidgets('not again when the page is entered a second time', (
      tester,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: _green,
      );
      await _settleFor(tester, _beat + _after);
      expect(rig.commands.newWorkspace, [projectId]);

      rig.router.go('/');
      await tester.pumpAndSettle();
      rig.router.go('/first-run?project=$projectId');
      await tester.pumpAndSettle();
      expect(find.text('Gate ready.'), findsOneWidget);
      await _settleFor(tester, const Duration(seconds: 5));
      expect(rig.commands.newWorkspace, [projectId]);
      expect(find.byKey(const ValueKey('fr-create')), findsOneWidget);
    });
  });

  group('a fresh project', () {
    testWidgets('write the preset, then green, then advance', (tester) async {
      var written = 0;
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
          extra: {
            'GET /projects/$projectId/baseline': (_) =>
                jsonRes({'running': false, 'result': null}),
            'POST /projects/$projectId/apply-preset': (_) {
              written++;
              return jsonRes({'ok': true});
            },
          },
        ),
        baselineFromBackend: true,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('fr-row-runner')),
          matching: find.byType(CheckMark),
        ),
        findsNothing,
        reason: 'a proposal is not a configured runner',
      );
      expect(find.byKey(const ValueKey('fr-wash')), findsNothing);
      expect(rig.baselineStarts, isEmpty);
      await _settleFor(tester, const Duration(seconds: 3));
      expect(rig.commands.newWorkspace, isEmpty);

      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fr-write')));
      await tester.pumpAndSettle();
      expect(written, 1);
      expect(
        rig.baselineStarts,
        hasLength(1),
        reason: 'fresh run for the write',
      );
      expect(find.text('Checking main...'), findsOneWidget);
      expect(find.text('Gate ready.'), findsNothing);
      await _settleFor(tester, const Duration(seconds: 3));
      expect(rig.commands.newWorkspace, isEmpty, reason: 'still running');

      _finish(rig);
      await tester.pump();
      expect(find.text('Gate ready.'), findsOneWidget);
      await _settleFor(tester, _justBefore);
      expect(rig.commands.newWorkspace, isEmpty);
      await _settleFor(tester, _after);
      expect(rig.commands.newWorkspace, [projectId]);
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
      await _settleFor(tester, const Duration(seconds: 3));
      expect(rig.commands.newWorkspace, isEmpty);

      _finish(rig);
      await tester.pump();
      await _settleFor(tester, _justBefore);
      await _settleFor(tester, _after);
      expect(posts, 2);
      expect(rig.commands.newWorkspace, [projectId]);
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
  });

  group('waits for the user', () {
    Future<void> stays(WidgetTester tester, FirstRunRig rig) async {
      await _settleFor(tester, const Duration(seconds: 5));
      expect(rig.commands.newWorkspace, isEmpty);
    }

    testWidgets('red baseline', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: const BaselineResult(
          status: BaselineStatus.failed,
          passed: 5,
          failed: 2,
          total: 7,
        ),
      );
      await stays(tester, rig);
      expect(find.text('main is already red (2 failing).'), findsOneWidget);
    });

    testWidgets('red baseline, even after Continue anyway', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: const BaselineResult(
          status: BaselineStatus.failed,
          failed: 2,
          total: 2,
        ),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('fr-continue')));
      await tester.tap(find.byKey(const ValueKey('fr-continue')));
      await tester.pumpAndSettle();
      await stays(tester, rig);
    });

    testWidgets('baseline errored', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: const BaselineResult(
          status: BaselineStatus.error,
          error: 'could not check out main',
        ),
      );
      await stays(tester, rig);
    });

    testWidgets('no tests on main', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: const BaselineResult(status: BaselineStatus.noTests),
      );
      await stays(tester, rig);
    });

    testWidgets('baseline still running', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: const BaselineResult.running(passed: 3),
      );
      await stays(tester, rig);
    });

    testWidgets('no runner detected', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(gate: gateJson(dir: '')),
        baseline: _green,
      );
      await stays(tester, rig);
    });

    testWidgets('a preset is proposed but not confirmed', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(runner: 'pytest', dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
        ),
        baseline: _green,
      );
      await stays(tester, rig);
      expect(rig.writes, isEmpty);
    });

    testWidgets('a runner is set but a proposal is still pending', (
      tester,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
        ),
        baseline: _green,
      );
      expect(find.byKey(const ValueKey('fr-fix-runner')), findsOneWidget);
      await stays(tester, rig);
    });

    testWidgets('opening the preset preview neither writes nor advances', (
      tester,
    ) async {
      var written = false;
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(runner: 'pytest', dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
          extra: {
            'POST /projects/$projectId/apply-preset': (_) {
              written = true;
              return jsonRes({'ok': true});
            },
          },
        ),
        baseline: _green,
      );
      await stays(tester, rig);
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      expect(rig.commands.newWorkspace, isEmpty);
      expect(written, isFalse, reason: 'nothing written before the confirm');
    });

    testWidgets('an overlay is open when the beat ends', (tester) async {
      haroOverlayDepth.value = 0;
      addTearDown(() => haroOverlayDepth.value = 0);
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: _green,
      );
      haroOverlayDepth.value = 1;
      await _settleFor(tester, const Duration(seconds: 3));
      expect(rig.commands.newWorkspace, isEmpty);
      haroOverlayDepth.value = 0;
      await _settleFor(tester, const Duration(seconds: 5));
      expect(rig.commands.newWorkspace, isEmpty, reason: 'counts as a click');
    });

    testWidgets('the project already has a workspace', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: _green,
        workspaces: [workspaceFor(Preview.green)],
      );
      expect(find.text('Gate ready.'), findsOneWidget);
      await stays(tester, rig);
    });

    testWidgets('unknown project', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: MockBackend({'GET /projects': (_) => jsonRes([])}),
        location: '/first-run?project=nope',
      );
      await stays(tester, rig);
    });
  });

  group('a click cancels', () {
    testWidgets('anywhere on the page before the beat ends', (tester) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: _green,
      );
      await _settleFor(tester, _justBefore);
      await tester.tap(find.text('ADDING ~/code/shop-api'));
      await tester.pump();
      await _settleFor(tester, const Duration(seconds: 5));
      expect(rig.commands.newWorkspace, isEmpty);
      await tester.tap(find.byKey(const ValueKey('fr-create')));
      expect(rig.commands.newWorkspace, [projectId]);
    });

    testWidgets('a click before any beat is pending forfeits nothing', (
      tester,
    ) async {
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(),
        baseline: const BaselineResult.running(),
      );
      await tester.tap(find.text('ADDING ~/code/shop-api'));
      await tester.pump();
      _finish(rig);
      await tester.pump();
      await _settleFor(tester, _justBefore);
      expect(rig.commands.newWorkspace, isEmpty);
      await _settleFor(tester, _after);
      expect(rig.commands.newWorkspace, [projectId]);
    });
  });
}
