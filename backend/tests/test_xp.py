"""XP maths and rules (xp.py): pure, so every clock here is fixed.

The rules are the product decision, so each one is pinned: the once-per-day cap, the
once-per-workspace merge, the empty diff, red never paying, the mode split, the caps, the
badges, the streak's local-day boundaries and the rank ladder."""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from haro import xp
from haro.models import XpEvent

UTC = timezone.utc
NY = ZoneInfo("America/New_York")


@pytest.fixture(autouse=True)
def _utc_machine(monkeypatch):
    """The default clock is the machine's local zone: pin it so the suite passes anywhere."""
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def ts(y, m, d, hh=12, mm=0, tz=UTC) -> float:
    return datetime(y, m, d, hh, mm, tzinfo=tz).timestamp()


def act(kind, mode, at, ws="w1"):
    return xp.Activity(kind=kind, mode=mode, at=at, workspace_id=ws)


def facts(**kw) -> xp.MergeFacts:
    base = dict(workspace_id="w1", mode="manual", at=ts(2026, 9, 30), by_hand=True,
                changed_files=["src/a.js"], green=True)
    base.update(kw)
    return xp.MergeFacts(**base)


def ledger(awards, at=0.0, mode="manual", ws="w1", by_hand=False):
    return xp.to_events(awards, at=at, mode=mode, workspace_id=ws, by_hand=by_hand)


def amounts(awards):
    return {a.kind: a.amount for a in awards}


# -- the table ----------------------------------------------------------------------- #
def test_rules_table_matches_the_spec():
    by = {r.kind: r for r in xp.RULES}
    assert (by["docs_read"].manual, by["docs_read"].agent) == (10, 2)
    assert (by["plan_made"].manual, by["plan_made"].agent) == (10, 2)
    assert (by["research"].manual, by["research"].agent) == (5, 1)
    assert (by["gate_run"].manual, by["gate_run"].agent) == (5, 1)
    assert (by["diff_reviewed"].manual, by["diff_reviewed"].agent) == (3, 5)
    assert (by["merge_green"].manual, by["merge_green"].agent) == (20, 10)
    assert (by["eyes_resolved"].manual, by["eyes_resolved"].agent, by["eyes_resolved"].cap) == (10, 5, 5)
    assert (by["review_bonus"].manual, by["review_bonus"].agent) == (None, 15)
    assert (by["hand_test"].manual, by["hand_test"].agent) == (None, 10)
    assert (by["red_to_green"].manual, by["red_to_green"].agent) == (120, None)
    assert (by["test_first"].manual, by["test_first"].agent) == (30, None)
    assert {r.kind for r in xp.RULES if r.group == "badge"} == {
        "first_by_hand", "regression_hunter"}


def test_rules_payload_serves_the_same_table():
    p = xp.rules_payload()
    assert [r.kind for r in p.rules] == [r.kind for r in xp.RULES]
    assert p.level_xp == 180
    assert [(r.name, r.at) for r in p.ranks] == [
        ("Novice", 0), ("Journeyman", 800), ("Craftsman", 2000), ("Master", 4000)]


def test_no_rule_text_has_kanji_or_em_dash():
    for r in xp.RULES:
        for s in (r.label, r.text):
            assert chr(0x2014) not in s
            assert all(ord(c) < 0x3000 for c in s)


# -- activity: once per kind per local day ------------------------------------------ #
def test_activity_pays_the_mode_number():
    assert amounts(xp.award_for(act("docs_read", "manual", ts(2026, 9, 30)), [])) == {"docs_read": 10}
    assert amounts(xp.award_for(act("docs_read", "agent", ts(2026, 9, 30)), [])) == {"docs_read": 2}
    assert amounts(xp.award_for(act("diff_reviewed", "agent", ts(2026, 9, 30)), [])) == {"diff_reviewed": 5}
    assert amounts(xp.award_for(act("diff_reviewed", "manual", ts(2026, 9, 30)), [])) == {"diff_reviewed": 3}


def test_activity_pays_once_per_kind_per_day():
    first = xp.award_for(act("research", "manual", ts(2026, 9, 30, 9)), [])
    hist = ledger(first, at=ts(2026, 9, 30, 9))
    assert xp.award_for(act("research", "manual", ts(2026, 9, 30, 20)), hist) == []
    # a different kind the same day still pays
    assert xp.award_for(act("plan_made", "manual", ts(2026, 9, 30, 20)), hist) != []
    # the next day pays again
    assert xp.award_for(act("research", "manual", ts(2026, 10, 1, 9)), hist) != []


def test_activity_day_boundary_is_the_local_midnight():
    hist = ledger(xp.award_for(act("gate_run", "manual", ts(2026, 9, 30, 23, 30, NY)), []),
                  at=ts(2026, 9, 30, 23, 30, NY))
    # 30 minutes later is past local midnight: a new day, even though it is the same UTC day
    later = ts(2026, 10, 1, 0, 5, NY)
    assert xp.award_for(act("gate_run", "manual", later), hist, tz=NY) != []
    # but two events inside one local day are capped
    same = ts(2026, 9, 30, 8, 0, NY)
    assert xp.award_for(act("gate_run", "manual", same), hist, tz=NY) == []


def test_activity_day_survives_a_dst_change():
    # US spring forward 2026-03-08 makes that a 23 hour day: date arithmetic, not 24h spans
    hist = ledger([xp.Award("research", 5, "x")], at=ts(2026, 3, 7, 23, 50, NY))
    assert xp.award_for(act("research", "manual", ts(2026, 3, 8, 0, 10, NY)), hist, tz=NY) != []
    hist2 = ledger([xp.Award("research", 5, "x")], at=ts(2026, 3, 8, 0, 10, NY))
    assert xp.award_for(act("research", "manual", ts(2026, 3, 8, 23, 50, NY)), hist2, tz=NY) == []


def test_diff_review_pays_once_per_workspace_even_on_another_day():
    hist = ledger([xp.Award("diff_reviewed", 3, "x")], at=ts(2026, 9, 29), ws="w1")
    assert xp.award_for(act("diff_reviewed", "manual", ts(2026, 9, 30), ws="w1"), hist) == []
    assert xp.award_for(act("diff_reviewed", "manual", ts(2026, 9, 30), ws="w2"), hist) != []


def test_unknown_or_merge_kinds_are_not_activities():
    assert xp.award_for(act("merge_green", "manual", ts(2026, 9, 30)), []) == []
    assert xp.award_for(act("nonsense", "manual", ts(2026, 9, 30)), []) == []


# -- merge ---------------------------------------------------------------------------- #
def test_by_hand_merge_pays_the_manual_number_and_anything_else_the_agent_number():
    assert amounts(xp.award_for(facts(), [])).get("merge_green") == 20
    assert amounts(xp.award_for(facts(mode="agent", by_hand=False), [])).get("merge_green") == 10
    # manual at merge time but not by hand the whole way (flipped, or switched and back)
    assert amounts(xp.award_for(facts(mode="manual", by_hand=False), [])).get("merge_green") == 10


def test_flipped_workspace_gets_agent_rates_agent_bonuses_and_no_manual_award_or_badge():
    flipped = facts(
        mode="manual", by_hand=False, eyes=5, reviewed_all=True, hand_test=True,
        red_to_green=True, start_from_test_ok=True, regression_search=True,
    )
    awards = xp.award_for(flipped, [])
    assert amounts(awards) == {
        "merge_green": 10, "eyes_resolved": 25, "review_bonus": 15, "hand_test": 10}
    assert not [a for a in awards if a.badge]


def test_a_by_hand_merge_still_pays_every_manual_award():
    awards = xp.award_for(
        facts(eyes=5, red_to_green=True, start_from_test_ok=True,
              regression_search=True), [])
    assert amounts(awards) == {
        "merge_green": 20, "eyes_resolved": 50, "red_to_green": 120,
        "test_first": 30, "first_by_hand": 0, "regression_hunter": 0}


def test_red_and_blocked_never_pay():
    assert xp.award_for(facts(green=False), []) == []


def test_empty_diff_pays_nothing():
    assert xp.award_for(facts(changed_files=[]), []) == []


def test_merge_pays_once_per_workspace():
    first = xp.award_for(facts(), [])
    hist = ledger(first, ws="w1")
    assert xp.award_for(facts(), hist) == []
    assert "merge_green" in amounts(xp.award_for(facts(workspace_id="w2"), hist))


def test_eyes_scale_and_cap():
    assert amounts(xp.award_for(facts(eyes=2), []))["eyes_resolved"] == 20
    assert amounts(xp.award_for(facts(eyes=5), []))["eyes_resolved"] == 50
    assert amounts(xp.award_for(facts(eyes=9), []))["eyes_resolved"] == 50
    assert amounts(xp.award_for(facts(mode="agent", by_hand=False, eyes=9), []))["eyes_resolved"] == 25
    assert "eyes_resolved" not in amounts(xp.award_for(facts(eyes=0), []))


def test_agent_only_bonuses():
    a = amounts(xp.award_for(facts(mode="agent", by_hand=False, reviewed_all=True, hand_test=True), []))
    assert a["review_bonus"] == 15 and a["hand_test"] == 10
    m = amounts(xp.award_for(facts(reviewed_all=True, hand_test=True), []))
    assert "review_bonus" not in m and "hand_test" not in m


def test_manual_only_bonuses():
    m = amounts(xp.award_for(facts(red_to_green=True, start_from_test_ok=True), []))
    assert m["red_to_green"] == 120 and m["test_first"] == 30
    a = amounts(xp.award_for(
        facts(mode="agent", by_hand=False, red_to_green=True,
              start_from_test_ok=True), []))
    assert not {"red_to_green", "test_first"} & a.keys()


def test_full_manual_merge_total():
    awards = xp.award_for(facts(eyes=3, red_to_green=True), [])
    assert sum(a.amount for a in awards) == 20 + 30 + 120


# -- badges --------------------------------------------------------------------------- #
def test_first_by_hand_badge_once_ever():
    first = xp.award_for(facts(), [])
    assert [a.kind for a in first if a.badge] == ["first_by_hand"]
    hist = ledger(first, by_hand=True)
    second = xp.award_for(facts(workspace_id="w2"), hist)
    assert not [a for a in second if a.badge]


def test_no_hand_badge_for_a_switched_workspace():
    assert not [a for a in xp.award_for(facts(by_hand=False), []) if a.badge]


def test_first_by_hand_and_regression_hunter():
    a = xp.award_for(facts(regression_search=True), [])
    assert {x.kind for x in a if x.badge} == {"first_by_hand", "regression_hunter"}
    hist = ledger(a)
    b = xp.award_for(facts(workspace_id="w2", regression_search=True), hist)
    assert not [x for x in b if x.badge]


def test_regression_hunter_is_manual_only():
    a = xp.award_for(facts(mode="agent", by_hand=False, regression_search=True), [])
    assert not [x for x in a if x.badge]


def test_badges_carry_no_xp():
    a = xp.award_for(facts(), [])
    assert all(x.amount == 0 for x in a if x.badge)
    assert xp.total_xp(ledger(a)) == 20


# -- rank, level, status ------------------------------------------------------------- #
def test_level_is_a_floor_of_xp_over_180():
    assert [xp.level_for(n) for n in (0, 179, 180, 359, 360, 1240)] == [1, 1, 2, 2, 3, 7]


def test_rank_thresholds():
    assert xp.rank_for(0) == ("Novice", 0, 800)
    assert xp.rank_for(799) == ("Novice", 0, 800)
    assert xp.rank_for(800) == ("Journeyman", 800, 2000)
    assert xp.rank_for(1999)[0] == "Journeyman"
    assert xp.rank_for(2000) == ("Craftsman", 2000, 4000)
    assert xp.rank_for(4000) == ("Master", 4000, None)
    assert xp.rank_for(99999) == ("Master", 4000, None)


def test_summary_line_lists_paid_labels_only():
    a = xp.award_for(facts(eyes=1), [])
    line = xp.summary_line(a)
    assert line == "XP: +30 (merged on green, resolved needs-your-review items)"
    assert xp.summary_line([]) is None
    assert xp.summary_line([xp.Award("first_by_hand", 0, "x", badge=True)]) is None


# -- streak --------------------------------------------------------------------------- #
def merge_event(day_ts, by_hand=True, ws="w"):
    return XpEvent(at=day_ts, kind="merge_green", amount=20, workspace_id=ws, by_hand=by_hand,
                   mode="manual" if by_hand else "agent")


def test_streak_counts_consecutive_by_hand_days_through_today():
    now = ts(2026, 9, 30, 15)
    hist = [merge_event(ts(2026, 9, d, 10), ws=f"w{d}") for d in (28, 29, 30)]
    days, ticks, done = xp.streak_state(hist, now)
    assert (days, done) == (3, True)
    assert ticks[-3:] == [True, True, True] and not any(ticks[:-3])
    assert len(ticks) == 14


def test_streak_is_alive_until_today_ends():
    now = ts(2026, 9, 30, 9)
    hist = [merge_event(ts(2026, 9, d, 10), ws=f"w{d}") for d in (28, 29)]
    days, _, done = xp.streak_state(hist, now)
    assert days == 2 and done is False


def test_streak_breaks_after_a_missed_day():
    now = ts(2026, 9, 30, 9)
    hist = [merge_event(ts(2026, 9, 27, 10))]
    assert xp.streak_state(hist, now)[0] == 0


def test_agent_merges_do_not_count_for_the_streak():
    now = ts(2026, 9, 30, 15)
    hist = [merge_event(ts(2026, 9, 30, 10), by_hand=False)]
    days, ticks, done = xp.streak_state(hist, now)
    assert (days, done) == (0, False) and not any(ticks)


def test_streak_days_use_the_local_date():
    # 23:30 New York is already the next day in UTC; the streak must follow the local day
    evening = merge_event(ts(2026, 9, 29, 23, 30, NY))
    now = ts(2026, 9, 30, 8, 0, NY)
    days, _, done = xp.streak_state([evening], now, tz=NY)
    assert days == 1 and done is False


def test_switching_a_workspace_keeps_its_xp_but_loses_the_streak():
    manual_part = ledger(xp.award_for(act("docs_read", "manual", ts(2026, 9, 30)), []), at=ts(2026, 9, 30))
    merged = xp.award_for(facts(mode="agent", by_hand=False), manual_part)
    hist = manual_part + ledger(merged, at=ts(2026, 9, 30), mode="agent", by_hand=False)
    st = xp.build_status(hist, ts(2026, 9, 30, 18))
    assert st.xp == 10 + 10
    assert st.streak_days == 0 and st.today_done is False


def test_build_status_shape_and_latest():
    a = xp.award_for(facts(eyes=2), [])
    hist = ledger(a, at=ts(2026, 9, 30, 10), by_hand=True)
    st = xp.build_status(hist, ts(2026, 9, 30, 18))
    assert st.xp == 20 + 20
    assert (st.level, st.rank, st.next_rank_at) == (1, "Novice", 800)
    assert st.today_done and st.streak_days == 1 and len(st.streak) == 14
    assert st.latest is not None and st.latest.kind in {"merge_green", "eyes_resolved", "first_by_hand"}
    assert [b.kind for b in st.badges] == ["first_by_hand"]


def test_build_status_empty_ledger():
    st = xp.build_status([], ts(2026, 9, 30))
    assert (st.xp, st.level, st.rank, st.streak_days, st.latest, st.badges) == (0, 1, "Novice", 0, None, [])
    assert st.streak == [False] * 14


def test_streak_window_slides_with_the_clock():
    hist = [merge_event(ts(2026, 9, 30, 10))]
    _, ticks, _ = xp.streak_state(hist, ts(2026, 9, 30, 12) + timedelta(days=5).total_seconds())
    assert ticks[-6] is True and ticks[-1] is False
