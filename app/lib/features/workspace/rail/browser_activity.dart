import '../../../api/models/models.dart';

/// The tools of the workspace's shared browser (the `haro_browser` MCP server, `browser.py`).
const _sharedBrowserTools = 'mcp__haro_browser__';

/// What the agent is doing in the shared browser right now (`navigate`, `click`...), or null.
///
/// A tool call has no end event of its own, so "in the middle of one" is read the way the stream
/// does: the run is going and the newest event is a browser call. The next event (the agent's next
/// words or step) or the end of the run says it has stopped. A background agent's steps
/// ([subEvents]) count too: whichever of the two lists has the newest event decides.
String? browserInUse(
  List<AgentEvent> events, {
  required bool running,
  List<AgentEvent> subEvents = const [],
}) {
  if (!running) return null;
  final main = events.isEmpty ? null : events.last;
  final sub = subEvents.isEmpty ? null : subEvents.last;
  final e = main == null
      ? sub
      : sub == null
      ? main
      : (sub.ts > main.ts ? sub : main);
  if (e == null) return null;
  if (e.type != AgentEventType.toolCall) return null;
  final tool = e.tool;
  if (!tool.startsWith(_sharedBrowserTools)) return null;
  final name = tool
      .substring(_sharedBrowserTools.length)
      .replaceFirst(RegExp('^browser_'), '');
  return name.isEmpty ? 'browser' : name.replaceAll('_', ' ');
}
