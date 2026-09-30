import 'assist.dart';
import 'baseline.dart';
import 'gate.dart';
import 'json_util.dart';
import 'project.dart';
import 'system.dart';
import 'test_first.dart';
import 'workspace.dart';
import 'xp.dart';

/// Every message on `/ws` and `/ws/workspaces/{id}` is `{channel: ..., ...}`. This is the
/// parsed form. Channels for removed features (`quality`, `race_*` notifies) come back as
/// [UnknownWsEvent] / [UnknownNotify] and are ignorable.
sealed class WsEvent {
  const WsEvent();
}

/// `channel: agent`. The backend always sends `session_id`; the primary session is `main`.
class AgentStreamEvent extends WsEvent {
  const AgentStreamEvent(this.event, {this.sessionId});
  final AgentEvent event;
  final String? sessionId;
}

/// `channel: test`: the authoritative gate. Only these may feed the state a merge rests on.
/// On the global feed the message also carries `workspaceId`; on a workspace socket it is null.
sealed class TestEvent extends WsEvent {
  const TestEvent({this.workspaceId});
  final String? workspaceId;
}

class TestRunStarted extends TestEvent {
  const TestRunStarted({super.workspaceId});
}

class TestCellEvent extends TestEvent {
  const TestCellEvent(this.cell, {super.workspaceId});
  final Cell cell;
}

class TestSnapshotEvent extends TestEvent {
  const TestSnapshotEvent(this.run, {super.workspaceId});
  final TestRun run;
}

/// `channel: watch`: the Live Gate's advisory stream. Deliberately NOT a [TestEvent]: it
/// wraps one, so the type system refuses to feed a watch cell into gate state.
class WatchEvent extends WsEvent {
  const WatchEvent(this.inner);
  final TestEvent inner;
}

/// `channel: status`. Fields are optional because the backend sends several shapes:
/// a bare status change, a setup-only message, and a gate-completion message that also
/// carries the fresh [gate] summary and [trust] report.
class StatusEvent extends WsEvent {
  const StatusEvent({
    required this.workspaceId,
    this.status,
    this.statusRaw,
    this.setup,
    this.gate,
    this.trust,
    this.testFirst,
    this.mode,
  });

  final String workspaceId;
  final WorkspaceStatus? status;
  final String? statusRaw;
  final SetupState? setup;
  final GateSummary? gate;
  final TrustReport? trust;

  /// Present only on a test-first workspace.
  final TestFirstState? testFirst;

  /// Present on every backend status message since workspace modes; null from older ones.
  final WorkspaceMode? mode;
}

/// `channel: assist`: progress of a manual-rail plan or research run. `kind` is `queued`,
/// `started`, `token`, `done`, `error` or `stopped`. A `done` plan run carries [plan]; a `done`
/// research run carries [answer] and [rows].
class AssistEvent extends WsEvent {
  const AssistEvent({
    required this.job,
    required this.kind,
    this.jobId,
    this.text = '',
    this.message = '',
    this.plan,
    this.answer,
    this.rows = const [],
    this.note,
    this.costUsd,
    this.guardNote,
    this.blockedCalls = const [],
  });

  /// `plan` | `research`.
  final String job;
  final String kind;
  final String? jobId;
  final String text;
  final String message;
  final ManualPlan? plan;
  final String? answer;
  final List<ResearchRow> rows;
  final String? note;
  final double? costUsd;

  /// On a `done`: the backend could not check the worktree during the run.
  final String? guardNote;

  /// On a `done`: tools the run tried that it does not have.
  final List<String> blockedCalls;
}

/// `channel: run`: dev-server state or a log line (the Dev log tab).
class RunEvent extends WsEvent {
  const RunEvent({
    this.runId = 'app',
    this.running,
    this.url,
    this.exit,
    this.error,
    this.line,
  });

  final String runId;
  final bool? running;
  final String? url;
  final int? exit;
  final String? error;
  final String? line;

  bool get isLogLine => line != null;
}

/// `channel: fs`: the backend watcher saw the worktree change (`changed` | `quiescent`).
class FsEvent extends WsEvent {
  const FsEvent(this.kind, {this.workspaceId});
  final String kind;
  final String? workspaceId;
}

sealed class NotifyEvent extends WsEvent {
  const NotifyEvent();
}

class AgentDoneNotify extends NotifyEvent {
  const AgentDoneNotify({
    required this.workspaceId,
    this.workspaceName,
    this.status,
  });
  final String workspaceId;
  final String? workspaceName;

  /// `done` | `error`.
  final String? status;
}

class CostWarningNotify extends NotifyEvent {
  const CostWarningNotify({
    required this.workspaceId,
    this.workspaceName,
    this.totalUsd = 0,
    this.thresholdUsd = 0,
  });
  final String workspaceId;
  final String? workspaceName;
  final double totalUsd;
  final double thresholdUsd;
}

class GateResultNotify extends NotifyEvent {
  const GateResultNotify({
    required this.workspaceId,
    required this.green,
    this.workspaceName,
    this.workspaceKind,
    this.passed = 0,
    this.failed = 0,
    this.total = 0,
  });
  final String workspaceId;
  final bool green;
  final String? workspaceName;
  final WorkspaceKind? workspaceKind;
  final int passed;
  final int failed;
  final int total;
}

class RungNotify extends NotifyEvent {
  const RungNotify({
    required this.workspaceId,
    this.workspaceName,
    this.state = '',
    this.detail = '',
    this.prUrl,
    this.streak = 0,
  });
  final String workspaceId;
  final String? workspaceName;

  /// `fired` | `held` | `failed`.
  final String state;
  final String detail;
  final String? prUrl;
  final int streak;
}

class BacklogChangedNotify extends NotifyEvent {
  const BacklogChangedNotify(this.projectId);
  final String projectId;
}

class ArchiveQueueNotify extends NotifyEvent {
  const ArchiveQueueNotify(this.run);
  final ArchiveQueueRun run;
}

class UpdateStatusNotify extends NotifyEvent {
  const UpdateStatusNotify(this.status);
  final UpdateStatus status;
}

class UpdateApplyingNotify extends NotifyEvent {
  const UpdateApplyingNotify();
}

class UnknownNotify extends NotifyEvent {
  const UnknownNotify(this.kind, this.raw);
  final String kind;
  final Json raw;
}

/// `channel: xp` on the global feed: an award was just paid. [amount] and [label] sum the
/// XP awards; badges unlocked by the same event are in [awards].
class XpWsEvent extends WsEvent {
  const XpWsEvent({
    this.workspaceId,
    this.amount = 0,
    this.label = '',
    this.awards = const [],
  });

  final String? workspaceId;
  final int amount;
  final String label;
  final List<XpAward> awards;

  List<String> get badges => [
    for (final a in awards)
      if (a.badge) a.label,
  ];
}

/// `channel: baseline` on the global feed: the First-run baseline gate for one project.
/// [kind] is `started` | `cell` | `done` | `error`. `cell` carries the running counts;
/// `done` and `error` carry the final [result].
class BaselineWsEvent extends WsEvent {
  const BaselineWsEvent({
    required this.projectId,
    required this.kind,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.result,
  });

  final String projectId;
  final String kind;
  final int passed;
  final int failed;
  final int skipped;
  final BaselineRun? result;
}

class UnknownWsEvent extends WsEvent {
  const UnknownWsEvent(this.raw);
  final Json raw;
}

/// Parses one decoded JSON envelope. Never throws on an unrecognized shape.
WsEvent parseWsEvent(Json j) {
  final channel = jStr(j, 'channel');
  switch (channel) {
    case 'agent':
      return AgentStreamEvent(
        AgentEvent.fromJson(asJson(j['event'])),
        sessionId: jStrN(j, 'session_id'),
      );
    case 'test':
      return _parseTest(j) ?? UnknownWsEvent(j);
    case 'watch':
      final inner = _parseTest(j);
      return inner == null ? UnknownWsEvent(j) : WatchEvent(inner);
    case 'status':
      final status = j['status'];
      return StatusEvent(
        workspaceId: jStr(j, 'workspace_id'),
        status: status is String ? WorkspaceStatus.parse(status) : null,
        statusRaw: status is String ? status : null,
        setup: j['setup'] is Map
            ? SetupState.fromJson(asJson(j['setup']))
            : null,
        gate: j['gate'] is Map ? GateSummary.fromJson(asJson(j['gate'])) : null,
        trust: j['trust'] is Map
            ? TrustReport.fromJson(asJson(j['trust']))
            : null,
        testFirst: j['test_first'] is Map
            ? TestFirstState.fromJson(asJson(j['test_first']))
            : null,
        mode: j['mode'] is String ? WorkspaceMode.parse(j['mode']) : null,
      );
    case 'run':
      return RunEvent(
        runId: jStr(j, 'run_id', 'app'),
        running: jBoolN(j, 'running'),
        url: jStrN(j, 'url'),
        exit: jIntN(j, 'exit'),
        error: jStrN(j, 'error'),
        line: jStrN(j, 'line'),
      );
    case 'assist':
      return AssistEvent(
        job: jStr(j, 'job'),
        kind: jStr(j, 'kind'),
        jobId: jStrN(j, 'job_id'),
        text: jStr(j, 'text'),
        message: jStr(j, 'message'),
        plan: j['plan'] is Map ? ManualPlan.fromJson(asJson(j['plan'])) : null,
        answer: jStrN(j, 'answer'),
        rows: jList(j, 'rows', ResearchRow.fromJson),
        note: jStrN(j, 'note'),
        costUsd: jDoubleN(j, 'cost_usd'),
        guardNote: jStrN(j, 'guard_note'),
        blockedCalls: jStrList(j, 'blocked_calls'),
      );
    case 'fs':
      return FsEvent(jStr(j, 'kind'), workspaceId: jStrN(j, 'workspace_id'));
    case 'notify':
      return _parseNotify(j);
    case 'baseline':
      return BaselineWsEvent(
        projectId: jStr(j, 'project_id'),
        kind: jStr(j, 'kind'),
        passed: jInt(j, 'passed'),
        failed: jInt(j, 'failed'),
        skipped: jInt(j, 'skipped'),
        result: j['result'] is Map
            ? BaselineRun.fromJson(asJson(j['result']))
            : null,
      );
    case 'xp':
      return XpWsEvent(
        workspaceId: jStrN(j, 'workspace_id'),
        amount: jInt(j, 'amount'),
        label: jStr(j, 'label'),
        awards: jList(j, 'awards', XpAward.fromJson),
      );
  }
  return UnknownWsEvent(j);
}

TestEvent? _parseTest(Json j) {
  final ws = jStrN(j, 'workspace_id');
  switch (jStr(j, 'kind')) {
    case 'run_started':
      return TestRunStarted(workspaceId: ws);
    case 'cell':
      return TestCellEvent(Cell.fromJson(asJson(j['cell'])), workspaceId: ws);
    case 'snapshot':
      return TestSnapshotEvent(
        TestRun.fromJson(asJson(j['test'])),
        workspaceId: ws,
      );
  }
  return null;
}

NotifyEvent _parseNotify(Json j) {
  final kind = jStr(j, 'kind');
  switch (kind) {
    case 'agent_done':
      return AgentDoneNotify(
        workspaceId: jStr(j, 'workspace_id'),
        workspaceName: jStrN(j, 'workspace_name'),
        status: jStrN(j, 'status'),
      );
    case 'cost_warning':
      return CostWarningNotify(
        workspaceId: jStr(j, 'workspace_id'),
        workspaceName: jStrN(j, 'workspace_name'),
        totalUsd: jDouble(j, 'total_usd'),
        thresholdUsd: jDouble(j, 'threshold_usd'),
      );
    case 'gate_green':
    case 'gate_red':
      return GateResultNotify(
        workspaceId: jStr(j, 'workspace_id'),
        green: kind == 'gate_green',
        workspaceName: jStrN(j, 'workspace_name'),
        workspaceKind: j['workspace_kind'] is String
            ? WorkspaceKind.parse(j['workspace_kind'])
            : null,
        passed: jInt(j, 'passed'),
        failed: jInt(j, 'failed'),
        total: jInt(j, 'total'),
      );
    case 'rung':
      return RungNotify(
        workspaceId: jStr(j, 'workspace_id'),
        workspaceName: jStrN(j, 'workspace_name'),
        state: jStr(j, 'state'),
        detail: jStr(j, 'detail'),
        prUrl: jStrN(j, 'pr_url'),
        streak: jInt(j, 'streak'),
      );
    case 'backlog_changed':
      return BacklogChangedNotify(jStr(j, 'project_id'));
    case 'archive_queue':
      return ArchiveQueueNotify(ArchiveQueueRun.fromJson(asJson(j['run'])));
    case 'update_status':
      return UpdateStatusNotify(UpdateStatus.fromJson(j));
    case 'update_applying':
      return const UpdateApplyingNotify();
  }
  return UnknownNotify(kind, j);
}
