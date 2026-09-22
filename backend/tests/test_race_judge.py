"""The winner-only fan-out judge (`race.py`, backlog/winner-fanout.md §2).

The whole feature rests on one claim — *the gate ranked them, not a model's opinion* —
so these tests pin the three things that claim needs to survive contact with reality:
determinism (same inputs, same winner), the disqualifiers (a green that shouldn't count
doesn't), and the two refusals (a thin suite and an honest tie produce NO winner rather
than a plausible one).

Pure-function tests: no repo, no store, no worktrees. That's the point of `race.py`
being IO-free — if any of this needed a fixture, the judge would have grown a
dependency it isn't allowed to have.
"""

from __future__ import annotations

from haro import race


def lane(ws_id: str, **kw) -> race.LaneFacts:
    """A green, rankable lane with enough impacted tests to clear the thin-suite guard.
    Every test overrides only the field it's actually about."""
    base = dict(
        name=ws_id, model="sonnet", effort="low", status="green", green=True,
        cost_usd=1.0, wall_ms=10_000.0, coverage_delta=0.0, impacted_count=10,
        diff_lines=100, finished_at=1000.0,
    )
    base.update(kw)
    return race.LaneFacts(workspace_id=ws_id, **base)


# --------------------------------------------------------------------------- #
# Policies
# --------------------------------------------------------------------------- #
def test_cheapest_green_picks_the_cheapest_lane():
    r = race.judge(
        [lane("a", cost_usd=3.0), lane("b", cost_usd=0.5), lane("c", cost_usd=1.5)],
        policy="cheapest_green",
    )
    assert r.winner_id == "b"
    assert "cheapest green" in r.reason


def test_first_green_picks_the_earliest_finisher():
    r = race.judge(
        [lane("a", finished_at=300.0), lane("b", finished_at=100.0)],
        policy="first_green",
    )
    assert r.winner_id == "b"


def test_best_coverage_delta_picks_the_biggest_rise():
    r = race.judge(
        [lane("a", coverage_delta=0.4), lane("b", coverage_delta=2.1)],
        policy="best_coverage_delta",
    )
    assert r.winner_id == "b"


def test_an_unmeasured_metric_never_wins_by_default():
    """No number is strictly *less* information than a bad number, so a lane with no
    coverage measurement must sort last — not first, which is what a naive
    `None`-sorts-low comparison would do."""
    r = race.judge(
        [lane("a", coverage_delta=None), lane("b", coverage_delta=-1.0)],
        policy="best_coverage_delta",
    )
    assert r.winner_id == "b"


def test_an_unknown_policy_falls_back_to_the_default():
    r = race.judge([lane("a", cost_usd=2.0), lane("b", cost_usd=1.0)], policy="vibes")
    assert r.policy == race.DEFAULT_POLICY
    assert r.winner_id == "b"


# --------------------------------------------------------------------------- #
# Determinism
# --------------------------------------------------------------------------- #
def test_same_inputs_same_winner_regardless_of_input_order():
    """The product promise in one test. Two lanes identical on every measured axis
    must not resolve by list order — that's what the trailing workspace-id tie-break
    in `_sort_key` is for."""
    a, b, c = lane("a"), lane("b"), lane("c")
    # Not all green, so the honest-tie path is off and the tie-break chain must decide.
    d = lane("d", green=False, status="red")
    first = race.judge([a, b, c, d]).winner_id
    second = race.judge([d, c, b, a]).winner_id
    third = race.judge([c, a, d, b]).winner_id
    assert first == second == third == "a"


def test_the_tie_break_chain_runs_cost_then_wall_then_diff():
    red = lane("red", green=False, status="red")  # keeps the honest-tie path off
    same_cost = [
        lane("slow-small", cost_usd=1.0, wall_ms=99_000.0, diff_lines=10),
        lane("fast-big", cost_usd=1.0, wall_ms=1_000.0, diff_lines=900),
        red,
    ]
    # Cost ties → wall time decides.
    assert race.judge(same_cost).winner_id == "fast-big"

    same_cost_and_wall = [
        lane("big", cost_usd=1.0, wall_ms=5_000.0, diff_lines=900),
        lane("small", cost_usd=1.0, wall_ms=5_000.0, diff_lines=10),
        red,
    ]
    # Cost AND wall tie → the smaller diff wins (the human reviews exactly one).
    assert race.judge(same_cost_and_wall).winner_id == "small"


# --------------------------------------------------------------------------- #
# Disqualifiers
# --------------------------------------------------------------------------- #
def test_a_red_lane_cannot_win_even_when_cheapest():
    r = race.judge([lane("cheap-red", cost_usd=0.1, green=False, status="red"), lane("green")])
    assert r.winner_id == "green"
    dq = {l.workspace_id: l.disqualified for l in r.lanes}
    assert "gate not green" in dq["cheap-red"]


def test_a_flaky_green_is_not_rankable():
    """§0 forces the flaky confirmation re-run precisely so this is visible. A green
    that only happened because a flake passed the second time is a coin toss, not a
    verdict you can rank another lane against."""
    r = race.judge([lane("flaky", cost_usd=0.1, flaky=["renders eventually"]), lane("solid")])
    assert r.winner_id == "solid"
    dq = {l.workspace_id: l.disqualified for l in r.lanes}
    assert "suspected-flaky" in dq["flaky"]


def test_a_degraded_green_is_not_rankable():
    r = race.judge([lane("degraded", cost_usd=0.1, degraded=True), lane("clean")])
    assert r.winner_id == "clean"
    dq = {l.workspace_id: l.disqualified for l in r.lanes}
    assert "degraded" in dq["degraded"]


def test_a_merge_conflicting_lane_is_not_rankable():
    r = race.judge([lane("conflicted", cost_usd=0.1, merge_conflict=True), lane("mergeable")])
    assert r.winner_id == "mergeable"


def test_no_green_lane_means_no_winner_but_every_lane_still_reports():
    r = race.judge([lane("a", green=False, status="red"), lane("b", green=False, status="error")])
    assert r.winner_id is None
    assert r.refused is None  # nothing to crown is not the same as declining to judge
    assert len(r.lanes) == 2
    assert all(l.disqualified for l in r.lanes)


def test_a_tampered_green_is_shown_but_still_eligible():
    """`green*` is displayed, deliberately NOT a disqualifier yet (§2 "spec the slot,
    don't build"). Promoting it silently would change what a race means before there's
    dogfood data on how often a `green*` lane is the best work."""
    r = race.judge([lane("starred", cost_usd=0.1, tamper_count=2), lane("plain")])
    assert r.winner_id == "starred"
    verdicts = {
        l.workspace_id: next(c for c in l.criteria if c.key == "verdict") for l in r.lanes
    }
    assert verdicts["starred"].value == "green*"
    assert verdicts["starred"].won is False  # visibly worse on the verdict axis
    assert verdicts["plain"].won is True


# --------------------------------------------------------------------------- #
# Refusals
# --------------------------------------------------------------------------- #
def test_a_thin_impact_refuses_to_auto_judge():
    """The named judge concern: on a weak suite, "it compiles and passes" is not
    evidence of good code, so the judge declines rather than crowning noise."""
    r = race.judge([lane("a", impacted_count=1), lane("b", impacted_count=8)], min_impacted_tests=3)
    assert r.winner_id is None
    assert r.refused is not None
    assert "impacted tests" in r.refused
    assert "a (1)" in r.refused          # names WHICH lane was too thin
    assert len(r.lanes) == 2              # all lanes shown — you pick


def test_a_thin_lane_that_is_already_disqualified_does_not_trigger_the_refusal():
    """The guard is about lanes that could otherwise WIN. A red lane's impact count is
    irrelevant, and letting it force the refusal would make the feature unusable on any
    project where one lane happens to fail."""
    r = race.judge(
        [lane("red-thin", green=False, status="red", impacted_count=0), lane("b", impacted_count=8)],
        min_impacted_tests=3,
    )
    assert r.refused is None
    assert r.winner_id == "b"


def test_all_green_and_inseparable_is_an_honest_tie_not_a_winner():
    r = race.judge([lane("a", cost_usd=1.0), lane("b", cost_usd=1.004)], policy="cheapest_green")
    assert r.winner_id is None
    assert r.tie == ["a", "b"]
    assert "can't separate" in r.reason


def test_a_gap_wider_than_epsilon_still_names_a_winner():
    r = race.judge([lane("a", cost_usd=1.0), lane("b", cost_usd=5.0)], policy="cheapest_green")
    assert r.winner_id == "a"
    assert r.tie == []


def test_one_failed_lane_switches_the_tie_off_and_lets_the_chain_decide():
    """"All lanes green" is the honest-tie condition. When a lane genuinely failed, the
    race HAS told us something, so the deterministic chain is allowed to settle the
    rest instead of punting to the human."""
    r = race.judge(
        [lane("a", cost_usd=1.0), lane("b", cost_usd=1.004), lane("c", green=False, status="red")],
        policy="cheapest_green",
    )
    assert r.tie == []
    assert r.winner_id == "a"


def test_merge_clean_ties_when_every_lane_merges():
    """merge_clean discriminates between clean and conflicting lanes. When they all
    merge it cannot discriminate at all — and says so, rather than quietly falling
    through to a cost tie-break the user never asked for."""
    r = race.judge([lane("a"), lane("b", cost_usd=0.1)], policy="merge_clean")
    assert r.winner_id is None
    assert r.tie == ["b", "a"]  # ordered by the tie-break chain, still deterministic


# --------------------------------------------------------------------------- #
# Scorecard shape
# --------------------------------------------------------------------------- #
def test_every_lane_gets_a_full_criteria_row_including_the_losers():
    """The scorecard exists so a human can second-guess the judge. It can't do that if
    the losing rows are censored, so criteria are computed for disqualified lanes too."""
    r = race.judge([lane("a", cost_usd=0.5), lane("b", green=False, status="red", cost_usd=9.0)])
    keys = {l.workspace_id: [c.key for c in l.criteria] for l in r.lanes}
    assert keys["a"] == keys["b"] == ["verdict", "cost", "wall", "coverage", "merge_clean"]


def test_the_policys_own_axis_is_marked_decisive():
    r = race.judge([lane("a", cost_usd=1.0), lane("b", cost_usd=9.0)], policy="cheapest_green")
    decisive = [c.key for l in r.lanes for c in l.criteria if c.decisive]
    assert set(decisive) == {"cost"}


def test_a_disqualified_lane_can_still_show_as_best_on_an_axis():
    """A red lane that WAS the cheapest still reads as cheapest — otherwise the
    scorecard hides the very trade-off the human is being asked to sanity-check."""
    r = race.judge([lane("green", cost_usd=5.0), lane("red", green=False, status="red", cost_usd=0.1)])
    red = next(l for l in r.lanes if l.workspace_id == "red")
    cost = next(c for c in red.criteria if c.key == "cost")
    assert cost.won is True
    assert red.eligible is False


def test_ranking_round_trips_to_a_plain_dict():
    """`RaceRun.verdict` stores this blob, so it has to be JSON-safe all the way down."""
    import json

    r = race.judge([lane("a"), lane("b", green=False, status="red")])
    blob = json.loads(json.dumps(r.to_dict()))
    assert blob["winner_id"] == "a"
    assert blob["lanes"][0]["criteria"][0]["key"] == "verdict"


def test_an_empty_race_does_not_crash():
    r = race.judge([])
    assert r.winner_id is None
    assert r.lanes == []
