"""Winner-only fan-out — the gate stops being a safety rail and becomes a **referee**.

Bet 11 (`backlog/winner-fanout.md`). Best-of-n is herd convergence: every rival races
N attempts and then dumps N diffs on the human, *multiplying* the review bottleneck,
because none of them owns a deterministic local scorer — their only ranker is another
model's opinion. haro refuses to show you N diffs. The same prompt fans out to N
lane configs (sonnet-low / sonnet-high / opus) as sibling workspaces, every lane
resolves to a real merge-blocking gate verdict, and **this module ranks them off gate
facts alone**. You review exactly one candidate plus a scorecard saying why it won.

Pure of IO, exactly like ``trust.py`` and ``merge_queue.py``: everything here reads
plain dataclasses of facts already recorded on a ``TestRun``/``AgentRun`` and returns a
verdict. No git, no store, no subprocess — so "same inputs, same winner, every time"
is a property you can *test*, by constructing lanes in memory with no repo at all.
The IO shell is ``fanout.py`` (seed the lanes, dispatch the agents, watch the budget,
stamp the facts, run the ceremony) and the ``/projects/{id}/races`` endpoints.

Three rules keep the judge honest, and all three are refusals rather than guesses:

* **Never race uncapped** (§0). ``preflight`` refuses to start without a per-run
  ``[agent] max_budget_usd`` and derives a race-level ceiling on top of it. N× token
  spend is the headline risk of this whole feature.
* **A thin suite cannot referee** (§0/§2). "Compiles and passes" is not "good code"
  when the suite is 4 tests wide, so both a pre-flight suite-size check and a
  judge-time impacted-test check *decline to pick* rather than crown a degenerate
  winner. Declining is a first-class outcome here, not an error path.
* **Never fake a winner** (§2). If every lane went green and the policy metric can't
  separate the top two, the answer is "here are both" — the human tie-breaks.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Sequence

#: The ranking policies a project can pick (``[race] policy``). Each names the ONE
#: metric that decides the winner; everything else is only ever a tie-break.
#:   * first_green         — earliest lane to a green gate (latency wins)
#:   * cheapest_green      — least dollars spent for a green (the default; cost is
#:                           the pain this feature is most likely to cause)
#:   * best_coverage_delta — the green that moved line coverage furthest up
#:   * merge_clean         — the green that still merges onto base
#:   * split_authors       — NOT a ranking policy (usp-critique-round3.md Move C):
#:                           two lanes, one tests-only and one impl-only, so no
#:                           single model can write a test that encodes the same
#:                           misreading as the implementation it's judging. There is
#:                           nothing to rank — ``fanout.judge_race`` routes this
#:                           policy around ``judge()`` entirely and records both
#:                           lane ids instead of a winner. Listed here only so
#:                           ``[race] policy = "split_authors"`` validates in config.
POLICIES = ("first_green", "cheapest_green", "best_coverage_delta", "merge_clean", "split_authors")
DEFAULT_POLICY = "cheapest_green"

#: Per-policy indifference band. Two lanes closer than this on the policy metric are
#: NOT meaningfully different, so when every lane is green we present both instead of
#: crowning one by a rounding error. Units follow each metric (seconds / USD / coverage
#: percentage points); ``merge_clean``'s metric is a 0/1 flag, so any two clean lanes
#: are exactly equal — that policy discriminates between clean and conflicting lanes
#: and *honestly says so* when they all merge.
EPSILON = {
    "first_green": 2.0,
    "cheapest_green": 0.01,
    "best_coverage_delta": 0.05,
    "merge_clean": 0.0,
}

#: The default lane grid: the same task at three points on the cost/effort curve.
#: Deliberately not three identical runs — a race between clones only measures
#: sampling noise, while this measures whether the extra spend bought anything.
DEFAULT_LANES = (
    {"model": "sonnet", "effort": "low"},
    {"model": "sonnet", "effort": "high"},
    {"model": "opus", "effort": ""},
)


# --------------------------------------------------------------------------- #
# Inputs
# --------------------------------------------------------------------------- #
@dataclass
class LaneFacts:
    """One lane's gate facts, as the judge sees them.

    Every field is something the gate already recorded (``TestRun``) or the agent run
    already reported (``AgentRun.cost_usd``) — the judge invents no measurement of its
    own. ``fanout.lane_facts`` is the adapter that fills this in from the store.
    """

    workspace_id: str
    name: str = ""
    model: str = ""
    effort: str = ""
    #: Lifecycle of the lane itself: pending | running | green | red | error | stopped.
    #: ``stopped`` is a lane the race-level budget ceiling cut short.
    status: str = "pending"
    #: The gate's verdict, already folded (passed AND not coverage/tamper/merge blocked).
    green: bool = False
    cost_usd: float = 0.0
    wall_ms: Optional[float] = None
    coverage_delta: Optional[float] = None
    merge_conflict: bool = False
    #: Suspected-flaky test names from the forced confirmation re-run (§0). A green
    #: resting on one of these is not a rankable green.
    flaky: Sequence[str] = ()
    #: A check the project asked for could not run (``TestRun.degraded_reasons``).
    degraded: bool = False
    #: ``green*`` findings count. Displayed on the scorecard, NOT a disqualifier yet —
    #: see the "future inputs" note at the bottom of this module.
    tamper_count: int = 0
    #: How many tests the diff provably touches, from ``TestRunnerAdapter.analyze_impact``.
    #: The judge-time thin-suite guard reads this.
    impacted_count: int = 0
    #: Added + removed lines vs base — the last link of the tie-break chain (smaller
    #: diff wins, because a smaller diff is cheaper to review and the human reviews
    #: exactly one).
    diff_lines: int = 0
    finished_at: Optional[float] = None
    #: DORMANT SLOT (§2 "spec the slot, don't build"). The Double Gate's quality lane
    #: (backlog/double-gate.md §1) will stamp a finding count here, and
    #: ``_disqualify`` gains one branch — no other change. ``None`` = not measured, which
    #: must never read as "clean" (the same rule the tamper alarm learned the hard way).
    quality_findings: Optional[int] = None


# --------------------------------------------------------------------------- #
# Outputs
# --------------------------------------------------------------------------- #
@dataclass
class Criterion:
    """One scorecard cell: how this lane did on one axis, and whether it was the best.

    ``won`` is "no sibling did better on this axis" — it is NOT "this is why the race
    was won". ``decisive`` marks the single axis the active policy actually ranked on,
    so the scorecard can say *why it won* rather than leaving the human to infer it
    from five ticks."""

    key: str
    label: str
    value: str
    won: bool = False
    decisive: bool = False

    def to_dict(self) -> dict:
        return {
            "key": self.key, "label": self.label, "value": self.value,
            "won": self.won, "decisive": self.decisive,
        }


@dataclass
class LaneScore:
    """One ranked lane: its identity, its criteria row, and — when it lost — why."""

    workspace_id: str
    name: str
    model: str
    effort: str
    status: str
    rank: Optional[int]  # 1-based among *eligible* lanes; None when disqualified
    eligible: bool
    #: Why this lane can't win. None when it's in the running.
    disqualified: Optional[str] = None
    criteria: list[Criterion] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "workspace_id": self.workspace_id, "name": self.name, "model": self.model,
            "effort": self.effort, "status": self.status, "rank": self.rank,
            "eligible": self.eligible, "disqualified": self.disqualified,
            "criteria": [c.to_dict() for c in self.criteria],
        }


@dataclass
class Ranking:
    """The judge's verdict. Exactly one of three shapes, and the UI must render all
    three — the *refusals* are the feature, not a degraded path:

    * ``winner_id`` set — one candidate to review, ``reason`` says why it won.
    * ``tie`` non-empty — every lane went green and the metric can't separate the top
      two; both are shown side-by-side and a human picks.
    * ``refused`` set — the judge declined to rank at all (a suite too thin to referee
      with). Every lane is shown; nothing is hidden behind a fake verdict.
    """

    policy: str
    winner_id: Optional[str] = None
    tie: list[str] = field(default_factory=list)
    refused: Optional[str] = None
    reason: str = ""
    lanes: list[LaneScore] = field(default_factory=list)

    @property
    def decided(self) -> bool:
        return self.winner_id is not None

    def to_dict(self) -> dict:
        return {
            "policy": self.policy, "winner_id": self.winner_id, "tie": list(self.tie),
            "refused": self.refused, "reason": self.reason,
            "lanes": [l.to_dict() for l in self.lanes],
        }


# --------------------------------------------------------------------------- #
# §0 — preconditions (refuse to race without them)
# --------------------------------------------------------------------------- #
@dataclass
class Preflight:
    """Whether this project may start a race at all, and under what ceiling.

    ``refusals`` is a list because a misconfigured project usually trips more than one
    check, and fixing them one 400 at a time is a miserable loop."""

    ok: bool
    refusals: list[str] = field(default_factory=list)
    #: The race-level dollar ceiling actually in force (never 0 when ``ok``).
    max_total_usd: float = 0.0
    #: Warnings that don't stop the race but change what the ceremony may claim.
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "ok": self.ok, "refusals": list(self.refusals),
            "max_total_usd": self.max_total_usd, "notes": list(self.notes),
        }


def preflight(
    *,
    enabled: bool,
    lane_count: int,
    max_budget_usd: float,
    max_total_usd: float,
    suite_tests: Optional[int],
    min_suite_tests: int,
) -> Preflight:
    """§0's hard gate, as a pure decision.

    ``suite_tests`` is the base_ref suite size from ``analyze_impact`` — ``None`` when
    the runner can't report one (no module graph). An unknown suite size is NOT a
    refusal: a pytest/command project would never be able to race, and the judge-time
    impacted-test guard still catches a degenerate ranking later. It's a note instead.

    ``max_total_usd`` of 0 means "derive it": lanes × the per-run ceiling, i.e. the
    worst case if every lane spends its full budget. So the race ceiling exists whether
    or not anyone configured one, which is the whole point of the check.
    """
    refusals: list[str] = []
    notes: list[str] = []

    if not enabled:
        refusals.append(
            "races are off for this project: set `[race] enabled = true` in .haro/settings.toml"
        )
    if lane_count < 2:
        refusals.append("a race needs at least 2 lanes")
    if max_budget_usd <= 0:
        # The judges' non-negotiable. An uncapped single run is a survivable mistake;
        # N uncapped runs of the same prompt is the failure mode this feature is most
        # likely to be remembered for.
        refusals.append(
            "never race uncapped: set `[agent] max_budget_usd` above 0 before racing "
            "(N lanes multiply every run's spend)"
        )
    if suite_tests is None:
        notes.append(
            "this runner can't report a suite size, so the pre-flight thin-suite check "
            "was skipped: the judge still declines to rank lanes with too few impacted tests"
        )
    elif suite_tests < min_suite_tests:
        refusals.append(
            f"suite is too thin to referee with: {suite_tests} test(s) at base, "
            f"below `[race] min_suite_tests` ({min_suite_tests}). "
            "Compiles-and-passes isn't good code on a weak suite — run plain parallel "
            "workspaces and review them yourself instead"
        )

    ceiling = max_total_usd if max_total_usd > 0 else lane_count * max(0.0, max_budget_usd)
    return Preflight(
        ok=not refusals, refusals=refusals, max_total_usd=round(ceiling, 4), notes=notes
    )


# --------------------------------------------------------------------------- #
# §2 — the judge
# --------------------------------------------------------------------------- #
def _disqualify(lane: LaneFacts) -> Optional[str]:
    """Why this lane can't be crowned — ``None`` when it's rankable.

    Ordered most-fundamental first so the reason a human reads is the root cause, not
    a symptom. Everything here is a *fact the gate recorded*, never a judgement: the
    judge's whole claim to legitimacy is that it adds no opinion of its own."""
    if not lane.green:
        return f"gate not green ({lane.status})"
    if lane.merge_conflict:
        return "won't merge onto base"
    if lane.degraded:
        # backlog/double-gate.md §0: a green where an enabled check silently no-opped
        # vouches for less than it looks like it does. Ranking one first would make the
        # race a laundering machine for exactly that.
        return "degraded: a check the project asked for could not run"
    if list(lane.flaky):
        # §0: races force the confirmation re-run precisely so this is *visible*. A
        # green that only happened because a flake passed the second time is not a
        # verdict you can rank against another lane's.
        return f"green rests on {len(list(lane.flaky))} suspected-flaky test(s)"
    return None


def _metric(lane: LaneFacts, policy: str) -> float:
    """The policy's ranking metric, normalized so **lower is always better**.

    A missing measurement sorts last rather than first: no number is strictly less
    information than a bad number, so it must never win by default."""
    if policy == "first_green":
        return lane.finished_at if lane.finished_at is not None else float("inf")
    if policy == "best_coverage_delta":
        return -lane.coverage_delta if lane.coverage_delta is not None else float("inf")
    if policy == "merge_clean":
        return 1.0 if lane.merge_conflict else 0.0
    return lane.cost_usd  # cheapest_green (the default)


def _sort_key(lane: LaneFacts, policy: str) -> tuple:
    """Policy metric first, then the fixed tie-break chain: cost → wall time → diff
    size → workspace id.

    The trailing id is not arbitrary decoration — without it two lanes identical on
    every measured axis would order by whatever the input list happened to be, and the
    promise this feature sells is "same inputs, same winner, every time"."""
    return (
        _metric(lane, policy),
        lane.cost_usd,
        lane.wall_ms if lane.wall_ms is not None else float("inf"),
        lane.diff_lines,
        lane.workspace_id,
    )


def _fmt_cost(v: float) -> str:
    return f"${v:.2f}" if v else "$0.00"


def _fmt_wall(ms: Optional[float]) -> str:
    if ms is None:
        return "—"
    return f"{ms / 1000:.1f}s" if ms < 60_000 else f"{ms / 60_000:.1f}m"


def _fmt_cov(d: Optional[float]) -> str:
    return "not measured" if d is None else f"{d:+.2f}%"


def _criteria(lane: LaneFacts, lanes: Sequence[LaneFacts], policy: str) -> list[Criterion]:
    """The scorecard row for one lane: five axes, each marked won/lost against its
    siblings, with the policy's own axis flagged ``decisive``.

    "Won" is computed over ALL lanes, not just eligible ones, so a disqualified lane
    that was genuinely cheapest still shows as cheapest — the scorecard's job is to let
    a human second-guess the judge, which it can't do if the losing rows are censored."""
    cheapest = min((l.cost_usd for l in lanes), default=0.0)
    fastest = min((l.wall_ms for l in lanes if l.wall_ms is not None), default=None)
    best_cov = max((l.coverage_delta for l in lanes if l.coverage_delta is not None), default=None)
    return [
        Criterion(
            key="verdict", label="verdict",
            value=("green*" if lane.green and lane.tamper_count else ("green" if lane.green else lane.status)),
            won=lane.green and not lane.tamper_count,
            decisive=False,
        ),
        Criterion(
            key="cost", label="cost", value=_fmt_cost(lane.cost_usd),
            won=lane.cost_usd <= cheapest, decisive=policy == "cheapest_green",
        ),
        Criterion(
            key="wall", label="wall time", value=_fmt_wall(lane.wall_ms),
            won=fastest is not None and lane.wall_ms == fastest,
            decisive=policy == "first_green",
        ),
        Criterion(
            key="coverage", label="coverage Δ", value=_fmt_cov(lane.coverage_delta),
            won=best_cov is not None and lane.coverage_delta == best_cov,
            decisive=policy == "best_coverage_delta",
        ),
        Criterion(
            key="merge_clean", label="merge-clean",
            value="conflicts" if lane.merge_conflict else ("clean" if lane.green else "—"),
            won=lane.green and not lane.merge_conflict,
            decisive=policy == "merge_clean",
        ),
    ]


def _win_reason(top: LaneFacts, runner_up: Optional[LaneFacts], policy: str) -> str:
    """One sentence naming the axis that decided it — the scorecard's headline."""
    if policy == "first_green":
        return (
            f"first to green ({_fmt_wall(top.wall_ms)})"
            + (f", ahead of {runner_up.name}" if runner_up else "")
        )
    if policy == "best_coverage_delta":
        return (
            f"best coverage delta ({_fmt_cov(top.coverage_delta)})"
            + (f" vs {_fmt_cov(runner_up.coverage_delta)}" if runner_up else "")
        )
    if policy == "merge_clean":
        return "green and merges cleanly onto base" + (
            f"; {runner_up.name} does not" if runner_up and runner_up.merge_conflict else ""
        )
    return (
        f"cheapest green ({_fmt_cost(top.cost_usd)})"
        + (f" vs {_fmt_cost(runner_up.cost_usd)}" if runner_up else "")
    )


def judge(
    lanes: Sequence[LaneFacts],
    *,
    policy: str = DEFAULT_POLICY,
    min_impacted_tests: int = 3,
    epsilon: Optional[float] = None,
) -> Ranking:
    """Rank finished lanes and pick at most one winner. Pure; deterministic.

    The order of the three refusals below is deliberate — each one is a *stronger*
    claim than the next, so we make the weakest claim we can:

    1. **Thin impact ⇒ don't rank.** If a green lane's diff provably touches fewer than
       ``min_impacted_tests`` tests, the gate barely looked at the work, so ranking on
       its verdict would crown noise. Degrade honestly to "all lanes shown, you pick".
    2. **Nothing green ⇒ no winner.** Not a refusal to judge; there is simply nothing
       to crown. The scorecard still explains every lane's failure.
    3. **All green and inseparable ⇒ tie.** Present the top two side-by-side.

    Only past all three does a winner get named.
    """
    policy = policy if policy in POLICIES else DEFAULT_POLICY
    eps = EPSILON.get(policy, 0.0) if epsilon is None else abs(epsilon)
    lanes = list(lanes)

    dq = {l.workspace_id: _disqualify(l) for l in lanes}
    eligible = sorted((l for l in lanes if dq[l.workspace_id] is None), key=lambda l: _sort_key(l, policy))

    def scores(order: Sequence[LaneFacts]) -> list[LaneScore]:
        rank_of = {l.workspace_id: i + 1 for i, l in enumerate(order)}
        return [
            LaneScore(
                workspace_id=l.workspace_id, name=l.name, model=l.model, effort=l.effort,
                status=l.status, rank=rank_of.get(l.workspace_id), eligible=dq[l.workspace_id] is None,
                disqualified=dq[l.workspace_id], criteria=_criteria(l, lanes, policy),
            )
            for l in lanes
        ]

    # (1) Judge-time thin-suite guard. Checked BEFORE picking, because a ranking
    # published and then retracted is worse than one never made.
    thin = [l for l in eligible if l.impacted_count < min_impacted_tests]
    if thin:
        names = ", ".join(f"{l.name} ({l.impacted_count})" for l in thin)
        return Ranking(
            policy=policy,
            refused=(
                f"not auto-judging: {names} — fewer than {min_impacted_tests} impacted "
                "tests, so a green says almost nothing about the work. All lanes are "
                "shown; you pick."
            ),
            reason="the suite is too thin here for the gate to referee",
            lanes=scores(eligible),
        )

    # (2) Nothing to crown.
    if not eligible:
        return Ranking(
            policy=policy,
            reason="no lane produced a rankable green — every candidate is shown with its reason",
            lanes=scores(eligible),
        )

    top = eligible[0]
    runner_up = eligible[1] if len(eligible) > 1 else None

    # (3) Honest tie: every lane went green AND the metric can't separate the top two.
    # Note the condition is "all lanes green", not "all eligible lanes" — a race where
    # one lane failed has genuinely told us something, and the tie-break chain is then
    # allowed to settle the remainder.
    all_green = bool(lanes) and all(l.green for l in lanes)
    if all_green and runner_up is not None:
        gap = abs(_metric(top, policy) - _metric(runner_up, policy))
        if gap <= eps:
            return Ranking(
                policy=policy,
                tie=[top.workspace_id, runner_up.workspace_id],
                reason=(
                    f"all {len(lanes)} lanes went green and {policy.replace('_', ' ')} "
                    "can't separate the top two — here are both, you tie-break"
                ),
                lanes=scores(eligible),
            )

    return Ranking(
        policy=policy,
        winner_id=top.workspace_id,
        reason=_win_reason(top, runner_up, policy),
        lanes=scores(eligible),
    )


# --------------------------------------------------------------------------- #
# Future ranking inputs — the slot is specced, deliberately not built (§2)
# --------------------------------------------------------------------------- #
# Two signals belong in ``_disqualify`` and are held back on purpose:
#
#   * **quality-lane findings** (backlog/double-gate.md §1) — ``LaneFacts.quality_findings``
#     already carries the shape (``None`` = not measured, ``0`` = clean, ``>0`` = findings).
#     When the quality gate ships a fact to read, this becomes one branch here and one
#     criterion in ``_criteria``; nothing else changes. Exactly the dormant-key pattern
#     ``trust.py`` uses for its ``quality`` condition.
#   * **tamper cleanliness as a disqualifier** — ``tamper_count`` is *displayed* today
#     (a winning lane renders ``green*``) but does not disqualify, because turning it into
#     one silently changes what a race means before we have dogfood data on how often a
#     ``green*`` lane is actually the best work. Promoting it is a one-line change here;
#     leaving it visible-but-not-load-bearing is what lets a human catch it meanwhile.
