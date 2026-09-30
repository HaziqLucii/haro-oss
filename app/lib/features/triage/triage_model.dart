import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../state/display_state.dart';
import '../../state/format.dart';
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

String triageEyebrow(TriageView v) {
  final w = v.workspaceCount;
  final p = v.projectCount;
  return 'Triage · $w ${plural(w, 'workspace')} · $p ${plural(p, 'project')}';
}

String triageHeadline(int needYou) => switch (needYou) {
  0 => 'Nothing needs you.',
  1 => '1 workspace needs you.',
  _ => '$needYou workspaces need you.',
};

const _numberWords = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
];

String _word(int n) => n < _numberWords.length ? _numberWords[n] : '$n';

String _join(List<String> parts) => switch (parts.length) {
  0 => '',
  1 => parts.single,
  2 => '${parts[0]} and ${parts[1]}',
  _ => '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}',
};

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// What one needs-you row is waiting on, as a clause with singular and plural forms.
enum _NeedKind { red, plan, acceptance, waiting, look }

_NeedKind _needKind(TriageRow r) {
  if (r.flow.waitingOnInput) return _NeedKind.waiting;
  if (r.flow.acceptanceReview) return _NeedKind.acceptance;
  return switch (r.flow.displayState) {
    DisplayState.red => _NeedKind.red,
    DisplayState.plan => _NeedKind.plan,
    _ => _NeedKind.look,
  };
}

String _needClause(_NeedKind k, int n) {
  final one = n == 1;
  final lead = _word(n);
  return switch (k) {
    _NeedKind.red => '$lead ${one ? 'is' : 'are'} red',
    _NeedKind.plan =>
      one
          ? '$lead has a plan waiting for approval'
          : '$lead have plans waiting for approval',
    _NeedKind.acceptance =>
      one
          ? '$lead has an acceptance test waiting for approval'
          : '$lead have acceptance tests waiting for approval',
    _NeedKind.waiting =>
      '$lead ${one ? 'has an agent' : 'have agents'} waiting on an answer',
    _NeedKind.look =>
      '$lead ${one ? 'is' : 'are'} green with something to look at',
  };
}

/// The summary sentence under the headline, written from the data. Mirrors the prototype's
/// hand-written example: what needs a decision, then what is merely in motion.
String triageSummary(TriageView v) {
  if (v.workspaceCount == 0) return '';
  final need = v.inGroup(TriageGroup.needsYou);
  final running = v.inGroup(TriageGroup.running).length;
  final ready = v.inGroup(TriageGroup.readyToShip).length;

  final counts = <_NeedKind, int>{};
  for (final r in need) {
    counts.update(_needKind(r), (n) => n + 1, ifAbsent: () => 1);
  }
  final needParts = [
    for (final k in _NeedKind.values)
      if (counts[k] != null) _needClause(k, counts[k]!),
  ];

  final motion = [
    if (running > 0) '${_word(running)} ${running == 1 ? 'is' : 'are'} running',
    if (ready > 0) '${_word(ready)} ${ready == 1 ? 'is' : 'are'} ready to ship',
  ];

  if (needParts.isNotEmpty) {
    final first = '${_cap(_join(needParts))}.';
    if (motion.isEmpty) return '$first Nothing else needs a decision.';
    return '$first ${_cap(_join(motion))}; nothing else needs a decision.';
  }
  if (motion.isEmpty) return 'Nothing is running or waiting on a decision.';
  return 'Nothing is waiting on a decision. ${_cap(_join(motion))}.';
}
