"""Threading the Plan-Mode flag through the run path (request → runner → adapter).

``test_plan_mode_flag.py`` pins the adapter argv; these pin the *handoff*: the
runner passes ``plan`` only to adapters that accept it (feature-detect, never a
hard error), and a plan run edits nothing so the runner must NOT fire the test
gate on its ``done`` — step ③ stays idle until an implementation run lands.
"""

import asyncio

import pytest

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, Workspace, WorkspaceStatus
from haro.models import TestRun as RunModel  # aliased: pytest tries to collect Test*
from haro.models import TestRunStatus as RunStatus
from haro.runner import run_agent
from haro.store import Store


class _PlanAwareAdapter(AgentAdapter):
    """Mirrors ClaudeCodeAdapter: its ``run`` accepts ``plan``."""

    name = "plan-aware"

    def __init__(self) -> None:
        self.seen_plan = "unset"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False):
        self.seen_plan = plan
        yield NormalizedEvent("done", {"session_id": "sess-1"})


class _PlanBlindAdapter(AgentAdapter):
    """A future adapter with no plan support — ``run`` has no ``plan`` param."""

    name = "plan-blind"

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


def _drive(adapter, ws, store, hub, *, plan, run_gate_spy, monkeypatch):
    """Run ``run_agent`` with the gate stubbed to a call-recorder, return the run."""
    async def fake_gate(**kwargs):
        run_gate_spy.append(kwargs)
        return RunModel(workspace_id=ws.id, runner="vitest", status=RunStatus.passed)

    monkeypatch.setattr("haro.runner.run_gate", fake_gate)
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t", plan=plan)
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        test_adapter=object(), project_path="/tmp/proj",
        auto_gate=True, plan=plan,
    ))
    return run


def test_plan_run_skips_the_gate(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _PlanAwareAdapter()
    spy: list = []
    run = _drive(adapter, ws, store, hub, plan=True, run_gate_spy=spy, monkeypatch=monkeypatch)

    assert adapter.seen_plan is True          # the flag reached the adapter
    assert spy == []                          # …and the gate never ran (no diff to gate)
    assert run.status == AgentRunStatus.done
    assert ws.status == WorkspaceStatus.idle   # settled to idle, step ③ untouched


def test_non_plan_run_still_gates(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _PlanAwareAdapter()
    spy: list = []
    _drive(adapter, ws, store, hub, plan=False, run_gate_spy=spy, monkeypatch=monkeypatch)

    assert adapter.seen_plan is False
    assert len(spy) == 1                       # auto-edit run → gate fires as before


def test_plan_flag_hidden_from_adapters_that_cant_plan(monkeypatch):
    # A plan request against an adapter whose run() has no `plan` param must not
    # raise (unexpected-kwarg): the flag is feature-detected away, not forced. And
    # because the adapter never planned, the run edited files as usual — so the gate
    # MUST still fire (never skip the gate on real edits).
    store, hub, ws = _fixture()
    adapter = _PlanBlindAdapter()
    spy: list = []
    run = _drive(adapter, ws, store, hub, plan=True, run_gate_spy=spy, monkeypatch=monkeypatch)

    assert adapter.called is True
    assert run.status == AgentRunStatus.done
    assert len(spy) == 1  # degraded to a normal auto-edit run → gated, not skipped
