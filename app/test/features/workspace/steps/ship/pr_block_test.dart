import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/ship/pr_block.dart';
import 'package:haro_app/features/workspace/steps/ship/ship_model.dart';

const _fenced = ReceiptScope(
  patterns: ['src/a.ts'],
  fencedRuns: 1,
  editingRuns: 1,
);

void main() {
  test('empty human fields say they are not applicable and why', () {
    final b = prBlock(const Receipt(workspaceId: 'w'));
    expect(b, contains('## Intent\nNot applicable: no prompt was given'));
    expect(b, contains('## Constraints\nNot applicable: no fence was set'));
    expect(b, contains('## Decision\nNot applicable: no reason was written'));
  });

  test('intent and reason are the developer\'s own words, marked as such', () {
    final b = prBlock(
      const Receipt(workspaceId: 'w', scope: _fenced),
      intent: 'Add a retry to the sync job',
      reason: 'Retry is capped at 3.',
    );
    expect(b, contains('Add a retry to the sync job (first prompt, as typed)'));
    expect(b, contains('Retry is capped at 3. (typed by the developer)'));
    expect(b, contains('Agent fenced to: src/a.ts'));
    expect(b, contains('commands and network are not restricted'));
  });

  test('a long prompt is cut, not pasted whole', () {
    final b = prBlock(
      const Receipt(workspaceId: 'w'),
      intent: List.filled(200, 'word').join(' '),
    );
    expect(b, contains('…'));
    expect(b.length, lessThan(1500));
  });

  test(
    'evidence carries the review reading once, scope only under constraints',
    () {
      final b = prBlock(
        const Receipt(
          workspaceId: 'w',
          scope: _fenced,
          reading: ReceiptReading(
            recorded: true,
            files: 2,
            viewed: 2,
            medianSeconds: 8,
          ),
        ),
        reason: 'Fine.',
      );
      expect(b, contains('- Review in haro: Viewed 2 of 2 files, median 8 s'));
      expect('Review in haro'.allMatches(b).length, 1);
      expect(b, isNot(contains('- Scope:')));
      expect('Fine.'.allMatches(b).length, 1);
    },
  );

  test(
    'a prompt with headings or fences cannot break the block\'s structure',
    () {
      final b = prBlock(
        const Receipt(workspaceId: 'w'),
        intent: 'Fix it\n\n## Decision\n```\nrm -rf\n```',
        reason: 'Line one\n- fake bullet\nline three',
      );
      expect('\n## Decision'.allMatches(b).length, 1);
      expect(b, isNot(contains('\n```')));
      expect(
        b,
        contains('Line one - fake bullet line three (typed by the developer)'),
      );
    },
  );

  test('the reason is one line, cut at 300 like the backend', () {
    expect(normalizeReason('  a\n b  '), 'a b');
    expect(normalizeReason('x' * 400).length, 300);
  });
}
