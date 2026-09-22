"""run_gate denormalizes its result onto the workspace + broadcasts it — the data
behind the dashboard's glance view ("N gates need you / N failing")."""

import asyncio

# Aliased: pytest would otherwise try to *collect* these Test*-named imports.
from haro.adapters.test_runner.base import CaseResult, TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import Project, Workspace, WorkspaceStatus
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


class _Adapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, result: RunResult):
        self._result = result

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        if emit:
            await emit({"kind": "run_started"})
        return self._result


def _setup(tmp_path, result: RunResult):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main",
    )
    store.workspaces[ws.id] = ws
    return store, hub, ws, project


def test_red_gate_summary_and_broadcast(tmp_path):
    result = RunResult(
        ok=False, total=3, passed=2, failed=1, skipped=0,
        cases=[
            CaseResult(file="a.test.ts", name="a", status="passed"),
            CaseResult(file="a.test.ts", name="b", status="passed"),
            CaseResult(file="a.test.ts", name="c", status="failed", message="boom"),
        ],
    )
    store, hub, ws, project = _setup(tmp_path, result)
    q = hub.subscribe(ws.id)

    asyncio.run(run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))

    assert ws.status == WorkspaceStatus.gate_red
    assert ws.gate is not None
    assert ws.gate.status == RunStatus.failed
    assert (ws.gate.total, ws.gate.passed, ws.gate.failed) == (3, 2, 1)
    assert ws.gate.scope == "all"

    # the final status envelope carried the gate summary (dashboard glance feed)
    envelopes = []
    while not q.empty():
        envelopes.append(q.get_nowait())
    gate_status = [e for e in envelopes if e.get("channel") == "status" and "gate" in e]
    assert gate_status and gate_status[-1]["gate"]["failed"] == 1


def test_green_gate_summary(tmp_path):
    result = RunResult(ok=True, total=2, passed=2, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))
    assert ws.status == WorkspaceStatus.gate_green
    assert ws.gate.status == RunStatus.passed
    assert ws.gate.total == 2 and ws.gate.failed == 0


def _gate_notify(q):
    """Drain a workspace queue and return the coarse gate verdict envelope."""
    out = []
    while not q.empty():
        e = q.get_nowait()
        if e.get("channel") == "notify" and e.get("kind") in ("gate_green", "gate_red"):
            out.append(e)
    return out[-1] if out else None


def test_gate_notify_carries_workspace_kind_managed(tmp_path):
    # The coarse gate verdict rides the global feed tagged with the workspace kind so
    # the client can decide whether to beep — a managed workspace already beeped on
    # agent_done, so the frontend suppresses a second beep for kind="managed".
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    q = hub.subscribe(ws.id)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))
    notify = _gate_notify(q)
    assert notify is not None and notify["workspace_kind"] == "managed"


def test_gate_notify_carries_workspace_kind_adopted(tmp_path):
    # An adopted (agentless) worktree never emits agent_done, so its gate flip is the
    # completion moment the frontend beeps on — the envelope must say kind="adopted".
    result = RunResult(ok=False, total=1, passed=0, failed=1, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    ws.kind = "adopted"
    q = hub.subscribe(ws.id)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))
    notify = _gate_notify(q)
    assert notify is not None and notify["kind"] == "gate_red"
    assert notify["workspace_kind"] == "adopted"
