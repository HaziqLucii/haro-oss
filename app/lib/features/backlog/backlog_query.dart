import '../../api/models/models.dart';

/// The Backlog's filter language for todos, the same operators the backend's search reads
/// (`backend/haro/backlog_find.py`): `tag:ui`, `stage:red`, `is:ready`, `path:backlog/`, plain
/// words (AND, case-insensitive), `-word` / `-key:value` to exclude, `"two words"` as one term.
class TodoQuery {
  const TodoQuery({
    this.terms = const [],
    this.negTerms = const [],
    this.flt = const [],
    this.negFlt = const [],
  });

  final List<String> terms;
  final List<String> negTerms;
  final List<(String, String)> flt;
  final List<(String, String)> negFlt;

  bool get isEmpty =>
      terms.isEmpty && negTerms.isEmpty && flt.isEmpty && negFlt.isEmpty;

  bool wants(String key, String value) => flt.contains((key, value));

  static const _keys = {'tag', 'stage', 'in', 'path', 'file', 'is'};

  factory TodoQuery.parse(String q) {
    final tokens = <String>[];
    final cur = StringBuffer();
    var quoted = false;
    for (final ch in q.split('')) {
      if (ch == '"') {
        quoted = !quoted;
      } else if (!quoted && ch.trim().isEmpty) {
        if (cur.isNotEmpty) tokens.add(cur.toString());
        cur.clear();
      } else {
        cur.write(ch);
      }
    }
    if (cur.isNotEmpty) tokens.add(cur.toString());
    final terms = <String>[], neg = <String>[];
    final flt = <(String, String)>[], nflt = <(String, String)>[];
    for (final tok in tokens) {
      final negated = tok.startsWith('-') && tok.length > 1;
      final body = negated ? tok.substring(1) : tok;
      final i = body.indexOf(':');
      if (i > 0 &&
          i < body.length - 1 &&
          _keys.contains(body.substring(0, i).toLowerCase())) {
        var v = body.substring(i + 1).toLowerCase();
        if (v.startsWith('#')) v = v.substring(1);
        (negated ? nflt : flt).add((body.substring(0, i).toLowerCase(), v));
      } else if (body.isNotEmpty) {
        (negated ? neg : terms).add(body.toLowerCase());
      }
    }
    return TodoQuery(terms: terms, negTerms: neg, flt: flt, negFlt: nflt);
  }

  /// The same query with `tag:<tag>` added (or removed when it is there): a tag chip's click.
  static String toggleTag(String q, String tag) {
    final token = 'tag:$tag';
    final parts = q
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.contains(token)) {
      parts.remove(token);
    } else {
      parts.add(token);
    }
    return parts.join(' ');
  }
}

/// One item matched against a query, with where it lives (for opening it).
class TodoHit {
  const TodoHit(this.file, this.index, this.item);

  final TodoFile file;
  final int index;
  final TodoItem item;
}

bool _tagMatch(List<String> tags, String want) =>
    tags.any((t) => t == want || t.startsWith('$want/'));

bool _filterOk(TodoFile f, TodoItem it, String key, String value) {
  switch (key) {
    case 'tag':
      return _tagMatch(it.tags, value);
    case 'stage':
      return it.stage == value;
    case 'in':
      return value == 'todo' || value == 'todos';
    case 'path':
    case 'file':
      return f.path.toLowerCase().contains(value);
    case 'is':
      return switch (value) {
        'done' || 'closed' => it.done,
        'open' => !it.done,
        'pinned' => it.pinned,
        'blocked' => it.blocked,
        'snoozed' => it.snoozed,
        'archived' => it.archived,
        'ready' =>
          !it.done &&
              !it.blocked &&
              !it.snoozed &&
              !it.archived &&
              (it.stage == null || it.stage == 'ready'),
        _ => false,
      };
  }
  return true;
}

bool todoMatches(TodoFile f, TodoItem it, TodoQuery q) {
  if (it.archived && !q.wants('is', 'archived')) return false;
  if (q.flt.any((p) => !_filterOk(f, it, p.$1, p.$2))) return false;
  if (q.negFlt.any((p) => _filterOk(f, it, p.$1, p.$2))) return false;
  final hay = '${it.text}\n${it.body}\n${f.path}\n${it.tags.join(' ')}'
      .toLowerCase();
  return q.terms.every(hay.contains) && !q.negTerms.any(hay.contains);
}

/// Every item of [files] that matches [q], pinned first, then file order.
List<TodoHit> filterTodos(List<TodoFile> files, TodoQuery q) {
  final hits = <TodoHit>[
    for (final f in files)
      for (var i = 0; i < f.items.length; i++)
        if (todoMatches(f, f.items[i], q)) TodoHit(f, i, f.items[i]),
  ];
  final pinned = [
    for (final h in hits)
      if (h.item.pinned) h,
  ];
  return [
    ...pinned,
    for (final h in hits)
      if (!h.item.pinned) h,
  ];
}

/// The board's columns, in order. `blocked` is a ready item an unfinished dependency holds back.
const boardColumns = <(String, String)>[
  ('ready', 'Ready'),
  ('blocked', 'Blocked'),
  ('queued', 'Queued'),
  ('running', 'Running'),
  ('red', 'Red'),
  ('green', 'Green'),
  ('shipped', 'Shipped'),
];

/// Which column an item sits in, or null when the board leaves it out: a done item nobody started
/// (ticked by hand), a snoozed one, an archived one (unless the query asked for them).
String? boardColumnOf(TodoItem it, TodoQuery q) {
  final stage = it.stage ?? 'ready';
  if (it.archived && !q.wants('is', 'archived')) return null;
  if (it.snoozed && !q.wants('is', 'snoozed')) return null;
  if (it.done && stage == 'ready' && !q.wants('is', 'done')) return null;
  if (stage == 'ready' && it.blocked) return 'blocked';
  return stage;
}

/// How alike two item texts are, 0..1 (shared words over all words): sorting the inbox warns at a high
/// value, plain text matching and nothing smarter.
double textSimilarity(String a, String b) {
  Set<String> words(String s) => {
    for (final w in s.toLowerCase().split(
      RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    ))
      if (w.length > 2) w,
  };
  final x = words(a), y = words(b);
  if (x.isEmpty || y.isEmpty) return 0;
  return x.intersection(y).length / x.union(y).length;
}

/// The item most like [text] in [files] when it is alike enough to mention, else null.
TodoHit? similarTodo(
  List<TodoFile> files,
  String text, {
  TodoHit? except,
  double atLeast = .6,
}) {
  TodoHit? best;
  var bestScore = atLeast;
  for (final f in files) {
    for (var i = 0; i < f.items.length; i++) {
      final it = f.items[i];
      if (except != null && identical(it, except.item)) continue;
      final s = textSimilarity(text, it.text);
      if (s >= bestScore) {
        bestScore = s;
        best = TodoHit(f, i, it);
      }
    }
  }
  return best;
}
