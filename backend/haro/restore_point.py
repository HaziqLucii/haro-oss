"""A restore point for the worktree at the start of every agent run.

The agent has a shell, so the one thing no rule can promise is that it never runs a command that
discards uncommitted work (``git reset --hard``, a clean, an overwrite). What haro can do is keep
the files as they were when the run started and put them back on request.

``pin`` turns the start snapshot ``runner`` already takes (a git tree of every tracked and
untracked, non-ignored file) into a commit under ``refs/haro/start/<workspace>/<run>`` so gc cannot
drop it. ``restore`` puts the worktree back to it: files the run added are deleted, files it
changed or deleted come back, and what the worktree held a moment before is first kept under
``refs/haro/before-restore/<workspace>/<time>``, so a restore can itself be undone by hand.

It restores files, never history: a commit the agent made stays, and ignored files such as
``node_modules`` are neither saved nor touched. Only the working tree changes, never the index.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

from . import git_ops, scope_fence

START_PREFIX = "refs/haro/start/"
BEFORE_RESTORE_PREFIX = "refs/haro/before-restore/"
KEEP_START = 10
KEEP_BEFORE_RESTORE = 5

_IDENT = {
    "GIT_AUTHOR_NAME": "haro", "GIT_AUTHOR_EMAIL": "haro@localhost",
    "GIT_COMMITTER_NAME": "haro", "GIT_COMMITTER_EMAIL": "haro@localhost",
}


@dataclass
class RestoreOutcome:
    restored: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)
    #: Where the worktree was kept just before the restore. None when nothing needed restoring.
    saved_ref: str | None = None
    nothing_to_restore: bool = False


async def _commit(worktree: str, tree: str, message: str, ref: str) -> None:
    sha = (await git_ops._git("commit-tree", tree, "-m", message, cwd=worktree, env=_IDENT)).strip()
    await git_ops._git("update-ref", ref, sha, cwd=worktree)


async def _prune(worktree: str, prefix: str, keep: int) -> None:
    out = await git_ops._git(
        "for-each-ref", "--sort=-creatordate", "--format=%(refname)", prefix, cwd=worktree
    )
    for ref in [r for r in out.splitlines() if r][keep:]:
        await git_ops._git("update-ref", "-d", ref, cwd=worktree)


async def pin(worktree: str, tree: str, workspace_id: str, run_id: str) -> str:
    ref = f"{START_PREFIX}{workspace_id}/{run_id}"
    await _commit(worktree, tree, f"haro: the worktree when run {run_id} started", ref)
    await _prune(worktree, f"{START_PREFIX}{workspace_id}/", KEEP_START)
    return ref


async def drop_workspace(worktree: str, workspace_id: str) -> None:
    """Forget a workspace's restore points (called when it is deleted)."""
    for prefix in (START_PREFIX, BEFORE_RESTORE_PREFIX):
        out = await git_ops._git("for-each-ref", "--format=%(refname)", f"{prefix}{workspace_id}/", cwd=worktree)
        for ref in [r for r in out.splitlines() if r]:
            await git_ops._git("update-ref", "-d", ref, cwd=worktree)


async def restore(worktree: str, ref: str, workspace_id: str) -> RestoreOutcome:
    start_tree = (await git_ops._git("rev-parse", f"{ref}^{{tree}}", cwd=worktree)).strip()
    now_tree = await scope_fence.snapshot_tree(worktree)
    if now_tree == start_tree:
        return RestoreOutcome(nothing_to_restore=True)
    entries = await scope_fence._name_status(worktree, start_tree, now_tree)
    saved = f"{BEFORE_RESTORE_PREFIX}{workspace_id}/{int(time.time() * 1000)}"
    await _commit(worktree, now_tree, "haro: the worktree just before it was restored to a run start", saved)
    await _prune(worktree, f"{BEFORE_RESTORE_PREFIX}{workspace_id}/", KEEP_BEFORE_RESTORE)
    out = RestoreOutcome(saved_ref=saved)
    # Added paths first: a file replaced by a directory is `D a` plus `A a/b`.
    for status, path in sorted(entries, key=lambda e: e[0] != "A"):
        if status == "A":
            (out.restored if scope_fence._remove_added(worktree, path) else out.failed).append(path)
            continue
        try:
            await git_ops._git(
                "--literal-pathspecs", "restore", f"--source={start_tree}", "--worktree", "--", path,
                cwd=worktree,
            )
        except git_ops.GitError:
            out.failed.append(path)
        else:
            out.restored.append(path)
    return out
