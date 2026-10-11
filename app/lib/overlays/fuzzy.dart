/// fzf-style subsequence scorer, ported from the React client's `fuzzy.ts`. Greedy left to
/// right on purpose: lists are small and queries short, so boundary and run bonuses do the
/// ranking work.
class FuzzyMatch {
  const FuzzyMatch(this.score, this.positions);

  final double score;

  /// Indices in the target that matched a query character.
  final List<int> positions;
}

// A match after one of these reads as the start of a new word.
const _boundary = {'/', '_', '-', '.', ' '};

bool _isLower(String c) => c == c.toLowerCase() && c != c.toUpperCase();

/// Null when [query] is not a subsequence of [target] (case-insensitive). Higher is better.
FuzzyMatch? fuzzyMatch(String query, String target) {
  if (query.isEmpty) return const FuzzyMatch(0, []);
  final q = query.toLowerCase();
  final t = target.toLowerCase();
  final positions = <int>[];
  var score = 0.0;
  var qi = 0;
  var prevMatch = -2;
  for (var ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t[ti] != q[qi]) continue;
    positions.add(ti);
    var bonus = 0;
    if (ti == prevMatch + 1) bonus += 8;
    if (ti == 0) {
      bonus += 12;
    } else {
      final prev = target[ti - 1];
      if (prev == '/') {
        bonus += 10;
      } else if (_boundary.contains(prev)) {
        bonus += 8;
      } else if (_isLower(prev) && target[ti] != t[ti]) {
        bonus += 7;
      }
    }
    score += 1 + bonus;
    prevMatch = ti;
    qi++;
  }
  if (qi < q.length) return null;
  score -= positions.first * 0.15;
  score -= target.length * 0.02;
  return FuzzyMatch(score, positions);
}

class FuzzyResult<T> {
  const FuzzyResult(this.value, this.score, this.positions);

  final T value;
  final double score;
  final List<int> positions;
}

/// Ranks [items] against [query], best first. An empty query keeps the given order.
/// [text] is what gets matched. Ties fall back to shorter text, then original order.
List<FuzzyResult<T>> fuzzyFind<T>(
  String query,
  List<T> items,
  String Function(T) text,
) {
  final q = query.trim();
  if (q.isEmpty) return [for (final i in items) FuzzyResult(i, 0, const [])];
  final out = <(FuzzyResult<T>, int)>[];
  for (var i = 0; i < items.length; i++) {
    final m = fuzzyMatch(q, text(items[i]));
    if (m != null) out.add((FuzzyResult(items[i], m.score, m.positions), i));
  }
  out.sort((a, b) {
    final byScore = b.$1.score.compareTo(a.$1.score);
    if (byScore != 0) return byScore;
    final byLen = text(a.$1.value).length.compareTo(text(b.$1.value).length);
    return byLen != 0 ? byLen : a.$2.compareTo(b.$2);
  });
  return [for (final r in out) r.$1];
}
