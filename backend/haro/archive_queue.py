"""Bulk archive — a serial queue, because N teardowns at once is the unsafe way.

Archiving one workspace is already a compound, destructive act: quiesce everything
running inside it, run the project's ``archive`` script, ``git worktree remove
--force``, then ``git branch -D``. Firing that N times concurrently multiplies every
failure mode at once — N archive scripts competing for the machine, N git commands
contending on the same repo's index, and a partial failure buried in a pile of
parallel results with nobody able to say which workspace survived.

So bulk archive is a **queue**: one teardown at a time, in a deterministic order,
each item reporting its own outcome, and the batch surviving any single failure.

The same decide/act split as ``trust.py``→``rungs.py`` and ``race.py``→``fanout.py``:

* ``plan`` is **pure** — facts in (busy? dirty? unmerged? worktree still there?),
  admission out. No git, no store, no clock, so the rules are unit-testable with no
  repo, and "why was this one skipped" has exactly one source of truth.
* ``run_queue`` is the serial driver, with the actual teardown injected. It owns the
  three properties the queue exists for: **one at a time**, **failure isolation**
  (one bad item never eats the batch) and a **cooperative stop** that lets the
  in-flight teardown finish rather than cancelling it half-done.

Two rules worth not breaking:

* **Risky work is skipped by default, never silently archived.** ``remove_worktree``
  force-deletes the branch, so uncommitted edits *and* unmerged commits both die with
  it. A single archive is one deliberate click on one workspace; a bulk archive is one
  click on many, so the default subset is the one with nothing at stake, and taking
  the rest requires ``force`` (the UI's explicit "include N with unsaved work").
* **Risk-free items go first.** If the user stops the queue halfway, what has already
  happened is the harmless half — the destructive ones are still pending.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Awaitable, Callable, Optional

from .models import ArchiveQueueItem, ArchiveQueueRun


@dataclass(frozen=True)
class Candidate:
    """The facts admission is decided on — gathered by the caller, never in here.

    ``ahead`` is commits on this branch that ``base_ref`` doesn't have: the work
    ``git branch -D`` would take with it. ``worktree_missing`` is deliberately *not*
    a risk — a husk has nothing left to lose and archiving is how you clean it up.
    """

    id: str
    name: str
    busy: Optional[str] = None      # store.busy_reason(): "setup" | "an agent" | "the gate"
    dirty: bool = False             # uncommitted changes in the worktree
    ahead: int = 0                  # commits not in base_ref
    worktree_missing: bool = False
    #: False when git couldn't answer "is there unsaved work here?". An unmeasured
    #: worktree is treated as risky, never as clean — the same never-silently-pass
    #: rule the coverage guard and the quality scanners follow.
    measured: bool = True


@dataclass
class PlanItem:
    id: str
    name: str
    queued: bool
    reason: Optional[str] = None
    risks: list[str] = field(default_factory=list)


def risks_of(candidate: Candidate) -> list[str]:
    """What this workspace stands to lose, in the user's words — one string per thing.

    Ordered by how irreversible it is: a running agent can be re-run, uncommitted edits
    cannot be recovered, and commits die with the force-deleted branch.
    """
    out: list[str] = []
    if candidate.worktree_missing:
        # Nothing on disk to lose. Say so — a husk otherwise reads as "no risks
        # detected", which is the same words for a very different reason.
        return out
    if not candidate.measured:
        out.append("couldn’t check this worktree for unsaved work")
    if candidate.busy:
        out.append(f"{candidate.busy} is still running — it will be stopped")
    if candidate.dirty:
        out.append("uncommitted changes will be discarded")
    if candidate.ahead > 0:
        n = candidate.ahead
        out.append(f"{n} unmerged commit{'' if n == 1 else 's'} — the branch is deleted too")
    return out


def plan(candidates: list[Candidate], *, force: bool = False) -> list[PlanItem]:
    """Admission + order for a bulk archive.

    Without ``force`` every candidate carrying a risk is **skipped** with that risk as
    its reason, so the default batch is the one that throws nothing away. With
    ``force`` they're all queued, risks recorded rather than hidden — the record has to
    say what the user agreed to lose.

    The order is risk-free first (then by name, so it never depends on dict order):
    a stopped queue should have done the harmless work and none of the destructive.
    """
    items: list[PlanItem] = []
    for c in sorted(candidates, key=lambda c: (bool(risks_of(c)), c.name.lower(), c.id)):
        risks = risks_of(c)
        if risks and not force:
            items.append(PlanItem(id=c.id, name=c.name, queued=False, reason="; ".join(risks), risks=risks))
        else:
            items.append(PlanItem(id=c.id, name=c.name, queued=True, risks=risks))
    return items


def to_items(items: list[PlanItem]) -> list[ArchiveQueueItem]:
    """The plan as the wire model the UI renders (preview and progress are one shape,
    so the confirm dialog and the live panel can't disagree about what was decided)."""
    return [
        ArchiveQueueItem(
            workspace_id=i.id,
            name=i.name,
            outcome="queued" if i.queued else "skipped",
            reason=i.reason,
            risks=i.risks,
        )
        for i in items
    ]


#: Tear one workspace down, by id. Raises on failure — the driver isolates it.
ArchiveOne = Callable[[str], Awaitable[None]]
#: Called after every state change so the UI sees the queue move (a bulk archive with
#: no visible progress is exactly the "did it hang?" moment the queue is meant to fix).
Publish = Callable[[ArchiveQueueRun], Awaitable[None]]


async def run_queue(run: ArchiveQueueRun, *, archive_one: ArchiveOne, publish: Publish) -> ArchiveQueueRun:
    """Drive the queue serially. Never raises for an item — it records and moves on.

    Stopping is **cooperative**: ``run.stop_requested`` is checked between items, so an
    in-flight teardown always completes. Cancelling mid-``remove_worktree`` is how you
    get the half-removed husk the crash-safety work exists to avoid, and a "stop" that
    corrupts the thing it stopped is worse than one that finishes the current item.
    """
    run.state = "running"
    await publish(run)

    for item in run.items:
        if item.outcome != "queued":
            continue  # skipped at plan time — not ours to reconsider
        if run.stop_requested:
            item.outcome = "canceled"
            item.reason = "stopped before this one ran"
            continue
        item.outcome = "archiving"
        await publish(run)
        try:
            await archive_one(item.workspace_id)
        except Exception as exc:  # noqa: BLE001 — one failed teardown must not eat the batch
            item.outcome = "failed"
            item.reason = str(exc) or exc.__class__.__name__
        else:
            item.outcome = "archived"
            item.reason = None
        await publish(run)

    # "canceled" means work was actually dropped — a stop that lands after the last
    # teardown finished still archived everything, and reporting that as canceled would
    # send the user hunting for workspaces that are already gone.
    run.state = "canceled" if any(i.outcome == "canceled" for i in run.items) else "done"
    await publish(run)
    return run


def summarize(run: ArchiveQueueRun) -> str:
    """One line for the toast/log: what actually happened to the batch."""
    counts: dict[str, int] = {}
    for item in run.items:
        counts[item.outcome] = counts.get(item.outcome, 0) + 1
    order = ["archived", "failed", "skipped", "canceled"]
    parts = [f"{counts[k]} {k}" for k in order if counts.get(k)]
    return " · ".join(parts) or "nothing to archive"
