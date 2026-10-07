import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../state/display_state.dart';
import '../../state/workspace_flow.dart';

enum TriageFilter {
  all('All'),
  needsYou('Needs you'),
  running('Running'),
  readyToShip('Ready to ship'),
  idle('Idle'),
  merged('Merged');

  const TriageFilter(this.label);
  final String label;

  TriageGroup? get group => switch (this) {
    all => null,
    needsYou => TriageGroup.needsYou,
    running => TriageGroup.running,
    readyToShip => TriageGroup.readyToShip,
    idle => TriageGroup.idle,
    merged => TriageGroup.merged,
  };
}

/// Group order, titles and hints as in the prototype.
const triageGroupOrder = <TriageGroup>[
  TriageGroup.needsYou,
  TriageGroup.running,
  TriageGroup.readyToShip,
  TriageGroup.idle,
  TriageGroup.merged,
];

String triageGroupTitle(TriageGroup g) => switch (g) {
  TriageGroup.needsYou => 'Needs you',
  TriageGroup.running => 'Running',
  TriageGroup.readyToShip => 'Ready to ship',
  TriageGroup.idle => 'Idle',
  TriageGroup.merged => 'Merged',
};

String triageGroupHint(TriageGroup g) => switch (g) {
  TriageGroup.needsYou => 'Decide, review or unblock',
  TriageGroup.running => 'Agents and gates at work',
  TriageGroup.readyToShip => 'Green, nothing to review',
  TriageGroup.idle => 'Waiting for a task',
  TriageGroup.merged => 'Shipped on a green gate',
};

class TriageRow {
  const TriageRow({
    required this.workspace,
    required this.projectName,
    required this.flow,
    this.at,
  });

  final Workspace workspace;
  final String projectName;
  final WorkspaceFlow flow;

  /// Epoch seconds of the last thing that happened, or null when the model has no honest
  /// value (running rows: the workspace carries no start time for the live agent or gate).
  final double? at;

  String get id => workspace.id;
}

class TriageView {
  const TriageView({
    required this.loaded,
    required this.error,
    required this.projectCount,
    required this.rows,
  });

  static const empty = TriageView(
    loaded: false,
    error: null,
    projectCount: 0,
    rows: [],
  );

  final bool loaded;
  final String? error;
  final int projectCount;
  final List<TriageRow> rows;

  int get workspaceCount => rows.length;

  List<TriageRow> inGroup(TriageGroup g) => [
    for (final r in rows)
      if (r.flow.triageGroup == g) r,
  ];

  int countOf(TriageFilter f) =>
      f.group == null ? rows.length : inGroup(f.group!).length;

  int get needYouCount => countOf(TriageFilter.needsYou);
}

double? triageTimestamp(Workspace ws, WorkspaceFlow flow) {
  switch (flow.displayState) {
    case DisplayState.agent:
    case DisplayState.gate:
    case DisplayState.plan:
      return null;
    case DisplayState.red:
    case DisplayState.green:
    case DisplayState.merged:
      return ws.gate?.endedAt ?? ws.createdAt;
    case DisplayState.idle:
      return ws.createdAt;
  }
}

TriageView buildTriageView(WorkspaceSnapshot snap) {
  final rows = <TriageRow>[
    for (final p in snap.projects)
      for (final w in snap.workspaces[p.id] ?? const <Workspace>[])
        () {
          final flow = deriveWorkspaceFlow(FlowInput.fromWorkspace(w));
          return TriageRow(
            workspace: w,
            projectName: p.name,
            flow: flow,
            at: triageTimestamp(w, flow),
          );
        }(),
  ];
  return TriageView(
    loaded: snap.loaded,
    error: snap.error,
    projectCount: snap.projects.length,
    rows: rows,
  );
}

String triageHeadline(int needYou) => switch (needYou) {
  0 => 'Nothing needs you.',
  1 => '1 workspace needs you.',
  _ => '$needYou workspaces need you.',
};
