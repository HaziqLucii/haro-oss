"""Conflict-aware merge queue — the gate becomes the admission ticket to shipping.

Only *green* workspaces are admitted (the caller filters), and they land in a
**conflict-safe order**: we greedily merge any candidate that currently merges
cleanly onto its base, advance the base, and re-scan — so a sibling that only
conflicts *after* another lands is deferred, never merged into a broken state.
Whatever can never merge cleanly is reported ``blocked`` (rebase + re-gate).

The greedy engine is pure of IO — the git conflict-check and the actual merge are
injected — so the ordering logic is unit-testable without a real repo (roadmap v3).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Awaitable, Callable


@dataclass
class Candidate:
    id: str
    name: str
    branch: str
    base_ref: str


# conflict_check(base_ref, branch) -> conflicted file paths ([] = clean)
ConflictCheck = Callable[[str, str], Awaitable[list[str]]]
# merge_one(candidate) -> None; raises on merge failure (branch protection, etc.)
MergeOne = Callable[[Candidate], Awaitable[None]]


@dataclass
class QueueOutcome:
    merged: list[dict] = field(default_factory=list)   # {id, name}
    blocked: list[dict] = field(default_factory=list)   # {id, name, reason, conflicts}


async def run_merge_queue(
    candidates: list[Candidate], *, conflict_check: ConflictCheck, merge_one: MergeOne
) -> QueueOutcome:
    """Greedy conflict-safe merge. Merges every candidate that can land cleanly (in
    dependency-respecting order); reports the rest as blocked with their conflicts."""
    pending = list(candidates)
    out = QueueOutcome()
    progress = True
    while pending and progress:
        progress = False
        for c in list(pending):
            if await conflict_check(c.base_ref, c.branch):
                continue  # conflicts *now* — a later sibling merge may or may not free it
            try:
                await merge_one(c)
            except Exception as exc:  # noqa: BLE001 — a failed merge blocks just that one
                out.blocked.append({"id": c.id, "name": c.name, "reason": str(exc), "conflicts": []})
            else:
                out.merged.append({"id": c.id, "name": c.name})
            pending.remove(c)
            progress = True
    # Nothing merged clean for these — report why (their current conflict set).
    for c in pending:
        conflicts = await conflict_check(c.base_ref, c.branch)
        out.blocked.append({
            "id": c.id, "name": c.name,
            "reason": "conflicts with base: merge base in and re-gate, then re-queue",
            "conflicts": conflicts,
        })
    return out


async def preview_merge_queue(
    candidates: list[Candidate], *, conflict_check: ConflictCheck
) -> QueueOutcome:
    """Dry run: report which admitted candidates would merge cleanly onto the base
    *right now* (single pass, nothing lands). An approximation of the real cascade —
    a merge that only becomes possible after a sibling lands shows as blocked here."""
    out = QueueOutcome()
    for c in candidates:
        conflicts = await conflict_check(c.base_ref, c.branch)
        if conflicts:
            out.blocked.append({
                "id": c.id, "name": c.name,
                "reason": "conflicts with base", "conflicts": conflicts,
            })
        else:
            out.merged.append({"id": c.id, "name": c.name})  # "would merge"
    return out
