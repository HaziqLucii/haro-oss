import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/ship/ship_model.dart';

void main() {
  List<String> labels(Receipt r) => [
    for (final row in receiptRows(r)) row.label,
  ];

  test('an unverified plan and lookup say so in the row and the markdown', () {
    final r = Receipt.fromJson({
      'workspace_id': 'w',
      'plan': {'plans': 1, 'steps': 3, 'ai_edits': 0, 'unverified': true},
      'research': {'lookups': 1, 'unverified': true},
    });
    final rows = {for (final row in receiptRows(r)) row.label: row.value};
    expect(rows['Plan'], contains('AI edits: unverified'));
    expect(rows['Plan'], isNot(contains('AI edits: 0')));
    expect(rows['Research'], '1 lookup \u00b7 AI edits: unverified');
    expect(receiptMarkdown(r), contains('AI edits: unverified'));
  });

  test('the XP row is opt-in, and never reaches the copied markdown', () {
    final r = Receipt.fromJson({
      'workspace_id': 'w',
      'xp': 'XP: +20 (merged on green)',
    });
    expect(labels(r), isNot(contains('XP')));
    final rows = {
      for (final row in receiptRows(r, showXp: true)) row.label: row.value,
    };
    expect(rows['XP'], '+20 (merged on green)');
    expect(receiptMarkdown(r), isNot(contains('XP')));
  });

  test('the XP text drops the backend prefix and ignores an empty line', () {
    expect(
      receiptXpText(
        Receipt.fromJson({'workspace_id': 'w', 'xp': 'XP: +5 (a)'}),
      ),
      '+5 (a)',
    );
    expect(
      receiptXpText(Receipt.fromJson({'workspace_id': 'w', 'xp': ' '})),
      isNull,
    );
    expect(receiptXpText(Receipt.fromJson({'workspace_id': 'w'})), isNull);
  });

  test('a receipt without manual-rail data has no Plan or Research row', () {
    final r = Receipt.fromJson({'workspace_id': 'w'});
    expect(labels(r), isNot(contains('Plan')));
    expect(labels(r), isNot(contains('Research')));
  });

  test(
    'saved plans and lookups get their own rows, in the copied markdown too',
    () {
      final r = Receipt.fromJson({
        'workspace_id': 'w',
        'plan': {'plans': 1, 'steps': 6, 'done': 3, 'ai_edits': 0},
        'research': {'lookups': 4},
      });
      final rows = {for (final row in receiptRows(r)) row.label: row.value};
      expect(rows['Plan'], 'haro AI · 6 steps · AI edits: 0');
      expect(rows['Research'], '4 lookups');
      final md = receiptMarkdown(r);
      expect(md, contains('| Plan | haro AI · 6 steps · AI edits: 0 |'));
      expect(md, contains('| Research | 4 lookups |'));
    },
  );
}
