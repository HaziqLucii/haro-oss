import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/review_queue.dart';

ReviewQueue queue(Map<String, int> lines, {int cap = 3}) => ReviewQueue(
  cap: cap,
  totalLines: lines.values.fold(0, (a, b) => a + b),
  workspaces: [
    for (final e in lines.entries)
      ReviewQueueItem(workspaceId: e.key, lines: e.value, files: 1),
  ],
);

void main() {
  test('parses the backend payload', () {
    final q = ReviewQueue.fromJson({
      'cap': 2,
      'total_lines': 30,
      'workspaces': [
        {'workspace_id': 'a', 'project_id': 'p', 'lines': 30, 'files': 4},
      ],
    });
    expect((q.cap, q.totalLines), (2, 30));
    expect(q.workspaces.single.files, 4);
  });

  group('reviewQueueLine', () {
    test('is null when nothing waits', () {
      expect(reviewQueueLine(queue({})), isNull);
    });

    test('counts workspaces and lines with a thousands separator', () {
      expect(
        reviewQueueLine(queue({'a': 1000, 'b': 240})),
        '2 workspaces waiting for your review · 1,240 changed lines',
      );
      expect(
        reviewQueueLine(queue({'a': 1})),
        '1 workspace waiting for your review · 1 changed line',
      );
    });

    test('says at the limit, then past it, and nothing below or with the limit off', () {
      String? line(int n, {int cap = 3}) => reviewQueueLine(
        queue({for (var i = 0; i < n; i++) 'w$i': 1}, cap: cap),
      );
      expect(line(2), isNot(contains('limit')));
      expect(line(3), endsWith('· review limit of 3 reached'));
      expect(line(4), endsWith('· over the review limit of 3'));
      expect(line(4, cap: 0), isNot(contains('limit')));
    });
  });

  group('reviewQueueHelp', () {
    test(
      'says what a changed line is, what the limit does and where to set it',
      () {
        final h = reviewQueueHelp(queue({'a': 5}));
        expect(h, contains('lines added plus removed'));
        expect(h, contains('review limit is 3 waiting workspaces'));
        expect(h, contains('never blocks one'));
        expect(h, contains('review_cap'));
        expect(h, isNot(contains('—')));
      },
    );

    test('with the limit off it does not describe one', () {
      final h = reviewQueueHelp(queue({'a': 5}, cap: 0));
      expect(h, isNot(contains('review limit is')));
      expect(h, contains('review_cap'));
    });
  });

  group('reviewCapWarning', () {
    final full = queue({'a': 500, 'b': 400, 'c': 300});

    test('warns once the limit is reached, in one line', () {
      final w = reviewCapWarning(full, 'z')!;
      expect(
        w,
        '3 other workspaces already wait for your review (1,200 changed lines). Another run adds to the pile.',
      );
      expect(w, isNot(contains('\n')));
    });

    test('reads right for one workspace', () {
      expect(
        reviewCapWarning(queue({'a': 1}, cap: 1), 'z'),
        '1 other workspace already waits for your review (1 changed line). Another run adds to the pile.',
      );
    });

    test('leaves out the workspace being typed in', () {
      expect(reviewCapWarning(full, 'a'), isNull);
    });

    test('is silent below the limit, with the limit off, or with no queue', () {
      expect(reviewCapWarning(queue({'a': 5, 'b': 5}), 'z'), isNull);
      expect(
        reviewCapWarning(queue({'a': 5, 'b': 5, 'c': 5}, cap: 0), 'z'),
        isNull,
      );
      expect(reviewCapWarning(null, 'z'), isNull);
    });

    test('never claims the work is good or bad', () {
      final w = reviewCapWarning(full, 'z')!.toLowerCase();
      for (final word in ['reviewed', 'risky', 'unsafe', 'blocked']) {
        expect(w, isNot(contains(word)));
      }
    });
  });
}
