"""POST /workspaces/{id}/review: the standalone on-demand review ("Review with AI").
It reviews the current diff, needs no gate run and no recorded task, and never writes
to a TestRun or the gate summary."""

from __future__ import annotations

import asyncio
import json
import subprocess

import pytest
from fastapi import HTTPException

from haro import main, review
from haro.hub import Hub
from haro.models import Project, ReviewRequest, ReviewResult, ReviewVerdict, Workspace
from haro.store import Store


def _repo(tmp_path, *, dirty: bool) -> str:
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@example.com"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "t"], check=True)
    (repo / "f.txt").write_text("x\n")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "init"], check=True)
    if dirty:
        (repo / "f.txt").write_text("y\n")
    return str(repo)


def _wire(monkeypatch, tmp_path, *, dirty: bool, settings: str = ""):
    repo = _repo(tmp_path, dirty=dirty)
    store = Store()
    # Settings live outside the worktree: an untracked .haro/ inside it would be a diff.
    proj_dir = tmp_path / "proj"
    (proj_dir / ".haro").mkdir(parents=True)
    (proj_dir / ".haro" / "settings.toml").write_text(settings)
    project = Project(id="p", name="proj", path=str(proj_dir), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(project_id="p", name="w", branch="main", worktree_path=repo, base_ref="HEAD")
    store.workspaces[ws.id] = ws
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    monkeypatch.setattr(main, "store", store)
    return store, ws


@pytest.fixture(autouse=True)
def _no_real_claude(monkeypatch):
    real = asyncio.create_subprocess_exec

    async def guarded(*cmd, **kw):
        if cmd and cmd[0] == "claude":
            raise AssertionError("a test tried to launch the real claude CLI")
        return await real(*cmd, **kw)

    monkeypatch.setattr(review.asyncio, "create_subprocess_exec", guarded)


ROLES = "[roles]\nenabled = true\nreview = 'opus:high'\n"


def test_empty_diff_is_nothing_to_review_for_both_reviewers(monkeypatch, tmp_path):
    store, ws = _wire(monkeypatch, tmp_path, dirty=False)
    plain = asyncio.run(main.run_review_endpoint(ws.id, ReviewRequest()))
    assert isinstance(plain, ReviewResult)
    assert plain.nothing_to_review is True and plain.error is None

    (tmp_path / "proj" / ".haro" / "settings.toml").write_text(ROLES)
    verdict = asyncio.run(main.run_review_endpoint(ws.id, None))
    assert isinstance(verdict, ReviewVerdict)
    assert verdict.nothing_to_review is True and verdict.error is None
    assert "Nothing to review" in verdict.summary


def test_reviews_the_current_diff_with_no_task_and_no_gate_run(monkeypatch, tmp_path):
    store, ws = _wire(monkeypatch, tmp_path, dirty=True, settings=ROLES)
    assert not store.runs and store.latest_test(ws.id) is None
    seen = {}

    class _Proc:
        returncode = 0

        async def communicate(self):
            body = {"verdict": "fail", "summary": "bad", "must_fix": [
                {"file": "f.txt", "line": 1, "title": "wrong", "detail": "d", "cited": "+y"}]}
            return json.dumps({"result": json.dumps(body)}).encode(), b""

    passthrough = asyncio.create_subprocess_exec  # the autouse guard: real for git

    async def fake_exec(*cmd, **kw):
        if cmd and cmd[0] != "claude":
            return await passthrough(*cmd, **kw)
        seen["cmd"] = cmd
        return _Proc()

    monkeypatch.setattr(review.asyncio, "create_subprocess_exec", fake_exec)
    out = asyncio.run(main.run_review_endpoint(ws.id, ReviewRequest(model="sonnet")))

    assert isinstance(out, ReviewVerdict)
    assert out.verdict == "fail" and out.must_fix[0].cited == "+y"
    assert out.model == "sonnet"  # request model overrides the role's
    assert "NO TASK WAS RECORDED" in seen["cmd"][2]
    assert "+y" in seen["cmd"][2]  # the live diff is in the prompt
    assert store.latest_test(ws.id) is None  # nothing was stamped anywhere


def test_the_endpoint_never_stamps_a_test_run(monkeypatch, tmp_path):
    from haro.models import TestRun, TestRunStatus

    store, ws = _wire(monkeypatch, tmp_path, dirty=True, settings=ROLES)
    run = TestRun(workspace_id=ws.id, runner="vitest", scope="all", status=TestRunStatus.passed)
    store.add_test(run)

    async def fake_code_review(**_kw):
        return ReviewVerdict(ran_at=0, model="opus", verdict="fail", summary="x")

    monkeypatch.setattr(review, "run_code_review", fake_code_review)
    asyncio.run(main.run_review_endpoint(ws.id, ReviewRequest()))
    assert run.review is None and run.review_blocked is False


def test_unknown_workspace_is_404(monkeypatch, tmp_path):
    _wire(monkeypatch, tmp_path, dirty=False)
    with pytest.raises(HTTPException) as e:
        asyncio.run(main.run_review_endpoint("nope", ReviewRequest()))
    assert e.value.status_code == 404
