import 'json_util.dart';

/// One project note in the list: a markdown page in `<project>/.haro/notes/`.
class NoteSummary {
  const NoteSummary({
    required this.path,
    required this.title,
    this.modified = 0,
    this.size = 0,
    this.snippets = const [],
  });

  /// Relative to the notes folder, e.g. `ideas.md` or `design/api.md`.
  final String path;
  final String title;

  /// Seconds since the epoch.
  final double modified;
  final int size;

  /// Lines that matched the search, empty when not searching.
  final List<String> snippets;

  factory NoteSummary.fromJson(Json j) => NoteSummary(
    path: jStr(j, 'path'),
    title: jStr(j, 'title'),
    modified: (j['modified'] is num) ? (j['modified'] as num).toDouble() : 0,
    size: jInt(j, 'size'),
    snippets: [
      for (final s
          in (j['snippets'] is List ? j['snippets'] as List : const []))
        if (s is String) s,
    ],
  );
}

/// A note's text and the hash a save must quote, so a file that changed in between is refused.
class NoteDoc {
  const NoteDoc({
    required this.path,
    required this.content,
    required this.etag,
  });

  final String path;
  final String content;
  final String etag;

  factory NoteDoc.fromJson(Json j) => NoteDoc(
    path: jStr(j, 'path'),
    content: jStr(j, 'content'),
    etag: jStr(j, 'etag'),
  );
}
