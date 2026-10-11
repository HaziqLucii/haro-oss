import 'dart:convert';

import '../../../../api/models/models.dart';
import '../../../../state/format.dart' show plural;

/// Pure derivation of the agent stream from the flat transcript. The widgets only render
/// [StreamRow]s, so grouping, footer copy and labels are testable without a widget tree.

/// One turn: the `user` event that opened it (null for transcripts that predate turn
/// markers) and everything the agent did until the next one. Mirrors `turns.ts`.
class TurnGroup {
  const TurnGroup({this.marker, this.user, required this.events});

  final TurnMarker? marker;
  final AgentEvent? user;
  final List<AgentEvent> events;
}

List<TurnGroup> groupTurns(List<AgentEvent> events) {
  final groups = <TurnGroup>[];
  AgentEvent? user;
  var body = <AgentEvent>[];

  void close() {
    if (user == null && body.isEmpty) return;
    final u = user;
    final marker = u == null ? null : TurnMarker.derive([u]).firstOrNull;
    groups.add(TurnGroup(marker: marker, user: u, events: body));
    body = <AgentEvent>[];
  }

  for (final e in events) {
    if (e.type == AgentEventType.user) {
      close();
      user = e;
    } else {
      body.add(e);
    }
  }
  close();
  return groups;
}

sealed class StreamRow {
  const StreamRow();
}

class UserRow extends StreamRow {
  const UserRow({required this.text, required this.ts, required this.kind});

  final String text;

  /// Epoch seconds.
  final double ts;

  /// `user` | `autofix` | `reviewfix`.
  final String kind;

  String get label => switch (kind) {
    'autofix' => 'AUTOFIX',
    'reviewfix' => 'REVIEW FIX',
    _ => 'YOU',
  };
}

class AgentLabelRow extends StreamRow {
  const AgentLabelRow({this.role, this.model, this.effort});

  final String? role;
  final String? model;
  final String? effort;

  /// `AGENT · build · sonnet-5 · high`; parts the run did not report are left out.
  String get text => ['AGENT', ?role, ?model, ?effort].join(' · ');
}

class ProseRow extends StreamRow {
  const ProseRow(this.text);

  final String text;
}

class ToolRow extends StreamRow {
  const ToolRow({
    required this.tool,
    this.target = '',
    this.added,
    this.removed,
    this.running = false,
    this.delegate = false,
    this.delegateId,
    this.path,
  });

  final String tool;
  final String target;
  final int? added;
  final int? removed;
  final bool running;

  /// A sub-agent hand-off (`↳ scout: ...`): dimmed, no tool name.
  final bool delegate;

  /// The delegation's id (the Agent/Task tool call), so the row can open that sub-agent.
  final String? delegateId;

  /// Worktree-relative path of a `file_edit`, so the row can offer "open in code".
  final String? path;

  bool get hasStats => (added ?? 0) > 0 || (removed ?? 0) > 0;
}

class ErrorRow extends StreamRow {
  const ErrorRow(this.message);

  final String message;
}

/// The agent asked the human something (`AskUserQuestion`).
class QuestionRow extends StreamRow {
  const QuestionRow({
    required this.question,
    this.options = const [],
    this.waiting = false,
  });

  final String question;
  final List<String> options;

  /// The run is still blocked on this question.
  final bool waiting;
}

class FooterRow extends StreamRow {
  const FooterRow({
    this.duration,
    this.files = 0,
    this.costUsd,
    this.planReady = false,
    this.runId,
  });

  /// The run that ended here, so the newest footer can offer to restore the files to its start.
  final String? runId;
  final Duration? duration;
  final int files;
  final double? costUsd;

  /// A Plan-Mode run ended here: it planned and edited nothing.
  final bool planReady;

  /// `done in 14m 1s · 21 files · $9.89`; a plan run reads `plan ready in ...`.
  String get text {
    final parts = <String>[
      if (duration != null)
        '${planReady ? 'plan ready in' : 'done in'} ${formatWall(duration!)}'
      else
        planReady ? 'plan ready' : 'done',
      if (files > 0) '$files ${plural(files, 'file')}',
      if (costUsd != null) formatCost(costUsd!),
    ];
    return parts.join(' · ');
  }
}

/// `420ms`, `8.3s`, `42s`, `14m 1s`, `1h 5m`.
String formatWall(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms < 0 ? 0 : ms}ms';
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final secs = (ms / 1000).round();
  if (secs < 60) return '${secs}s';
  final m = secs ~/ 60;
  if (m < 60) return '${m}m ${secs % 60}s';
  return '${m ~/ 60}h ${m % 60}m';
}

/// Sub-dollar amounts keep four decimals so small follow-ups stay legible.
String formatCost(double usd) {
  final abs = usd.abs();
  final s = abs.toStringAsFixed(abs >= 1 ? 2 : 4);
  return '${usd < 0 ? '-' : ''}\$$s';
}

/// `claude-sonnet-5` -> `sonnet-5`. The CLI echoes the resolved model id.
String shortModel(String model) =>
    model.startsWith('claude-') ? model.substring(7) : model;

String? _cleanEffort(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  if (s.isEmpty || s == 'None' || s == 'null' || s == 'default') return null;
  return s;
}

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Keeps both ends of a long path or command; the tail is usually the informative part.
String truncateMid(String s, [int max = 96]) {
  if (s.length <= max) return s;
  final head = (max * .4).ceil();
  final tail = (max * .5).floor();
  return '${s.substring(0, head)}…${s.substring(s.length - tail)}';
}

/// A tool summary with the worktree's own absolute prefix taken out wherever it appears
/// (a Read of `/home/.../worktree/lib/a.ts`, a Bash `cd /home/.../worktree && ...`), so
/// the stream reads like the Edit rows and never shows the user's home path.
String relativeSummary(String text, String? root) {
  if (root == null || root.isEmpty) return text;
  final bare = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return text
      .replaceAll('$bare/', '')
      .replaceAll(RegExp('${RegExp.escape(bare)}(?=\\s|\$)'), '.');
}

String relativePath(String path, String? root) {
  if (root == null || root.isEmpty) return path;
  final prefix = root.endsWith('/') ? root : '$root/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

const askTool = 'AskUserQuestion';

/// The tool input arrives as a summary string that is cut at 200 chars, so a full parse is
/// tried first and a regex over the raw text second.
({String question, List<String> options}) parseQuestion(String summary) {
  try {
    final j = jsonDecode(summary);
    if (j is Map &&
        j['questions'] is List &&
        (j['questions'] as List).isNotEmpty) {
      final q = (j['questions'] as List).first;
      if (q is Map && q['question'] is String) {
        return (
          question: q['question'] as String,
          options: [
            if (q['options'] is List)
              for (final o in q['options'] as List)
                if (o is Map && o['label'] is String) o['label'] as String,
          ],
        );
      }
    }
  } catch (_) {
    // Truncated or not JSON: fall through to the regex.
  }
  final m = RegExp(r'"question"\s*:\s*"((?:[^"\\]|\\.)*)').firstMatch(summary);
  if (m != null) {
    final raw = m.group(1)!;
    String text;
    try {
      text = jsonDecode('"$raw"') as String;
    } catch (_) {
      text = raw;
    }
    return (question: text, options: const []);
  }
  return (question: _oneLine(summary), options: const []);
}

/// Rows for the whole transcript. [running] marks the newest tool line as in flight;
/// [waiting] marks the newest question as unanswered.
List<StreamRow> deriveStreamRows(
  List<AgentEvent> events, {
  bool running = false,
  bool waiting = false,
  String? worktreePath,
}) {
  final rows = <StreamRow>[];
  final groups = groupTurns(events);
  for (var gi = 0; gi < groups.length; gi++) {
    final g = groups[gi];
    final lastGroup = gi == groups.length - 1;
    final u = g.user;
    if (u != null) {
      rows.add(UserRow(text: u.text, ts: u.ts, kind: g.marker?.kind ?? 'user'));
    }
    _turnRows(
      g.events,
      rows,
      live: lastGroup && running,
      waiting: lastGroup && waiting,
      worktreePath: worktreePath,
    );
  }
  return rows;
}

void _turnRows(
  List<AgentEvent> events,
  List<StreamRow> rows, {
  required bool live,
  required bool waiting,
  String? worktreePath,
}) {
  String? role, model, effort;
  var labelled = false;
  final prose = StringBuffer();
  final files = <String>{};
  var segmentHasContent = false;

  void label() {
    if (labelled) return;
    labelled = true;
    rows.add(AgentLabelRow(role: role, model: model, effort: effort));
  }

  void flushProse() {
    final t = prose.toString();
    prose.clear();
    if (t.trim().isEmpty) return;
    label();
    rows.add(ProseRow(t));
  }

  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    final isLast = i == events.length - 1;
    switch (e.type) {
      case AgentEventType.token:
        final p = e.payload;
        if (p['model'] is String) {
          final m = p['model'] as String;
          if (m != '?' && m.isNotEmpty) model = shortModel(m);
          effort = _cleanEffort(p['effort']);
          final r = p['role'];
          if (r is String && r.isNotEmpty) role = r;
        }
        if (p['system'] == true || p['meta'] == true) break;
        prose.write(e.text);
        segmentHasContent = true;
      case AgentEventType.toolCall:
        flushProse();
        label();
        segmentHasContent = true;
        final summary = e.payload['summary'];
        final text = relativeSummary(
          summary is String ? summary : '',
          worktreePath,
        );
        if (e.tool == askTool) {
          final q = parseQuestion(text);
          rows.add(
            QuestionRow(
              question: q.question,
              options: q.options,
              waiting: waiting && isLast,
            ),
          );
        } else if (text.startsWith('↳')) {
          rows.add(
            ToolRow(
              tool: e.tool,
              target: truncateMid(_oneLine(text)),
              delegate: true,
              delegateId: _delegateId(e),
              running: live && isLast,
            ),
          );
        } else {
          rows.add(
            ToolRow(
              tool: e.tool.isEmpty ? 'Tool' : e.tool,
              target: truncateMid(_oneLine(text)),
              running: live && isLast,
            ),
          );
        }
      case AgentEventType.fileEdit:
        flushProse();
        label();
        segmentHasContent = true;
        final raw = e.path;
        final rel = raw == null ? null : relativePath(raw, worktreePath);
        if (rel != null) files.add(rel);
        int? n(Object? v) => v is num ? v.toInt() : null;
        rows.add(
          ToolRow(
            tool: e.tool.isEmpty ? 'Edit' : e.tool,
            target: rel == null ? '' : truncateMid(rel),
            path: rel,
            added: n(e.payload['added']),
            removed: n(e.payload['removed']),
            running: live && isLast,
          ),
        );
      case AgentEventType.error:
        flushProse();
        label();
        segmentHasContent = true;
        final m = e.payload['message'];
        rows.add(
          ErrorRow(m is String && m.isNotEmpty ? m : 'The agent failed.'),
        );
      case AgentEventType.done:
        flushProse();
        if (!segmentHasContent) break;
        final ms = e.payload['duration_ms'];
        final cost = e.payload['cost_usd'];
        rows.add(
          FooterRow(
            duration: ms is num ? Duration(milliseconds: ms.round()) : null,
            files: files.length,
            costUsd: cost is num ? cost.toDouble() : null,
            planReady: e.isPlanDone,
            runId: e.runId.isEmpty ? null : e.runId,
          ),
        );
        files.clear();
        segmentHasContent = false;
      case AgentEventType.user:
      case AgentEventType.unknown:
        break;
    }
  }
  flushProse();
  if (live && model != null) label();
}

/// Share of the model's context window the newest run used, from the newest `done` event
/// that reported both figures. Null when unknown.
int? contextPercent(List<AgentEvent> events) {
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (e.type != AgentEventType.done) continue;
    final win = e.payload['context_window'];
    final used = e.payload['context_tokens'];
    if (win is num && used is num && win > 0) {
      return (used / win * 100).round().clamp(0, 100);
    }
    return null;
  }
  return null;
}

String? _delegateId(AgentEvent e) {
  final d = e.payload['delegate'];
  final id = d is Map ? d['id'] : null;
  return id is String && id.isNotEmpty ? id : null;
}
