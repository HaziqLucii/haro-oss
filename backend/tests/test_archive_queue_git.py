"""Bulk archive against a REAL git repo (backlog/bulk-archive.md).

The stubbed queue tests prove the ordering, the isolation and the stop. They prove
nothing about the part that actually destroys work: ``git worktree remove --force``
followed by ``git branch -D``. These hold the two promises that are about git —

1. an admitted workspace really is torn down (worktree gone, branch gone),
2. a workspace with unmerged work is really left ALONE by a default run — its branch
   and its commit are still there afterwards, and it stays archivable by hand.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
from pathlib import Path

from haro import main as main_mod
from haro.models import ArchiveQueueRequest, Project, Workspace
from haro.store import Store


def _git(*args: str, cwd: Path) -> str:
    env = {
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        "PATH": os.environ.get("PATH", ""),
    }
    out = subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True)
    return out.stdout


def _branches(repo: Path) -> set[str]:
    return {b.strip().lstrip("* ") for b in _git("branch", "--format=%(refname:short)", cwd=repo).split()}


def _setup(root: Path, monkeypatch) -> tuple[Store, Project, Path]:
    repo = root / "repo"
    repo.mkdir()
    _git("init", "-b", "main", cwd=repo)
    (repo / "a.txt").write_text("hello\n")
    _git("add", ".", cwd=repo)
    _git("commit", "-m", "init", cwd=repo)

    store = Store()
    project = Project(name="p", path=str(repo), default_branch="main")
    store.add_project(project)

    async def _save(*a, **k):
        return None

    monkeypatch.setattr(main_mod.db, "save_snapshot", _save)
    monkeypatch.setattr(main_mod, "store", store)
    return store, project, repo


def _worktree(store: Store, project: Project, repo: Path, root: Path, name: str) -> Workspace:
    wt = root / name
    _git("worktree", "add", "-b", f"haro/{name}", str(wt), "main", cwd=repo)
    ws = Workspace(
        project_id=project.id, name=name, branch=f"haro/{name}",
        worktree_path=str(wt), base_ref="main",
    )
    store.add_workspace(ws)
    return ws


def test_clean_worktrees_are_torn_down_one_after_another(tmp_path, monkeypatch):
    store, project, repo = _setup(tmp_path, monkeypatch)
    a = _worktree(store, project, repo, tmp_path, "a")
    b = _worktree(store, project, repo, tmp_path, "b")

    async def go():
        run = await main_mod.start_archive_queue(
            project.id, ArchiveQueueRequest(workspace_ids=[a.id, b.id])
        )
        await store.archive_tasks[project.id]
        return run

    run = asyncio.run(go())
    assert [i.outcome for i in run.items] == ["archived", "archived"]
    assert not (tmp_path / "a").exists() and not (tmp_path / "b").exists()
    assert _branches(repo) == {"main"}
    assert store.list_workspaces(project.id) == []


def test_unmerged_work_is_held_back_and_survives(tmp_path, monkeypatch):
    store, project, repo = _setup(tmp_path, monkeypatch)
    safe = _worktree(store, project, repo, tmp_path, "safe")
    risky = _worktree(store, project, repo, tmp_path, "risky")
    # A committed-but-unmerged change: `git branch -D` would take it with no recovery.
    (tmp_path / "risky" / "work.txt").write_text("the work nobody merged\n")
    _git("add", ".", cwd=tmp_path / "risky")
    _git("commit", "-m", "work", cwd=tmp_path / "risky")

    async def go():
        run = await main_mod.start_archive_queue(
            project.id, ArchiveQueueRequest(workspace_ids=[safe.id, risky.id])
        )
        await store.archive_tasks[project.id]
        return run

    run = asyncio.run(go())
    outcomes = {i.name: i.outcome for i in run.items}
    assert outcomes == {"safe": "archived", "risky": "skipped"}
    # Still there, still diffable, still archivable one-by-one.
    assert (tmp_path / "risky" / "work.txt").exists()
    assert "haro/risky" in _branches(repo)
    assert store.get_workspace(risky.id) is not None


def test_uncommitted_edits_are_held_back_too(tmp_path, monkeypatch):
    store, project, repo = _setup(tmp_path, monkeypatch)
    ws = _worktree(store, project, repo, tmp_path, "dirty")
    (tmp_path / "dirty" / "scratch.txt").write_text("an agent's uncommitted edit\n")

    async def plan_only():
        return await main_mod.start_archive_queue(
            project.id, ArchiveQueueRequest(workspace_ids=[ws.id]), dry=True
        )

    run = asyncio.run(plan_only())
    assert run.items[0].outcome == "skipped"
    assert "uncommitted" in run.items[0].reason


def test_force_takes_the_risky_one(tmp_path, monkeypatch):
    store, project, repo = _setup(tmp_path, monkeypatch)
    ws = _worktree(store, project, repo, tmp_path, "risky")
    (tmp_path / "risky" / "work.txt").write_text("x\n")
    _git("add", ".", cwd=tmp_path / "risky")
    _git("commit", "-m", "work", cwd=tmp_path / "risky")

    async def go():
        run = await main_mod.start_archive_queue(
            project.id, ArchiveQueueRequest(workspace_ids=[ws.id], force=True)
        )
        await store.archive_tasks[project.id]
        return run

    run = asyncio.run(go())
    assert run.items[0].outcome == "archived"
    # Forced ≠ unrecorded: the run still says what it threw away.
    assert run.items[0].risks
    assert "haro/risky" not in _branches(repo)


def test_a_husk_is_cleaned_up_rather_than_held_back(tmp_path, monkeypatch):
    # An interrupted archive left a directory with no `.git` link. Archiving is the
    # repair — holding it back as if it held unsaved work would strand it forever.
    store, project, repo = _setup(tmp_path, monkeypatch)
    ws = _worktree(store, project, repo, tmp_path, "husk")
    (tmp_path / "husk" / ".git").unlink()

    async def go():
        run = await main_mod.start_archive_queue(
            project.id, ArchiveQueueRequest(workspace_ids=[ws.id])
        )
        await store.archive_tasks[project.id]
        return run

    run = asyncio.run(go())
    assert run.items[0].outcome == "archived"
    assert not (tmp_path / "husk").exists()
