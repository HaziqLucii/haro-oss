import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/review_queue_provider.dart';
import 'package:haro_app/theme/tokens.dart';

import '../harness.dart';

ReviewQueue waiting(List<String> ids, {int cap = 3}) => ReviewQueue(
  cap: cap,
  totalLines: 100 * ids.length,
  workspaces: [
    for (final w in ids) ReviewQueueItem(workspaceId: w, lines: 100),
  ],
);

Future<void> pumpRail(
  WidgetTester tester,
  ReviewQueue q, {
  WorkspaceMode mode = WorkspaceMode.agent,
}) async {
  final rig = Rig(Preview.idle, mode: mode);
  rig.extra.add(reviewQueueProvider.overrideWith((ref) async => q));
  await rig.pump(tester);
  await tester.pumpAndSettle();
}

final note = find.byKey(const ValueKey('rail-review-cap'));

void main() {
  testWidgets('past the limit the rail says so, in the warning colour', (
    tester,
  ) async {
    await pumpRail(tester, waiting(['a', 'b', 'c']));
    final text = tester.widget<Text>(note);
    expect(
      text.data,
      '3 other workspaces already wait for your review (300 changed lines). Another run adds to the pile.',
    );
    expect(text.style?.color, HaroTokens.warn);
    expect(text.maxLines, isNull, reason: 'it wraps instead of being cut off');
    expect(find.text('REVIEW LIMIT'), findsOneWidget);
  });

  testWidgets(
    'below the limit, with the limit off, or when this workspace is one of them, nothing shows',
    (tester) async {
      await pumpRail(tester, waiting(['a', 'b']));
      expect(note, findsNothing);
      await pumpRail(tester, waiting(['a', 'b', 'c', 'd'], cap: 0));
      expect(note, findsNothing);
      await pumpRail(tester, waiting([id, 'a', 'b']));
      expect(note, findsNothing);
    },
  );

  testWidgets(
    'a manual workspace never shows it (no agent run to add to the pile)',
    (tester) async {
      await pumpRail(
        tester,
        waiting(['a', 'b', 'c']),
        mode: WorkspaceMode.manual,
      );
      expect(note, findsNothing);
    },
  );
}
