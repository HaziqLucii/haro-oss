import 'package:haro_app/api/models/models.dart';

int _n = 0;

AgentEvent _ev(
  String type,
  Map<String, dynamic> payload, {
  int? turn,
  String runId = 'run_1',
  double? ts,
}) => AgentEvent.fromJson({
  'run_id': runId,
  'workspace_id': 'ws_1',
  'ts': ts ?? (1790000000.0 + _n++),
  'type': type,
  'payload': payload,
  'turn': ?turn,
});

AgentEvent userEv(
  String text, {
  int turn = 1,
  double? ts,
  String runId = 'user',
}) => _ev('user', {'text': text}, turn: turn, ts: ts, runId: runId);

AgentEvent metaEv({
  String model = 'claude-sonnet-5',
  Object? effort = 'high',
  String? role = 'build',
  int turn = 1,
  bool text = false,
}) => _ev('token', {
  'system': true,
  if (!text) 'meta': true,
  'model': model,
  'effort': effort,
  'role': ?role,
  if (text) 'text': '◆ session started (model: $model)\n',
}, turn: turn);

AgentEvent tokEv(String text, {int turn = 1}) =>
    _ev('token', {'text': text}, turn: turn);

AgentEvent toolEv(String tool, String summary, {int turn = 1}) =>
    _ev('tool_call', {'tool': tool, 'summary': summary}, turn: turn);

AgentEvent editEv(
  String path, {
  String tool = 'Edit',
  int added = 1,
  int removed = 0,
  int turn = 1,
}) => _ev('file_edit', {
  'tool': tool,
  'path': path,
  'added': added,
  'removed': removed,
  'diff': const [],
}, turn: turn);

AgentEvent errorEv(String message, {int turn = 1}) =>
    _ev('error', {'message': message}, turn: turn);

AgentEvent doneEv({
  int durationMs = 841000,
  double cost = 9.89,
  bool plan = false,
  int? contextWindow = 1000000,
  int? contextTokens = 208817,
  int turn = 1,
}) => _ev('done', {
  'duration_ms': durationMs,
  'cost_usd': cost,
  'tokens_in': 182,
  'tokens_out': 48762,
  'context_window': ?contextWindow,
  'context_tokens': ?contextTokens,
  if (plan) 'plan': true,
}, turn: turn);

/// The prototype's transcript: read, bash, prose, three edits, bash, prose, done.
List<AgentEvent> prototypeTranscript() => [
  userEv(
    'Make the desktop app start faster. Profile the boot, fix the slow steps, '
    'and keep the backend shutdown clean.',
    ts: 1790000000,
  ),
  metaEv(text: true),
  toolEv('Read', 'desktop/main.js'),
  toolEv('Bash', 'HARO_BOOT_TRACE=1 npm run desktop'),
  tokEv('Boot takes 3.4s. Most of it is a blocking PATH scrape. '),
  tokEv('I will make the scrape async.'),
  editEv(
    '/Users/dev/.haro/worktrees/electron/desktop/main.js',
    added: 211,
    removed: 134,
  ),
  editEv('backend/desktop_app.py', added: 7, removed: 2),
  editEv('frontend/src/App.tsx', added: 240, removed: 211),
  toolEv('Bash', 'npm test --prefix frontend'),
  tokEv('Done. Root chunk drops from 1,081 kB to 624 kB.'),
  doneEv(),
];

/// The driving agent's call that starts a sub-agent (`↳ Explore: <description>`).
AgentEvent delegateStartEv(
  String id,
  String type,
  String description, {
  int turn = 1,
  String? kind,
}) => _ev('tool_call', {
  'tool': 'Agent',
  'summary': '↳ $type: $description',
  'delegate': {
    'id': id,
    'subagent_type': type,
    'description': description,
    'status': 'running',
    'kind': ?kind,
  },
}, turn: turn);

/// The hand-back that settles it (`done` or `error`).
AgentEvent delegateDoneEv(
  String id,
  String type, {
  String status = 'done',
  int turn = 1,
}) => _ev('tool_call', {
  'tool': 'Agent',
  'summary': '↳ $type: $status — sent back to main agent',
  'delegate': {'id': id, 'subagent_type': type, 'status': status},
}, turn: turn);

/// One of a sub-agent's own steps, tagged with the delegation it belongs to.
AgentEvent nestedToolEv(
  String parent,
  String tool,
  String summary, {
  int turn = 1,
}) => _ev('tool_call', {
  'tool': tool,
  'summary': summary,
  'parent': parent,
}, turn: turn);

AgentEvent nestedTokEv(String parent, String text, {int turn = 1}) =>
    _ev('token', {'text': text, 'parent': parent}, turn: turn);
