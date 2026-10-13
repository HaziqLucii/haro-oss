import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The middle dot as a text separator (`Sort inbox · 4`, `path · 6 h ago`, `···`) is gone from the
/// app: a count is a tag (`HaroTag`, `HaroButton.count`, `MonoCaption.count`), a menu is a Lucide
/// icon button, facts are separate widgets or read as plain words. This keeps it that way.
void main() {
  test('no middle dot in the app source (outside comments)', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trimLeft();
        if (t.startsWith('//')) continue;
        final l = lines[i].toLowerCase();
        if (l.contains('·') || l.contains(r'·')) {
          hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
