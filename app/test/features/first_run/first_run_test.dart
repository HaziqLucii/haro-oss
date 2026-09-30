import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/first_run/first_run_model.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import '../creation_harness.dart';
import 'first_run_harness.dart';

Finder _row(String id) => find.byKey(ValueKey('fr-row-$id'));

Finder _in(String id, String text) =>
    find.descendant(of: _row(id), matching: find.text(text));

const _red = BaselineResult(
  status: BaselineStatus.failed,
  passed: 125,
  failed: 3,
  total: 128,
  duration: Duration(milliseconds: 1400),
);

const _green = BaselineResult(
  status: BaselineStatus.passed,
  passed: 128,
  total: 128,
  duration: Duration(milliseconds: 1400),
);

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('rows render from what the backend reports, nothing is written', (
    tester,
  ) async {
    final rig = await pumpFirstRun(tester, backend: backendFor());

    expect(find.text('ADDING ~/code/shop-api'), findsOneWidget);
    expect(
      find.text('Checking how this project proves itself'),
      findsOneWidget,
    );
    expect(_in('git', 'main · origin linked'), findsOneWidget);
    expect(_in('runner', 'Vitest in src/'), findsOneWidget);
    expect(_in('dev', 'npm run dev'), findsOneWidget);
    expect(
      _in('secrets', '2 variables in the Environment seed'),
      findsOneWidget,
    );
    expect(_in('coverage', 'not measured'), findsOneWidget);
    expect(find.byKey(const ValueKey('fr-fix-runner')), findsNothing);
    expect(find.byKey(const ValueKey('fr-fix-coverage')), findsNothing);
    expect(find.byKey(const ValueKey('fr-fix-secrets')), findsNothing);
    expect(rig.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the footer is on screen at the smallest window when ready', (
    tester,
  ) async {
    await pumpFirstRun(tester, backend: backendFor());
    final bottom = tester.getBottomLeft(
      find.byKey(const ValueKey('fr-create')),
    );
    expect(bottom.dy, lessThanOrEqualTo(640));
  });

  testWidgets('a local-only project says so', (tester) async {
    await pumpFirstRun(
      tester,
      backend: backendFor(project: projectJson(remote: null)),
    );
    expect(_in('git', 'main · no remote linked'), findsOneWidget);
  });

  testWidgets('with no baseline yet the row says so and claims nothing', (
    tester,
  ) async {
    await pumpFirstRun(tester, backend: backendFor());
    expect(
      _in('baseline', 'not run yet: one full run of the suite on main'),
      findsOneWidget,
    );
    expect(find.textContaining('passed on main'), findsNothing);
  });

  testWidgets('result line names runner and dir, N only when known', (
    tester,
  ) async {
    await pumpFirstRun(tester, backend: backendFor());
    expect(find.text('Gate ready.'), findsOneWidget);
    expect(
      find.text('Green means all Vitest tests in src/ pass.'),
      findsOneWidget,
    );
  });

  testWidgets('a passing baseline supplies the test count', (tester) async {
    await pumpFirstRun(tester, backend: backendFor(), baseline: _green);
    expect(
      _in(
        'baseline',
        '128 passed on main, the gate has a green starting point · 1.4s',
      ),
      findsOneWidget,
    );
    expect(_in('runner', 'Vitest in src/ · 128 tests'), findsOneWidget);
    expect(
      find.text('Green means all 128 Vitest tests in src/ pass.'),
      findsOneWidget,
    );
  });

  testWidgets('missing runner: an ink line says what is missing, no green', (
    tester,
  ) async {
    await pumpFirstRun(
      tester,
      backend: backendFor(gate: gateJson(dir: '')),
    );
    expect(_in('runner', 'Nothing detected'), findsOneWidget);
    expect(find.text('Gate ready.'), findsNothing);
    expect(find.text('Gate not ready.'), findsOneWidget);
    expect(find.textContaining('No test runner found'), findsOneWidget);
  });

  testWidgets('red baseline: main is already red, continue gates the primary', (
    tester,
  ) async {
    final rig = await pumpFirstRun(
      tester,
      backend: backendFor(),
      baseline: _red,
    );
    expect(
      _in(
        'baseline',
        '3 failing on main before any agent touches it: fix these first or '
            'the gate will be red from the start · 1.4s',
      ),
      findsOneWidget,
    );
    expect(find.text('main is already red (3 failing).'), findsOneWidget);
    expect(find.text('Gate ready.'), findsNothing);
    expect(
      find.text('(the gate compares against this baseline)'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const ValueKey('fr-create')));
    await tester.tap(find.byKey(const ValueKey('fr-create')));
    await tester.pump();
    expect(rig.commands.newWorkspace, isEmpty);

    await tester.tap(find.byKey(const ValueKey('fr-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Gate ready.'), findsOneWidget);
    expect(
      find.text(
        'The gate compares against the 3 tests already failing on main.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('fr-create')));
    expect(rig.commands.newWorkspace, [projectId]);
  });

  testWidgets('red baseline: pick a different command opens the gate tab', (
    tester,
  ) async {
    final rig = await pumpFirstRun(
      tester,
      backend: backendFor(),
      baseline: _red,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('fr-pick-command')));
    await tester.tap(find.byKey(const ValueKey('fr-pick-command')));
    expect(rig.commands.settings, [SettingsTab.gate]);
  });

  testWidgets('footer: adjust opens the gate tab, create opens New workspace', (
    tester,
  ) async {
    final rig = await pumpFirstRun(tester, backend: backendFor());
    await tester.tap(find.byKey(const ValueKey('fr-adjust')));
    expect(rig.commands.settings, [SettingsTab.gate]);
    await tester.tap(find.byKey(const ValueKey('fr-create')));
    expect(rig.commands.newWorkspace, [projectId]);
    expect(rig.writes, isEmpty);
  });

  testWidgets(
    'accepting a detected preset shows the config, writes only on click',
    (tester) async {
      var applied = 0;
      final rig = await pumpFirstRun(
        tester,
        backend: backendFor(
          gate: gateJson(dir: ''),
          scripts: scriptsJson(setup: null, run: null),
          detection: detectionJson(proposal: true),
          extra: {
            'POST /projects/$projectId/apply-preset': (call) {
              applied++;
              expect(call.body, {'preset_id': 'vitest', 'target': 'shared'});
              return jsonRes({'ok': true});
            },
          },
        ),
      );
      expect(rig.writes, isEmpty);
      expect(_in('runner', 'Vitest in project root'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fr-preview')), findsOneWidget);
      expect(find.textContaining('runner = "vitest"'), findsOneWidget);
      expect(rig.writes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('fr-write')));
      await tester.pumpAndSettle();
      expect(applied, 1);
      expect(find.byKey(const ValueKey('fr-preview')), findsNothing);
    },
  );

  testWidgets('cancelling the preview writes nothing', (tester) async {
    final rig = await pumpFirstRun(
      tester,
      backend: backendFor(
        gate: gateJson(runner: 'pytest', dir: ''),
        scripts: scriptsJson(setup: null, run: null),
        detection: detectionJson(proposal: true),
      ),
    );
    expect(
      _in('runner', 'Node (vitest) detected · not written yet'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fr-preview-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fr-preview')), findsNothing);
    expect(rig.writes, isEmpty);
  });

  testWidgets('a failed write shows the error and stays open', (tester) async {
    await pumpFirstRun(
      tester,
      backend: backendFor(
        gate: gateJson(runner: 'pytest', dir: ''),
        scripts: scriptsJson(setup: null, run: null),
        detection: detectionJson(proposal: true),
        extra: {
          'POST /projects/$projectId/apply-preset': (_) =>
              errorRes('disk full', 500),
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fr-write')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not write the preset'), findsOneWidget);
    expect(find.byKey(const ValueKey('fr-preview')), findsOneWidget);
  });

  testWidgets('unknown project: mono line and a way back to triage', (
    tester,
  ) async {
    final rig = await pumpFirstRun(
      tester,
      backend: MockBackend({'GET /projects': (_) => jsonRes([])}),
      location: '/first-run?project=nope',
    );
    expect(find.text('PROJECT NOT FOUND'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fr-back')));
    await tester.pumpAndSettle();
    expect(rig.location, '/');
  });

  testWidgets('no project param', (tester) async {
    await pumpFirstRun(
      tester,
      backend: MockBackend({}),
      location: '/first-run',
    );
    expect(find.text('NO PROJECT SELECTED'), findsOneWidget);
  });

  testWidgets(
    'no overflow at 960x640 with the preview open and a red baseline',
    (tester) async {
      await pumpFirstRun(
        tester,
        baseline: _red,
        backend: backendFor(
          gate: gateJson(runner: 'pytest', dir: ''),
          scripts: scriptsJson(
            setup: null,
            run: 'npm --prefix frontend run dev -- --port \$HARO_PORT --host 0.0.0.0',
          ),
          detection: detectionJson(proposal: true),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  group('model', () {
    test('env count ignores comments and blanks, keeps no values', () {
      expect(
        envVariableCount('A=1\n\n# B=2\nexport C=3\n D = 4\nnot a var'),
        3,
      );
    });

    test('tildify only rewrites paths under home', () {
      expect(tildify('/Users/me/code/x', '/Users/me'), '~/code/x');
      expect(tildify('/opt/x', '/Users/me'), '/opt/x');
      expect(tildify('/Users/mex/y', '/Users/me'), '/Users/mex/y');
    });
  });
}
