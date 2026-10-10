import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards two house rules: the derivation layer stays free of widget imports (so it stays
/// unit-testable), and no source or copy contains an em-dash.
void main() {
  Iterable<File> sources(String dir) =>
      Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

  test('lib/state has no Flutter widget imports', () {
    for (final f in sources('lib/state')) {
      final src = f.readAsStringSync();
      expect(
        RegExp(r"import 'package:flutter/(widgets|material|cupertino)")
            .hasMatch(src),
        isFalse,
        reason: f.path,
      );
    }
  });

  test('lib/api and lib/state contain no em-dashes', () {
    for (final f in [...sources('lib/api'), ...sources('lib/state')]) {
      expect(f.readAsStringSync().contains('—'), isFalse, reason: f.path);
    }
  });
}
