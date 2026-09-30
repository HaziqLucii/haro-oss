import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../api/models/models.dart';
import '../../../../../data/workspace_store.dart';

/// Shortest query worth sending: one character matches half the tree.
const int minSearchChars = 2;

class SearchHit {
  const SearchHit({
    required this.line,
    required this.pre,
    required this.match,
    required this.post,
  });

  final int line;
  final String pre;

  /// The part to mark. Empty when the query is a pattern whose literal text is not on the line.
  final String match;
  final String post;
}

class SearchGroup {
  const SearchGroup(this.file, this.hits);

  final String file;
  final List<SearchHit> hits;
}

/// A line cut around the query: a little context before it, a little after, leading
/// whitespace dropped. The backend searches with a regex (ripgrep, smart-case), so the mark is
/// only drawn when the query also occurs literally on the line.
SearchHit snippetFor(SearchMatch m, String query) {
  final text = m.text.trimLeft();
  final at = query.isEmpty ? -1 : _indexOfFold(text, query);
  if (at < 0) {
    return SearchHit(line: m.line, pre: '', match: '', post: _clip(text, 60));
  }
  final start = at > 14 ? at - 14 : 0;
  final end = at + query.length;
  return SearchHit(
    line: m.line,
    pre: text.substring(start, at),
    match: text.substring(at, end),
    post: _clip(text.substring(end), 30),
  );
}

int _indexOfFold(String text, String query) =>
    text.toLowerCase().indexOf(query.toLowerCase());

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);

/// Matches grouped by file, files in the order ripgrep first reported them.
List<SearchGroup> groupMatches(List<SearchMatch> matches, String query) {
  final byFile = <String, List<SearchHit>>{};
  for (final m in matches) {
    (byFile[m.file] ??= []).add(snippetFor(m, query));
  }
  return [for (final e in byFile.entries) SearchGroup(e.key, e.value)];
}

/// `N results in M files`, with the singular forms and an "at least" once the backend cut
/// the list short.
String searchSummary(List<SearchGroup> groups, {bool truncated = false}) {
  final hits = groups.fold<int>(0, (n, g) => n + g.hits.length);
  if (hits == 0) return 'No results';
  final more = truncated ? '+' : '';
  final files = groups.length;
  return '$hits$more ${hits == 1 ? 'result' : 'results'} in $files '
      '${files == 1 ? 'file' : 'files'}';
}

/// Find-in-files for one workspace and query. Nothing is requested below [minSearchChars].
final workspaceSearchProvider = FutureProvider.autoDispose
    .family<SearchResult, (String, String)>((ref, key) {
      final (id, q) = key;
      if (q.trim().length < minSearchChars) {
        return Future.value(const SearchResult());
      }
      return ref.read(haroApiProvider).searchFiles(id, q.trim());
    });
