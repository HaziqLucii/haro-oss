"""Agent session lifecycle — both EDGES of a run are backend-owned and crash-safe
(backlog/agent-session-lifecycle.md).

A run's *execution* was already decoupled from the client. Its start and its end
weren't, and that's where every reported clunk lived. These tests pin the five fixes:

§1 **start edge** — a run fired at a still-provisioning worktree is ACCEPTED as
   ``queued`` and held by the backend until setup settles (it used to 409, which pushed
   the wait onto a client queue scoped to the *selected* workspace — switch away and the
   task was stranded forever). Plus its kill condition: a setup that never settles fails
   the run loudly instead of hanging it.
§2 **end edge** — cancelling a run kills the `claude` *process group*, not just the
   generator wrapped around it.
§3 ``stop_agent`` returns once the run has actually settled, and a cancelled setup
   shell takes its install tree with it.
§4 boot settles zombie ``running`` runs no task can ever finish.
§5 ``[agent] max_parallel`` caps concurrent spawns; over-cap runs wait as ``queued``.

Driven with ``asyncio.run`` (no pytest-asyncio in the gate env) — same pattern as
test_shared_branch.py / test_ws_multiplexing.py.
"""

from __future__ import annotations

import asyncio
import os
import tempfile
import time

from haro import db, main, runner
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.config import load_project_settings, write_project_agent
from haro.hub import Hub
from haro.lifecycle import _run_shell
from haro.models import (
    AgentRun,
    AgentRunStatus,
    StartAgentRequest,
    Workspace,
    WorkspaceStatus,
)
from haro.procs import terminate_tree
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


def _mk_run(store, ws, status=AgentRunStatus.running):
    run = AgentRun(workspace_id=ws.id, adapter="x", task="t", status=status)
    store.add_run(run)
    return run


def _texts(hub, ws) -> list[str]:
    """Every text line published on the agent channel for a workspace."""
    return [
        e["event"]["payload"].get("text") or ""
        for e in hub.history(ws.id)
        if e.get("channel") == "agent" and "event" in e
    ]


class _DoneAdapter(AgentAdapter):
    name = "done"

    def __init__(self) -> None:
        self.started_at: float | None = None

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        self.started_at = time.monotonic()
        yield NormalizedEvent("done", {"session_id": "c"})


# --------------------------------------------------------------------------- #
# §1 — backend-owned run deferral
# --------------------------------------------------------------------------- #
def test_run_fired_during_setup_waits_then_runs():
    """The felt bug: the agent must still start even though the click landed while the
    worktree was provisioning — and without the client being present to nudge it."""
    store, hub, ws = _fixture()
    adapter = _DoneAdapter()
    finished_setup: list[float] = []

    async def go():
        async def fake_setup():
            await asyncio.sleep(0.05)
            finished_setup.append(time.monotonic())
            store.pop_active_task(ws.id, SETUP_SESSION)  # run_setup's finally does this

        setup = asyncio.create_task(fake_setup())
        store.set_active_task(ws.id, SETUP_SESSION, setup)

        run = _mk_run(store, ws, status=AgentRunStatus.queued)
        await run_agent(store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
                        auto_gate=False)
        await setup
        return run

    run = asyncio.run(go())

    # It ran, and it ran AFTER setup finished — the backend held it, nothing was dropped.
    assert adapter.started_at is not None
    assert finished_setup and adapter.started_at >= finished_setup[0]
    # `queued` is a real state that resolves to `done`, not a limbo.
    assert run.status == AgentRunStatus.done
    assert any("Waiting for setup" in t for t in _texts(hub, ws))


def test_queued_status_round_trips_through_persistence():
    """Runs are persisted as JSON blobs keyed by id, so a new enum member needs no schema
    change — but it does need to survive validation on hydrate."""
    run = AgentRun(workspace_id="w", adapter="claude-code", status=AgentRunStatus.queued)
    revived = AgentRun.model_validate_json(run.model_dump_json())
    assert revived.status == AgentRunStatus.queued


def test_a_run_with_no_setup_in_flight_is_not_delayed():
    """No provisioning task ⇒ no wait, no notice. The common path is untouched."""
    store, hub, ws = _fixture()
    adapter = _DoneAdapter()
    run = _mk_run(store, ws)
    asyncio.run(run_agent(store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
                          auto_gate=False))
    assert run.status == AgentRunStatus.done
    assert not any("Waiting for setup" in t for t in _texts(hub, ws))


def test_a_setup_that_never_settles_fails_the_run_loudly():
    """§1's kill condition: a run must never sit `queued` forever because a setup task
    hung. It fails, says why, and leaves the workspace usable."""
    store, hub, ws = _fixture()
    adapter = _DoneAdapter()
    original = runner.SETUP_WAIT_TIMEOUT
    runner.SETUP_WAIT_TIMEOUT = 0.05

    async def go():
        hung = asyncio.create_task(asyncio.sleep(3600))
        store.set_active_task(ws.id, SETUP_SESSION, hung)
        run = _mk_run(store, ws, status=AgentRunStatus.queued)
        ws.status = WorkspaceStatus.setting_up
        await run_agent(store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
                        auto_gate=False)
        hung.cancel()
        return run

    try:
        run = asyncio.run(go())
    finally:
        runner.SETUP_WAIT_TIMEOUT = original

    assert run.status == AgentRunStatus.error
    assert run.ended_at is not None
    assert adapter.started_at is None  # loudly refused, never spawned
    assert ws.status == WorkspaceStatus.idle  # and not wedged in setting_up
    # Persisted (not just published), so the failure survives a reload.
    errors = [
        e for e in store.events_for(ws.id)
        if e["type"] == "error" and "setup has not finished" in e["payload"]["message"]
    ]
    assert len(errors) == 1


def test_start_agent_accepts_a_run_during_setup_as_queued():
    """The route half: no 409 while setting up, and the run comes back `queued`. The
    duplicate-same-session 409 — the guard that IS correct — still fires."""
    async def go():
        store, hub, ws = _fixture()
        main.store = store
        proj_path = tempfile.mkdtemp(prefix="haro-proj-")
        from haro.models import Project

        proj = Project(name="p", path=proj_path, default_branch="main")
        store.projects[proj.id] = proj
        ws.project_id = proj.id

        setup = asyncio.create_task(asyncio.sleep(3600))
        store.set_active_task(ws.id, SETUP_SESSION, setup)

        run = await main.start_agent(ws.id, StartAgentRequest(task="do it"))
        assert run.status == AgentRunStatus.queued, "a run during setup must be queued, not refused"

        # Same session, again → still a 409. Sessions serialize; one at a time.
        from fastapi import HTTPException

        try:
            await main.start_agent(ws.id, StartAgentRequest(task="again"))
            raise AssertionError("expected a 409 for a second run in the same session")
        except HTTPException as exc:
            assert exc.status_code == 409

        # Clean up the tasks this spawned so the loop closes quietly.
        for task in store.workspace_tasks(ws.id):
            task.cancel()
        await asyncio.gather(*store.workspace_tasks(ws.id), return_exceptions=True)

    asyncio.run(go())


def test_setup_guard_is_released_before_idle_is_announced():
    """``run_setup``'s finally used to publish "idle" while ``setup_running()`` was still
    true, so anything reacting to that event could be refused by the very guard the event
    said had lifted. Order matters: release, then announce."""
    from haro import lifecycle
    from haro.config import ProjectSettings
    from haro.models import Project

    store, hub, ws = _fixture(worktree_path=tempfile.mkdtemp(prefix="haro-wt-"))
    os.mkdir(os.path.join(ws.worktree_path, "node_modules"))  # ensure_deps no-ops
    proj = Project(name="p", path=tempfile.mkdtemp(prefix="haro-proj-"), default_branch="main")
    seen: list[bool] = []

    async def go():
        real_publish = hub.publish

        async def spy(ws_id, envelope):
            if envelope.get("status") == "idle":
                seen.append(store.setup_running(ws.id))
            await real_publish(ws_id, envelope)

        hub.publish = spy  # type: ignore[method-assign]
        task = asyncio.create_task(lifecycle.run_setup(
            store=store, hub=hub, workspace=ws, project=proj,
            psettings=ProjectSettings(),
        ))
        store.set_active_task(ws.id, SETUP_SESSION, task)
        await task

    asyncio.run(go())
    assert seen == [False], "idle was announced while setup_running() was still true"


# --------------------------------------------------------------------------- #
# §2 / §3 — process-group teardown
# --------------------------------------------------------------------------- #
def _spawn_tree() -> asyncio.subprocess.Process:
    """A shell that spawns a long-lived CHILD and waits — the shape that orphans:
    killing only the shell leaves the grandchild alive."""
    return asyncio.create_subprocess_exec(  # type: ignore[return-value]
        "/bin/sh", "-c", "sleep 300 & echo $!; wait",
        stdout=asyncio.subprocess.PIPE,
        start_new_session=True,
    )


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def test_terminate_tree_kills_the_whole_group():
    """The primitive §2 and §3 both build on: the grandchild dies too."""
    async def go():
        proc = await _spawn_tree()
        line = await proc.stdout.readline()
        child_pid = int(line.decode().strip())
        assert _alive(child_pid)
        await terminate_tree(proc, grace=2)
        assert proc.returncode is not None
        # Give the kernel a beat to reap the group.
        for _ in range(50):
            if not _alive(child_pid):
                break
            await asyncio.sleep(0.02)
        assert not _alive(child_pid), "the grandchild survived the group kill"

    asyncio.run(go())


def test_terminate_tree_is_a_noop_on_a_finished_process():
    """A normally-completing run must be completely unaffected by the teardown."""
    async def go():
        proc = await asyncio.create_subprocess_exec("/bin/true", start_new_session=True)
        await proc.wait()
        assert proc.returncode == 0
        await terminate_tree(proc)  # must not raise, must not change the outcome
        assert proc.returncode == 0

    asyncio.run(go())


def test_cancelling_a_run_kills_the_agent_subprocess():
    """End-to-end §2: a real `claude`-shaped subprocess, a real ⏹ stop. The adapter's
    generator is closed by the runner (``aclosing``), whose ``finally`` kills the group —
    so nothing survives detached."""
    pids: list[int] = []

    class _TreeAdapter(AgentAdapter):
        """Stands in for ClaudeCodeAdapter: same spawn flags, same teardown contract."""

        name = "tree"

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            proc = await _spawn_tree()
            try:
                line = await proc.stdout.readline()
                pids.append(int(line.decode().strip()))
                yield NormalizedEvent("token", {"text": "working"})
                await asyncio.sleep(3600)  # the long-running middle of a real run
                yield NormalizedEvent("done", {})
            finally:
                await terminate_tree(proc)

    store, hub, ws = _fixture()
    run = _mk_run(store, ws)

    async def go():
        task = asyncio.create_task(run_agent(
            store=store, hub=hub, adapter=_TreeAdapter(), workspace=ws, run=run,
            auto_gate=False,
        ))
        store.set_active_task(ws.id, DEFAULT_SESSION, task)
        while not pids:
            await asyncio.sleep(0.01)
        # Exactly what POST /agent/stop does, including the bounded settle wait.
        task.cancel()
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=5)
        except asyncio.CancelledError:
            pass
        for _ in range(100):
            if not _alive(pids[0]):
                break
            await asyncio.sleep(0.02)

    asyncio.run(go())
    assert not _alive(pids[0]), "the agent's child survived the stop (orphaned)"
    assert run.status == AgentRunStatus.stopped
    assert ws.status == WorkspaceStatus.idle


def test_stop_agent_returns_only_once_the_run_has_settled():
    """§3: "stopped" used to be a promise, not a fact — the endpoint returned the instant
    cancel() was *requested*. Now a 200 means the teardown has actually run."""
    torn_down: list[str] = []

    class _SlowTeardownAdapter(AgentAdapter):
        name = "slow-teardown"

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            try:
                yield NormalizedEvent("token", {"text": "working"})
                await asyncio.sleep(3600)
            finally:
                await asyncio.sleep(0.05)  # a real kill+grace takes time
                torn_down.append("done")

    async def go():
        store, hub, ws = _fixture()
        main.store = store
        run = _mk_run(store, ws)
        task = asyncio.create_task(run_agent(
            store=store, hub=hub, adapter=_SlowTeardownAdapter(), workspace=ws, run=run,
            auto_gate=False,
        ))
        store.set_active_task(ws.id, DEFAULT_SESSION, task)
        while not _texts(hub, ws):
            await asyncio.sleep(0.01)
        result = await main.stop_agent(ws.id)
        # The teardown ran BEFORE the endpoint answered — that's the whole point.
        assert torn_down == ["done"], "stop_agent returned before the run settled"
        assert result["settled"] is True
        assert run.status == AgentRunStatus.stopped

    asyncio.run(go())


def test_a_cancelled_setup_shell_leaves_no_orphaned_install():
    """§3's other half: the setup shell is group-led and killed in a ``finally``, so a
    workspace deleted mid-`npm install` doesn't leave the install churning."""
    pids: list[int] = []

    async def go():
        async def on_line(text: str) -> None:
            stripped = text.strip()
            if stripped.isdigit():
                pids.append(int(stripped))

        task = asyncio.create_task(_run_shell(
            "sleep 300 & echo $!; wait", cwd="/tmp", env=dict(os.environ), on_line=on_line,
        ))
        while not pids:
            await asyncio.sleep(0.01)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        for _ in range(100):
            if not _alive(pids[0]):
                break
            await asyncio.sleep(0.02)

    asyncio.run(go())
    assert not _alive(pids[0]), "a cancelled setup left its install process running"


# --------------------------------------------------------------------------- #
# §4 — boot reconcile of AgentRun.status
# --------------------------------------------------------------------------- #
def test_reconcile_settles_interrupted_runs():
    store = Store()
    proj_dir = tempfile.mkdtemp(prefix="haro-proj-")
    from haro.models import Project

    proj = Project(name="p", path=proj_dir, default_branch="main")
    store.projects[proj.id] = proj
    wt = tempfile.mkdtemp(prefix="haro-wt-")
    os.mkdir(os.path.join(wt, ".git"))
    ws = Workspace(project_id=proj.id, name="w", branch="haro/w",
                   worktree_path=wt, base_ref="main")
    store.add_workspace(ws)

    zombie = AgentRun(workspace_id=ws.id, adapter="x", status=AgentRunStatus.running)
    held = AgentRun(workspace_id=ws.id, adapter="x", status=AgentRunStatus.queued)
    finished = AgentRun(workspace_id=ws.id, adapter="x", status=AgentRunStatus.done,
                        ended_at=123.0)
    for r in (zombie, held, finished):
        store.add_run(r)

    notes = db.reconcile(store)

    # Nothing can ever finish these two — the task supervising them died with the process.
    assert zombie.status == AgentRunStatus.stopped and zombie.ended_at is not None
    assert held.status == AgentRunStatus.stopped and held.ended_at is not None
    # A genuinely-finished run is untouched, timestamp included.
    assert finished.status == AgentRunStatus.done and finished.ended_at == 123.0
    assert any("interrupted agent run" in n for n in notes)


def test_reconcile_leaves_a_live_run_alone():
    """Guarded on there being no live task, so it stays correct if it's ever called
    somewhere other than boot."""
    async def go():
        store = Store()
        ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/tmp/wt",
                       base_ref="main")
        store.add_workspace(ws)
        live = AgentRun(workspace_id=ws.id, adapter="x", status=AgentRunStatus.running)
        store.add_run(live)
        task = asyncio.create_task(asyncio.sleep(3600))
        store.set_active_task(ws.id, DEFAULT_SESSION, task)
        db.reconcile(store)
        task.cancel()
        return live

    live = asyncio.run(go())
    assert live.status == AgentRunStatus.running


# --------------------------------------------------------------------------- #
# §5 — global concurrency guardrail
# --------------------------------------------------------------------------- #
def _race_two_runs(max_parallel: int) -> list[str]:
    """Start two runs in DIFFERENT workspaces at once; return the enter/exit order."""
    order: list[str] = []

    class _Marking(AgentAdapter):
        name = "marking"

        def __init__(self, tag: str) -> None:
            self.tag = tag

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            order.append(f"enter:{self.tag}")
            await asyncio.sleep(0.05)  # would interleave if nothing serialized them
            order.append(f"exit:{self.tag}")
            yield NormalizedEvent("done", {})

    async def go():
        store, hub = Store(), Hub()
        runs = []
        for tag in ("A", "B"):
            ws = Workspace(project_id="p", name=tag, branch=f"haro/{tag}",
                           worktree_path=f"/tmp/wt-{tag}", base_ref="main")
            store.add_workspace(ws)
            runs.append((ws, _mk_run(store, ws), _Marking(tag)))
        await asyncio.gather(*[
            run_agent(store=store, hub=hub, adapter=ad, workspace=ws, run=run,
                      auto_gate=False, max_parallel=max_parallel)
            for ws, run, ad in runs
        ])

    asyncio.run(go())
    return order


def test_max_parallel_one_serializes_cross_workspace_runs():
    """Different worktrees, so the per-worktree lock does NOT apply — only the global
    cap can serialize these."""
    order = _race_two_runs(max_parallel=1)
    assert order in (
        ["enter:A", "exit:A", "enter:B", "exit:B"],
        ["enter:B", "exit:B", "enter:A", "exit:A"],
    ), order


def test_max_parallel_zero_means_unlimited():
    order = _race_two_runs(max_parallel=0)
    assert order[:2] in (["enter:A", "enter:B"], ["enter:B", "enter:A"]), order


def test_a_run_waiting_for_a_slot_reads_as_queued():
    """The wait must be visible: a run over the cap says so on its own stream, rather
    than looking like a hang."""
    store, hub = Store(), Hub()
    states: list[AgentRunStatus] = []

    class _Blocking(AgentAdapter):
        name = "blocking"

        def __init__(self, release: asyncio.Event | None) -> None:
            self.release = release

        async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                      instructions=None, max_budget_usd=None):
            if self.release is not None:
                await self.release.wait()
            yield NormalizedEvent("done", {})

    async def go():
        release = asyncio.Event()
        ws_a = Workspace(project_id="p", name="A", branch="a", worktree_path="/tmp/a",
                         base_ref="main")
        ws_b = Workspace(project_id="p", name="B", branch="b", worktree_path="/tmp/b",
                         base_ref="main")
        store.add_workspace(ws_a)
        store.add_workspace(ws_b)
        run_a, run_b = _mk_run(store, ws_a), _mk_run(store, ws_b)

        first = asyncio.create_task(run_agent(
            store=store, hub=hub, adapter=_Blocking(release), workspace=ws_a, run=run_a,
            auto_gate=False, max_parallel=1,
        ))
        await asyncio.sleep(0.02)  # let A take the only slot
        second = asyncio.create_task(run_agent(
            store=store, hub=hub, adapter=_Blocking(None), workspace=ws_b, run=run_b,
            auto_gate=False, max_parallel=1,
        ))
        await asyncio.sleep(0.02)
        states.append(run_b.status)
        assert any("Queued" in t for t in _texts(hub, ws_b))
        release.set()
        await asyncio.gather(first, second)
        states.append(run_b.status)

    asyncio.run(go())
    assert states == [AgentRunStatus.queued, AgentRunStatus.done]


def test_max_parallel_round_trips_through_the_config(tmp_path):
    """`0` is a real value (unlimited), so it must survive a write→read cycle rather
    than being read back as "unset" and silently re-defaulting to 4."""
    proj = tmp_path / "proj"
    proj.mkdir()
    assert load_project_settings(str(proj)).max_parallel == 4  # default

    write_project_agent(
        str(proj), default_model="sonnet", default_effort="", max_budget_usd=5.0,
        cost_warn_usd=20.0, max_parallel=0,
    )
    assert load_project_settings(str(proj)).max_parallel == 0

    write_project_agent(
        str(proj), default_model="sonnet", default_effort="", max_budget_usd=5.0,
        cost_warn_usd=20.0, max_parallel=2,
    )
    assert load_project_settings(str(proj)).max_parallel == 2
    assert "max_parallel = 2" in (proj / ".haro" / "settings.toml").read_text()
