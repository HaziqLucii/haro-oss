/// GitHub issue text uses `<details><summary>..</summary>..</details>`, which the markdown
/// renderer shows as raw tags. This splits a text into plain markdown and collapsible blocks
/// so [AgentProse] can draw the blocks itself.
library;

sealed class ProseSegment {
  const ProseSegment();
}

class MarkdownSegment extends ProseSegment {
  const MarkdownSegment(this.text);
  final String text;
}

class DetailsSegment extends ProseSegment {
  const DetailsSegment({
    required this.summary,
    required this.body,
    required this.open,
  });

  final String summary;
  final String body;

  /// The `open` attribute: GitHub draws the block expanded.
  final bool open;
}

final _tag = RegExp(r'<(/?)details\b([^>]*)>', caseSensitive: false);
final _summary = RegExp(
  r'^\s*<summary[^>]*>(.*?)</summary>',
  caseSensitive: false,
  dotAll: true,
);
final _anyTag = RegExp(r'<[^>]+>');
final _open = RegExp(r'(^|\s)open(\s|=|$)', caseSensitive: false);

/// Character ranges inside a fenced code block, where a literal `<details>` is code.
List<(int, int)> _fenced(String text) {
  final ranges = <(int, int)>[];
  int? start;
  var offset = 0;
  for (final line in text.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) {
      if (start == null) {
        start = offset;
      } else {
        ranges.add((start, offset + line.length));
        start = null;
      }
    }
    offset += line.length + 1;
  }
  if (start != null) ranges.add((start, text.length));
  return ranges;
}

bool _startsLine(String text, int i) {
  for (var j = i - 1; j >= 0; j--) {
    final c = text[j];
    if (c == '\n') return true;
    if (c != ' ' && c != '\t') return false;
  }
  return true;
}

/// A text with no complete `<details>` block comes back as one [MarkdownSegment] holding it
/// unchanged. An unclosed block is left as it is.
List<ProseSegment> splitDetails(String text) {
  if (!text.contains(RegExp('<details', caseSensitive: false))) {
    return [MarkdownSegment(text)];
  }
  final fenced = _fenced(text);
  bool inFence(int i) => fenced.any((r) => i >= r.$1 && i < r.$2);

  final out = <ProseSegment>[];
  var cursor = 0;
  var depth = 0;
  var blockStart = 0;
  var bodyStart = 0;
  var isOpen = false;
  for (final m in _tag.allMatches(text)) {
    if (inFence(m.start)) continue;
    final closing = m.group(1) == '/';
    // A block starts at the head of a line, as GitHub reads it, so a sentence that mentions
    // `<details>` in inline code is left alone. Inside a block any tag counts.
    if (depth == 0 && (closing || !_startsLine(text, m.start))) continue;
    if (!closing) {
      if (depth == 0) {
        blockStart = m.start;
        bodyStart = m.end;
        isOpen = _open.hasMatch(m.group(2) ?? '');
      }
      depth++;
    } else if (depth > 0) {
      depth--;
      if (depth == 0) {
        if (blockStart > cursor) {
          out.add(MarkdownSegment(text.substring(cursor, blockStart)));
        }
        var body = text.substring(bodyStart, m.start);
        var summary = 'Details';
        final s = _summary.firstMatch(body);
        if (s != null) {
          final plain = s
              .group(1)!
              .replaceAll(_anyTag, '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (plain.isNotEmpty) summary = plain;
          body = body.substring(s.end);
        }
        out.add(
          DetailsSegment(summary: summary, body: body.trim(), open: isOpen),
        );
        cursor = m.end;
      }
    }
  }
  if (cursor < text.length) out.add(MarkdownSegment(text.substring(cursor)));
  return out.isEmpty ? [MarkdownSegment(text)] : out;
}
