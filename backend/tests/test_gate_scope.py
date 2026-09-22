"""Impacted-only auto-gate: the agent→gate handoff picks its scope.

The manual "run all"/"impacted" buttons already choose scope per-run; this covers
the *default* scope the auto-gate uses when an agent finishes — ``gate_scope``
threaded into ``run_agent`` → ``run_gate(changed_since=...)``. "all" runs the full
suite (``changed_since=None``); "impacted" runs only the tests the diff vs base_ref
affects (``changed_since=base_ref``).
"""

import asyncio

from haro import runner
from haro.models import AgentRun, AgentRunStatus, Project, Workspace
from haro.models import TestRun as RunModel  # aliased: pytest tries to collect Test*
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


class _Adapter:
    name = "claude"


def _drive_run_agent(gate_scope: str, monkeypatch) -> list[str | None]:
    """Run ``run_agent`` with the gate stubbed; return the ``changed_since`` values
    it passed into ``run_gate`` (one per gate call)."""
    store = Store()
    project = Project(id="p", name="proj", path="/tmp/proj", default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path="/tmp/wt", base_ref="main",
    )
    store.workspaces[ws.id] = ws
    run = AgentRun(workspace_id=ws.id, adapter="claude", task="do it")
    store.add_run(run)

    seen: list[str | None] = []

    async def fake_drive(*, run, **_kw):
        run.status = AgentRunStatus.done

    async def fake_gate(*, changed_since=None, **_kw):
        seen.append(changed_since)
        # A green run stops the auto-fix loop from spinning.
        return RunModel(workspace_id=ws.id, runner="vitest", status=RunStatus.passed)

    # setattr via the fixture so both stubs are RESTORED after the test — a raw
    # ``runner._drive_agent = …`` leaks the fake into every later test in the suite.
    monkeypatch.setattr(runner, "_drive_agent", fake_drive)
    monkeypatch.setattr(runner, "run_gate", fake_gate)

    asyncio.run(
        runner.run_agent(
            store=store,
            hub=None,  # type: ignore[arg-type] — never touched (both hooks are stubbed)
            adapter=_Adapter(),  # type: ignore[arg-type]
            workspace=ws,
            run=run,
            test_adapter=_Adapter(),  # type: ignore[arg-type]
            project_path=project.path,
            auto_gate=True,
            gate_scope=gate_scope,
        )
    )
    return seen


def test_auto_gate_all_scope_runs_full_suite(monkeypatch):
    assert _drive_run_agent("all", monkeypatch) == [None]


def test_auto_gate_impacted_scope_runs_impacted_since_base_ref(monkeypatch):
    assert _drive_run_agent("impacted", monkeypatch) == ["main"]
