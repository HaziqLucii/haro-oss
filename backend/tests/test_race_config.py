"""`[race]` config + §0's pre-flight hard gate (backlog/winner-fanout.md §0/§1).

The pre-flight is the check that stands between a project and N× token spend, so it
gets the same treatment as the judge: pure, and tested for what it *refuses*.
"""

from __future__ import annotations

from pathlib import Path

from haro import fanout, race
from haro.config import load_project_settings


def write_settings(tmp_path: Path, body: str) -> str:
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir(parents=True, exist_ok=True)
    (haro_dir / "settings.toml").write_text(body)
    return str(tmp_path)


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
def test_a_project_with_no_race_table_gets_safe_defaults(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, ""))
    assert ps.race_enabled is False          # opt-in: this is the N×-spend feature
    assert ps.race_policy == "cheapest_green"
    assert ps.race_max_lanes == 3
    assert ps.race_min_suite_tests == 10
    assert ps.race_min_impacted_tests == 3
    assert ps.race_max_total_usd == 0.0       # 0 ⇒ derived from lanes × per-run budget
    assert [(l.model, l.effort) for l in ps.race_lanes] == [
        ("sonnet", "low"), ("sonnet", "high"), ("opus", ""),
    ]


def test_lanes_parse_from_an_array_of_tables(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
enabled = true
policy = "first_green"

[[race.lanes]]
model = "haiku"

[[race.lanes]]
model = "opus"
effort = "max"
"""))
    assert ps.race_enabled is True
    assert ps.race_policy == "first_green"
    assert [(l.model, l.effort) for l in ps.race_lanes] == [("haiku", ""), ("opus", "max")]


def test_lanes_also_parse_from_plain_strings(tmp_path, monkeypatch):
    """The array-of-tables form is the one people get wrong by hand, so the shorthand
    `["sonnet", "opus:high"]` is accepted too — a config format nobody can write is a
    feature nobody turns on."""
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
lanes = ["sonnet", "opus:high"]
"""))
    assert [(l.model, l.effort) for l in ps.race_lanes] == [("sonnet", ""), ("opus", "high")]


def test_junk_lanes_fall_back_instead_of_breaking_the_whole_config(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
lanes = [42, {}, ""]
"""))
    assert len(ps.race_lanes) == 3  # the default grid, not an empty list


def test_an_unknown_policy_and_a_silly_max_lanes_are_clamped(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
policy = "whoever_i_like"
max_lanes = 1
min_suite_tests = 0
"""))
    assert ps.race_policy == "cheapest_green"
    assert ps.race_max_lanes == 2   # a 1-lane "race" is just a run
    assert ps.race_min_suite_tests == 1  # 0 would disable the thin-suite check entirely


# --------------------------------------------------------------------------- #
# §0 — preflight
# --------------------------------------------------------------------------- #
def test_never_race_uncapped():
    """Both judges demanded this one: no per-run budget ceiling, no race."""
    pf = race.preflight(
        enabled=True, lane_count=3, max_budget_usd=0.0, max_total_usd=0.0,
        suite_tests=50, min_suite_tests=10,
    )
    assert pf.ok is False
    assert any("uncapped" in r for r in pf.refusals)


def test_a_thin_suite_refuses_the_race_before_anything_is_created():
    pf = race.preflight(
        enabled=True, lane_count=3, max_budget_usd=5.0, max_total_usd=0.0,
        suite_tests=4, min_suite_tests=10,
    )
    assert pf.ok is False
    assert any("too thin to referee" in r for r in pf.refusals)


def test_races_are_off_until_a_project_opts_in():
    pf = race.preflight(
        enabled=False, lane_count=3, max_budget_usd=5.0, max_total_usd=0.0,
        suite_tests=50, min_suite_tests=10,
    )
    assert pf.ok is False
    assert any("races are off" in r for r in pf.refusals)


def test_every_refusal_comes_back_at_once():
    """A misconfigured project usually trips several checks; fixing them one 400 at a
    time is a miserable loop."""
    pf = race.preflight(
        enabled=False, lane_count=1, max_budget_usd=0.0, max_total_usd=0.0,
        suite_tests=2, min_suite_tests=10,
    )
    assert len(pf.refusals) == 4


def test_an_unmeasurable_suite_is_a_note_not_a_refusal():
    """pytest and the generic command adapter have no module graph, so they can't
    report a suite size. Refusing would lock those projects out of the feature
    entirely; the judge-time impacted guard still covers the real risk."""
    pf = race.preflight(
        enabled=True, lane_count=3, max_budget_usd=5.0, max_total_usd=0.0,
        suite_tests=None, min_suite_tests=10,
    )
    assert pf.ok is True
    assert any("can't report a suite size" in n for n in pf.notes)


def test_the_race_ceiling_is_derived_when_nobody_configured_one():
    pf = race.preflight(
        enabled=True, lane_count=3, max_budget_usd=2.0, max_total_usd=0.0,
        suite_tests=50, min_suite_tests=10,
    )
    assert pf.max_total_usd == 6.0  # lanes × the per-run ceiling


def test_an_explicit_race_ceiling_wins_over_the_derived_one():
    pf = race.preflight(
        enabled=True, lane_count=3, max_budget_usd=2.0, max_total_usd=1.5,
        suite_tests=50, min_suite_tests=10,
    )
    assert pf.max_total_usd == 1.5


# --------------------------------------------------------------------------- #
# §1 — lane resolution + the forced gate
# --------------------------------------------------------------------------- #
def test_a_client_lane_override_cannot_widen_the_projects_fleet(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
max_lanes = 2
"""))
    lanes = fanout.resolve_lanes(ps, [{"model": m} for m in ("a", "b", "c", "d", "e")])
    assert [l.model for l in lanes] == ["a", "b"]


def test_a_race_lane_forces_the_strict_gate_whatever_the_project_configured(tmp_path, monkeypatch):
    """Ranking is a comparison, so every lane's green has to mean the same thing:
    the merge result's green, flake-confirmed, full-scope. Note all three overrides
    only ever make a gate *stricter* — that's what keeps this from being a back door."""
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[gate]
merge_result = false
default_scope = "impacted"

[workflow]
flaky_rerun = false
"""))
    forced = fanout.lane_gate_settings(ps)
    assert forced.gate_merge_result is True
    assert forced.flaky_rerun is True
    assert forced.gate_default_scope == "all"
    # The project's own settings object is untouched — the override is per-race.
    assert ps.gate_merge_result is False
    assert ps.flaky_rerun is False


def test_lane_labels_read_the_way_the_scorecard_shows_them(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, ""))
    assert [l.label for l in ps.race_lanes] == ["sonnet-low", "sonnet-high", "opus"]


# --------------------------------------------------------------------------- #
# split_authors (usp-critique-round3.md Move C) — two role-tagged lanes, not a
# ranked grid.
# --------------------------------------------------------------------------- #
def test_split_authors_forces_exactly_two_role_tagged_lanes(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
policy = "split_authors"
max_lanes = 5

[[race.lanes]]
model = "opus"
effort = "high"
"""))
    lanes = fanout.resolve_lanes(ps)
    assert [(l.model, l.effort, l.role) for l in lanes] == [
        ("opus", "high", "tests_only"),
        ("opus", "high", "impl_only"),
    ]


def test_split_authors_with_no_configured_lanes_falls_back_to_sonnet(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[race]
policy = "split_authors"
"""))
    lanes = fanout.resolve_lanes(ps)
    assert [l.role for l in lanes] == ["tests_only", "impl_only"]
    assert all(l.model == "sonnet" for l in lanes)


def test_split_authors_ignores_a_client_lane_override_count():
    # the override still supplies the model, but the COUNT collapses to 2 roles —
    # a client can't accidentally race 5 authorship lanes.
    from haro.config import ProjectSettings

    ps = ProjectSettings(race_policy="split_authors")
    lanes = fanout.resolve_lanes(ps, [{"model": m} for m in ("a", "b", "c")])
    assert [(l.model, l.role) for l in lanes] == [("a", "tests_only"), ("a", "impl_only")]


def test_augment_task_for_role_appends_constraint_only_for_known_roles():
    plain = fanout._augment_task_for_role("add a login form", "")
    assert plain == "add a login form"
    tests_only = fanout._augment_task_for_role("add a login form", "tests_only")
    assert tests_only.startswith("add a login form")
    assert "ONLY test changes" in tests_only
    impl_only = fanout._augment_task_for_role("add a login form", "impl_only")
    assert "ONLY implementation changes" in impl_only


def test_judge_split_authors_ties_both_lanes_with_no_winner():
    from haro.models import RaceLane, RaceRun

    run = RaceRun(
        project_id="p", task="t", policy="split_authors",
        lanes=[
            RaceLane(workspace_id="w1", role="tests_only", status="red"),
            RaceLane(workspace_id="w2", role="impl_only", status="green", green=True),
        ],
    )
    out = fanout._judge_split_authors(run)
    assert out.winner_id is None
    assert set(out.tie) == {"w1", "w2"}
    assert out.refused is None
    assert out.status == "judged"
    assert out.verdict == {"kind": "split_authors", "tests_lane_id": "w1", "impl_lane_id": "w2"}


def test_judge_split_authors_refuses_when_a_role_lane_is_missing():
    from haro.models import RaceLane, RaceRun

    run = RaceRun(
        project_id="p", task="t", policy="split_authors",
        lanes=[RaceLane(workspace_id="w1", role="tests_only", status="red")],
    )
    out = fanout._judge_split_authors(run)
    assert out.winner_id is None
    assert out.refused is not None
    assert out.status == "refused"


def test_split_authors_lane_labels_are_distinguishable():
    # refuter round-3: both lanes get the SAME model/effort, so without the role
    # suffix their workspace names/branches were identical apart from an
    # auto-appended "(2)" — nothing told a human which lane held the tests.
    from haro.config import ProjectSettings

    ps = ProjectSettings(race_policy="split_authors")
    lanes = fanout.resolve_lanes(ps, [{"model": "opus", "effort": "high"}])
    labels = [l.label for l in lanes]
    assert labels == ["opus-high-tests_only", "opus-high-impl_only"]
    assert labels[0] != labels[1]
