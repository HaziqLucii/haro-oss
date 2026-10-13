"""Conflict-aware merge queue — the gate becomes the admission ticket to shipping.

Only *green* workspaces are admitted (the caller filters), and they land in a
**conflict-safe order**: we greedily merge any candidate that currently merges
cleanly onto its base, advance the base, and re-scan — so a sibling that only
conflicts *after* another lands is deferred, never merged into a broken state.
Whatever can never merge cleanly is reported ``blocked`` (rebase + re-gate).

The greedy engine is pure of IO: the conflict check, the actual merge and the train's
gate are injected: so the ordering logic is unit-testable without a real repo (roadmap v3).

**Merge train** (``gate_check`` given): before each candidate lands it is gated on the
merge of the *current* base (which already contains everything landed earlier in this run)
plus the candidate. A clean textual merge is not a green one: two branches can each pass
alone and fail together. A red candidate is blocked ("red on merged base") and the train
carries on with the next; it is never retried later in the same run.
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
class GateVerdict:
    """The train gate's answer for one candidate. ``green`` is the only thing that lets it
    land; ``error`` distinguishes "the gate could not run" from "the gate ran red"."""

    green: bool
    detail: str = ""
    error: bool = False


# gate_check(candidate) -> verdict for (advanced base + candidate), full scope
GateCheck = Callable[[Candidate], Awaitable[GateVerdict]]

RED_ON_MERGED_BASE = "red on merged base"


@dataclass
class QueueOutcome:
    merged: list[dict] = field(default_factory=list)   # {id, name[, gate]}
    blocked: list[dict] = field(default_factory=list)   # {id, name, reason, conflicts[, gate]}


async def run_merge_queue(
    candidates: list[Candidate],
    *,
    conflict_check: ConflictCheck,
    merge_one: MergeOne,
    gate_check: GateCheck | None = None,
) -> QueueOutcome:
    """Greedy conflict-safe merge. Merges every candidate that can land cleanly (in
    dependency-respecting order); reports the rest as blocked with their conflicts.

    With ``gate_check`` (the merge train) a conflict-free candidate must also be green on
    the merged base before ``merge_one`` runs; landed items carry ``gate: "green"``."""
    pending = list(candidates)
    out = QueueOutcome()
    progress = True
    while pending and progress:
        progress = False
        for c in list(pending):
            if await conflict_check(c.base_ref, c.branch):
                continue  # conflicts *now* — a later sibling merge may or may not free it
            if gate_check is not None:
                try:
                    verdict = await gate_check(c)
                except Exception as exc:  # noqa: BLE001: a gate that can't run is not a green
                    verdict = GateVerdict(green=False, detail=f"gate could not run: {exc}", error=True)
                if not verdict.green:
                    reason = verdict.detail if verdict.error else (
                        f"{RED_ON_MERGED_BASE} ({verdict.detail})" if verdict.detail else RED_ON_MERGED_BASE
                    )
                    out.blocked.append({
                        "id": c.id, "name": c.name, "reason": reason, "conflicts": [],
                        "gate": "error" if verdict.error else "red",
                    })
                    pending.remove(c)
                    progress = True
                    continue
            try:
                await merge_one(c)
            except Exception as exc:  # noqa: BLE001 — a failed merge blocks just that one
                out.blocked.append({"id": c.id, "name": c.name, "reason": str(exc), "conflicts": []})
            else:
                landed = {"id": c.id, "name": c.name}
                if gate_check is not None:
                    landed["gate"] = "green"
                out.merged.append(landed)
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
