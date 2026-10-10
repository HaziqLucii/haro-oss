import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';

import '../../../../data/pr_poll_api.dart';
import 'ship_harness.dart';

Finder key(String k) => find.byKey(ValueKey(k));

class RecordApi extends PrPollApi {
  RecordApi() : super([noPr()]);

  final saved = <String?>[];

  @override
  Future<void> putReviewRecord(
    String wsId, {
    List<({String path, double seconds})>? viewed,
    int? files,
    String? reason,
  }) async => saved.add(reason);
}

Receipt readReceipt() => receipt(
  reading: const ReceiptReading(
    recorded: true,
    files: 4,
    viewed: 3,
    medianSeconds: 9,
    quickViews: 1,
    reason: 'Saved earlier.',
  ),
);

void main() {
  testWidgets('the reason field starts from the saved reason', (tester) async {
    await ShipRig(Preview.green, receiptValue: readReceipt()).pumpStep(tester);
    final field = tester.widget<EditableText>(
      find.descendant(
        of: key('receipt-reason'),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.controller.text, 'Saved earlier.');
    expect(find.textContaining('Viewed 3 of 4 files'), findsWidgets);
  });

  testWidgets('typing saves the reason once, after a pause', (tester) async {
    final api = RecordApi();
    await ShipRig(Preview.green, prApi: api).pumpStep(tester);
    await tester.enterText(key('receipt-reason'), 'Retry is capped.');
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    expect(api.saved, ['Retry is capped.']);
    expect(find.textContaining('Retry is capped.'), findsWidgets);
  });

  testWidgets('Copy for PR writes the block with the typed reason', (
    tester,
  ) async {
    final copied = mockClipboard(tester);
    await ShipRig(Preview.green).pumpStep(tester);
    await tester.enterText(key('receipt-reason'), 'Additive only.');
    await tester.tap(key('receipt-copy-pr'));
    await tester.pump();
    expect(copied.single, contains('## Intent'));
    expect(copied.single, contains('## Constraints'));
    expect(copied.single, contains('## Evidence'));
    expect(copied.single, contains('Additive only. (typed by the developer)'));
    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
  });
}
