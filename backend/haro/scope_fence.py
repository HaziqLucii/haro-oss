"""Scope fence: the agent may only edit the paths the developer handed it.

A run carries a list of paths and globs. Reading stays unrestricted; only edits are fenced.

The fence is enforced on the result, not on the tools. The agent has a shell, so deny rules on
its edit tools are a speed bump at best (see ``protect_tests.py``). What cannot be bypassed is
the worktree itself: when the run starts we snapshot it as a git tree, when it ends we snapshot
it again, and every path that changed in between and does not match the fence is put back as it
was at the start. Comparing against the start snapshot (not HEAD) matters: the developer's own
uncommitted stubs, which are the whole point of fencing, are in that snapshot and must survive.

Both snapshots go through a throwaway copy of the real index (``GIT_INDEX_FILE``), so the
worktree's own index and the developer's staging are never touched. Ignored files are not part
of a snapshot, so build output and ``node_modules`` are never fenced or reverted. The tree of
the run's end state is kept under ``refs/haro/scope/<run id>`` before anything is reverted, so
reverted work is recoverable. A concurrent edit by the developer in a fenced-out file during
the run looks the same as the agent's and is reverted too; the backup ref is what covers that.
"""

from __future__ import annotations

import contextlib
import os
import re
import secrets
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import command_guard, git_ops

MAX_PATTERNS = 50
_GLOB_CHARS = frozenset("*?[")
REF_PREFIX = "refs/haro/scope/"


class ScopeError(ValueError):
    """A fence that cannot be armed (bad pattern list)."""


def normalize(patterns: list[str] | None) -> list[str]:
    """Trim, drop blanks and duplicates, strip a leading ``./`` or ``/``. Raises on a list
    too long to be a deliberate fence."""
    out: list[str] = []
    for raw in patterns or []:
        p = raw.strip().replace("\\", "/")
        if p in {".", "./", "/"}:
            p = "**"  # the whole tree: a vacuous but deliberate fence
        while p.startswith("./"):
            p = p[2:]
        p = p.lstrip("/")
        if p and p not in out:
            out.append(p)
    if len(out) > MAX_PATTERNS:
        raise ScopeError(f"a scope fence takes at most {MAX_PATTERNS} paths")
    return out


def _glob_to_regex(pattern: str) -> re.Pattern[str]:
    """gitignore-flavoured glob to an anchored regex. ``**/`` spans directories, ``*`` and
    ``?`` stay inside one path segment, a slash-less pattern matches at any depth, and a
    match on a directory covers everything under it."""
    i, n, out = 0, len(pattern), []
    while i < n:
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "[":
            j = pattern.find("]", i + 2)
            if j == -1:
                out.append(re.escape(c))
                i += 1
            else:
                body = pattern[i + 1 : j]
                negate = body.startswith("!")
                if negate:
                    body = body[1:]
                body = body.replace("\\", "\\\\").replace("[", "\\[").replace("^", "\\^")
                out.append("[" + ("^" if negate else "") + body + "]")
                i = j + 1
        else:
            out.append(re.escape(c))
            i += 1
    prefix = "(?:.*/)?" if "/" not in pattern else ""
    try:
        return re.compile(prefix + "".join(out) + "(?:/.*)?", re.DOTALL)
    except re.error as exc:
        raise ScopeError(f"bad pattern {pattern!r}: {exc}") from exc


@dataclass
class Fence:
    patterns: list[str]
    _globs: list[re.Pattern[str]] = field(default_factory=list, repr=False)
    _prefixes: list[str] = field(default_factory=list, repr=False)

    @classmethod
    def build(cls, patterns: list[str] | None) -> "Fence":
        pats = normalize(patterns)
        fence = cls(patterns=pats)
        for p in pats:
            if _GLOB_CHARS & set(p):
                fence._globs.append(_glob_to_regex(p.rstrip("/")))
            else:
                fence._prefixes.append(p.rstrip("/"))
        return fence

    def allows(self, path: str) -> bool:
        """True when ``path`` (repo-relative, forward slashes) is inside the fence. A plain
        path allows itself and, when it is a directory, everything under it."""
        for pre in self._prefixes:
            if path == pre or path.startswith(pre + "/"):
                return True
        return any(g.fullmatch(path) for g in self._globs)


@dataclass
class ArmedFence:
    """A fence that is live for one run, so the PreToolUse hook the CLI calls can ask haro whether
    an edit is inside it (same matching as the revert after the run)."""

    #: None on a run with no fence: the hook then only runs the command guard.
    fence: Fence | None
    worktree: str
    #: Repo-relative paths the hook refused before the write, in order, each once.
    blocked: list[str] = field(default_factory=list)
    #: Whether Bash and Read calls go through ``command_guard`` (``[agent] command_guard``).
    guard: bool = False
    #: Labels of the commands and reads the guard refused before they ran, in order, each once.
    refused: list[str] = field(default_factory=list)
    #: Secret part of the hook URL: the endpoint is local and unauthenticated, so a page or process
    #: that does not hold it cannot add refusals to a run's receipt or probe its fence.
    token: str = field(default_factory=lambda: secrets.token_urlsafe(16))


_ARMED: dict[str, ArmedFence] = {}

_EDIT_TOOL_NAMES = ("Edit", "Write", "MultiEdit", "NotebookEdit")
_GUARD_TOOL_NAMES = ("Bash", "Read")
_EDIT_TOOLS = frozenset(_EDIT_TOOL_NAMES)


_GUARD_TOOLS = frozenset(_GUARD_TOOL_NAMES)


def hook_matcher(fenced: bool, guarded: bool) -> str:
    """The PreToolUse matcher for a run: the edit tools when it is fenced, Bash and Read when the
    command guard is on."""
    return "|".join([*(_EDIT_TOOL_NAMES if fenced else ()), *(_GUARD_TOOL_NAMES if guarded else ())])


def arm(fence: Fence | None, worktree: str, guard: bool = False) -> ArmedFence:
    armed = ArmedFence(fence=fence, worktree=worktree, guard=guard)
    _ARMED[armed.token] = armed
    return armed


def disarm(armed: ArmedFence) -> None:
    _ARMED.pop(armed.token, None)


def judge(token: str, event: dict) -> dict:
    """The answer to a PreToolUse hook call (``token`` is the armed fence's URL secret): ``{}`` lets the tool run, a deny carries a reason the
    agent reads. Only edits inside the worktree are judged (anything else is not this fence's
    business) and an unknown token is allowed: the revert after the run is the real check, this is
    the early warning."""
    armed = _ARMED.get(token)
    tool = event.get("tool_name")
    if armed is None:
        return {}
    tool_input = event.get("tool_input") or {}
    if armed.guard and tool in _GUARD_TOOLS:
        label = command_guard.refusal(tool, tool_input, armed.worktree)
        if label is None:
            return {}
        if label not in armed.refused:
            armed.refused.append(label)
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": command_guard.reason(label),
            }
        }
    if tool not in _EDIT_TOOLS or armed.fence is None:
        return {}
    raw = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not raw:
        return {}
    root = os.path.realpath(armed.worktree)
    # A relative path is relative to the worktree the agent runs in, not to this process.
    rel = os.path.relpath(os.path.realpath(os.path.join(root, raw)), root).replace(os.sep, "/")
    if rel == ".." or rel.startswith("../") or armed.fence.allows(rel):
        return {}
    if rel not in armed.blocked:
        armed.blocked.append(rel)
    listed = ", ".join(f"`{p}`" for p in armed.fence.patterns)
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"Outside the scope fence: in this run you may only edit {listed}. `{rel}` is not "
                "allowed and nothing was written. Do not work around it (haro puts back anything "
                "outside the fence when the run ends): say which file the task needs and why, then stop."
            ),
        }
    }


def addendum(patterns: list[str]) -> str:
    """The standing instruction that tells the agent about its fence."""
    listed = "\n".join(f"- `{p}`" for p in patterns)
    return (
        "SCOPE FENCE: in this run you may create or edit only the files matching these paths:\n"
        f"{listed}\n"
        "Reading anything is fine. haro reverts every change outside this list when the run ends, "
        "so do not spend effort there. If the task needs a change outside the list, do not make "
        "it: say which file and why, and stop."
    )


async def _index_path(worktree: str) -> str:
    raw = (await git_ops._git("rev-parse", "--git-path", "index", cwd=worktree)).strip()
    return raw if os.path.isabs(raw) else os.path.join(worktree, raw)


async def snapshot_tree(worktree: str) -> str:
    """The sha of a git tree holding every tracked and untracked, non-ignored file in the
    worktree as it is right now, built in a temporary copy of the index."""
    real = await _index_path(worktree)
    fd, tmp = tempfile.mkstemp(prefix="haro-scope-index-")
    os.close(fd)
    try:
        if os.path.exists(real):
            shutil.copyfile(real, tmp)
        else:
            os.unlink(tmp)  # git builds a fresh index at a path that does not exist
        env = {"GIT_INDEX_FILE": tmp}
        await git_ops._git("add", "-A", cwd=worktree, env=env)
        return (await git_ops._git("write-tree", cwd=worktree, env=env)).strip()
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)


@dataclass
class FenceResult:
    reverted: list[str] = field(default_factory=list)
    backup_ref: str | None = None
    #: Every path the run changed, inside the fence or not, before anything was reverted.
    changed: list[str] = field(default_factory=list)
    #: Paths that were outside the fence but could not be put back (git refused, or the path
    #: resolves outside the worktree). They are still on disk: the dev must look at them.
    failed: list[str] = field(default_factory=list)


def _parse_name_status(raw: str) -> list[tuple[str, str]]:
    parts = raw.split("\0")
    out: list[tuple[str, str]] = []
    for i in range(0, len(parts) - 1, 2):
        if parts[i]:
            out.append((parts[i][0], parts[i + 1]))
    return out


async def _name_status(worktree: str, before_tree: str, after_tree: str) -> list[tuple[str, str]]:
    raw = await git_ops._git(
        "diff-tree", "-r", "--name-status", "-z", "--no-renames", before_tree, after_tree, cwd=worktree
    )
    return _parse_name_status(raw)


async def changed_since(worktree: str, before_tree: str) -> list[str]:
    """Every path that differs between ``before_tree`` and the worktree now. For a run with no
    fence: the files it left changed, whatever tool wrote them (its shell included)."""
    after = await snapshot_tree(worktree)
    if after == before_tree:
        return []
    return sorted(p for _s, p in await _name_status(worktree, before_tree, after))


async def _backup(worktree: str, tree: str, run_id: str) -> str:
    ident = {
        "GIT_AUTHOR_NAME": "haro", "GIT_AUTHOR_EMAIL": "haro@localhost",
        "GIT_COMMITTER_NAME": "haro", "GIT_COMMITTER_EMAIL": "haro@localhost",
    }
    sha = (await git_ops._git(
        "commit-tree", tree, "-m",
        f"haro scope fence: the worktree before out-of-scope edits of {run_id} were reverted",
        cwd=worktree, env=ident,
    )).strip()
    ref = f"{REF_PREFIX}{run_id}"
    await git_ops._git("update-ref", ref, sha, cwd=worktree)
    return ref


def _remove_added(worktree: str, rel: str) -> bool:
    """Delete a path the run added. Unlinks the path itself (a symlink is removed, never what
    it points to) and refuses when the containing directory resolves outside the worktree."""
    root = Path(worktree).resolve()
    target = root / rel
    parent = target.parent.resolve()
    if parent != root and root not in parent.parents:
        return False
    try:
        target.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        return False
    while parent != root:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent
    return True


async def enforce(worktree: str, fence: Fence, before_tree: str, run_id: str) -> FenceResult:
    """Put back every path changed since ``before_tree`` that the fence does not allow.

    A path the run added is deleted; a path it modified or deleted is restored from the start
    snapshot. The working tree only: the index is left alone."""
    after = await snapshot_tree(worktree)
    if after == before_tree:
        return FenceResult()
    entries = await _name_status(worktree, before_tree, after)
    changed = sorted(p for _s, p in entries)
    outside = [(s, p) for s, p in entries if not fence.allows(p)]
    if not outside:
        return FenceResult(changed=changed)
    backup = await _backup(worktree, after, run_id)
    added = [p for st, p in outside if st == "A"]
    restore = [p for st, p in outside if st != "A"]
    done: list[str] = []
    failed: list[str] = []
    # Added paths first: a file replaced by a directory is `D a` plus `A a/b`, and `a` can only
    # be restored once `a/b` is gone. One path failing must not stop the others.
    for path in added:
        (done if _remove_added(worktree, path) else failed).append(path)
    for path in restore:
        try:
            await git_ops._git(
                "--literal-pathspecs", "restore", f"--source={before_tree}", "--worktree", "--", path,
                cwd=worktree,
            )
        except git_ops.GitError:
            failed.append(path)
        else:
            done.append(path)
    return FenceResult(reverted=sorted(done), backup_ref=backup, failed=sorted(failed), changed=changed)
