"""run_gate holds an *auto* trigger on an unprovisioned adopted worktree, but never a
*manual* one — the Merge Firewall cry-wolf guard end-to-end (backlog/merge-firewall.md §2).

Complements the pure-helper unit tests in test_auto_gate_setup_guard.py: this asserts the
wiring in ``run_gate`` (early-return, no status flip, no recorded run) rather than the
decision alone."""

import asyncio

from haro.adapters.test_runner.base import TestRunnerAdapter
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
        self.ran = False

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        self.ran = True
        return self._result


def _setup(tmp_path, kind: str):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main", kind=kind,
    )
    store.workspaces[ws.id] = ws
    return store, hub, ws, project


def test_auto_gate_held_on_unprovisioned_adopted(tmp_path):
    store, hub, ws, project = _setup(tmp_path, "adopted")
    adapter = _Adapter(RunResult(ok=True, total=1, passed=1, failed=0, cases=[]))
    # setup_state absent → not ok.
    test = asyncio.run(run_gate(
        store=store, hub=hub, adapter=adapter, workspace=ws,
        project_path=project.path, trigger="auto",
    ))
    assert adapter.ran is False           # the gate never actually ran
    assert ws.status != WorkspaceStatus.gate_red  # no cry-wolf red flip
    assert ws.gate is None                # nothing denormalized
    assert store.latest_test(ws.id) is None  # not recorded
    assert test.status == RunStatus.running  # the held sentinel


def test_manual_gate_runs_on_unprovisioned_adopted(tmp_path):
    store, hub, ws, project = _setup(tmp_path, "adopted")
    adapter = _Adapter(RunResult(ok=True, total=1, passed=1, failed=0, cases=[]))
    asyncio.run(run_gate(
        store=store, hub=hub, adapter=adapter, workspace=ws,
        project_path=project.path, trigger="manual",
    ))
    assert adapter.ran is True            # a hand-triggered gate is always honored
    assert ws.status == WorkspaceStatus.gate_green


def test_auto_gate_runs_once_adopted_setup_ok(tmp_path):
    store, hub, ws, project = _setup(tmp_path, "adopted")
    store.setup_state[ws.id] = {"status": "ok", "exit": 0, "note": None}
    adapter = _Adapter(RunResult(ok=True, total=1, passed=1, failed=0, cases=[]))
    asyncio.run(run_gate(
        store=store, hub=hub, adapter=adapter, workspace=ws,
        project_path=project.path, trigger="auto",
    ))
    assert adapter.ran is True
    assert ws.status == WorkspaceStatus.gate_green
