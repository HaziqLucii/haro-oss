"""The restore point: the worktree as it was when an agent run started, put back on request."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import main, restore_point
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, Workspace
from haro.runner import run_agent
from haro.store import Store


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout


@pytest.fixture
def repo(tmp_path) -> Path:
    r = tmp_path / "repo"
    (r / "src").mkdir(parents=True)
    _git(r, "init", "-q", "-b", "main")
    (r / "src/a.ts").write_text("a0\n")
    (r / "notes.md").write_text("n0\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    return r


class _Wrecker(AgentAdapter):
    """Stands in for an agent whose shell ran `git reset --hard` and wrote new files."""

    name = "wrecker"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False):
        subprocess.run(["git", "reset", "--hard", "-q"], cwd=cwd, check=True)
        subprocess.run(["git", "clean", "-fdq"], cwd=cwd, check=True)
        (Path(cwd) / "src/new.ts").write_text("new\n")
        (Path(cwd) / "notes.md").write_text("agent notes\n")
        yield NormalizedEvent("done", {"session_id": "c"})


def _run_wrecker(repo: Path):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="wrecker", task="t")
    store.add_run(run)
    asyncio.run(run_agent(store=store, hub=hub, adapter=_Wrecker(), workspace=ws, run=run, auto_gate=False))
    return store, ws, run


def test_every_agent_run_pins_its_start_and_a_reset_hard_can_be_undone(repo):
    (repo / "src/a.ts").write_text("a-uncommitted-by-hand\n")
    (repo / "scratch.txt").write_text("untracked by hand\n")
    store, ws, run = _run_wrecker(repo)
    assert run.status == AgentRunStatus.done
    assert run.start_ref == f"refs/haro/start/{ws.id}/{run.id}"
    assert (repo / "src/a.ts").read_text() == "a0\n"  # the reset ate the developer's edit
    assert not (repo / "scratch.txt").exists()

    out = asyncio.run(restore_point.restore(str(repo), run.start_ref, ws.id))

    assert (repo / "src/a.ts").read_text() == "a-uncommitted-by-hand\n"
    assert (repo / "scratch.txt").read_text() == "untracked by hand\n"
    assert (repo / "notes.md").read_text() == "n0\n"
    assert not (repo / "src/new.ts").exists()
    assert {"src/a.ts", "scratch.txt", "notes.md", "src/new.ts"} <= set(out.restored)
    assert out.failed == []


def test_what_the_worktree_held_is_kept_before_a_restore(repo):
    store, ws, run = _run_wrecker(repo)
    out = asyncio.run(restore_point.restore(str(repo), run.start_ref, ws.id))
    assert out.saved_ref.startswith(f"refs/haro/before-restore/{ws.id}/")
    kept = _git(repo, "show", f"{out.saved_ref}:notes.md")
    assert kept == "agent notes\n"


def test_restoring_an_unchanged_worktree_says_so(repo):
    store, ws, run = _run_wrecker(repo)
    asyncio.run(restore_point.restore(str(repo), run.start_ref, ws.id))
    again = asyncio.run(restore_point.restore(str(repo), run.start_ref, ws.id))
    assert again.nothing_to_restore and again.saved_ref is None


def test_a_plan_run_pins_nothing(repo):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="wrecker", task="t", plan=True)
    store.add_run(run)
    asyncio.run(run_agent(store=store, hub=hub, adapter=_Wrecker(), workspace=ws, run=run, auto_gate=False, plan=True))
    assert run.start_ref is None


def test_only_the_newest_restore_points_are_kept_and_a_deleted_workspace_keeps_none(repo):
    tree = _git(repo, "write-tree").strip()
    for i in range(restore_point.KEEP_START + 3):
        asyncio.run(restore_point.pin(str(repo), tree, "ws1", f"run{i:02d}"))
    refs = _git(repo, "for-each-ref", "--format=%(refname)", "refs/haro/start/ws1/").split()
    assert len(refs) == restore_point.KEEP_START
    asyncio.run(restore_point.drop_workspace(str(repo), "ws1"))
    assert _git(repo, "for-each-ref", "refs/haro/start/").strip() == ""


@pytest.fixture
def api(repo):
    store, ws, run = _run_wrecker(repo)
    main.store.add_workspace(ws)
    main.store.add_run(run)
    yield ws, run
    main.store.runs.pop(run.id, None)
    main.store.remove_workspace(ws.id)


def _restore(ws, run):
    return asyncio.run(main.restore_run_start(ws.id, run.id))


def test_the_endpoint_restores_and_reports(api, repo):
    ws, run = api
    res = _restore(ws, run)
    assert "src/new.ts" in res.restored and res.saved_ref
    assert not (repo / "src/new.ts").exists()


def test_the_endpoint_refuses_while_something_runs_and_for_a_run_with_no_point(api, monkeypatch):
    ws, run = api
    run.start_ref = None
    with pytest.raises(HTTPException) as e:
        _restore(ws, run)
    assert e.value.status_code == 404
    run.start_ref = f"refs/haro/start/{ws.id}/{run.id}"
    monkeypatch.setattr(main.store, "busy_reason", lambda _id: "an agent")
    with pytest.raises(HTTPException) as e:
        _restore(ws, run)
    assert e.value.status_code == 409
    with pytest.raises(HTTPException) as e:
        asyncio.run(main.restore_run_start(ws.id, "run_nope"))
    assert e.value.status_code == 404
