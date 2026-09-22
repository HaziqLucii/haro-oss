"""Thin async wrappers around the local ``git`` CLI.

Local-first by design (see CLAUDE.md): we drive the user's own git binary via
subprocess — no libgit2, no network, no GitHub OAuth. Every call is async so it
never blocks FastAPI's event loop while a worktree is being created or diffed.
"""

from __future__ import annotations

import asyncio
import os
import re
import shutil
from collections.abc import Iterable
from pathlib import Path

from .config import settings


# Pathspec that keeps haro's own generated artifacts out of diffs and impact
# analysis: the injected node_modules symlink (see gate.ensure_deps — a
# ``node_modules/`` gitignore rule matches directories, not the symlink we
# create, so it needs an explicit exclude) and saved `haro gate --attest`
# statements (usp-critique-round3.md Move A — otherwise attesting pollutes the
# very diff it just described, and every diff thereafter self-reports stale).
_EXCLUDE = ("--", ".", ":(exclude)node_modules", ":(exclude).haro/attestations")

# The same pathspec minus the exclude, for `git add`: naming an *already ignored*
# path in a pathspec makes `git add` abort ("The following paths are ignored by one
# of your .gitignore files"). See `_add_pathspec`.
_ADD_ONLY = ("--", ".")


# Credential-helper override, injected before every git subcommand.
#
# `gh auth setup-git` writes an ABSOLUTE path to the helper into ~/.gitconfig (e.g.
# `/opt/homebrew/bin/gh` on this machine). Worktrees share that config, so an
# absolute path baked in on one machine can be wrong on another — git then runs a
# missing binary, the helper errors, and push/PR-create fall through to a terminal
# prompt that can't be answered → "could not read Username" fatal.
#
# The empty first value RESETS the accumulated (broken, absolute-path) helper list
# read from the global config; the second re-adds a PATH-resolved `gh`, so it works
# regardless of where `gh` is installed. Injected via `-c` so it lands LAST, after
# the global config.
_CRED_OVERRIDE = (
    "-c", "credential.helper=",
    "-c", "credential.helper=!gh auth git-credential",
)


# "Don't firewall ourselves" marker, injected into every git subprocess env.
#
# The Merge Firewall (backlog/merge-firewall.md §3) installs a repo-level pre-push /
# pre-merge-commit hook that refuses to merge a branch whose gate isn't green — and under
# `[trust] strict` it also blocks branches it doesn't govern. But haro's OWN integration
# path merges/commits git for you: integrate's `local_merge` makes a merge commit onto the
# base branch (`main`), the merge queue drives the same path, and the gate's
# `snapshot_worktree_commit` / `create_merge_worktree` build throwaway merge commits. Under
# strict, that base branch reads as "unknown" and the hook would block haro merging its own
# green work — haro firewalling itself. git passes its process env down to the hooks it
# spawns, so tagging every git we run with `HARO_INTERNAL=1` lets `hook.sh` recognize a
# haro-driven operation and step aside.
#
# This is a CONVENIENCE SEAM, NOT A SECURITY BOUNDARY: any process can set the var, so it
# cannot authenticate that haro is the caller — it only prevents the self-deadlock. Real
# enforcement lives in the verdict oracle (a red gate blocks regardless of this marker,
# because haro never merges red work through `integrate`).
_INTERNAL_ENV = {"HARO_INTERNAL": "1"}


class GitError(RuntimeError):
    """A git command exited non-zero. Carries stderr for surfacing to the UI."""

    def __init__(self, args: list[str], code: int, stderr: str):
        self.args = args
        self.code = code
        self.stderr = stderr.strip()
        super().__init__(f"git {' '.join(args)} -> exit {code}: {self.stderr}")


# Per-directory locks that serialize git subprocesses sharing a working tree.
#
# git guards each index with an `index.lock` file: any command that may write
# the index (`add`, `commit`, and even `diff`, which we precede with `add -A -N`
# to surface untracked files) creates the lock, then removes it. If a second git
# process hits the *same* worktree while the first still holds it, git aborts
# with "Unable to create '.../index.lock': File exists". The UI triggers exactly
# this: loading a workspace fires the diff and impact-map endpoints concurrently,
# so two `git add -A -N` land on one worktree at once. Since every git call in
# this process funnels through `_git`, one lock per `cwd` makes those calls queue
# instead of collide — the whole class of race disappears, cheaply (git is fast).
_cwd_locks: dict[str, asyncio.Lock] = {}


def _lock_for(cwd: str | Path | None) -> asyncio.Lock:
    key = str(Path(cwd)) if cwd else "<cwd:none>"
    lock = _cwd_locks.get(key)
    if lock is None:
        lock = asyncio.Lock()
        _cwd_locks[key] = lock
    return lock


async def _git(*args: str, cwd: str | Path | None = None, env: dict[str, str] | None = None) -> str:
    """Run a git command, returning stdout. Raises GitError on failure.

    Serialized per `cwd` (see `_cwd_locks`): only one git subprocess runs in a
    given working tree at a time, so two commands can never fight over that
    tree's `index.lock`. `env` merges over the inherited environment (used by
    `push` to disable credential prompts so a missing token fails fast). Every
    call also carries `HARO_INTERNAL=1` (see `_INTERNAL_ENV`) so the Merge
    Firewall hook lets haro's own merges/pushes through.
    """
    async with _lock_for(cwd):
        proc = await asyncio.create_subprocess_exec(
            "git",
            *_CRED_OVERRIDE,
            *args,
            cwd=str(cwd) if cwd else None,
            env={**os.environ, **_INTERNAL_ENV, **(env or {})},
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await proc.communicate()
    if proc.returncode != 0:
        raise GitError(list(args), proc.returncode or -1, err.decode())
    return out.decode()


async def is_git_repo(path: str | Path) -> bool:
    # OSError (incl. FileNotFoundError/NotADirectoryError) fires when `path` doesn't
    # exist yet — e.g. creating a brand-new project, where git can't even spawn with
    # cwd set to a missing dir. That's simply "not a repo", not a server error.
    try:
        out = await _git("rev-parse", "--is-inside-work-tree", cwd=path)
        return out.strip() == "true"
    except (GitError, OSError):
        return False


async def default_branch(path: str | Path) -> str:
    """Best-effort detection of the repo's default branch.

    Prefers ``origin/HEAD`` when a remote exists; falls back to the current
    branch (fresh local repos have no remote HEAD symref).
    """
    try:
        out = await _git("symbolic-ref", "--short", "refs/remotes/origin/HEAD", cwd=path)
        return out.strip().split("/", 1)[-1]
    except GitError:
        pass
    out = await _git("rev-parse", "--abbrev-ref", "HEAD", cwd=path)
    return out.strip()


async def init_repo(path: str | Path, default_branch: str = "main") -> None:
    """``git init`` a folder (creating it if missing) on ``default_branch``, with a
    single empty initial commit.

    The empty commit is not optional: a fresh ``git init`` leaves the branch
    *unborn* (no commit), and the platform's core primitive —
    ``git worktree add -b <branch> <path> <base_ref>`` — needs ``base_ref`` to
    resolve to a real commit. Without it, the first "new workspace" would fail.
    No-op if the path is already a git repo."""
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    if (p / ".git").exists():
        return
    # git >= 2.28 supports `init -b`; fall back to a post-init symbolic-ref.
    try:
        await _git("init", "-b", default_branch, cwd=path)
    except GitError:
        await _git("init", cwd=path)
        try:
            await _git("symbolic-ref", "HEAD", f"refs/heads/{default_branch}", cwd=path)
        except GitError:
            pass
    # Fall back to a haro identity only if the repo/user has none configured,
    # mirroring commit_all so a bare machine can still make the initial commit.
    idflags: list[str] = []
    try:
        email = await _git("config", "user.email", cwd=path)
        if not email.strip():
            raise GitError(["config"], 1, "")
    except GitError:
        idflags = ["-c", "user.name=haro", "-c", "user.email=haro@local"]
    await _git(*idflags, "commit", "--allow-empty", "-m", "Initial commit", cwd=path)


async def _mark_untracked(worktree_path: str | Path) -> None:
    """Intent-to-add untracked files so new files show up in diffs.

    We deliberately do NOT pass an ``:(exclude)node_modules`` pathspec here: git
    raises a fatal "paths are ignored" error when an exclude pathspec is combined
    with an ignored path that actually exists (e.g. a real node_modules dir the
    agent created). Plain ``git add -A -N .`` instead silently skips a genuinely
    ignored node_modules, and the injected symlink (which gitignore's dir rule
    doesn't match) is filtered out later by the diff's exclude pathspec."""
    await _git("add", "-A", "-N", ".", cwd=worktree_path)


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "task"


async def add_worktree(
    repo_path: str | Path,
    worktree_path: str | Path,
    branch: str,
    base_ref: str,
) -> None:
    """``git worktree add -b <branch> <path> <base_ref>``.

    Creates an isolated checkout on a brand-new branch. The main working tree is
    never touched — this is the core isolation primitive of the whole product.
    """
    Path(worktree_path).parent.mkdir(parents=True, exist_ok=True)
    await _git(
        "worktree",
        "add",
        "-b",
        branch,
        str(worktree_path),
        base_ref,
        cwd=repo_path,
    )


async def rename_branch(worktree_path: str | Path, old_branch: str, new_branch: str) -> None:
    """``git branch -m <old> <new>``, run inside the worktree that has it checked
    out. Renaming the branch a worktree is on updates that worktree's HEAD symref
    in place — the worktree directory/path is untouched (it's addressed by
    workspace id/slug, never by branch name). Local-only: any existing remote
    tracking ref keeps its old name until the caller pushes the new one."""
    await _git("branch", "-m", old_branch, new_branch, cwd=worktree_path)


async def ensure_excluded(worktree_path: str | Path, pattern: str) -> None:
    """Idempotently add ``pattern`` to the repo's local ``.git/info/exclude``.

    Used for haro's ``.context/`` handoff folder (pasted-block attachments): those
    files must never show as dirty or land in a diff, or they'd block the commit-first
    merge gate and pollute PRs. ``info/exclude`` is local-only (never committed), so
    this keeps the convention private without touching the tracked ``.gitignore``.
    ``--git-common-dir`` resolves the shared .git even from a linked worktree."""
    common = (await _git("rev-parse", "--git-common-dir", cwd=worktree_path)).strip()
    exclude = Path(worktree_path) / common / "info" / "exclude" if not Path(common).is_absolute() \
        else Path(common) / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude.read_text().splitlines() if exclude.exists() else []
    if pattern not in existing:
        with exclude.open("a") as fh:
            fh.write(("" if not existing or existing[-1] == "" else "\n") + pattern + "\n")


async def checkout_new_branch(
    worktree_path: str | Path, new_branch: str, base_ref: str
) -> None:
    """``git checkout -b <new_branch> <base_ref>`` inside an existing worktree.

    The re-branch primitive for "Continue on a new branch": after a merge lands, the
    worktree stays checked out on the (now-merged) branch — this switches it onto a
    fresh branch off the *updated* base (fetch first so ``origin/<base>`` includes the
    work just merged), keeping the same worktree dir + agent session. ``-b`` creates
    the branch pointing at base_ref's commit without checking out base itself, so it's
    worktree-safe even when base_ref is already checked out in the main tree."""
    await _git("checkout", "-b", new_branch, base_ref, cwd=worktree_path)


async def has_remote(repo_path: str | Path) -> bool:
    out = await _git("remote", cwd=repo_path)
    return bool(out.strip())


async def fetch(repo_path: str | Path, remote: str = "origin") -> None:
    """Update remote-tracking refs (e.g. ``origin/main``) from ``remote``.

    ``GIT_TERMINAL_PROMPT=0`` so a missing credential fails fast instead of hanging
    on an interactive prompt. Used before creating a workspace so it branches off
    the *latest* integrated remote tip, not a drifted local branch."""
    await _git("fetch", remote, cwd=repo_path, env={"GIT_TERMINAL_PROMPT": "0"})


async def ref_exists(repo_path: str | Path, ref: str) -> bool:
    """True if ``ref`` resolves (e.g. ``origin/main`` exists after a fetch)."""
    try:
        await _git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", cwd=repo_path)
        return True
    except GitError:
        return False


async def get_remote(repo_path: str | Path, name: str = "origin") -> str | None:
    """The push/fetch URL for ``name`` (default ``origin``), or None if unset.

    A remote lives in the repo's shared ``.git``, so it's a *project-level* fact —
    every worktree of the repo inherits it (used to choose the merge path: local
    vs. ``gh`` PR, and to push branches)."""
    try:
        out = await _git("remote", "get-url", name, cwd=repo_path)
        return out.strip() or None
    except GitError:
        return None


def web_url_from_remote(remote: str | None) -> str | None:
    """Normalize a git ``origin`` URL into its browsable web base
    (``https://host/owner/repo``), or None if it isn't recognizably one.

    Handles the three shapes git stores: scp-style ssh (``git@github.com:o/r.git``),
    ssh URLs (``ssh://git@github.com/o/r.git``), and https (with or without a
    userinfo prefix / ``.git`` suffix). Used to deep-link a typed ``PR #12`` to its
    GitHub page without a network call — the number is trusted, the base is derived."""
    if not remote:
        return None
    url = remote.strip()
    if not url:
        return None
    host_path: str | None = None
    if url.startswith("git@") or (":" in url and "://" not in url and "@" in url.split(":", 1)[0]):
        # scp-style: git@host:owner/repo(.git)
        _, _, rest = url.partition("@")
        host, _, path = rest.partition(":")
        host_path = f"{host}/{path}"
    elif "://" in url:
        # scheme://[user@]host/owner/repo(.git)
        after = url.split("://", 1)[1]
        if "@" in after.split("/", 1)[0]:
            after = after.split("@", 1)[1]
        host_path = after
    else:
        return None
    host_path = host_path.strip("/")
    if host_path.endswith(".git"):
        host_path = host_path[: -len(".git")]
    # Require at least host + owner + repo to be a real repo web base.
    if host_path.count("/") < 2:
        return None
    return f"https://{host_path}"


async def set_remote(repo_path: str | Path, url: str, name: str = "origin") -> None:
    """Point ``name`` at ``url`` — ``remote add`` if new, else ``set-url``. Idempotent."""
    if await get_remote(repo_path, name) is None:
        await _git("remote", "add", name, url, cwd=repo_path)
    else:
        await _git("remote", "set-url", name, url, cwd=repo_path)


async def remove_remote(repo_path: str | Path, name: str = "origin") -> None:
    """Unlink ``name`` (back to local-only). No-op if it doesn't exist."""
    try:
        await _git("remote", "remove", name, cwd=repo_path)
    except GitError:
        pass


async def set_config(repo_path: str | Path, key: str, value: str) -> None:
    """Set a *local* git config key in the repo (``git config <key> <value>``).

    Used by the Merge Firewall installer to write the two keys the hook reads:
    ``haro.url`` (backend location for non-default ports) and ``haro.strict`` (the
    fail-closed toggle). Local scope, so it lands in the shared ``.git/config`` every
    worktree already inherits."""
    await _git("config", key, value, cwd=repo_path)


async def unset_config(repo_path: str | Path, key: str) -> None:
    """Best-effort remove a local git config key (``git config --unset``). A no-op
    when the key is already absent — git exits 5, which we swallow — so unsetting
    ``haro.url`` back to the default is idempotent."""
    try:
        await _git("config", "--unset", key, cwd=repo_path)
    except GitError:
        pass


async def get_config(repo_path: str | Path, key: str) -> str | None:
    """Read a git config key (all scopes), returning ``None`` when unset. Used by the
    Merge Firewall installer to detect ``core.hooksPath`` — the husky/lefthook redirect
    that moves the active hooks dir out of ``$GIT_COMMON_DIR/hooks``."""
    try:
        out = await _git("config", "--get", key, cwd=repo_path)
    except GitError:
        return None
    val = out.strip()
    return val or None


async def head_sha(worktree_path: str | Path) -> str:
    """Current HEAD commit SHA (full) of the worktree — for comparing against a
    PR's headRefOid so a reused branch name's old merged PR isn't read as ours."""
    return (await _git("rev-parse", "HEAD", cwd=worktree_path)).strip()


async def current_branch(repo_path: str | Path) -> str:
    out = await _git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo_path)
    return out.strip()


async def list_branches(repo_path: str | Path) -> list[str]:
    """Local branch names (for the 'new workspace from a branch' picker)."""
    out = await _git("branch", "--format=%(refname:short)", cwd=repo_path)
    return [b.strip() for b in out.splitlines() if b.strip()]


async def list_remote_branches(repo_path: str | Path, remote: str = "origin") -> list[str]:
    """Remote-tracking branch names (e.g. ``origin/main``) for the base picker when
    a remote exists. Filters out the ``origin/HEAD`` symref. Caller should ``fetch``
    first so the list is current."""
    out = await _git("branch", "-r", "--format=%(refname:short)", cwd=repo_path)
    names = [b.strip() for b in out.splitlines() if b.strip()]
    return [b for b in names if not b.endswith("/HEAD") and " -> " not in b]


async def is_clean(repo_path: str | Path) -> bool:
    """True if the working tree has no changes (ignoring our node_modules symlink)."""
    out = await _git("status", "--porcelain", *_EXCLUDE, cwd=repo_path)
    return not out.strip()


async def ahead_count(worktree_path: str | Path, base_ref: str) -> int:
    """Commits on this branch that ``base_ref`` doesn't have — the work an archive
    would destroy, since ``remove_worktree`` finishes with ``git branch -D``.

    Raises ``GitError`` rather than reporting a comforting zero: the bulk-archive
    planner treats "couldn't measure" as risky, and a swallowed error here would
    hand it a clean-looking answer for a branch it never actually read
    (``git_panel.status``'s ahead/behind is the lenient display-side twin)."""
    out = await _git("rev-list", "--count", f"{base_ref}..HEAD", cwd=worktree_path)
    return int(out.strip() or 0)


async def commit_all(worktree_path: str | Path, message: str) -> str | None:
    """Stage & commit all worktree changes; return the commit sha, or None if
    there was nothing to commit.

    Removes the injected node_modules symlink first so it never enters history
    (gitignore then skips any real node_modules dir the agent created)."""
    nm = Path(worktree_path) / "node_modules"
    if nm.is_symlink():
        nm.unlink()
    await _git("add", "-A", ".", cwd=worktree_path)
    staged = await _git("diff", "--cached", "--name-only", cwd=worktree_path)
    if not staged.strip():
        return None
    # Fall back to a haro identity only if the repo has none configured.
    idflags: list[str] = []
    try:
        email = await _git("config", "user.email", cwd=worktree_path)
        if not email.strip():
            raise GitError(["config"], 1, "")
    except GitError:
        idflags = ["-c", "user.name=haro", "-c", "user.email=haro@local"]
    await _git(*idflags, "commit", "-m", message, cwd=worktree_path)
    sha = await _git("rev-parse", "HEAD", cwd=worktree_path)
    return sha.strip()


async def local_merge(
    repo_path: str | Path, branch: str, base_ref: str, message: str
) -> None:
    """Merge ``branch`` into ``base_ref`` in the main checkout (offline path).

    Requires the main checkout to be on ``base_ref`` and clean, so we never
    surprise the user by merging into the wrong branch or clobbering local work."""
    cur = await current_branch(repo_path)
    if cur != base_ref:
        raise GitError(
            ["merge"], 1, f"main checkout is on '{cur}', not base '{base_ref}': switch it first"
        )
    if not await is_clean(repo_path):
        raise GitError(["merge"], 1, "main checkout has uncommitted changes: commit or stash first")
    try:
        await _git("merge", "--no-ff", branch, "-m", message, cwd=repo_path)
    except GitError as exc:
        # A real content conflict leaves unmerged (stage-1/2/3) index entries; anything
        # else (a rejecting pre-merge-commit hook, gpg signing, an unmergeable ref) fails
        # without one, even though `--no-ff` still writes MERGE_HEAD before the commit is
        # attempted — so MERGE_HEAD alone can't tell the two apart. Only a real conflict
        # should get the "resolve conflicts" message; everything else keeps its real
        # stderr, or the actual cause vanishes.
        conflicted = False
        try:
            unmerged = await _git("diff", "--name-only", "--diff-filter=U", cwd=repo_path)
            conflicted = bool(unmerged.strip())
        except GitError:
            pass
        # Roll the main checkout back to pristine instead of leaving markers/MERGE_HEAD
        # on disk. `merge --abort` is a no-op-safe cleanup when there's nothing to abort.
        try:
            await _git("merge", "--abort", cwd=repo_path)
        except GitError:
            pass
        if not await is_clean(repo_path):
            # The one scenario this whole function exists to prevent: say so plainly
            # instead of reusing the conflict message, which would hide that `main` is
            # still stuck mid-merge.
            raise GitError(
                ["merge"], 1,
                f"merge of '{branch}' into {base_ref} failed and could not be cleanly "
                f"aborted — the main checkout may still be mid-merge; resolve it manually "
                f"before trying again. Original error: {exc.stderr}",
            ) from exc
        if conflicted:
            raise GitError(
                ["merge"], 1,
                f"'{branch}' conflicts with {base_ref} — merge {base_ref} into the "
                f"workspace and resolve the conflicts there, then merge again",
            ) from exc
        raise GitError(
            ["merge"], 1, f"merge of '{branch}' into {base_ref} failed: {exc.stderr}",
        ) from exc


async def push_branch(worktree_path: str | Path, branch: str) -> None:
    await _git("push", "-u", "origin", branch, cwd=worktree_path)


async def delete_remote_branch(
    worktree_path: str | Path, branch: str, remote: str = "origin"
) -> None:
    """Best-effort ``git push origin --delete <branch>`` after its PR merged.

    We do this ourselves instead of via ``gh pr merge --delete-branch``: gh's flag
    ALSO switches the local checkout off the branch first (``git checkout <base>``),
    which is fatal under worktrees — the base branch is already checked out in the
    main tree ("'main' is already used by worktree at …"). Pushing the delete only
    touches the remote ref, so it's worktree-safe. Non-fatal: the branch may already
    be gone (some merge settings delete it server-side)."""
    try:
        await _git(
            "push", remote, "--delete", branch, cwd=worktree_path,
            env={"GIT_TERMINAL_PROMPT": "0"},
        )
    except GitError:
        pass


async def push(repo_path: str | Path, branch: str, set_upstream: bool = True) -> str:
    """Push ``branch`` to origin (e.g. publish `main` to a freshly-linked remote).
    ``GIT_TERMINAL_PROMPT=0`` so a missing credential fails fast with a clear error
    instead of hanging on an interactive prompt. Returns git's stderr/stdout blurb."""
    args = ["push"]
    if set_upstream:
        args += ["-u"]
    args += ["origin", branch]
    return await _git(*args, cwd=repo_path, env={"GIT_TERMINAL_PROMPT": "0"})


async def pull(repo_path: str | Path, branch: str, remote: str = "origin") -> str:
    """Fast-forward ``branch`` to ``remote/branch`` in the main checkout.

    Requires the main checkout to already be on ``branch`` and clean, same
    guard as :func:`local_merge` — never surprise the user by pulling into
    the wrong branch or clobbering local work. ``--ff-only`` so a diverged
    history fails loudly instead of creating a merge commit or conflict."""
    cur = await current_branch(repo_path)
    if cur != branch:
        raise GitError(
            ["pull"], 1, f"main checkout is on '{cur}', not '{branch}': switch it first"
        )
    if not await is_clean(repo_path):
        raise GitError(["pull"], 1, "main checkout has uncommitted changes: commit or stash first")
    return await _git(
        "pull", "--ff-only", remote, branch, cwd=repo_path,
        env={"GIT_TERMINAL_PROMPT": "0"},
    )


async def add_detached_worktree(
    repo_path: str | Path, worktree_path: str | Path, ref: str
) -> None:
    """``git worktree add --detach <path> <ref>`` — a throwaway checkout at a ref
    (used to measure baseline coverage without a branch)."""
    Path(worktree_path).parent.mkdir(parents=True, exist_ok=True)
    await _git("worktree", "add", "--detach", str(worktree_path), ref, cwd=repo_path)


def worktree_valid(worktree_path: str | Path) -> bool:
    """True if the path is a usable worktree — i.e. its ``.git`` link exists.

    A directory *husk* left behind by an interrupted ``git worktree remove`` (the
    tree half-deleted, the ``.git`` link already gone) fails this check: any git
    command run inside it dies with "not a git repository". Callers use this to
    detect store↔disk desync before touching git."""
    return (Path(worktree_path) / ".git").exists()


def _norm_path(p: str | Path) -> str:
    """Canonicalize a path for cross-source equality. git prints *resolved*
    absolute paths in the porcelain output; the store saves whatever string a
    worktree was created with. Resolving both (following symlinks, e.g. macOS'
    ``/var`` → ``/private/var``) is what makes a tracked worktree compare equal
    instead of reading as foreign. Falls back to a lexical normalize if the path
    doesn't exist on disk (a stale store entry)."""
    try:
        return str(Path(p).resolve())
    except OSError:
        return os.path.normpath(str(p))


async def list_worktrees(
    repo_path: str | Path,
    tracked_paths: Iterable[str | Path] = (),
    worktree_root: str | Path | None = None,
) -> list[dict]:
    """Parse ``git worktree list --porcelain`` into structured rows — the scanner
    behind the Merge Firewall's "adopt foreign worktrees" flow (backlog/merge-firewall.md §1).

    Returns one dict per worktree (the repo's main checkout included), each::

        {path, branch, head, detached, bare, locked, prunable,
         tracked, under_worktree_root}

    ``branch`` is the short name (``refs/heads/x`` → ``x``), or ``None`` when the
    worktree is detached/bare. Two booleans classify each row for the caller:

    - ``tracked`` — the path matches a workspace haro already manages. Pass the
      store's known ``worktree_path`` set as ``tracked_paths``; git_ops stays
      store-agnostic (a thin git wrapper), so the caller supplies them.
    - ``under_worktree_root`` — the path lives under haro's own worktrees home
      (``settings.worktree_root`` by default; override for tests). haro's own
      worktrees sit here, so a row that is untracked yet under the root is a
      leftover/desynced haro worktree, not a genuinely foreign one.

    A row that is neither ``tracked`` nor ``under_worktree_root`` is a *foreign*
    worktree (a native Claude Code / claude-squad / tmux checkout) — the adopt
    candidates the scan endpoint surfaces.
    """
    root = _norm_path(worktree_root if worktree_root is not None else settings.worktree_root)
    tracked = {_norm_path(p) for p in tracked_paths}

    out = await _git("worktree", "list", "--porcelain", cwd=repo_path)
    rows: list[dict] = []
    cur: dict | None = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            if cur is not None:
                rows.append(cur)
            cur = {
                "path": line[len("worktree "):],
                "branch": None,
                "head": None,
                "detached": False,
                "bare": False,
                "locked": False,
                "prunable": False,
            }
        elif cur is None:
            continue  # defensive: git always leads a record with `worktree `
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):].strip() or None
        elif line.startswith("branch "):
            ref = line[len("branch "):].strip()
            cur["branch"] = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
        elif line == "detached":
            cur["detached"] = True
        elif line == "bare":
            cur["bare"] = True
        elif line == "locked" or line.startswith("locked "):
            cur["locked"] = True
        elif line == "prunable" or line.startswith("prunable "):
            cur["prunable"] = True
    if cur is not None:
        rows.append(cur)

    for row in rows:
        norm = _norm_path(row["path"])
        row["tracked"] = norm in tracked
        row["under_worktree_root"] = Path(norm).is_relative_to(root)
    return rows


async def rev_parse(ref: str, cwd: str | Path) -> str:
    """Resolve ``ref`` (e.g. ``HEAD``) to a full commit sha in ``cwd``."""
    out = await _git("rev-parse", ref, cwd=cwd)
    return out.strip()


async def add_note(repo_path: str | Path, sha: str, message: str) -> None:
    """Attach ``message`` as a ``git notes`` entry on ``sha`` (local only — never
    pushed). ``-f`` overwrites a stale note from a prior attempt on the same commit
    instead of erroring, so a retried merge can't leave two receipts fighting."""
    await _git("notes", "add", "-f", "-m", message, sha, cwd=repo_path)


async def merge_base(repo_path: str | Path, ref_a: str, ref_b: str) -> str:
    """The commit both ``ref_a`` and ``ref_b`` descend from — the attestation
    subject's anchor point (usp-critique-round3.md Move A). Stable under either ref
    moving forward, unlike naming HEAD or base_ref directly."""
    out = await _git("merge-base", ref_a, ref_b, cwd=repo_path)
    return out.strip()


async def is_ancestor(repo_path: str | Path, maybe_ancestor: str, ref: str) -> bool:
    """True if ``maybe_ancestor`` is an ancestor of ``ref`` (``git merge-base
    --is-ancestor``). Used by the merge-result gate to skip the whole merge dance
    when base_ref is already contained in the workspace (nothing new to merge)."""
    try:
        await _git("merge-base", "--is-ancestor", maybe_ancestor, ref, cwd=repo_path)
        return True
    except GitError:
        return False


#: The paths ``_EXCLUDE`` carries excludes for — kept alongside it so `_add_pathspec`
#: can check each independently rather than re-deriving them from the pathspec strings.
_EXCLUDED_PATHS = ("node_modules", ".haro/attestations")


async def _add_pathspec(worktree_path: str | Path) -> tuple[str, ...]:
    """The pathspec ``git add`` should use to stage everything but haro's own
    generated artifacts (see ``_EXCLUDE``'s docstring for what those are and why).

    ``git add`` **aborts** (exit 1, nothing staged) when a pathspec explicitly names a
    path git already ignores. A real ``npm install`` directory IS ignored, so passing
    ``:(exclude)node_modules`` there kills the whole snapshot — which silently degraded
    every merge-result gate on every npm project. Each excluded path is therefore
    checked independently: named in the pathspec only when it is NOT already
    gitignored (an already-ignored path needs no explicit exclude — ``git add -A``
    skips it on its own, and naming it anyway is exactly what aborts the add).
    """
    excludes: list[str] = []
    for path in _EXCLUDED_PATHS:
        try:
            await _git("check-ignore", "-q", path, cwd=worktree_path)
        except GitError:
            excludes.append(f":(exclude){path}")  # not ignored — exclude by hand
    return (*_ADD_ONLY, *excludes)


async def snapshot_worktree_commit(
    worktree_path: str | Path, message: str = "haro: gate snapshot"
) -> str:
    """Commit the worktree's *entire current content* (tracked edits + untracked
    files) as a throwaway commit parented on HEAD — WITHOUT touching the real index
    or working tree. Done via a private ``GIT_INDEX_FILE`` so a concurrent diff/gate
    on the same worktree is unaffected. The result has proper ancestry, so a later
    ``git merge base_ref`` against it is a real 3-way merge (agents rarely commit, so
    HEAD alone would miss their work — this captures it)."""
    import tempfile

    fd, idx = tempfile.mkstemp(prefix="synth-gate-idx-")
    os.close(fd)
    os.unlink(idx)  # let git create it fresh in the temp index
    env = {
        "GIT_INDEX_FILE": idx,
        # A guaranteed identity so commit-tree works even on a repo with none set.
        "GIT_AUTHOR_NAME": "haro", "GIT_AUTHOR_EMAIL": "haro@localhost",
        "GIT_COMMITTER_NAME": "haro", "GIT_COMMITTER_EMAIL": "haro@localhost",
    }
    try:
        await _git("read-tree", "HEAD", cwd=worktree_path, env=env)
        # -A stages everything; keep the injected node_modules symlink (ensure_deps) out,
        # but only name it when git isn't already ignoring it (see `_add_pathspec`).
        await _git("add", "-A", *await _add_pathspec(worktree_path), cwd=worktree_path, env=env)
        tree = (await _git("write-tree", cwd=worktree_path, env=env)).strip()
        head = (await _git("rev-parse", "HEAD", cwd=worktree_path, env=env)).strip()
        sha = (await _git("commit-tree", tree, "-p", head, "-m", message, cwd=worktree_path, env=env)).strip()
        return sha
    finally:
        for p in (idx, idx + ".lock"):
            try:
                os.unlink(p)
            except OSError:
                pass


async def create_merge_worktree(
    repo_path: str | Path, at_commit: str, merge_ref: str, dest: str | Path
) -> list[str]:
    """Check out ``at_commit`` in a temp worktree at ``dest`` and merge ``merge_ref``
    into it (no commit — just the merged working tree, ready to test).

    Returns the list of conflicted files: empty ``[]`` means a clean merge and
    ``dest`` now holds the true ship-result; a non-empty list means the workspace
    can't cleanly integrate base. Caller removes ``dest`` via ``remove_worktree``."""
    await add_detached_worktree(repo_path, dest, at_commit)
    try:
        # git merge validates a committer identity up front even with --no-commit,
        # so guarantee one — otherwise, on a repo/host with no user.name/email set,
        # the merge fails ("Committer identity unknown"), prepare_merge_result's
        # broad except swallows it, and merge-result gating silently degrades to
        # running the un-merged worktree. Mirrors snapshot_worktree_commit.
        env = {
            "GIT_AUTHOR_NAME": "haro", "GIT_AUTHOR_EMAIL": "haro@localhost",
            "GIT_COMMITTER_NAME": "haro", "GIT_COMMITTER_EMAIL": "haro@localhost",
        }
        await _git("merge", "--no-ff", "--no-commit", merge_ref, cwd=dest, env=env)
    except GitError:
        conflicts = await _conflicted_files(dest)
        if conflicts:
            return conflicts
        raise  # not a content conflict (bad ref, etc.) — a real error
    return []


async def merge_tree_conflicts(repo_path: str | Path, base_ref: str, branch: str) -> list[str]:
    """Dry-run: would merging ``branch`` into ``base_ref`` conflict? Uses
    ``git merge-tree --write-tree`` (Git 2.38+) — computes the merge purely in the
    object store, touching no worktree or index. Returns the conflicted file paths
    (``[]`` = clean). The merge-queue uses this to order/skip merges safely without
    ever leaving a half-merged tree behind.

    Not via ``_git`` because merge-tree prints the conflicted paths to *stdout* and
    exits 1 — ``_git`` would raise and drop that stdout."""
    async with _lock_for(repo_path):
        proc = await asyncio.create_subprocess_exec(
            "git", "merge-tree", "--write-tree", "--name-only", base_ref, branch,
            cwd=str(repo_path),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        out, err = await proc.communicate()
    if proc.returncode == 0:
        return []
    if proc.returncode == 1:
        # stdout: <tree-oid>\n<file>\n<file>\n\n<informational messages…>
        files: list[str] = []
        for line in out.decode(errors="replace").splitlines()[1:]:
            if not line.strip():
                break  # blank line ends the conflicted-paths section
            files.append(line)
        return files or ["(merge conflict)"]
    # any other exit code is a real failure (bad ref, ancient git) — surface it
    raise GitError(["merge-tree", base_ref, branch], proc.returncode or -1, err.decode())


async def _conflicted_files(cwd: str | Path) -> list[str]:
    try:
        out = await _git("diff", "--name-only", "--diff-filter=U", cwd=cwd)
    except GitError:
        return []
    return [ln for ln in out.splitlines() if ln.strip()]


async def branch_merged(repo_path: str | Path, branch: str, base_ref: str) -> bool:
    """True if ``branch`` has no commits beyond ``base_ref`` (already merged), or
    doesn't exist. Lets a broken/removed worktree whose work is safely in ``base_ref``
    be finalized instead of erroring."""
    try:
        out = await _git("rev-list", "--count", f"{base_ref}..{branch}", cwd=repo_path)
        return out.strip() == "0"
    except GitError:
        return True  # branch gone → nothing left to merge


async def remove_worktree(
    repo_path: str | Path,
    worktree_path: str | Path,
    branch: str | None = None,
) -> None:
    """Archive a workspace: drop the worktree, then delete its branch. Idempotent
    and crash-safe — safe to call on an already-removed or half-removed worktree.

    ``--force`` because an agent almost always leaves uncommitted edits behind, and
    the whole point of archiving is to throw that scratch work away. If git's own
    removal was interrupted (leaving a directory husk), we ``rmtree`` the leftover
    and ``prune`` the stale admin entry — so a killed/retried archive never strands
    a husk that later desyncs the store.
    """
    try:
        await _git("worktree", "remove", "--force", str(worktree_path), cwd=repo_path)
    except GitError:
        # Already removed, or a husk git no longer recognizes — fall through to the
        # manual cleanup below so this call is idempotent rather than fatal.
        pass
    if Path(worktree_path).exists():
        shutil.rmtree(worktree_path, ignore_errors=True)
    try:
        await _git("worktree", "prune", cwd=repo_path)
    except GitError:
        pass
    if branch:
        try:
            await _git("branch", "-D", branch, cwd=repo_path)
        except GitError:
            # Branch may have been merged/renamed/never-committed — non-fatal.
            pass


async def diff(worktree_path: str | Path, base_ref: str) -> tuple[str, int]:
    """Return ``(unified_diff, files_changed)`` for the worktree vs ``base_ref``.

    Agents edit files but rarely commit, so a plain ``git diff <ref>`` (which
    compares the *working tree* to a commit) already captures their changes —
    except brand-new files, which are untracked and invisible to diff. The
    ``add -A -N`` (intent-to-add) marks untracked files so they show up as
    additions without actually staging content.
    """
    await _mark_untracked(worktree_path)
    text = await _git("diff", base_ref, *_EXCLUDE, cwd=worktree_path)
    stat = await _git("diff", "--numstat", base_ref, *_EXCLUDE, cwd=worktree_path)
    files_changed = len([ln for ln in stat.splitlines() if ln.strip()])
    return text, files_changed


async def diff_commit(worktree_path: str | Path, sha: str) -> tuple[str, int]:
    """Return ``(unified_diff, files_changed)`` for a single commit's own change
    vs its parent — the exact patch ``sha`` introduced, ignoring the working
    tree entirely. Lets a reviewer step through a branch's commits one at a
    time instead of the squashed working-vs-``base_ref`` view from :func:`diff`.
    ``git show`` diffs a root commit (no parent) against the empty tree, so no
    special-casing is needed there.
    """
    text = await _git("show", sha, "--format=", *_EXCLUDE, cwd=worktree_path)
    stat = await _git("show", sha, "--format=", "--numstat", *_EXCLUDE, cwd=worktree_path)
    files_changed = len([ln for ln in stat.splitlines() if ln.strip()])
    return text, files_changed


async def show_file(worktree_path: str | Path, ref: str, rel: str) -> dict:
    """Committed content of ``rel`` at ``ref`` — the base side of the editor's
    per-file "working vs base" diff.

    Returns ``{content, exists, error?}``. ``exists=False`` (with empty content)
    when the path isn't in ``ref`` — a file the agent newly added — so the diff
    renders as all-additions instead of erroring. A binary blob reports
    ``error="binary file"`` (the caller shows a not-diffable notice). We capture
    the subprocess directly (not via :func:`_git`) so we can keep the raw bytes
    and decode defensively instead of blowing up on non-UTF-8 content.
    """
    async with _lock_for(worktree_path):
        proc = await asyncio.create_subprocess_exec(
            "git", *_CRED_OVERRIDE, "show", f"{ref}:{rel}",
            cwd=str(worktree_path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, _err = await proc.communicate()
    if proc.returncode != 0:
        # Path absent at ref (new file) — empty base, not an error.
        return {"content": "", "exists": False}
    try:
        return {"content": out.decode("utf-8"), "exists": True}
    except UnicodeDecodeError:
        return {"content": "", "exists": True, "error": "binary file"}


async def changed_files(worktree_path: str | Path, base_ref: str) -> list[dict]:
    """Parsed ``git diff --numstat`` vs ``base_ref``: ``[{path, added, removed}]``.

    Includes untracked files (via the intent-to-add marker). Binary files report
    ``added``/``removed`` as None (numstat prints ``-`` for them).
    """
    await _mark_untracked(worktree_path)
    stat = await _git("diff", "--numstat", base_ref, *_EXCLUDE, cwd=worktree_path)
    out: list[dict] = []
    for line in stat.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        added, removed, path = parts
        out.append(
            {
                "path": path,
                "added": None if added == "-" else int(added),
                "removed": None if removed == "-" else int(removed),
            }
        )
    return out
