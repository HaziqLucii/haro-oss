import 'json_util.dart';

/// Parsed backlog task. `stage` is derived server-side from the seeded workspace:
/// `ready` | `queued` | `running` | `red` | `green` | `shipped`.
class TodoItem {
  const TodoItem({
    this.heading,
    required this.text,
    this.body = '',
    this.done = false,
    this.seedKey,
    this.seededWorkspace,
    this.stage,
  });

  final String? heading;

  /// Compact prose: checklist display and the short branch/workspace name.
  final String text;

  /// Full item including fenced code: the brief seeded to the agent.
  final String body;
  final bool done;

  /// Stable id passed back on workspace create so the item can be marked in progress.
  final String? seedKey;
  final String? seededWorkspace;
  final String? stage;

  factory TodoItem.fromJson(Json j) => TodoItem(
    heading: jStrN(j, 'heading'),
    text: jStr(j, 'text'),
    body: jStr(j, 'body'),
    done: jBool(j, 'done'),
    seedKey: jStrN(j, 'seed_key'),
    seededWorkspace: jStrN(j, 'seeded_workspace'),
    stage: jStrN(j, 'stage'),
  );
}

/// An ordered document block: either a task or a note (raw markdown).
sealed class TodoBlock {
  const TodoBlock();

  factory TodoBlock.fromJson(Json j) => jStr(j, 'kind') == 'note'
      ? TodoNote(jStr(j, 'md'))
      : TodoItemBlock(TodoItem.fromJson(j));
}

class TodoItemBlock extends TodoBlock {
  const TodoItemBlock(this.item);
  final TodoItem item;
}

class TodoNote extends TodoBlock {
  const TodoNote(this.md);
  final String md;
}

class TodoFile {
  const TodoFile({
    required this.path,
    this.label = '',
    this.items = const [],
    this.blocks = const [],
    this.content = '',
    this.done = 0,
    this.pending = 0,
  });

  final String path;
  final String label;
  final List<TodoItem> items;
  final List<TodoBlock> blocks;
  final String content;
  final int done;
  final int pending;

  factory TodoFile.fromJson(Json j) => TodoFile(
    path: jStr(j, 'path'),
    label: jStr(j, 'label'),
    items: jList(j, 'items', TodoItem.fromJson),
    blocks: jList(j, 'blocks', TodoBlock.fromJson),
    content: jStr(j, 'content'),
    done: jInt(j, 'done'),
    pending: jInt(j, 'pending'),
  );
}

class OrphanedSeed {
  const OrphanedSeed({required this.workspaceId, required this.seedKey});

  final String workspaceId;
  final String seedKey;

  factory OrphanedSeed.fromJson(Json j) => OrphanedSeed(
    workspaceId: jStr(j, 'workspace_id'),
    seedKey: jStr(j, 'seed_key'),
  );
}

class TodoResponse {
  const TodoResponse({this.files = const [], this.orphaned = const []});

  final List<TodoFile> files;
  final List<OrphanedSeed> orphaned;

  factory TodoResponse.fromJson(Json j) => TodoResponse(
    files: jList(j, 'files', TodoFile.fromJson),
    orphaned: jList(j, 'orphaned', OrphanedSeed.fromJson),
  );
}

class IssueItem {
  const IssueItem({
    required this.number,
    required this.title,
    this.body = '',
    this.state = 'open',
    this.labels = const [],
    this.url = '',
    this.seedKey,
    this.seededWorkspace,
    this.stage,
  });

  final int number;
  final String title;
  final String body;

  /// `open` | `closed`.
  final String state;
  final List<String> labels;
  final String url;
  final String? seedKey;
  final String? seededWorkspace;
  final String? stage;

  factory IssueItem.fromJson(Json j) => IssueItem(
    number: jInt(j, 'number'),
    title: jStr(j, 'title'),
    body: jStr(j, 'body'),
    state: jStr(j, 'state', 'open'),
    labels: jStrList(j, 'labels'),
    url: jStr(j, 'url'),
    seedKey: jStrN(j, 'seed_key'),
    seededWorkspace: jStrN(j, 'seeded_workspace'),
    stage: jStrN(j, 'stage'),
  );
}

class IssuesResponse {
  const IssuesResponse({
    required this.available,
    this.reason,
    this.stale = false,
    this.fetchedAt,
    this.issues = const [],
    this.truncated = false,
  });

  /// `false` means the empty state (no remote, no `gh`); [reason] says which.
  final bool available;
  final String? reason;
  final bool stale;
  final String? fetchedAt;
  final List<IssueItem> issues;
  final bool truncated;

  factory IssuesResponse.fromJson(Json j) => IssuesResponse(
    available: jBool(j, 'available'),
    reason: jStrN(j, 'reason'),
    stale: jBool(j, 'stale'),
    fetchedAt: jStrN(j, 'fetched_at'),
    issues: jList(j, 'issues', IssueItem.fromJson),
    truncated: jBool(j, 'truncated'),
  );
}

class IssueComment {
  const IssueComment({
    required this.author,
    this.body = '',
    this.createdAt = '',
  });

  final String author;
  final String body;
  final String createdAt;

  factory IssueComment.fromJson(Json j) => IssueComment(
    author: jStr(j, 'author'),
    body: jStr(j, 'body'),
    createdAt: jStr(j, 'created_at'),
  );
}

class IssueDetailResponse {
  const IssueDetailResponse({
    required this.available,
    this.reason,
    this.number,
    this.title,
    this.body,
    this.state,
    this.url,
    this.labels = const [],
    this.comments = const [],
  });

  final bool available;
  final String? reason;
  final int? number;
  final String? title;
  final String? body;
  final String? state;
  final String? url;
  final List<String> labels;
  final List<IssueComment> comments;

  factory IssueDetailResponse.fromJson(Json j) => IssueDetailResponse(
    available: jBool(j, 'available'),
    reason: jStrN(j, 'reason'),
    number: jIntN(j, 'number'),
    title: jStrN(j, 'title'),
    body: jStrN(j, 'body'),
    state: jStrN(j, 'state'),
    url: jStrN(j, 'url'),
    labels: jStrList(j, 'labels'),
    comments: jList(j, 'comments', IssueComment.fromJson),
  );
}
