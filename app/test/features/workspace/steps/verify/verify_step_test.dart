import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/features/workspace/steps/verify/verify_step.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../../../state/builders.dart';
import '../../harness.dart';
import 'verify_harness.dart';

const untestedKey = 'untested_lines:lib/rates.ts:2';
const failedKey = 'failed:lib/shipping.test.ts:calculateShipping › case 0';

Preview previewOf(WorkspaceStatus s) => switch (s) {
  WorkspaceStatus.testsRunning => Preview.running,
  WorkspaceStatus.gateRed => Preview.red,
  WorkspaceStatus.gateGreen => Preview.green,
  WorkspaceStatus.merged => Preview.merged,
  _ => Preview.idle,
};

WorkspaceDetail greenDetail({
  List<String> checked = const [],
  List<Cell>? cellList,
  WorkspaceAnalysis analysis = WorkspaceAnalysis.none,
  List<Map<String, dynamic>> tamper = const [],
}) => verifyDetail(
  WorkspaceStatus.gateGreen,
  run: greenRun(
    unchecked: [untestedRow('lib/rates.ts', 2), untestedRow('lib/zones.ts', 1)],
    tamper: tamper,
  ),
  cells: cellList ?? cells(594),
  checked: checked,
  analysis: analysis,
);

WorkspaceDetail redDetail({bool tamper = true}) => verifyDetail(
  WorkspaceStatus.gateRed,
  run: failingRun(tamper: tamper ? [removedTest] : const []),
);

Future<VerifyRig> pumpVerify(
  WidgetTester tester,
  WorkspaceDetail d, {
  Size size = const Size(1400, 900),
  VerifiedHunksResponse? hunks,
  ReceiptResponse? receipt,
  ImpactResponse? impact,
  BlameResponse? blame,
  bool terminal = false,
}) async {
  final rig = VerifyRig(
    previewOf(d.workspace!.status),
    state: d,
    hunks: hunks,
    receipt: receipt,
    impact: impact,
    blame: blame,
  );
  rig.router = await rig.pump(tester, size: size);
  if (terminal) {
    await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
    await tester.pumpAndSettle();
  }
  return rig;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String location(GoRouter r) =>
    r.routerDelegate.currentConfiguration.uri.toString();

double rowOpacity(WidgetTester tester, String key) => tester
    .widget<Opacity>(
      find.descendant(
        of: find.byKey(ValueKey('look-row-$key')),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

Finder inStep(Finder f) =>
    find.descendant(of: find.byType(VerifyStep), matching: f);

Iterable<HaroButton> stepButtons(WidgetTester tester) => tester.widgetList(
  find.descendant(
    of: find.byType(VerifyStep),
    matching: find.byType(HaroButton),
  ),
);

String? word(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('verify-verdict-word'))).data;

Color? wordColor(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('verify-verdict-word')))
    .style
    ?.color;

void main() {
  group('verdict copy per state', () {
    testWidgets('idle', (tester) async {
      await pumpVerify(tester, verifyDetail(WorkspaceStatus.idle));
      expect(word(tester), 'NOT RUN');
      expect(find.text('The gate hasn’t run on this tree.'), findsOneWidget);
      expect(
        find.text(
          'It starts by itself when the agent finishes. Run it now if you changed files by hand.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('verify-progress')), findsNothing);
      expect(
        find.text('Nothing to review until the gate has run.'),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('metric-tests'))).data,
        '–',
      );
    });

    testWidgets('running shows the live count and a 2px ink bar', (
      tester,
    ) async {
      await pumpVerify(
        tester,
        verifyDetail(
          WorkspaceStatus.testsRunning,
          run: greenRun(),
          cells: cells(412, running: 4),
          expectedTotal: 594,
        ),
      );
      expect(word(tester), 'RUNNING');
      expect(find.text('412 of 594 tests done'), findsOneWidget);
      expect(
        find.text(
          'No failures so far. The first failure shows up here the moment it happens.',
        ),
        findsOneWidget,
      );
      expect(find.text('412 / 594'), findsOneWidget);
      final bar = tester.widget<FractionallySizedBox>(
        find.byKey(const ValueKey('verify-progress')),
      );
      expect(bar.widthFactor, closeTo(412 / 594, .001));
      final fill = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(const ValueKey('verify-progress')),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(fill.color, HaroTokens.ink);
      expect(wordColor(tester), HaroTokens.ink);
      expect(find.text('Appears when the run finishes.'), findsOneWidget);
      expect(find.text('after run'), findsNWidgets(3));
    });

    testWidgets('red', (tester) async {
      await pumpVerify(tester, redDetail());
      expect(word(tester), 'RED');
      expect(find.text('3 tests are failing'), findsOneWidget);
      expect(wordColor(tester), HaroTokens.fail);
      expect(find.text('Failing & flagged'.toUpperCase()), findsOneWidget);
      expect(find.text('Failures block the merge'), findsOneWidget);
      expect(find.text('13 / 16'), findsOneWidget);
    });

    testWidgets('green', (tester) async {
      await pumpVerify(tester, greenDetail());
      expect(word(tester), 'GREEN');
      expect(find.text('All 594 tests pass'), findsOneWidget);
      expect(wordColor(tester), HaroTokens.gate);
      expect(inStep(find.text('NEEDS YOUR EYES')), findsOneWidget);
      expect(find.text('Advisory · never blocks the merge'), findsOneWidget);
      expect(find.text('594 / 594'), findsOneWidget);
      expect(find.text('2.1s'), findsOneWidget);
      expect(find.textContaining('vitest · '), findsWidgets);
      expect(find.textContaining('4m ago'), findsWidgets);
    });

    testWidgets('merged is lilac and quiet', (tester) async {
      await pumpVerify(
        tester,
        verifyDetail(
          WorkspaceStatus.merged,
          run: greenRun(unchecked: [untestedRow('lib/rates.ts', 2)]),
          cells: cells(594),
          pr: 232,
        ),
      );
      expect(word(tester), 'MERGED');
      expect(find.text('Merged into origin/main'), findsOneWidget);
      expect(wordColor(tester), HaroTokens.merged);
      expect(rowOpacity(tester, untestedKey), .45);
      expect(find.byKey(const ValueKey('look-send')), findsNothing);
      expect(find.byKey(const ValueKey('verify-rerun')), findsNothing);
      expect(find.byKey(const ValueKey('verify-impacted')), findsNothing);
      expect(
        tester
            .widget<HaroButton>(find.byKey(const ValueKey('verify-next')))
            .label,
        'Continue on a new branch',
      );
    });
  });

  testWidgets('exactly one bone-filled button in the main column', (
    tester,
  ) async {
    int primaries() {
      final barFinder = find.byKey(const ValueKey('next-action'));
      final bar = barFinder.evaluate().isEmpty
          ? null
          : tester.widget<HaroButton>(barFinder);
      return (bar?.variant == HaroButtonVariant.primary ? 1 : 0) +
          stepButtons(tester)
              .where((b) => b.variant == HaroButtonVariant.primary)
              .length;
    }

    final cases = <String, (WorkspaceDetail, int)>{
      // When the action lands on this step the bar hides it and the step takes the fill.
      'idle with changes': (verifyDetail(WorkspaceStatus.idle), 1),
      'red: send failures': (redDetail(tamper: false), 1),
      'red: restore tests': (redDetail(), 1),
      'green: review & ship': (greenDetail(), 1),
      'merged': (
        verifyDetail(WorkspaceStatus.merged, run: greenRun(), pr: 232),
        1,
      ),
      // Nothing to press while the gate runs.
      'running': (
        verifyDetail(
          WorkspaceStatus.testsRunning,
          run: greenRun(),
          cells: cells(10),
          expectedTotal: 594,
        ),
        0,
      ),
    };
    for (final e in cases.entries) {
      await pumpVerify(tester, e.value.$1);
      expect(primaries(), e.value.$2, reason: e.key);
    }
  });

  testWidgets('a gate run is primary in the verdict block, not the step bar', (
    tester,
  ) async {
    await pumpVerify(tester, verifyDetail(WorkspaceStatus.idle));
    expect(
      tester
          .widget<HaroButton>(find.byKey(const ValueKey('verify-next')))
          .variant,
      HaroButtonVariant.primary,
    );
    expect(find.byKey(const ValueKey('next-action')), findsNothing);
  });

  group('verdict buttons', () {
    testWidgets('the next action does what the step bar does', (tester) async {
      final rig = await pumpVerify(tester, redDetail(tamper: false));
      await tapKey(tester, 'verify-next');
      expect(rig.calls, ['sendFailures']);
    });

    testWidgets('run again and impacted only', (tester) async {
      final rig = await pumpVerify(tester, greenDetail());
      expect(find.byKey(const ValueKey('verify-rerun')), findsOneWidget);
      await tapKey(tester, 'verify-rerun');
      await tapKey(tester, 'verify-impacted');
      expect(rig.calls, ['runGate', 'runGate:impacted']);
    });

    testWidgets('a running gate disables them', (tester) async {
      final rig = await pumpVerify(
        tester,
        verifyDetail(
          WorkspaceStatus.testsRunning,
          run: greenRun(),
          cells: cells(10),
          expectedTotal: 594,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('verify-rerun')));
      await tester.tap(find.byKey(const ValueKey('verify-impacted')));
      await tester.tap(find.byKey(const ValueKey('verify-next')));
      await tester.pump();
      expect(rig.calls, isEmpty);
    });

    testWidgets('no duplicate button when the next action is a gate run', (
      tester,
    ) async {
      await pumpVerify(tester, verifyDetail(WorkspaceStatus.idle));
      expect(find.byKey(const ValueKey('verify-rerun')), findsNothing);
      expect(find.byKey(const ValueKey('verify-impacted')), findsOneWidget);
    });
  });

  group('acceptance test', () {
    WorkspaceDetail withApproved(WorkspaceDetail d) => d.copyWith(
      workspace: d.workspace!.copyWith(
        testFirst: const TestFirstState(phase: TestFirstPhase.approved),
      ),
    );

    Map<String, dynamic> acceptance({bool ok = true}) => {
      'approved_at': 1790000000.0,
      'total': 2,
      'passing': ok ? 2 : 1,
      'changed': ok ? [] : ['tests/test_ship.py'],
      'ok': ok,
    };

    testWidgets('a green run shows the receipt line: N/N passing, unchanged', (
      tester,
    ) async {
      final d = verifyDetail(
        WorkspaceStatus.gateGreen,
        run: greenRun(overrides: {'acceptance': acceptance()}),
        cells: cells(594),
      );
      await pumpVerify(tester, withApproved(d));
      final line = tester.widget<Text>(
        find.byKey(const ValueKey('verify-acceptance')),
      );
      expect(line.data, startsWith('Acceptance test (approved '));
      expect(line.data, endsWith('): 2/2 passing, unchanged.'));
    });

    testWidgets(
      'a changed acceptance file reads red with the contract headline',
      (tester) async {
        await pumpVerify(
          tester,
          withApproved(
            verifyDetail(
              WorkspaceStatus.gateRed,
              run: greenRun(
                overrides: {
                  'acceptance': acceptance(ok: false),
                  'acceptance_blocked': true,
                },
                tamper: [
                  {
                    'kind': 'acceptance_changed',
                    'file': 'tests/test_ship.py',
                    'detail':
                        'approved acceptance test file changed after approval',
                  },
                ],
              ),
            ),
          ),
        );
        expect(find.text('The acceptance test isn’t intact'), findsOneWidget);
        expect(
          find.textContaining('file changed: tests/test_ship.py'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'after leaving test-first a stale run shows no acceptance line',
      (tester) async {
        await pumpVerify(
          tester,
          verifyDetail(
            WorkspaceStatus.gateGreen,
            run: greenRun(overrides: {'acceptance': acceptance()}),
            cells: cells(594),
          ),
        );
        expect(find.byKey(const ValueKey('verify-acceptance')), findsNothing);
      },
    );

    testWidgets('an ordinary workspace has no acceptance line', (tester) async {
      await pumpVerify(tester, greenDetail());
      expect(find.byKey(const ValueKey('verify-acceptance')), findsNothing);
    });
  });

  group('tamper alarm', () {
    testWidgets('shows above the list on a red gate, with both actions', (
      tester,
    ) async {
      final rig = await pumpVerify(tester, redDetail());
      expect(find.text('TAMPER ALARM'), findsOneWidget);
      expect(
        find.text('The agent deleted a test that covered this change.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('is free at exactly the \$100 boundary'),
        findsWidgets,
      );
      expect(
        find.textContaining('lib/shipping.test.ts. A passing'),
        findsOneWidget,
      );
      final banner = tester.getTopLeft(
        find.byKey(const ValueKey('tamper-headline')),
      );
      final list = tester.getTopLeft(find.text('FAILING & FLAGGED'));
      expect(banner.dy, lessThan(list.dy));

      await tapKey(tester, 'tamper-restore');
      expect(rig.calls, ['restoreTests']);
      expect(location(rig.router!), '/w/ws_1/agent');
    });

    testWidgets('See deletion opens the code step on that file', (
      tester,
    ) async {
      final rig = await pumpVerify(tester, redDetail());
      await tapKey(tester, 'tamper-see');
      expect(location(rig.router!), '/w/ws_1/code?file=lib%2Fshipping.test.ts');
    });

    testWidgets('absent without a finding', (tester) async {
      await pumpVerify(tester, redDetail(tamper: false));
      expect(find.text('TAMPER ALARM'), findsNothing);
    });

    testWidgets('also on a starred green', (tester) async {
      await pumpVerify(tester, greenDetail(tamper: [removedTest]));
      expect(find.text('TAMPER ALARM'), findsOneWidget);
      expect(word(tester), 'GREEN*');
    });

    testWidgets('merged has nothing left to restore', (tester) async {
      await pumpVerify(
        tester,
        verifyDetail(
          WorkspaceStatus.merged,
          run: greenRun(tamper: [removedTest]),
          pr: 232,
        ),
      );
      expect(find.byKey(const ValueKey('tamper-see')), findsOneWidget);
      expect(find.byKey(const ValueKey('tamper-restore')), findsNothing);
    });
  });

  group('needs your eyes', () {
    testWidgets(
      'a possible secret is a red-labelled row on a green that stays green',
      (tester) async {
        await pumpVerify(
          tester,
          verifyDetail(
            WorkspaceStatus.gateGreen,
            run: greenRun(
              unchecked: [
                secretRow('lib/config.ts', 3),
                untestedRow('lib/rates.ts', 2),
              ],
            ),
            cells: cells(594),
          ),
        );
        expect(word(tester), 'GREEN');
        final label = find.text('POSSIBLE SECRET');
        expect(label, findsOneWidget);
        expect(tester.widget<Text>(label).style?.color, HaroTokens.fail);
        expect(find.text('Advisory · never blocks the merge'), findsOneWidget);
      },
    );

    testWidgets('rows show kind, path and detail', (tester) async {
      await pumpVerify(tester, greenDetail());
      expect(find.text('NO TEST RAN'), findsWidgets);
      expect(find.text('lib/rates.ts'), findsWidgets);
      expect(find.text('2 added lines never executed'), findsOneWidget);
      expect(find.text('2 open'), findsOneWidget);
    });

    testWidgets('failures read FAILED in red', (tester) async {
      await pumpVerify(tester, redDetail(tamper: false));
      final kind = tester.widget<Text>(find.text('FAILED').first);
      expect(kind.style?.color, HaroTokens.fail);
      expect(
        find.text('expected 0, received 499 · lib/shipping.test.ts'),
        findsWidgets,
      );
    });

    testWidgets('a persisted tick drops the row to 45%, after the open ones', (
      tester,
    ) async {
      await pumpVerify(tester, greenDetail(checked: [untestedKey]));
      expect(rowOpacity(tester, untestedKey), .45);
      expect(rowOpacity(tester, 'untested_lines:lib/zones.ts:1'), 1);
      expect(find.text('1 open'), findsOneWidget);
      expect(find.text('Send 1 to agent'), findsOneWidget);
      final open = tester.getTopLeft(
        find.byKey(const ValueKey('look-row-untested_lines:lib/zones.ts:1')),
      );
      final ticked = tester.getTopLeft(
        find.byKey(const ValueKey('look-row-$untestedKey')),
      );
      expect(open.dy, lessThan(ticked.dy));
    });

    testWidgets('ticking a code-to-check row persists it', (tester) async {
      final rig = await pumpVerify(tester, greenDetail());
      await tapKey(tester, 'look-check-$untestedKey');
      expect(rig.calls, ['toggle:$untestedKey:true']);
    });

    testWidgets('ticking a failing test is local and updates the count', (
      tester,
    ) async {
      final rig = await pumpVerify(tester, redDetail());
      expect(find.text('Send 4 to agent'), findsOneWidget);
      await tapKey(tester, 'look-check-$failedKey');
      expect(rowOpacity(tester, failedKey), .45);
      expect(find.text('Send 3 to agent'), findsOneWidget);
      expect(find.text('3 open'), findsOneWidget);
      expect(rig.calls, isEmpty);
      await tapKey(tester, 'look-check-$failedKey');
      expect(rowOpacity(tester, failedKey), 1);
      expect(find.text('Send 4 to agent'), findsOneWidget);
    });

    testWidgets('Send N sends every open item as one prompt', (tester) async {
      final rig = await pumpVerify(tester, greenDetail());
      await tapKey(tester, 'look-send');
      expect(rig.calls, ['send:2']);
      expect(rig.prompts, hasLength(1));
      expect(rig.prompts.single, contains('Address these 2 gate findings'));
      expect(rig.prompts.single, contains('lib/rates.ts'));
      expect(rig.prompts.single, contains('lib/zones.ts'));
      expect(location(rig.router!), '/w/ws_1/agent');
    });

    testWidgets('Send N leaves ticked rows out', (tester) async {
      final rig = await pumpVerify(tester, greenDetail(checked: [untestedKey]));
      await tapKey(tester, 'look-send');
      expect(rig.calls, ['send:1']);
      expect(rig.prompts.single, isNot(contains('lib/rates.ts')));
    });

    testWidgets('Ask agent sends just that row', (tester) async {
      final rig = await pumpVerify(tester, greenDetail());
      await tapKey(tester, 'look-ask-$untestedKey');
      expect(rig.calls, ['send:1']);
      expect(rig.prompts.single, contains('Address this gate finding'));
    });

    testWidgets('Add to backlog reports how many landed', (tester) async {
      final rig = await pumpVerify(tester, greenDetail());
      await tapKey(tester, 'look-backlog');
      expect(rig.calls, ['backlog:2']);
      expect(find.text('Added 2 to backlog'), findsOneWidget);
    });

    testWidgets('Open diff goes to the code step at the file', (tester) async {
      final rig = await pumpVerify(tester, greenDetail());
      await tapKey(tester, 'look-open-$untestedKey');
      expect(location(rig.router!), '/w/ws_1/code?file=lib%2Frates.ts');
    });

    testWidgets(
      'secret_found rows: red POSSIBLE SECRET label, advisory, actions',
      (tester) async {
        const secretKey = 'secret_found:src/config.ts:12:aws-access-token';
        final rig = await pumpVerify(
          tester,
          verifyDetail(
            WorkspaceStatus.gateGreen,
            run: greenRun(
              unchecked: [
                secretRow('src/config.ts', 12),
                untestedRow('lib/rates.ts', 2),
              ],
            ),
            cells: cells(594),
          ),
        );
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('look-row-$secretKey')),
            matching: find.text('POSSIBLE SECRET'),
          ),
        );
        expect(label.style?.color, HaroTokens.fail);
        final untestedLabel = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('look-row-$untestedKey')),
            matching: find.text('NO TEST RAN'),
          ),
        );
        expect(untestedLabel.style?.color, isNot(HaroTokens.fail));
        expect(find.text('src/config.ts:12'), findsOneWidget);
        expect(
          find.text('possible credential · aws-access-token'),
          findsOneWidget,
        );
        expect(find.text('Advisory · never blocks the merge'), findsOneWidget);
        expect(find.text('2 open'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('look-editor-$secretKey')),
          findsOneWidget,
        );
        await tapKey(tester, 'look-open-$secretKey');
        expect(
          location(rig.router!),
          '/w/ws_1/code?file=src%2Fconfig.ts&line=12',
        );
      },
    );

    testWidgets('a failing test opens at the change blame points to', (
      tester,
    ) async {
      final rig = await pumpVerify(
        tester,
        redDetail(tamper: false),
        blame: const BlameResponse(
          baseRef: 'main',
          supported: true,
          entries: [
            BlameEntry(
              file: 'lib/shipping.test.ts',
              name: 'calculateShipping › case 0',
              hunks: [BlameHunk(file: 'lib/shipping.ts', line: 41)],
            ),
          ],
        ),
      );
      await tapKey(tester, 'look-open-$failedKey');
      expect(
        location(rig.router!),
        '/w/ws_1/code?file=lib%2Fshipping.ts&line=41',
      );
    });

    testWidgets('empty green says nothing was flagged', (tester) async {
      await pumpVerify(
        tester,
        verifyDetail(
          WorkspaceStatus.gateGreen,
          run: greenRun(),
          cells: cells(3),
        ),
      );
      expect(find.text('Nothing flagged on this run.'), findsOneWidget);
      expect(find.byKey(const ValueKey('look-send')), findsNothing);
    });
  });

  group('evidence', () {
    testWidgets('mutation is open by default, the rest are closed', (
      tester,
    ) async {
      await pumpVerify(tester, greenDetail());
      expect(find.byKey(const ValueKey('evidence-body-mut')), findsOneWidget);
      for (final k in ['untested', 'grid', 'impact', 'cov', 'flaky']) {
        expect(
          find.byKey(ValueKey('evidence-body-$k')),
          findsNothing,
          reason: k,
        );
      }
      expect(
        find.text('Can you trust green? Start with the first two.'),
        findsOneWidget,
      );
    });

    testWidgets('the first two names are full ink, the rest dimmer', (
      tester,
    ) async {
      await pumpVerify(tester, greenDetail());
      Color? color(String name) =>
          tester.widget<Text>(find.text(name)).style?.color;
      expect(color('Mutation score'), HaroTokens.ink);
      expect(color('Lines no test ran'), HaroTokens.ink);
      for (final n in ['Test grid', 'Impact', 'Coverage', 'Flaky tests']) {
        expect(color(n), HaroTokens.ink66, reason: n);
      }
    });

    testWidgets('rows open and close', (tester) async {
      await pumpVerify(tester, greenDetail());
      await tapKey(tester, 'evidence-head-cov');
      expect(find.byKey(const ValueKey('evidence-body-cov')), findsOneWidget);
      await tapKey(tester, 'evidence-head-cov');
      expect(find.byKey(const ValueKey('evidence-body-cov')), findsNothing);
      await tapKey(tester, 'evidence-head-mut');
      expect(find.byKey(const ValueKey('evidence-body-mut')), findsNothing);
    });

    testWidgets('mutation, coverage and flaky never start on their own', (
      tester,
    ) async {
      final rig = await pumpVerify(tester, greenDetail());
      for (final k in ['untested', 'grid', 'impact', 'cov', 'flaky']) {
        await tapKey(tester, 'evidence-head-$k');
      }
      expect(rig.calls, isEmpty);
      expect(find.byKey(const ValueKey('run-mutation')), findsOneWidget);
      expect(find.byKey(const ValueKey('measure-coverage')), findsOneWidget);
      expect(find.byKey(const ValueKey('check-flaky')), findsOneWidget);

      await tapKey(tester, 'run-mutation');
      await tapKey(tester, 'measure-coverage');
      await tapKey(tester, 'check-flaky');
      expect(rig.calls, ['runMutation', 'measureCoverage', 'checkFlaky']);
    });

    testWidgets('impact is only fetched once its row is opened', (
      tester,
    ) async {
      final rig = await pumpVerify(
        tester,
        greenDetail(),
        impact: sampleImpact(),
      );
      expect(rig.impactCalls, isEmpty);
      await tapKey(tester, 'evidence-head-impact');
      expect(rig.impactCalls, hasLength(1));
      expect(
        find.text('3 of 594 tests touch this change · 591 unaffected'),
        findsOneWidget,
      );
      expect(find.text('desktop/main.test.js · 2 tests'), findsOneWidget);
    });

    testWidgets('no button on a red gate, only the reason', (tester) async {
      await pumpVerify(tester, redDetail(tamper: false));
      expect(find.byKey(const ValueKey('run-mutation')), findsNothing);
      expect(find.text('Available once the gate is green.'), findsOneWidget);
    });

    testWidgets('mutation result: copy and survivors', (tester) async {
      final rig = await pumpVerify(
        tester,
        greenDetail(analysis: WorkspaceAnalysis(mutation: sampleMutation())),
      );
      expect(
        find.textContaining(
          'haro made 50 small, deliberate mistakes in the changed lines. The suite caught 41. These survived:',
        ),
        findsOneWidget,
      );
      expect(find.text('main.js:206'), findsOneWidget);
      expect(find.text('|| → && went unnoticed'), findsOneWidget);
      expect(find.byKey(const ValueKey('run-mutation')), findsNothing);
      expect(find.text('82% · 41 of 50 mistakes caught'), findsOneWidget);
      expect(rig.calls, isEmpty);
    });

    testWidgets('two survivors on one line both render', (tester) async {
      await pumpVerify(
        tester,
        greenDetail(
          analysis: const WorkspaceAnalysis(
            mutation: MutationResponse(
              baseRef: 'main',
              supported: true,
              score: 60,
              killed: 3,
              survived: 2,
              survivors: [
                MutationSurvivor(
                  path: 'lib/shipping.ts',
                  line: 46,
                  operator: 'ceil → floor',
                ),
                MutationSurvivor(
                  path: 'lib/shipping.ts',
                  line: 46,
                  operator: '1 → 0',
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('shipping.ts:46'), findsNWidgets(2));
    });

    testWidgets('survivor opens the code step at its line', (tester) async {
      final rig = await pumpVerify(
        tester,
        greenDetail(analysis: WorkspaceAnalysis(mutation: sampleMutation())),
      );
      await tester.ensureVisible(find.text('main.js:231'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('main.js:231'));
      await tester.pumpAndSettle();
      expect(
        location(rig.router!),
        '/w/ws_1/code?file=desktop%2Fmain.js&line=231',
      );
    });

    testWidgets(
      'a mutation score cached by the backend shows without a click',
      (tester) async {
        final rig = await pumpVerify(
          tester,
          greenDetail(),
          receipt: const ReceiptResponse(
            receipt: Receipt(
              workspaceId: 'ws_1',
              mutation: ReceiptMutation(supported: true, ran: true, score: 71),
            ),
          ),
        );
        expect(find.byKey(const ValueKey('metric-mutation')), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('metric-mutation')))
              .data,
          '71%',
        );
        expect(find.byKey(const ValueKey('run-mutation')), findsNothing);
        expect(rig.calls, isEmpty);
      },
    );

    testWidgets('a running analysis says so and offers no second start', (
      tester,
    ) async {
      await pumpVerify(
        tester,
        greenDetail(
          analysis: const WorkspaceAnalysis(running: {AnalysisKind.mutation}),
        ),
      );
      expect(
        find.textContaining('haro is making small, deliberate mistakes'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('run-mutation')), findsNothing);
      expect(find.text('running…'), findsWidgets);
    });

    testWidgets('a failed analysis shows its error and lets you retry', (
      tester,
    ) async {
      await pumpVerify(
        tester,
        greenDetail(
          analysis: const WorkspaceAnalysis(
            errors: {AnalysisKind.mutation: 'agent is running'},
          ),
        ),
      );
      expect(find.text('agent is running'), findsOneWidget);
      expect(find.byKey(const ValueKey('run-mutation')), findsOneWidget);
    });

    testWidgets('coverage bars: main in ink, this tree in gate green', (
      tester,
    ) async {
      await pumpVerify(
        tester,
        greenDetail(
          analysis: WorkspaceAnalysis(
            coverage: CoverageResponse.fromJson({
              'supported': true,
              'base_ref': 'main',
              'current': {'lines': 91.2},
              'baseline': {'lines': 89.8},
              'delta': {'lines': 1.4},
            }),
          ),
        ),
      );
      await tapKey(tester, 'evidence-head-cov');
      expect(find.text('89.8%'), findsOneWidget);
      expect(find.text('91.2%'), findsOneWidget);
      expect(find.text('91.2% · up 1.4 from main'), findsOneWidget);
      final fills = tester
          .widgetList<ColoredBox>(
            find.descendant(
              of: find.byKey(const ValueKey('evidence-body-cov')),
              matching: find.byType(ColoredBox),
            ),
          )
          .map((c) => c.color);
      expect(fills, containsAll([HaroTokens.ink42, HaroTokens.gate]));
    });

    testWidgets('flaky: a stable result is one sentence', (tester) async {
      await pumpVerify(
        tester,
        greenDetail(
          analysis: const WorkspaceAnalysis(
            flaky: FlakyResponse(runs: 5, checked: 594),
          ),
        ),
      );
      await tapKey(tester, 'evidence-head-flaky');
      expect(
        find.textContaining(
          'Every test gave the same result across the last 5 runs',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('check-flaky')), findsNothing);
    });

    testWidgets('lines no test ran: file:line to code, click opens it', (
      tester,
    ) async {
      final rig = await pumpVerify(tester, greenDetail(), hunks: sampleHunks());
      expect(find.text('7 of 8 added lines'), findsOneWidget);
      await tapKey(tester, 'evidence-head-untested');
      expect(find.text('AgentStream.tsx:211'), findsOneWidget);
      expect(find.text("if (evt.kind === 'retry') return"), findsOneWidget);
      expect(
        find.text('5 added lines · no test imports this file'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('AgentStream.tsx:211'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AgentStream.tsx:211'));
      await tester.pumpAndSettle();
      expect(
        location(rig.router!),
        '/w/ws_1/code?file=frontend%2Fsrc%2Fcomponents%2FAgentStream.tsx&line=211',
      );
    });

    testWidgets('without a line map it says not measured', (tester) async {
      await pumpVerify(tester, greenDetail());
      expect(
        find.byKey(const ValueKey('evidence-meta-untested')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('evidence-meta-untested')))
            .data,
        'not measured',
      );
    });
  });

  group('test grid', () {
    testWidgets('up to 1000 tests are widgets', (tester) async {
      await pumpVerify(tester, greenDetail(cellList: cells(300)));
      await tapKey(tester, 'evidence-head-grid');
      expect(find.byKey(const ValueKey('test-grid-squares')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-grid-painter')), findsNothing);
    });

    testWidgets('above 1000 tests one painter draws them', (tester) async {
      await pumpVerify(tester, greenDetail(cellList: cells(1200)));
      await tapKey(tester, 'evidence-head-grid');
      expect(find.byKey(const ValueKey('test-grid-painter')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-grid-squares')), findsNothing);
      expect(tester.takeException(), isNull);
      // Hovering names the square under the pointer.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      final origin = tester.getTopLeft(
        find.byKey(const ValueKey('test-grid-painter')),
      );
      await gesture.moveTo(origin + const Offset(4, 4));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('test-grid-caption')))
            .data,
        'lib/shipping.test.ts · 3 tests',
      );
    });

    testWidgets('a running gate fills the tail with empty squares', (
      tester,
    ) async {
      await pumpVerify(
        tester,
        verifyDetail(
          WorkspaceStatus.testsRunning,
          run: greenRun(),
          cells: cells(30, running: 3),
          expectedTotal: 594,
        ),
      );
      await tapKey(tester, 'evidence-head-grid');
      final grid = find.byKey(const ValueKey('test-grid-squares'));
      final boxes = tester.widgetList<DecoratedBox>(
        find.descendant(of: grid, matching: find.byType(DecoratedBox)),
      );
      // 33 cells in 11 squares, plus the 561 not started in 187 empty ones.
      expect(boxes.length, 11 + 187);
      final hollow = boxes.where((b) {
        final d = b.decoration as BoxDecoration;
        return d.color == HaroTokens.transparent && d.border != null;
      });
      expect(hollow.length, 1);
    });
  });

  group('no overflow', () {
    final details = <String, WorkspaceDetail Function()>{
      'idle': () => verifyDetail(WorkspaceStatus.idle),
      'running': () => verifyDetail(
        WorkspaceStatus.testsRunning,
        run: greenRun(),
        cells: cells(200, running: 4),
        expectedTotal: 594,
      ),
      'red + tamper': redDetail,
      'green': () => greenDetail(
        tamper: [removedTest],
        analysis: WorkspaceAnalysis(mutation: sampleMutation()),
      ),
      'merged': () => verifyDetail(
        WorkspaceStatus.merged,
        run: greenRun(unchecked: [untestedRow('lib/rates.ts', 2)]),
        pr: 232,
      ),
    };
    for (final size in const [Size(900, 640), Size(1400, 900)]) {
      for (final e in details.entries) {
        testWidgets(
          '${e.key} at ${size.width.toInt()}x${size.height.toInt()} with the terminal open',
          (tester) async {
            await pumpVerify(
              tester,
              e.value(),
              size: size,
              hunks: sampleHunks(),
              impact: sampleImpact(),
              terminal: true,
            );
            for (final k in ['untested', 'grid', 'impact', 'cov', 'flaky']) {
              await tapKey(tester, 'evidence-head-$k');
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
