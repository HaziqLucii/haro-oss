import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/gate_facts.dart';
import 'package:haro_app/state/review_items.dart';
import 'package:haro_app/state/test_first.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../api/fixtures.dart';
import 'builders.dart';

TestFirstState tf(
  String phase, {
  int cases = 2,
  String? reason,
  double? approvedAt,
}) => TestFirstState.fromJson({
  'phase': phase,
  'task': 'add a shipping calculator',
  'reject_reason': reason,
  'files': [
    {
      'path': 'tests/test_ship.py',
      'file': 'tests/test_ship.py',
      'sha256': 'ab',
    },
  ],
  'cases': [
    for (var i = 0; i < cases; i++)
      {
        'file': 'tests/test_ship.py',
        'name': 'case $i',
        'message': 'expected 499',
      },
  ],
  'approved_at': approvedAt,
  'rounds': 1,
});

WorkspaceFlow flowOf(TestFirstState state, {WorkspaceStatus? status}) =>
    deriveWorkspaceFlow(
      input(
        status ?? WorkspaceStatus.idle,
        testFirst: state,
        agent: AgentPhase.done,
      ),
    );

void main() {
  group('parsing', () {
    test(
      'a workspace carries its test-first state, an ordinary one has none',
      () {
        final ws = Workspace.fromJson({
          ...workspaceJson(),
          'test_first': {'phase': 'review', 'task': 't'},
        });
        expect(ws.testFirst!.phase, TestFirstPhase.review);
        expect(Workspace.fromJson(workspaceJson()).testFirst, isNull);
      },
    );

    test('an unknown phase does not crash the client', () {
      expect(TestFirstPhase.parse('someday'), TestFirstPhase.unknown);
    });

    test('a status event carries the state to the workspace copy', () {
      final ws = Workspace.fromJson(workspaceJson());
      final next = ws.copyWith(testFirst: tf('review'));
      expect(next.testFirst!.cases, hasLength(2));
      expect(next.copyWith(status: WorkspaceStatus.idle).testFirst, isNotNull);
    });

    test('a gate run carries the acceptance check and its block flag', () {
      final r = run(
        overrides: {
          'acceptance': {
            'approved_at': 1790000000.0,
            'total': 2,
            'passing': 2,
            'ok': true,
          },
          'acceptance_blocked': false,
        },
      );
      expect(r.acceptance!.passing, 2);
      expect(r.acceptanceBlocked, isFalse);
      expect(run().acceptance, isNull);
    });
  });

  group('flow states', () {
    test(
      'a proven-red test awaits approval: needs you, Review acceptance test',
      () {
        final f = flowOf(tf('review'));
        expect(f.displayState, DisplayState.plan);
        expect(f.triageGroup, TriageGroup.needsYou);
        expect(f.acceptanceReview, isTrue);
        expect(f.nextAction.kind, NextActionKind.reviewAcceptance);
        expect(f.nextAction.label, 'Review acceptance test');
        expect(f.nextAction.step, StepKey.agent);
        expect(f.step(StepKey.agent).line, 'test ready');
        expect(f.rowDetail, 'Acceptance test ready to approve · 2 red on base');
        expect(f.rowAction, 'Review acceptance test');
        expect(f.defaultStep, StepKey.agent);
      },
    );

    test('a rejected draft is needs you with a redraft action', () {
      final f = flowOf(
        tf(
          'rejected',
          reason: '1 of 1 drafted test(s) already pass on base (x): they do not pin it.',
        ),
      );
      expect(f.triageGroup, TriageGroup.needsYou);
      expect(f.nextAction.label, 'Redraft acceptance test');
      expect(f.step(StepKey.agent).line, 'test rejected');
      expect(
        f.rowDetail,
        startsWith('Acceptance draft rejected · 1 of 1 drafted'),
      );
    });

    test('drafting is running, the agent step says so', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.agentRunning,
          testFirst: tf('drafting'),
          agent: AgentPhase.running,
          elapsed: const Duration(minutes: 2),
        ),
      );
      expect(f.triageGroup, TriageGroup.running);
      expect(f.acceptanceReview, isFalse);
      expect(f.step(StepKey.agent).line, 'drafting test · 2m');
      expect(f.rowDetail, 'Agent drafting the acceptance test');
    });

    test('proving red is running with a disabled next action', () {
      final f = deriveWorkspaceFlow(
        input(
          WorkspaceStatus.agentRunning,
          testFirst: tf('proving'),
          agent: AgentPhase.running,
        ),
      );
      expect(f.triageGroup, TriageGroup.running);
      expect(f.nextAction.kind, NextActionKind.agentRunning);
      expect(f.nextAction.label, 'Proving test');
      expect(f.nextAction.enabled, isFalse);
      expect(f.step(StepKey.agent).line, 'proving test is red');
      expect(f.rowDetail, 'Proving the acceptance test fails on base');
    });

    test('an approved test leaves the normal flow untouched', () {
      final f = flowOf(tf('approved', approvedAt: 1790000000.0));
      expect(f.displayState, DisplayState.idle);
      expect(f.acceptanceReview, isFalse);
      expect(f.nextAction.kind, isNot(NextActionKind.reviewAcceptance));
    });

    test('an ordinary workspace is unaffected', () {
      final f = deriveWorkspaceFlow(input(WorkspaceStatus.idle));
      expect(f.acceptanceReview, isFalse);
      expect(f.displayState, DisplayState.idle);
    });
  });

  group('gate side', () {
    TestRun broken({bool changed = true}) => run(
      status: 'passed',
      overrides: {
        'acceptance_blocked': true,
        'acceptance': {
          'approved_at': 1790000000.0,
          'total': 1,
          'passing': changed ? 1 : 0,
          'changed': changed ? ['tests/test_ship.py'] : [],
          'missing': changed ? [] : ['case 0'],
          'ok': false,
        },
      },
      tamper: [
        {
          'kind': changed ? 'acceptance_changed' : 'acceptance_missing',
          'file': 'tests/test_ship.py',
          'detail': 'x',
        },
      ],
    );

    test(
      'a changed acceptance file is a blocker even when every test passes',
      () {
        final facts = GateFacts.fromRun(broken());
        final blockers = deriveBlockers(facts);
        expect(blockers.first.kind, BlockerKind.acceptanceBroken);
        expect(blockers.first.text, contains('changed after approval'));
        expect(blockers.first.fix, FixAction.restoreTests);
      },
    );

    test('a missing acceptance test blocks and names the test', () {
      final blockers = deriveBlockers(
        GateFacts.fromRun(broken(changed: false)),
      );
      expect(blockers.first.text, contains('missing from the run (case 0)'));
    });

    test(
      'the red verdict says the contract broke, not that the suite is weak',
      () {
        final flow = deriveWorkspaceFlow(
          input(WorkspaceStatus.gateRed, run: broken()),
        );
        expect(flow.verdict.headline, 'The acceptance test isn’t intact');
        expect(flow.verdict.rail, 'acceptance test');
        expect(flow.nextAction.kind, NextActionKind.restoreTests);
        expect(flow.tamper!.headline, contains('acceptance test changed'));
      },
    );

    test('the restore instruction for an acceptance finding is specific', () {
      expect(
        tamperFixHint('acceptance_changed'),
        contains('exactly as approved'),
      );
      expect(tamperKindLabel('acceptance_missing'), 'acceptance missing');
    });
  });

  group('receipt line', () {
    test('intact reads N/N passing, unchanged', () {
      final line = acceptanceReceiptLine(
        const AcceptanceCheck(
          approvedAt: 1790000000.0,
          total: 2,
          passing: 2,
          ok: true,
        ),
      )!;
      expect(line, startsWith('Acceptance test (approved '));
      expect(line, endsWith('): 2/2 passing, unchanged.'));
    });

    test('broken names what is wrong', () {
      final line = acceptanceReceiptLine(
        const AcceptanceCheck(
          total: 2,
          passing: 1,
          changed: ['a.py'],
          failing: ['c1'],
        ),
      )!;
      expect(line, contains('1/2 passing, file changed: a.py; failing: c1.'));
    });

    test(
      'no check, no line',
      () => expect(acceptanceReceiptLine(null), isNull),
    );
  });

  group('state word', () {
    test('acceptance review reads test, not plan', () {
      expect(flowOf(tf('review')).stateWord, 'test');
      expect(flowOf(tf('rejected')).stateWord, 'test');
      expect(
        deriveWorkspaceFlow(input(WorkspaceStatus.idle)).stateWord,
        'idle',
      );
      expect(
        deriveWorkspaceFlow(input(WorkspaceStatus.idle, planReady: true))
            .stateWord,
        'plan',
      );
    });
  });

  group('helpers', () {
    test('red proof headline counts', () {
      expect(
        redProofHeadline(tf('review', cases: 1)),
        '1 test, failing on base',
      );
      expect(
        redProofHeadline(tf('review', cases: 3)),
        '3 tests, every one failing on base',
      );
    });

    test('short reject reason is the first sentence', () {
      expect(
        shortRejectReason('No tests were collected. Ask again.'),
        'No tests were collected',
      );
      expect(shortRejectReason(null), 'the draft was rejected');
    });

    test('draft lines are read from the diff for the drafted files only', () {
      const diff = '''
diff --git a/tests/test_ship.py b/tests/test_ship.py
new file mode 100644
--- /dev/null
+++ b/tests/test_ship.py
@@ -0,0 +1,2 @@
+def test_a():
+    assert ship(1) == 0
diff --git a/src/x.py b/src/x.py
--- a/src/x.py
+++ b/src/x.py
@@ -1 +1 @@
-old
+new
''';
      final lines = acceptanceDiffLines(diff, tf('review').files);
      expect(lines['tests/test_ship.py'], [
        'def test_a():',
        '    assert ship(1) == 0',
      ]);
      expect(lines.containsKey('src/x.py'), isFalse);
    });

    test('a file the diff has not shown yet maps to no lines', () {
      expect(
        acceptanceDiffLines('', tf('review').files)['tests/test_ship.py'],
        isEmpty,
      );
    });
  });
}
