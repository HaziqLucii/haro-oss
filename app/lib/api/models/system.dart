import 'json_util.dart';

class FileNode {
  const FileNode({
    required this.name,
    required this.path,
    this.dir = false,
    this.children = const [],
  });

  final String name;
  final String path;
  final bool dir;
  final List<FileNode> children;

  factory FileNode.fromJson(Json j) => FileNode(
    name: jStr(j, 'name'),
    path: jStr(j, 'path'),
    dir: jBool(j, 'dir'),
    children: jList(j, 'children', FileNode.fromJson),
  );
}

class FileContent {
  const FileContent({
    required this.path,
    this.content = '',
    this.error,
    this.size,
  });

  final String path;
  final String content;

  /// Set when the file is guarded (too large or binary); content is then empty.
  final String? error;
  final int? size;

  factory FileContent.fromJson(Json j) => FileContent(
    path: jStr(j, 'path'),
    content: jStr(j, 'content'),
    error: jStrN(j, 'error'),
    size: jIntN(j, 'size'),
  );
}

/// The committed side of a per-file diff. `exists == false` means the file is new.
class FileBase {
  const FileBase({this.content = '', this.exists = false, this.error});

  final String content;
  final bool exists;
  final String? error;

  factory FileBase.fromJson(Json j) => FileBase(
    content: jStr(j, 'content'),
    exists: jBool(j, 'exists'),
    error: jStrN(j, 'error'),
  );
}

class SearchMatch {
  const SearchMatch({
    required this.file,
    this.line = 0,
    this.col = 0,
    this.text = '',
  });

  final String file;
  final int line;
  final int col;
  final String text;

  factory SearchMatch.fromJson(Json j) => SearchMatch(
    file: jStr(j, 'file'),
    line: jInt(j, 'line'),
    col: jInt(j, 'col'),
    text: jStr(j, 'text'),
  );
}

class SearchResult {
  const SearchResult({this.matches = const [], this.truncated = false});

  final List<SearchMatch> matches;
  final bool truncated;

  factory SearchResult.fromJson(Json j) => SearchResult(
    matches: jList(j, 'matches', SearchMatch.fromJson),
    truncated: jBool(j, 'truncated'),
  );
}

class ContextAttachment {
  const ContextAttachment({
    required this.path,
    this.name = '',
    this.kind = 'text',
    this.lines,
    this.size,
  });

  final String path;
  final String name;

  /// `text` | `image` | `file`.
  final String kind;
  final int? lines;
  final int? size;

  factory ContextAttachment.fromJson(Json j) => ContextAttachment(
    path: jStr(j, 'path'),
    name: jStr(j, 'name'),
    kind: jStr(j, 'kind', 'text'),
    lines: jIntN(j, 'lines'),
    size: jIntN(j, 'size'),
  );
}

class RunAppResult {
  const RunAppResult({required this.running, this.url});

  final bool running;
  final String? url;

  factory RunAppResult.fromJson(Json j) =>
      RunAppResult(running: jBool(j, 'running'), url: jStrN(j, 'url'));
}

class ContinueResult {
  const ContinueResult({
    this.branch = '',
    this.baseRef = '',
    this.priorPrs = const [],
    this.detail = '',
  });

  final String branch;
  final String baseRef;
  final List<int> priorPrs;
  final String detail;

  factory ContinueResult.fromJson(Json j) => ContinueResult(
    branch: jStr(j, 'branch'),
    baseRef: jStr(j, 'base_ref'),
    priorPrs: jIntList(j, 'prior_prs'),
    detail: jStr(j, 'detail'),
  );
}

// Merge queue and bulk archive.

class MergeQueueItem {
  const MergeQueueItem({
    required this.workspaceId,
    this.name = '',
    this.outcome = 'blocked',
    this.reason,
    this.conflicts = const [],
    this.gate,
  });

  final String workspaceId;
  final String name;

  /// `merged` | `ready` | `blocked` | `skipped`.
  final String outcome;
  final String? reason;
  final List<String> conflicts;

  /// Merge train verdict: `green` | `red` | `error`, or null when the train was off.
  final String? gate;

  factory MergeQueueItem.fromJson(Json j) => MergeQueueItem(
    workspaceId: jStr(j, 'workspace_id'),
    name: jStr(j, 'name'),
    outcome: jStr(j, 'outcome', 'blocked'),
    reason: jStrN(j, 'reason'),
    conflicts: jStrList(j, 'conflicts'),
    gate: jStrN(j, 'gate'),
  );
}

class MergeQueueResult {
  const MergeQueueResult({
    this.dry = false,
    this.train = false,
    this.items = const [],
  });

  final bool dry;

  /// Each candidate was gated on the advanced base plus itself before landing.
  final bool train;
  final List<MergeQueueItem> items;

  factory MergeQueueResult.fromJson(Json j) => MergeQueueResult(
    dry: jBool(j, 'dry'),
    train: jBool(j, 'train'),
    items: jList(j, 'items', MergeQueueItem.fromJson),
  );
}

enum ArchiveOutcome {
  queued('queued'),
  archiving('archiving'),
  archived('archived'),
  failed('failed'),
  skipped('skipped'),
  canceled('canceled'),
  unknown('');

  const ArchiveOutcome(this.wire);
  final String wire;

  static ArchiveOutcome parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

class ArchiveQueueItem {
  const ArchiveQueueItem({
    required this.workspaceId,
    this.name = '',
    this.outcome = ArchiveOutcome.queued,
    this.reason,
    this.risks = const [],
  });

  final String workspaceId;
  final String name;
  final ArchiveOutcome outcome;
  final String? reason;

  /// What the workspace stands to lose (uncommitted edits, unmerged commits, running agent).
  final List<String> risks;

  factory ArchiveQueueItem.fromJson(Json j) => ArchiveQueueItem(
    workspaceId: jStr(j, 'workspace_id'),
    name: jStr(j, 'name'),
    outcome: ArchiveOutcome.parse(j['outcome']),
    reason: jStrN(j, 'reason'),
    risks: jStrList(j, 'risks'),
  );
}

class ArchiveQueueRun {
  const ArchiveQueueRun({
    required this.id,
    this.projectId = '',
    this.dry = false,
    this.force = false,
    this.state = 'planned',
    this.stopRequested = false,
    this.items = const [],
    this.createdAt,
    this.finishedAt,
  });

  final String id;
  final String projectId;

  /// A preview: same shape as a live run, nothing torn down.
  final bool dry;
  final bool force;

  /// `planned` | `running` | `done` | `canceled`.
  final String state;
  final bool stopRequested;
  final List<ArchiveQueueItem> items;
  final double? createdAt;
  final double? finishedAt;

  bool get isRunning => state == 'running';

  factory ArchiveQueueRun.fromJson(Json j) => ArchiveQueueRun(
    id: jStr(j, 'id'),
    projectId: jStr(j, 'project_id'),
    dry: jBool(j, 'dry'),
    force: jBool(j, 'force'),
    state: jStr(j, 'state', 'planned'),
    stopRequested: jBool(j, 'stop_requested'),
    items: jList(j, 'items', ArchiveQueueItem.fromJson),
    createdAt: jDoubleN(j, 'created_at'),
    finishedAt: jDoubleN(j, 'finished_at'),
  );
}

// Desktop update and Claude usage (Settings > System / Usage).

class UpdateStatus {
  const UpdateStatus({
    this.supported = false,
    this.available = false,
    this.pending = false,
    this.buildSha = '',
    this.headSha = '',
    this.busy = false,
    this.busyReason,
    this.mode = 'manual',
  });

  final bool supported;
  final bool available;
  final bool pending;
  final String buildSha;
  final String headSha;
  final bool busy;
  final String? busyReason;

  /// `manual` | `auto`.
  final String mode;

  factory UpdateStatus.fromJson(Json j) => UpdateStatus(
    supported: jBool(j, 'supported'),
    available: jBool(j, 'available'),
    pending: jBool(j, 'pending'),
    buildSha: jStr(j, 'buildSha'),
    headSha: jStr(j, 'headSha'),
    busy: jBool(j, 'busy'),
    busyReason: jStrN(j, 'busyReason'),
    mode: jStr(j, 'mode', 'manual'),
  );
}

class UpdateProgress {
  const UpdateProgress({this.pct = 0, this.label = ''});

  final double pct;
  final String label;

  factory UpdateProgress.fromJson(Json j) =>
      UpdateProgress(pct: jDouble(j, 'pct'), label: jStr(j, 'label'));
}

class UsageLimit {
  const UsageLimit({
    required this.kind,
    this.group = '',
    this.label = '',
    this.percent,
    this.severity = 'normal',
    this.resetsAt,
    this.isActive = false,
  });

  final String kind;
  final String group;
  final String label;
  final double? percent;
  final String severity;

  /// ISO 8601.
  final String? resetsAt;
  final bool isActive;

  factory UsageLimit.fromJson(Json j) => UsageLimit(
    kind: jStr(j, 'kind'),
    group: jStr(j, 'group'),
    label: jStr(j, 'label'),
    percent: jDoubleN(j, 'percent'),
    severity: jStr(j, 'severity', 'normal'),
    resetsAt: jStrN(j, 'resets_at'),
    isActive: jBool(j, 'is_active'),
  );
}

class UsageSpend {
  const UsageSpend({
    this.percent,
    this.severity = 'normal',
    this.usedLabel,
    this.limitLabel,
    this.disclaimer,
  });

  final double? percent;
  final String severity;
  final String? usedLabel;
  final String? limitLabel;
  final String? disclaimer;

  factory UsageSpend.fromJson(Json j) => UsageSpend(
    percent: jDoubleN(j, 'percent'),
    severity: jStr(j, 'severity', 'normal'),
    usedLabel: jStrN(j, 'used_label'),
    limitLabel: jStrN(j, 'limit_label'),
    disclaimer: jStrN(j, 'disclaimer'),
  );
}

class UsageAccount {
  const UsageAccount({this.name, this.email, this.org, this.plan});

  final String? name;
  final String? email;
  final String? org;
  final String? plan;

  factory UsageAccount.fromJson(Json j) => UsageAccount(
    name: jStrN(j, 'name'),
    email: jStrN(j, 'email'),
    org: jStrN(j, 'org'),
    plan: jStrN(j, 'plan'),
  );
}

class UsageResponse {
  const UsageResponse({
    required this.available,
    this.reason,
    this.detail,
    this.fetchedAt,
    this.account,
    this.limits = const [],
    this.spend,
  });

  /// `false` carries a [reason]: `no_credentials` | `token_expired` | `fetch_failed`.
  final bool available;
  final String? reason;
  final String? detail;
  final double? fetchedAt;
  final UsageAccount? account;
  final List<UsageLimit> limits;
  final UsageSpend? spend;

  factory UsageResponse.fromJson(Json j) => UsageResponse(
    available: jBool(j, 'available'),
    reason: jStrN(j, 'reason'),
    detail: jStrN(j, 'detail'),
    fetchedAt: jDoubleN(j, 'fetched_at'),
    account: j['account'] is Map
        ? UsageAccount.fromJson(asJson(j['account']))
        : null,
    limits: jList(j, 'limits', UsageLimit.fromJson),
    spend: j['spend'] is Map ? UsageSpend.fromJson(asJson(j['spend'])) : null,
  );
}
