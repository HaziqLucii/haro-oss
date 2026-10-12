import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart';
import 'workspace_store.dart' show haroApiProvider;

/// `issue:116` is the seed key of a workspace started from GitHub issue #116; anything else
/// (a backlog line, a plain workspace) has no issue.
int? issueNumberOf(String? seedKey) {
  if (seedKey == null || !seedKey.startsWith('issue:')) return null;
  return int.tryParse(seedKey.substring('issue:'.length));
}

/// The issue as `gh` reads it for the project: title, state, labels, body and comments. Read when
/// the rail or its fullscreen view asks, and dropped with the last of them.
final workspaceIssueProvider = FutureProvider.autoDispose
    .family<IssueDetailResponse, ({String projectId, int number})>(
      (ref, key) =>
          ref.watch(haroApiProvider).getIssueDetail(key.projectId, key.number),
      // A failed read shows its error with a Try again, not a spinner that retries by itself.
      retry: (_, _) => null,
    );
