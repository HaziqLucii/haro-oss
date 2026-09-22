"""Threading the Fast-Mode flag through the run path (request → runner → adapter).

``test_fast_mode_flag.py`` pins the adapter argv; these pin the *handoff*: the
runner passes ``fast`` only to adapters that accept it (feature-detect, never a
hard error). Unlike a plan run, a fast run STILL edits files — so the gate MUST
fire on its ``done`` (the one behaviour that must NOT differ from a normal run).
"""

import asyncio

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, Workspace
from haro.models import TestRun as RunModel  # aliased: pytest tries to collect Test*
from haro.models import TestRunStatus as RunStatus
from haro.runner import run_agent
from haro.store import Store


class _FastAwareAdapter(AgentAdapter):
    """Mirrors ClaudeCodeAdapter: its ``run`` accepts ``fast``."""

    name = "fast-aware"

    def __init__(self) -> None:
        self.seen_fast = "unset"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False, fast=False):
        self.seen_fast = fast
        yield NormalizedEvent("done", {"session_id": "sess-1"})


class _FastBlindAdapter(AgentAdapter):
    """A future adapter with no fast support — ``run`` has no ``fast`` param."""

    name = "fast-blind"

    def __init__(self) -> None:
        self.called = False

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        self.called = True
        yield NormalizedEvent("done", {})


def _fixture():
    store, hub = Store(), Hub()
    ws = Workspace(
        project_id="p", name="w", branch="haro/w",
        worktree_path="/tmp/wt", base_ref="main",
    )
    store.add_workspace(ws)
    return store, hub, ws


def _drive(adapter, ws, store, hub, *, fast, run_gate_spy, monkeypatch):
    """Run ``run_agent`` with the gate stubbed to a call-recorder, return the run."""
    async def fake_gate(**kwargs):
        run_gate_spy.append(kwargs)
        return RunModel(workspace_id=ws.id, runner="vitest", status=RunStatus.passed)

    monkeypatch.setattr("haro.runner.run_gate", fake_gate)
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t", fast=fast)
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        test_adapter=object(), project_path="/tmp/proj",
        auto_gate=True, fast=fast,
    ))
    return run


def test_fast_run_reaches_adapter_and_still_gates(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _FastAwareAdapter()
    spy: list = []
    run = _drive(adapter, ws, store, hub, fast=True, run_gate_spy=spy, monkeypatch=monkeypatch)

    assert adapter.seen_fast is True           # the flag reached the adapter
    assert len(spy) == 1                        # …and the gate STILL ran (fast edits files)
    assert run.status == AgentRunStatus.done


def test_non_fast_run_leaves_flag_off(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _FastAwareAdapter()
    spy: list = []
    _drive(adapter, ws, store, hub, fast=False, run_gate_spy=spy, monkeypatch=monkeypatch)

    assert adapter.seen_fast is False
    assert len(spy) == 1


def test_fast_flag_hidden_from_adapters_that_cant_fast(monkeypatch):
    # A fast request against an adapter whose run() has no `fast` param must not
    # raise (unexpected-kwarg): the flag is feature-detected away, not forced. The
    # run proceeds normally and the gate fires as usual.
    store, hub, ws = _fixture()
    adapter = _FastBlindAdapter()
    spy: list = []
    run = _drive(adapter, ws, store, hub, fast=True, run_gate_spy=spy, monkeypatch=monkeypatch)

    assert adapter.called is True
    assert run.status == AgentRunStatus.done
    assert len(spy) == 1
