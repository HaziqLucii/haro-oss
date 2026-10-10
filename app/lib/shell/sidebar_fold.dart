import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/display_state.dart';
import 'shell_models.dart';

/// What the sidebar has folded: whole projects, and (per project) whether its merged
/// workspaces are listed. Kept while the app runs, so hiding the sidebar or leaving a page
/// does not unfold it.
@immutable
class SidebarFold {
  const SidebarFold({this.folded = const {}, this.mergedShown = const {}});

  final Set<String> folded;
  final Set<String> mergedShown;
}

class SidebarFoldNotifier extends Notifier<SidebarFold> {
  @override
  SidebarFold build() => const SidebarFold();

  void toggleProject(String id) => state = SidebarFold(
    folded: _toggled(state.folded, id),
    mergedShown: state.mergedShown,
  );

  void toggleMerged(String id) => state = SidebarFold(
    folded: state.folded,
    mergedShown: _toggled(state.mergedShown, id),
  );

  static Set<String> _toggled(Set<String> set, String id) =>
      set.contains(id) ? ({...set}..remove(id)) : {...set, id};
}

final sidebarFoldProvider = NotifierProvider<SidebarFoldNotifier, SidebarFold>(
  SidebarFoldNotifier.new,
);

/// The rows one project shows under its header.
@immutable
class SidebarProjectView {
  const SidebarProjectView({
    required this.folded,
    required this.rows,
    required this.mergedCount,
    required this.mergedOpen,
  });

  final bool folded;
  final List<SidebarWorkspace> rows;

  /// Merged workspaces the toggle row stands for (0 hides the row).
  final int mergedCount;
  final bool mergedOpen;
}

/// Folded: the open workspace stays, and so does anything running or needing you (a red
/// gate, a plan to approve, an agent or gate at work), so folding never hides news.
/// Otherwise the merged ones collapse into one toggle row, except the open one. Rows keep
/// the order they came in.
SidebarProjectView sidebarProjectView(
  SidebarProject project,
  SidebarFold fold,
  String? selectedId,
) {
  final workspaces = project.workspaces;
  if (fold.folded.contains(project.id)) {
    return SidebarProjectView(
      folded: true,
      rows: [
        for (final w in workspaces)
          if (w.id == selectedId || _needsAttention(w.state)) w,
      ],
      mergedCount: 0,
      mergedOpen: false,
    );
  }
  final shown = fold.mergedShown.contains(project.id);
  final merged = [
    for (final w in workspaces)
      if (w.state == DisplayState.merged) w,
  ];
  final hidden = shown ? 0 : merged.where((w) => w.id != selectedId).length;
  return SidebarProjectView(
    folded: false,
    rows: [
      for (final w in workspaces)
        if (w.state != DisplayState.merged || shown || w.id == selectedId) w,
    ],
    mergedCount: shown ? merged.length : hidden,
    mergedOpen: shown,
  );
}

bool _needsAttention(DisplayState s) => switch (s) {
  DisplayState.red ||
  DisplayState.plan ||
  DisplayState.agent ||
  DisplayState.gate => true,
  _ => false,
};
