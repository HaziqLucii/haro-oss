import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/backlog/backlog_query.dart';

TodoItem item(
  String text, {
  bool done = false,
  List<String> tags = const [],
  String? stage,
  bool blocked = false,
  bool pinned = false,
  bool snoozed = false,
  bool archived = false,
}) => TodoItem(
  text: text,
  done: done,
  tags: tags,
  stage: stage,
  blocked: blocked,
  pinned: pinned,
  snoozed: snoozed,
  archived: archived,
);

final file = TodoFile(
  path: 'backlog/a.md',
  items: [
    item('fix the cart bug', tags: ['ui'], stage: 'red'),
    item('cart refactor', tags: ['perf/db'], done: true),
    item('wait for api', blocked: true, stage: 'ready'),
    item('old idea', archived: true),
    item('pin me', pinned: true),
  ],
);

List<String> texts(String q) => [
  for (final h in filterTodos([file], TodoQuery.parse(q))) h.item.text,
];

void main() {
  test(
    'operators filter, words are ANDed, a parent tag matches its children',
    () {
      expect(texts('cart tag:ui'), ['fix the cart bug']);
      expect(texts('tag:perf'), ['cart refactor']);
      expect(texts('stage:red'), ['fix the cart bug']);
      expect(texts('cart -is:done'), ['fix the cart bug']);
      expect(texts('"cart bug"'), ['fix the cart bug']);
      expect(texts('path:a.md is:blocked'), ['wait for api']);
      expect(texts('cart -refactor'), ['fix the cart bug']);
    },
  );

  test('archived is hidden unless asked for, pinned comes first', () {
    expect(texts(''), isNot(contains('old idea')));
    expect(texts('is:archived'), ['old idea']);
    expect(texts('')[0], 'pin me');
  });

  test('is:ready leaves out done, blocked, snoozed and archived items', () {
    // the red one has a workspace; the blocked, done and archived ones are out
    expect(texts('is:ready'), ['pin me']);
  });

  test('toggleTag adds and removes a tag token', () {
    expect(TodoQuery.toggleTag('cart', 'ui'), 'cart tag:ui');
    expect(TodoQuery.toggleTag('cart tag:ui', 'ui'), 'cart');
  });

  test('the board puts blocked ready items apart and leaves some out', () {
    const q = TodoQuery();
    expect(boardColumnOf(item('a', stage: 'red'), q), 'red');
    expect(boardColumnOf(item('a', blocked: true), q), 'blocked');
    expect(boardColumnOf(item('a'), q), 'ready');
    expect(boardColumnOf(item('a', done: true), q), isNull);
    expect(boardColumnOf(item('a', snoozed: true), q), isNull);
    expect(boardColumnOf(item('a', archived: true), q), isNull);
    expect(
      boardColumnOf(item('a', archived: true), TodoQuery.parse('is:archived')),
      'ready',
    );
  });

  test('similar texts are noticed, unrelated ones are not', () {
    expect(
      textSimilarity('fix the cart bug', 'fix cart bug now') >= .5,
      isTrue,
    );
    expect(
      textSimilarity('fix the cart bug', 'write the release notes') < .3,
      isTrue,
    );
    final hit = similarTodo([file], 'cart bug fix please', atLeast: .4);
    expect(hit?.item.text, 'fix the cart bug');
    expect(similarTodo([file], 'something else entirely'), isNull);
  });
}
