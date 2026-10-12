"""XP, rank and streak: the rules and the maths, with no I/O.

The award table ``RULES`` is the single source: ``GET /xp/rules`` serves it and the client's
"How XP works" renders it, so a number changed here changes everywhere. ``award_for`` turns one
event plus the ledger so far into awards; the caller (``xp_hooks.py``) records the facts and
persists the result.

The rules are built to be un-farmable, because XP that can be ground stops meaning anything:
an activity pays at most once per kind per local day, a merge pays once per workspace and only
when it is green with a non-empty diff, and nothing pays for a red or blocked run.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, tzinfo
from typing import Literal, Optional

from .models import XpBadge, XpEvent, XpLatest, XpRank, XpRule, XpRules, XpStatus

Mode = Literal["agent", "manual"]
Group = Literal["daily", "merge", "manual", "badge"]

LEVEL_XP = 180
STREAK_DAYS = 14
EYES_CAP = 5

#: (name, XP where the rank starts), lowest first.
RANKS: tuple[tuple[str, int], ...] = (
    ("Novice", 0),
    ("Journeyman", 800),
    ("Craftsman", 2000),
    ("Master", 4000),
)


@dataclass(frozen=True)
class Rule:
    kind: str
    group: Group
    #: Toast wording: "+10 XP · read the docs".
    label: str
    #: The line "How XP works" shows.
    text: str
    manual: Optional[int] = None
    agent: Optional[int] = None
    cap: Optional[int] = None

    def amount(self, mode: Mode) -> int:
        return (self.manual if mode == "manual" else self.agent) or 0


RULES: tuple[Rule, ...] = (
    Rule("docs_read", "daily", "read the docs",
         "Read a plan, pinned doc or man page in Docs", manual=10, agent=2),
    Rule("plan_made", "daily", "made a plan", "Made a plan with haro", manual=10, agent=2),
    Rule("research", "daily", "ran a search", "Ran a Search lookup", manual=5, agent=1),
    Rule("gate_run", "daily", "ran the gate", "Ran the gate and it passed", manual=5, agent=1),
    Rule("diff_reviewed", "daily", "reviewed the diff",
         "Marked every changed file Viewed in review", manual=3, agent=5),
    Rule("merge_green", "merge", "merged on green",
         "Merged on green (once per workspace, and the diff must not be empty)",
         manual=20, agent=10),
    Rule("eyes_resolved", "merge", "resolved needs-your-review items",
         "Each needs-your-review item ticked before the merge", manual=10, agent=5, cap=EYES_CAP),
    Rule("review_bonus", "merge", "reviewed every changed file",
         "Marked every changed file Viewed before merging", agent=15),
    Rule("hand_test", "merge", "tested by hand",
         "A test file you edited yourself is in the merged diff", agent=10),
    Rule("red_to_green", "manual", "red to green by hand",
         "The gate was red and you got it green with no agent run", manual=120),
    Rule("test_first", "manual", "started from a test",
         "Started from a test: the first gate run was red with only test files changed",
         manual=30),
    Rule("first_by_hand", "badge", "First by hand", "Your first merge made by hand"),
    Rule("regression_hunter", "badge", "Regression hunter",
         "A manual merge where a git Search ran before the first green"),
)

_BY_KIND = {r.kind: r for r in RULES}
DAILY_KINDS = frozenset(r.kind for r in RULES if r.group == "daily")
#: Kinds the client may report itself; the rest are observed by the backend.
CLIENT_KINDS = frozenset({"docs_read", "diff_reviewed"})
#: A daily kind that also pays at most once per workspace.
_ONCE_PER_WORKSPACE = frozenset({"diff_reviewed"})


@dataclass(frozen=True)
class Award:
    kind: str
    amount: int
    label: str
    detail: str = ""
    badge: bool = False


@dataclass(frozen=True)
class Activity:
    kind: str
    mode: Mode
    at: float
    workspace_id: Optional[str] = None


@dataclass(frozen=True)
class MergeFacts:
    workspace_id: str
    mode: Mode
    at: float
    #: Manual mode the whole way, never switched: the streak reads this.
    by_hand: bool
    changed_files: list[str] = field(default_factory=list)
    #: The latest gate run passed and nothing blocked it.
    green: bool = True
    eyes: int = 0
    reviewed_all: bool = False
    hand_test: bool = False
    red_to_green: bool = False
    start_from_test_ok: bool = False
    regression_search: bool = False


def label_for(kind: str) -> str:
    rule = _BY_KIND.get(kind)
    return rule.label if rule else kind


def local_date(ts: float, tz: Optional[tzinfo] = None) -> date:
    """The local calendar day of ``ts``. Days are compared as dates, never as 24h spans, so a
    DST change (a 23h or 25h day) cannot merge or split a day."""
    return datetime.fromtimestamp(ts, tz).date()


def award_for(
    event: Activity | MergeFacts, history: list[XpEvent], tz: Optional[tzinfo] = None
) -> list[Award]:
    if isinstance(event, Activity):
        return _activity_awards(event, history, tz)
    return _merge_awards(event, history)


def _activity_awards(ev: Activity, history: list[XpEvent], tz: Optional[tzinfo]) -> list[Award]:
    if ev.kind not in DAILY_KINDS:
        return []
    day = local_date(ev.at, tz)
    for h in history:
        if h.kind != ev.kind:
            continue
        if local_date(h.at, tz) == day:
            return []
        if ev.kind in _ONCE_PER_WORKSPACE and ev.workspace_id and h.workspace_id == ev.workspace_id:
            return []
    rule = _BY_KIND[ev.kind]
    amount = rule.amount(ev.mode)
    return [Award(ev.kind, amount, rule.label)] if amount else []


def _merge_awards(f: MergeFacts, history: list[XpEvent]) -> list[Award]:
    if not f.green or not f.changed_files:
        return []
    if any(h.kind == "merge_green" and h.workspace_id == f.workspace_id for h in history):
        return []
    # The manual column and every manual-only award need a workspace written by hand the whole
    # way. The mode at merge time is not evidence: flipping a green agent workspace to manual
    # just before merging must not buy the manual rates or bonuses.
    manual = f.by_hand
    rate: Mode = "manual" if manual else "agent"
    out: list[Award] = []

    def add(kind: str, amount: Optional[int] = None, detail: str = "") -> None:
        rule = _BY_KIND[kind]
        n = rule.amount(rate) if amount is None else amount
        if n:
            out.append(Award(kind, n, rule.label, detail))

    add("merge_green")
    items = min(max(f.eyes, 0), EYES_CAP)
    if items:
        add("eyes_resolved", _BY_KIND["eyes_resolved"].amount(rate) * items,
            f"{items} item{'s' if items != 1 else ''}")
    if not manual:
        if f.reviewed_all:
            add("review_bonus")
        if f.hand_test:
            add("hand_test")
    else:
        if f.red_to_green:
            add("red_to_green")
        if f.start_from_test_ok:
            add("test_first")

    have = {h.kind for h in history}
    if manual and "first_by_hand" not in have:
        out.append(Award("first_by_hand", 0, label_for("first_by_hand"), badge=True))
    if manual and f.regression_search and "regression_hunter" not in have:
        out.append(Award("regression_hunter", 0, label_for("regression_hunter"), badge=True))
    return out


def to_events(awards: list[Award], *, at: float, mode: Mode, workspace_id: Optional[str],
              by_hand: bool = False) -> list[XpEvent]:
    return [
        XpEvent(at=at, kind=a.kind, amount=a.amount, workspace_id=workspace_id, mode=mode,
                by_hand=by_hand and a.kind == "merge_green", detail=a.detail)
        for a in awards
    ]


def total_xp(history: list[XpEvent]) -> int:
    return sum(h.amount for h in history)


def level_for(xp: int) -> int:
    return max(xp, 0) // LEVEL_XP + 1


def rank_for(xp: int) -> tuple[str, int, Optional[int]]:
    """``(rank name, where it starts, where the next begins or None at the top)``."""
    idx = 0
    for i, (_, at) in enumerate(RANKS):
        if xp >= at:
            idx = i
    name, start = RANKS[idx]
    nxt = RANKS[idx + 1][1] if idx + 1 < len(RANKS) else None
    return name, start, nxt


def by_hand_days(history: list[XpEvent], tz: Optional[tzinfo] = None) -> set[date]:
    return {local_date(h.at, tz) for h in history if h.kind == "merge_green" and h.by_hand}


def streak_state(history: list[XpEvent], now: float, tz: Optional[tzinfo] = None
                 ) -> tuple[int, list[bool], bool]:
    """``(streak days, last 14 days oldest first, done today)``. The streak stays alive through
    a day that has not ended yet: it counts back from yesterday until today's merge lands."""
    days = by_hand_days(history, tz)
    today = local_date(now, tz)
    done = today in days
    cursor = today if done else today - timedelta(days=1)
    n = 0
    while cursor in days:
        n += 1
        cursor -= timedelta(days=1)
    ticks = [(today - timedelta(days=STREAK_DAYS - 1 - i)) in days for i in range(STREAK_DAYS)]
    return n, ticks, done


def build_status(history: list[XpEvent], now: float, tz: Optional[tzinfo] = None) -> XpStatus:
    xp = total_xp(history)
    name, start, nxt = rank_for(xp)
    streak_days, ticks, done = streak_state(history, now, tz)
    rewards = [h for h in history if h.kind in _BY_KIND]
    last = max(rewards, key=lambda h: h.at, default=None)
    latest = None
    if last is not None:
        label = label_for(last.kind)
        if last.detail and last.kind == "eyes_resolved":
            label = f"resolved {last.detail}"
        latest = XpLatest(kind=last.kind, amount=last.amount, label=label, at=last.at)
    badges = [
        XpBadge(kind=h.kind, label=label_for(h.kind), at=h.at)
        for h in sorted(history, key=lambda e: e.at)
        if _BY_KIND.get(h.kind) is not None and _BY_KIND[h.kind].group == "badge"
    ]
    return XpStatus(
        xp=xp, level=level_for(xp), rank=name, rank_start=start, next_rank_at=nxt,
        streak_days=streak_days, streak=ticks, today_done=done, latest=latest, badges=badges,
    )


def rules_payload() -> XpRules:
    return XpRules(
        rules=[
            XpRule(kind=r.kind, group=r.group, label=r.label, text=r.text,
                   manual=r.manual, agent=r.agent, cap=r.cap)
            for r in RULES
        ],
        ranks=[XpRank(name=n, at=a) for n, a in RANKS],
        level_xp=LEVEL_XP,
    )


def summary_line(awards: list[Award]) -> Optional[str]:
    """"XP: +140 (merged on green, red to green by hand)" for a set of merge awards."""
    paid = [a for a in awards if not a.badge and a.amount]
    if not paid:
        return None
    labels = ", ".join(a.label for a in paid)
    return f"XP: +{sum(a.amount for a in paid)} ({labels})"
