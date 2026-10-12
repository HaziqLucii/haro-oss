import 'json_util.dart';

class GitFileStatus {
  const GitFileStatus({
    required this.path,
    this.index = '',
    this.work = '',
    this.staged = false,
    this.partial = false,
    this.origPath = '',
    this.conflict = false,
  });

  final String path;

  /// Staged change word, e.g. `modified`.
  final String index;

  /// Unstaged change word.
  final String work;
  final bool staged;

  /// Staged, with further edits in the worktree on top of what is in the index.
  final bool partial;

  /// A rename or copy's old path.
  final String origPath;

  /// Unmerged: staging it would mark the conflict resolved, so it isn't offered.
  final bool conflict;

  factory GitFileStatus.fromJson(Json j) => GitFileStatus(
    path: jStr(j, 'path'),
    index: jStr(j, 'index'),
    work: jStr(j, 'work'),
    staged: jBool(j, 'staged'),
    partial: jBool(j, 'partial'),
    origPath: jStr(j, 'orig_path'),
    conflict: jBool(j, 'conflict'),
  );
}

class GitStatusResponse {
  const GitStatusResponse({
    required this.branch,
    required this.baseRef,
    this.ahead = 0,
    this.behind = 0,
    this.dirty = 0,
    this.files = const [],
    this.mergeMode = 'both',
    this.worktreeMissing = false,
    this.countsUnknown = false,
  });

  final String branch;
  final String baseRef;
  final int ahead;
  final int behind;
  final int dirty;
  final List<GitFileStatus> files;

  /// Which ship actions to offer: `both` | `pr` | `merge`.
  final String mergeMode;

  /// No worktree on disk, so ahead/behind/dirty are unknown rather than zero.
  final bool worktreeMissing;

  /// A git read failed, so ahead/behind/dirty are placeholders, not measured zeros.
  final bool countsUnknown;

  factory GitStatusResponse.fromJson(Json j) => GitStatusResponse(
    branch: jStr(j, 'branch'),
    baseRef: jStr(j, 'base_ref'),
    ahead: jInt(j, 'ahead'),
    behind: jInt(j, 'behind'),
    dirty: jInt(j, 'dirty'),
    files: jList(j, 'files', GitFileStatus.fromJson),
    mergeMode: jStr(j, 'merge_mode', 'both'),
    worktreeMissing: jBool(j, 'worktree_missing'),
    countsUnknown: jBool(j, 'counts_unknown'),
  );
}

class GitCommit {
  const GitCommit({
    required this.sha,
    this.short = '',
    this.author = '',
    this.when = '',
    this.subject = '',
    this.own = false,
  });

  final String sha;
  final String short;
  final String author;
  final String when;
  final String subject;
  final bool own;

  factory GitCommit.fromJson(Json j) => GitCommit(
    sha: jStr(j, 'sha'),
    short: jStr(j, 'short'),
    author: jStr(j, 'author'),
    when: jStr(j, 'when'),
    subject: jStr(j, 'subject'),
    own: jBool(j, 'own'),
  );
}

class PrCheck {
  const PrCheck({required this.name, this.bucket = 'pending', this.url = ''});

  final String name;

  /// `pass` | `fail` | `pending`.
  final String bucket;
  final String url;

  factory PrCheck.fromJson(Json j) => PrCheck(
    name: jStr(j, 'name'),
    bucket: jStr(j, 'bucket', 'pending'),
    url: jStr(j, 'url'),
  );
}

class PrStatusResponse {
  const PrStatusResponse({
    this.supported = false,
    this.exists = false,
    this.reason,
    this.number,
    this.title,
    this.state,
    this.workspaceMerged = false,
    this.url,
    this.draft = false,
    this.mergeable,
    this.reviewDecision = '',
    this.comments = 0,
    this.additions = 0,
    this.deletions = 0,
    this.checks = const [],
    this.checksPassed = 0,
    this.checksFailed = 0,
    this.checksPending = 0,
  });

  final bool supported;
  final bool exists;
  final String? reason;
  final int? number;
  final String? title;
  final String? state;

  /// Server-reconciled merged verdict (head_sha aware). Read this, not `state == MERGED`:
  /// a branch name stays MERGED on GitHub forever.
  final bool workspaceMerged;
  final String? url;
  final bool draft;
  final String? mergeable;
  final String reviewDecision;
  final int comments;
  final int additions;
  final int deletions;
  final List<PrCheck> checks;
  final int checksPassed;
  final int checksFailed;
  final int checksPending;

  factory PrStatusResponse.fromJson(Json j) => PrStatusResponse(
    supported: jBool(j, 'supported'),
    exists: jBool(j, 'exists'),
    reason: jStrN(j, 'reason'),
    number: jIntN(j, 'number'),
    title: jStrN(j, 'title'),
    state: jStrN(j, 'state'),
    workspaceMerged: jBool(j, 'workspace_merged'),
    url: jStrN(j, 'url'),
    draft: jBool(j, 'draft'),
    mergeable: jStrN(j, 'mergeable'),
    reviewDecision: jStr(j, 'review_decision'),
    comments: jInt(j, 'comments'),
    additions: jInt(j, 'additions'),
    deletions: jInt(j, 'deletions'),
    checks: jList(j, 'checks', PrCheck.fromJson),
    checksPassed: jInt(j, 'checks_passed'),
    checksFailed: jInt(j, 'checks_failed'),
    checksPending: jInt(j, 'checks_pending'),
  );
}

class MergeResult {
  const MergeResult({
    required this.merged,
    this.method = '',
    this.prUrl,
    this.detail = '',
    this.committed,
  });

  final bool merged;

  /// `local` | `gh`.
  final String method;
  final String? prUrl;
  final String detail;
  final String? committed;

  factory MergeResult.fromJson(Json j) => MergeResult(
    merged: jBool(j, 'merged'),
    method: jStr(j, 'method'),
    prUrl: jStrN(j, 'pr_url'),
    detail: jStr(j, 'detail'),
    committed: jStrN(j, 'committed'),
  );
}

class CommitResult {
  const CommitResult({this.committed, this.nothingToCommit = false});

  final String? committed;
  final bool nothingToCommit;

  factory CommitResult.fromJson(Json j) => CommitResult(
    committed: jStrN(j, 'committed'),
    nothingToCommit: jBool(j, 'nothing_to_commit'),
  );
}

class CreatePrResult {
  const CreatePrResult({
    this.created = false,
    this.alreadyExists = false,
    this.url,
  });

  final bool created;
  final bool alreadyExists;
  final String? url;

  factory CreatePrResult.fromJson(Json j) => CreatePrResult(
    created: jBool(j, 'created'),
    alreadyExists: jBool(j, 'already_exists'),
    url: jStrN(j, 'url'),
  );
}
