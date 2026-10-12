import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/verify/review_dwell.dart';

void main() {
  final t0 = DateTime(2026, 10, 10, 9);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('a file never opened has zero seconds', () {
    expect(ReviewDwell().seconds('a.ts', at(30)), 0);
  });

  test('counts a stretch still open and sums stretches', () {
    final d = ReviewDwell()..update({'a.ts'}, at(0));
    expect(d.seconds('a.ts', at(7)), 7);
    d.update({}, at(10));
    expect(d.seconds('a.ts', at(60)), 10);
    d.update({'a.ts'}, at(60));
    expect(d.seconds('a.ts', at(65)), 15);
  });

  test('tracks files independently', () {
    final d = ReviewDwell()
      ..update({'a.ts', 'b.ts'}, at(0))
      ..update({'b.ts'}, at(4));
    expect(d.seconds('a.ts', at(20)), 4);
    expect(d.seconds('b.ts', at(20)), 20);
  });

  test('reset starts a file over', () {
    final d = ReviewDwell()
      ..update({'a.ts'}, at(0))
      ..update({}, at(9))
      ..reset('a.ts', at(9));
    expect(d.seconds('a.ts', at(30)), 0);
  });
}
