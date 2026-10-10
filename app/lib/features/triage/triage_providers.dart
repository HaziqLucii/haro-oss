import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/workspace_store.dart';
import '../../state/display_state.dart' show TriageGroup;
import 'triage_model.dart';

/// Session-only: a fresh app start goes back to All.
class TriageFilterNotifier extends Notifier<TriageFilter> {
  @override
  TriageFilter build() => TriageFilter.all;

  void pick(TriageFilter f) => state = f;
}

final triageFilterProvider =
    NotifierProvider<TriageFilterNotifier, TriageFilter>(
      TriageFilterNotifier.new,
    );

final triageViewProvider = Provider<TriageView>(
  (ref) => buildTriageView(ref.watch(workspaceStoreProvider)),
);

/// Which half of the dashboard shows. Session-only, like the filter.
class TriageTabNotifier extends Notifier<TriageTab> {
  @override
  TriageTab build() => TriageTab.workspaces;

  void pick(TriageTab t) => state = t;
}

final triageTabProvider = NotifierProvider<TriageTabNotifier, TriageTab>(
  TriageTabNotifier.new,
);

class TriageSearchNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String q) => state = q;
}

final triageSearchProvider = NotifierProvider<TriageSearchNotifier, String>(
  TriageSearchNotifier.new,
);

/// Which groups are folded and which show all their rows. Session-only like the filter, so
/// coming back from a workspace finds the dashboard as it was left.
class TriageFold {
  const TriageFold({
    this.closed = const {TriageGroup.merged},
    this.expanded = const {},
  });

  final Set<TriageGroup> closed;
  final Set<TriageGroup> expanded;
}

class TriageFoldNotifier extends Notifier<TriageFold> {
  @override
  TriageFold build() => const TriageFold();

  void toggle(TriageGroup g) {
    final closed = {...state.closed};
    if (!closed.remove(g)) closed.add(g);
    state = TriageFold(closed: closed, expanded: state.expanded);
  }

  void expand(TriageGroup g) => state = TriageFold(
    closed: state.closed,
    expanded: {...state.expanded, g},
  );
}

final triageFoldProvider = NotifierProvider<TriageFoldNotifier, TriageFold>(
  TriageFoldNotifier.new,
);
