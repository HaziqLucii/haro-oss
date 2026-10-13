import 'json_util.dart';

List<String> _strings(Object? v) => [
  for (final e in (v is List ? v : const []))
    if (e is String) e,
];

/// One hit of the Backlog's search (`GET /projects/{id}/find`): a todo, a note or a GitHub issue.
class FindResult {
  const FindResult({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.snippet = '',
    this.tags = const [],
    this.stage,
    this.done = false,
    this.pinned = false,
    this.id,
    this.path = '',
    this.file,
    this.index,
    this.number,
    this.fileKind,
  });

  /// `todo`, `note`, `file` or `issue`.
  final String kind;
  final String title;
  final String subtitle;
  final String snippet;
  final List<String> tags;
  final String? stage;
  final bool done;
  final bool pinned;
  final String? id;
  final String path;

  /// A todo: its file and position among that file's items.
  final String? file;
  final int? index;

  /// An issue: its number.
  final int? number;

  /// A file beside the notes: `pdf`, `sheet`, `doc`, ...
  final String? fileKind;

  factory FindResult.fromJson(Json j) => FindResult(
    kind: jStr(j, 'kind'),
    title: jStr(j, 'title'),
    subtitle: jStr(j, 'subtitle'),
    snippet: jStr(j, 'snippet'),
    tags: _strings(j['tags']),
    stage: jStrN(j, 'stage'),
    done: jBool(j, 'done'),
    pinned: jBool(j, 'pinned'),
    id: jStrN(j, 'id'),
    path: jStr(j, 'path'),
    file: jStrN(j, 'file'),
    index: jIntN(j, 'index'),
    number: jIntN(j, 'number'),
    fileKind: jStrN(j, 'file_kind'),
  );
}

/// A saved Backlog view: a query and how to lay it out (`list` or `board`).
class BacklogView {
  const BacklogView({
    this.id = '',
    required this.name,
    required this.query,
    this.layout = 'list',
  });

  final String id;
  final String name;
  final String query;
  final String layout;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'query': query,
    'layout': layout,
  };

  factory BacklogView.fromJson(Json j) => BacklogView(
    id: jStr(j, 'id'),
    name: jStr(j, 'name'),
    query: jStr(j, 'query'),
    layout: jStr(j, 'layout') == 'board' ? 'board' : 'list',
  );
}

/// An unchecked `- [ ]` line in a note (listed, never copied to the backlog).
class NoteTask {
  const NoteTask({
    required this.path,
    required this.title,
    required this.line,
    required this.text,
  });

  final String path;
  final String title;
  final int line;
  final String text;

  factory NoteTask.fromJson(Json j) => NoteTask(
    path: jStr(j, 'path'),
    title: jStr(j, 'title'),
    line: jInt(j, 'line'),
    text: jStr(j, 'text'),
  );
}

class NoteTemplate {
  const NoteTemplate({
    required this.id,
    required this.name,
    this.source = 'built-in',
  });

  final String id;
  final String name;

  /// `built-in` or `project` (a file in `.haro/templates/`).
  final String source;

  factory NoteTemplate.fromJson(Json j) => NoteTemplate(
    id: jStr(j, 'id'),
    name: jStr(j, 'name'),
    source: jStr(j, 'source'),
  );
}

/// One commit that changed a note.
class NoteCommit {
  const NoteCommit({
    required this.sha,
    required this.date,
    required this.author,
    required this.subject,
  });

  final String sha;

  /// Seconds since the epoch.
  final int date;
  final String author;
  final String subject;

  factory NoteCommit.fromJson(Json j) => NoteCommit(
    sha: jStr(j, 'sha'),
    date: jInt(j, 'date'),
    author: jStr(j, 'author'),
    subject: jStr(j, 'subject'),
  );
}

/// A note as of a commit, and the diff from it to the file on disk now.
class NoteRevision {
  const NoteRevision({
    required this.sha,
    required this.content,
    required this.diff,
  });

  final String sha;
  final String content;
  final String diff;

  factory NoteRevision.fromJson(Json j) => NoteRevision(
    sha: jStr(j, 'sha'),
    content: jStr(j, 'content'),
    diff: jStr(j, 'diff'),
  );
}

/// A todo the weekly review points at.
class ReviewTodo {
  const ReviewTodo({
    required this.file,
    required this.index,
    required this.text,
    this.id,
    this.days = 0,
  });

  final String file;
  final int index;
  final String text;
  final String? id;
  final int days;

  factory ReviewTodo.fromJson(Json j) => ReviewTodo(
    file: jStr(j, 'file'),
    index: jInt(j, 'index'),
    text: jStr(j, 'text'),
    id: jStrN(j, 'id'),
    days: jInt(j, 'days'),
  );
}

class ReviewNote {
  const ReviewNote({required this.path, required this.title, this.days = 0});

  final String path;
  final String title;
  final int days;

  factory ReviewNote.fromJson(Json j) => ReviewNote(
    path: jStr(j, 'path'),
    title: jStr(j, 'title'),
    days: jInt(j, 'days'),
  );
}

/// What to look at this week (`GET /projects/{id}/review`), all computed from facts.
class ReviewData {
  const ReviewData({
    this.stale = const [],
    this.staleDays = 14,
    this.notStarted = const [],
    this.unlinkedNotes = const [],
    this.orphaned = 0,
    this.resurface,
    this.noteTasks = 0,
  });

  final List<ReviewTodo> stale;
  final int staleDays;
  final List<ReviewTodo> notStarted;
  final List<ReviewNote> unlinkedNotes;
  final int orphaned;
  final ReviewNote? resurface;
  final int noteTasks;

  factory ReviewData.fromJson(Json j) => ReviewData(
    stale: jList(j, 'stale', ReviewTodo.fromJson),
    staleDays: jInt(j, 'stale_days', 14),
    notStarted: jList(j, 'not_started', ReviewTodo.fromJson),
    unlinkedNotes: jList(j, 'unlinked_notes', ReviewNote.fromJson),
    orphaned: (j['orphaned'] is List) ? (j['orphaned'] as List).length : 0,
    resurface: j['resurface'] is Map<String, dynamic>
        ? ReviewNote.fromJson(j['resurface'] as Map<String, dynamic>)
        : null,
    noteTasks: jInt(j, 'note_tasks'),
  );
}
