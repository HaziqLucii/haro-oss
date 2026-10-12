import 'json_util.dart';

class ReviewQueueItem {
  const ReviewQueueItem({
    required this.workspaceId,
    this.projectId = '',
    this.lines = 0,
    this.files = 0,
  });

  final String workspaceId;
  final String projectId;
  final int lines;
  final int files;

  factory ReviewQueueItem.fromJson(Json j) => ReviewQueueItem(
    workspaceId: jStr(j, 'workspace_id'),
    projectId: jStr(j, 'project_id'),
    lines: jInt(j, 'lines'),
    files: jInt(j, 'files'),
  );
}

/// Agent-written work waiting for the developer, across every project. `cap` is the soft limit
/// on how many workspaces may wait (0 = no warning); crossing it never blocks anything.
class ReviewQueue {
  const ReviewQueue({
    this.cap = 3,
    this.totalLines = 0,
    this.workspaces = const [],
  });

  final int cap;
  final int totalLines;
  final List<ReviewQueueItem> workspaces;

  factory ReviewQueue.fromJson(Json j) => ReviewQueue(
    cap: jInt(j, 'cap', 3),
    totalLines: jInt(j, 'total_lines'),
    workspaces: jList(j, 'workspaces', ReviewQueueItem.fromJson),
  );
}
