import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/look_at.dart';
import 'package:haro_app/state/review_items.dart';

import '../api/fixtures.dart';
import 'builders.dart';

void main() {
  group('deriveLookAt', () {
    test('fixed order: failures, code to check, tamper, flaky, coverage', () {
      final r = run(
        status: 'failed',
        failed: 1,
        passed: 593,
        unchecked: [untestedRow('lib/a.ts', 3)],
        tamper: [removedTest],
        overrides: {
          'flaky_tests': ['flaky one'],
          'coverage_note': 'coverage fell 1.2%',
        },
        cases: [caseJson('boom', 'failed', message: 'nope')],
      );
      final la = deriveLookAt(run: r);
      expect(la.pending.map((i) => i.kind), [
        LookAtKind.failedTest,
        LookAtKind.codeToCheck,
        LookAtKind.tamper,
        LookAtKind.flaky,
        LookAtKind.coverage,
      ]);
      expect(la.pending.map((i) => i.label), [
        'FAILED',
        'NO TEST RAN',
        'TEST REMOVED',
        'FLAKY',
        'COVERAGE DROP',
      ]);
    });

    test(
      'failure rows carry test name, file, first message line and blocking',
      () {
        final la = deriveLookAt(run: redRun(failed: 1));
        final item = la.pending.first;
        expect(item.isFailure, isTrue);
        expect(item.blocking, isTrue);
        expect(item.title, 'case 0');
        expect(item.file, 'lib/shipping.test.ts');
        expect(item.detail, 'expected 0, received 499');
        expect(item.glyph, '✕');
        expect(item.shortFile, 'shipping.test.ts');
      },
    );

    test('advisory items are not blocking and use the hollow glyph', () {
      final la = deriveLookAt(
        run: run(unchecked: [untestedRow('lib/a.ts', 3)]),
      );
      final item = la.pending.single;
      expect(item.blocking, isFalse);
      expect(item.glyph, '○');
      expect(item.count, 3);
      expect(item.rawKind, 'untested_lines');
      expect(la.blockingCount, 0);
    });

    test(
      'secret_found rows are advisory, red-labelled data, and carry file:line',
      () {
        final la = deriveLookAt(
          run: run(
            unchecked: [
              secretRow('src/config.ts', 12),
              untestedRow('lib/a.ts', 3),
            ],
          ),
        );
        expect(la.openCount, 2);
        final s = la.pending.first;
        expect(s.label, 'POSSIBLE SECRET');
        expect(s.isSecret, isTrue);
        expect(s.blocking, isFalse);
        expect(s.title, 'src/config.ts:12');
        expect(s.file, 'src/config.ts');
        expect(s.line, 12);
        expect(s.detail, 'possible credential · aws-access-token');
        expect(la.blockingCount, 0);
        expect(la.pending.last.isSecret, isFalse);
      },
    );

    test(
      'secret_found survives code_to_check being off, other rows do not',
      () {
        final la = deriveLookAt(
          run: run(
            unchecked: [secretRow('a.env', 1), untestedRow('lib/a.ts', 3)],
          ),
          codeToCheckEnabled: false,
        );
        expect(la.pending.map((i) => i.rawKind), ['secret_found']);
      },
    );

    test('a ticked secret_found row moves to done', () {
      final row = secretRow('a.env', 1);
      final la = deriveLookAt(
        run: run(unchecked: [row]),
        checkedKeys: [row['key'] as String],
      );
      expect(la.pending, isEmpty);
      expect(la.done.single.isSecret, isTrue);
    });

    test('no test imports label', () {
      final la = deriveLookAt(
        run: run(
          unchecked: [
            {
              'kind': 'no_test_file',
              'file': 'lib/new.ts',
              'detail': '5 added lines',
              'count': 5,
              'key': 'k',
            },
          ],
        ),
      );
      expect(la.pending.single.label, 'NO TEST IMPORTS');
    });

    test('ticked-off code-to-check rows move to done and leave the count', () {
      final rows = [untestedRow('lib/a.ts', 3), untestedRow('lib/b.ts', 1)];
      final la = deriveLookAt(
        run: run(unchecked: rows),
        checkedKeys: [rows[0]['key'] as String],
      );
      expect(la.openCount, 1);
      expect(la.done.single.file, 'lib/a.ts');
    });

    test('code to check is skipped when the project turns it off', () {
      final la = deriveLookAt(
        run: run(unchecked: [untestedRow('lib/a.ts', 3)]),
        codeToCheckEnabled: false,
      );
      expect(la.openCount, 0);
    });

    test(
      'a null unchecked list (pass never ran) yields no rows, not clean',
      () {
        final la = deriveLookAt(run: run(unchecked: null));
        expect(la.openCount, 0);
      },
    );

    test('a running run and a gate error produce nothing', () {
      expect(
        deriveLookAt(run: run(status: 'running', unchecked: null)).openCount,
        0,
      );
      expect(
        deriveLookAt(
          run: run(
            status: 'error',
            unchecked: null,
            cases: [caseJson('x', 'failed')],
          ),
        ).openCount,
        0,
      );
      expect(deriveLookAt().openCount, 0);
    });

    test('live cells win over stored cases', () {
      final la = deriveLookAt(
        run: redRun(failed: 1),
        cells: [
          Cell.fromJson(cellJson('live', 'failed', message: 'live failure')),
        ],
      );
      expect(la.pending.single.detail, 'live failure');
    });

    test('rail shows at most three items', () {
      final la = deriveLookAt(run: redRun(failed: 5));
      expect(la.openCount, 5);
      expect(la.railItems, hasLength(3));
    });

    test('tamper blocked flips the tamper item to blocking', () {
      final la = deriveLookAt(
        run: run(tamper: [removedTest], overrides: {'tamper_blocked': true}),
      );
      expect(la.pending.single.blocking, isTrue);
    });

    test('tamper labels for the other kinds', () {
      String label(String kind) => deriveLookAt(
        run: run(
          tamper: [
            {'kind': kind, 'file': 'a.test.ts', 'detail': 'd', 'test': null},
          ],
        ),
      ).pending.single.label;
      expect(label('skip'), 'TEST SKIPPED');
      expect(label('only'), 'TEST .ONLY ADDED');
      expect(label('assertions'), 'ASSERTIONS REMOVED');
      expect(label('xfail'), 'TEST MARKED XFAIL');
      expect(label('weakened'), 'ASSERTION WEAKENED');
      expect(label('timeout'), 'TIMEOUT WIDENED');
      expect(label('mystery'), 'MYSTERY');
    });
  });

  group('deriveUncheckedState', () {
    test('every honest state', () {
      expect(deriveUncheckedState(enabled: false), isA<UncheckedOff>());
      expect(deriveUncheckedState(enabled: true), isA<UncheckedUnmeasured>());
      expect(
        deriveUncheckedState(enabled: true, status: TestRunStatus.running),
        isA<UncheckedUnmeasured>(),
      );

      final red = deriveUncheckedState(
        enabled: true,
        status: TestRunStatus.failed,
      ) as UncheckedUnmeasured;
      expect(red.reason, contains('gate is red'));
      final impacted = deriveUncheckedState(
        enabled: true,
        status: TestRunStatus.passed,
        scope: TestScope.impacted,
      ) as UncheckedUnmeasured;
      expect(impacted.reason, contains('impacted-only'));
      final generic = deriveUncheckedState(
        enabled: true,
        status: TestRunStatus.passed,
      ) as UncheckedUnmeasured;
      expect(generic.reason, 'this run did not measure the diff');

      final clean = deriveUncheckedState(
        enabled: true,
        rows: const [],
        coveredFiles: 4,
        status: TestRunStatus.passed,
      );
      expect((clean as UncheckedClean).files, 4);

      expect(
        deriveUncheckedState(
          enabled: true,
          rows: const [],
          coveredFiles: 0,
          status: TestRunStatus.passed,
        ),
        isA<UncheckedQuiet>(),
      );
      expect(
        deriveUncheckedState(
          enabled: true,
          rows: const [],
          coveredFiles: null,
          status: TestRunStatus.passed,
        ),
        isA<UncheckedQuiet>(),
      );
    });

    test('rows state carries the blind-coverage caveat', () {
      final s = deriveUncheckedState(
        enabled: true,
        rows: [UncheckedRow.fromJson(untestedRow('a.ts', 1))],
        coveredFiles: 0,
        status: TestRunStatus.passed,
      ) as UncheckedRows;
      expect(s.coverage, contains('executed none of the changed files'));
    });
  });

  group('review items and the follow-up prompt', () {
    test('failures, tamper and unchecked build sendable asks', () {
      final failure = failureReviewItem(
        Cell.fromJson(cellJson('c', 'failed', message: 'expected 1')),
      );
      expect(failure.target, 'test: test c');
      expect(failure.context, 'expected 1');
      expect(failure.text, contains('without weakening it'));

      final tamper = tamperReviewItem(TamperFinding.fromJson(removedTest));
      expect(tamper.target, 'removed: is free at exactly the \$100 boundary');
      expect(tamper.text, startsWith('restore this deleted test'));
      expect(tamper.context, 'test deleted · lib/shipping.test.ts');

      final unchecked = uncheckedReviewItem(
        UncheckedRow.fromJson(untestedRow('lib/rates.ts', 2)),
      );
      expect(unchecked.target, 'no test ran: rates.ts');
    });

    test('unknown kinds fall through to generic wording', () {
      expect(tamperKindLabel('future'), 'future');
      expect(tamperKindLabel('xfail'), 'xfail');
      expect(tamperKindLabel('weakened'), 'weakened');
      expect(tamperKindLabel('timeout'), 'timeout');
      expect(tamperFixHint('xfail'), contains('xfail'));
      expect(tamperFixHint('weakened'), contains('stricter assertion'));
      expect(tamperFixHint('timeout'), contains('timeout'));
      expect(tamperFixHint('future'), contains('restore this weakened test'));
      expect(uncheckedKindLabel('future'), 'future');
      expect(uncheckedFixHint('future'), contains('nothing checked it'));
    });

    test('buildFollowUpPrompt numbers items and skips empty context', () {
      final prompt = buildFollowUpPrompt([
        const ReviewItem(target: 'a.ts', context: 'ctx', text: 'do a'),
        const ReviewItem(target: 'b.ts', text: 'do b'),
      ]);
      expect(prompt, '''Address these 2 gate findings:

1. a.ts
   ctx
   do a

2. b.ts
   do b''');
      expect(
        buildFollowUpPrompt([const ReviewItem(target: 'x', text: 'y')]),
        startsWith('Address this gate finding:'),
      );
    });

    test('tamperCountSummary prefers the backend note', () {
      expect(
        tamperCountSummary(3, '2 removed · 1 skipped'),
        '2 removed · 1 skipped',
      );
      expect(tamperCountSummary(1, null), '1 suspicious test change');
      expect(tamperCountSummary(2, ''), '2 suspicious test changes');
    });

    test('gateErrorFraming', () {
      expect(
        gateErrorFraming(GateErrorKind.noTests).title,
        'The gate ran, but found no tests',
      );
      expect(gateErrorFraming(null).title, 'The gate crashed');
      expect(
        gateErrorFraming(GateErrorKind.setup, adopted: true).title,
        'Environment, not code',
      );
    });
  });
}
