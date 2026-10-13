import '../../shortcuts/platform_keys.dart';

/// One piece of a guide topic. Text may carry `**bold**` and `` `code` ``, and `{mod}`, which is
/// shown as Cmd on macOS and Ctrl elsewhere.
sealed class GuideBlock {
  const GuideBlock();

  /// Every string in the block, for search.
  Iterable<String> get texts;
}

class GuideParagraph extends GuideBlock {
  const GuideParagraph(this.text);

  final String text;

  @override
  Iterable<String> get texts => [text];
}

/// A small heading inside a topic.
class GuideHeading extends GuideBlock {
  const GuideHeading(this.text);

  final String text;

  @override
  Iterable<String> get texts => [text];
}

class GuideSteps extends GuideBlock {
  const GuideSteps(this.items);

  final List<String> items;

  @override
  Iterable<String> get texts => items;
}

class GuideBullets extends GuideBlock {
  const GuideBullets(this.items);

  final List<String> items;

  @override
  Iterable<String> get texts => items;
}

/// A short aside: a way to save time, or something worth knowing before you click.
class GuideTip extends GuideBlock {
  const GuideTip(this.text, {this.label = 'TIP'});

  final String text;
  final String label;

  @override
  Iterable<String> get texts => [text];
}

/// Words and what they mean, one per row.
class GuideTerms extends GuideBlock {
  const GuideTerms(this.rows);

  final List<(String, String)> rows;

  @override
  Iterable<String> get texts => [
    for (final r in rows) ...[r.$1, r.$2],
  ];
}

/// Cards that send a reader to the topic that suits them.
class GuidePath {
  const GuidePath(this.title, this.text, this.topic);

  final String title;
  final String text;
  final String topic;
}

class GuidePaths extends GuideBlock {
  const GuidePaths(this.paths);

  final List<GuidePath> paths;

  @override
  Iterable<String> get texts => [
    for (final p in paths) ...[p.title, p.text],
  ];
}

/// Links to other topics, shown as a row under the content.
class GuideSeeAlso extends GuideBlock {
  const GuideSeeAlso(this.topics);

  final List<String> topics;

  @override
  Iterable<String> get texts => const [];
}

class GuideTopic {
  const GuideTopic({
    required this.id,
    required this.title,
    required this.group,
    required this.summary,
    required this.blocks,
  });

  final String id;
  final String title;
  final String group;

  /// One or two plain sentences under the title; also what search shows first.
  final String summary;
  final List<GuideBlock> blocks;

  Iterable<String> get texts => [
    title,
    summary,
    for (final b in blocks) ...b.texts,
  ];
}

/// `{mod}` as the platform's own name for the primary key.
String guideText(String text, {PrimaryModifier? modifier}) => text.replaceAll(
  '{mod}',
  (modifier ?? primaryModifier) == PrimaryModifier.meta ? 'Cmd' : 'Ctrl',
);

/// What the reader sees of [text]: the platform key name in place of `{mod}`, and no markup.
String plainGuideText(String text, {PrimaryModifier? modifier}) => guideText(
  text,
  modifier: modifier,
).replaceAll('**', '').replaceAll('`', '');

/// The lowercased visible text of each topic, with `{mod}` still in it (the platform can change
/// between searches, the rest cannot).
final _haystacks = Expando<String>('guideHaystack');

String _haystack(GuideTopic t) => _haystacks[t] ??= t.texts
    .map((s) => s.replaceAll('**', '').replaceAll('`', ''))
    .join('\n')
    .toLowerCase();

/// Topics whose title, summary or text contain every word of [query] (case-insensitive), as the
/// reader sees them (`Ctrl+K`, not `{mod}+K`). A blank query matches everything, in the original
/// order.
List<GuideTopic> searchGuide(
  List<GuideTopic> topics,
  String query, {
  PrimaryModifier? modifier,
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return topics;
  final mod = (modifier ?? primaryModifier) == PrimaryModifier.meta
      ? 'cmd'
      : 'ctrl';
  return [
    for (final t in topics)
      if (() {
        final hay = _haystack(t).replaceAll('{mod}', mod);
        return words.every(hay.contains);
      }())
        t,
  ];
}
