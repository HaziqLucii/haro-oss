"""The agent's own `gh` calls are pinned to the project's GitHub account: the machine's active
account is global, so another session's `gh auth switch` must not change who a PR or comment is
posted as between two of the agent's calls."""

from __future__ import annotations

import asyncio

from haro.adapters import claude_code as cc
from haro.adapters.claude_code import ClaudeCodeAdapter


def _spawned_env(monkeypatch, **kwargs):
    seen: dict = {}

    async def fake_exec(*cmd, env=None, **_):
        seen["env"] = env
        raise FileNotFoundError

    monkeypatch.setattr(cc.asyncio, "create_subprocess_exec", fake_exec)

    async def go():
        async for _ in ClaudeCodeAdapter().run(task="t", cwd="/tmp", **kwargs):
            pass

    asyncio.run(go())
    return seen["env"]


def test_the_pinned_token_reaches_the_agent_process(monkeypatch):
    monkeypatch.delenv("GH_TOKEN", raising=False)
    env = _spawned_env(monkeypatch, gh_token="tok_project")
    assert env["GH_TOKEN"] == "tok_project"


def test_without_a_pinned_token_the_env_is_left_alone(monkeypatch):
    monkeypatch.delenv("GH_TOKEN", raising=False)
    env = _spawned_env(monkeypatch)
    assert env is None


class _Recorder:
    """Stands in for an adapter and keeps the keyword arguments the runner passed."""

    name = "rec"

    def __init__(self):
        self.kwargs: dict = {}

    async def run(self, *, task, cwd, gh_token=None, **_):
        self.kwargs["gh_token"] = gh_token
        from haro.adapters.base import NormalizedEvent

        yield NormalizedEvent("done", {"session_id": "c"})


def _run_with(monkeypatch, tmp_path, gh_env, ambient=None):
    from haro import git_ops
    from haro.hub import Hub
    from haro.models import AgentRun, Workspace
    from haro.runner import run_agent
    from haro.store import Store

    async def fake_gh_env(_path):
        return gh_env

    monkeypatch.setattr(git_ops, "gh_env", fake_gh_env)
    if ambient:
        monkeypatch.setenv("GH_TOKEN", ambient)
    else:
        monkeypatch.delenv("GH_TOKEN", raising=False)
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="rec", task="t")
    store.add_run(run)
    rec = _Recorder()
    asyncio.run(run_agent(store=store, hub=hub, adapter=rec, workspace=ws, run=run, auto_gate=False))
    return rec.kwargs["gh_token"]


def test_the_runner_hands_the_project_account_token_to_the_agent(monkeypatch, tmp_path):
    assert _run_with(monkeypatch, tmp_path, {"GH_TOKEN": "tok_project", "GH_REPO": "o/r"}) == "tok_project"


def test_no_account_and_a_users_own_gh_token_are_left_alone(monkeypatch, tmp_path):
    assert _run_with(monkeypatch, tmp_path, None) is None
    assert _run_with(monkeypatch, tmp_path, {"GH_TOKEN": "mine"}, ambient="mine") is None
