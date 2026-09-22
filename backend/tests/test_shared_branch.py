"""Shared-branch semantics — the last bullet of backlog/agent-modes.md §4.

All agent sessions in a workspace edit the SAME git worktree, so:

- **Serialization**: their runs serialize on a per-worktree agent lock
  (``Store.agent_lock`` — the analogue of ``git_ops._cwd_locks``). A 2nd session is
  *allowed* to start (not rejected like the old per-workspace guard), but its drive
  queues behind the 1st and only edits a settled tree. Two agents never edit the same
  files at the same instant.
- **The gate sees the combined diff**: the gate is session-agnostic — it always runs
  on ``workspace.worktree_path`` (the one shared tree), never a per-session path.

No httpx/pytest-asyncio in the gate env, so coroutines are driven directly with
``asyncio.run`` (same pattern as test_ws_multiplexing.py).
"""

from __future__ import annotations

import asyncio
import os
import tempfile

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.adapters.test_runner.base import TestResult as _TestResult  # aliased: pytest tries to collect a bare ``Test*`` import as a test class
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, Workspace, WorkspaceStatus
from haro.runner import run_agent
from haro.store import DEFAULT_SESSION, SETUP_SESSION, Store


def _fixture(worktree_path: str = "/tmp/wt"):
    store, hub = Store(), Hub()
    ws = Workspace(
        project_id="p", name="w", branch="haro/w",
        worktree_path=worktree_path, base_ref="main",
    )
    store.add_workspace(ws)
    return store, hub, ws


def _mk_run(store, ws, session_id):
    run = AgentRun(workspace_id=ws.id, adapter="x", task="t")
    store.add_run(run)
    return run


# --- store: per-session task registry + worktree lock ------------------------ #
def test_agent_lock_is_one_per_workspace():
    store = Store()
    a, a2, b = store.agent_lock("w1"), store.agent_lock("w1"), store.agent_lock("w2")
    assert a is a2  # same workspace → same lock (that's what serializes its sessions)
    assert a is not b  # different worktrees don't block each other


def test_task_registry_is_per_session():
    async def go():
        store, _hub, ws = _fixture()

        async def idle():
            await asyncio.sleep(3600)

        task_a = asyncio.create_task(idle())
        store.set_active_task(ws.id, "A", task_a)
        # A is busy, but a *different* session is free — no blanket per-workspace reject.
        assert store.active_task(ws.id, "A") is task_a
        assert store.active_task(ws.id, "B") is None
        assert store.workspace_busy(ws.id) is True

        task_a.cancel()
        try:
            await task_a
        except asyncio.CancelledError:
            pass
        # A settled → the workspace is no longer busy; pop clears the slot.
        assert store.workspace_busy(ws.id) is False
        store.pop_active_task(ws.id, "A")
        assert store.active_task(ws.id, "A") is None

    asyncio.run(go())


def test_busy_reason_precedence():
    async def go():
        store, _hub, ws = _fixture()

        async def idle():
            await asyncio.sleep(3600)

        assert store.busy_reason(ws.id) is None

        gate = asyncio.create_task(idle())
        store.gate_tasks[ws.id] = gate
        assert store.busy_reason(ws.id) == "the gate"

        agent = asyncio.create_task(idle())
        store.set_active_task(ws.id, "A", agent)
        assert store.busy_reason(ws.id) == "an agent"  # an agent outranks the gate

        setup = asyncio.create_task(idle())
        store.set_active_task(ws.id, SETUP_SESSION, setup)
        assert store.busy_reason(ws.id) == "setup"  # setup outranks both
        assert store.setup_running(ws.id) is True

        for t in (gate, agent, setup):
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass

    asyncio.run(go())


# --- runner: two sessions serialize on the worktree lock --------------------- #
def test_two_sessions_in_one_workspace_serialize():
    """Launched concurrently, the two runs do NOT interleave — one fully enters and
    exits its edit window before the other begins (the per-worktree lock at work)."""
    store, hub, ws = _fixture()
    order: list[str] = []

    class SerialAdapter(AgentAdapter):
        name = "serial"

        def __init__(self, sid: str) -> None:
            self.sid = sid

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            order.append(f"enter:{self.sid}")
            await asyncio.sleep(0.02)  # yield control — would interleave without the lock
            order.append(f"exit:{self.sid}")
            yield NormalizedEvent("done", {"session_id": f"c-{self.sid}"})

    async def go():
        await asyncio.gather(
            run_agent(store=store, hub=hub, adapter=SerialAdapter("A"), workspace=ws,
                      run=_mk_run(store, ws, "A"), auto_gate=False, session_id="A"),
            run_agent(store=store, hub=hub, adapter=SerialAdapter("B"), workspace=ws,
                      run=_mk_run(store, ws, "B"), auto_gate=False, session_id="B"),
        )

    asyncio.run(go())

    # Serialized: never enter:A, enter:B, … — one closes before the other opens.
    assert order in (
        ["enter:A", "exit:A", "enter:B", "exit:B"],
        ["enter:B", "exit:B", "enter:A", "exit:A"],
    )
    # Both sessions kept their own transcript (the queued one still ran to completion).
    assert store.sessions(ws.id) == ["A", "B"]


def test_queued_session_gets_a_waiting_notice():
    """A 2nd run that finds the lock held tells its own stream it's queued, so a
    serialized session doesn't look like a hang."""
    store, hub, ws = _fixture()

    class SlowAdapter(AgentAdapter):
        name = "slow"

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            await asyncio.sleep(0.02)
            yield NormalizedEvent("done", {"session_id": "c"})

    async def go():
        await asyncio.gather(
            run_agent(store=store, hub=hub, adapter=SlowAdapter(), workspace=ws,
                      run=_mk_run(store, ws, "A"), auto_gate=False, session_id="A"),
            run_agent(store=store, hub=hub, adapter=SlowAdapter(), workspace=ws,
                      run=_mk_run(store, ws, "B"), auto_gate=False, session_id="B"),
        )

    asyncio.run(go())

    # Exactly one session (whichever lost the race) got the queued notice on its stream.
    notices = [
        e for e in hub.history(ws.id)
        if e.get("channel") == "agent"
        and "queued" in (e.get("event", {}).get("payload", {}).get("text") or "")
    ]
    assert len(notices) == 1
    assert notices[0]["session_id"] in ("A", "B")


# --- runner: the gate is session-agnostic (combined diff) -------------------- #
def test_gate_runs_on_the_shared_worktree_for_every_session():
    proj = tempfile.mkdtemp(prefix="haro-proj-")
    wt = tempfile.mkdtemp(prefix="haro-wt-")
    os.mkdir(os.path.join(wt, "node_modules"))  # so ensure_deps is a no-op
    store, hub, ws = _fixture(worktree_path=wt)
    ws.project_id = "p"

    seen_cwds: list[str] = []

    class FakeGate(TestRunnerAdapter):
        name = "fake"

        async def run(self, *, cwd, emit=None, changed_since=None, only=None):
            seen_cwds.append(cwd)
            return _TestResult(ok=True, total=1, passed=1)

    class DoneAdapter(AgentAdapter):
        name = "done"

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            yield NormalizedEvent("done", {"session_id": "c"})

    gate = FakeGate()
    for sid in (DEFAULT_SESSION, "review"):
        asyncio.run(run_agent(
            store=store, hub=hub, adapter=DoneAdapter(), workspace=ws,
            run=_mk_run(store, ws, sid), test_adapter=gate, project_path=proj,
            auto_gate=True, session_id=sid,
        ))

    # The gate ran once per session, always against the ONE shared worktree — never a
    # per-session path. That is "the gate sees the combined diff".
    assert seen_cwds == [wt, wt]
    assert ws.status == WorkspaceStatus.gate_green
