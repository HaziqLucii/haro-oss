import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/workspace_store.dart';
import '../state/display_state.dart';
import '../state/workspace_flow.dart';

/// The workspace after [currentId] in [ids], wrapping. When [currentId] is not in the list
/// (no workspace open, or one that does not need you) the first one is returned.
String? nextNeedYou(List<String> ids, String? currentId) {
  if (ids.isEmpty) return null;
  final i = currentId == null ? -1 : ids.indexOf(currentId);
  return ids[(i + 1) % ids.length];
}

/// Needs-you workspaces in sidebar order (projects, then each project's workspaces), the same
/// order the triage list uses within its group.
final needYouIdsProvider = Provider<List<String>>((ref) {
  final snap = ref.watch(workspaceStoreProvider);
  return [
    for (final p in snap.projects)
      for (final w in snap.workspaces[p.id] ?? const [])
        if (deriveWorkspaceFlow(FlowInput.fromWorkspace(w)).triageGroup ==
            TriageGroup.needsYou)
          w.id,
  ];
});
