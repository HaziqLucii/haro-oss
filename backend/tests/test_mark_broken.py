"""Task 2 — visible `broken` workspace state.

`db.mark_broken` classifies husk worktrees (directory present, `.git` gone) that
the sync `reconcile` deliberately leaves in place: unmerged work → `broken` and
KEPT; already-merged → dropped. Exercised against a real throwaway git repo.
"""

import asyncio
import subprocess
from pathlib import Path

from haro import db
from haro.models import Project, Workspace, WorkspaceStatus
from haro.store import Store


def _git(*args: str, cwd: Path) -> None:
    env = {
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "PATH": __import__("os").environ.get("PATH", ""),
    }
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True)


def _repo_with_husk(root: Path, *, extra_commit: bool) -> tuple[Store, str]:
    """Build a repo + a worktree on branch `feat`, optionally add an unmerged
    commit, then turn the worktree into a husk (remove its `.git`). Returns the
    store and the workspace id."""
    repo = root / "repo"
    repo.mkdir()
    _git("init", "-b", "main", cwd=repo)
    (repo / "a.txt").write_text("hello\n")
    _git("add", ".", cwd=repo)
    _git("commit", "-m", "init", cwd=repo)

    wt = root / "wt"
    _git("worktree", "add", "-b", "feat", str(wt), "main", cwd=repo)
    if extra_commit:
        (wt / "b.txt").write_text("more\n")
        _git("add", ".", cwd=wt)
        _git("commit", "-m", "unmerged work", cwd=wt)

    # Simulate a husk: the interrupted-removal state — dir present, `.git` gone.
    (wt / ".git").unlink()

    store = Store()
    proj = Project(name="repo", path=str(repo), default_branch="main")
    store.projects[proj.id] = proj
    ws = Workspace(
        project_id=proj.id,
        name="feat-ws",
        branch="feat",
        worktree_path=str(wt),
        base_ref="main",
        status=WorkspaceStatus.gate_green,
    )
    store.workspaces[ws.id] = ws
    return store, ws.id


def test_unmerged_husk_is_marked_broken(tmp_path: Path):
    store, wid = _repo_with_husk(tmp_path, extra_commit=True)
    notes = asyncio.run(db.mark_broken(store))
    assert wid in store.workspaces
    assert store.workspaces[wid].status == WorkspaceStatus.broken
    assert any("broken" in n for n in notes)


def test_merged_husk_is_dropped(tmp_path: Path):
    store, wid = _repo_with_husk(tmp_path, extra_commit=False)
    notes = asyncio.run(db.mark_broken(store))
    assert wid not in store.workspaces
    assert any("already merged" in n for n in notes)


def test_valid_worktree_untouched(tmp_path: Path):
    # No husk (leave `.git` in place) → mark_broken must not touch it.
    repo = tmp_path / "repo"
    repo.mkdir()
    _git("init", "-b", "main", cwd=repo)
    (repo / "a.txt").write_text("hello\n")
    _git("add", ".", cwd=repo)
    _git("commit", "-m", "init", cwd=repo)
    wt = tmp_path / "wt"
    _git("worktree", "add", "-b", "feat", str(wt), "main", cwd=repo)

    store = Store()
    proj = Project(name="repo", path=str(repo), default_branch="main")
    store.projects[proj.id] = proj
    ws = Workspace(
        project_id=proj.id, name="ok", branch="feat",
        worktree_path=str(wt), base_ref="main", status=WorkspaceStatus.idle,
    )
    store.workspaces[ws.id] = ws
    notes = asyncio.run(db.mark_broken(store))
    assert ws.id in store.workspaces
    assert store.workspaces[ws.id].status == WorkspaceStatus.idle
    assert notes == []
