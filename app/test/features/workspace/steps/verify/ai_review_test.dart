import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/verify/ai_review_panel.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../../../state/builders.dart';
import '../../harness.dart';
import 'verify_harness.dart';

const mainJs = 'desktop/main.js';
const stream = 'frontend/src/components/AgentStream.tsx';

Finder key(String k) => find.byKey(ValueKey(k));

String textOf(WidgetTester t, String k) => t.widget<Text>(key(k)).data!;

Color? colorOf(WidgetTester t, String k) => t.widget<Text>(key(k)).style?.color;

ReviewVerdict verdict({bool pass = false, List<String> notes = const []}) =>
    ReviewVerdict(
      ranAt: 1790000000,
      model: 'opus',
      pass: pass,
      summary: 'The rate table is read before it is loaded.',
      mustFix: pass
          ? const []
          : [
              const AiReviewItem(
                title: 'Read before load',
                file: mainJs,
                line: 205,
                detail: 'Load it first.',
              ),
              const AiReviewItem(
                title: 'Not in this diff',
                file: 'lib/elsewhere.ts',
                line: 3,
              ),
            ],
      notes: notes,
    );

ReviewResult findings() => const ReviewResult(
  ranAt: 1790000000,
  model: 'sonnet',
  summary: 'Two things.',
  findings: [
    AiReviewItem(
      title: 'Unbounded loop',
      file: stream,
      line: 210,
      severity: 'high',
      category: 'bug',
      detail: 'Never ends.',
    ),
    AiReviewItem(
      title: 'Name',
      file: mainJs,
      severity: 'nit',
      category: 'style',
    ),
  ],
);

Future<VerifyRig> pump(
  WidgetTester tester, {
  WorkspaceStatus status = WorkspaceStatus.gateGreen,
  Future<AiReview> Function()? onReview,
  Size size = const Size(1400, 900),
}) async {
  final d = verifyDetail(
    status,
    run: greenRun(),
    cells: cells(594),
    pr: status == WorkspaceStatus.merged ? 232 : null,
  );
  final rig = VerifyRig(
    status == WorkspaceStatus.merged ? Preview.merged : Preview.green,
    state: d,
  )..onReview = onReview;
  rig.router = await rig.pump(tester, size: size);
  return rig;
}

Future<void> run(WidgetTester tester) async {
  await tester.ensureVisible(key('ai-review-run'));
  await tester.pumpAndSettle();
  await tester.tap(key('ai-review-run'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'never runs on mount; the button is a small bone control with the hint',
    (tester) async {
      final rig = await pump(tester);
      expect(rig.calls, isNot(contains('review')));
      expect(find.text('Review with AI'), findsOneWidget);
      final button = tester.widget<HaroButton>(key('ai-review-run'));
      expect(button.variant, HaroButtonVariant.control);
      expect(tester.getSize(key('ai-review-run')).width, lessThan(260));
      expect(button.tooltip, aiReviewHint);
      expect(key('ai-review-result'), findsNothing);
    },
  );

  testWidgets('hidden once merged', (tester) async {
    await pump(tester, status: WorkspaceStatus.merged);
    expect(key('ai-review-run'), findsNothing);
  });

  testWidgets('one click, one call: busy disables the button', (tester) async {
    final done = Completer<AiReview>();
    final rig = await pump(tester, onReview: () => done.future);
    await tester.ensureVisible(key('ai-review-run'));
    await tester.tap(key('ai-review-run'));
    await tester.pump();
    expect(find.text('Reviewing…'), findsOneWidget);
    expect(tester.widget<HaroButton>(key('ai-review-run')).onPressed, isNull);
    await tester.tap(key('ai-review-run'), warnIfMissed: false);
    await tester.pump();
    expect(rig.calls.where((c) => c == 'review'), hasLength(1));
    done.complete(verdict());
    await tester.pumpAndSettle();
    expect(find.text('Review with AI'), findsOneWidget);
    expect(key('ai-review-result'), findsOneWidget);
  });

  testWidgets('a verdict: ink PASS/FAIL, red only on the must-fix count', (
    tester,
  ) async {
    await pump(tester, onReview: () async => verdict());
    await run(tester);
    expect(textOf(tester, 'ai-review-word'), 'FAIL');
    expect(colorOf(tester, 'ai-review-word'), HaroTokens.ink);
    expect(textOf(tester, 'ai-review-mustfix-count'), '2 MUST FIX');
    expect(colorOf(tester, 'ai-review-mustfix-count'), HaroTokens.fail);
    expect(
      textOf(tester, 'ai-review-summary'),
      'The rate table is read before it is loaded.',
    );
  });

  testWidgets('a finding sits under its file, the rest in the summary', (
    tester,
  ) async {
    await pump(tester, onReview: () async => verdict());
    await run(tester);
    expect(
      find.descendant(
        of: key('file-card-$mainJs'),
        matching: key('ai-review-item-0'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: key('ai-review-result'),
        matching: key('ai-review-item-1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: key('ai-review-result'),
        matching: key('ai-review-item-0'),
      ),
      findsNothing,
    );
    expect(textOf(tester, 'ai-review-where-0'), '$mainJs:205');
  });

  testWidgets('a passing verdict has no red and no green', (tester) async {
    await pump(
      tester,
      onReview: () async => verdict(pass: true, notes: ['ok']),
    );
    await run(tester);
    expect(textOf(tester, 'ai-review-word'), 'PASS');
    expect(colorOf(tester, 'ai-review-word'), HaroTokens.ink);
    expect(key('ai-review-mustfix-count'), findsNothing);
    expect(find.text('Nothing to fix.'), findsOneWidget);
  });

  testWidgets('findings carry a mono severity under their files', (
    tester,
  ) async {
    await pump(tester, onReview: () async => findings());
    await run(tester);
    expect(textOf(tester, 'ai-review-count'), '2 FINDINGS');
    expect(textOf(tester, 'ai-review-sev-0'), 'HIGH · BUG');
    expect(textOf(tester, 'ai-review-sev-1'), 'NIT · STYLE');
    expect(textOf(tester, 'ai-review-where-1'), mainJs);
    expect(
      find.descendant(
        of: key('file-card-$stream'),
        matching: key('ai-review-item-0'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Open diff goes to the code step at that line', (tester) async {
    final rig = await pump(tester, onReview: () async => verdict());
    await run(tester);
    await tester.ensureVisible(key('ai-review-diff-0'));
    await tester.pumpAndSettle();
    await tester.tap(key('ai-review-diff-0'));
    await tester.pumpAndSettle();
    expect(
      rig.router!.routerDelegate.currentConfiguration.uri.toString(),
      '/w/ws_1/code?file=${Uri.encodeQueryComponent(mainJs)}&line=205',
    );
  });

  testWidgets('nothing to review is one line', (tester) async {
    await pump(
      tester,
      onReview: () async =>
          const ReviewResult(ranAt: 1, model: 'sonnet', nothingToReview: true),
    );
    await run(tester);
    expect(
      textOf(tester, 'ai-review-empty'),
      'Nothing to review: this branch matches main.',
    );
    expect(key('ai-review-result'), findsNothing);
  });

  testWidgets('a reviewer error shows inline and Retry runs it again', (
    tester,
  ) async {
    var n = 0;
    final rig = await pump(
      tester,
      onReview: () async => n++ == 0
          ? const ReviewResult(ranAt: 1, error: 'reviewer timed out')
          : findings(),
    );
    await run(tester);
    expect(find.textContaining('reviewer timed out'), findsOneWidget);
    await tester.ensureVisible(key('ai-review-retry'));
    await tester.tap(key('ai-review-retry'));
    await tester.pumpAndSettle();
    expect(rig.calls.where((c) => c == 'review'), hasLength(2));
    expect(key('ai-review-error'), findsNothing);
    expect(key('ai-review-count'), findsOneWidget);
  });

  testWidgets('a thrown request shows inline too', (tester) async {
    await pump(
      tester,
      onReview: () async =>
          throw const HaroApiException(404, 'workspace not found'),
    );
    await run(tester);
    expect(find.textContaining('workspace not found'), findsOneWidget);
    expect(key('ai-review-retry'), findsOneWidget);
  });

  testWidgets('the result survives leaving and returning to the step', (
    tester,
  ) async {
    final rig = await pump(tester, onReview: () async => findings());
    await run(tester);
    rig.router!.go('/w/$id/ship');
    await tester.pumpAndSettle();
    rig.router!.go('/w/$id/verify');
    await tester.pumpAndSettle();
    expect(key('ai-review-count'), findsOneWidget);
    expect(rig.calls.where((c) => c == 'review'), hasLength(1));
  });

  testWidgets('the ship step no longer offers the review', (tester) async {
    final rig = await pump(tester);
    rig.router!.go('/w/$id/ship');
    await tester.pumpAndSettle();
    expect(key('ai-review-run'), findsNothing);
  });

  for (final size in [const Size(900, 640), const Size(960, 640)]) {
    testWidgets('a long review at ${size.width.toInt()}x640: no overflow', (
      tester,
    ) async {
      final long = ReviewVerdict(
        ranAt: 1790000000,
        model: 'opus',
        pass: false,
        summary: 'A long summary. ' * 40,
        mustFix: [
          for (var i = 0; i < 6; i++)
            AiReviewItem(
              title: 'A very long must-fix title that keeps going $i ' * 3,
              file: i.isEven
                  ? mainJs
                  : 'packages/very/deeply/nested/file_$i.ts',
              line: 100 + i,
              detail: 'Detail sentence that goes on and on. ' * 12,
            ),
        ],
        notes: ['A note that is also fairly long. ' * 8],
      );
      await pump(tester, onReview: () async => long, size: size);
      await run(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('ai-review-item-4'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
