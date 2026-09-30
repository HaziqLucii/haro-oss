import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/first_run/first_run_model.dart';
import 'package:haro_app/features/first_run/first_run_providers.dart';

import '../creation_harness.dart';
import 'first_run_harness.dart';

const _path = '/projects/$projectId/baseline';

Finder _row(String id) => find.byKey(ValueKey('fr-row-$id'));

Finder _in(String id, String text) =>
    find.descendant(of: _row(id), matching: find.text(text));

Finder _inContaining(String id, String text) =>
    find.descendant(of: _row(id), matching: find.textContaining(text));

final _runButton = find.byKey(const ValueKey('fr-action-baseline'));

Map<String, dynamic> runJson({
  String status = 'passed',
  int passed = 0,
  int failed = 0,
  int skipped = 0,
  int? total,
  double durationS = 1.4,
  double? coverage,
  List<String> failing = const [],
  String? error,
}) => {
  'status': status,
  'passed': passed,
  'failed': failed,
  'skipped': skipped,
  'total': total ?? passed + failed + skipped,
  'duration_s': durationS,
  'coverage_pct': coverage,
  'failing_ids': failing,
  'error': error,
};

Map<String, Handler> routes({
  Map<String, dynamic>? existing,
  bool running = false,
  Handler? post,
}) => {
  'GET $_path': (_) => jsonRes({'running': running, 'result': existing}),
  'POST $_path': post ?? (_) => jsonRes({'running': true, 'result': existing}),
};

Future<FirstRunRig> pump(WidgetTester tester, Map<String, Handler> extra) =>
    pumpFirstRun(
      tester,
      backend: backendFor(extra: extra),
      baselineFromBackend: true,
    );

BaselineLive live(FirstRunRig rig) =>
    rig.container.read(firstRunBaselineLiveProvider(projectId).notifier);

BaselineWsEvent event(
  String kind, {
  int passed = 0,
  int failed = 0,
  BaselineRun? result,
}) => BaselineWsEvent(
  projectId: projectId,
  kind: kind,
  passed: passed,
  failed: failed,
  result: result,
);

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('never run: an honest row, a Run baseline button, no coverage', (
    tester,
  ) async {
    await pump(tester, routes());
    expect(
      _in('baseline', 'not run yet: one full run of the suite on main'),
      findsOneWidget,
    );
    expect(find.text('Run baseline'), findsOneWidget);
    expect(_in('coverage', 'not measured'), findsOneWidget);
    expect(find.text('Gate ready.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('run: POST, live count from the feed, then the passed result', (
    tester,
  ) async {
    final rig = await pump(tester, routes());
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(rig.backend.where('POST', _path), hasLength(1));
    expect(_in('baseline', 'running the suite on main'), findsOneWidget);
    expect(_runButton, findsNothing);
    expect(find.text('Gate ready.'), findsNothing);

    live(rig).apply(event('cell', passed: 3, failed: 1));
    await tester.pumpAndSettle();
    expect(
      _in('baseline', 'running the suite on main · 4 tests done · 1 failing'),
      findsOneWidget,
    );

    live(rig).apply(
      event(
        'done',
        result: BaselineRun.fromJson(
          runJson(passed: 128, coverage: 81.234, durationS: 1.4),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _in(
        'baseline',
        '128 passed on main, the gate has a green starting point · 1.4s',
      ),
      findsOneWidget,
    );
    expect(_in('coverage', '81.2% of lines on main'), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
    expect(find.text('Gate ready.'), findsOneWidget);
    expect(
      find.text('Green means all 128 Vitest tests in src/ pass.'),
      findsOneWidget,
    );
  });

  testWidgets('events for another project are ignored', (tester) async {
    final rig = await pump(tester, routes());
    live(
      rig,
    ).apply(const BaselineWsEvent(projectId: 'other', kind: 'cell', passed: 9));
    await tester.pumpAndSettle();
    expect(
      _in('baseline', 'not run yet: one full run of the suite on main'),
      findsOneWidget,
    );
  });

  testWidgets('a stored passed result shows and Run again posts again', (
    tester,
  ) async {
    final existing = runJson(passed: 42);
    final rig = await pump(tester, routes(existing: existing));
    expect(_inContaining('baseline', '42 passed on main'), findsOneWidget);
    expect(_in('coverage', 'not measured'), findsOneWidget);

    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(rig.backend.where('POST', _path), hasLength(1));
    expect(_in('baseline', 'running the suite on main'), findsOneWidget);
  });

  testWidgets('a run already in flight when the page opens reads as running', (
    tester,
  ) async {
    await pump(tester, routes(running: true));
    expect(_in('baseline', 'running the suite on main'), findsOneWidget);
    expect(_runButton, findsNothing);
  });

  testWidgets('failed: count, up to five ids, the rest folded, red gate line', (
    tester,
  ) async {
    final failing = [for (var i = 1; i <= 7; i++) 'src/a.test.ts::case $i'];
    await pump(
      tester,
      routes(
        existing: runJson(
          status: 'failed',
          passed: 121,
          failed: 7,
          failing: failing,
        ),
      ),
    );
    expect(
      _in(
        'baseline',
        '7 failing on main before any agent touches it: fix these first or '
            'the gate will be red from the start · 1.4s',
      ),
      findsOneWidget,
    );
    for (var i = 1; i <= 5; i++) {
      expect(_in('baseline', 'src/a.test.ts::case $i'), findsOneWidget);
    }
    expect(_in('baseline', 'src/a.test.ts::case 6'), findsNothing);
    expect(_in('baseline', '+2 more'), findsOneWidget);
    expect(find.text('main is already red (7 failing).'), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no overflow at 960x640');
  });

  testWidgets('failed with no failing test: says so, shows the error, red', (
    tester,
  ) async {
    await pump(
      tester,
      routes(
        existing: runJson(
          status: 'failed',
          passed: 4,
          error: 'the runner reported failure but no failing test case',
        ),
      ),
    );
    expect(
      _in(
        'baseline',
        'the suite failed on main without a failing test (unhandled error or '
            'setup problem) · 1.4s',
      ),
      findsOneWidget,
    );
    expect(
      _in('baseline', 'the runner reported failure but no failing test case'),
      findsOneWidget,
    );
    expect(
      find.text('main is already red (the suite failed).'),
      findsOneWidget,
    );
    expect(find.text('Gate ready.'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('fr-continue')));
    await tester.tap(find.byKey(const ValueKey('fr-continue')));
    await tester.pumpAndSettle();
    expect(
      find.text('The gate compares against the suite already failing on main.'),
      findsOneWidget,
    );
  });

  testWidgets('a note about what the run covered shows under the row', (
    tester,
  ) async {
    await pump(
      tester,
      routes(
        existing: {
          ...runJson(passed: 3),
          'note': 'the project\'s setup script was not run',
        },
      ),
    );
    expect(
      _in('baseline', 'the project\'s setup script was not run'),
      findsOneWidget,
    );
  });

  testWidgets('a reconnect clears a stuck running row and re-reads the truth', (
    tester,
  ) async {
    Map<String, dynamic> current = {'running': true, 'result': null};
    final rig = await pump(tester, {
      'GET $_path': (_) => jsonRes(current),
      'POST $_path': (_) => jsonRes(current),
    });
    live(rig).apply(event('cell', passed: 2));
    await tester.pumpAndSettle();
    expect(_inContaining('baseline', 'running the suite on main'), findsOne);

    current = {'running': false, 'result': runJson(passed: 9)};
    live(rig).apply(const BaselineWsEvent(projectId: '*', kind: 'resync'));
    await tester.pumpAndSettle();
    expect(_inContaining('baseline', '9 passed on main'), findsOneWidget);
    expect(_runButton, findsOneWidget);
  });

  testWidgets('a fresh read that says not running beats a running row', (
    tester,
  ) async {
    Map<String, dynamic> current = {'running': false, 'result': null};
    final rig = await pump(tester, {
      'GET $_path': (_) => jsonRes(current),
      'POST $_path': (_) => jsonRes({'running': true, 'result': null}),
    });
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(_in('baseline', 'running the suite on main'), findsOneWidget);

    current = {'running': false, 'result': runJson(passed: 5)};
    rig.container.invalidate(firstRunBaselineProvider(projectId));
    await tester.pumpAndSettle();
    expect(_inContaining('baseline', '5 passed on main'), findsOneWidget);
  });

  testWidgets('a stopped run (error event, no result) drops the running row', (
    tester,
  ) async {
    final rig = await pump(tester, routes(existing: runJson(passed: 7)));
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(_in('baseline', 'running the suite on main'), findsOneWidget);

    live(rig).apply(event('error'));
    await tester.pumpAndSettle();
    expect(_inContaining('baseline', '7 passed on main'), findsOneWidget);
  });

  testWidgets('no tests: says so and the gate is not ready', (tester) async {
    await pump(
      tester,
      routes(
        existing: runJson(status: 'no_tests', error: 'no tests found'),
      ),
    );
    expect(
      _in('baseline', 'no tests found on main, so the gate has nothing to run'),
      findsOneWidget,
    );
    expect(find.text('Gate ready.'), findsNothing);
    expect(find.text('Gate not ready.'), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
  });

  testWidgets('error: first line of the reason, Run again offered', (
    tester,
  ) async {
    await pump(
      tester,
      routes(
        existing: runJson(
          status: 'error',
          error: '\n  pytest not found: add pytest.\nsecond line',
        ),
      ),
    );
    expect(_in('baseline', 'could not run the suite on main'), findsOneWidget);
    expect(_in('baseline', 'pytest not found: add pytest.'), findsOneWidget);
    expect(find.text('second line'), findsNothing);
    expect(find.text('Run again'), findsOneWidget);
  });

  testWidgets('an error result from the feed replaces the running row', (
    tester,
  ) async {
    final rig = await pump(tester, routes());
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    live(rig).apply(
      event(
        'error',
        result: BaselineRun.fromJson(
          runJson(status: 'error', error: 'could not check out main'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_in('baseline', 'could not run the suite on main'), findsOneWidget);
    expect(_in('baseline', 'could not check out main'), findsOneWidget);
  });

  testWidgets('a 409 means it is already running, not an error', (
    tester,
  ) async {
    await pump(
      tester,
      routes(post: (_) => errorRes('a baseline run is already in progress')),
    );
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(_in('baseline', 'running the suite on main'), findsOneWidget);
    expect(find.textContaining('Could not start'), findsNothing);
  });

  testWidgets('a failed start says why and keeps the button', (tester) async {
    await pump(tester, routes(post: (_) => errorRes('project not found', 404)));
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(
      _in('baseline', 'Could not start the run: project not found'),
      findsOneWidget,
    );
    expect(_runButton, findsOneWidget);
  });

  testWidgets('a backend without the endpoint reads as never run', (
    tester,
  ) async {
    await pump(tester, {
      'GET $_path': (_) => errorRes('not found', 404),
      'POST $_path': (_) => errorRes('not found', 404),
    });
    expect(
      _in('baseline', 'not run yet: one full run of the suite on main'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('model', () {
    test('fromRun maps every status and the duration', () {
      BaselineResult of(String status) => BaselineResult.fromRun(
        BaselineRun.fromJson(runJson(status: status, durationS: 2.5)),
      );
      expect(of('passed').status, BaselineStatus.passed);
      expect(of('failed').status, BaselineStatus.failed);
      expect(of('no_tests').status, BaselineStatus.noTests);
      expect(of('error').status, BaselineStatus.error);
      expect(of('surprise').status, BaselineStatus.error);
      expect(of('passed').duration, const Duration(milliseconds: 2500));
    });

    test('a running count never leaks into the suite size', () {
      const running = BaselineResult.running(passed: 5, failed: 1);
      expect(running.total, 6);
      expect(running.knownTotal, isNull);
      expect(
        const BaselineResult(
          status: BaselineStatus.passed,
          total: 9,
        ).knownTotal,
        9,
      );
    });

    test(
      'coverage row: whole numbers drop the decimal, null is not measured',
      () {
        expect(coverageRow(null).finding, 'not measured');
        expect(
          coverageRow(
            const BaselineResult(
              status: BaselineStatus.passed,
              coveragePct: 80,
            ),
          ).finding,
          '80% of lines on main',
        );
      },
    );

    test('the ws event parses with counts and a result', () {
      final e = parseWsEvent({
        'channel': 'baseline',
        'project_id': 'p1',
        'kind': 'done',
        'result': runJson(passed: 3, coverage: 50),
      });
      expect(e, isA<BaselineWsEvent>());
      final b = e as BaselineWsEvent;
      expect(b.projectId, 'p1');
      expect(b.result?.passed, 3);
      expect(b.result?.coveragePct, 50);
      final c = parseWsEvent({
        'channel': 'baseline',
        'project_id': 'p1',
        'kind': 'cell',
        'passed': 2,
        'failed': 1,
        'skipped': 0,
      }) as BaselineWsEvent;
      expect((c.passed, c.failed, c.result), (2, 1, null));
    });
  });
}
