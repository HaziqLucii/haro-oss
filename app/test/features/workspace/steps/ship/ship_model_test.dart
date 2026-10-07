import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/ship/ship_model.dart';
import 'package:haro_app/theme/tokens.dart';

import '../../../../api/fixtures.dart' show workspaceJson;
import 'ship_harness.dart';

ShipModel model(Preview p, {GitStatusResponse? git, PrStatusResponse? pr}) {
  final d = detailFor(p);
  return deriveShip(
    workspace: d.workspace!,
    flow: d.flow!,
    git: git ?? gitStatus(),
    pr: pr ?? noPr(),
  );
}

void main() {
  group('deriveShip', () {
    test(
      'green with work to ship is ready and tinted with the gate colour',
      () {
        final m = model(Preview.green);
        expect(m.phase, ShipPhase.ready);
        expect(m.title, 'Gate is green. Ready to merge.');
        expect(m.sub, '2 items to look at · won’t block the merge');
        expect(m.dot, HaroTokens.gate);
        expect(m.baseShort, 'main');
      },
    );

    test('red names the first blocker and points at verify', () {
      final m = model(Preview.red);
      expect(m.phase, ShipPhase.gateBlocked);
      expect(m.title, 'Merging is blocked');
      expect(m.sub, contains('3 failing tests.'));
      expect(m.sub, contains('The gate must be green'));
      expect(m.showGoVerify, isTrue);
      expect(m.dot, HaroTokens.fail);
    });

    test('idle and running are blocked by the gate, not by git', () {
      final idle = model(Preview.idle);
      expect(idle.phase, ShipPhase.gateBlocked);
      expect(idle.sub, 'The gate hasn’t passed on this tree yet.');
      final running = model(Preview.running);
      expect(running.phase, ShipPhase.gateBlocked);
      expect(running.sub, contains('still running'));
      expect(running.dot, isNot(HaroTokens.gate));
    });

    test(
      'a green gate can still be unshippable: dirty, conflict, nothing ahead',
      () {
        final dirty = model(Preview.green, git: gitStatus(dirty: 3));
        expect(dirty.phase, ShipPhase.cannotShip);
        expect(
          dirty.sub,
          '3 uncommitted changes. Commit them before you ship.',
        );
        expect(dirty.showGoVerify, isFalse);

        final conflict = model(
          Preview.green,
          pr: openPr(mergeable: 'CONFLICTING'),
        );
        expect(conflict.phase, ShipPhase.cannotShip);
        expect(conflict.sub, contains('merge conflicts'));

        final none = model(Preview.green, git: gitStatus(ahead: 0));
        expect(none.phase, ShipPhase.cannotShip);
        expect(none.sub, contains('Nothing to merge'));

        final gone = model(
          Preview.green,
          git: gitStatus(worktreeMissing: true),
        );
        expect(gone.phase, ShipPhase.cannotShip);

        final d = detailFor(Preview.green);
        final unknown = deriveShip(workspace: d.workspace!, flow: d.flow!);
        expect(unknown.phase, ShipPhase.cannotShip);
        expect(unknown.sub, 'Checking the working tree.');
      },
    );

    test(
      'merged says where it landed, with the PR number when there is one',
      () {
        final withPr = model(Preview.merged, pr: openPr(merged: true));
        expect(withPr.phase, ShipPhase.merged);
        expect(withPr.title, 'Merged into origin/main as #232');
        expect(withPr.dot, HaroTokens.merged);
        expect(withPr.hasPr, isTrue);

        final local = model(Preview.merged);
        expect(local.title, 'Merged into origin/main');
        expect(local.hasPr, isFalse);
      },
    );

    test('merge_mode decides which actions exist', () {
      final both = model(Preview.green, pr: noPr());
      expect(both.showPr && both.showMerge, isTrue);

      final prOnly = model(Preview.green, git: gitStatus(mergeMode: 'pr'));
      expect(prOnly.showPr, isTrue);
      expect(prOnly.showMerge, isFalse);

      final mergeOnly = model(
        Preview.green,
        git: gitStatus(mergeMode: 'merge'),
      );
      expect(mergeOnly.showPr, isFalse);
      expect(mergeOnly.showMerge, isTrue);

      final noRemote = model(
        Preview.green,
        git: gitStatus(mergeMode: 'pr'),
        pr: noPr(supported: false),
      );
      expect(noRemote.showPr, isFalse);
      expect(noRemote.showMerge, isTrue);
    });
  });

  group('title and summary', () {
    test(
      'title: PR, else newest commit on a branch with work, else the name',
      () {
        final d = detailFor(Preview.green);
        final ws = d.workspace!;
        expect(
          deriveShipTitle(workspace: ws, pr: openPr(), git: gitStatus()),
          'perf(desktop): stable port, async PATH scrape, lazy panels',
        );
        expect(
          deriveShipTitle(
            workspace: ws,
            pr: noPr(),
            git: gitStatus(),
            commits: const [commitA],
          ),
          'perf(desktop): stable port, async PATH scrape…',
        );
        expect(
          deriveShipTitle(
            workspace: ws,
            git: gitStatus(ahead: 0),
            commits: const [commitA],
          ),
          'electron optimization',
        );
        const follow = GitCommit(
          sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          short: 'bbbbbbb',
          author: 'HaziqLucii',
          when: '2 minutes ago',
          subject: 'test: cover the new branch',
          own: true,
        );
        expect(
          deriveShipTitle(
            workspace: ws,
            git: gitStatus(ahead: 2),
            commits: const [follow, commitA],
          ),
          'perf(desktop): stable port, async PATH scrape…',
          reason:
              'the branch\'s first commit names the feature, not a follow-up',
        );
      },
    );

    test('summary carries commits, diff counts and files', () {
      final ws = detailFor(Preview.green).workspace!;
      final s = deriveSummary(
        workspace: ws,
        baseRef: 'origin/main',
        git: gitStatus(ahead: 2),
        diff: shipDiff,
      );
      expect(s.branch, 'feat/electron-optimization');
      expect(s.commits, 2);
      expect((s.added, s.removed, s.files), (367, 130, 21));
    });
  });

  group('receipt', () {
    test('rows are Suite, Tamper alarm, Verified lines, Mutation, Agent', () {
      final rows = receiptRows(receipt(), hunks: hunks());
      expect(rows.map((r) => r.label), [
        'Suite',
        'Tamper alarm',
        'Verified lines',
        'Mutation',
        'Agent',
      ]);
      final v = {for (final r in rows) r.label: r.value};
      expect(v['Suite'], '594 / 594 passed');
      expect(v['Tamper alarm'], 'clean');
      expect(v['Verified lines'], '361 of 367 added lines ran');
      expect(v['Mutation'], 'not run');
      expect(v['Agent'], 'sonnet-5 · high · \$9.89');
      expect(
        rows.any((r) => r.label.toLowerCase().contains('quality')),
        isFalse,
      );
    });

    test(
      'Written by sits after Suite and only when there is something to say',
      () {
        final rows = receiptRows(
          receipt(),
          hunks: hunks(),
          writtenBy: 'HaziqLucii',
        );
        expect(rows.map((r) => r.label).take(3), [
          'Suite',
          'Written by',
          'Tamper alarm',
        ]);
        expect(rows[1].value, 'HaziqLucii');
        expect(
          receiptRows(
            receipt(),
            writtenBy: '',
          ).any((r) => r.label == 'Written by'),
          isFalse,
        );
      },
    );

    test('writtenByText prefers the backend line and draws arrows', () {
      final r = receipt(
        writtenBy: 'you and the agent (manual -> agent at 10:32)',
      );
      expect(writtenByText(r), 'you and the agent (manual → agent at 10:32)');
      expect(writtenByText(receipt(writtenBy: 'HaziqLucii')), 'HaziqLucii');
    });

    test('writtenByText derives from mode and switches when the field is absent', () {
      Workspace ws(Map<String, dynamic> o) =>
          Workspace.fromJson(workspaceJson(overrides: o));
      expect(writtenByText(receipt()), isNull);
      expect(
        writtenByText(receipt(), workspace: ws({'mode': 'manual'})),
        'you',
      );
      expect(writtenByText(receipt(), workspace: ws({})), 'agent · sonnet-5');
      final switched = ws({
        'mode': 'agent',
        'mode_switches': [
          {'to': 'manual', 'at': '2026-09-29T10:32:00', 'sha': 'a'},
          {'to': 'agent', 'at': '2026-09-29T11:05:00', 'sha': 'b'},
        ],
      });
      expect(
        writtenByText(receipt(), workspace: switched),
        'you and the agent (agent → manual at 10:32, manual → agent at 11:05)',
      );
    });

    test('the markdown carries the Written by row', () {
      final md = receiptMarkdown(receipt(), writtenBy: 'HaziqLucii');
      expect(md, contains('| Written by | HaziqLucii |'));
      expect(md, isNot(contains('\u2014')));
    });

    test('a protected run adds one honest row, never "read-only"', () {
      final rows = receiptRows(receipt(tamperProtected: true), hunks: hunks());
      final row = rows.singleWhere((r) => r.label == 'Test edits');
      expect(
        row.value,
        'Existing tests were edit-protected for the agent (tamper alarm still checks the diff).',
      );
      expect(row.value.toLowerCase(), isNot(contains('read-only')));
    });

    test('a retried green adds the receipt line', () {
      expect(receiptRows(receipt()).any((r) => r.label == 'Retried'), isFalse);
      expect(flakyRetriedText(receipt()), isNull);
      final retried = receipt(flakyRetried: ['a.test.ts::f1', 'b.test.ts::f2']);
      expect(
        flakyRetriedText(retried),
        'green after retrying 2 known-flaky tests: f1, f2',
      );
      final row = receiptRows(retried).singleWhere((r) => r.label == 'Retried');
      expect(row.tone, ReceiptTone.dim);
    });

    test('red suite and a weakened suite read as failures', () {
      final r = receipt(
        verdict: 'green',
        tamperClean: false,
        mutationScore: 82,
        survivors: 3,
      );
      expect(receiptWord(r), 'GREEN*');
      final rows = receiptRows(r);
      expect(rows[1].value, '1 removed');
      expect(rows[1].tone, ReceiptTone.fail);
      expect(rows[3].value, '82% caught · 3 survivors');

      final red = receipt(verdict: 'red', passed: 591, failed: 3);
      expect(receiptRows(red).first.value, '591 / 594 · 3 failing');
      expect(receiptRows(red).first.tone, ReceiptTone.fail);
    });

    test('verified lines fall back to the receipt percentage', () {
      expect(receiptRows(receipt())[2].value, '98.1% of added lines ran');
    });

    test('sha: the gate tree when recorded, else the newest commit', () {
      expect(
        receiptSha(receipt(gateSha: 'abcdef0123456789'), const []),
        'abcdef0',
      );
      expect(receiptSha(receipt(), const [commitA]), 'a41f0c2');
      expect(receiptSha(receipt(), const []), isNull);
    });

    test('footer never invents a link', () {
      expect(
        receiptFooter(receipt(), 'a41f0c2'),
        'Ran 594 tests on this exact tree · a41f0c2',
      );
      expect(
        receiptFooter(receipt(), null),
        'Ran 594 tests on this exact tree',
      );
      expect(receiptFooter(receipt(), 'a41f0c2'), isNot(contains('haro.dev')));
    });

    test(
      'markdown is a table with a haro footer and no em-dash or quality row',
      () {
        final md = receiptMarkdown(receipt(), hunks: hunks(), sha: 'a41f0c2');
        expect(md, startsWith('### haro. gate receipt: GREEN'));
        expect(md, contains('| Check | Result |'));
        expect(md, contains('| Suite | 594 / 594 passed |'));
        expect(md, contains('| Verified lines | 361 of 367 added lines ran |'));
        expect(
          md,
          contains(
            'Ran 594 tests on this exact tree · a41f0c2 · gated by haro.',
          ),
        );
        expect(md, isNot(contains('\u2014')));
        expect(md.toLowerCase(), isNot(contains('quality')));
      },
    );
  });
}
