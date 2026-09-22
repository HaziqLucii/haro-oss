"""Core data model for haro (v0).

Mirrors the "first pass" data model in notes/product-spec.md. v0 keeps everything
in memory (see store.py) — no database yet — but the shapes here are the same ones
we'll persist later, so the API contract is stable from day one.
"""

from __future__ import annotations

import time
import uuid
from enum import Enum
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field


def _id(prefix: str) -> str:
    """Short, human-scannable ids like ``ws_1a2b3c4d`` (nice in logs and URLs)."""
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


def _now() -> float:
    return time.time()


# --------------------------------------------------------------------------- #
# Enums
# --------------------------------------------------------------------------- #
class WorkspaceStatus(str, Enum):
    """Lifecycle of a workspace. v0 only exercises a subset; the gate states
    (gate_green / gate_red) arrive in v1, merged/archived round out the loop."""

    setting_up = "setting_up"
    idle = "idle"
    agent_running = "agent_running"
    tests_running = "tests_running"
    gate_green = "gate_green"
    gate_red = "gate_red"
    merged = "merged"
    archived = "archived"
    #: Worktree desynced from disk — a husk (dir present, ``.git`` gone) whose
    #: branch still has unmerged work. Surfaced as "needs repair" instead of
    #: silently dropped on boot, so the work isn't invisibly abandoned.
    broken = "broken"


class AgentRunStatus(str, Enum):
    #: Accepted by the backend but not spawned yet — it's waiting for the worktree's
    #: setup script to finish, or for a free slot under ``[agent] max_parallel``. The
    #: deferral is BACKEND-owned (see runner.run_agent): the client fires and forgets,
    #: so closing the tab or switching workspace can't strand the run.
    queued = "queued"
    running = "running"
    done = "done"
    error = "error"
    stopped = "stopped"


class TestRunStatus(str, Enum):
    """Outcome of a gate execution. ``passed``/``failed`` drive the merge gate;
    ``error`` means the runner itself couldn't run (deps missing, no tests…)."""

    running = "running"
    passed = "passed"
    failed = "failed"
    error = "error"


# Per-test-case status, normalized across runners (Vitest first).
TestCaseStatus = Literal["passed", "failed", "skipped"]


# The normalized event vocabulary every AgentAdapter must speak. The UI only
# ever knows these five types — never a vendor's raw JSON.
AgentEventType = Literal["token", "tool_call", "file_edit", "done", "error"]


class GateSummary(BaseModel):
    """Denormalized latest-gate result, carried on the Workspace so the multi-agent
    dashboard can show gate detail (green/red + N failing) at a glance, without a
    fetch-per-card. Set whenever a gate run finishes; broadcast on the status feed."""

    status: TestRunStatus
    total: int = 0
    passed: int = 0
    failed: int = 0
    scope: Literal["all", "impacted", "failed"] = "all"
    error_kind: Optional[Literal["setup", "no_tests", "runner"]] = None
    ended_at: Optional[float] = None
    #: Tamper-alarm glance fields (backlog/tamper-alarm.md §3): how many test-suite-
    #: integrity findings the run recorded, plus the compact one-line reason
    #: ("3 removed · 2 skipped"). A *green* with ``tamper_count > 0`` is the ``green*``
    #: verdict — carried here (not just on the ``TestRun``) so the dashboard card and
    #: the "N gates need you" banner can star it live off the coarse status feed,
    #: with no fetch-per-card. The findings themselves stay on the ``TestRun``.
    tamper_count: int = 0
    tamper_note: Optional[str] = None
    #: "Code to check" glance count (backlog/code-to-check.md): how many diff-level rows the
    #: run recorded. Carried here, not only on the ``TestRun``, for the same reason
    #: ``tamper_count`` is — the rail badge and the dashboard card render off the coarse
    #: status feed with no fetch-per-card. The rows themselves stay on the ``TestRun``.
    #:
    #: Counts rows still AWAITING a look, so it matches the pane's badge: a row the user has
    #: ticked off is done, and a glance number that keeps counting finished work is the kind
    #: of badge people switch off. ``None`` = the pass never ran, mirroring
    #: ``TestRun.unchecked_items`` — a dashboard card must not print a confident 0 for a
    #: check that did not happen.
    unchecked_count: Optional[int] = None
    #: Double Gate glance state (backlog/double-gate.md §1). ``quality_status`` is the
    #: tri-state the ③ step renders as ``tests ✓ · quality ✓/✗``: None = not measured on
    #: this run (gate off / red tests), "clean", or "findings". Carried here for the same
    #: reason as ``tamper_count`` — the card and the stepper render off the coarse status
    #: feed with no fetch-per-card. The findings themselves stay on the ``TestRun``.
    quality_status: Optional[Literal["clean", "findings"]] = None
    quality_count: int = 0
    #: How many of those met ``[quality] severity_threshold``. Kept separate from
    #: ``quality_count`` because they answer different questions: the count is what the chip
    #: shows, the blocking count is what refuses a ship. Conflating them would block a merge
    #: on an advisory `low` finding the project deliberately set below its threshold.
    quality_blocking: int = 0
    quality_note: Optional[str] = None
    #: The refuter's glance state (Phase 3 — notes/workflow-roles-plan.md), same
    #: reason as the ``quality_*``/``tamper_count`` fields above: the dashboard card
    #: and the ③ verdict card render off the coarse status feed, no fetch-per-card.
    #: ``None`` = not measured this run (roles/review off, red tests, quality already
    #: blocked); the verdict itself + must-fix list stay on the ``TestRun``.
    review_verdict: Optional[Literal["pass", "fail"]] = None
    review_must_fix: int = 0
    review_blocking: bool = False
    #: True when a check the project asked for couldn't run (backlog/double-gate.md §0).
    #: Carried here for the same reason as `tamper_count`: the dashboard card and the
    #: verdict banner must be able to say "treat this green as unverified" off the coarse
    #: status feed, with no fetch-per-card. The reasons themselves stay on the `TestRun`.
    degraded: bool = False


class TrustSummary(BaseModel):
    """Compact denormalized subset of the autonomy-ladder ``TrustReport`` (streak +
    rung state), carried on the Workspace so the dashboard's per-card trust meter
    renders without a fetch-per-card — exactly the ``GateSummary`` rule. The full
    checklist (every condition + detail) stays behind ``GET /workspaces/{id}/trust``
    and the status broadcast that feeds the ④-ship panel. Set whenever a gate run
    finishes (see ``gate.run_gate``); ``enabled`` false ⇒ project isn't on the ladder,
    so the meter stays hidden. See backlog/autonomy-ladder.md."""

    enabled: bool = False
    streak: int = 0
    streak_required: int = 3
    auto_action: Literal["off", "auto_pr"] = "off"
    met: bool = False
    armed: bool = False


# --------------------------------------------------------------------------- #
# Entities
# --------------------------------------------------------------------------- #
class Project(BaseModel):
    """A registered local git repo."""

    id: str = Field(default_factory=lambda: _id("proj"))
    name: str
    path: str
    default_branch: str
    # `origin` URL if the repo is linked to a remote (else None = local-only). Cached
    # from git so the sidebar can badge linked projects without a git call per row;
    # kept in sync on create + when set via /remote, reconciled from git on boot.
    remote_url: Optional[str] = None
    settings: dict[str, Any] = Field(default_factory=dict)
    # Tech-stack logo ids (e.g. ["vuejs", "laravel"]) for the sidebar row.
    # Detected from the repo's manifests at create time; see presets._LOGO_ORDER.
    stack: list[str] = Field(default_factory=list)
    created_at: float = Field(default_factory=_now)


class Workspace(BaseModel):
    """One task = one git worktree on its own branch."""

    id: str = Field(default_factory=lambda: _id("ws"))
    project_id: str
    name: str
    branch: str
    worktree_path: str
    base_ref: str
    port: Optional[int] = None
    status: WorkspaceStatus = WorkspaceStatus.idle
    #: Provenance of the worktree. ``managed`` = haro created it (``git_ops.add_worktree``
    #: on the create path); ``adopted`` = a foreign worktree (Claude Code native session,
    #: claude-squad, a bare terminal…) haro registered in place via the Merge Firewall's
    #: adopt path — no ``add_worktree``, and agentless (the ① agent step is hidden; code/gate/
    #: ship remain). Defaults to ``managed`` so every pre-firewall row hydrates correctly.
    #: See backlog/merge-firewall.md.
    kind: Literal["managed", "adopted"] = "managed"
    #: Best-guess tool that created an *adopted* worktree, stamped at adopt time from the
    #: path (``_guess_worktree_source``: ``claude-code`` | ``claude-squad`` | ``orphaned``
    #: [a desynced haro worktree the store lost track of] | ``unknown``).
    #: Display-only provenance for the "adopted · <source>" badge — never load-bearing,
    #: and ``None`` for ``managed`` workspaces. See backlog/merge-firewall.md §1.
    source: Optional[str] = None
    #: Claude Code session id of the last run on the workspace's PRIMARY agent session
    #: (``store.DEFAULT_SESSION``) — passed as --resume so the agent keeps its
    #: conversation context (+ auto-compacts) across runs. Kept as the primary session's
    #: resume id (and mirrored into ``session_resume["main"]``) so pre-multi-session rows
    #: hydrate correctly.
    last_session_id: Optional[str] = None
    #: Per-session Claude resume ids — ``session_id`` → last Claude session id, so each
    #: agent session in this workspace ``--resume``\\s its OWN conversation independently
    #: (the switcher's sessions don't cross-contaminate context). The primary session also
    #: lives in ``last_session_id`` above for backward-compat; a session absent here that
    #: is the primary falls back to it. See runner.py ``_drive_agent``.
    session_resume: dict[str, str] = Field(default_factory=dict)
    #: Latest gate result (denormalized for the dashboard glance view). None until
    #: the first gate runs; kept in sync by ``gate.run_gate``.
    gate: Optional[GateSummary] = None
    #: Autonomy-ladder glance summary (streak + rung state), denormalized for the
    #: dashboard's per-card trust meter — same rule as ``gate`` above. None until the
    #: first gate run stamps it; kept in sync by ``gate.run_gate``. backlog/autonomy-ladder.md.
    trust: Optional[TrustSummary] = None
    #: PR numbers of prior branches merged from THIS workspace (via "Continue on a
    #: new branch"). The next merge's PR body references them ("Follow-up to #106").
    prior_prs: list[int] = Field(default_factory=list)
    #: PR number of the most recent merge, pending promotion into ``prior_prs`` when
    #: the user continues on a fresh branch. None once continued or never merged.
    last_pr_number: Optional[int] = None
    #: Stable id of the backlog todo item this workspace was seeded from
    #: (``<todo-file-path>::<item-text>``), or None if created manually. Lets the
    #: backlog mark that item "in progress" so it isn't clicked into a duplicate.
    seed_key: Optional[str] = None
    #: Keys of "code to check" rows the user has ticked off (``unchecked.row_key``).
    #:
    #: This lives on the WORKSPACE, not the run, because a tick outlives the gate that
    #: raised the row: re-gate and the same claim comes back, and re-asking a question
    #: already answered is how a worklist turns into wallpaper. Four of the eight row kinds
    #: (a new dependency, a touched secret file, a deletion, a migration) can only ever be
    #: resolved by a human confirming, so without somewhere to record that confirmation the
    #: pane is structurally unable to reach zero — which is its own documented kill
    #: condition (backlog/code-to-check.md).
    #:
    #: The key embeds the claim's count/detail, so a tick dies the moment the claim changes.
    #: Pruned to the live row set on every gate (``gate.run_gate``) so it cannot grow into a
    #: junk drawer of keys for lines that no longer exist.
    checked_rows: list[str] = Field(default_factory=list)
    #: Id of the ``RaceRun`` this workspace is a lane of (backlog/winner-fanout.md §1).
    #: Deliberately its OWN field rather than an overloaded ``seed_key``: the issue
    #: write-back path *parses* ``seed_key`` (``issue:<n>``), so smuggling a race tag
    #: through it would fire GitHub writes for a lane. ``None`` for every ordinary
    #: workspace, which is also what makes "group the siblings under one race card"
    #: a pure client-side join.
    race_id: Optional[str] = None
    #: The latest PLAN run's final result text (Phase 3 — notes/workflow-roles-plan.md),
    #: so the refuter audits the diff against the plan the dev actually approved, not
    #: just the one-line task. Stamped by ``runner._drive_agent`` on a plan run's
    #: ``done`` (capped, see there); ``None`` for a workspace that never ran a plan turn.
    plan_text: Optional[str] = None
    created_at: float = Field(default_factory=_now)


class AgentRun(BaseModel):
    """One agent session inside a workspace."""

    id: str = Field(default_factory=lambda: _id("run"))
    workspace_id: str
    adapter: str
    model: Optional[str] = None
    effort: Optional[str] = None  # reasoning effort: low|medium|high|xhigh|max
    task: str = ""
    #: True when this was a Plan-Mode run (agent planned, edited nothing). Recorded so
    #: the UI can offer "Approve → implement" on a finished plan and knows not to expect
    #: a diff/gate for it. Only ever set for adapters that support plan mode.
    plan: bool = False
    #: True when this run used Fast Mode ("speed over depth" — Opus + speed="fast").
    #: A per-run toggle, mutually exclusive with plan in the UI. Only set for adapters
    #: that support it (claude-code today).
    fast: bool = False
    #: Which step of the plan→scout→build→refute loop produced this run
    #: (`"plan"` | `"build"`; empty when `[roles] enabled` is off, so the
    #: byte-identical-when-off contract extends to this field too). Stamped by
    #: `start_agent`, never client-supplied directly onto the run itself.
    role: str = ""
    status: AgentRunStatus = AgentRunStatus.running
    tokens_in: int = 0
    tokens_out: int = 0
    cost_usd: Optional[float] = None
    started_at: float = Field(default_factory=_now)
    ended_at: Optional[float] = None


class TestCaseResult(BaseModel):
    """One test case, normalized. ``file`` is repo-relative when we can make it so."""

    file: str
    name: str
    status: TestCaseStatus
    duration_ms: float | None = None
    message: str | None = None  # failure message, present on failed cases
    # Raw failure stack (file:line frames) — not shown directly; the /blame endpoint
    # matches its frames against the diff to point at the changed lines responsible.
    stack: str | None = None


class UncheckedRow(BaseModel):
    """One "code to check" row — the persistable pydantic twin of ``unchecked.UncheckedItem``
    (same dataclass/model split as ``TamperFinding`` vs the ``tamper.py`` engine).

    ``kind`` is one of no_test_file | untested_lines | new_dep | secret | deleted |
    migration | suite_weakened; ``file`` locates it; ``detail`` is the literal one-liner
    ("41 of 52 added lines never ran"); ``count`` carries the number the label needs, 0 when
    the kind is not countable.

    Note the vocabulary: rows say what was **not observed**, never that anything is proven or
    verified. A line with a hit count was *executed*, which is not the same as asserted
    about, and a positive word here would become the metric an agent games.

    ``key`` is the row's stable identity across re-gates (``unchecked.row_key``), and it is
    what makes the pane a worklist rather than a report: it is the handle a tick-off is
    stored against, so "I looked at this" survives the next gate while a claim that has
    *changed* comes back needing a fresh look."""

    kind: str
    file: str
    detail: str = ""
    count: int = 0
    key: str = ""


class QualityFindingRow(BaseModel):
    """One deterministic quality finding — the persistable pydantic twin of the dataclass
    the scanners emit (``adapters/quality/base.QualityFinding``), the same split
    ``TamperFinding`` has from ``tamper.py``.

    ``tool`` is the scanner that found it (gitleaks | semgrep | lint), ``rule`` its
    identifier, ``file``/``line`` locate it for the UI's deep-link, and ``blocking`` records
    whether this particular finding met ``[quality] severity_threshold`` — stored rather
    than recomputed so the UI never has to re-derive policy the gate already applied.

    ``message`` never carries a secret's value: gitleaks runs with ``--redact`` and we keep
    only its description, so a leak detector can't become a leak amplifier."""

    tool: str
    severity: Literal["high", "medium", "low", "info"] = "medium"
    file: str = ""
    line: Optional[int] = None
    rule: str = ""
    message: str = ""
    blocking: bool = False


class PlanGap(BaseModel):
    """One plan item the diff does not implement (backlog/double-gate.md §3).

    ``cited`` is the anti-rationalization guardrail made data: the reviewer must point at
    the diff hunk backing each judgement. A gap it cannot ground in the diff is an
    *opinion*, and opinions do not block merges here — see ``PlanComplianceResult``."""

    item: str
    why: str = ""
    cited: str = ""


class PlanComplianceResult(BaseModel):
    """Did the diff actually implement the task it was given?

    The one question tests structurally cannot answer: a suite can be green, secret-free
    and lint-clean over code that solves a different problem than the one asked for.

    ``confidence`` is load-bearing, not decoration. An LLM asked "is this compliant?" will
    always produce an answer, so the design assumption is that it is sometimes wrong. Only
    a HIGH-confidence non-compliance blocks; low confidence warns. A model that cannot
    cite the diff is telling you it is guessing, and a guess must not refuse a merge.
    """

    ran_at: float
    model: str = ""
    compliant: bool = True
    confidence: Literal["high", "low"] = "low"
    summary: str = ""
    gaps: list[PlanGap] = Field(default_factory=list)
    #: Set when the pass could not run at all (no CLI, empty diff, unparseable output).
    #: Like every other check, "couldn't run" degrades the gate rather than reading clean.
    error: Optional[str] = None

    @property
    def blocking(self) -> bool:
        return bool(self.gaps) and not self.compliant and self.confidence == "high"


class ReviewMustFix(BaseModel):
    """One refuter must-fix (Phase 3 — notes/workflow-roles-plan.md), the same
    anti-rationalization shape as ``PlanGap``: ``cited`` is the guardrail made
    data — a must-fix with no quoted diff line is dropped by
    ``review.parse_refuter_verdict``, never surfaced as if it were grounded."""

    file: str
    line: Optional[int] = None
    title: str
    detail: str = ""
    cited: str = ""


class ReviewVerdict(BaseModel):
    """The refuter's verdict on a green gate's diff (Phase 3 —
    notes/workflow-roles-plan.md): the test gate already proved the suite passes;
    this asks whether the suite *should* have caught something the diff got wrong.
    Plan compliance's sibling — auditing correctness/scope-drift with read-only
    tools to open files around the diff, rather than "did it implement the task
    at all" from the diff text alone.

    ``verdict`` is only ``"fail"`` when ``must_fix`` is non-empty
    (``review.parse_refuter_verdict`` enforces this): a guess with no citation
    must not block a merge — same guardrail as ``PlanComplianceResult.blocking``."""

    ran_at: float
    model: str = ""
    verdict: Literal["pass", "fail"] = "pass"
    summary: str = ""
    must_fix: list[ReviewMustFix] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
    #: Set when the pass could not run at all (no CLI, empty diff, unparseable
    #: output, timeout). Like every other check, "couldn't run" degrades the gate
    #: rather than reading clean.
    error: Optional[str] = None


class TamperFinding(BaseModel):
    """One suspicious change to the test suite that turns a green gate into
    ``green*`` — the persistable pydantic twin of the dataclass emitted by the
    pure-function engine in ``tamper.py`` (same split as ``ReviewFinding`` vs its
    reviewer). ``kind`` is one of removed | skip | only | todo | assertions |
    snapshot | config | vacuous; ``file``/``test`` locate it; ``detail`` is the
    human one-liner (e.g. "``.only`` added", "3 fewer expect() calls")."""

    kind: str
    file: str
    detail: str = ""
    test: Optional[str] = None


class TestRun(BaseModel):
    """One gate execution in a workspace."""

    id: str = Field(default_factory=lambda: _id("test"))
    workspace_id: str
    # Stamped at gate time from the workspace's project, so the run stays attributable
    # to its project after the workspace merges + archives (remove_workspace drops the
    # workspace but leaves its runs). The substrate for the project-level trust streak
    # (backlog/autonomy-ladder.md). Optional so runs persisted before this field existed
    # still hydrate — those legacy rows are re-attributed via the live-workspace join in
    # store.project_test_history.
    project_id: str | None = None
    runner: str
    # "all" full suite · "impacted" diff blast-radius (fast gate) · "failed" a
    # re-run of just the previously-red tests (the tight inner fix loop).
    scope: Literal["all", "impacted", "failed"] = "all"
    # What kicked off this gate run — the trust substrate's "green-first-try" signal
    # (backlog/autonomy-ladder.md). "auto" = the post-agent auto-gate, "manual" = a
    # hand-triggered run (POST /tests), "autofix" = a re-gate inside the auto-fix loop,
    # "watch" = the Live Gate's ADVISORY loop (backlog/live-gate.md).
    # Only non-``autofix``/``watch`` greens count toward the project streak: needing the
    # fix loop isn't a clean pass, and a watch run is an impacted-only advisory signal
    # that never even reaches ``store.tests`` (``gate.run_watch`` records nothing) — the
    # exclusion in ``trust._is_clean_green`` is a second lock on the same door.
    # Stamped by run_gate / run_watch.
    trigger: Literal["auto", "manual", "autofix", "watch"] = "manual"
    status: TestRunStatus = TestRunStatus.running
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    duration_ms: float | None = None  # sum of per-test durations
    wall_ms: float | None = None       # wall-clock time of the whole run
    cases: list[TestCaseResult] = Field(default_factory=list)
    error: str | None = None  # runner-level failure (deps missing, no tests, crash)
    # When ``status == error``, *why* the gate couldn't run — lets the UI frame a
    # "the gate never ran" message (setup/deps to fix) apart from real test failures.
    error_kind: Literal["setup", "no_tests", "runner"] | None = None
    # Tests that failed then *passed* on the flaky-aware confirmation re-run — surfaced
    # as suspected-flaky (amber) and, when they're the only failures, don't block green.
    flaky_tests: list[str] = Field(default_factory=list)
    # Coverage guard (opt-in): line-coverage delta vs base_ref, and a note when a drop
    # tripped the guard. ``coverage_blocked`` downgrades an otherwise-green verdict to red.
    coverage_delta: float | None = None
    coverage_note: str | None = None
    coverage_blocked: bool = False
    # Tamper alarm ([workflow] tamper_alarm, warn by default): the test-suite-integrity
    # signal computed on an otherwise-green gate (see tamper.py). ``tamper_findings``
    # classifies *how* the suite changed vs base_ref (removed/skip/only/todo/assertions/
    # snapshot); ``tamper_note`` is the compact ``green*`` chip line ("3 removed · 2
    # skipped"), None when clean. ``tamper_blocked`` downgrades an otherwise-green verdict
    # to red — only under ``tamper_alarm = "block"`` (warn mode records findings but never
    # blocks), exactly the ``coverage_blocked`` pattern above.
    tamper_findings: list[TamperFinding] = Field(default_factory=list)
    tamper_note: str | None = None
    tamper_blocked: bool = False
    # Whether the alarm actually ran and completed on THIS run — `tamper_findings` alone
    # can't answer this: it's `[]` both when the alarm is off and when it ran clean,
    # exactly the ambiguity `quality_findings`'s tri-state exists to avoid. A consumer
    # (the Gate Receipt, the autonomy ladder's `no_tamper` condition) that reads
    # `tamper_findings == []` as "measured clean" without checking this first would
    # report unmeasured runs as clean.
    #
    # A GENUINE tri-state, not a plain bool: gate.py stamps True/False explicitly
    # whenever the tamper block runs at all (True on full success, False on the
    # base-inventory-unavailable and engine-crash paths); it stays at the default None
    # only for a `TestRun` the block never touched — including every row persisted
    # BEFORE this field existed. `None` must not collapse to `False` (a plain
    # `bool = False` field would do exactly that via pydantic's own default, making any
    # `getattr(..., True)` fallback in a reader dead code) — a consumer that can't tell
    # "we know this wasn't measured" from "we don't know" should treat old data
    # conservatively, not report a specific-but-invented cause for it.
    tamper_measured: bool | None = None
    # Code to check ([workflow] code_to_check, warn by default): the DIFF-level signal
    # (see unchecked.py). Every other guard here is suite-level — did the suite pass, did
    # total coverage drop, was the suite weakened — so none of them can notice that the
    # lines the agent just added were executed by nothing. These rows are that gap:
    # files no test imports, added lines that never ran, plus the deterministic facts a
    # test structurally cannot vouch for (a dependency change, a touched secret file, a
    # deletion, a migration). Advisory only in this pass: there is no ``unchecked_blocked``
    # twin, because blocking a merge on "a dependency changed" is a policy call to make
    # after reading real counts. See backlog/code-to-check.md.
    #
    # TRI-STATE, and it is load-bearing: ``None`` = the pass never ran (a red gate, an
    # impacted-only run, a crashed engine), ``[]`` = it ran and found nothing. Defaulting
    # this to ``[]`` is what let the pane render its earned "nothing to check ✓ · every
    # changed line ran" over runs where not one line had been measured. Same contract
    # ``quality_findings`` carries, for the same reason: unmeasured is never clean.
    unchecked_items: list[UncheckedRow] | None = None
    unchecked_note: str | None = None
    # How many changed files the coverage half actually spoke about (unchecked.covered_files).
    # None = no per-line map at all; 0 = a map existed but contained nothing from this diff
    # (a Python change under a vitest gate); N = N files genuinely executed. Only N > 0
    # entitles the pane to claim every changed line ran, and on this repo's own 125-run
    # history the majority of "clean" panes were the 0 case wearing the N case's clothes.
    unchecked_covered_files: int | None = None
    # THE DOUBLE GATE ([quality] enabled, off by default): the deterministic quality half —
    # secrets, security patterns and the project's own linter, scoped to the diff
    # (see quality.py + adapters/quality/). Denormalized onto the run because that is where
    # every consumer already looks: the autonomy ladder reads gate facts off ``latest_test``
    # (backlog/autonomy-ladder.md §3 registered ``quality`` as a rung condition and has been
    # waiting for exactly this field).
    #
    # The tri-state is the contract, and it is NOT the same shape as ``tamper_findings``:
    #   None  — not measured on this run (gate off, red tests, a partial re-run)
    #   []    — measured and genuinely clean
    #   [...] — findings; blocking ones downgrade the verdict via ``quality_blocked``
    # ``[]`` and ``None`` must never be conflated: "I looked and found nothing" is a very
    # different claim from "nobody looked", and only the first should let a rung arm.
    quality_findings: list[QualityFindingRow] | None = None
    quality_note: str | None = None
    # Whether at least one configured scanner actually produced an answer this run
    # (``QualityReport.ran`` is non-empty) — NOT the same question as
    # ``quality_findings is not None`` above. When every configured scanner is
    # unavailable (missing binary, crash, timeout), ``quality.analyze`` still returns
    # ``findings == []`` (the tri-state's own "measured clean" value) even though
    # nothing was actually scanned; that case is recorded in ``degraded_reasons``, but
    # without this field a consumer reading only the tri-state would report a
    # completely-degraded quality pass as a clean one. Same failure class
    # ``tamper_measured`` exists to prevent, one scanner category over — including the
    # same genuine-tri-state shape: ``None`` (the default) only for a run the quality
    # block never touched, which includes every row persisted BEFORE this field
    # existed. Never collapse ``None`` to ``False`` in a reader; that loses "we don't
    # know" as a distinct state from "we know this specific run wasn't measured".
    quality_measured: bool | None = None
    # PLAN COMPLIANCE ([quality] plan_compliance, off by default) — the Double Gate's LLM
    # third (backlog/double-gate.md §3), run only once tests AND deterministic quality are
    # green because it is the expensive one. Same tri-state discipline: None = not
    # measured on this run. Non-compliance only blocks at HIGH confidence; see
    # PlanComplianceResult.blocking for why a guess must not refuse a merge.
    plan_compliance: PlanComplianceResult | None = None
    # Downgrades an otherwise-green verdict to red, exactly the ``coverage_blocked`` /
    # ``tamper_blocked`` pattern: only findings at or above ``[quality] severity_threshold``
    # under ``[quality] enforce = "block"`` set it, so ``warn`` records without blocking.
    quality_blocked: bool = False
    # THE REFUTER ([roles] review_enforce, off by default — Phase 3 of
    # notes/workflow-roles-plan.md): an independent re-check of the green diff against
    # the task/plan, with read-only tools (Read/Grep/Glob) to open files around the
    # diff rather than judging the diff text alone. Same tri-state discipline as
    # ``plan_compliance``: None = not measured on this run (roles/review off, red
    # tests, quality already blocked). Runs LAST — after plan compliance — because it
    # is the most expensive check and the least structured one.
    review: ReviewVerdict | None = None
    # Structurally always False since 2026-09-17: `review_enforce = "block"` (the only
    # thing that ever set this) was cut — an LLM verdict never blocks a merge on its
    # own. Kept on the model (rather than deleted) for symmetry with `quality_blocked`
    # and because `ship_preflight`/the receipt still read it defensively.
    review_blocked: bool = False
    # DEGRADED (backlog/double-gate.md §0): a check the project ASKED FOR could not run.
    # This exists because the alternative is the worst failure this product can have — a
    # green that means less than it looks like it means. Every entry is a check that was
    # enabled and then silently no-opped: the merge-result prep failed, the coverage guard
    # couldn't measure, the tamper alarm couldn't read the base inventory (whose empty
    # result otherwise reads as "suite intact" and satisfies `trust.no_tamper`), or the
    # code-to-check engine crashed. Empty list = every enabled check actually ran.
    #
    # A degraded run is NOT shippable (`integrate.ship_preflight` refuses it) and cannot be
    # a clean green for the streak. The escape hatch is deliberate and needs no new knob:
    # turn the offending check off, and it is no longer a check you asked for.
    degraded_reasons: list[str] = Field(default_factory=list)
    # `receipt.diff_fingerprint` of the worktree-vs-base_ref diff AT GATE TIME
    # (usp-critique-round3.md Move A). The `Verified-by:` trailer and an
    # `--attest`/`haro verify` statement both need "what did the gate actually
    # measure", not "what does the tree look like right now" — a checkpoint commit
    # or an edit between a green gate and the merge click must not silently make
    # the trailer's digest describe a diff nothing ever gated (refuter round-3
    # found `integrate.py` re-computing this fresh at merge time instead).
    diff_fingerprint: str | None = None
    # Linux-first sandboxing, step 1 (usp-critique-round3.md Move D). Set from
    # `TestResult.sandbox_profile` ONLY when the adapter actually wrapped the
    # run with bwrap — never just because `[gate] sandbox` was on. `None` means
    # "not sandboxed" whether that's because the project didn't ask, the runner
    # doesn't support it yet, or bwrap wasn't installed; `degraded_reasons`
    # (below) is where THAT distinction lives.
    sandbox_profile: str | None = None
    # Merge-result gate ([gate] merge_result): the suite ran against the worktree
    # *merged onto base_ref*, so a green survives a base change that landed after this
    # workspace branched. ``merge_conflict`` = base wouldn't merge cleanly (a red gate,
    # no tests run); ``merge_note`` explains either outcome. Surfaced as a gate note.
    merge_conflict: bool = False
    merge_note: str | None = None
    # v1.2 (Impact Map) — reserved, unused in v1.0.
    changed_files: list[str] = Field(default_factory=list)
    impacted_tests: list[str] = Field(default_factory=list)
    started_at: float = Field(default_factory=_now)
    ended_at: float | None = None


class RaceLane(BaseModel):
    """One lane of a winner-only fan-out: a sibling workspace running the SAME task
    under its own model/effort config, plus the gate facts the judge ranks on.

    This is a **cache of facts**, not a second source of truth — every number here is
    copied off the lane's ``TestRun``/``AgentRun`` when the lane settles, so a race
    stays readable after its workspaces are soft-archived (and, later, as calibration
    data: $/green by model×effort). Live state always wins while the race is running;
    see ``fanout.lane_facts``. backlog/winner-fanout.md §1/§3."""

    workspace_id: str
    name: str = ""
    branch: str = ""
    model: str = ""
    effort: str = ""
    #: "" (ordinary ranked lane) | "tests_only" | "impl_only" — only set on a
    #: ``split_authors`` race (usp-critique-round3.md Move C). Not a ranking input:
    #: ``fanout.judge_race`` reads it to route the race around ``race.judge`` entirely.
    role: str = ""
    #: pending | running | green | red | error | stopped (``stopped`` = the race-level
    #: budget ceiling cut this lane short).
    status: str = "pending"
    green: bool = False
    cost_usd: float = 0.0
    wall_ms: Optional[float] = None
    coverage_delta: Optional[float] = None
    merge_conflict: bool = False
    flaky: list[str] = Field(default_factory=list)
    degraded: bool = False
    tamper_count: int = 0
    #: Tests the lane's diff provably touches (``analyze_impact``) — the judge-time
    #: thin-suite guard's input. Also mirrored onto the lane's ``TestRun.impacted_tests``.
    impacted_count: int = 0
    diff_lines: int = 0
    #: Set when this lane lost and its worktree was soft-archived: the row + transcript
    #: + branch survive, only the checkout is gone. See ``fanout.soft_archive_lane``.
    archived: bool = False
    note: Optional[str] = None
    finished_at: Optional[float] = None


class RaceRun(BaseModel):
    """One winner-only fan-out: N sibling workspaces, one prompt, one verdict.

    ``verdict`` holds the serialized ``race.Ranking`` (winner + per-lane scorecard +
    the honest-tie / refused shapes). It is stored rather than recomputed so the
    scorecard a human acted on is the one the record keeps — a re-judge after the
    losers were purged would silently produce a different story.

    Persisted like every other entity (a JSON blob keyed by id, see ``db.py``) because
    §3 wants every race outcome kept as model-calibration data: races double as
    measurements of what a model×effort actually costs per green."""

    id: str = Field(default_factory=lambda: _id("race"))
    project_id: str
    task: str = ""
    policy: str = "cheapest_green"
    #: running | judged | refused | stopped | failed. ``refused`` = the judge declined
    #: to rank (thin suite); ``stopped`` = the budget ceiling ended it early.
    status: str = "running"
    lanes: list[RaceLane] = Field(default_factory=list)
    winner_id: Optional[str] = None
    #: Workspace ids presented side-by-side on an honest tie (never a fabricated winner).
    tie: list[str] = Field(default_factory=list)
    #: Why the judge declined to rank, when it did.
    refused: Optional[str] = None
    reason: str = ""
    #: Serialized ``race.Ranking`` — the scorecard.
    verdict: Optional[dict[str, Any]] = None
    #: The race-level dollar ceiling in force, and what the lanes actually spent.
    max_total_usd: float = 0.0
    spent_usd: float = 0.0
    #: True once the loser worktrees have been soft-archived (the ceremony ran).
    losers_archived: bool = False
    #: True once the human explicitly purged the loser branches — the point of no
    #: second-guessing, which is why it's an action rather than part of the ceremony.
    losers_purged: bool = False
    created_at: float = Field(default_factory=_now)
    ended_at: Optional[float] = None


class AgentEvent(BaseModel):
    """Normalized stream item broadcast over the WebSocket.

    ``type`` is one of the five AgentEventType values; ``payload`` carries the
    type-specific fields (e.g. ``{"text": ...}`` for token, ``{"tool": ...,
    "path": ...}`` for file_edit). Keeping payload loose lets adapters attach
    richer detail without churning the schema.
    """

    run_id: str
    workspace_id: str
    ts: float = Field(default_factory=_now)
    type: AgentEventType
    payload: dict[str, Any] = Field(default_factory=dict)
    #: Per-workspace turn ordinal, assigned by ``Store.append_event`` (NOT the adapter)
    #: — a ``user`` event opens a new turn, every agent event that follows shares it.
    #: The stable anchor a "rewind to here" action targets. ``None`` until the store
    #: tags it on append.
    turn: Optional[int] = None


# --------------------------------------------------------------------------- #
# API request/response shapes
# --------------------------------------------------------------------------- #
class CreateProjectRequest(BaseModel):
    path: str
    name: Optional[str] = None
    # When the path isn't a git repo yet: run `git init` (with an initial commit)
    # instead of refusing. Optionally link a remote in the same step (paste a URL).
    init: bool = False
    remote_url: Optional[str] = None


class StackPreset(BaseModel):
    """A stack preset as offered to the add-project UI: its identity plus the
    ``settings.toml`` fragment it would write, so the dev inspects the generated
    config before it lands (detect-and-propose, never magic)."""

    id: str
    label: str
    blurb: str
    setup: Optional[str] = None
    run: Optional[str] = None
    gate: dict[str, str] = Field(default_factory=dict)
    #: The `[scripts]`+`[gate]` block this preset serializes to, for inspection.
    toml: str


class StackCandidate(BaseModel):
    preset: StackPreset
    #: Detector confidence in [0, 1]; 0 = no signal for this stack.
    confidence: float


class StackDetection(BaseModel):
    """Result of sniffing a project's tree: the full ranked candidate list plus a
    single ``proposal`` to auto-fill. ``proposal`` is None when detection is
    ambiguous (two real stacks scored too close) — the UI then asks rather than
    auto-picking. ``candidates`` always includes ``custom`` so 'configure
    manually' is on the menu for every repo."""

    ambiguous: bool
    proposal: Optional[StackCandidate] = None
    candidates: list[StackCandidate]


class ApplyPresetRequest(BaseModel):
    """Confirm a stack preset from the add-project propose-and-confirm UI: write its
    ``[scripts]`` + ``[gate]`` into the project's settings. ``target`` picks the
    file (shared/committed vs local/personal); the propose-and-confirm flow defaults
    to shared so the whole team inherits the project's gate."""

    preset_id: str
    target: Literal["local", "shared"] = "shared"


class MkdirRequest(BaseModel):
    """Create a new folder inside the browse root (the 'new project' affordance)."""
    parent: str
    name: str


class CreateWorkspaceRequest(BaseModel):
    name: str
    base_ref: Optional[str] = None  # defaults to the project's default branch
    branch: Optional[str] = None    # defaults to haro/<slug(name)>
    # Set when the workspace is seeded from a backlog todo: the item's stable id
    # (see Workspace.seed_key), so the backlog can flag that item as in progress.
    seed_key: Optional[str] = None


class StartRaceRequest(BaseModel):
    """Start a winner-only fan-out (backlog/winner-fanout.md §1): one task, N lanes.

    ``lanes`` overrides the project's ``[race] lanes`` grid for this race only (the
    composer's "race ×N" affordance sends nothing and inherits the project's). ``name``
    seeds each lane's workspace/branch name; without one the task's first line is
    slugified, exactly like a manually-created workspace.

    Nothing here can widen the safety envelope: the budget ceiling, the lane cap, the
    policy and both thin-suite floors all come from project config, so a client can
    never talk the platform into an uncapped or unrefereeable race."""

    task: str
    name: Optional[str] = None
    #: Per-lane ``{"model": …, "effort": …}`` overrides; capped at ``[race] max_lanes``.
    lanes: Optional[list[dict[str, str]]] = None
    base_ref: Optional[str] = None
    #: Backlog item this race was seeded from — stamped on every lane workspace so the
    #: backlog still flags the item in progress.
    seed_key: Optional[str] = None


class RacePreflightResponse(BaseModel):
    """Dry-run of §0's hard gate: may this project race, and under what ceiling?

    Its own endpoint so the composer can grey out (and *explain*) the race button
    before anyone spends a dollar — a refusal discovered after three worktrees exist
    is a refusal that already cost money."""

    ok: bool
    refusals: list[str] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
    max_total_usd: float = 0.0
    lanes: list[dict[str, str]] = Field(default_factory=list)
    policy: str = "cheapest_green"
    suite_tests: Optional[int] = None


class AdoptWorkspaceRequest(BaseModel):
    """Adopt an existing *foreign* git worktree (one haro never created) as a
    workspace, so the gate/firewall governs it too (backlog/merge-firewall.md §1).

    ``path`` is the worktree's on-disk path (as surfaced by
    ``GET /projects/{id}/worktrees``). The branch and base are derived server-side
    from git — never trusted from the client. ``name`` is an optional display
    label, defaulting to the branch name."""

    path: str
    name: Optional[str] = None


class FirewallVerdict(BaseModel):
    """Merge Firewall verdict oracle (backlog/merge-firewall.md §3): the repo-level
    git hook curls ``GET /firewall/verdict`` to decide whether a push/merge may
    proceed. ``green`` ⇔ the workspace's ``status == gate_green`` (which already
    reflects ``gate_merge_result`` and, later, the Double Gate — no extra logic to
    inherit them); ``red`` ⇔ the gate ran and isn't green; ``unknown`` ⇔ no
    haro-governed workspace for that (repo, branch), or it has no gate verdict yet.
    Whether ``unknown``/``red`` actually *blocks* is the hook + ``[trust]`` config's
    call (fail-open warn by default), never this endpoint's — it only reports.

    ``workspace_id``/``gate`` are populated whenever a workspace is matched (so the
    hook can name it + show failing counts), and ``None`` when the branch is
    ungoverned."""

    verdict: Literal["green", "red", "unknown"]
    workspace_id: Optional[str] = None
    gate: Optional[GateSummary] = None


class FirewallInstallRequest(BaseModel):
    """Arm the Merge Firewall for a project (``POST /projects/{id}/firewall``,
    backlog/merge-firewall.md §3). ``firewall`` is the posture: ``off`` disarms
    (removes our hooks), ``warn`` installs fail-open, ``block`` installs fail-closed.
    ``strict`` opts a ``warn`` posture into fail-closed independently (``block``
    implies it). ``backend_url`` is written to ``git config haro.url`` only when it
    differs from the default, so the hook can reach a backend on a non-default
    host/port; the frontend passes the origin it's talking to."""

    firewall: Literal["off", "warn", "block"] = "off"
    strict: bool = False
    backend_url: Optional[str] = None


class FirewallInstallResult(BaseModel):
    """Outcome of arming/disarming the firewall: the persisted posture, the effective
    ``git config haro.strict`` value, and the hook paths written (or removed when
    ``off``), plus the settings file the ``[trust]`` posture was persisted to."""

    firewall: str
    strict: bool
    hooks: list[str] = []
    config_path: str


class RenameWorkspaceRequest(BaseModel):
    """Either field may be omitted to leave it unchanged. ``branch`` renames the
    live git branch (``git branch -m``) — the worktree directory itself doesn't
    move, since it's addressed by workspace id/slug, not branch name."""

    name: Optional[str] = None
    branch: Optional[str] = None


class StartAgentRequest(BaseModel):
    task: str
    # Which agent session in the workspace to run in (transcript keyed by
    # ``(workspace_id, session_id)``). None ⇒ the primary session (``store.DEFAULT_SESSION``),
    # so the single-session path is unchanged. A second concurrent conversation (the stream
    # switcher's "+ session") sends its own id here — each session --resume's independently.
    session_id: Optional[str] = None
    # Per-run backend override. None ⇒ fall back to the project's default (`[agent] adapter`).
    # "claude-code" uses model/effort below; "local" ignores effort and treats `model` as
    # the local model tag (falling back to the project's `local_model`).
    adapter: Optional[str] = None
    model: Optional[str] = None
    effort: Optional[str] = None  # reasoning effort: low|medium|high|xhigh|max
    run_gate_on_done: bool = True  # auto-run the test gate when the agent finishes
    # Plan Mode (per-run): run with `--permission-mode plan` — the agent produces a plan
    # and edits NOTHING until the dev approves it, the review surface *before* the first
    # file edit. Only adapters that support it act on it (claude-code today); ignored
    # otherwise (feature-detect, not break). A plan run has no diff, so the gate stays
    # idle for it (see runner.py) and the stream shows approve/feedback actions.
    plan: bool = False
    # Fast Mode (per-run): "speed over depth" for narrow edits / quick follow-ups. Injects
    # `--settings '{"fastMode":true}'` (there is no `--fast` flag) so the CLI runs Opus with
    # `speed="fast"`. Mutually exclusive with plan in the UI (fast ≠ careful planning).
    # Only claude-code acts on it today; ignored otherwise (feature-detect, not break). A
    # fast run still edits files, so — unlike plan — it gates normally.
    fast: bool = False
    # Which step of the plan→scout→build→refute loop this run is (`"plan"` |
    # `"build"`; role/review is Phase 2+). None ⇒ inferred server-side as
    # `"plan"` when `plan` is set, else `"build"` — only sent explicitly by the
    # approve-plan handoff, which must resolve to "build" even though the prior
    # plan turn used the plan role. See notes/workflow-roles-plan.md.
    role: Optional[str] = None


class RewindRequest(BaseModel):
    """Rewind the session to a turn boundary — a ``user`` event's ``turn`` ordinal (the
    "rewind to here" anchors from ``GET /turns``). The transcript is truncated at/after
    that turn and the composer re-prompted from it. ``checkpoint`` snapshots the current
    worktree as a commit *first* (reusing the Git-panel checkpoint-commit path) so the
    dropped turns' file edits are preserved + recoverable — a non-destructive reconcile
    of the worktree with the rewound conversation."""

    turn: int
    checkpoint: bool = True
    # Which agent session to rewind (transcript keyed by (ws, session_id)). None ⇒ the
    # primary session. The switcher rewinds whichever session tab is active.
    session_id: Optional[str] = None


class RewindResponse(BaseModel):
    """Outcome of a rewind: which turn we rewound to, that turn's prompt (for the
    composer to prefill), how many transcript events were dropped, and the sha of the
    safety checkpoint commit if one was made (``None`` when the worktree was clean or
    ``checkpoint`` was off)."""

    turn: int
    prompt: str = ""
    dropped: int = 0
    checkpoint: Optional[str] = None


class TodoWriteRequest(BaseModel):
    """Create or overwrite one backlog markdown file from the in-app editor.
    ``path`` is repo-relative (e.g. ``backlog/gate.md``) and must be backlog-eligible
    — under the project's backlog folder or a todo-named doc; ``content`` is the full
    raw markdown. See ``backlog.write_todo`` for the path-safety guards."""

    path: str
    content: str


class TodoItemAppendRequest(BaseModel):
    """One "send to backlog" call from ③ verify (backlog-redesign-plan.md Move 3):
    a failing test, a mutation survivor, an untested hunk, a refuter finding, or a
    review comment, appended as a single ``- [ ] <title> (<evidence>)`` line.
    ``file``, when omitted, defaults to ``"<[backlog] dir>/follow-ups.md"`` (decided
    over the producing workspace's own seed file, so residue is never buried in a
    spec doc) — resolved server-side in ``main.add_todo_item`` against the
    project's actual configured `backlog_dir`, NOT frozen as a literal
    ``"backlog/follow-ups.md"`` here, or every project with a custom `[backlog] dir`
    would 400 on every "send to backlog" button. Still backlog-eligible-checked,
    not a free-form path. See ``backlog.append_item``."""

    title: str
    evidence: str = ""
    file: str | None = None


class LocalModelsResponse(BaseModel):
    """The models installed on the project's configured local server, for the composer's
    Local-AI model dropdown. ``reachable`` is False when the server can't be queried (not
    running / wrong URL) — the UI then falls back to a free-text tag field."""

    reachable: bool
    models: list[str] = []
    base_url: str = ""


class MergeRequest(BaseModel):
    message: Optional[str] = None  # commit / PR message; defaults from the workspace + task


class WriteFileRequest(BaseModel):
    path: str
    content: str


class CreateEntryRequest(BaseModel):
    """Tree right-click "new file" / "new folder": create an entry in the worktree."""
    path: str
    dir: bool = False


class RenameEntryRequest(BaseModel):
    """Tree right-click "rename" (also a move): ``path`` → ``to`` within the worktree."""
    path: str
    to: str


class DeleteEntryRequest(BaseModel):
    """Tree right-click "delete": remove a file or folder (recursive) from the worktree."""
    path: str


class ContextAttachRequest(BaseModel):
    """A large pasted block promoted to a file attachment (composer paste-to-file).
    Written under ``.context/`` in the worktree (git-excluded) so the agent can read
    it via an ``@`` mention without the block bloating the prompt or the diff."""

    content: str
    name: Optional[str] = None  # optional display/basename hint; server slugs + uniquifies


class CheckedRowRequest(BaseModel):
    """Tick a "code to check" row off, or put it back (``POST /workspaces/{id}/checked``).

    The tick records that a human LOOKED, never that anything was verified — the pane's
    naming law reaches the API too. It exists because half the row kinds ask a question no
    test can answer ("confirm this deletion is intended"), and a question with nowhere to
    put the answer is a question people stop reading."""

    key: str
    checked: bool = True


class ContextUploadRequest(BaseModel):
    """A pasted image or a picked file promoted to a ``.context/`` attachment — the
    binary sibling of :class:`ContextAttachRequest`. The payload is base64 so it
    rides the same JSON transport (no multipart dep); the server decodes + writes
    the raw bytes, keeping the original extension so the code view can preview it
    and Claude Code can read it via an ``@`` mention."""

    content_b64: str  # base64 of the raw file bytes
    name: Optional[str] = None  # original filename (for the basename + extension)
    content_type: Optional[str] = None  # MIME hint from the browser (e.g. "image/png")


class RunScriptInfo(BaseModel):
    """One named run command for the workspace Run menu. ``running``/``url`` are the
    live process state (only populated by the per-workspace scripts endpoint)."""

    id: str
    command: str
    default: bool = False
    icon: Optional[str] = None
    running: bool = False
    url: Optional[str] = None


class ScriptsConfig(BaseModel):
    """The `[scripts]` config surfaced to the in-app editor (Runbook)."""

    setup: Optional[str] = None
    run: Optional[str] = None            # the DEFAULT run command (back-compat)
    runs: list[RunScriptInfo] = Field(default_factory=list)  # all named runs
    archive: Optional[str] = None
    run_mode: str = "concurrent"
    login_shell: bool = False


class ScriptsUpdateRequest(ScriptsConfig):
    # "local" → settings.local.toml (personal); "shared" → settings.toml (committed, team).
    target: Literal["local", "shared"] = "local"


class InstructionsConfig(BaseModel):
    """The project's custom-instructions markdown, split by scope for the editor.

    ``shared`` = ``.haro/instructions.md`` (committed, team baseline);
    ``local`` = ``.haro/instructions.local.md`` (gitignored, personal). Both
    are concatenated (shared then local) into the agent's `--append-system-prompt`."""

    shared: str = ""
    local: str = ""


class InstructionsUpdateRequest(BaseModel):
    text: str = ""
    target: Literal["local", "shared"] = "local"


class EnvConfig(BaseModel):
    """The project's worktree ``.env`` seed (``.haro/.env``) surfaced to the
    Environment settings tab. Always gitignored — it holds secrets — so there's no
    team/personal split, just one machine-local dotenv block. New worktrees are
    seeded with it so a fresh workspace inherits the dev's secrets."""

    content: str = ""


class EnvUpdateRequest(BaseModel):
    content: str = ""  # empty → remove the seed file


class RemoteConfig(BaseModel):
    """A project's ``origin`` git remote (shared across all its worktrees). ``url``
    is None when the repo is local-only — merges then stay local instead of `gh` PR.
    ``web_url`` is the browsable base (``https://host/owner/repo``) derived from
    ``url``, used to deep-link typed ``PR #N`` references in the composer."""

    url: Optional[str] = None
    web_url: Optional[str] = None


class RemoteUpdateRequest(BaseModel):
    url: str = ""  # empty → unlink (back to local-only)


class DefaultBranchRequest(BaseModel):
    # The base branch new worktrees branch from. An `origin/` prefix is stripped
    # server-side (default_branch is stored bare; create_workspace re-adds it).
    branch: str


class WorkflowConfig(BaseModel):
    """The project's `[workflow]` ship policy surfaced to the Git settings tab.

    ``merge_mode`` decides which ship actions the ④ step offers — "both"
    (PR + Merge), "pr" (PR only), or "merge" (Merge only)."""

    merge_mode: Literal["both", "pr", "merge"] = "both"


class WorkflowUpdateRequest(WorkflowConfig):
    # merge_mode is a team policy, so default to the committed settings.toml.
    target: Literal["local", "shared"] = "shared"


class GateConfig(BaseModel):
    """The project's gate config surfaced to the Gate settings tab.

    ``runner`` picks the test-runner adapter (vitest is the default). ``command`` /
    ``format`` apply to the command/offense runners only. ``gate_dir`` is the subdir
    the gate runs in (monorepos). ``default_scope`` is the scope the auto-gate uses,
    ``merge_result`` gates the merge result rather than the worktree alone, and the
    flaky/coverage guards decide what can still block a green gate — these last three
    live under ``[workflow]`` on disk but are surfaced here as gate behaviour."""

    runner: Literal["vitest", "pytest", "command", "offense"] = "vitest"
    command: str = ""
    format: str = ""
    gate_dir: str = ""
    default_scope: Literal["all", "impacted"] = "all"
    merge_result: bool = False
    flaky_rerun: bool = False
    coverage_guard: Literal["off", "warn", "block"] = "off"
    coverage_tolerance: float = 0.0
    # Test-tamper alarm — the ``green*`` signal. Defaults ON to "warn" (deterministic,
    # no extra test run); "block" folds ``tamper_blocked`` into the green conjunction.
    tamper_alarm: Literal["off", "warn", "block"] = "warn"
    # Code to check (backlog/code-to-check.md): the diff-level signal. "warn" (default)
    # records rows for the rail pane; "off" skips the pass. No "block" on purpose — see
    # the field comment on TestRun.unchecked_items.
    code_to_check: Literal["off", "warn"] = "warn"
    # Live Gate (backlog/live-gate.md) — an ADVISORY impacted-only loop off the fs
    # watcher, so the rail carries a live verdict while you edit. OFF by default: it
    # spends CPU on every save (unlike the tamper alarm, which adds no test run). A
    # watch run can never ship anything — see ``gate.run_watch``.
    watch: bool = False
    # Verified Hunks (backlog/verified-hunks.md): per-line "executed by the green suite"
    # annotation on the ④ ship diff, so a 1,200-line agent diff collapses to the residue
    # the suite never exercised. ON by default — it's evidence, never a verdict (it can't
    # block a merge), and adds no extra test run: it reuses the per-line coverage map the
    # code-to-check pass already measures on a green gate.
    verified_hunks: bool = True
    # Mutation score (backlog/mutation-gate.md): the "would the tests notice if the code
    # were wrong?" residue. On-demand + ADVISORY — it re-runs the suite once per injected
    # fault, so it lives off the ~1s merge-gate path and can never block a merge (there is
    # no ``mutation_blocked``). OFF by default: it is the one signal that costs N test runs.
    mutation: bool = False


class GateUpdateRequest(GateConfig):
    # The gate policy is a team default, so default to the committed settings.toml.
    target: Literal["local", "shared"] = "shared"


class AgentConfig(BaseModel):
    """The project's `[agent]` cost/model guardrails surfaced to the Agent settings tab.

    ``default_model`` / ``default_effort`` are the model + reasoning-effort a run gets
    when it doesn't pick its own (an explicit per-run pick still wins). ``max_budget_usd``
    is the HARD per-run dollar ceiling (0 ⇒ uncapped); ``cost_warn_usd`` a SOFT heads-up
    on cumulative workspace spend (0 ⇒ off). Every workspace inherits these.

    ``max_parallel`` caps how many agent subprocesses run AT ONCE across the whole
    install (0 ⇒ unlimited); runs over the cap wait as ``AgentRunStatus.queued``. It's a
    resource guard rather than a cost guard — the two above bound *spend*, this one
    bounds how much of the machine a fleet of parallel agents may take.

    ``adapter`` picks the agent backend: ``"claude-code"`` (default, cloud CLI) or
    ``"local"`` (LocalModelAdapter → Ollama / llama.cpp — no cloud). When ``local``,
    the Claude model/effort/budget knobs don't apply; ``local_base_url`` +
    ``local_model`` point at the local OpenAI-compatible server."""

    default_model: Literal["opus", "sonnet", "haiku", "fable"] = "sonnet"
    default_effort: Literal["", "low", "medium", "high", "xhigh", "max"] = ""
    max_budget_usd: float = 5.0
    cost_warn_usd: float = 20.0
    max_parallel: int = Field(default=4, ge=0)
    adapter: Literal["claude-code", "local"] = "claude-code"
    local_base_url: str = "http://localhost:11434/v1"
    local_model: str = "qwen2.5-coder"


class AgentUpdateRequest(AgentConfig):
    # The agent defaults are a team policy, so default to the committed settings.toml.
    target: Literal["local", "shared"] = "shared"


class RolesConfig(BaseModel):
    """The project's `[roles]` workflow-loop config (notes/workflow-roles-plan.md):
    each step of plan→scout→build→refute gets its own model/effort, surfaced to the
    Roles settings tab. Each role is its ``"model:effort"`` shorthand (e.g.
    ``"fable:xhigh"``, or just ``"haiku"`` for scout which carries no effort); ``""``
    means that step falls back to `[agent] default_model`/`default_effort`.

    ``review_enforce``/``review_max_rounds`` configure the refuter (Phase 3) but are
    parsed from day one so the Roles tab and `[roles]` TOML shape never have to
    change shape later — only start being acted on."""

    enabled: bool = False
    plan: str = ""
    build: str = ""
    review: str = ""
    scout: str = ""
    review_enforce: Literal["off", "warn"] = "off"
    review_max_rounds: int = Field(default=2, ge=0, le=10)


class RolesUpdateRequest(RolesConfig):
    # Roles are workflow policy (like trust), so default to the committed settings.toml.
    target: Literal["local", "shared"] = "shared"


class DiffResponse(BaseModel):
    base_ref: str
    diff: str
    files_changed: int
    # Echoes the requested commit sha when this diff is scoped to a single
    # commit (vs the full working-vs-base_ref diff) — None for the default view.
    commit: str | None = None


class ReviewFinding(BaseModel):
    """One AI code-review finding on the worktree diff — the "quality" half of the
    verify step's Double Gate. Advisory: findings surface next to the test grid and
    round-trip to the composer as a fix, but they never block the merge (only a red
    *test* gate does). See notes/differentiation-bets.md Bet 7."""

    file: str
    line: Optional[int] = None
    severity: Literal["high", "medium", "low", "nit"] = "medium"
    category: str = "review"
    title: str
    detail: str = ""


class ReviewResult(BaseModel):
    """A completed AI review pass over the diff. ``error`` is set (findings empty)
    when the reviewer couldn't run or its output couldn't be parsed."""

    ran_at: float
    model: str
    summary: str = ""
    findings: list[ReviewFinding] = Field(default_factory=list)
    error: Optional[str] = None


class ReviewRequest(BaseModel):
    """Trigger an AI review pass. ``model`` overrides the project default reviewer."""

    model: Optional[str] = None


class MergeQueueItem(BaseModel):
    """One workspace's outcome in a merge-queue run.

    ``outcome``: ``merged`` (landed), ``ready`` (dry-run: would merge cleanly),
    ``blocked`` (conflicts with base / merge failed — needs a rebase + re-gate),
    ``skipped`` (not admitted: dirty, busy, not green, or — on a project that armed
    ``[trust] auto_action`` — not rung-complete, in which case ``reason`` names the unmet
    trust conditions and the workspace stays merge-by-hand)."""

    workspace_id: str
    name: str
    outcome: Literal["merged", "ready", "blocked", "skipped"]
    reason: Optional[str] = None
    conflicts: list[str] = Field(default_factory=list)


class MergeQueueResult(BaseModel):
    """The conflict-aware merge queue's result: only green workspaces are admitted,
    and they merge in a conflict-safe order (each re-checked against the advancing
    base). ``dry`` runs report readiness without landing anything."""

    dry: bool = False
    items: list[MergeQueueItem] = Field(default_factory=list)


class ArchiveQueueRequest(BaseModel):
    """Archive many workspaces through the serial queue (backlog/bulk-archive.md).

    ``force`` takes the risky ones too — the ones the planner skips by default because
    archiving throws their work away (uncommitted edits, unmerged commits, a running
    agent). It's the UI's explicit "include N with unsaved work", never a default."""

    workspace_ids: list[str] = Field(default_factory=list)
    force: bool = False


class ArchiveQueueItem(BaseModel):
    """One workspace's slot in a bulk-archive run.

    ``outcome``: ``queued`` (admitted, waiting) → ``archiving`` (in flight, one at a
    time) → ``archived`` | ``failed`` (this teardown only — the batch continues);
    ``skipped`` = never admitted (its ``reason`` is the risk it carries, and it stays
    archivable one-by-one); ``canceled`` = still queued when the run was stopped.

    ``risks`` is what the workspace stands to lose, recorded even on a ``force`` run:
    the record has to say what the user agreed to throw away."""

    workspace_id: str
    name: str
    outcome: Literal["queued", "archiving", "archived", "failed", "skipped", "canceled"] = "queued"
    reason: Optional[str] = None
    risks: list[str] = Field(default_factory=list)


class ArchiveQueueRun(BaseModel):
    """A bulk archive: one teardown at a time, in a deterministic order.

    ``dry`` runs are the preview the confirm dialog renders — same shape as the live
    run, so what the user approved and what they watch are literally one model.
    ``stop_requested`` is the cooperative stop: checked between items so the in-flight
    teardown always finishes (a half-removed worktree is worse than a slow stop)."""

    id: str = Field(default_factory=lambda: _id("arq"))
    project_id: str
    dry: bool = False
    force: bool = False
    state: Literal["planned", "running", "done", "canceled"] = "planned"
    stop_requested: bool = False
    items: list[ArchiveQueueItem] = Field(default_factory=list)
    created_at: float = Field(default_factory=_now)
    finished_at: Optional[float] = None


class ImpactResponse(BaseModel):
    """The Impact Map: the agent's diff → the tests it provably affects."""

    base_ref: str
    supported: bool = True
    error: Optional[str] = None
    changed_files: list[dict] = Field(default_factory=list)  # [{path, added, removed}]
    total_tests: int = 0
    total_test_files: int = 0
    impacted_tests: list[dict] = Field(default_factory=list)  # [{file, name}]
    impacted_files: list[str] = Field(default_factory=list)   # distinct impacted test files


class BlameHunk(BaseModel):
    """One changed location implicated in a test failure. ``line``/``code`` are set
    when a stack frame lands exactly on a changed line; ``line`` is None for a
    file-level fallback (the failure's stack passed through a changed file, but no
    single changed line matched)."""

    file: str
    line: Optional[int] = None
    code: Optional[str] = None


class BlameEntry(BaseModel):
    file: str  # the failing test's file
    name: str  # the failing test's name
    hunks: list[BlameHunk] = Field(default_factory=list)


class BlameResponse(BaseModel):
    """Failure → blame: for each failing test in the latest run, the changed lines
    (vs base_ref) most likely responsible — the reverse of the Impact Map."""

    base_ref: str
    supported: bool = True
    error: Optional[str] = None
    entries: list[BlameEntry] = Field(default_factory=list)


class VerifiedFile(BaseModel):
    """What the last green gate can and cannot say about one file's added lines.

    The pydantic twin of ``verified_hunks.FileProof`` (same relationship
    ``TamperFinding`` has to ``tamper.Finding``). ``lines`` is keyed by the line
    number as a *string* because that is what JSON gives us; a ``null`` value means
    the line is **not coverable** (blank, comment, closing brace, type-only) and is
    counted in ``noncoverable`` — never as untested."""

    path: str
    in_map: bool = True     # some test imports this file at all
    stale: bool = False     # its added lines moved since the gate ran ⇒ no line data
    added: int = 0
    executed: int = 0
    unexecuted: int = 0
    noncoverable: int = 0
    lines: dict[str, Optional[int]] = Field(default_factory=dict)


class VerifiedHunksResponse(BaseModel):
    """Per-line proof for the ④ ship diff (backlog/verified-hunks.md §2).

    ``supported=False`` + ``note`` is the honest "we cannot say" state, and it has
    several causes worth keeping distinct in the copy: the feature is off, the runner
    is not vitest, no coverage provider is installed, or no green gate has run on this
    tree yet. ``stale`` means at least one file's added lines moved since the gate ran
    — those files carry no line data at all, because a shifted line number would put a
    green dot on code the suite never saw."""

    base_ref: str
    gate_sha: Optional[str] = None   # HEAD when the gate measured; display only
    supported: bool = False
    stale: bool = False
    files: list[VerifiedFile] = Field(default_factory=list)
    note: Optional[str] = None


class MutationSurvivor(BaseModel):
    """One injected fault the green suite still passed — a mutant it could not tell
    apart. The pydantic twin of ``mutation.Survivor``. It is EVIDENCE (a line whose
    tests are too weak to notice this change), never a verdict."""

    path: str
    line: int
    operator: str   # e.g. "round → floor"


class MutationResponse(BaseModel):
    """Mutation score for the ③ verify residue (the "is the suite hard to fool?" test).

    Advisory by construction — mirrors ``VerifiedHunksResponse``: ``supported=False`` +
    ``note`` is the honest "we cannot say" state (feature off · non-vitest runner · no
    green gate on this tree yet). ``score`` is the percent of *runnable* mutants the
    suite caught (killed / (killed+survived)); ``None`` when nothing was scored. The
    ``survivors`` list is the shortlist a reviewer should actually read — it can never
    block a merge (there is no ``mutation_blocked``)."""

    base_ref: str
    #: HEAD at measurement time — display only. NOT sufficient on its own to detect a
    #: stale score: haro doesn't commit agent work until merge, so HEAD can sit still for
    #: an entire workspace's lifetime while the tree keeps changing underneath it.
    #: `diff_fingerprint` below is the field that actually tracks tree content.
    gate_sha: Optional[str] = None
    #: A cheap hash of the diff this score was measured against (vs `base_ref`). The
    #: staleness key: `receipt.py` recomputes this over the CURRENT diff and compares,
    #: so a score survives repeated gate runs on an unchanged tree but is flagged the
    #: moment the agent's uncommitted edits actually move it — the case `gate_sha` misses.
    diff_fingerprint: Optional[str] = None
    supported: bool = False
    score: Optional[int] = None
    killed: int = 0
    survived: int = 0
    skipped: int = 0                 # mutants that failed to compile — not scored
    total_mutants: int = 0
    budget_capped: bool = False
    survivors: list[MutationSurvivor] = Field(default_factory=list)
    note: Optional[str] = None


# --------------------------------------------------------------------------- #
# Gate Receipt (usp-critique-plan.md idea 1) — the exportable evidence packet
# --------------------------------------------------------------------------- #
class ReceiptSuite(BaseModel):
    runner: str = ""
    scope: str = "all"
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    impacted_count: Optional[int] = None


class ReceiptTamper(BaseModel):
    measured: bool = False
    clean: bool = True
    findings_count: int = 0
    note: Optional[str] = None


class ReceiptPlanCompliance(BaseModel):
    """The Double Gate's LLM third (backlog/double-gate.md §3) — "does the diff
    implement the task it was given?" — a SEPARATE check from the deterministic
    scanners above and the only thing that can set `ReceiptQuality.blocked` while
    `measured` (the deterministic tier) stays False, since it runs independently of
    `[quality] enabled`. Round-7 review found the deterministic-only rendering left a
    plan-compliance-blocked run's markdown with no stated cause at all — this exists
    so `blocked=True` is never unexplained."""

    ran: bool = False
    error: Optional[str] = None
    compliant: bool = True
    confidence: Optional[str] = None
    summary: Optional[str] = None
    gaps: int = 0
    #: Whether this result MEETS the bar to block (`PlanComplianceResult.blocking`,
    #: high-confidence non-compliance with cited gaps) — independent of whether the
    #: project actually has `[quality] plan_compliance = "block"` configured. Never
    #: display this alone as "BLOCKING": under `"warn"` mode it can be True on a
    #: genuinely GREEN run (the gate never enforces it), and see `error` below.
    blocking: bool = False
    #: Structurally always False since 2026-09-17: `[quality] plan_compliance = "block"`
    #: (the only value that would set this) was cut — an LLM verdict never blocks a
    #: merge on its own. Kept for the same "blocking alone lies" reason round 8 added
    #: it: the check a reader wants is `blocking AND enforced`, not `blocking` alone.
    enforced: bool = False


class ReceiptQuality(BaseModel):
    measured: bool = False
    #: Mode-agnostic: True whenever `blocking_count > 0`, i.e. whenever
    #: `ship_preflight` (integrate.py) would actually refuse this run — NOT the same
    #: as `TestRun.quality_blocked`, which only fires under `[quality] enforce =
    #: "block"`. Under "warn" the automated verdict can stay green while a blocking
    #: finding still refuses a merge; this field (and the receipt's overall verdict)
    #: reflect that stricter, actual-mergeability check instead.
    blocked: bool = False
    findings_count: int = 0
    #: How many of `findings_count` meet the blocking severity threshold — mirrors
    #: `GateSummary.quality_blocking`. Can be > 0 while `blocked` was False in an
    #: older receipt read before round 9's fix; kept as its own count (not just a
    #: bool) so the markdown/UI can name the number, not just wave at "some".
    blocking_count: int = 0
    note: Optional[str] = None
    plan_compliance: ReceiptPlanCompliance = Field(default_factory=ReceiptPlanCompliance)


class ReceiptReview(BaseModel):
    """The refuter (Phase 3 — notes/workflow-roles-plan.md): an independent re-check
    of the green diff with read-only tools, plan compliance's sibling — but its own
    top-level field (not nested under ``quality`` like ``ReceiptPlanCompliance``),
    since it's gated on `[roles]` and runs independently of `[quality] enabled`
    entirely. Same round-8 lesson as ``ReceiptPlanCompliance``: ``blocking`` is
    whether this verdict MEETS the bar (a "fail" with a surviving must-fix);
    ``enforced`` is structurally always False since 2026-09-17 (`review_enforce =
    "block"` was cut) but the field stays, for the same reason as above;
    ``enforced`` is whether it was, so a reader needs `blocking AND enforced` before
    calling this run BLOCKING."""

    ran: bool = False
    error: Optional[str] = None
    verdict: Literal["pass", "fail"] = "pass"
    summary: Optional[str] = None
    must_fix: int = 0
    blocking: bool = False
    enforced: bool = False


class ReceiptVerifiedHunks(BaseModel):
    supported: bool = False
    percentage: Optional[float] = None  # executed / added across the diff, 0-100
    untested_files: list[str] = Field(default_factory=list)
    note: Optional[str] = None


class ReceiptMutation(BaseModel):
    supported: bool = False
    ran: bool = False  # a score was actually computed at some point for this tree
    # Best-effort: True when the cached score's own `diff_fingerprint` disagrees with
    # the tree's current diff (see `MutationResponse.diff_fingerprint` — a commit sha
    # can't detect this, since haro doesn't commit agent work until merge). Unknown
    # (stays False) when the cached score has no fingerprint — an old score predating
    # this field degrades to "can't say", not "assume fresh".
    stale: bool = False
    score: Optional[int] = None
    survivors: list[MutationSurvivor] = Field(default_factory=list)
    note: Optional[str] = None


class ReceiptAgent(BaseModel):
    model: Optional[str] = None
    effort: Optional[str] = None
    cost_usd: Optional[float] = None


class Receipt(BaseModel):
    """The exportable evidence packet for a workspace's gate run
    (usp-critique-plan.md idea 1): what a reviewer reads instead of the diff.

    Assembled entirely from facts a green gate already computed — building a
    receipt triggers no new test run. Mutation is the one signal that costs test
    runs, so the receipt only reports whatever score was last computed on demand
    (``mutation.ran = False`` when nobody has run it yet); it never recomputes one."""

    workspace_id: str
    branch: str = ""
    base_ref: str = ""
    verdict: Literal["green", "red", "degraded", "none"] = "none"
    #: The sha the last GREEN gate actually measured (from the cached per-line coverage
    #: map) — not a live `rev_parse HEAD`, which would name whatever's on disk right now
    #: rather than what the evidence below describes.
    gate_sha: Optional[str] = None
    #: `diff_fingerprint` of the diff the gate ACTUALLY measured (from
    #: `TestRun.diff_fingerprint`, frozen at gate time) — usp-critique-round3.md
    #: Move A. An `--attest` statement's subject digest and the merge commit's
    #: `Verified-by:` trailer both read this, never a fresh re-diff, so a tree that
    #: drifted after the gate ran can't silently attach a mismatched claim.
    digest: Optional[str] = None
    #: `TestRun.sandbox_profile` — usp-critique-round3.md Move D step 1. `None`
    #: means this run was not sandboxed (not asked for, unsupported runner, or
    #: bwrap unavailable — see `degraded_reasons` for which).
    sandbox_profile: Optional[str] = None
    #: Verbatim from `TestRun.degraded_reasons` — the actual "what didn't run" facts
    #: behind a `degraded` verdict. Without this, `verdict == "degraded"` is one
    #: unexplained word above a body where every other section still claims "clean";
    #: this is what lets a reader (or the git note / PR comment sinks) see WHICH check
    #: was compromised instead of just that something was.
    degraded_reasons: list[str] = Field(default_factory=list)
    suite: ReceiptSuite = Field(default_factory=ReceiptSuite)
    tamper: ReceiptTamper = Field(default_factory=ReceiptTamper)
    quality: ReceiptQuality = Field(default_factory=ReceiptQuality)
    review: ReceiptReview = Field(default_factory=ReceiptReview)
    verified_hunks: ReceiptVerifiedHunks = Field(default_factory=ReceiptVerifiedHunks)
    mutation: ReceiptMutation = Field(default_factory=ReceiptMutation)
    agent: ReceiptAgent = Field(default_factory=ReceiptAgent)
    generated_at: float = Field(default_factory=_now)


class ReceiptResponse(BaseModel):
    receipt: Receipt
    markdown: str


# --------------------------------------------------------------------------- #
# Git & PR panel (#3 — the in-app "switch to a terminal / GitHub" killer)
# --------------------------------------------------------------------------- #
class GitFileStatus(BaseModel):
    """One dirty file in the worktree, with staged/unstaged status words."""

    path: str
    index: str = ""   # staged change, e.g. "modified"/"added"/""
    work: str = ""    # unstaged change
    staged: bool = False


class GitStatusResponse(BaseModel):
    branch: str
    base_ref: str
    ahead: int = 0    # commits this branch has that base doesn't
    behind: int = 0   # commits base has that this branch doesn't
    dirty: int = 0
    files: list[GitFileStatus] = Field(default_factory=list)
    # Which ship actions to offer ("both" | "pr" | "merge"); from [workflow] config.
    merge_mode: str = "both"
    #: The workspace has no worktree on disk (archived/merged, or removed out of band), so
    #: git could not be consulted. Set explicitly rather than letting ahead/behind/dirty
    #: read as a measured zero — an unmeasurable number must never look measured
    #: (backlog/double-gate.md §0's rule, applied to the git panel).
    worktree_missing: bool = False


class GitCommit(BaseModel):
    sha: str
    short: str
    author: str
    when: str         # relative, e.g. "3 hours ago"
    subject: str
    own: bool = False  # added by this branch since base_ref


class CommitRequest(BaseModel):
    message: str


class PrStatusResponse(BaseModel):
    """PR state + CI checks + review, via the user's ``gh`` CLI. Degrades gracefully:
    ``supported=False`` (no remote / no gh) or ``exists=False`` (no PR yet)."""

    supported: bool = True
    exists: bool = False
    reason: Optional[str] = None
    number: Optional[int] = None
    title: Optional[str] = None
    state: Optional[str] = None
    # PR headRefOid — lets us tell a reused/renamed branch's OLD merged PR apart
    # from this branch's current commit (a branch name stays MERGED forever).
    head_sha: Optional[str] = None
    # The workspace's *reconciled* merged verdict, computed server-side on this very
    # request (``_adopt_merged_state``) and therefore head_sha-aware. The panel must
    # read this rather than re-deriving merged from ``state == "MERGED"``: that
    # SHA-blind shortcut painted the ④ ship step purple while the sidebar dot, the
    # bento border and "Continue on a new branch" all correctly read not-merged.
    workspace_merged: bool = False
    url: Optional[str] = None
    draft: bool = False
    mergeable: Optional[str] = None
    review_decision: str = ""
    comments: int = 0
    additions: int = 0
    deletions: int = 0
    checks: list[dict] = Field(default_factory=list)  # [{name, bucket, url}]
    checks_passed: int = 0
    checks_failed: int = 0
    checks_pending: int = 0
