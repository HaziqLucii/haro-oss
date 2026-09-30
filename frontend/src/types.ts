// Mirror of the backend's pydantic shapes (the subset the UI consumes).

export interface Project {
  id: string;
  name: string;
  path: string;
  default_branch: string;
  remote_url?: string | null; // `origin` URL if linked to a remote, else null
  stack?: string[]; // tech-stack logo ids (e.g. ["vuejs", "laravel"]) for the sidebar
}

export interface RemoteConfig {
  url: string | null;
  // Browsable base (https://host/owner/repo) derived from `url`; null when
  // local-only or unrecognized. Used to deep-link typed `PR #N` references.
  web_url?: string | null;
}

// Project `[workflow]` ship policy — which ④ ship actions the project offers.
export interface WorkflowConfig {
  merge_mode: "both" | "pr" | "merge";
}

// Project gate config surfaced to the Gate settings tab — the test runner + how the
// auto-gate runs and what can block a green gate.
export interface GateConfig {
  runner: "vitest" | "pytest" | "command" | "offense";
  command: string;
  format: string;
  gate_dir: string;
  default_scope: "all" | "impacted";
  merge_result: boolean;
  flaky_rerun: boolean;
  coverage_guard: "off" | "warn" | "block";
  coverage_tolerance: number;
  // Test-tamper alarm (the green* signal). Defaults ON to "warn"; "block" makes a
  // tampered suite red; "off" skips the check.
  tamper_alarm: "off" | "warn" | "block";
  // Code to check (backlog/code-to-check.md): the diff-level signal. "warn" (default)
  // records rows for the rail pane; "off" skips it. No "block": refusing a merge because
  // a dependency changed is a policy call to make on real counts.
  code_to_check: "off" | "warn";
  // Live Gate (backlog/live-gate.md) — an advisory impacted-only loop off the fs watcher,
  // shown in the rail. OFF by default: it spends CPU on every save. A watch run can never
  // ship anything (see gate.run_watch), so it's a comfort knob, not a policy one.
  watch: boolean;
  // Verified Hunks (backlog/verified-hunks.md): per-line "executed by the green suite"
  // annotation on the ④ ship diff. ON by default — evidence, never a verdict, and it adds no
  // extra test run: it reuses the per-line coverage map the code-to-check pass already
  // measures on a green gate.
  verified_hunks: boolean;
}

// The Live Gate's state for the rail panel (GET /workspaces/{id}/watch). `enabled`
// distinguishes "off" from "on but nothing has run yet" — two different empty states.
// `run` is never a ship verdict: it lives only in the backend's in-memory store, so a
// restart legitimately forgets it (a vital sign describes *now*).
export interface WatchState {
  enabled: boolean;
  run: TestRun | null;
}

// Project agent config surfaced to the Agent settings tab — the default model +
// reasoning effort a run inherits, plus the per-run budget ceiling / cost warning.
export interface AgentConfig {
  default_model: "opus" | "sonnet" | "haiku" | "fable";
  default_effort: "" | "low" | "medium" | "high" | "xhigh" | "max";
  max_budget_usd: number;
  cost_warn_usd: number;
  // How many agent subprocesses may run at once across the whole install (0 = unlimited).
  // Runs over the cap wait server-side as `queued` and start as slots free up.
  max_parallel: number;
  // Agent backend: "claude-code" (cloud CLI) or "local" (Ollama / llama.cpp — no cloud).
  adapter: "claude-code" | "local";
  local_base_url: string;
  local_model: string;
}

// Project `[roles]` workflow-loop config surfaced to the Roles settings tab
// (notes/workflow-roles-plan.md): each step of plan→scout→build→refute gets its
// own model/effort so approving a plan can't silently build at the plan model.
// Each role is its "model:effort" shorthand (e.g. "fable:xhigh", or just "haiku"
// for scout, which carries no effort); "" ⇒ that step falls back to the Agent
// tab's default_model/default_effort. `review`/`scout`/`review_enforce`/
// `review_max_rounds` are parsed today but only acted on from Phase 2/3 onward.
export interface RolesConfig {
  enabled: boolean;
  plan: string;
  build: string;
  review: string;
  scout: string;
  review_enforce: "off" | "warn";
  review_max_rounds: number;
}

// Models installed on a project's configured local server (composer's Local-AI
// model dropdown). `reachable` false ⇒ server down/misconfigured → UI uses a text field.
export interface LocalModelsResponse {
  reachable: boolean;
  models: string[];
  base_url: string;
}

// Project worktree `.env` seed (Environment settings tab). Stored gitignored in
// `.haro/.env` (secrets — never committed); new worktrees are seeded with it.
export interface EnvConfig {
  content: string;
}

// Stack detection (add-project) — sniff the repo, propose a gate/setup preset.
export interface StackPreset {
  id: string;
  label: string;
  blurb: string;
  setup?: string | null;
  run?: string | null;
  gate: Record<string, string>;
  toml: string; // the settings.toml fragment this preset would write, for inspection
}

export interface StackCandidate {
  preset: StackPreset;
  confidence: number; // [0, 1]
}

export interface StackDetection {
  ambiguous: boolean;
  proposal?: StackCandidate | null; // clear winner to auto-fill; null when ambiguous
  candidates: StackCandidate[]; // full ranked list; always includes `custom`
}

// Project backlog — parsed from every backlog doc in the repo (files under the
// `backlog/` folder + any todo-named file). A todo flips to done when an agent's
// branch merges the tick back to main; items are also editable in-app (PUT /todo).
export interface TodoItem {
  kind?: "item"; // discriminant when this appears inside `blocks`
  heading: string | null;
  text: string; // compact prose — checklist display + short branch/workspace name
  body: string; // full item incl. fenced code — the brief seeded to the agent
  done: boolean;
  seed_key?: string; // stable id passed back on create so the item can be marked in-progress
  seeded_workspace?: string | null; // id of a live workspace already started from this item
  // Derived from the seeded workspace's gate/run state (backlog/backlog-v2.md Move 2):
  // "ready" (no workspace) | "queued" | "running" | "red" | "green" | "shipped".
  stage?: string;
}
// A non-task block: headings/prose/context rendered as notes around the items.
export interface TodoNote {
  kind: "note";
  md: string; // raw markdown
}
// The file as an ordered document: notes and `- [ ]` items interleaved in source
// order, so the detail pane renders notes as context with the clickable items among
// them. Discriminate on `kind`.
export type TodoBlock = TodoItem | TodoNote;
// One discovered backlog file → one entry in the Backlog panel.
export interface TodoFile {
  path: string; // repo-relative, e.g. "backlog/gate.md"
  label: string; // tab label (basename, or full path if basenames collide)
  items: TodoItem[]; // seedable tasks only
  blocks: TodoBlock[]; // notes + items in document order (interleaved render)
  content: string; // raw markdown (the in-app editor edits this)
  done: number;
  pending: number;
}
// A workspace whose seed_key no longer matches any current item (edited/removed
// without a one-for-one rename `PUT /todo` could remap) — see backlog-v2.md C5.
export interface OrphanedSeed {
  workspace_id: string;
  seed_key: string;
}
export interface TodoResponse {
  files: TodoFile[];
  orphaned?: OrphanedSeed[];
}

// GitHub issues assigned to the current user — a second backlog tab, read live
// via `gh` (never persisted). Open issues are the queue; closed issues stay
// visible and clickable so a dev can pick a resolved one back up.
export interface IssueItem {
  number: number;
  title: string; // → short branch/workspace name when seeded
  body: string; // → agent brief when seeded
  state: "open" | "closed";
  labels: string[];
  url: string;
  seed_key?: string; // "issue:<number>" — links to a seeded workspace
  seeded_workspace?: string | null; // id of a live workspace started from this issue
  stage?: string; // see TodoItem.stage
}
export interface IssuesResponse {
  available: boolean; // false → empty state (no remote / no gh)
  reason?: string | null; // "no-remote" | "no-gh" | error text
  stale?: boolean; // true → display cache served after a failed refresh
  fetched_at?: string; // ISO stamp of the last successful fetch ("as of HH:MM")
  issues: IssueItem[];
  truncated?: boolean; // true → hit [backlog] issue_limit; more may exist
}

// One comment on an issue, flattened from `gh issue view --json comments`.
export interface IssueComment {
  author: string; // GitHub login of the commenter
  body: string;
  created_at: string; // ISO stamp
}
// Full detail for a single issue, fetched on demand when a backlog row is
// expanded (read-only, never persisted). `available: false` → the panel shows
// the reason inline, same degrade story as the list.
export interface IssueDetailResponse {
  available: boolean;
  reason?: string | null; // "no-remote" | "no-gh" | error text
  number?: number;
  title?: string;
  body?: string;
  state?: "open" | "closed";
  url?: string;
  labels?: string[];
  comments?: IssueComment[];
}

// Directory browser (the "add project" folder picker).
export interface FsEntry {
  name: string;
  path: string;
  is_git_repo: boolean;
}
export interface FsListing {
  root: string;
  path: string;
  parent: string | null;
  is_git_repo: boolean;
  entries: FsEntry[];
}

// Denormalized latest-gate result carried on the workspace for the dashboard glance.
export interface GateSummary {
  status: TestRunStatus;
  total: number;
  passed: number;
  failed: number;
  scope: TestScope;
  error_kind: "setup" | "no_tests" | "runner" | null;
  ended_at: number | null;
  // Tamper-alarm glance fields: how many test-suite-integrity findings the run recorded
  // + the compact reason ("3 removed · 2 skipped"). A green with tamper_count > 0 is the
  // `green*` verdict — here so the dashboard stars it off the status feed alone (no
  // fetch-per-card); the findings themselves stay on the TestRun. backlog/tamper-alarm.md.
  tamper_count: number;
  tamper_note: string | null;
  // Code to check glance count (backlog/code-to-check.md) — the rail badge and dashboard
  // render off this coarse feed with no fetch-per-card; the rows stay on the TestRun.
  // Counts rows STILL AWAITING A LOOK (ticked-off ones are done), and is null when the
  // pass never ran, so a card can't print a confident 0 for a check that did not happen.
  unchecked_count?: number | null;
  // THE DOUBLE GATE's glance state (backlog/double-gate.md §2), so ③ can read
  // `tests ✓ · quality ✓/✗` and the dashboard card can show it off the coarse feed.
  // Tri-state: undefined/null = not measured on this run (gate off, or tests red so it
  // never ran) — deliberately distinct from "clean", because "nobody looked" is not a
  // clean bill of health. `quality_blocking` is the subset that met the severity
  // threshold; only those refuse a ship.
  quality_status?: "clean" | "findings" | null;
  quality_count?: number;
  quality_blocking?: number;
  quality_note?: string | null;
  // The refuter's glance state (Phase 3), same reasoning as quality_status above.
  // undefined/null = not measured this run; the verdict + must-fix list stay on the
  // TestRun.
  review_verdict?: "pass" | "fail" | null;
  review_must_fix?: number;
  review_blocking?: boolean;
  // A check the project asked for could not run (backlog/double-gate.md §0), so this
  // green covers less than it looks like it does. Not shippable.
  degraded?: boolean;
}

// Compact denormalized subset of TrustReport (streak + rung state) carried on the
// workspace for the dashboard's per-card trust meter — same rule as GateSummary. The
// full TrustReport (a superset) rides the status feed and merges in cleanly. `enabled`
// false ⇒ project isn't on the autonomy ladder, so the meter stays hidden.
export interface TrustSummary {
  enabled: boolean;
  streak: number;
  streak_required: number;
  auto_action: "off" | "auto_pr";
  met: boolean;
  armed: boolean;
}

export interface Workspace {
  id: string;
  project_id: string;
  name: string;
  branch: string;
  worktree_path: string;
  base_ref: string;
  port: number | null;
  status: string;
  // Provenance: "managed" = haro created the worktree; "adopted" = a foreign worktree
  // (Claude Code native / claude-squad / bare terminal) registered in place via the
  // Merge Firewall. Adopted workspaces are agentless. backlog/merge-firewall.md.
  kind: "managed" | "adopted";
  // Best-guess tool that created an adopted worktree ("claude-code" | "claude-squad" |
  // "unknown"), stamped at adopt time — drives the "adopted · <source>" badge. Null for
  // managed workspaces. backlog/merge-firewall.md §1.
  source?: string | null;
  gate?: GateSummary | null;
  // Autonomy-ladder glance summary — the dashboard trust meter's source, denormalized
  // like `gate` (no fetch-per-card). backlog/autonomy-ladder.md.
  trust?: TrustSummary | null;
  // PR numbers this workspace's next merge follows up on (set by "Continue on a
  // new branch"); the next PR body reads "Follow-up to #N.".
  prior_prs?: number[];
  last_pr_number?: number | null;
  // Stable id of the backlog item this workspace was seeded from. "issue:<n>" links
  // it to a GitHub issue, which threads "Closes #<n>" into the commit/PR body.
  seed_key?: string;
  // Keys of "code to check" rows the user has ticked off. Lives on the workspace, not the
  // run, so a tick outlives the gate that raised the row — re-asking a question already
  // answered is how a worklist turns into wallpaper. backlog/code-to-check.md.
  checked_rows?: string[];
  // Set when this workspace is one lane of a winner-only fan-out — the join the
  // dashboards use to collapse N sibling cards into ONE race scorecard.
  // backlog/winner-fanout.md.
  race_id?: string | null;
  // The latest PLAN run's final result text (Phase 3 of notes/workflow-roles-plan.md),
  // so the refuter audits the diff against the plan the dev actually approved, not
  // just the one-line task. null for a workspace that never ran a plan turn.
  plan_text?: string | null;
}

// --- Winner-only fan-out (backlog/winner-fanout.md) ------------------------- //
// One prompt, N sibling workspaces, and a deterministic gate-fact ranking — so the
// human reviews exactly one diff plus a scorecard saying why it won. Mirrors
// backend/haro/models.py (RaceLane/RaceRun) and race.py (Ranking).

/** One scorecard cell. `won` = no sibling did better on this axis; `decisive` marks
 *  the single axis the active policy actually ranked on (why it won, not just that
 *  it ticked a box). */
export interface RaceCriterion {
  key: "verdict" | "cost" | "wall" | "coverage" | "merge_clean";
  label: string;
  value: string;
  won: boolean;
  decisive: boolean;
}

/** One ranked lane. `rank` is 1-based among *eligible* lanes and null when the lane
 *  was disqualified; `disqualified` then says why in words. */
export interface RaceLaneScore {
  workspace_id: string;
  name: string;
  model: string;
  effort: string;
  /** "" | "tests_only" | "impl_only" — only set on a `split_authors` race.
   *  Optional: a `race.verdict.lanes` row from the backend's ranking judge never
   *  carries it (see race.py's LaneFacts); only the fallback built from `race.lanes`
   *  does. */
  role?: string;
  status: string;
  rank: number | null;
  eligible: boolean;
  disqualified: string | null;
  criteria: RaceCriterion[];
}

/** The judge's verdict — exactly one of three shapes, and the UI renders all three:
 *  a `winner_id` (review one diff), a `tie` (all green, metric can't separate the top
 *  two — you pick), or `refused` (the suite is too thin to referee with). The refusals
 *  are the feature, not a degraded path. */
export interface RaceVerdict {
  policy: string;
  winner_id: string | null;
  tie: string[];
  refused: string | null;
  reason: string;
  lanes: RaceLaneScore[];
}

/** A lane's cached gate facts. Live workspace state wins while the race runs; this is
 *  what keeps the scorecard readable after the losers are soft-archived. */
export interface RaceLane {
  workspace_id: string;
  name: string;
  branch: string;
  model: string;
  effort: string;
  /** "" (an ordinary ranked lane) | "tests_only" | "impl_only" — only set on a
   *  `split_authors` race (usp-critique-round3.md Move C). */
  role: string;
  status: "pending" | "running" | "green" | "red" | "error" | "stopped";
  green: boolean;
  cost_usd: number;
  wall_ms: number | null;
  coverage_delta: number | null;
  merge_conflict: boolean;
  flaky: string[];
  degraded: boolean;
  tamper_count: number;
  impacted_count: number;
  diff_lines: number;
  archived: boolean;
  note: string | null;
  finished_at: number | null;
}

export interface RaceRun {
  id: string;
  project_id: string;
  task: string;
  policy: string;
  status: "running" | "judged" | "refused" | "stopped" | "failed";
  lanes: RaceLane[];
  winner_id: string | null;
  tie: string[];
  refused: string | null;
  reason: string;
  verdict: RaceVerdict | null;
  max_total_usd: number;
  spent_usd: number;
  losers_archived: boolean;
  losers_purged: boolean;
  created_at: number;
  ended_at: number | null;
}

/** §0's hard gate as a dry run (GET /projects/{id}/race/preflight): may this project
 *  race, and under what ceiling? Never an error response — the refusal IS the payload,
 *  so the composer can disable the button *and say why* before a dollar is spent. */
export interface RacePreflight {
  ok: boolean;
  refusals: string[];
  notes: string[];
  max_total_usd: number;
  lanes: { model: string; effort: string }[];
  policy: string;
  suite_tests: number | null;
}

export interface AgentRun {
  id: string;
  workspace_id: string;
  adapter: string;
  model: string | null;
  task: string;
  // True when this was a Plan-Mode run (agent planned, edited nothing) — lets the
  // stream offer "Approve → implement" and know not to expect a diff/gate for it.
  plan?: boolean;
  // True when this run used Fast Mode ("speed over depth"). Per-run, mutually
  // exclusive with plan in the composer.
  fast?: boolean;
  // Which step of the plan→scout→build→refute loop produced this run ("plan" |
  // "build"); empty when `[roles] enabled` is off. See notes/workflow-roles-plan.md.
  role?: string;
  status: string;
  tokens_in: number;
  tokens_out: number;
  cost_usd: number | null;
}

// "user" is a client-injected turn marker (echoes your prompt into the stream);
// the rest are the normalized agent events the backend emits.
export type AgentEventType = "token" | "tool_call" | "file_edit" | "done" | "error" | "user";

export interface AgentEvent {
  run_id: string;
  workspace_id: string;
  ts: number;
  type: AgentEventType;
  payload: Record<string, any>;
  // Per-workspace turn ordinal, assigned by the backend store (a `user` event opens a
  // new turn; every agent event that follows shares it). The stable anchor a "rewind to
  // here" action targets. Optional: older transcripts persisted before markers existed.
  turn?: number;
}

// A rewindable turn boundary — one per `user` event in the transcript. `kind`
// separates a real user prompt from a platform auto-fix round or a refuter
// review-fix round (Phase 3 of notes/workflow-roles-plan.md) — both dimmed in the UI.
// The GET /workspaces/{id}/turns summary; also derivable client-side (see turns.ts).
export interface TurnMarker {
  turn: number;
  run_id: string;
  ts: number;
  prompt: string;
  kind: "user" | "autofix" | "reviewfix";
}

// Outcome of a "rewind to here": which turn we rewound to, that turn's prompt (to
// prefill the composer), how many transcript events were dropped, and the sha of the
// safety checkpoint commit if one was made (null when the worktree was clean).
export interface RewindResponse {
  turn: number;
  prompt: string;
  dropped: number;
  checkpoint?: string | null;
}

export interface DiffResponse {
  base_ref: string;
  diff: string;
  files_changed: number;
  // Set when this diff is scoped to a single commit (commit-by-commit filter),
  // absent for the full working-vs-base_ref diff.
  commit?: string | null;
}

// AI code review — the verify step's advisory "quality" lane (Bet 7). Findings
// surface beside the test grid and round-trip to the composer as a fix; they never
// block the merge (only a red test gate does).
export type ReviewSeverity = "high" | "medium" | "low" | "nit";
export interface ReviewFinding {
  file: string;
  line: number | null;
  severity: ReviewSeverity;
  category: string;
  title: string;
  detail: string;
}
export interface ReviewResult {
  ran_at: number;
  model: string;
  summary: string;
  findings: ReviewFinding[];
  error: string | null;
}

// Conflict-aware merge queue: only green workspaces are admitted; they land in a
// conflict-safe order, and whatever can't land cleanly is reported blocked. On a project
// that armed [trust] auto_action the queue inherits the autonomy ladder — only
// rung-complete workspaces are admitted, the rest come back "skipped" with the unmet
// trust conditions in `reason` and stay merge-by-hand.
export interface MergeQueueItem {
  workspace_id: string;
  name: string;
  outcome: "merged" | "ready" | "blocked" | "skipped";
  reason: string | null;
  conflicts: string[];
}
export interface MergeQueueResult {
  dry: boolean;
  items: MergeQueueItem[];
}

// Bulk archive (backlog/bulk-archive.md): many workspaces torn down through a serial
// queue — one at a time, each reporting its own outcome. `risks` is what a workspace
// stands to lose (uncommitted edits, unmerged commits, a running agent); those are
// skipped unless the run is `force`d, and the risks stay on the record either way.
export type ArchiveOutcome =
  | "queued"
  | "archiving"
  | "archived"
  | "failed"
  | "skipped"
  | "canceled";

export interface ArchiveQueueItem {
  workspace_id: string;
  name: string;
  outcome: ArchiveOutcome;
  reason: string | null;
  risks: string[];
}

export interface ArchiveQueueRun {
  id: string;
  project_id: string;
  /** A preview: the same shape as the live run, nothing torn down. */
  dry: boolean;
  force: boolean;
  state: "planned" | "running" | "done" | "canceled";
  stop_requested: boolean;
  items: ArchiveQueueItem[];
  created_at: number;
  finished_at: number | null;
}

export type TestCaseStatus = "passed" | "failed" | "skipped";

export interface TestCaseResult {
  file: string;
  name: string;
  status: TestCaseStatus;
  duration_ms: number | null;
  message: string | null;
}

export type TestRunStatus = "running" | "passed" | "failed" | "error";
export type TestScope = "all" | "impacted" | "failed";

// One suspicious change to the test suite that turns a green gate into green*.
// kind: removed | skip | only | todo | assertions | snapshot; file/test locate it;
// detail is the human one-liner (".only added", "3 fewer expect() calls").
// One "code to check" row — mirrors backend `UncheckedRow`. Rows say what was NOT
// observed, never that anything is proven: a line with a hit count was *executed*, which
// is not the same as asserted about. `kind` is one of no_test_file | untested_lines |
// new_dep | secret | deleted | migration | suite_weakened.
export interface UncheckedRow {
  kind: string;
  file: string;
  detail: string;
  count: number;
  /** Stable identity across re-gates (`unchecked.row_key`), and the handle a tick-off is
   *  stored against. It embeds the claim's count, so ticking "23 lines never ran" survives
   *  the next gate but expires the moment there are 24. */
  key: string;
}

export interface TamperFinding {
  kind: string;
  file: string;
  detail: string;
  test: string | null;
}

/** One deterministic quality finding (backlog/double-gate.md §1) — the mirror of
 *  `models.QualityFindingRow`. `blocking` records whether it met the project's
 *  `[quality] severity_threshold`, stored rather than recomputed here so the UI never
 *  re-derives policy the gate already applied. `message` never carries a secret's value. */
export interface QualityFindingRow {
  tool: string;
  severity: "high" | "medium" | "low" | "info";
  file: string;
  line: number | null;
  rule: string;
  message: string;
  blocking: boolean;
}

/** One plan requirement the diff doesn't implement. `cited` is the anti-rationalization
 *  guardrail: the diff line the reviewer is relying on. Uncited gaps are dropped server-side. */
export interface PlanGap {
  item: string;
  why: string;
  cited: string;
}

/** The plan-compliance verdict (backlog/double-gate.md §3). `error` set = the pass could
 *  not run, which degrades the gate rather than reading as compliant. */
export interface PlanComplianceResult {
  ran_at: number;
  model: string;
  compliant: boolean;
  confidence: "high" | "low";
  summary: string;
  gaps: PlanGap[];
  error: string | null;
}

/** One refuter must-fix (Phase 3 of notes/workflow-roles-plan.md), the same
 *  anti-rationalization shape as `PlanGap`: `cited` is the guardrail made data — a
 *  must-fix with no quoted diff line is dropped server-side, never surfaced as if
 *  it were grounded. */
export interface ReviewMustFix {
  file: string;
  line: number | null;
  title: string;
  detail: string;
  cited: string;
}

/** The refuter's verdict on a green gate's diff (Phase 3): plan compliance's
 *  sibling, but auditing correctness/scope-drift with read-only tools to open
 *  files around the diff, rather than "did it implement the task at all" from the
 *  diff text alone. `verdict` is only "fail" when `must_fix` is non-empty
 *  (enforced server-side): a guess with no citation must not block a merge.
 *  `error` set = the pass could not run, which degrades the gate rather than
 *  reading as a clean pass. */
export interface ReviewVerdict {
  ran_at: number;
  model: string;
  verdict: "pass" | "fail";
  summary: string;
  must_fix: ReviewMustFix[];
  notes: string[];
  error: string | null;
}

export interface TestRun {
  id: string;
  workspace_id: string;
  runner: string;
  scope: TestScope;
  // What kicked the run off. "watch" is the Live Gate's advisory loop — such a run never
  // reaches the ribbon, the streak or any merge preflight (backlog/live-gate.md), so it
  // only ever arrives here via the `watch` channel / GET /watch, never the gate's.
  // Optional: runs persisted before the field existed hydrate without it.
  trigger?: "auto" | "manual" | "autofix" | "watch";
  status: TestRunStatus;
  total: number;
  passed: number;
  failed: number;
  skipped: number;
  duration_ms: number | null;
  wall_ms: number | null;
  cases: TestCaseResult[];
  error: string | null;
  // When status === "error", why the gate couldn't run (vs. tests failing).
  error_kind: "setup" | "no_tests" | "runner" | null;
  // Tests that failed then passed on the flaky-aware re-run (suspected-flaky).
  flaky_tests: string[];
  // Coverage guard: line-coverage delta vs base, a note when it tripped, and whether
  // it blocked an otherwise-green gate.
  coverage_delta: number | null;
  coverage_note: string | null;
  coverage_blocked: boolean;
  // Tamper alarm ([workflow] tamper_alarm, warn by default): test-suite-integrity signal on
  // an otherwise-green gate. findings classify how the suite changed vs base (removed/skip/
  // only/todo/assertions/snapshot); note is the compact green* chip line; blocked downgrades
  // green→red only under "block" mode (mirrors the coverage_* trio above).
  tamper_findings: TamperFinding[];
  tamper_note: string | null;
  tamper_blocked: boolean;
  // Code to check ([workflow] code_to_check): the DIFF-level rows for this run. Advisory
  // by construction — there is no `unchecked_blocked` twin, so these can never downgrade a
  // verdict the tests earned. backlog/code-to-check.md.
  // Tri-state, exactly like `quality_findings` below: `undefined`/`null` = the pass never
  // ran (red gate, impacted-only run, crashed engine), `[]` = it ran and found nothing.
  // Never normalize a missing value to `[]` — that is what made the pane render its earned
  // "every changed line ran" over runs that measured no lines at all.
  unchecked_items?: UncheckedRow[] | null;
  unchecked_note?: string | null;
  // How many changed files the coverage half could actually speak about. null/undefined =
  // no per-line map existed; 0 = a map existed but held nothing from this diff (the
  // everyday case for a Python change under a vitest gate); N = N files really were
  // executed. Only N > 0 entitles the pane to the clean state.
  unchecked_covered_files?: number | null;
  // THE DOUBLE GATE ([quality] enabled, off by default): the deterministic quality half —
  // secrets, security patterns and the project's own linter, scoped to the diff.
  // Tri-state and load-bearing: `undefined`/`null` = NOT MEASURED on this run, `[]` =
  // measured clean, non-empty = findings. The autonomy ladder reads exactly this
  // distinction, so never normalize a missing value to `[]`. backlog/double-gate.md §1.
  quality_findings?: QualityFindingRow[] | null;
  quality_note?: string | null;
  quality_blocked?: boolean;
  // Plan compliance — the Double Gate's LLM third (backlog/double-gate.md §3): did the
  // diff actually implement the task it was given? `blocking` is deliberately narrow:
  // only HIGH-confidence non-compliance WITH cited diff lines can refuse a merge, because
  // a model that can't ground its claim is guessing and a guess must not block anyone.
  plan_compliance?: PlanComplianceResult | null;
  // THE REFUTER ([roles] review_enforce, Phase 3, off by default): an independent
  // re-check of the green diff with read-only tools, plan compliance's sibling.
  // Same tri-state discipline: undefined/null = not measured on this run (roles/
  // review off, red tests, quality already blocked). `review_blocked` is structurally
  // always false since 2026-09-17 (`review_enforce = "block"`, the only thing that
  // ever set it, was cut — an LLM verdict never blocks a merge on its own); kept on
  // the type for symmetry with `quality_blocked`.
  review?: ReviewVerdict | null;
  review_blocked?: boolean;
  // Why the run is degraded, one entry per enabled-but-unrunnable check. Empty = healthy.
  degraded_reasons?: string[];
  // Merge-result gate ([gate] merge_result): ran against the worktree merged onto base.
  // merge_conflict = base wouldn't merge cleanly (a red gate); merge_note explains either case.
  merge_conflict: boolean;
  merge_note: string | null;
  started_at: number;
  ended_at: number | null;
}

// A live grid cell — a single test as it streams (running → passed/failed/skipped).
export type CellStatus = "running" | "passed" | "failed" | "skipped";
export interface Cell {
  id: string;
  file: string;
  name: string;
  status: CellStatus;
  duration_ms: number | null;
  message: string | null;
}

// Worktree file tree (the in-app "code" view).
export interface FileNode {
  name: string;
  path: string;
  dir: boolean;
  children?: FileNode[];
}

// Impact Map — the agent's diff → the tests it provably affects.
export interface ChangedFile {
  path: string;
  added: number | null;
  removed: number | null;
}
export interface ImpactTest {
  file: string;
  name: string;
}
export interface ImpactResponse {
  base_ref: string;
  supported: boolean;
  error: string | null;
  changed_files: ChangedFile[];
  total_tests: number;
  total_test_files: number;
  impacted_tests: ImpactTest[];
  impacted_files: string[];
}

// Failure → blame — for a red test, the changed lines (vs base) most likely to blame.
export interface BlameHunk {
  file: string;
  line: number | null; // null = file-level fallback (no single changed line matched)
  code: string | null;
}
export interface BlameEntry {
  file: string;
  name: string;
  hunks: BlameHunk[];
}
export interface BlameResponse {
  base_ref: string;
  supported: boolean;
  error: string | null;
  entries: BlameEntry[];
}

// Verified Hunks (backlog/verified-hunks.md) — what the last green gate can say about one
// file's added lines. Mirrors backend `VerifiedFile`.
//
// The vocabulary is load-bearing: `executed` never means verified, proven or correct. A line
// ran under a passing suite; whether any assertion checked it is a different question this
// data cannot answer. `lines` is keyed by line number as a string (JSON), and a `null` value
// means the line is NOT COVERABLE (blank, comment, closing brace) — counted in
// `noncoverable`, never as untested. Empty `lines` means no per-line claim is available:
// either the file moved since the gate ran (`stale`) or nothing imports it (`in_map` false).
export interface VerifiedFile {
  path: string;
  in_map: boolean;
  stale: boolean;
  added: number;
  executed: number;
  unexecuted: number;
  noncoverable: number;
  lines: Record<string, number | null>;
}

export interface VerifiedHunksResponse {
  base_ref: string;
  gate_sha: string | null;
  supported: boolean;
  stale: boolean;
  files: VerifiedFile[];
  note: string | null;
}

// Mutation score (backlog/mutation-gate.md) — the "would the tests notice if the code were
// wrong?" test. A survivor is one injected fault the green suite still passed: evidence the
// tests are weak exactly there, NEVER a verdict (there is no `mutation_blocked`). Mirrors
// backend `MutationSurvivor` / `MutationResponse`. `score` = killed / (killed+survived) as a
// percent, null when nothing was scored. `supported=false` + `note` is the honest cannot-say.
export interface MutationSurvivor {
  path: string;
  line: number;
  operator: string;
}

export interface MutationResponse {
  base_ref: string;
  gate_sha: string | null;
  supported: boolean;
  score: number | null;
  killed: number;
  survived: number;
  skipped: number;
  total_mutants: number;
  budget_capped: boolean;
  survivors: MutationSurvivor[];
  note: string | null;
}

// Gate Receipt (usp-critique-plan.md idea 1) — the exportable evidence packet for the
// ④ ship step: what a reviewer reads instead of the diff. Mirrors backend `Receipt` /
// `ReceiptResponse`. Assembled from facts the gate already computed — fetching it never
// runs a test, a mutation pass, or a gh call.
export interface ReceiptSuite {
  runner: string;
  scope: string;
  total: number;
  passed: number;
  failed: number;
  skipped: number;
  impacted_count: number | null;
}

export interface ReceiptTamper {
  measured: boolean;
  clean: boolean;
  findings_count: number;
  note: string | null;
}

// Plan compliance (backlog/double-gate.md §3) — the Double Gate's LLM third, a SEPARATE
// check from the deterministic scanners that runs independently of `[quality] enabled`
// and can set `ReceiptQuality.blocked` on its own. Without this the exported receipt
// could show "Quality scan: not measured" over a blocked verdict with no stated cause.
export interface ReceiptPlanCompliance {
  ran: boolean;
  error: string | null;
  compliant: boolean;
  confidence: string | null;
  summary: string | null;
  gaps: number;
  // Meets the bar to block (high-confidence, cited) — NOT the same as actually having
  // blocked. Never display alone as "BLOCKING": under plan_compliance="warn" this can
  // be true on a GREEN run. Pair with `enforced`.
  blocking: boolean;
  // Whether [quality] plan_compliance = "block" was the active mode for this run.
  enforced: boolean;
}

export interface ReceiptQuality {
  measured: boolean;
  // Mode-agnostic: true whenever a finding meets the blocking severity threshold,
  // NOT only under [quality] enforce = "block". Under "warn" the automated verdict
  // can stay green while a blocking finding still refuses a merge (ship_preflight) —
  // this (and the receipt's overall verdict) reflect that stricter, actual check.
  blocked: boolean;
  findings_count: number;
  blocking_count: number;
  note: string | null;
  plan_compliance: ReceiptPlanCompliance;
}

// The refuter (Phase 3): plan compliance's sibling, but a top-level field (not
// nested under `quality`) since it's gated on `[roles]` and runs independently of
// `[quality] enabled` entirely. Same `blocking AND enforced` split as
// ReceiptPlanCompliance — `blocking` alone can be true on a WARN-mode run that
// stayed green.
export interface ReceiptReview {
  ran: boolean;
  error: string | null;
  verdict: "pass" | "fail";
  summary: string | null;
  must_fix: number;
  blocking: boolean;
  enforced: boolean;
}

export interface ReceiptVerifiedHunks {
  supported: boolean;
  percentage: number | null;
  untested_files: string[];
  note: string | null;
}

export interface ReceiptMutation {
  supported: boolean;
  ran: boolean;
  stale: boolean;
  score: number | null;
  survivors: MutationSurvivor[];
  note: string | null;
}

export interface ReceiptAgent {
  model: string | null;
  effort: string | null;
  cost_usd: number | null;
}

export interface Receipt {
  workspace_id: string;
  branch: string;
  base_ref: string;
  verdict: "green" | "red" | "degraded" | "none";
  gate_sha: string | null;
  degraded_reasons: string[];
  suite: ReceiptSuite;
  tamper: ReceiptTamper;
  quality: ReceiptQuality;
  review: ReceiptReview;
  verified_hunks: ReceiptVerifiedHunks;
  mutation: ReceiptMutation;
  agent: ReceiptAgent;
  generated_at: number;
}

export interface ReceiptResponse {
  receipt: Receipt;
  markdown: string;
}

// Coverage delta (v1.2) — current worktree vs. base_ref baseline.
export interface Coverage {
  lines: number | null;
  statements: number | null;
  functions: number | null;
  branches: number | null;
}
export interface CoverageResponse {
  supported: boolean;
  base_ref: string;
  current: Coverage | null;
  baseline: Coverage | null;
  delta: Partial<Coverage> | null;
  note: string | null;
}

// Flaky detector (v1.2) — re-run N times, flag pass/fail flips.
export interface FlakyTest {
  file: string;
  name: string;
  passed: number;
  failed: number;
}
export interface FlakyResponse {
  runs: number;
  checked: number;
  flaky: FlakyTest[];
  stable: boolean;
}

// Autonomy-ladder trust report (GET /workspaces/{id}/trust, backlog/autonomy-ladder.md).
// A deterministic conjunction of gate facts — no scores, no percentages: each condition
// is individually displayable as met/unmet with a `detail` that explains the state.
// Deep-link target for an unmet condition's fix (backend sets it on the branch that
// knows the reason): open the Gate settings tab (a guard is off), re-run the full
// suite (a fast impacted gate ran), eye the regression ribbon (streak short), or land on
// the green* findings chip (the suite was weakened — its "restore weakened tests →
// agent" action is the fix).
export type TrustFix = "gate_settings" | "run_full" | "ribbon" | "tamper";
export interface TrustCondition {
  key: string;
  met: boolean;
  detail: string;
  // required=false ⇒ shown but dropped from the AND (a `require_<key> = false` in [trust]).
  required: boolean;
  // Set only on an unmet row whose fix is a config toggle / action, not code; null ⇒
  // the fix is to write tests / de-flake / ship the feature (no in-app deep-link).
  fix?: TrustFix | null;
}
export interface TrustReport {
  enabled: boolean;
  conditions: TrustCondition[];
  streak: number;
  streak_required: number;
  auto_action: "off" | "auto_pr";
  met: boolean; // all REQUIRED conditions hold — the conjunction the ladder gates on
  armed: boolean; // met + enabled + auto_action fireable
}

// A pending review comment (v1.3) that will round-trip to the agent.
export interface ReviewComment {
  id: string;
  target: string; // e.g. "src/math.js" or 'test: multiplies two numbers'
  context: string | null; // the diff line or failing-test error, for the agent
  text: string; // the user's instruction
}

// Git & PR panel (#3).
export interface GitFileStatus {
  path: string;
  index: string; // staged change word, e.g. "modified"
  work: string; // unstaged change word
  staged: boolean;
}
export interface GitStatusResponse {
  branch: string;
  base_ref: string;
  ahead: number;
  behind: number;
  dirty: number;
  files: GitFileStatus[];
  merge_mode: "both" | "pr" | "merge"; // which ship actions to offer
  // The workspace has no worktree on disk (archived/merged, or removed out of band), so
  // git could not be consulted. Distinguishes "unknown" from a measured zero: without
  // it, ahead/behind/dirty all read 0, which looks exactly like a clean branch.
  worktree_missing?: boolean;
}
export interface GitCommit {
  sha: string;
  short: string;
  author: string;
  when: string;
  subject: string;
  own: boolean;
}
export interface PrCheck {
  name: string;
  bucket: "pass" | "fail" | "pending";
  url: string;
}
export interface PrStatusResponse {
  supported: boolean;
  exists: boolean;
  reason: string | null;
  number: number | null;
  title: string | null;
  state: string | null;
  // Server-reconciled merged verdict for the workspace (head_sha-aware). Read this,
  // not `state === "MERGED"` — a branch name stays MERGED on GitHub forever.
  workspace_merged: boolean;
  url: string | null;
  draft: boolean;
  mergeable: string | null;
  review_decision: string;
  comments: number;
  additions: number;
  deletions: number;
  checks: PrCheck[];
  checks_passed: number;
  checks_failed: number;
  checks_pending: number;
}

export interface MergeResult {
  merged: boolean;
  method: string; // "local" | "gh"
  pr_url: string | null;
  detail: string;
  committed: string | null;
}

// Project [scripts] config, edited in the in-app Runbook editor.
// One named run command shown in the workspace Run menu. `running`/`url` are the
// live process state (populated only by the per-workspace scripts endpoint).
export interface RunScriptInfo {
  id: string;
  command: string;
  default: boolean;
  icon: string | null;
  running: boolean;
  url: string | null;
}

export interface ScriptsConfig {
  setup: string | null;
  run: string | null; // the DEFAULT run command (back-compat)
  runs?: RunScriptInfo[]; // all named runs (web/worker/test); read-only display data

  archive: string | null;
  run_mode: string;
  login_shell: boolean;
}

// Custom instructions (Tier-1): a standing prompt appended to every agent run in
// the project. `shared` is committed (team); `local` is personal (gitignored).
export interface InstructionsConfig {
  shared: string;
  local: string;
}

// Setup ("deps") state — drives the gate chip; ok = deps ready, so a red gate
// from missing deps is diagnosable at a glance.
export interface SetupState {
  status: "running" | "ok" | "failed" | "unknown";
  exit: number | null;
  note: string | null;
}

// The multiplexed WebSocket carries channel-tagged envelopes.
export type WSMessage =
  // `session_id` tags which agent session the event belongs to, so the UI routes
  // concurrent streams to the right switcher tab. Absent ⇒ the primary session ("main").
  | { channel: "agent"; event: AgentEvent; session_id?: string }
  | { channel: "test"; kind: "run_started" }
  | { channel: "test"; kind: "cell"; cell: Cell }
  | { channel: "test"; kind: "snapshot"; test: TestRun }
  // The Live Gate's advisory stream (backlog/live-gate.md). Same envelope shape as `test`
  // on a deliberately separate channel: a watch run is impacted-only and can never make
  // work mergeable, so its cells must never land in the state the authoritative grid and
  // the merge preflights read.
  | { channel: "watch"; kind: "run_started" }
  | { channel: "watch"; kind: "cell"; cell: Cell }
  | { channel: "watch"; kind: "snapshot"; test: TestRun }
  | {
      channel: "status";
      workspace_id: string;
      status?: string;
      setup?: SetupState;
      gate?: GateSummary | null;
      // Piggybacked on a gate-completion status publish so the ④-ship checklist
      // refreshes without a fetch (backlog/autonomy-ladder.md).
      trust?: TrustReport;
    }
  | {
      channel: "run";
      run_id?: string; // which named run this message is about (default "app")
      running?: boolean;
      url?: string | null;
      exit?: number | null;
      error?: string | null;
      line?: string; // a dev-server log line (Dev log tab)
    }
  // The backend fs watcher saw a change in this worktree → reload the code tree.
  | { channel: "fs"; kind: "changed"; workspace_id: string }
  // Coarse signals riding the global feed.
  | {
      channel: "notify";
      kind: "agent_done";
      workspace_id: string;
      workspace_name?: string;
      status?: string; // "done" | "error"
    }
  | {
      channel: "notify";
      kind: "cost_warning";
      workspace_id: string;
      workspace_name?: string;
      total_usd: number;
      threshold_usd: number;
    }
  // The test gate resolved for a workspace → OS desktop notification when unfocused.
  | {
      channel: "notify";
      kind: "gate_green" | "gate_red";
      workspace_id: string;
      workspace_name?: string;
      // Agentless adopted worktrees beep on the gate flip (their completion moment),
      // since they never emit `agent_done`; managed ones already beeped there.
      workspace_kind?: "managed" | "adopted";
      passed: number;
      failed: number;
      total: number;
    }
  // An autonomy-ladder rung acted on a green gate (backlog/autonomy-ladder.md §3).
  // An automatic ship is never silent: `fired` happened, `held` was refused by a ship
  // preflight (almost always "commit your changes first"), `failed` errored on the way.
  | {
      channel: "notify";
      kind: "rung";
      workspace_id: string;
      workspace_name?: string;
      action: "auto_pr";
      state: "fired" | "held" | "failed";
      detail: string;
      pr_url?: string | null;
      streak: number;
    }
  // A committed todo-*.md file changed (e.g. after a `git pull`) → refetch backlog.
  | { channel: "notify"; kind: "backlog_changed"; project_id: string }
  // Winner-only fan-out lifecycle (backlog/winner-fanout.md §1). Project-scoped, not
  // workspace-scoped, so the dashboard can group the siblings under one race card. The
  // whole RaceRun rides the event — same denormalize-onto-the-feed rule as GateSummary,
  // so a card renders with no fetch-per-race.
  | {
      channel: "notify";
      kind: "race_started" | "race_lane" | "race_budget" | "race_done"
        | "race_archived" | "race_purged";
      project_id: string;
      race_id: string;
      detail?: string;
      race: RaceRun;
    };

/** Desktop self-update state (GET /update/status). The installed app is a frozen
 *  snapshot; `available` = the local source has moved past the running build. */
export interface UpdateStatus {
  supported: boolean; // false on a dev/run.sh run (no build stamp)
  available: boolean;
  pending: boolean; // a manual apply is queued to run once idle
  buildSha: string;
  headSha: string;
  busy: boolean; // agents/gates running — a restart would interrupt them
  busyReason: string | null;
  mode: "manual" | "auto";
}

// A coarse rebuild milestone from GET /update/progress (null when no rebuild is in
// flight). pct is 0–100; label names the current step ("Freezing backend", …).
export interface UpdateProgress {
  pct: number;
  label: string;
}

/** One rate-limit window from GET /usage (mirrors Claude Desktop's Usage view).
 *  `severity` drives the bar color: normal → accent, warning → amber, else red. */
export interface UsageLimit {
  kind: string; // "session" | "weekly_all" | "weekly_scoped" | …
  group: string; // "session" | "weekly"
  label: string; // human label, e.g. "Weekly (Fable)"
  percent: number | null;
  severity: string; // "normal" | "warning" | "critical" | …
  resets_at: string | null; // ISO8601 — the UI renders a live countdown
  is_active: boolean; // the window currently governing throttling
}

/** Extra-usage credits ("usage credits cover you past your plan limits"). */
export interface UsageSpend {
  percent: number | null;
  severity: string;
  used_label: string | null; // "$70.06"
  limit_label: string | null; // "$100.00"
  disclaimer: string | null;
}

export interface UsageAccount {
  name: string | null;
  email: string | null;
  org: string | null;
  plan: string | null; // e.g. "Claude Max 5×"
}

/** Merge Firewall posture. `off` disarms (removes our hooks); `warn` installs
 *  fail-open; `block` installs fail-closed. backlog/merge-firewall.md §3. */
export type FirewallPosture = "off" | "warn" | "block";

/** Outcome of arming/disarming the Merge Firewall (POST/DELETE
 *  /projects/{id}/firewall). `hooks` are the hook paths written, or removed on
 *  disarm. backlog/merge-firewall.md §3. */
export interface FirewallResult {
  firewall: string;
  strict: boolean;
  hooks: string[];
  config_path: string;
}

/** GET /usage. `available:false` carries a `reason` the UI turns into guidance
 *  (no_credentials | token_expired | fetch_failed). */
export interface UsageResponse {
  available: boolean;
  reason?: string;
  detail?: string;
  fetched_at?: number;
  account?: UsageAccount;
  limits?: UsageLimit[];
  spend?: UsageSpend | null;
}
