"""Keep a project's main checkout level with ``origin``, safely, without being asked.

haro reads backlog files, instructions and settings from the project's own checkout, and
bases new workspaces on ``origin/<default>``. A PR merged on GitHub changes neither the
checkout nor what the Backlog shows, so the checkout drifts until someone runs ``git pull``.

The rule is the one ``git_ops.pull`` already had, made quiet: only a **fast-forward**, only
when the checkout is already **on the pull branch** (the project's ``pull_branch``, else its
default branch) with no tracked changes. In a result, ``default_branch`` is that pull branch. Never a
merge, a rebase, a branch switch or a stash, so it cannot lose work. Untracked files do not
block it (a project's ``.haro/`` is untracked), but git itself still refuses if one would be
overwritten, and that is reported instead of forced. Every other situation is described, not
acted on.
"""

from __future__ import annotations

import asyncio
import time

from . import git_ops
from .git_ops import GitError, _git

#: ``state`` values. ``pulled`` and ``up_to_date`` are the good ones; the rest explain why the
#: checkout was left alone.
PULLED = "pulled"
UP_TO_DATE = "up_to_date"
NO_REMOTE = "no_remote"
FETCH_FAILED = "fetch_failed"
OTHER_BRANCH = "other_branch"
DIRTY = "dirty"
DIVERGED = "diverged"
BLOCKED = "blocked"
BRANCH_MISSING = "branch_missing"

#: The newest result per project id, for ``GET /projects/{id}/sync``.
last: dict[str, dict] = {}
_locks: dict[str, asyncio.Lock] = {}


def _first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


async def _counts(repo: str, left: str, right: str) -> tuple[int, int]:
    """``(commits only on left, commits only on right)``."""
    out = await _git("rev-list", "--left-right", "--count", f"{left}...{right}", cwd=repo)
    a, _, b = out.strip().partition("\t")
    return int(a or 0), int(b or 0)


async def _tracked_changes(repo: str) -> bool:
    out = await _git("status", "--porcelain", "--untracked-files=no", cwd=repo)
    return bool(out.strip())


def _blocked_detail(exc: GitError) -> str:
    err = exc.stderr or ""
    if "untracked working tree files would be overwritten" in err:
        files = [
            line.strip()
            for line in err.splitlines()
            if line.startswith("\t")
        ]
        shown = ", ".join(files[:3]) + (f" (+{len(files) - 3} more)" if len(files) > 3 else "")
        return f"the update would overwrite untracked files here: {shown}" if files else _first_line(err)
    return _first_line(err) or "git refused the fast-forward"


async def sync_project(project) -> dict:
    """Fetch, then fast-forward the checkout when that is safe. Returns the result dict
    (always ``state`` plus ``branch``/``default_branch``/``behind``/``ahead``/``at``)."""
    lock = _locks.setdefault(project.id, asyncio.Lock())
    if lock.locked():  # a sync is already running: do not stack another behind it
        return last.get(project.id) or {"state": UP_TO_DATE, "at": time.time()}
    async with lock:
        result = await _sync(project)
        result["at"] = time.time()
        # The pull branch may have been changed while this ran: its answer is about the old one.
        if result["default_branch"] == target_branch(project):
            last[project.id] = result
        return result


def target_branch(project) -> str:
    return project.pull_branch or project.default_branch


async def _sync(project) -> dict:
    repo = project.path
    default = target_branch(project)
    base = f"origin/{default}"
    out: dict = {"default_branch": default, "branch": None, "behind": 0, "ahead": 0, "pulled": 0}

    if not await git_ops.get_remote(repo):
        return {**out, "state": NO_REMOTE}
    try:
        await git_ops.fetch(repo)
    except GitError as exc:
        return {**out, "state": FETCH_FAILED, "detail": _first_line(exc.stderr or "")}
    if not await git_ops.ref_exists(repo, base):
        return {**out, "state": BRANCH_MISSING, "detail": f"origin has no branch '{default}'"}
    try:
        out["branch"] = await git_ops.current_branch(repo)
        out["ahead"], out["behind"] = await _counts(repo, "HEAD", base)
    except (GitError, ValueError) as exc:
        return {**out, "state": FETCH_FAILED, "detail": f"could not compare with {base}: {exc}"}

    if out["branch"] != default:
        # What the Backlog shows is this branch's files, so say how stale they are.
        return {**out, "state": OTHER_BRANCH}
    if out["behind"] == 0:
        return {**out, "state": UP_TO_DATE}
    if out["ahead"] > 0:
        return {**out, "state": DIVERGED}
    if await _tracked_changes(repo):
        return {**out, "state": DIRTY}
    try:
        await _git("merge", "--ff-only", base, cwd=repo, env={"GIT_TERMINAL_PROMPT": "0"})
    except GitError as exc:
        return {**out, "state": BLOCKED, "detail": _blocked_detail(exc)}
    return {**out, "state": PULLED, "pulled": out["behind"], "behind": 0}


async def switch_to_default(project) -> dict:
    """The one action the Backlog notice offers: switch the checkout to the default branch,
    then sync it. Refused (as a plain ``ValueError``) when tracked changes would be at risk;
    git itself also refuses a switch that would overwrite them. Never stashes or discards."""
    repo = project.path
    default = target_branch(project)
    if await git_ops.current_branch(repo) == default:
        return await sync_project(project)
    if await _tracked_changes(repo):
        raise ValueError("the checkout has uncommitted changes: commit or stash them first")
    try:
        await _git("switch", default, cwd=repo)
    except GitError as exc:
        raise ValueError(_first_line(exc.stderr or "") or f"could not switch to {default}") from exc
    return await sync_project(project)
