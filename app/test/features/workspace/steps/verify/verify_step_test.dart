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
  List<Map<String, dynamic>> tamper = const [],
}) => verifyDetail(
  WorkspaceStatus.gateGreen,
  run: greenRun(
    unchecked: [untestedRow('lib/rates.ts', 2), untestedRow('lib/zones.ts', 1)],
    tamper: tamper,
  ),
  cells: cellList ?? cells(594),
  checked: checked,
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
  BlameResponse? blame,
  bool terminal = false,
}) async {
  final rig = VerifyRig(
    previewOf(d.workspace!.status),
    state: d,
    hunks: hunks,
    receipt: receipt,
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
      expect(find.text('after run'), findsNWidgets(2));
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
      expect(inStep(find.text('NEEDS YOUR REVIEW')), findsOneWidget);
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
      // Proceed to ship waits for every file to be viewed, so it is not pressable yet.
      'green: files not viewed': (greenDetail(), 0),
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

  group('needs your review', () {
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
      'green': () => greenDetail(tamper: [removedTest]),
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
              terminal: true,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
