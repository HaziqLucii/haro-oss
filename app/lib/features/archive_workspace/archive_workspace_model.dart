import 'package:flutter/foundation.dart';

import '../../api/models/models.dart';
import '../../state/format.dart' show plural;

@immutable
class ArchiveLine {
  const ArchiveLine(this.text, {this.warn = false});

  final String text;

  /// Red: work that is lost. Plain lines are facts.
  final bool warn;
}

/// What `DELETE /workspaces/{id}` destroys, for the confirm. The backend force-removes the
/// worktree and then runs `git branch -D`, so anything not merged is gone with the branch.
///
/// [git] is null while unknown (not loaded, or the request failed): the lines then say
/// "if any" instead of claiming the tree is clean or dirty. A status whose counts the backend
/// could not measure (`countsUnknown`) is treated the same as a failed read, so the
/// all-clear only prints for a merged workspace whose ahead == 0 and dirty == 0 were measured.
List<ArchiveLine> archiveConsequences(Workspace ws, GitStatusResponse? git) {
  final merged = ws.status == WorkspaceStatus.merged;
  final read = git != null && !git.countsUnknown ? git : null;
  final g = read != null && !read.worktreeMissing ? read : null;
  return [
    if (ws.status == WorkspaceStatus.agentRunning)
      const ArchiveLine('The running agent is stopped.'),
    if (ws.status == WorkspaceStatus.testsRunning)
      const ArchiveLine('The running gate is stopped.'),
    if (git != null && git.worktreeMissing)
      const ArchiveLine('The worktree is already gone from disk.'),
    if (g == null && !merged)
      ArchiveLine(
        'Not merged: commits on ${ws.branch} that are not in '
        '${ws.baseRef} are deleted with the branch.',
        warn: true,
      )
    else if (g == null && read == null)
      ArchiveLine(
        'Commits on ${ws.branch} that are not in ${ws.baseRef}, if any, '
        'are deleted with the branch.',
      )
    else if (g != null && g.ahead > 0)
      ArchiveLine(
        merged
            ? '${g.ahead} ${plural(g.ahead, 'commit')} on ${ws.branch} '
                  '${g.ahead == 1 ? 'is' : 'are'} not in ${ws.baseRef} (new '
                  'since the merge, or squash-merged copies) and '
                  '${g.ahead == 1 ? 'is' : 'are'} deleted with the branch.'
            : '${g.ahead} ${plural(g.ahead, 'commit')} on ${ws.branch} '
                  '${g.ahead == 1 ? "isn't" : "aren't"} merged into '
                  '${ws.baseRef} and ${g.ahead == 1 ? 'is' : 'are'} deleted '
                  'with the branch.',
        warn: true,
      ),
    if (g != null && g.dirty > 0)
      ArchiveLine(
        '${g.dirty} ${plural(g.dirty, 'uncommitted file')} in the worktree '
        '${g.dirty == 1 ? 'is' : 'are'} deleted.',
        warn: true,
      )
    else if (read == null)
      const ArchiveLine('Uncommitted changes, if any, are deleted too.'),
    if (merged && g != null && g.ahead == 0 && g.dirty == 0)
      ArchiveLine(
        'Merged into ${ws.baseRef}. No unmerged commits or uncommitted '
        'files found.',
      ),
  ];
}

/// True for a route inside the archived workspace.
bool routeIsWorkspace(Uri location, String workspaceId) {
  final s = location.pathSegments;
  return s.length >= 2 && s.first == 'w' && s[1] == workspaceId;
}
