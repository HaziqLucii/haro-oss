import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/shortcuts/need_you.dart';

void main() {
  const ids = ['a', 'b', 'c'];

  test('moves to the one after the current workspace', () {
    expect(nextNeedYou(ids, 'a'), 'b');
    expect(nextNeedYou(ids, 'b'), 'c');
  });

  test('wraps from the last to the first', () {
    expect(nextNeedYou(ids, 'c'), 'a');
  });

  test('starts at the first when nothing or an unlisted workspace is open', () {
    expect(nextNeedYou(ids, null), 'a');
    expect(nextNeedYou(ids, 'green-one'), 'a');
  });

  test('returns null when nothing needs you', () {
    expect(nextNeedYou(const [], 'a'), isNull);
    expect(nextNeedYou(const [], null), isNull);
  });

  test('a single workspace cycles to itself', () {
    expect(nextNeedYou(const ['a'], 'a'), 'a');
  });
}
