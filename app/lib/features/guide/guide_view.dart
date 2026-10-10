import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/widgets.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import 'guide_content.dart';
import 'guide_model.dart';

/// The guide: topics down the left (grouped, with a search box), the open topic on the right.
class GuideView extends StatefulWidget {
  const GuideView({
    super.key,
    this.topics = guideTopics,
    this.initialTopic,
    this.onTopic,
  });

  final List<GuideTopic> topics;

  /// Id of the topic to open first; the first topic when null or unknown.
  final String? initialTopic;

  /// Told when the reader opens a topic, so the overlay can remember it.
  final ValueChanged<String>? onTopic;

  @override
  State<GuideView> createState() => _GuideViewState();
}

class _GuideViewState extends State<GuideView> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late String _id = _initial();

  String _initial() {
    final want = widget.initialTopic;
    return widget.topics.any((t) => t.id == want)
        ? want!
        : widget.topics.first.id;
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<GuideTopic>? _matches;
  String _matchesFor = '\u0000';

  /// The topics for the current query, worked out once per query (hover rebuilds are frequent).
  List<GuideTopic> get _found {
    final q = _query.text;
    if (_matches == null || _matchesFor != q) {
      _matches = searchGuide(widget.topics, q);
      _matchesFor = q;
    }
    return _matches!;
  }

  void _open(String id) {
    if (!widget.topics.any((t) => t.id == id)) return;
    // A link can lead to a topic the search has filtered out: show the whole guide again
    // instead of staying where you are.
    if (!_found.any((t) => t.id == id)) _query.clear();
    setState(() => _id = id);
    widget.onTopic?.call(id);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _found;
    final searching = _query.text.trim().isNotEmpty;
    final shown = matches.any((t) => t.id == _id)
        ? widget.topics.firstWhere((t) => t.id == _id)
        : (matches.isEmpty ? null : matches.first);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 244,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 16, 12),
                child: HaroTextField(
                  key: const ValueKey('guide-search'),
                  controller: _query,
                  hintText: 'Search the guide',
                  height: 32,
                  fontSize: 13,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(right: 16, bottom: 12),
                  children: [
                    if (searching && matches.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Nothing matches that. Try a simpler word.',
                          key: const ValueKey('guide-no-match'),
                          style: HaroText.ui(size: 13, color: HaroTokens.ink42),
                        ),
                      ),
                    for (final group in guideGroups)
                      ..._group(group, matches, searching, shown?.id),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(width: 1, color: HaroTokens.line08),
        Expanded(
          child: shown == null
              ? const SizedBox.shrink()
              : _TopicPage(
                  key: ValueKey('guide-page-${shown.id}'),
                  topic: shown,
                  topics: widget.topics,
                  scroll: _scroll,
                  onOpen: _open,
                ),
        ),
      ],
    );
  }

  List<Widget> _group(
    String group,
    List<GuideTopic> matches,
    bool searching,
    String? selected,
  ) {
    final inGroup = [
      for (final t in matches)
        if (t.group == group) t,
    ];
    if (inGroup.isEmpty) return const [];
    return [
      if (!searching)
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6, left: 2),
          child: Text(
            group,
            style: HaroText.mono(
              size: 10,
              color: HaroTokens.ink42,
              tracking: .16,
            ),
          ),
        ),
      for (final t in inGroup)
        _TopicRow(
          topic: t,
          selected: t.id == selected,
          onTap: () => _open(t.id),
        ),
    ];
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow({
    required this.topic,
    required this.selected,
    required this.onTap,
  });

  final GuideTopic topic;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    key: ValueKey('guide-topic-${topic.id}'),
    onTap: onTap,
    semanticLabel: topic.title,
    builder: (context, hovered) => Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: selected ? HaroTokens.ink : const Color(0x00000000),
            width: 2,
          ),
        ),
      ),
      child: Text(
        topic.title,
        style: HaroText.ui(
          size: 13.5,
          weight: selected ? FontWeight.w500 : FontWeight.w400,
          color: selected
              ? HaroTokens.ink
              : (hovered ? HaroTokens.ink86 : HaroTokens.ink66),
        ),
      ),
    ),
  );
}

class _TopicPage extends StatelessWidget {
  const _TopicPage({
    super.key,
    required this.topic,
    required this.topics,
    required this.scroll,
    required this.onOpen,
  });

  final GuideTopic topic;
  final List<GuideTopic> topics;
  final ScrollController scroll;
  final ValueChanged<String> onOpen;

  GuideTopic? get _next {
    final i = topics.indexWhere((t) => t.id == topic.id);
    return i >= 0 && i + 1 < topics.length ? topics[i + 1] : null;
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: scroll,
    padding: const EdgeInsets.fromLTRB(32, 0, 12, 28),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                topic.group,
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: .16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                topic.title,
                key: const ValueKey('guide-title'),
                style: HaroText.ui(
                  size: 26,
                  weight: FontWeight.w500,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 10),
              GuideText(
                topic.summary,
                style: HaroText.ui(
                  size: 15,
                  color: HaroTokens.ink66,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 22),
              for (final b in topic.blocks) ...[
                _Block(block: b, onOpen: onOpen, topics: topics),
                const SizedBox(height: 16),
              ],
              if (_next case final next?) ...[
                const SizedBox(height: 10),
                Container(height: 1, color: HaroTokens.line08),
                const SizedBox(height: 14),
                _NextLink(topic: next, onTap: () => onOpen(next.id)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Text with `**bold**`, `` `code` `` and `{mod}` rendered.
class GuideText extends StatelessWidget {
  const GuideText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  static final _marks = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');

  @override
  Widget build(BuildContext context) {
    final src = guideText(text);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _marks.allMatches(src)) {
      if (m.start > at) spans.add(TextSpan(text: src.substring(at, m.start)));
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: HaroTokens.ink,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: HaroText.mono(
              size: (style.fontSize ?? 14) * .9,
              color: HaroTokens.ink86,
              tracking: 0,
            ),
          ),
        );
      }
      at = m.end;
    }
    if (at < src.length) spans.add(TextSpan(text: src.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

TextStyle get _body =>
    HaroText.ui(size: 14.5, color: HaroTokens.ink86, height: 1.55);

class _Block extends StatelessWidget {
  const _Block({
    required this.block,
    required this.onOpen,
    required this.topics,
  });

  final GuideBlock block;
  final ValueChanged<String> onOpen;
  final List<GuideTopic> topics;

  @override
  Widget build(BuildContext context) => switch (block) {
    GuideParagraph b => GuideText(b.text, style: _body),
    GuideHeading b => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        b.text.toUpperCase(),
        style: HaroText.mono(size: 11, color: HaroTokens.ink66, tracking: .16),
      ),
    ),
    GuideSteps b => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, item) in b.items.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    '${i + 1}',
                    style: HaroText.mono(
                      size: 12,
                      color: HaroTokens.ink42,
                      tracking: 0,
                    ).copyWith(height: 1.9),
                  ),
                ),
                Expanded(child: GuideText(item, style: _body)),
              ],
            ),
          ),
      ],
    ),
    GuideBullets b => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in b.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18,
                  child: Text(
                    '·',
                    style: _body.copyWith(color: HaroTokens.ink42),
                  ),
                ),
                Expanded(child: GuideText(item, style: _body)),
              ],
            ),
          ),
      ],
    ),
    GuideTip b => Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line20),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            b.label,
            style: HaroText.mono(
              size: 10,
              color: HaroTokens.ink66,
              tracking: .16,
            ),
          ),
          const SizedBox(height: 6),
          GuideText(
            b.text,
            style: HaroText.ui(
              size: 13.5,
              color: HaroTokens.ink86,
              height: 1.5,
            ),
          ),
        ],
      ),
    ),
    GuideTerms b => _Terms(rows: b.rows),
    GuidePaths b => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in b.paths)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PathCard(path: p, onTap: () => onOpen(p.topic)),
          ),
      ],
    ),
    GuideSeeAlso b => Wrap(
      spacing: 18,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'SEE ALSO',
          style: HaroText.mono(
            size: 10,
            color: HaroTokens.ink42,
            tracking: .16,
          ),
        ),
        for (final id in b.topics)
          if (topics.where((t) => t.id == id).firstOrNull case final t?)
            HaroPressable(
              key: ValueKey('guide-see-$id'),
              onTap: () => onOpen(id),
              builder: (context, hovered) => Text(
                '${t.title} →',
                style: HaroText.ui(
                  size: 13.5,
                  color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                ),
              ),
            ),
      ],
    ),
  };
}

class _Terms extends StatelessWidget {
  const _Terms({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 520;
      return Column(
        children: [
          for (final r in rows)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: HaroTokens.line08)),
              ),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 170,
                          child: GuideText(
                            r.$1,
                            style: HaroText.ui(
                              size: 14,
                              weight: FontWeight.w500,
                              color: HaroTokens.ink,
                              height: 1.5,
                            ),
                          ),
                        ),
                        Expanded(child: GuideText(r.$2, style: _body)),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GuideText(
                          r.$1,
                          style: HaroText.ui(
                            size: 14,
                            weight: FontWeight.w500,
                            color: HaroTokens.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        GuideText(r.$2, style: _body),
                      ],
                    ),
            ),
        ],
      );
    },
  );
}

class _PathCard extends StatelessWidget {
  const _PathCard({required this.path, required this.onTap});

  final GuidePath path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    key: ValueKey('guide-path-${path.topic}'),
    onTap: onTap,
    semanticLabel: path.title,
    builder: (context, hovered) => Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        border: Border.all(
          color: hovered ? HaroTokens.line30 : HaroTokens.line20,
        ),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  path.title,
                  style: HaroText.ui(
                    size: 15,
                    weight: FontWeight.w500,
                    color: HaroTokens.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  path.text,
                  style: HaroText.ui(
                    size: 13.5,
                    color: HaroTokens.ink66,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '→',
            style: HaroText.ui(
              size: 16,
              color: hovered ? HaroTokens.ink : HaroTokens.ink42,
            ),
          ),
        ],
      ),
    ),
  );
}

class _NextLink extends StatelessWidget {
  const _NextLink({required this.topic, required this.onTap});

  final GuideTopic topic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    key: const ValueKey('guide-next'),
    onTap: onTap,
    builder: (context, hovered) => Row(
      children: [
        Text(
          'NEXT',
          style: HaroText.mono(
            size: 10,
            color: HaroTokens.ink42,
            tracking: .16,
          ),
        ),
        const SizedBox(width: 14),
        Text(
          '${topic.title} →',
          style: HaroText.ui(
            size: 15,
            weight: FontWeight.w500,
            color: hovered ? HaroTokens.ink : HaroTokens.ink86,
          ),
        ),
      ],
    ),
  );
}
