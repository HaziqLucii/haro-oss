import 'json_util.dart';

/// One checklist line of a manual-rail plan.
class PlanStep {
  const PlanStep({required this.text, this.done = false});

  final String text;
  final bool done;

  PlanStep copyWith({String? text, bool? done}) =>
      PlanStep(text: text ?? this.text, done: done ?? this.done);

  factory PlanStep.fromJson(Json j) =>
      PlanStep(text: jStr(j, 'text'), done: jBool(j, 'done'));

  Json toJson() => {'text': text, 'done': done};
}

/// A checklist the read-only assistant wrote for the developer to implement by hand.
/// `saved` is "Finish plan, save to Docs".
class ManualPlan {
  const ManualPlan({
    required this.id,
    this.title = '',
    this.prompt = '',
    this.steps = const [],
    this.why = '',
    this.model,
    this.effort,
    this.costUsd,
    this.createdAt,
    this.saved = false,
    this.guardNote,
    this.blockedCalls = const [],
  });

  final String id;
  final String title;
  final String prompt;
  final List<PlanStep> steps;
  final String why;
  final String? model;
  final String? effort;
  final double? costUsd;
  final double? createdAt;
  final bool saved;

  /// Set when haro could not check the files during the run (a gate or dev server was
  /// writing). "AI edits: 0" is then unverified, and the plan says so.
  final String? guardNote;

  /// Tools the run tried and does not have, edits included. Nothing was written.
  final List<String> blockedCalls;

  int get doneCount => steps.where((s) => s.done).length;

  ManualPlan copyWith({String? title, List<PlanStep>? steps, bool? saved}) =>
      ManualPlan(
        id: id,
        title: title ?? this.title,
        prompt: prompt,
        steps: steps ?? this.steps,
        why: why,
        model: model,
        effort: effort,
        costUsd: costUsd,
        createdAt: createdAt,
        saved: saved ?? this.saved,
        guardNote: guardNote,
        blockedCalls: blockedCalls,
      );

  factory ManualPlan.fromJson(Json j) => ManualPlan(
    id: jStr(j, 'id'),
    title: jStr(j, 'title'),
    prompt: jStr(j, 'prompt'),
    steps: jList(j, 'steps', PlanStep.fromJson),
    why: jStr(j, 'why'),
    model: jStrN(j, 'model'),
    effort: jStrN(j, 'effort'),
    costUsd: jDoubleN(j, 'cost_usd'),
    createdAt: jDoubleN(j, 'created_at'),
    saved: jBool(j, 'saved'),
    guardNote: jStrN(j, 'guard_note'),
    blockedCalls: jStrList(j, 'blocked_calls'),
  );
}

/// One pointer from a research call. `action`: `open` (a link, in the browser), `jump`
/// (`path[:line]`, in the editor), `read` (a man page, in Docs).
class ResearchRow {
  const ResearchRow({
    required this.source,
    required this.title,
    required this.target,
    this.why = '',
    this.action = 'open',
  });

  /// `repo` | `git` | `man` | `web` | `doc`.
  final String source;
  final String title;
  final String target;
  final String why;
  final String action;

  factory ResearchRow.fromJson(Json j) => ResearchRow(
    source: jStr(j, 'source'),
    title: jStr(j, 'title'),
    target: jStr(j, 'target'),
    why: jStr(j, 'why'),
    action: jStr(j, 'action', 'open'),
  );
}

/// A past `ask` on a workspace that kept its answer (the newest ten): the Search tab's
/// "Recent" list. [at] is epoch seconds.
class RecentAsk {
  const RecentAsk({
    required this.query,
    required this.answer,
    this.at,
    this.rows = const [],
    this.note,
    this.guardNote,
    this.blockedCalls = const [],
  });

  final String query;
  final String answer;
  final double? at;
  final List<ResearchRow> rows;
  final String? note;
  final String? guardNote;
  final List<String> blockedCalls;

  factory RecentAsk.fromJson(Json j) => RecentAsk(
    query: jStr(j, 'query'),
    answer: jStr(j, 'answer'),
    at: jDoubleN(j, 'at'),
    rows: jList(j, 'rows', ResearchRow.fromJson),
    note: jStrN(j, 'note'),
    guardNote: jStrN(j, 'guard_note'),
    blockedCalls: jStrList(j, 'blocked_calls'),
  );

  /// The `ask` entries of a workspace's `research_log` that carry an answer, newest first.
  static List<RecentAsk> fromLog(Json log) {
    final raw = log['entries'];
    if (raw is! List) return const [];
    final out = <RecentAsk>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final j = asJson(e);
      if (jStr(j, 'scope') != 'ask' || jStrN(j, 'answer') == null) continue;
      out.add(RecentAsk.fromJson(j));
    }
    return out.reversed.toList();
  }
}

/// `POST /assist/research`. Non-AI scopes fill [rows]; `ask` returns [jobId] and its answer
/// arrives on the `assist` channel.
class ResearchResponse {
  const ResearchResponse({
    required this.scope,
    required this.query,
    this.answer,
    this.rows = const [],
    this.note,
    this.jobId,
  });

  final String scope;
  final String query;
  final String? answer;
  final List<ResearchRow> rows;
  final String? note;
  final String? jobId;

  factory ResearchResponse.fromJson(Json j) => ResearchResponse(
    scope: jStr(j, 'scope'),
    query: jStr(j, 'query'),
    answer: jStrN(j, 'answer'),
    rows: jList(j, 'rows', ResearchRow.fromJson),
    note: jStrN(j, 'note'),
    jobId: jStrN(j, 'job_id'),
  );
}

/// The latest assist run, as `POST /assist/plan` and `GET /assist` return it.
class AssistJob {
  const AssistJob({
    required this.id,
    required this.kind,
    this.status = 'running',
    this.query = '',
    this.text = '',
    this.error,
    this.planId,
    this.answer,
    this.rows = const [],
    this.blockedCalls = const [],
    this.guardNote,
    this.note,
  });

  final String id;

  /// `plan` | `research`.
  final String kind;

  /// `queued` | `running` | `done` | `error` | `stopped`.
  final String status;
  final String query;

  /// What the run has streamed so far (code fences already removed).
  final String text;
  final String? error;

  /// A finished plan job: the plan it stored on the workspace.
  final String? planId;

  /// A finished `ask` job: the short answer and its checked pointers.
  final String? answer;
  final List<ResearchRow> rows;

  /// Tools the run tried and does not have, so far.
  final List<String> blockedCalls;
  final String? guardNote;

  /// A finished `ask`: how many of its sources were dropped for pointing at nothing.
  final String? note;

  bool get active => status == 'running' || status == 'queued';

  factory AssistJob.fromJson(Json j) => AssistJob(
    id: jStr(j, 'id'),
    kind: jStr(j, 'kind'),
    status: jStr(j, 'status', 'running'),
    query: jStr(j, 'query'),
    text: jStr(j, 'text'),
    error: jStrN(j, 'error'),
    planId: jStrN(j, 'plan_id'),
    answer: jStrN(j, 'answer'),
    rows: jList(j, 'rows', ResearchRow.fromJson),
    blockedCalls: jStrList(j, 'blocked_calls'),
    guardNote: jStrN(j, 'guard_note'),
    note: jStrN(j, 'note'),
  );
}

class PinnedDoc {
  const PinnedDoc({required this.title, required this.url});

  final String title;
  final String url;

  factory PinnedDoc.fromJson(Json j) =>
      PinnedDoc(title: jStr(j, 'title'), url: jStr(j, 'url'));

  Json toJson() => {'title': title, 'url': url};
}

class ManPage {
  const ManPage({
    required this.page,
    required this.text,
    this.truncated = false,
  });

  final String page;
  final String text;
  final bool truncated;

  factory ManPage.fromJson(Json j) => ManPage(
    page: jStr(j, 'page'),
    text: jStr(j, 'text'),
    truncated: jBool(j, 'truncated'),
  );
}

/// Saved plans and lookups on the ship receipt. `aiEdits` is a fixed 0 from the backend.
class ReceiptPlan {
  const ReceiptPlan({
    this.plans = 0,
    this.steps = 0,
    this.done = 0,
    this.aiEdits = 0,
    this.unverified = false,
  });

  final int plans;
  final int steps;
  final int done;
  final int aiEdits;

  /// A saved plan's run could not be checked, so `aiEdits` is not a claim.
  final bool unverified;

  factory ReceiptPlan.fromJson(Json j) => ReceiptPlan(
    plans: jInt(j, 'plans'),
    steps: jInt(j, 'steps'),
    done: jInt(j, 'done'),
    aiEdits: jInt(j, 'ai_edits'),
    unverified: jBool(j, 'unverified'),
  );
}
