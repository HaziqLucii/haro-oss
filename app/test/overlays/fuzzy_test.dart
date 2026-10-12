import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/overlays/fuzzy.dart';

void main() {
  test('non-subsequence does not match', () {
    expect(fuzzyMatch('zz', 'gate'), isNull);
    expect(fuzzyMatch('etag', 'gate'), isNull);
  });

  test('case-insensitive subsequence with positions', () {
    final m = fuzzyMatch('GT', 'gate')!;
    expect(m.positions, [0, 2]);
  });

  test('empty query matches everything with score 0', () {
    expect(fuzzyMatch('', 'anything')!.score, 0);
  });

  test('word starts and consecutive runs outrank scattered letters', () {
    final start = fuzzyMatch('sh', 'shipping cost')!.score;
    final scattered = fuzzyMatch('sh', 'a swarm hole')!.score;
    expect(start, greaterThan(scattered));
  });

  test('fuzzyFind ranks best first and drops non-matches', () {
    final r = fuzzyFind<String>('gate', [
      'Toggle terminal',
      'Run gate',
      'Gate',
      'Delete merged workspaces',
    ], (s) => s);
    expect(r.map((e) => e.value), ['Gate', 'Run gate']);
  });

  test('empty query keeps the given order', () {
    final r = fuzzyFind<String>('  ', ['b', 'a'], (s) => s);
    expect(r.map((e) => e.value), ['b', 'a']);
  });
}
