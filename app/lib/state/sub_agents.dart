import '../api/models/models.dart';

/// A step of a delegated sub-agent's own work: the backend tags each with the delegation it
/// belongs to (`payload.parent`). They are kept out of the main stream and read only here.
bool isNestedEvent(AgentEvent e) {
  final p = e.payload['parent'];
  return p is String && p.isNotEmpty;
}

/// Splits one transcript into the driving agent's events and the sub-agents' own.
(List<AgentEvent>, List<AgentEvent>) splitNested(List<AgentEvent> all) {
  final main = <AgentEvent>[];
  final nested = <AgentEvent>[];
  for (final e in all) {
    (isNestedEvent(e) ? nested : main).add(e);
  }
  return (main, nested);
}

enum SubAgentStatus { running, done, error, stopped }

/// One thing a sub-agent did: a tool call, or a run of its own words.
class SubAgentStep {
  const SubAgentStep({required this.text, this.tool = '', this.prose = false});

  /// Tool: its one-line summary. Prose: what the sub-agent said.
  final String text;
  final String tool;
  final bool prose;
}

/// A delegation to a sub-agent (scout, Explore, code-review...): what it was asked, how it is
/// going, and what it has done so far.
class SubAgent {
  const SubAgent({
    required this.id,
    required this.type,
    required this.description,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.steps = const [],
  });

  final String id;
  final String type;
  final String description;
  final SubAgentStatus status;

  /// Unix seconds of the delegation row and, once settled, of its hand-back.
  final double startedAt;
  final double? endedAt;
  final List<SubAgentStep> steps;

  bool get running => status == SubAgentStatus.running;

  /// The newest tool line, for the one-line list row.
  String? get latestTool {
    for (var i = steps.length - 1; i >= 0; i--) {
      if (!steps[i].prose) {
        final s = steps[i];
        return s.text.isEmpty ? s.tool : '${s.tool} ${s.text}';
      }
    }
    return null;
  }

  /// The sub-agent's last words: its hand-back to the driving agent.
  String? get finalText {
    for (var i = steps.length - 1; i >= 0; i--) {
      if (steps[i].prose) return steps[i].text;
    }
    return null;
  }
}

/// Builds the sub-agent list from the driving agent's events (which carry each delegation's
/// start and hand-back rows) and the tagged inner events. [live] says the run is still going:
/// a delegation still "running" after the run ended was cut off.
List<SubAgent> deriveSubAgents(
  List<AgentEvent> main,
  List<AgentEvent> nested, {
  required bool live,
}) {
  final order = <String>[];
  final type = <String, String>{};
  final desc = <String, String>{};
  final status = <String, SubAgentStatus>{};
  final started = <String, double>{};
  final ended = <String, double>{};

  for (final e in main) {
    if (e.type != AgentEventType.toolCall) continue;
    final d = e.payload['delegate'];
    if (d is! Map) continue;
    final id = d['id'];
    if (id is! String || id.isEmpty) continue;
    if (!status.containsKey(id)) {
      order.add(id);
      started[id] = e.ts;
      status[id] = SubAgentStatus.running;
    }
    final t = d['subagent_type'];
    if (t is String && t.isNotEmpty) type[id] = t;
    final text = d['description'];
    if (text is String && text.isNotEmpty) desc[id] = text;
    switch (d['status']) {
      case 'done':
        status[id] = SubAgentStatus.done;
        ended[id] = e.ts;
      case 'error':
        status[id] = SubAgentStatus.error;
        ended[id] = e.ts;
      case 'stopped':
        status[id] = SubAgentStatus.stopped;
        ended[id] = e.ts;
    }
  }

  final steps = <String, List<SubAgentStep>>{};
  for (final e in nested) {
    final parent = e.payload['parent'] as String;
    final list = steps.putIfAbsent(parent, () => []);
    if (e.type == AgentEventType.token) {
      final text = e.text;
      if (text.trim().isEmpty) continue;
      if (list.isNotEmpty && list.last.prose) {
        list[list.length - 1] = SubAgentStep(
          text: list.last.text + text,
          prose: true,
        );
      } else {
        list.add(SubAgentStep(text: text, prose: true));
      }
    } else if (e.type == AgentEventType.toolCall) {
      final s = e.payload['summary'];
      list.add(
        SubAgentStep(
          tool: e.tool.isEmpty ? 'Tool' : e.tool,
          text: s is String ? s : '',
        ),
      );
    }
  }

  return [
    for (final id in order)
      SubAgent(
        id: id,
        type: type[id] ?? 'agent',
        description: desc[id] ?? '',
        status: switch (status[id]!) {
          SubAgentStatus.running when !live => SubAgentStatus.stopped,
          final s => s,
        },
        startedAt: started[id]!,
        endedAt: ended[id],
        steps: steps[id] ?? const [],
      ),
  ];
}
