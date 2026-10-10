import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/theme/tokens.dart';

import 'ship_harness.dart';

Finder key(String k) => find.byKey(ValueKey(k));

const _feature = GitCommit(
  sha: 'f00000000000000000000000000000000000000f',
  short: 'f000000',
  author: 'HaziqLucii',
  when: '2 days ago',
  subject: 'feat: the feature',
  own: true,
);
const _followUp = GitCommit(
  sha: 'e11111111111111111111111111111111111111e',
  short: 'e111111',
  author: 'HaziqLucii',
  when: '1 day ago',
  subject: 'test: a follow-up',
  own: true,
);

String? titleText(WidgetTester tester) =>
    key('ship-pr-title').evaluate().isEmpty
    ? null
    : tester.widget<Text>(key('ship-pr-title')).data;

/// First read answers, the next ones wait on [later].
class SlowRefetchApi extends HaroApi {
  SlowRefetchApi(this.later) : super(Uri.parse('http://127.0.0.1:1'));

  final Completer<PrStatusResponse> later;
  int calls = 0;

  @override
  Future<PrStatusResponse> gitPr(String wsId) {
    calls++;
    return calls == 1 ? Future.value(openPr()) : later.future;
  }
}

void main() {
  group('title', () {
    testWidgets(
      'a skeleton until git, the log and the PR all answer, then one title',
      (tester) async {
        final git = Completer<GitStatusResponse>();
        final log = Completer<List<GitCommit>>();
        final pr = Completer<PrStatusResponse>();
        await ShipRig(
          Preview.green,
          gitGate: git,
          logGate: log,
          prGate: pr,
        ).pumpStep(tester);
        expect(key('ship-title-skeleton'), findsOneWidget);
        expect(key('ship-commits-skeleton'), findsOneWidget);
        expect(titleText(tester), isNull);

        git.complete(gitStatus(ahead: 2));
        await tester.pumpAndSettle();
        expect(titleText(tester), isNull);

        log.complete([_followUp, _feature]);
        await tester.pumpAndSettle();
        expect(titleText(tester), isNull);
        expect(key('ship-title-skeleton'), findsOneWidget);

        pr.complete(noPr());
        await tester.pumpAndSettle();
        expect(titleText(tester), 'feat: the feature');
        expect(key('ship-title-skeleton'), findsNothing);
        expect(key('ship-commits-skeleton'), findsNothing);
        expect(find.text('2 commits'), findsOneWidget);
      },
    );

    testWidgets('the PR title wins once everything has answered', (
      tester,
    ) async {
      final pr = Completer<PrStatusResponse>();
      await ShipRig(
        Preview.green,
        commits: const [_followUp, _feature],
        git: gitStatus(ahead: 2),
        prGate: pr,
      ).pumpStep(tester);
      expect(titleText(tester), isNull);
      pr.complete(openPr());
      await tester.pumpAndSettle();
      expect(titleText(tester), startsWith('perf(desktop)'));
    });

    testWidgets('a source that errors settles on the workspace name', (
      tester,
    ) async {
      final git = Completer<GitStatusResponse>();
      final rig = ShipRig(Preview.green, gitGate: git);
      await rig.pumpStep(tester);
      expect(titleText(tester), isNull);
      git.completeError(const HaroApiException(500, 'boom'));
      await tester.pumpAndSettle();
      expect(titleText(tester), rig.detail.workspace!.name);
    });

    testWidgets('the skeleton and the title take the same height', (
      tester,
    ) async {
      final pr = Completer<PrStatusResponse>();
      await ShipRig(
        Preview.green,
        prGate: pr,
        commits: const [_feature],
      ).pumpStep(tester);
      final before = tester.getSize(find.byType(AnimatedSwitcher).first);
      pr.complete(noPr());
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AnimatedSwitcher).first), before);
    });
  });

  group('merge panel', () {
    testWidgets('no blocked state flashes while git and the PR are loading', (
      tester,
    ) async {
      final git = Completer<GitStatusResponse>();
      final pr = Completer<PrStatusResponse>();
      await ShipRig(Preview.green, gitGate: git, prGate: pr).pumpStep(tester);
      expect(key('ship-state-skeleton'), findsOneWidget);
      expect(key('ship-title'), findsNothing);
      expect(key('ship-merge-blocked'), findsNothing);
      expect(key('ship-pr-skeleton'), findsOneWidget);
      expect(key('ship-merge-skeleton'), findsOneWidget);

      git.complete(gitStatus());
      await tester.pumpAndSettle();
      expect(key('ship-state-skeleton'), findsOneWidget);

      pr.complete(noPr());
      await tester.pumpAndSettle();
      expect(key('ship-state-skeleton'), findsNothing);
      expect(find.text('Gate is green. Ready to merge.'), findsOneWidget);
    });

    testWidgets('a red gate needs neither source, so it shows at once', (
      tester,
    ) async {
      final git = Completer<GitStatusResponse>();
      final pr = Completer<PrStatusResponse>();
      await ShipRig(Preview.red, gitGate: git, prGate: pr).pumpStep(tester);
      expect(key('ship-state-skeleton'), findsNothing);
      expect(find.text('Merging is blocked'), findsOneWidget);
    });

    for (final withPr in [true, false]) {
      testWidgets(
        'the ${withPr ? 'View' : 'Open pull request'} button lands exactly in its skeleton',
        (tester) async {
          final git = Completer<GitStatusResponse>();
          final pr = Completer<PrStatusResponse>();
          await ShipRig(
            Preview.green,
            gitGate: git,
            prGate: pr,
          ).pumpStep(tester);
          final skeleton = tester.getRect(key('ship-pr-skeleton'));
          final mergeSkeleton = tester.getRect(key('ship-merge-skeleton'));
          final textBefore = tester.getRect(key('ship-state-skeleton'));

          git.complete(gitStatus());
          pr.complete(withPr ? openPr() : noPr());
          await tester.pumpAndSettle();

          final button = key(withPr ? 'ship-view-pr' : 'ship-open-pr');
          expect(button, findsOneWidget);
          expect(tester.getSize(button), skeleton.size);
          expect(tester.getRect(button).left, skeleton.left);
          expect(tester.getRect(key('ship-merge')).left, mergeSkeleton.left);
          expect(tester.getSize(key('ship-merge')), mergeSkeleton.size);
          final textAfter = tester.getRect(key('ship-sub'));
          expect(textAfter.left, textBefore.left);
          expect(textAfter.width, textBefore.width);
        },
      );
    }

    testWidgets('a PR re-read keeps the button and brings no skeleton back', (
      tester,
    ) async {
      final later = Completer<PrStatusResponse>();
      final api = SlowRefetchApi(later);
      await ShipRig(Preview.green, prApi: api).pumpStep(tester);
      expect(key('ship-view-pr'), findsOneWidget);
      final before = tester.getRect(key('ship-view-pr'));

      await tester.pump(HaroTokens.prPollInterval);
      await tester.pump();
      expect(api.calls, 2);
      expect(key('ship-view-pr'), findsOneWidget);
      expect(tester.getRect(key('ship-view-pr')), before);
      expect(key('ship-pr-skeleton'), findsNothing);
      expect(key('ship-state-skeleton'), findsNothing);
      expect(key('ship-title-skeleton'), findsNothing);
      expect(titleText(tester), isNotNull);

      later.complete(openPr());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('receipt', () {
    testWidgets(
      'a card-sized skeleton holds the place until the receipt lands',
      (tester) async {
        final gate = Completer<ReceiptResponse?>();
        await ShipRig(Preview.green, receiptGate: gate).pumpStep(tester);
        expect(key('receipt-skeleton'), findsOneWidget);
        expect(
          tester.getSize(key('receipt-skeleton')).height,
          HaroTokens.shipReceiptSkeletonHeight,
        );
        expect(key('receipt-card'), findsNothing);
        expect(find.text('Gate receipt'.toUpperCase()), findsOneWidget);

        gate.complete(ReceiptResponse(receipt: receipt(), markdown: 'md'));
        await tester.pumpAndSettle();
        expect(key('receipt-skeleton'), findsNothing);
        expect(key('receipt-card'), findsOneWidget);
        expect(key('receipt-copy'), findsOneWidget);
      },
    );

    testWidgets('no receipt: the skeleton fades away and leaves nothing', (
      tester,
    ) async {
      final gate = Completer<ReceiptResponse?>();
      await ShipRig(Preview.green, receiptGate: gate).pumpStep(tester);
      expect(key('receipt-skeleton'), findsOneWidget);
      gate.complete(null);
      await tester.pumpAndSettle();
      expect(key('receipt-skeleton'), findsNothing);
      expect(key('receipt-card'), findsNothing);
      expect(find.text('GATE RECEIPT'), findsNothing);
    });

    testWidgets('a workspace the gate never ran on reserves no receipt', (
      tester,
    ) async {
      final gate = Completer<ReceiptResponse?>();
      await ShipRig(Preview.idle, receiptGate: gate).pumpStep(tester);
      expect(key('receipt-skeleton'), findsNothing);
    });
  });

  group('commit section', () {
    testWidgets('skeleton sub line and one row while git status loads', (
      tester,
    ) async {
      final git = Completer<GitStatusResponse>();
      await ShipRig(
        Preview.green,
        gitGate: git,
        commits: const [_feature],
      ).pumpStep(tester);
      expect(key('commit-row-skeleton'), findsOneWidget);
      expect(find.textContaining('Working tree is clean'), findsNothing);
      final rowHeight = tester.getSize(key('commit-row-skeleton')).height;

      git.complete(gitStatus());
      await tester.pumpAndSettle();
      expect(key('commit-row-skeleton'), findsNothing);
      expect(key('commit-row-f000000'), findsOneWidget);
      expect(tester.getSize(key('commit-row-f000000')).height + 14, rowHeight);
    });

    testWidgets(
      'the commit box appears with the dirty count once git answers',
      (tester) async {
        final git = Completer<GitStatusResponse>();
        await ShipRig(Preview.green, gitGate: git).pumpStep(tester);
        expect(key('commit-field'), findsNothing);
        git.complete(gitStatus(dirty: 2));
        await tester.pumpAndSettle();
        expect(key('commit-field'), findsOneWidget);
      },
    );
  });
}
