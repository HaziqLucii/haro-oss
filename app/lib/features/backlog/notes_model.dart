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
