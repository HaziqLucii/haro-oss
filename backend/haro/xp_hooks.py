"""The side-effecting half of XP: read workspace facts, ask ``xp.award_for``, write the ledger.

Every public function here swallows its own failures. XP is a reward on top of work, so a merge
or a gate run must never fail, or even slow down, because the ledger did: log and carry on.
Persistence rides the existing autosave and the snapshot the callers already take.
"""

from __future__ import annotations

import logging
import posixpath
import time
from typing import Optional

from . import git_ops, xp
from .models import Workspace, XpEvent
from .tamper import is_test_file

log = logging.getLogger(__name__)

#: A ceiling on the path lists kept on a workspace: they are facts to intersect with a diff,
#: not an archive, and an unbounded list would ride every snapshot.
_PATH_CAP = 500


def _now() -> float:
    return time.time()


def norm_path(path: str) -> str:
    """One spelling per file: forward slashes, no ``./`` prefix, no doubled or trailing
    separators. The editor, the diff and the client each write paths a little differently, and
    a mismatch here would silently withhold an award."""
    p = posixpath.normpath(path.replace("\\", "/").strip())
    return "" if p == "." else p.lstrip("/")


def by_hand(ws: Workspace) -> bool:
    """Written by hand the whole way: manual now and never switched. The one fact behind the
    manual rates, the manual-only bonuses and the streak."""
    return ws.mode == "manual" and not ws.mode_switches


def _remember(paths: list[str], path: str) -> None:
    path = norm_path(path)
    if path and path not in paths:
        paths.append(path)
        del paths[:-_PATH_CAP]


def note_hand_saved(ws: Workspace, path: str) -> None:
    try:
        _remember(ws.hand_saved_paths, path)
    except Exception:  # noqa: BLE001 - XP must never break the save
        log.exception("xp: could not note a hand save")


def note_mutation(ws: Workspace, survived: int) -> None:
    try:
        ws.mutation_survivors.append(survived)
        del ws.mutation_survivors[:-50]
    except Exception:  # noqa: BLE001
        log.exception("xp: could not note a mutation run")


def note_research(store, ws: Workspace, scope: str) -> None:
    """A git-scope Search before the first green gate: the regression-hunter fact."""
    try:
        if scope == "git" and not any(
            t.status.value == "passed" for t in store.test_history(ws.id)
        ):
            ws.git_search_before_green = True
    except Exception:  # noqa: BLE001
        log.exception("xp: could not note a research lookup")


async def _publish(hub, workspace_id: Optional[str], awards: list[xp.Award]) -> None:
    if not awards or hub is None:
        return
    paid = [a for a in awards if not a.badge and a.amount]
    badges = [a for a in awards if a.badge]
    await hub.broadcast_global({
        "channel": "xp",
        "workspace_id": workspace_id,
        "amount": sum(a.amount for a in paid),
        "label": ", ".join(a.label for a in paid),
        "badge": badges[0].label if badges else None,
        "awards": [
            {"kind": a.kind, "amount": a.amount, "label": a.label, "badge": a.badge}
            for a in awards
        ],
    })


def _record(store, awards: list[xp.Award], *, at: float, mode: str, workspace_id: Optional[str],
            by_hand: bool = False) -> list[XpEvent]:
    events = xp.to_events(awards, at=at, mode=mode, workspace_id=workspace_id, by_hand=by_hand)  # type: ignore[arg-type]
    for e in events:
        store.xp_events[e.id] = e
    return events


async def record_activity(
    store, hub, kind: str, workspace_id: Optional[str] = None, *, mode: Optional[str] = None,
) -> list[xp.Award]:
    try:
        ws = store.get_workspace(workspace_id) if workspace_id else None
        # The manual number is for a workspace written by hand the whole way; a flipped or
        # agent workspace earns the agent number, so a mode switch cannot buy the higher rate.
        m = mode or ("manual" if ws is not None and by_hand(ws) else "agent")
        at = _now()
        awards = xp.award_for(
            xp.Activity(kind=kind, mode=m, at=at, workspace_id=workspace_id),  # type: ignore[arg-type]
            store.list_xp_events(),
        )
        _record(store, awards, at=at, mode=m, workspace_id=workspace_id)
        await _publish(hub, workspace_id, awards)
        return awards
    except Exception:  # noqa: BLE001 - XP must never break its caller
        log.exception("xp: activity %s failed", kind)
        return []


async def record_diff_reviewed(store, hub, ws: Workspace, paths: list[str]) -> list[xp.Award]:
    """The client says which changed files it has shown in Diff. The server keeps the list (the
    merge review bonus reads it) and only pays when it covers every file changed right now."""
    try:
        for p in paths:
            _remember(ws.reviewed_diff_paths, p)
        changed = {norm_path(p) for p in await git_ops.working_changed_paths(ws.worktree_path, ws.base_ref)}
        if not changed or not changed <= set(ws.reviewed_diff_paths):
            return []
        return await record_activity(store, hub, "diff_reviewed", ws.id)
    except Exception:  # noqa: BLE001
        log.exception("xp: diff_reviewed failed")
        return []


async def on_gate_finished(store, hub, ws: Workspace, test, *, green: bool) -> None:
    """After every stored gate run: settle the start-from-a-test fact, then pay ``gate_run``
    for a green one. A red or blocked run pays nothing."""
    try:
        if ws.start_from_test and ws.start_from_test_ok is None and len(store.test_history(ws.id)) == 1:
            ws.start_from_test_ok = False
            if test.status.value == "failed":
                changed = await git_ops.working_changed_paths(ws.worktree_path, ws.base_ref)
                ws.start_from_test_ok = bool(changed) and all(is_test_file(p) for p in changed)
        if green and test.trigger != "watch":
            await record_activity(store, hub, "gate_run", ws.id)
    except Exception:  # noqa: BLE001
        log.exception("xp: gate hook failed")


def merge_facts(store, ws: Workspace, changed: list[str], *, at: float) -> xp.MergeFacts:
    history = store.test_history(ws.id)
    latest = history[-1] if history else None
    green = bool(
        latest
        and latest.status.value == "passed"
        and not (latest.coverage_blocked or latest.merge_conflict or latest.tamper_blocked
                 or latest.acceptance_blocked)
    )
    no_agent_edits = not any(r.workspace_id == ws.id and not r.plan for r in store.runs.values())
    red_then_green = green and any(t.status.value == "failed" for t in history[:-1])
    files = [p for p in (norm_path(c) for c in changed) if p]
    reviewed = {norm_path(p) for p in ws.reviewed_diff_paths}
    hand = {norm_path(p) for p in ws.hand_saved_paths}
    # A tick counts only if it matches a row the final gate run raised. The checked endpoint
    # takes any key and prunes only at the next gate, so a bare tick proves nothing.
    live_rows = {r.key for r in ((latest.unchecked_items if latest else None) or [])}
    hand_owned = by_hand(ws)
    return xp.MergeFacts(
        workspace_id=ws.id,
        mode="manual" if hand_owned else "agent",
        at=at,
        by_hand=hand_owned,
        changed_files=files,
        green=green,
        eyes=len(set(ws.checked_rows) & live_rows),
        reviewed_all=bool(files) and set(files) <= reviewed,
        hand_test=any(p in hand and is_test_file(p) for p in files),
        red_to_green=red_then_green and no_agent_edits,
        mutant_killed=xp.mutant_killed(ws.mutation_survivors),
        start_from_test_ok=bool(ws.start_from_test and ws.start_from_test_ok),
        regression_search=ws.git_search_before_green,
    )


async def merge_changed_paths(ws: Workspace) -> list[str]:
    """What the merge is about to land. Read BEFORE a local merge: afterwards the branch is an
    ancestor of the base and the three-dot diff is empty."""
    try:
        return await git_ops.branch_changed_paths(ws.worktree_path, ws.base_ref)
    except Exception:  # noqa: BLE001
        log.exception("xp: could not read the merge diff")
        return []


async def record_merge(store, hub, ws: Workspace, changed: list[str]) -> list[xp.Award]:
    try:
        at = _now()
        facts = merge_facts(store, ws, changed, at=at)
        awards = xp.award_for(facts, store.list_xp_events())
        _record(store, awards, at=at, mode=facts.mode, workspace_id=ws.id, by_hand=facts.by_hand)
        await _publish(hub, ws.id, awards)
        return awards
    except Exception:  # noqa: BLE001
        log.exception("xp: merge awards failed")
        return []


def merge_preview(store, ws: Workspace, changed: list[str]) -> Optional[str]:
    """The receipt line before the merge: what the merge would pay if it landed now."""
    facts = merge_facts(store, ws, changed, at=_now())
    return xp.summary_line(xp.award_for(facts, store.list_xp_events()))


def merged_line(store, ws_id: str) -> Optional[str]:
    """The receipt line after the merge: what was actually paid for this workspace."""
    events = [e for e in store.list_xp_events() if e.workspace_id == ws_id and e.kind in xp._BY_KIND]
    awards = [
        xp.Award(e.kind, e.amount, xp.label_for(e.kind), badge=e.amount == 0) for e in events
        if xp._BY_KIND[e.kind].group in ("merge", "manual")
    ]
    return xp.summary_line(awards)

