"""The guard, the restore point and the API-key note through ``run_agent``."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import receipt as receipt_svc
from haro import runner, scope_fence
from haro.adapters import claude_code
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, Workspace
from haro.runner import run_agent
from haro.store import Store


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    )


@pytest.fixture
def repo(tmp_path) -> Path:
    r = tmp_path / "repo"
    r.mkdir()
    _git(r, "init", "-q", "-b", "main")
    (r / "a.txt").write_text("a0\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    return r


class _Shell(AgentAdapter):
    """Stands in for the CLI: asks the hook before each command, runs only what it allows."""

    name = "shell"

    def __init__(self, commands: list[str]) -> None:
        self.commands, self.url, self.matcher, self.ran = commands, None, None, []

    async def run(self, *, task, cwd, model=None, effort=None, resume=None, instructions=None,
                  max_budget_usd=None, fence_hook_url=None, hook_matcher=None):
        self.url, self.matcher = fence_hook_url, hook_matcher
        token = fence_hook_url.rsplit("/", 1)[-1] if fence_hook_url else ""
        for c in self.commands:
            if not scope_fence.judge(token, {"tool_name": "Bash", "tool_input": {"command": c}}):
                self.ran.append(c)
        yield NormalizedEvent("done", {"session_id": "c"})


def _setup(repo: Path, scope=()):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="shell", task="t", scope=list(scope))
    store.add_run(run)
    return store, hub, ws, run


def _go(store, hub, ws, run, adapter, **kw):
    asyncio.run(run_agent(store=store, hub=hub, adapter=adapter, workspace=ws, run=run, auto_gate=False, **kw))


def _texts(hub, ws):
    return [
        e["event"]["payload"].get("text") or ""
        for e in hub.history(ws.id)
        if e.get("channel") == "agent" and "event" in e
    ]


@pytest.fixture(autouse=True)
def _api(monkeypatch):
    monkeypatch.setattr("haro.runner.settings.api_url", "http://127.0.0.1:9", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    runner._API_KEY_NOTED.clear()


def test_an_unfenced_run_gets_the_guard_hook_on_bash_and_read_only(repo):
    store, hub, ws, run = _setup(repo)
    adapter = _Shell(["npm test", "git reset --hard", "cat .env"])
    _go(store, hub, ws, run, adapter)
    assert adapter.matcher == "Bash|Read"
    assert adapter.ran == ["npm test"]
    assert run.guard_refused == ["git reset --hard", "read of .env"]
    assert any("Command guard: refused before they ran: `git reset --hard`, `read of .env`" in t for t in _texts(hub, ws))
    assert receipt_svc._build_guard(store, ws).refused == ["git reset --hard", "read of .env"]


def test_a_fenced_run_gets_edits_and_guard_in_one_matcher(repo):
    store, hub, ws, run = _setup(repo, scope=["a.txt"])
    adapter = _Shell(["git clean -fd"])
    _go(store, hub, ws, run, adapter)
    assert adapter.matcher == "Edit|Write|MultiEdit|NotebookEdit|Bash|Read"
    assert run.guard_refused == ["git clean -f"]


def test_the_guard_can_be_switched_off(repo):
    store, hub, ws, run = _setup(repo)
    adapter = _Shell(["git reset --hard"])
    _go(store, hub, ws, run, adapter, command_guard=False)
    assert adapter.url is None and adapter.ran == ["git reset --hard"]
    assert run.guard_refused == []


def test_no_hook_without_haros_own_address(repo, monkeypatch):
    monkeypatch.setattr("haro.runner.settings.api_url", "", raising=False)
    store, hub, ws, run = _setup(repo)
    adapter = _Shell(["git reset --hard"])
    _go(store, hub, ws, run, adapter)
    assert adapter.url is None


def test_an_api_key_in_the_environment_is_noted_once_per_workspace(repo, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-not-real")
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, _Shell([]))
    first = [t for t in _texts(hub, ws) if "ANTHROPIC_API_KEY" in t]
    assert len(first) == 1 and "may bill that API key instead of your Claude login" in first[0]
    assert "sk-not-real" not in first[0]
    run2 = AgentRun(workspace_id=ws.id, adapter="shell", task="t2")
    store.add_run(run2)
    _go(store, hub, ws, run2, _Shell([]))
    assert len([t for t in _texts(hub, ws) if "ANTHROPIC_API_KEY" in t]) == 1


def test_no_note_without_an_api_key(repo):
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, _Shell([]))
    assert not any("ANTHROPIC_API_KEY" in t for t in _texts(hub, ws))


def test_settings_json_uses_the_matcher_it_is_given():
    import json

    s = json.loads(claude_code._run_settings("http://x/hooks/fence/t", False, "Bash|Read"))
    assert s["hooks"]["PreToolUse"][0]["matcher"] == "Bash|Read"
    d = json.loads(claude_code._run_settings("http://x/hooks/fence/t", False))
    assert d["hooks"]["PreToolUse"][0]["matcher"] == claude_code._FENCE_MATCHER
