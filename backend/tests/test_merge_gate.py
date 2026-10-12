"""Merge-result gate plumbing: snapshot the worktree (incl. untracked) + merge the
latest base into a temp worktree, so the gate tests what actually *ships*."""

import asyncio
import subprocess
from pathlib import Path

from haro import git_ops


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "math.js").write_text("export const v = 1\n")
    (repo / "keep.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    return repo


def _worktree(repo: Path, tmp_path: Path, ref="main") -> Path:
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, ref))
    # detach → give it a branch so HEAD is stable
    _run("checkout", "-b", "feat", cwd=wt)
    return wt


def test_clean_merge_captures_base_and_worktree_changes(tmp_path):
    repo = _repo(tmp_path)
    branch_point = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    wt = _worktree(repo, tmp_path)

    # base advances on a *different* file after the workspace branched
    (repo / "keep.txt").write_text("base changed\n")
    _run("commit", "-am", "advance base", cwd=repo)

    # workspace: an uncommitted edit + a brand-new untracked file
    (wt / "math.js").write_text("export const v = 2\n")
    (wt / "new.js").write_text("export const n = 9\n")

    assert asyncio.run(git_ops.is_ancestor(wt, "main", "HEAD")) is False  # base advanced

    snap = asyncio.run(git_ops.snapshot_worktree_commit(wt))
    dest = tmp_path / "merged"
    conflicts = asyncio.run(git_ops.create_merge_worktree(repo, snap, "main", dest))
    try:
        assert conflicts == []
        # the merge result has BOTH the base change and the workspace's work (incl. untracked)
        assert (dest / "keep.txt").read_text() == "base changed\n"
        assert (dest / "math.js").read_text() == "export const v = 2\n"
        assert (dest / "new.js").read_text() == "export const n = 9\n"
    finally:
        asyncio.run(git_ops.remove_worktree(repo, dest))
    assert branch_point  # sanity


def test_conflicting_change_is_reported(tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo, tmp_path)

    # base and workspace edit the SAME line differently → a merge conflict
    (repo / "math.js").write_text("export const v = 100\n")
    _run("commit", "-am", "base edits math", cwd=repo)
    (wt / "math.js").write_text("export const v = 200\n")

    snap = asyncio.run(git_ops.snapshot_worktree_commit(wt))
    dest = tmp_path / "merged"
    conflicts = asyncio.run(git_ops.create_merge_worktree(repo, snap, "main", dest))
    try:
        assert conflicts == ["math.js"]
    finally:
        asyncio.run(git_ops.remove_worktree(repo, dest))


def test_base_contained_short_circuits(tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo, tmp_path)
    # base hasn't moved → it's an ancestor of the workspace HEAD → no merge needed
    assert asyncio.run(git_ops.is_ancestor(wt, "main", "HEAD")) is True


def test_contained_base_is_not_reported_as_a_failed_merge(tmp_path):
    """Base already contained means the worktree IS the merge result, so the check ran.
    It must return a note, not the empty tuple the exception fallback uses, or every
    workspace whose base hasn't moved reads as degraded and can never ship."""
    from haro import gate

    repo = _repo(tmp_path)
    wt = _worktree(repo, tmp_path)
    merge_root, conflicts, note = asyncio.run(
        gate.prepare_merge_result(worktree_path=str(wt), project_path=str(repo), base_ref="main")
    )
    assert merge_root is None and conflicts == []
    assert note, "the no-op case must be distinguishable from the failure case"


def test_snapshot_survives_a_real_gitignored_node_modules(tmp_path):
    """`npm install` leaves a real, gitignored node_modules. Naming it in the add
    pathspec makes git abort, which used to sink the whole merge-result gate."""
    repo = _repo(tmp_path)
    (repo / ".gitignore").write_text("node_modules/\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "ignore node_modules", cwd=repo)
    wt = _worktree(repo, tmp_path)

    (wt / "node_modules").mkdir()
    (wt / "node_modules" / "pkg.js").write_text("module.exports = 1\n")
    (wt / "math.js").write_text("export const v = 2\n")  # the edit that must survive

    snap = asyncio.run(git_ops.snapshot_worktree_commit(wt))
    listed = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", snap],
        cwd=wt, check=True, capture_output=True, text=True,
    ).stdout.split()
    assert not [p for p in listed if "node_modules" in p]
    show = subprocess.run(
        ["git", "show", f"{snap}:math.js"], cwd=wt, check=True, capture_output=True, text=True
    ).stdout
    assert show == "export const v = 2\n"


def test_snapshot_still_excludes_the_ensure_deps_symlink(tmp_path):
    """A `node_modules/` rule matches directories, not the symlink ensure_deps injects,
    so that one still has to be excluded by hand."""
    repo = _repo(tmp_path)
    (repo / ".gitignore").write_text("node_modules/\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "ignore node_modules", cwd=repo)
    wt = _worktree(repo, tmp_path)

    real = tmp_path / "shared_modules"
    real.mkdir()
    (real / "pkg.js").write_text("module.exports = 1\n")
    (wt / "node_modules").symlink_to(real)

    snap = asyncio.run(git_ops.snapshot_worktree_commit(wt))
    listed = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", snap],
        cwd=wt, check=True, capture_output=True, text=True,
    ).stdout.split()
    assert not [p for p in listed if "node_modules" in p]
