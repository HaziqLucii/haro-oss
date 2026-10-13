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

/// One link of the open note and where it points; [path] is null when no note has that name yet.
class NoteLinkOut {
  const NoteLinkOut({
    required this.target,
    this.path,
    this.title,
    this.ambiguous = false,
    this.todoText,
    this.todoDone = false,
    this.todoPath,
    this.isTodo = false,
    this.file,
  });

  final String target;
  final String? path;
  final String? title;

  /// The file beside the notes this link names (`[[report.pdf]]`), relative to the notes folder.
  final String? file;

  /// A `[[todo:<id> text]]` link: [isTodo], and the item it names now ([todoText] null when the
  /// item can no longer be found).
  final bool isTodo;
  final String? todoText;
  final bool todoDone;
  final String? todoPath;

  /// Several notes share this name; the first by path was taken.
  final bool ambiguous;

  factory NoteLinkOut.fromJson(Json j) => NoteLinkOut(
    target: jStr(j, 'target'),
    path: jStrN(j, 'path'),
    title: jStrN(j, 'title'),
    file: jStrN(j, 'file'),
    ambiguous: jBool(j, 'ambiguous'),
    isTodo: j.containsKey('todo'),
    todoText: j['todo'] is Map
        ? jStrN(j['todo'] as Map<String, dynamic>, 'text')
        : null,
    todoDone:
        j['todo'] is Map && jBool(j['todo'] as Map<String, dynamic>, 'done'),
    todoPath: j['todo'] is Map
        ? jStrN(j['todo'] as Map<String, dynamic>, 'path')
        : null,
  );
}

/// Another note that links to, or only mentions, the open one, with the line it does it on.
class NoteRef {
  const NoteRef({required this.path, required this.title, this.snippet = ''});

  final String path;
  final String title;
  final String snippet;

  factory NoteRef.fromJson(Json j) => NoteRef(
    path: jStr(j, 'path'),
    title: jStr(j, 'title'),
    snippet: jStr(j, 'snippet'),
  );
}

/// What connects the open note to the others, read from the files (`GET .../notes/links`).
class NoteLinks {
  const NoteLinks({
    required this.path,
    this.tags = const [],
    this.outgoing = const [],
    this.backlinks = const [],
    this.mentions = const [],
  });

  final String path;
  final List<String> tags;
  final List<NoteLinkOut> outgoing;
  final List<NoteRef> backlinks;
  final List<NoteRef> mentions;

  /// The note a link target names, null when none does.
  String? resolve(String target) {
    for (final l in outgoing) {
      if (l.target == target) return l.path;
    }
    return null;
  }

  factory NoteLinks.fromJson(Json j) {
    List<T> list<T>(String k, T Function(Json) f) => [
      for (final e in (j[k] is List ? j[k] as List : const []))
        if (e is Map<String, dynamic>) f(e),
    ];
    return NoteLinks(
      path: jStr(j, 'path'),
      tags: [
        for (final t in (j['tags'] is List ? j['tags'] as List : const []))
          if (t is String) t,
      ],
      outgoing: list('outgoing', NoteLinkOut.fromJson),
      backlinks: list('backlinks', NoteRef.fromJson),
      mentions: list('mentions', NoteRef.fromJson),
    );
  }
}

/// A file beside the notes: a PDF, a sheet, a document, an image, a drawing. [kind] is `pdf`,
/// `sheet`, `doc`, `image`, `drawing`, `text` or `other`.
class NoteFile {
  const NoteFile({
    required this.path,
    required this.name,
    required this.kind,
    this.size = 0,
    this.modified = 0,
  });

  final String path;
  final String name;
  final String kind;
  final int size;
  final double modified;

  factory NoteFile.fromJson(Json j) => NoteFile(
    path: jStr(j, 'path'),
    name: jStr(j, 'name'),
    kind: jStr(j, 'kind'),
    size: jInt(j, 'size'),
    modified: jDouble(j, 'modified'),
  );
}
