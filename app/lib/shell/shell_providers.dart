import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/workspace_store.dart';
import '../data/xp_store.dart';
import '../state/display_state.dart';
import '../state/workspace_flow.dart';
import 'shell_models.dart';

final shellDataProvider = Provider<ShellData>((ref) {
  ref.watch(xpWiringProvider);
  final snap = ref.watch(workspaceStoreProvider);
  var needYou = 0;
  var total = 0;
  final projects = [
    for (final p in snap.projects)
      SidebarProject(
        id: p.id,
        name: p.name,
        workspaces: [
          for (final w in snap.workspaces[p.id] ?? const [])
            () {
              final flow = deriveWorkspaceFlow(FlowInput.fromWorkspace(w));
              total++;
              if (flow.triageGroup == TriageGroup.needsYou) needYou++;
              return SidebarWorkspace(
                id: w.id,
                name: w.name,
                state: flow.displayState,
                defaultStep: flow.defaultStep,
                word: flow.stateWord,
                mode: w.mode,
              );
            }(),
        ],
      ),
  ];
  return ShellData(
    triageCount: total,
    backlogOpen: snap.backlogOpen,
    needYouCount: needYou,
    projects: projects,
    xp: ref.watch(xpFooterProvider),
  );
});
