import '../../widgets/shell_icons.dart';

import 'package:flutter/widgets.dart';

/// The line a "Make todo" acts on: the selection if there is one, else the line the cursor is
/// on. Empty when the cursor sits on a blank line.
String lineOrSelection(String text, TextSelection sel) {
  if (!sel.isValid) return '';
  if (!sel.isCollapsed) {
    final a = sel.start.clamp(0, text.length);
    final b = sel.end.clamp(0, text.length);
    return text.substring(a, b).trim();
  }
  final at = sel.baseOffset.clamp(0, text.length);
  final start = at == 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;
  var end = text.indexOf('\n', at);
  if (end < 0) end = text.length;
  return text.substring(start, end).trim();
}

/// Turns a note line into a todo title: drops the bullet, the checkbox and heading marks, and
/// folds a multi-line selection onto one line.
String todoTextFrom(String raw) {
  final lines = raw
      .split('\n')
      .map(
        (l) => l
            .trim()
            .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
            .replaceFirst(RegExp(r'^[-*+]\s+(\[[ xX]\]\s+)?'), '')
            .replaceFirst(RegExp(r'^\d+[.)]\s+'), '')
            .trim(),
      )
      .where((l) => l.isNotEmpty);
  return lines.join(' ');
}

/// `ideas` -> `ideas.md`; a name with a folder keeps it; anything that is not a plain relative
/// name returns null (the backend rejects the rest too).
String? notePathFrom(String raw) {
  var p = raw.trim().replaceAll(RegExp(r'\s+'), '-');
  if (p.isEmpty || p.startsWith('/') || p.endsWith('/') || p.contains('..')) {
    return null;
  }
  if (!p.toLowerCase().endsWith('.md')) p = '$p.md';
  return p;
}

/// The file's own name without `.md`: what the tree shows, so a rename is visible there.
String noteFileLabel(String path) => path
    .substring(path.lastIndexOf('/') + 1)
    .replaceFirst(RegExp(r'\.md$', caseSensitive: false), '');

String noteTitleFor(String path) {
  final base = path.substring(path.lastIndexOf('/') + 1);
  final stem = base.replaceFirst(RegExp(r'\.md$', caseSensitive: false), '');
  final t = stem.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  return t.isEmpty ? 'Note' : t[0].toUpperCase() + t.substring(1);
}

/// `just now`, `5 min ago`, `3 h ago`, `2 d ago`, then the date.
String relativeTime(double epochSeconds, DateTime now) {
  final then = DateTime.fromMillisecondsSinceEpoch(
    (epochSeconds * 1000).round(),
  );
  final d = now.difference(then);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  final m = then.month.toString().padLeft(2, '0');
  final day = then.day.toString().padLeft(2, '0');
  return '${then.year}-$m-$day';
}

// ---- wikilinks and tags (the same syntax and rules as backend/haro/notes_links.py) ----

final _wiki = RegExp(
  r'\[\[([^\[\]\n|#]+?)(?:#([^\[\]\n|]*))?(?:\|([^\[\]\n]*))?\]\]',
);
final _tag = RegExp(
  r'(?<![\p{L}\p{N}_/&#\[(=])#(\p{L}[\p{L}\p{N}_/-]*)',
  unicode: true,
);

/// The line with inline code spans blanked: a backtick run opens a span the next run of the same
/// length closes. A linear scan (a regex for this backtracks badly on long runs of backticks).
String _maskInline(String line) {
  final units = line.codeUnits.toList();
  const tick = 0x60;
  final n = units.length;
  var i = 0;
  while (i < n) {
    if (units[i] != tick) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && units[j] == tick) {
      j++;
    }
    final run = j - i;
    var k = j;
    var close = -1;
    while (true) {
      k = line.indexOf('`', k);
      if (k == -1) break;
      var e = k;
      while (e < n && units[e] == tick) {
        e++;
      }
      if (e - k == run) {
        close = e;
        break;
      }
      k = e;
    }
    if (close == -1) {
      i = j;
      continue;
    }
    for (var x = i; x < close; x++) {
      units[x] = 0x20;
    }
    i = close;
  }
  return String.fromCharCodes(units);
}

/// (marker, length) when the line opens a fenced block: up to three spaces of indent, then three
/// or more backticks (none after them) or tildes.
(String, int)? _fenceOpen(String line) {
  final stripped = line.replaceFirst(RegExp(r'^ +'), '');
  if (line.length - stripped.length > 3) return null;
  for (final ch in const ['`', '~']) {
    if (stripped.startsWith(ch * 3)) {
      var run = 0;
      while (run < stripped.length && stripped[run] == ch) {
        run++;
      }
      if (ch == '`' && stripped.substring(run).contains('`')) return null;
      return (ch, run);
    }
  }
  return null;
}

/// The text with fenced blocks and inline code blanked out (same length), so a `[[x]]` or `#tag`
/// in an example is not read as a link. Only `\n` ends a line, as in the backend's copy.
String maskCode(String text) {
  final out = <String>[];
  (String, int)? fence;
  for (final line in text.split('\n')) {
    final open = fence;
    if (open != null) {
      out.add(' ' * line.length);
      final body = line.replaceAll(RegExp(r'^ +| +$'), '');
      final indent = line.length - line.replaceFirst(RegExp(r'^ +'), '').length;
      if (body.isNotEmpty &&
          body.split('').every((c) => c == open.$1) &&
          body.length >= open.$2 &&
          indent <= 3) {
        fence = null;
      }
      continue;
    }
    final opening = _fenceOpen(line);
    if (opening != null) {
      fence = opening;
      out.add(' ' * line.length);
    } else {
      out.add(_maskInline(line));
    }
  }
  return out.join('\n');
}

String _enc(String v) =>
    Uri.encodeComponent(v).replaceAll('(', '%28').replaceAll(')', '%29');

const noteLinkScheme = 'haro-note:';
const noteTagScheme = 'haro-tag:';
const todoLinkScheme = 'haro-todo:';
const issueLinkScheme = 'haro-issue:';
const codeLinkScheme = 'haro-code:';
const fileLinkScheme = 'haro-file:';

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp'};
const _fileExts = {
  'pdf',
  'xlsx',
  'xls',
  'xlsm',
  'csv',
  'ods',
  'docx',
  'doc',
  'odt',
  'rtf',
  'pptx',
  'ppt',
  'txt',
  'sql',
  'json',
  'log',
  'tsv',
  'yaml',
  'yml',
  'toml',
  'svg',
  'excalidraw',
};

String _extOf(String target) {
  final base = target.split('/').last;
  final i = base.lastIndexOf('.');
  return i <= 0 ? '' : base.substring(i + 1).toLowerCase();
}

/// The file link's target (a path, or a name as Obsidian writes it), or null for any other link.
String? fileLinkFrom(String url) => url.startsWith(fileLinkScheme)
    ? Uri.decodeComponent(url.substring(fileLinkScheme.length))
    : null;

/// A Lucide icon for a file by the kind the backend reports.
ShellIcon fileIconFor(String kind) => switch (kind) {
  'sheet' => ShellIcon.fileSheet,
  'image' => ShellIcon.image,
  'drawing' => ShellIcon.drawing,
  'text' => ShellIcon.fileCode,
  _ => ShellIcon.fileText,
};

final _issueRef = RegExp(
  r'(?<![\p{L}\p{N}_/&#\[(=])#(\d+)(?![\p{L}\p{N}_])',
  unicode: true,
);
final _codeRef = RegExp(r'`([A-Za-z0-9_./\-]+\.[A-Za-z0-9]+):(\d+)(?:-\d+)?`');

/// Character ranges of fenced code blocks, so a `path:line` in an example is left alone.
List<(int, int)> _fenceRanges(String text) {
  final out = <(int, int)>[];
  (String, int)? fence;
  var offset = 0;
  int? start;
  for (final line in text.split('\n')) {
    final end = offset + line.length;
    final open = fence;
    if (open != null) {
      final body = line.replaceAll(RegExp(r'^ +| +$'), '');
      final indent = line.length - line.replaceFirst(RegExp(r'^ +'), '').length;
      if (body.isNotEmpty &&
          body.split('').every((c) => c == open.$1) &&
          body.length >= open.$2 &&
          indent <= 3) {
        fence = null;
        out.add((start!, end));
      }
    } else {
      final opening = _fenceOpen(line);
      if (opening != null) {
        fence = opening;
        start = offset;
      }
    }
    offset = end + 1;
  }
  if (fence != null && start != null) out.add((start, text.length));
  return out;
}

/// Turns `[[target|shown]]` into a markdown link `[shown](haro-note:target)` and `#tag` into
/// `[#tag](haro-tag:tag)`, outside code, so the note's View can draw them as links the tab handles.
String wikiToMarkdown(String text, {Set<String> knownFiles = const {}}) {
  final masked = maskCode(text);
  final edits = <(int, int, String)>[];
  for (final m in _wiki.allMatches(masked)) {
    final target = m.group(1)!.trim();
    if (target.isEmpty) continue;
    final todo = RegExp(r'^todo:([A-Za-z0-9]+)\s*(.*)$').firstMatch(target);
    if (todo != null) {
      final text = (m.group(3) ?? '').trim().isNotEmpty
          ? m.group(3)!.trim()
          : todo.group(2)!.trim();
      edits.add((
        m.start,
        m.end,
        '[${text.isEmpty ? 'todo ${todo.group(1)}' : text}]($todoLinkScheme${todo.group(1)!.toLowerCase()})',
      ));
      continue;
    }
    final embed = m.start > 0 && text[m.start - 1] == '!';
    final start = embed ? m.start - 1 : m.start;
    final alias = (m.group(3) ?? '').trim();
    final shown = alias.isNotEmpty && !RegExp(r'^\d+(x\d+)?$').hasMatch(alias)
        ? alias
        : target;
    final ext = _extOf(target);
    if (_imageExts.contains(ext)) {
      edits.add((start, m.end, '![$shown](${_enc(target)})'));
      continue;
    }
    if (_fileExts.contains(ext)) {
      // An Excalidraw drawing shows its exported picture when the plugin made one.
      final png = ext == 'excalidraw' ? '${target.split('/').last}.png' : null;
      if (embed && png != null && knownFiles.contains(png.toLowerCase())) {
        edits.add((start, m.end, '![$shown](${_enc('$target.png')})'));
      } else {
        edits.add((
          start,
          m.end,
          '[${target.split('/').last}]($fileLinkScheme${_enc(target)})',
        ));
      }
      continue;
    }
    edits.add((start, m.end, '[$shown]($noteLinkScheme${_enc(target)})'));
  }
  for (final m in _tag.allMatches(masked)) {
    final inWiki = edits.any((e) => m.start >= e.$1 && m.start < e.$2);
    if (inWiki) continue;
    edits.add((
      m.start,
      m.end,
      '[#${m.group(1)}]($noteTagScheme${_enc(m.group(1)!)})',
    ));
  }
  bool taken(int at) => edits.any((e) => at >= e.$1 && at < e.$2);
  for (final m in _issueRef.allMatches(masked)) {
    if (taken(m.start)) continue;
    edits.add((
      m.start,
      m.end,
      '[#${m.group(1)}]($issueLinkScheme${m.group(1)})',
    ));
  }
  final fences = _fenceRanges(text);
  for (final m in _codeRef.allMatches(text)) {
    if (fences.any((f) => m.start >= f.$1 && m.start < f.$2) ||
        taken(m.start)) {
      continue;
    }
    final shown = m.group(0)!;
    final target = '${m.group(1)}:${m.group(2)}';
    edits.add((m.start, m.end, '[$shown]($codeLinkScheme${_enc(target)})'));
  }
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  for (final (start, end, repl) in edits) {
    out = out.replaceRange(start, end, repl);
  }
  return out;
}

/// The id in a `haro-todo:` link, the number in a `haro-issue:` one, `(path, line)` in a `haro-code:` one.
String? todoIdFrom(String url) => url.startsWith(todoLinkScheme)
    ? url.substring(todoLinkScheme.length)
    : null;

int? issueNumberFrom(String url) => url.startsWith(issueLinkScheme)
    ? int.tryParse(url.substring(issueLinkScheme.length))
    : null;

(String, int)? codeRefFrom(String url) {
  if (!url.startsWith(codeLinkScheme)) return null;
  final v = Uri.decodeComponent(url.substring(codeLinkScheme.length));
  final i = v.lastIndexOf(':');
  if (i <= 0) return null;
  return (v.substring(0, i), int.tryParse(v.substring(i + 1)) ?? 1);
}

/// The target a `haro-note:` or `haro-tag:` link carries, or null for any other link.
({bool tag, String value})? noteLinkFrom(String url) {
  if (url.startsWith(noteLinkScheme)) {
    return (
      tag: false,
      value: Uri.decodeComponent(url.substring(noteLinkScheme.length)),
    );
  }
  if (url.startsWith(noteTagScheme)) {
    return (
      tag: true,
      value: Uri.decodeComponent(url.substring(noteTagScheme.length)),
    );
  }
  return null;
}

/// A note's leading `---` block (Obsidian properties) split from the text: `(properties, body)`.
/// A line `key: value` is a property, a `- item` line adds to the one above it; anything the simple
/// reading cannot make sense of keeps the whole block in the body, shown as written.
(List<(String, String)>, String) splitFrontMatter(String text) {
  if (!text.startsWith('---\n') && !text.startsWith('---\r\n')) {
    return (const [], text);
  }
  final lines = text.split('\n');
  var end = -1;
  for (var i = 1; i < lines.length && i < 80; i++) {
    if (lines[i].trimRight() == '---') {
      end = i;
      break;
    }
  }
  if (end == -1) return (const [], text);
  final props = <(String, String)>[];
  for (final raw in lines.sublist(1, end)) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final item = RegExp(r'^\s+-\s+(.*)$|^-\s+(.*)$').firstMatch(line);
    if (item != null && props.isNotEmpty) {
      final last = props.removeLast();
      final v = (item.group(1) ?? item.group(2))!.trim();
      props.add((last.$1, last.$2.isEmpty ? v : '${last.$2}, $v'));
      continue;
    }
    final i = line.indexOf(':');
    if (i <= 0 || line.startsWith(' ')) return (const [], text);
    props.add((
      line.substring(0, i).trim(),
      line.substring(i + 1).trim().replaceAll(RegExp(r'^["\x27]|["\x27]$'), ''),
    ));
  }
  if (props.isEmpty) return (const [], text);
  return (props, lines.sublist(end + 1).join('\n').trimLeft());
}
