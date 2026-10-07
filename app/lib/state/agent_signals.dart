import '../api/models/models.dart';

/// What the transcript says about the agent, for the flow derivation.
class AgentSignals {
  const AgentSignals({
    this.hasActivity = false,
    this.planReady = false,
    this.waitingOnInput = false,
    this.lastEditedFile,
    this.lastRunDuration,
  });

  static const none = AgentSignals();

  final bool hasActivity;

  /// A Plan-Mode run finished and nothing has superseded it.
  final bool planReady;

  /// The agent is blocked on a question to the human. The backend has no explicit signal
  /// for this, so it is inferred: the run is live and the newest event is an
  /// `AskUserQuestion` tool call.
  final bool waitingOnInput;
  final String? lastEditedFile;

  /// `duration_ms` reported by the newest `done` event.
  final Duration? lastRunDuration;
}

const _askTools = {'AskUserQuestion'};

/// [busy] is "the workspace status says an agent is running". [worktreePath], when given, is
/// stripped from edited paths so a row reads `lib/rates.ts` rather than an absolute path.
AgentSignals deriveAgentSignals(
  List<AgentEvent> events, {
  required bool busy,
  String? worktreePath,
}) {
  if (events.isEmpty) return AgentSignals.none;

  var planReady = false;
  if (!busy) {
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == AgentEventType.done) {
        planReady = e.isPlanDone;
        break;
      }
      if (e.type == AgentEventType.error) break;
    }
  }

  var waiting = false;
  if (busy) {
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == AgentEventType.token) continue;
      waiting = e.type == AgentEventType.toolCall && _askTools.contains(e.tool);
      break;
    }
  }

  String? lastEdited;
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (e.type == AgentEventType.fileEdit && e.path != null) {
      lastEdited = _relativize(e.path!, worktreePath);
      break;
    }
  }

  Duration? lastRun;
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (e.type == AgentEventType.done) {
      final ms = e.payload['duration_ms'];
      if (ms is num) lastRun = Duration(milliseconds: ms.round());
      break;
    }
  }

  return AgentSignals(
    hasActivity: true,
    planReady: planReady,
    waitingOnInput: waiting,
    lastEditedFile: lastEdited,
    lastRunDuration: lastRun,
  );
}

String _relativize(String path, String? root) {
  if (root == null || root.isEmpty) return path;
  final prefix = root.endsWith('/') ? root : '$root/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}
