import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diff_model.dart' show dirnameOf;

/// Which side panel the activity bar shows. The Gate icon is not a view: it opens the bottom
/// panel.
enum WorkbenchView { files, search, changes }

/// The explorer's two lists: the whole tree, or only the files this branch changed.
enum ExplorerScope { all, changes }

class WorkbenchState {
  const WorkbenchState({
    this.view = WorkbenchView.files,
    this.sideOpen = true,
    this.sideWidth = defaultSideWidth,
    this.scope = ExplorerScope.all,
    this.filter = '',
    this.expanded = const {},
    this.cursor,
    this.query = '',
  });

  static const double defaultSideWidth = 250;
  static const double minSideWidth = 220;
  static const double maxSideWidth = 460;

  final WorkbenchView view;
  final bool sideOpen;
  final double sideWidth;
  final ExplorerScope scope;
  final String filter;

  /// Directory paths open in the All files tree.
  final Set<String> expanded;

  /// The keyboard row of the explorer (the open file is tracked by the editor tabs).
  final String? cursor;

  /// The Search panel's query.
  final String query;

  WorkbenchState copyWith({
    WorkbenchView? view,
    bool? sideOpen,
    double? sideWidth,
    ExplorerScope? scope,
    String? filter,
    Set<String>? expanded,
    Object? cursor = _keep,
    String? query,
  }) => WorkbenchState(
    view: view ?? this.view,
    sideOpen: sideOpen ?? this.sideOpen,
    sideWidth: sideWidth ?? this.sideWidth,
    scope: scope ?? this.scope,
    filter: filter ?? this.filter,
    expanded: expanded ?? this.expanded,
    cursor: identical(cursor, _keep) ? this.cursor : cursor as String?,
    query: query ?? this.query,
  );
}

const Object _keep = Object();

double clampSideWidth(double w) =>
    w.clamp(WorkbenchState.minSideWidth, WorkbenchState.maxSideWidth);

/// The side panel's drawn width: the dragged one, unless that would squeeze the editor below
/// [minEditor] (then down to [minPanel]). [available] is the step's width minus the activity bar.
double fitSideWidth(
  double wanted,
  double available, {
  double minEditor = 260,
  double minPanel = 140,
}) {
  final room = available - minEditor;
  return wanted < room ? wanted : (room > minPanel ? room : minPanel);
}

/// Every directory above [path], outermost first: `a/b/c.ts` gives `a`, `a/b`.
List<String> ancestorsOf(String path) {
  final out = <String>[];
  var dir = dirnameOf(path);
  while (dir.isNotEmpty) {
    out.insert(0, dir);
    dir = dirnameOf(dir);
  }
  return out;
}

class WorkbenchNotifier extends Notifier<WorkbenchState> {
  WorkbenchNotifier(this.workspaceId);

  final String workspaceId;

  @override
  WorkbenchState build() => const WorkbenchState();

  /// An activity-bar click: another icon switches the panel, the active one closes it.
  void pick(WorkbenchView view) {
    if (state.sideOpen && state.view == view) {
      state = state.copyWith(sideOpen: false);
    } else {
      state = state.copyWith(view: view, sideOpen: true);
    }
  }

  void toggleSide() => state = state.copyWith(sideOpen: !state.sideOpen);

  void showSearch() =>
      state = state.copyWith(view: WorkbenchView.search, sideOpen: true);

  void setWidth(double w) =>
      state = state.copyWith(sideWidth: clampSideWidth(w));

  void setScope(ExplorerScope scope) => state = state.copyWith(scope: scope);

  void setFilter(String filter) => state = state.copyWith(filter: filter);

  void setQuery(String query) => state = state.copyWith(query: query);

  void setCursor(String? path) => state = state.copyWith(cursor: path);

  /// Opens or closes [path]; [force] pins the direction (Right expands, Left collapses).
  void toggleDir(String path, {bool? force}) {
    final open = {...state.expanded};
    final want = force ?? !open.contains(path);
    want ? open.add(path) : open.remove(path);
    state = state.copyWith(expanded: open, cursor: path);
  }

  void collapseAll() => state = state.copyWith(expanded: const {});

  /// Expands the folders above [path], puts the cursor on it and shows the plain tree.
  void reveal(String path) => state = state.copyWith(
    view: WorkbenchView.files,
    sideOpen: true,
    scope: ExplorerScope.all,
    filter: '',
    expanded: {...state.expanded, ...ancestorsOf(path)},
    cursor: path,
  );

  /// Opens the folders above [path] without moving the view or the cursor: the file the step
  /// opened by itself should be visible in a tree that is otherwise collapsed.
  void expandTo(String path) {
    final need = ancestorsOf(path).where((d) => !state.expanded.contains(d));
    if (need.isEmpty) return;
    state = state.copyWith(expanded: {...state.expanded, ...need});
  }
}

final workbenchProvider =
    NotifierProvider.family<WorkbenchNotifier, WorkbenchState, String>(
      WorkbenchNotifier.new,
    );
