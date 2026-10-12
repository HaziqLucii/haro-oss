"""The scope fence through ``run_agent``: armed before the agent starts, enforced when it ends
(done, error or a user stop), recorded on the run, the stream and the receipt."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import receipt as receipt_svc
from haro import scope_fence
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, Receipt, ReceiptScope, StartAgentRequest, Workspace
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
    (r / "docs").mkdir()
    _git(r, "init", "-q", "-b", "main")
    (r / "src/a.ts").write_text("a0\n")
    (r / "docs/readme.md").write_text("r0\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    return r


class _Edits(AgentAdapter):
    """Writes the given files, then finishes (or raises, or hangs for a stop)."""

    name = "edits"

    def __init__(self, writes: dict[str, str], *, then: str = "done") -> None:
        self.writes, self.then = writes, then

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        for rel, text in self.writes.items():
            p = Path(cwd) / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        if self.then == "hang":
            await asyncio.sleep(60)
        if self.then == "error":
            raise RuntimeError("boom")
        yield NormalizedEvent("done", {"session_id": "c"})


def _setup(repo: Path, scope: list[str]):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="edits", task="t", scope=scope)
    store.add_run(run)
    return store, hub, ws, run


def _texts(hub, ws) -> list[str]:
    return [
        e["event"]["payload"].get("text") or ""
        for e in hub.history(ws.id)
        if e.get("channel") == "agent" and "event" in e
    ]


def _go(store, hub, ws, run, adapter):
    asyncio.run(run_agent(store=store, hub=hub, adapter=adapter, workspace=ws, run=run, auto_gate=False))


def test_a_fenced_run_keeps_in_scope_edits_and_reverts_the_rest(repo):
    (repo / "docs/readme.md").write_text("r-by-hand\n")  # the dev's own uncommitted work
    store, hub, ws, run = _setup(repo, ["src/a.ts"])
    _go(store, hub, ws, run, _Edits({"src/a.ts": "a1\n", "docs/readme.md": "r-agent\n", "lib/x.ts": "x\n"}))
    assert run.status == AgentRunStatus.done
    assert (repo / "src/a.ts").read_text() == "a1\n"
    assert (repo / "docs/readme.md").read_text() == "r-by-hand\n"
    assert not (repo / "lib").exists()
    assert run.scope_reverted == ["docs/readme.md", "lib/x.ts"]
    assert run.scope_backup_ref == f"refs/haro/scope/{run.id}"
    assert any("reverted 2 change(s) outside the fence" in t for t in _texts(hub, ws))
    assert any("the message above may not match the files" in t for t in _texts(hub, ws))


def test_a_run_without_a_fence_is_untouched(repo):
    store, hub, ws, run = _setup(repo, [])
    _go(store, hub, ws, run, _Edits({"docs/readme.md": "r-agent\n"}))
    assert (repo / "docs/readme.md").read_text() == "r-agent\n"
    assert run.scope_reverted == [] and run.scope_backup_ref is None


def test_an_errored_run_is_still_fenced(repo):
    store, hub, ws, run = _setup(repo, ["src"])
    _go(store, hub, ws, run, _Edits({"docs/readme.md": "r-agent\n"}, then="error"))
    assert run.status == AgentRunStatus.error
    assert (repo / "docs/readme.md").read_text() == "r0\n"
    assert run.scope_reverted == ["docs/readme.md"]


def test_a_stopped_run_is_still_fenced(repo):
    store, hub, ws, run = _setup(repo, ["src"])

    async def go():
        task = asyncio.create_task(run_agent(
            store=store, hub=hub, adapter=_Edits({"docs/readme.md": "r-agent\n"}, then="hang"),
            workspace=ws, run=run, auto_gate=False))
        await asyncio.sleep(0.5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(go())
    assert run.status == AgentRunStatus.stopped
    assert (repo / "docs/readme.md").read_text() == "r0\n"
    assert run.scope_reverted == ["docs/readme.md"]


def test_a_fence_that_cannot_be_armed_never_starts_the_agent(repo, monkeypatch):
    async def boom(_wt):
        raise RuntimeError("no git")

    monkeypatch.setattr(scope_fence, "snapshot_tree", boom)
    store, hub, ws, run = _setup(repo, ["src"])
    _go(store, hub, ws, run, _Edits({"src/a.ts": "a1\n"}))
    assert run.status == AgentRunStatus.error
    assert (repo / "src/a.ts").read_text() == "a0\n"
    assert run.scope == []  # it never started: the receipt must not count it as fenced


def test_a_check_that_fails_is_recorded_and_said_out_loud(repo, monkeypatch):
    async def boom(*_a, **_k):
        raise RuntimeError("disk full")

    monkeypatch.setattr(scope_fence, "enforce", boom)
    store, hub, ws, run = _setup(repo, ["src"])
    _go(store, hub, ws, run, _Edits({"docs/readme.md": "r-agent\n"}))
    assert run.scope_error and "disk full" in run.scope_error
    assert any("could not check this run's edits" in t for t in _texts(hub, ws))
    assert receipt_svc._build_scope(store, ws).unchecked_runs == 1


def test_the_receipt_counts_fenced_runs_and_reverts(repo):
    store, hub, ws, run = _setup(repo, ["src"])
    _go(store, hub, ws, run, _Edits({"docs/readme.md": "r-agent\n"}))
    plan = AgentRun(workspace_id=ws.id, adapter="edits", task="p", plan=True)
    unfenced = AgentRun(workspace_id=ws.id, adapter="edits", task="u")
    store.add_run(plan)
    store.add_run(unfenced)
    scope = receipt_svc._build_scope(store, ws)
    assert scope.patterns == ["src"]
    assert (scope.fenced_runs, scope.editing_runs) == (1, 2)  # the plan run is not an editing run
    assert scope.reverted == ["docs/readme.md"]


def test_the_markdown_names_the_fence_and_the_reverts():
    r = Receipt(
        workspace_id="w", workspace_name="w", branch="b", base_ref="main", verdict="green",
        scope=ReceiptScope(patterns=["src/a.ts"], fenced_runs=1, editing_runs=2, reverted=["docs/readme.md"]),
    )
    md = receipt_svc.render_markdown(r)
    assert "Agent edits fenced to `src/a.ts` (1 of 2 agent runs)" in md
    assert "1 out-of-scope change(s) reverted: `docs/readme.md`" in md
    assert "fenced to" not in receipt_svc.render_markdown(
        Receipt(workspace_id="w", workspace_name="w", branch="b", base_ref="main", verdict="green"))


def test_the_request_and_run_carry_the_fence():
    assert StartAgentRequest(task="t", scope=["src/"]).scope == ["src/"]
    run = AgentRun(workspace_id="w", adapter="x", scope=["src/"], scope_reverted=["a"])
    assert AgentRun.model_validate_json(run.model_dump_json()).scope == ["src/"]


def _start(scope):
    """``main.start_agent`` against a workspace whose setup is still running, so the run is
    accepted as queued and nothing spawns."""
    import tempfile

    from fastapi import HTTPException

    from haro import main
    from haro.models import Project
    from haro.store import SETUP_SESSION

    async def go():
        store = Store()
        ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/tmp/wt", base_ref="main")
        store.add_workspace(ws)
        main.store = store
        proj = Project(name="p", path=tempfile.mkdtemp(prefix="haro-proj-"), default_branch="main")
        store.projects[proj.id] = proj
        ws.project_id = proj.id
        store.set_active_task(ws.id, SETUP_SESSION, asyncio.create_task(asyncio.sleep(3600)))
        try:
            return await main.start_agent(ws.id, StartAgentRequest(task="do it", scope=scope))
        except HTTPException as exc:
            return exc
        finally:
            for task in store.workspace_tasks(ws.id):
                task.cancel()
            await asyncio.gather(*store.workspace_tasks(ws.id), return_exceptions=True)

    return asyncio.run(go())


def test_start_agent_normalizes_the_fence_onto_the_run():
    run = _start([" ./src/a.ts ", "", "docs/", "src/a.ts"])
    assert run.scope == ["src/a.ts", "docs/"]


def test_start_agent_without_a_fence_leaves_the_run_unfenced():
    assert _start(None).scope == [] and _start([]).scope == [] and _start(["  "]).scope == []


def test_start_agent_refuses_an_absurdly_long_fence():
    from fastapi import HTTPException

    res = _start([f"f{i}" for i in range(scope_fence.MAX_PATTERNS + 1)])
    assert isinstance(res, HTTPException) and res.status_code == 400


def test_a_path_that_cannot_be_put_back_is_recorded_and_said_out_loud(repo, monkeypatch):
    real = scope_fence.enforce

    async def partial(worktree, fence, before, run_id):
        res = await real(worktree, fence, before, run_id)
        res.failed, res.reverted = ["docs/readme.md"], []
        return res

    monkeypatch.setattr(scope_fence, "enforce", partial)
    store, hub, ws, run = _setup(repo, ["src"])
    _go(store, hub, ws, run, _Edits({"docs/readme.md": "r-agent\n"}))
    assert run.scope_error and "docs/readme.md" in run.scope_error
    assert any("could not put back 1 change(s)" in t for t in _texts(hub, ws))
    assert receipt_svc._build_scope(store, ws).unchecked_runs == 1


def test_start_agent_refuses_a_malformed_glob():
    from fastapi import HTTPException

    res = _start(["src/[z-a].ts"])
    assert isinstance(res, HTTPException) and res.status_code == 400


class _HookEdits(AgentAdapter):
    """Stands in for the CLI: asks the hook URL before each write, writes only what it allows."""

    name = "hook-edits"

    def __init__(self, writes: dict[str, str]) -> None:
        self.writes, self.url, self.answers = writes, None, {}

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, fence_hook_url=None):
        self.url = fence_hook_url
        token = fence_hook_url.rsplit("/", 1)[-1] if fence_hook_url else ""
        for rel, text in self.writes.items():
            ev = {"tool_name": "Write", "tool_input": {"file_path": str(Path(cwd) / rel)}}
            self.answers[rel] = scope_fence.judge(token, ev)
            if self.answers[rel]:
                continue
            p = Path(cwd) / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        yield NormalizedEvent("done", {"session_id": "c"})


def test_a_fenced_run_is_asked_before_each_write_and_the_refusals_reach_the_receipt(repo, monkeypatch):
    monkeypatch.setattr("haro.runner.settings.api_url", "http://127.0.0.1:9/", raising=False)  # trailing slash
    store, hub, ws, run = _setup(repo, ["src/a.ts"])
    adapter = _HookEdits({"src/a.ts": "a1\n", "docs/readme.md": "r-agent\n"})
    _go(store, hub, ws, run, adapter)
    assert adapter.url.startswith("http://127.0.0.1:9/hooks/fence/") and "//hooks" not in adapter.url
    assert run.id not in adapter.url  # the secret token, not the run id
    assert (repo / "src/a.ts").read_text() == "a1\n"
    assert (repo / "docs/readme.md").read_text() == "r0\n"  # never written, so nothing to revert
    assert run.fence_blocked == ["docs/readme.md"]
    assert run.scope_reverted == []
    assert receipt_svc._build_scope(store, ws).blocked == ["docs/readme.md"]
    token = adapter.url.rsplit("/", 1)[-1]
    assert scope_fence.judge(token, {"tool_name": "Write", "tool_input": {"file_path": str(repo / "docs/x")}}) == {}
    assert any("refused edit(s) outside the fence" in t for t in _texts(hub, ws))


def test_without_an_api_address_the_hook_is_not_offered(repo, monkeypatch):
    monkeypatch.setattr("haro.runner.settings.api_url", "", raising=False)
    store, hub, ws, run = _setup(repo, ["src/a.ts"])
    adapter = _HookEdits({"docs/readme.md": "r-agent\n"})
    _go(store, hub, ws, run, adapter)
    assert adapter.url is None
    assert run.scope_reverted == ["docs/readme.md"]  # the revert after the run still holds
