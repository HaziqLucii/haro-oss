import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/agent/composer_state.dart';
import 'package:haro_app/features/workspace/steps/ship/merge_panel.dart';
import 'package:haro_app/features/workspace/workspace_page.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

import 'ship_harness.dart';

Finder key(String k) => find.byKey(ValueKey(k));

String textOf(WidgetTester tester, String k) =>
    tester.widget<Text>(key(k)).data ?? '';

void main() {
  group('merge panel per state', () {
    testWidgets('green: ready, PR + merge, one primary', (tester) async {
      await ShipRig(Preview.green).pumpStep(tester);
      expect(textOf(tester, 'ship-title'), 'Gate is green. Ready to merge.');
      expect(textOf(tester, 'ship-sub'), contains('to look at'));
      expect(textOf(tester, 'ship-sub'), contains('won’t block the merge'));
      expect(find.text('Open pull request'), findsOneWidget);
      expect(find.text('Merge into main'), findsOneWidget);
      expect(primaryButtons(tester), 1);
      final panel = tester.widget<AnimatedContainer>(key('merge-panel'));
      final border = (panel.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, HaroTokens.gate.withValues(alpha: .45));
      expect(tester.widget<Container>(key('ship-dot')).color, HaroTokens.gate);
    });

    testWidgets('green with a PR: View #N replaces Open pull request', (
      tester,
    ) async {
      final rig = ShipRig(Preview.green, pr: openPr());
      await rig.pumpStep(tester);
      expect(find.text('View #232 ↗'), findsOneWidget);
      expect(find.text('Open pull request'), findsNothing);
      await tester.tap(key('ship-view-pr'));
      await tester.pump();
      expect(rig.opened.single.toString(), contains('/pull/232'));
    });

    testWidgets('red: blocked with the reason, verify link, dashed pill', (
      tester,
    ) async {
      final rig = ShipRig(Preview.red);
      final router = await rig.pumpStep(tester);
      expect(textOf(tester, 'ship-title'), 'Merging is blocked');
      expect(textOf(tester, 'ship-sub'), contains('failing'));
      expect(find.text('Merge into main'), findsNothing);
      expect(key('ship-merge-blocked'), findsOneWidget);
      expect(find.text('Merge blocked'), findsOneWidget);
      expect(primaryButtons(tester), 0);
      await tester.tap(key('ship-go-verify'));
      await tester.pumpAndSettle();
      expect(find.text('at verify'), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/ws_1/verify',
      );
    });

    for (final p in [Preview.idle, Preview.running]) {
      testWidgets('$p: blocked, no primary, not green', (tester) async {
        await ShipRig(p, git: gitStatus(ahead: 0)).pumpStep(tester);
        expect(textOf(tester, 'ship-title'), 'Merging is blocked');
        expect(key('ship-go-verify'), findsOneWidget);
        expect(primaryButtons(tester), 0);
        expect(
          tester.widget<Container>(key('ship-dot')).color,
          isNot(HaroTokens.gate),
        );
      });
    }

    testWidgets('green but dirty: cannot ship, commit box shows', (
      tester,
    ) async {
      await ShipRig(Preview.green, git: gitStatus(dirty: 2)).pumpStep(tester);
      expect(textOf(tester, 'ship-title'), 'Merging is blocked');
      expect(textOf(tester, 'ship-sub'), contains('2 uncommitted changes'));
      expect(key('ship-go-verify'), findsNothing);
      expect(key('ship-merge-blocked'), findsOneWidget);
      expect(key('commit-field'), findsOneWidget);
      expect(primaryButtons(tester), 1);
      expect(
        tester.widget<HaroButton>(key('commit-button')).variant,
        HaroButtonVariant.primary,
      );
    });

    testWidgets('merged: lilac, View + Continue, continue is the one primary', (
      tester,
    ) async {
      final rig = ShipRig(
        Preview.merged,
        pr: openPr(merged: true),
        git: gitStatus(ahead: 0),
      );
      final router = await rig.pumpStep(tester);
      expect(textOf(tester, 'ship-title'), 'Merged into origin/main as #232');
      expect(
        tester.widget<Container>(key('ship-dot')).color,
        HaroTokens.merged,
      );
      expect(find.text('View #232 ↗'), findsOneWidget);
      expect(primaryButtons(tester), 1);
      await tester.tap(key('ship-continue'));
      await tester.pumpAndSettle();
      expect(rig.calls, ['continue']);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/ws_1/agent',
      );
    });

    testWidgets('manual: continue opens the code step, not the agent', (
      tester,
    ) async {
      final rig = ShipRig(
        Preview.merged,
        pr: openPr(merged: true),
        git: gitStatus(ahead: 0),
        mode: WorkspaceMode.manual,
      );
      final router = await rig.pumpStep(tester);
      await tester.tap(key('ship-continue'));
      await tester.pumpAndSettle();
      expect(rig.calls, ['continue']);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/ws_1/code',
      );
    });

    testWidgets('merged locally: no number and no View link', (tester) async {
      await ShipRig(Preview.merged, git: gitStatus(ahead: 0)).pumpStep(tester);
      expect(textOf(tester, 'ship-title'), 'Merged into origin/main');
      expect(key('ship-view-pr'), findsNothing);
      expect(key('ship-continue'), findsOneWidget);
    });
  });

  group('merge', () {
    testWidgets('needs a confirming second tap, then calls merge once', (
      tester,
    ) async {
      final rig = ShipRig(Preview.green);
      await rig.pumpStep(tester);
      await tester.tap(key('ship-merge'));
      await tester.pump();
      expect(find.text('Confirm merge'), findsOneWidget);
      expect(rig.calls, isEmpty);
      await tester.tap(key('ship-merge'));
      await tester.pumpAndSettle();
      expect(rig.calls, ['merge']);
      expect(find.text('Confirm merge'), findsNothing);
    });

    testWidgets('reverts to Merge into main after 4 seconds', (tester) async {
      final rig = ShipRig(Preview.green);
      await rig.pumpStep(tester);
      await tester.tap(key('ship-merge'));
      await tester.pump();
      await tester.pump(mergeConfirmWindow - const Duration(milliseconds: 100));
      expect(find.text('Confirm merge'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Merge into main'), findsOneWidget);
      await tester.tap(key('ship-merge'));
      await tester.pump();
      expect(rig.calls, isEmpty);
    });

    testWidgets('an API error shows inline and the panel stays', (
      tester,
    ) async {
      final rig = ShipRig(
        Preview.green,
        failMerge: const HaroApiException(409, 'protected branch: open a PR'),
      );
      await rig.pumpStep(tester);
      await tester.tap(key('ship-merge'));
      await tester.pump();
      await tester.tap(key('ship-merge'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'ship-error'), 'protected branch: open a PR');
      expect(find.text('Merge into main'), findsOneWidget);
    });

    testWidgets('merged: false surfaces the backend detail', (tester) async {
      final rig = ShipRig(
        Preview.green,
        mergeResult: const MergeResult(
          merged: false,
          detail: 'checks are still pending',
        ),
      );
      await rig.pumpStep(tester);
      await tester.tap(key('ship-merge'));
      await tester.pump();
      await tester.tap(key('ship-merge'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'ship-error'), 'checks are still pending');
    });

    testWidgets('pr-only mode: no merge button, the PR button is primary', (
      tester,
    ) async {
      await ShipRig(
        Preview.green,
        git: gitStatus(mergeMode: 'pr'),
      ).pumpStep(tester);
      expect(key('ship-merge'), findsNothing);
      expect(find.text('Open pull request'), findsOneWidget);
      expect(primaryButtons(tester), 1);
    });

    testWidgets('merge-only mode: no PR button', (tester) async {
      await ShipRig(
        Preview.green,
        git: gitStatus(mergeMode: 'merge'),
      ).pumpStep(tester);
      expect(key('ship-open-pr'), findsNothing);
      expect(key('ship-merge'), findsOneWidget);
    });

    testWidgets('Open pull request calls openPr and opens the link', (
      tester,
    ) async {
      final rig = ShipRig(Preview.green);
      await rig.pumpStep(tester);
      await tester.tap(key('ship-open-pr'));
      await tester.pumpAndSettle();
      expect(rig.calls, ['openPr']);
      expect(rig.opened.single.toString(), 'https://github.com/x/pull/9');
    });
  });

  group('commit', () {
    testWidgets('clean tree: one line per commit, no commit box', (
      tester,
    ) async {
      await ShipRig(Preview.green).pumpStep(tester);
      expect(key('commit-field'), findsNothing);
      expect(key('commit-button'), findsNothing);
      final row = key('commit-row-a41f0c2');
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('14 minutes ago')),
        findsOneWidget,
      );
      expect(find.textContaining('everything is in 1 commit'), findsOneWidget);
    });

    testWidgets('dirty tree: the button commits the message', (tester) async {
      final rig = ShipRig(Preview.green, git: gitStatus(dirty: 3));
      await rig.pumpStep(tester);
      final button = tester.widget<HaroButton>(key('commit-button'));
      expect(button.variant, HaroButtonVariant.primary);
      await tester.tap(key('commit-button'));
      await tester.pump();
      expect(rig.calls, isEmpty);
      await tester.enterText(key('commit-field'), 'fix: rounding');
      await tester.pump();
      await tester.tap(key('commit-button'));
      await tester.pumpAndSettle();
      expect(rig.calls, ['commit:fix: rounding']);
      expect(textOf(tester, 'commit-note'), 'Committed b7c8d9e');
    });

    testWidgets('meta+enter in the field commits', (tester) async {
      final rig = ShipRig(Preview.green, git: gitStatus(dirty: 1));
      await rig.pumpStep(tester);
      await tester.tap(key('commit-field'));
      await tester.enterText(key('commit-field'), 'wip');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(rig.calls, ['commit:wip']);
    });
  });

  group('receipt card', () {
    testWidgets('header, rows, footer; no quality row, no invented link', (
      tester,
    ) async {
      await ShipRig(Preview.green).pumpStep(tester);
      expect(find.text('haro.'), findsOneWidget);
      expect(textOf(tester, 'receipt-head'), 'GATE RECEIPT · a41f0c2');
      expect(textOf(tester, 'receipt-verdict'), 'GREEN');
      expect(textOf(tester, 'receipt-row-Suite'), '594 / 594 passed');
      expect(textOf(tester, 'receipt-row-Tamper alarm'), 'clean');
      expect(
        textOf(tester, 'receipt-row-Verified lines'),
        '361 of 367 added lines ran',
      );
      expect(textOf(tester, 'receipt-row-Agent'), 'sonnet-5 · high · \$9.89');
      expect(find.textContaining('Quality'), findsNothing);
      expect(
        textOf(tester, 'receipt-footer'),
        'Ran 594 tests on this exact tree · a41f0c2',
      );
      expect(find.textContaining('haro.dev'), findsNothing);
      expect(find.text('Copy link'), findsNothing);
    });

    testWidgets('Written by: the backend line, arrows drawn', (tester) async {
      await ShipRig(
        Preview.green,
        receiptValue: receipt(
          writtenBy: 'you and the agent (manual -> agent at 10:32)',
        ),
      ).pumpStep(tester);
      expect(
        textOf(tester, 'receipt-row-Written by'),
        'you and the agent (manual → agent at 10:32)',
      );
    });

    testWidgets('XP: the merge awards, in the card only', (tester) async {
      await ShipRig(
        Preview.green,
        receiptValue: receipt(
          xp: 'XP: +140 (merged on green, red to green by hand)',
        ),
      ).pumpStep(tester);
      expect(
        textOf(tester, 'receipt-row-XP'),
        '+140 (merged on green, red to green by hand)',
      );
    });

    testWidgets('XP: no row when the merge pays nothing', (tester) async {
      await ShipRig(Preview.green).pumpStep(tester);
      expect(key('receipt-row-XP'), findsNothing);
    });

    testWidgets('XP: Show XP off drops the row', (tester) async {
      await ShipRig(
        Preview.green,
        receiptValue: receipt(xp: 'XP: +20 (merged on green)'),
        prefs: {
          'xp': {'show_xp': false},
        },
      ).pumpStep(tester);
      expect(key('receipt-row-XP'), findsNothing);
    });

    testWidgets('Written by falls back to the workspace mode', (tester) async {
      await ShipRig(Preview.green, mode: WorkspaceMode.manual).pumpStep(tester);
      expect(textOf(tester, 'receipt-row-Written by'), 'you');
    });

    testWidgets('a red receipt shows RED and the failing count', (
      tester,
    ) async {
      await ShipRig(Preview.red).pumpStep(tester);
      expect(textOf(tester, 'receipt-verdict'), 'RED');
      expect(textOf(tester, 'receipt-row-Suite'), '591 / 594 · 3 failing');
    });

    testWidgets('no receipt, no card', (tester) async {
      await ShipRig(Preview.green, noReceipt: true).pumpStep(tester);
      expect(key('receipt-card'), findsNothing);
      expect(key('receipt-copy'), findsNothing);
    });

    testWidgets('Copy markdown writes the table to the clipboard', (
      tester,
    ) async {
      final copied = mockClipboard(tester);
      await ShipRig(Preview.green).pumpStep(tester);
      await tester.tap(key('receipt-copy'));
      await tester.pump();
      expect(copied, hasLength(1));
      expect(copied.single, contains('### haro. gate receipt: GREEN'));
      expect(copied.single, contains('| Suite | 594 / 594 passed |'));
      expect(copied.single, contains('gated by haro.'));
      expect(copied.single, isNot(contains('backend md')));
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copy markdown'), findsOneWidget);
    });

    testWidgets('Post to PR is disabled without a PR', (tester) async {
      final rig = ShipRig(Preview.green);
      await rig.pumpStep(tester);
      expect(tester.widget<HaroButton>(key('receipt-post')).onPressed, isNull);
      await tester.tap(key('receipt-post'), warnIfMissed: false);
      await tester.pump();
      expect(rig.calls, isEmpty);
    });

    testWidgets('Post to PR posts when a PR exists', (tester) async {
      final rig = ShipRig(Preview.green, pr: openPr());
      await rig.pumpStep(tester);
      await tester.tap(key('receipt-post'));
      await tester.pumpAndSettle();
      expect(rig.calls, ['post']);
      expect(textOf(tester, 'receipt-note'), 'Posted to the pull request.');
    });

    testWidgets('receipt actions are never green', (tester) async {
      await ShipRig(Preview.green, pr: openPr()).pumpStep(tester);
      for (final k in ['receipt-copy', 'receipt-post']) {
        final b = tester.widget<HaroButton>(key(k));
        expect(b.variant, HaroButtonVariant.tertiary);
        expect(b.foreground, isNot(HaroTokens.gate));
      }
    });
  });

  group('title and summary', () {
    testWidgets('PR title and the mono summary line', (tester) async {
      await ShipRig(
        Preview.green,
        pr: openPr(),
        git: gitStatus(ahead: 2),
      ).pumpStep(tester);
      expect(
        textOf(tester, 'ship-pr-title'),
        'perf(desktop): stable port, async PATH scrape, lazy panels',
      );
      final summary = tester.widget<Wrap>(key('ship-summary'));
      final texts = summary.children.whereType<Text>().toList();
      expect(texts.first.data, 'feat/electron-optimization → origin/main');
      expect(texts[1].data, '2 commits');
      expect(texts[2].textSpan!.toPlainText(), '+367 −130');
      expect(texts[3].data, '21 files');
    });
  });

  group('page', () {
    // Whole page, step bar included: it steps its button down on the step it points at, so
    // the ship step must supply the one primary. Zero is documented in ship_model.dart for
    // nothing-ahead, no worktree and a still-loading git status.
    final scenarios = <String, (ShipRig, int)>{
      'green clean': (ShipRig(Preview.green), 1),
      'green dirty': (ShipRig(Preview.green, git: gitStatus(dirty: 2)), 1),
      'green conflict': (
        ShipRig(Preview.green, pr: openPr(mergeable: 'CONFLICTING')),
        1,
      ),
      'green nothing ahead': (
        ShipRig(Preview.green, git: gitStatus(ahead: 0)),
        0,
      ),
      'red': (ShipRig(Preview.red), 1),
      'merged': (
        ShipRig(
          Preview.merged,
          pr: openPr(merged: true),
          git: gitStatus(ahead: 0),
        ),
        1,
      ),
    };
    for (final e in scenarios.entries) {
      testWidgets('${e.key}: enabled primaries on the page = ${e.value.$2}', (
        tester,
      ) async {
        await e.value.$1.pumpApp(tester);
        final n = tester
            .widgetList<HaroButton>(
              find.descendant(
                of: find.byType(WorkspacePage),
                matching: find.byType(HaroButton),
              ),
            )
            .where(
              (b) =>
                  b.variant == HaroButtonVariant.primary && b.onPressed != null,
            )
            .length;
        expect(n, e.value.$2);
      });
    }

    testWidgets('manual: a conflict offers no AI resolve', (tester) async {
      final rig = ShipRig(
        Preview.green,
        pr: openPr(mergeable: 'CONFLICTING'),
        mode: WorkspaceMode.manual,
      );
      await rig.pumpStep(tester);
      expect(key('ship-resolve'), findsNothing);
    });

    testWidgets('conflict: Help resolve seeds the composer and opens agent', (
      tester,
    ) async {
      final rig = ShipRig(Preview.green, pr: openPr(mergeable: 'CONFLICTING'));
      final router = await rig.pumpStep(tester);
      await tester.tap(key('ship-resolve'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/ws_1/agent',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.text('at agent')),
      );
      final text = container.read(composerDraftProvider(id)).text;
      expect(text, contains('git merge origin/main'));
      expect(text, contains('#232'));
    });

    for (final p in [Preview.green, Preview.red, Preview.merged]) {
      for (final terminal in [false, true]) {
        testWidgets('$p at 900x640 terminal=$terminal: no overflow', (
          tester,
        ) async {
          await ShipRig(
            p,
            pr: openPr(merged: p == Preview.merged),
            git: gitStatus(dirty: p == Preview.red ? 2 : 0),
          ).pumpApp(tester, size: const Size(900, 640), terminal: terminal);
          expect(tester.takeException(), isNull);
          expect(key('merge-panel'), findsOneWidget);
          await tester.dragUntilVisible(
            key('receipt-card'),
            key('ship-scroll'),
            const Offset(0, -200),
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
