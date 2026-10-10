import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/review_queue_provider.dart';

import 'agent_harness.dart';

ReviewQueue waiting(List<String> ids, {int cap = 3}) => ReviewQueue(
  cap: cap,
  totalLines: 100 * ids.length,
  workspaces: [
    for (final w in ids) ReviewQueueItem(workspaceId: w, lines: 100),
  ],
);

Future<AgentRig> pump(
  WidgetTester tester,
  ReviewQueue q, {
  Preview preview = Preview.idle,
}) async {
  final rig = AgentRig(preview);
  rig.extra.add(reviewQueueProvider.overrideWith((ref) async => q));
  await rig.pump(tester, step: 'agent');
  await tester.pumpAndSettle();
  return rig;
}

final warning = find.byKey(const ValueKey('composer-review-cap'));

void main() {
  testWidgets(
    'past the limit the composer says so in one line and still sends',
    (tester) async {
      final rig = await pump(tester, waiting(['a', 'b', 'c']));
      expect(
        tester.widget<Text>(warning).data,
        '3 other workspaces already wait for your review (300 changed lines). Another run adds to the pile.',
      );
      expect(tester.widget<Text>(warning).maxLines, 1);
      await tester.enterText(find.byType(TextField).first, 'do the thing');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(rig.agent.starts, hasLength(1));
    },
  );

  testWidgets(
    'below the limit, or this workspace is one of them, nothing shows',
    (tester) async {
      await pump(tester, waiting(['a', 'b']));
      expect(warning, findsNothing);
    },
  );

  testWidgets('the limit off means no warning', (tester) async {
    await pump(tester, waiting(['a', 'b', 'c', 'd'], cap: 0));
    expect(warning, findsNothing);
  });

  testWidgets(
    'this workspace waiting does not count against its own follow-up',
    (tester) async {
      await pump(tester, waiting(['ws_1', 'a', 'b']));
      expect(warning, findsNothing);
    },
  );
}
