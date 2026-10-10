"""How much work is waiting for the developer to review, across every project.

Review is the bottleneck of running agents in parallel: ``[agent] max_parallel`` bounds the
machine, this measures the person. A workspace is counted when an agent has run in it (a plan
run edits nothing), nothing is running there now, it is not merged, and it still differs from
its base. It does not say who wrote the lines: a hand edit in such a workspace counts too. The
number is lines added plus removed against that base, the same diff the review step shows
(lockfiles and generated files included). Reading is side-effect free: unlike the diff view it
never marks untracked files intent-to-add, so it cannot take the index lock while the developer
is staging by hand. It is a count, never a gate: a past-the-cap reading only changes what the
dashboard and the composer say.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from . import git_ops
from .config import review_cap
from .models import ReviewQueue, ReviewQueueItem, WorkspaceStatus

_WAITING = frozenset({WorkspaceStatus.idle, WorkspaceStatus.tests_running, WorkspaceStatus.gate_green, WorkspaceStatus.gate_red})

#: Git passes running at once, so many idle workspaces do not compete with live runs.
_PARALLEL = 4
#: An untracked file bigger than this is counted as one line: it is data, not something read.
_MAX_UNTRACKED_BYTES = 1_000_000


def _untracked_lines(root: Path, name: str) -> int:
    try:
        path = root / name
        if not path.is_file() or path.stat().st_size > _MAX_UNTRACKED_BYTES:
            return 1
        data = path.read_bytes()
    except OSError:
        return 0
    if b"\0" in data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1)


async def _measure(workspace, gate: asyncio.Semaphore) -> ReviewQueueItem | None:
    cwd = workspace.worktree_path
    async with gate:
        try:
            stat = await git_ops._git("diff", "--numstat", workspace.base_ref, *git_ops._EXCLUDE, cwd=cwd)
            fresh = await git_ops._git("ls-files", "-o", "--exclude-standard", "-z", cwd=cwd)
            lines = files = 0
            for row in stat.splitlines():
                added, removed, *_ = row.split("\t")
                lines += (int(added) if added.isdigit() else 0) + (int(removed) if removed.isdigit() else 0)
                files += 1
            for name in (n for n in fresh.split("\0") if n):
                lines += _untracked_lines(Path(cwd), name)
                files += 1
        except Exception:  # noqa: BLE001 - a workspace that cannot be read is left out, not an error
            return None
    if lines <= 0:
        return None
    return ReviewQueueItem(workspace_id=workspace.id, project_id=workspace.project_id, lines=lines, files=files)


async def build_review_queue(store) -> ReviewQueue:
    ran = {r.workspace_id for r in store.runs.values() if not r.plan}
    waiting = [w for w in store.list_workspaces() if w.status in _WAITING and w.mode != "manual" and w.id in ran]
    gate = asyncio.Semaphore(_PARALLEL)
    items = [i for i in await asyncio.gather(*(_measure(w, gate) for w in waiting)) if i is not None]
    items.sort(key=lambda i: -i.lines)
    return ReviewQueue(cap=review_cap(), total_lines=sum(i.lines for i in items), workspaces=items)
