import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sub_agents.dart';
import '../state/workspace_flow.dart' show AgentPhase;
import 'workspace_detail.dart';

/// The workspace's delegated sub-agents (scout, Explore, code-review...), newest last, derived
/// from the driving agent's delegation rows plus the sub-agents' own tagged steps.
final subAgentsProvider = Provider.autoDispose.family<List<SubAgent>, String>((
  ref,
  id,
) {
  final main = ref.watch(workspaceDetailProvider(id).select((d) => d.events));
  final nested = ref.watch(
    workspaceDetailProvider(id).select((d) => d.subEvents),
  );
  final live = ref.watch(
    workspaceDetailProvider(id)
        .select((d) => d.agentPhase == AgentPhase.running),
  );
  return deriveSubAgents(main, nested, live: live);
});

/// Which sub-agent the rail is showing in full (its delegation id), or null for the list.
class SelectedSubAgent extends Notifier<String?> {
  SelectedSubAgent(this.workspaceId);

  final String workspaceId;

  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedSubAgentProvider =
    NotifierProvider.family<SelectedSubAgent, String?, String>(
      SelectedSubAgent.new,
    );

/// Sub-agents the dev has cleared from the rail list (a delegation id each). Only hides the
/// line; the sub-agent's record stays and opens again from its row in the stream.
class ClearedSubAgents extends Notifier<Set<String>> {
  ClearedSubAgents(this.workspaceId);

  final String workspaceId;

  @override
  Set<String> build() => const {};

  /// Clears every settled sub-agent in [agents]; running ones stay.
  void clearSettled(List<SubAgent> agents) {
    final settled = {
      for (final a in agents)
        if (!a.running) a.id,
    };
    if (settled.isNotEmpty) state = {...state, ...settled};
  }

  void clear(String id) => state = {...state, id};

  /// Opening a cleared sub-agent from the stream brings its line back.
  void restore(String id) {
    if (state.contains(id)) state = {...state}..remove(id);
  }
}

final clearedSubAgentsProvider =
    NotifierProvider.family<ClearedSubAgents, Set<String>, String>(
      ClearedSubAgents.new,
    );

/// What the rail lists: every sub-agent not cleared, and every shell or monitor that is
/// still going. A finished sub-agent keeps its row (its answer is worth reading); a finished
/// shell has nothing left to show, and a long session left a pile of "stopped" rows.
final visibleSubAgentsProvider = Provider.autoDispose
    .family<List<SubAgent>, String>((ref, id) {
      final cleared = ref.watch(clearedSubAgentsProvider(id));
      return [
        for (final a in ref.watch(subAgentsProvider(id)))
          if (!cleared.contains(a.id) && !(a.isShell && !a.running)) a,
      ];
    });
