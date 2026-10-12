import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/notes_model.dart';

void main() {
  group('lineOrSelection', () {
    const text = 'first line\n- [ ] second line\n\nlast';
    test('a collapsed cursor takes its line', () {
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: 3)),
        'first line',
      );
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: 15)),
        '- [ ] second line',
      );
      expect(
        lineOrSelection(
          text,
          const TextSelection.collapsed(offset: text.length),
        ),
        'last',
      );
    });

    test('a blank line gives nothing', () {
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: 29)),
        '',
      );
    });

    test('a selection wins over the line', () {
      expect(
        lineOrSelection(
          text,
          const TextSelection(baseOffset: 6, extentOffset: 10),
        ),
        'line',
      );
    });

    test('an invalid selection gives nothing', () {
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: -1)),
        '',
      );
    });
  });

  group('todoTextFrom', () {
    test('drops bullets, checkboxes, headings and numbers', () {
      expect(todoTextFrom('- [ ] cache the lookups'), 'cache the lookups');
      expect(todoTextFrom('* [x] done thing'), 'done thing');
      expect(todoTextFrom('## Caching'), 'Caching');
      expect(todoTextFrom('3. third idea'), 'third idea');
      expect(todoTextFrom('plain'), 'plain');
    });

    test('folds several lines onto one', () {
      expect(todoTextFrom('- one\n\n- two\n  three'), 'one two three');
    });
  });

  group('notePathFrom', () {
    test('adds .md and joins spaces', () {
      expect(notePathFrom('caching ideas'), 'caching-ideas.md');
      expect(notePathFrom('design/api'), 'design/api.md');
      expect(notePathFrom('Keep.MD'), 'Keep.MD');
    });

    test('refuses anything that is not a plain relative name', () {
      for (final bad in ['', '  ', '/etc/x', '../x', 'a/../b', 'folder/']) {
        expect(notePathFrom(bad), isNull, reason: bad);
      }
    });
  });

  test('noteTitleFor reads the file name', () {
    expect(noteTitleFor('caching-ideas.md'), 'Caching ideas');
    expect(noteTitleFor('design/api_sketch.md'), 'Api sketch');
    expect(noteTitleFor('.md'), 'Note');
  });

  test('relativeTime', () {
    final now = DateTime(2026, 10, 10, 12);
    double ago(Duration d) => now.subtract(d).millisecondsSinceEpoch / 1000;
    expect(relativeTime(ago(const Duration(seconds: 20)), now), 'just now');
    expect(relativeTime(ago(const Duration(minutes: 5)), now), '5 min ago');
    expect(relativeTime(ago(const Duration(hours: 3)), now), '3 h ago');
    expect(relativeTime(ago(const Duration(days: 2)), now), '2 d ago');
    expect(relativeTime(ago(const Duration(days: 60)), now), '2026-08-11');
  });
}
