"""The Git & PR panel's backend: in-app git visibility & lightweight actions.

The gated *merge* lives in integrate.py — that's the discipline, one shot,
green-only. This module covers the everyday git moments a developer would
otherwise alt-tab to a terminal (or GitHub) for:

  - **status**: current branch, base, ahead/behind, and the dirty file list
  - **log**: recent commits, with the ones this branch added since base marked
  - **commit**: make a checkpoint commit *without* merging (unlike integrate)
  - **pr**: PR state + CI checks + review count via the user's own ``gh`` CLI

Everything is local-first (the user's git binary / their authenticated ``gh``);
no OAuth, no libgit2 — same stance as git_ops.py.
"""

from __future__ import annotations

import asyncio
import json as _json

from . import git_ops
from .git_ops import GitError, _EXCLUDE, _git

# Human-readable meaning for the two-character porcelain XY status codes, so the
# UI can show "modified"/"new file" instead of raw "M "/"??" glyphs.
_XY = {
    "M": "modified",
    "A": "added",
    "D": "deleted",
    "R": "renamed",
    "C": "copied",
    "U": "unmerged",
    "?": "untracked",
    "!": "ignored",
    " ": "",
}


async def _gh(*args: str, cwd: str) -> tuple[int, str, str]:
    """Run the user's ``gh`` CLI. Returns (code, stdout, stderr); 127 if absent."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "gh", *args, cwd=cwd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        return 127, "", "`gh` CLI not found"
    out, err = await proc.communicate()
    return proc.returncode or 0, out.decode().strip(), err.decode().strip()


#: Why a workspace can have no worktree at all. Opening an ARCHIVED or merged workspace is
#: the common path: `remove_worktree` tears the directory down while the Workspace row stays
#: for history, so every git call below then dies with "not a git repository". A husk left by
#: an interrupted `git worktree remove` fails the same way (see `git_ops.worktree_valid`).
_GONE = (
    "this workspace has no worktree on disk: it was archived, merged, or its worktree was "
    "removed, so git actions aren't available"
)


def worktree_gone(worktree_path: str) -> bool:
    """True when git cannot run here. Checked BEFORE shelling out, because the failure
    modes are otherwise all bad in different ways: `log`/`pr_status` raised straight into a
    500, `commit`/`create_pr` surfaced a cryptic "fatal: not a git repository", and `status`
    was the worst of the three — it swallowed the GitError and returned ahead/behind/dirty
    all **zero**, which is a confident wrong answer rather than an error (the same
    never-silently-pass rule as backlog/double-gate.md §0)."""
    return not git_ops.worktree_valid(worktree_path)


async def status(worktree_path: str, branch: str, base_ref: str) -> dict:
    """Branch state + dirty files (relative to what's committed).

    ``ahead``/``behind`` count commits between ``base_ref`` and HEAD — how far
    this branch's own work has diverged from where it started.
    """
    if worktree_gone(worktree_path):
        # Report "unknown", never a measured-looking zero.
        return {
            "branch": branch, "base_ref": base_ref, "ahead": 0, "behind": 0,
            "dirty": 0, "files": [], "worktree_missing": True,
        }

    # Ahead/behind vs base. `A...B --left-right --count` -> "<behind>\t<ahead>".
    ahead = behind = 0
    try:
        rl = await _git("rev-list", "--left-right", "--count", f"{base_ref}...HEAD", cwd=worktree_path)
        left, right = rl.split()
        behind, ahead = int(left), int(right)
    except (GitError, ValueError):
        pass

    # Dirty files (staged + unstaged + untracked), hiding the node_modules symlink.
    files: list[dict] = []
    try:
        porcelain = await _git("status", "--porcelain=v1", *_EXCLUDE, cwd=worktree_path)
        for raw in porcelain.splitlines():
            if len(raw) < 3:
                continue
            x, y, path = raw[0], raw[1], raw[3:]
            # Renames read "R  old -> new"; show the new path.
            if " -> " in path:
                path = path.split(" -> ", 1)[1]
            files.append({
                "path": path,
                "index": _XY.get(x, ""),   # staged change
                "work": _XY.get(y, ""),    # unstaged change
                "staged": x not in " ?",
            })
    except GitError:
        pass

    return {
        "branch": branch,
        "base_ref": base_ref,
        "ahead": ahead,
        "behind": behind,
        "dirty": len(files),
        "files": files,
    }


async def log(worktree_path: str, base_ref: str, limit: int = 30) -> list[dict]:
    """Recent commits, newest first. Commits added since ``base_ref`` on this
    branch are flagged ``own=True`` (the work this workspace produced)."""
    if worktree_gone(worktree_path):
        return []
    # Which shas are unique to this branch vs base? (the workspace's own commits)
    own: set[str] = set()
    try:
        rl = await _git("rev-list", f"{base_ref}..HEAD", cwd=worktree_path)
        own = {s.strip() for s in rl.splitlines() if s.strip()}
    except GitError:
        pass

    # Unit-separated fields, record-separated commits — robust against spaces.
    fmt = "%H%x1f%h%x1f%an%x1f%ar%x1f%s%x1e"
    try:
        out = await _git("log", f"--pretty=format:{fmt}", "-n", str(limit), cwd=worktree_path)
    except GitError:
        return []

    commits: list[dict] = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        parts = rec.split("\x1f")
        if len(parts) != 5:
            continue
        sha, short, author, when, subject = parts
        commits.append({
            "sha": sha,
            "short": short,
            "author": author,
            "when": when,
            "subject": subject,
            "own": sha in own,
        })
    return commits


async def commit(worktree_path: str, message: str) -> dict:
    """Checkpoint commit of all worktree changes — no merge, no archive.

    Reuses git_ops.commit_all (which drops the node_modules symlink and falls
    back to a haro identity only if the repo configures none)."""
    if worktree_gone(worktree_path):
        raise GitError(["commit"], 128, _GONE)
    sha = await git_ops.commit_all(worktree_path, message)
    return {"committed": sha, "nothing_to_commit": sha is None}


async def _last_subject(worktree_path: str) -> str | None:
    """The branch tip's commit subject — a title for a PR we give an explicit body to."""
    try:
        return (await _git("log", "-1", "--format=%s", cwd=worktree_path)).strip() or None
    except GitError:
        return None


async def create_pr(
    worktree_path: str, branch: str, base_ref: str, body: str | None = None
) -> dict:
    """Open a PR for this branch via ``gh`` — push + ``gh pr create`` — WITHOUT
    merging. The team/junior path: request review instead of merging directly
    (useful when the repo blocks direct merges for non-maintainers).

    Idempotent: if a PR already exists we return its URL instead of erroring, so
    the button can flip to "open PR ↗" either way. ``gh``'s ``--fill`` derives the
    title/body from the branch's commits (which is why we require a commit first).

    ``body`` replaces that derived body with our own text — used by the autonomy
    ladder's ``auto_pr`` rung to embed the trust report that authorized it
    (backlog/autonomy-ladder.md §3). ``--body`` can't be combined with ``--fill``, and
    a ``gh pr create`` with no title would *prompt* (a hang, in a subprocess), so we
    pair it with the tip commit's subject as the title — and fall back to plain
    ``--fill`` if that lookup fails. Attribution is worth a lot; a hung rung is not."""
    if worktree_gone(worktree_path):
        raise GitError(["pr", "create"], 128, _GONE)
    if not await git_ops.has_remote(worktree_path):
        raise GitError(
            ["pr", "create"], 1,
            "no git remote: connect one to open a PR (local repos merge directly)",
        )
    # gh wants the bare remote branch name for --base ("main", not "origin/main").
    base_branch = base_ref[len("origin/"):] if base_ref.startswith("origin/") else base_ref
    await git_ops.push_branch(worktree_path, branch)
    title = await _last_subject(worktree_path) if body else None
    fill = ["--title", title, "--body", body] if (body and title) else ["--fill"]
    code, out, err = await _gh(
        "pr", "create", *fill, "--head", branch, "--base", base_branch,
        cwd=worktree_path,
    )
    if code == 0:
        return {"created": True, "already_exists": False,
                "url": out if out.startswith("http") else None}
    low = (err or out).lower()
    if "already exists" in low:
        vcode, vout, _ = await _gh(
            "pr", "view", branch, "--json", "url", "-q", ".url", cwd=worktree_path
        )
        return {"created": False, "already_exists": True,
                "url": vout if vcode == 0 and vout.startswith("http") else None}
    if code == 127:
        raise GitError(["pr", "create"], 127, "`gh` CLI not found: install it to open PRs")
    raise GitError(["pr", "create"], code, err or out)


async def comment_pr(worktree_path: str, branch: str, body: str) -> dict:
    """Post ``body`` as a comment on ``branch``'s PR via ``gh pr comment``.

    Used by the Gate Receipt's PR-comment sink (receipt.py): the evidence packet
    travels to a reviewer who never installed haro. Requires an existing PR —
    unlike ``create_pr`` this never opens one, since commenting on a PR that
    doesn't exist yet isn't a sensible default action to take automatically."""
    if worktree_gone(worktree_path):
        raise GitError(["pr", "comment"], 128, _GONE)
    if not await git_ops.has_remote(worktree_path):
        raise GitError(["pr", "comment"], 1, "no git remote: PR comments need a remote")
    code, out, err = await _gh(
        "pr", "comment", branch, "--body", body, cwd=worktree_path,
    )
    if code == 127:
        raise GitError(["pr", "comment"], 127, "`gh` CLI not found: install it to comment on PRs")
    if code != 0:
        low = (err or out).lower()
        if "no pull requests found" in low or "could not find" in low:
            raise GitError(
                ["pr", "comment"], code,
                f"no open PR for '{branch}' yet — open one first, then post the receipt",
            )
        raise GitError(["pr", "comment"], code, err or out)
    return {"posted": True, "url": out if out.startswith("http") else None}


async def pr_status(worktree_path: str, branch: str) -> dict:
    """PR state + CI checks + review count for this branch, via ``gh``.

    Degrades gracefully: no remote / no gh / no PR yet all return a benign
    ``supported``/``exists`` shape rather than an error — the panel just shows
    "no PR yet" and offers the merge button, which opens one.
    """
    if worktree_gone(worktree_path):
        return {"supported": False, "reason": _GONE}
    if not await git_ops.has_remote(worktree_path):
        return {"supported": False, "reason": "no git remote: local-only workspace"}

    code, out, err = await _gh(
        "pr", "view", branch,
        "--json", "number,title,state,headRefOid,url,isDraft,mergeable,reviewDecision,"
                  "statusCheckRollup,comments,additions,deletions",
        cwd=worktree_path,
    )
    if code == 127:
        return {"supported": False, "reason": "`gh` CLI not found: install it to see PRs"}
    if code != 0:
        # gh exits non-zero when no PR exists for the branch — that's expected.
        low = (err or out).lower()
        if "no pull requests found" in low or "no default remote" in low or "could not resolve" in low:
            return {"supported": True, "exists": False}
        return {"supported": True, "exists": False, "reason": err or out}

    try:
        pr = _json.loads(out)
    except _json.JSONDecodeError:
        return {"supported": True, "exists": False, "reason": "unparseable gh output"}

    # Flatten CI checks into pass/fail/pending tallies + a per-check list.
    checks: list[dict] = []
    passed = failed = pending = 0
    for c in pr.get("statusCheckRollup") or []:
        # Check runs use conclusion+status; commit statuses use state.
        concl = (c.get("conclusion") or c.get("state") or "").upper()
        st = (c.get("status") or "").upper()
        name = c.get("name") or c.get("context") or "check"
        if st and st != "COMPLETED":
            bucket, pending = "pending", pending + 1
        elif concl in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            bucket, passed = "pass", passed + 1
        elif concl in ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"):
            bucket, failed = "fail", failed + 1
        else:
            bucket, pending = "pending", pending + 1
        checks.append({"name": name, "bucket": bucket,
                       "url": c.get("detailsUrl") or c.get("targetUrl") or ""})

    return {
        "supported": True,
        "exists": True,
        "number": pr.get("number"),
        "title": pr.get("title"),
        "state": pr.get("state"),
        "head_sha": pr.get("headRefOid"),
        "url": pr.get("url"),
        "draft": pr.get("isDraft", False),
        "mergeable": pr.get("mergeable"),
        "review_decision": pr.get("reviewDecision") or "",
        "comments": len(pr.get("comments") or []),
        "additions": pr.get("additions", 0),
        "deletions": pr.get("deletions", 0),
        "checks": checks,
        "checks_passed": passed,
        "checks_failed": failed,
        "checks_pending": pending,
    }
