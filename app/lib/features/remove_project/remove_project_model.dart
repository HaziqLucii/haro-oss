import 'package:flutter/foundation.dart';

import '../../data/workspace_store.dart';
import '../../state/display_state.dart';
import '../../state/workspace_flow.dart';

@immutable
class RemovalRow {
  const RemovalRow({required this.id, required this.name, required this.state});

  final String id;
  final String name;
  final DisplayState state;

  /// The backend deletes the worktree, so anything short of merged loses work.
  bool get unmerged => state != DisplayState.merged;
}

/// What `DELETE /projects/{id}` is about to destroy, read from the workspace store.
@immutable
class RemovalPlan {
  const RemovalPlan({
    required this.projectId,
    required this.name,
    required this.path,
    required this.rows,
  });

  final String projectId;
  final String name;
  final String path;
  final List<RemovalRow> rows;

  int get unmergedCount => rows.where((r) => r.unmerged).length;

  /// Typing the project name is only asked for when work would be lost.
  bool get requiresName => unmergedCount > 0;

  bool confirms(String typed) => typed.trim() == name;

  Set<String> get workspaceIds => {for (final r in rows) r.id};
}

RemovalPlan? buildRemovalPlan(WorkspaceSnapshot snapshot, String projectId) {
  for (final p in snapshot.projects) {
    if (p.id != projectId) continue;
    return RemovalPlan(
      projectId: p.id,
      name: p.name,
      path: p.path,
      rows: [
        for (final w in snapshot.workspaces[p.id] ?? const [])
          RemovalRow(
            id: w.id,
            name: w.name,
            state: deriveWorkspaceFlow(FlowInput.fromWorkspace(w)).displayState,
          ),
      ],
    );
  }
  return null;
}

String tildePath(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  final base = home.endsWith('/') ? home : '$home/';
  return path.startsWith(base) ? '~/${path.substring(base.length)}' : path;
}

/// True for a workspace route of the project or its First run page.
bool routeBelongsTo(Uri location, RemovalPlan plan) {
  final s = location.pathSegments;
  if (s.length >= 2 && s.first == 'w') return plan.workspaceIds.contains(s[1]);
  return s.firstOrNull == 'first-run' &&
      location.queryParameters['project'] == plan.projectId;
}
