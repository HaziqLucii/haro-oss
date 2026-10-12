"""Runs saved before 2026-09-30 carry `vacuous` tamper findings, and under `tamper_alarm =
"block"` those runs were red. Hydrating must strip them and settle the workspace the way the
gate would, so an old vacuous-only run reads green without a re-gate."""

from __future__ import annotations

import asyncio

import pytest

from haro import db
from haro.models import (
    GateSummary,
    Project,
    TamperFinding,
    Workspace,
    WorkspaceStatus,
)
from haro.models import TestRun as RunModel
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


def _run(coro):
    return asyncio.run(coro)


@pytest.fixture
def sqlite_db(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_DB", str(tmp_path / "haro.db"))
    monkeypatch.setattr(db, "_conn", None)
    monkeypatch.setattr(db, "_readonly", False)
    monkeypatch.setattr(db, "_lock_fd", None)
    db._hydrated.clear()
    yield
    _run(db.close())
    db._hydrated.clear()


def _snapshot(tmp_path, findings, *, blocked, extra=None):
    wt = tmp_path / "wt"
    wt.mkdir(exist_ok=True)
    project = Project(name="p", path=str(tmp_path), default_branch="main")
    ws = Workspace(
        project_id=project.id, name="w", branch="b", worktree_path=str(wt), base_ref="main",
        status=WorkspaceStatus.gate_red,
    )
    run = RunModel(
        workspace_id=ws.id, project_id=project.id, runner="vitest", status=RunStatus.passed,
        total=1, passed=1, tamper_findings=findings, tamper_blocked=blocked,
        tamper_note=" · ".join(sorted({f"1 {f.kind}" for f in findings})) or None,
        **(extra or {}),
    )
    ws.gate = GateSummary(
        status=run.status, tamper_count=len(findings), tamper_note=run.tamper_note
    )
    return project, ws, run


def _boot(project, ws, run):
    async def go():
        assert await db.init()
        store = Store()
        store.projects[project.id] = project
        store.workspaces[ws.id] = ws
        store.tests[run.id] = run
        await db.save_snapshot(store)
        fresh = Store()
        await db.load_into(fresh)
        return fresh

    return _run(go())


def _vac(name="weekdays add nothing"):
    return TamperFinding(kind="vacuous", file="a.test.ts", test=name, detail="already passes at base_ref")


def test_an_old_vacuous_only_blocked_run_reads_green_after_load(sqlite_db, tmp_path):
    project, ws, run = _snapshot(tmp_path, [_vac()], blocked=True)
    store = _boot(project, ws, run)

    r = store.tests[run.id]
    assert r.tamper_findings == []
    assert r.tamper_blocked is False
    assert r.tamper_note is None
    w = store.workspaces[ws.id]
    assert w.status == WorkspaceStatus.gate_green
    assert w.gate.tamper_count == 0 and w.gate.tamper_note is None


def test_a_mixed_old_run_stays_blocked_on_the_remaining_finding(sqlite_db, tmp_path):
    removed = TamperFinding(kind="removed", file="a.test.ts", test="guards", detail="test removed")
    project, ws, run = _snapshot(tmp_path, [_vac(), removed], blocked=True)
    store = _boot(project, ws, run)

    r = store.tests[run.id]
    assert [f.kind for f in r.tamper_findings] == ["removed"]
    assert r.tamper_blocked is True
    assert r.tamper_note == "1 removed"
    w = store.workspaces[ws.id]
    assert w.status == WorkspaceStatus.gate_red
    assert w.gate.tamper_count == 1


def test_a_warn_mode_old_run_stays_unblocked_and_the_workspace_is_untouched(sqlite_db, tmp_path):
    project, ws, run = _snapshot(tmp_path, [_vac()], blocked=False)
    ws.status = WorkspaceStatus.gate_green
    store = _boot(project, ws, run)

    assert store.tests[run.id].tamper_findings == []
    assert store.tests[run.id].tamper_blocked is False
    assert store.workspaces[ws.id].status == WorkspaceStatus.gate_green


def test_other_blockers_keep_the_workspace_red(sqlite_db, tmp_path):
    project, ws, run = _snapshot(tmp_path, [_vac()], blocked=True, extra={"coverage_blocked": True})
    store = _boot(project, ws, run)

    assert store.tests[run.id].tamper_blocked is False
    assert store.workspaces[ws.id].status == WorkspaceStatus.gate_red


def test_an_old_red_first_engine_failure_no_longer_degrades_the_run(sqlite_db, tmp_path):
    other = "the sandbox was asked for but bwrap is not installed"
    project, ws, run = _snapshot(
        tmp_path, [], blocked=False,
        extra={"degraded_reasons": [db._OLD_RED_FIRST_DEGRADE, other]},
    )
    ws.status = WorkspaceStatus.gate_green
    ws.gate.degraded = True
    store = _boot(project, ws, run)
    assert store.tests[run.id].degraded_reasons == [other]
    assert store.workspaces[ws.id].gate.degraded is True


def test_a_run_degraded_only_by_the_old_red_first_failure_is_no_longer_degraded(sqlite_db, tmp_path):
    project2, ws2, run2 = _snapshot(
        tmp_path, [], blocked=False, extra={"degraded_reasons": [db._OLD_RED_FIRST_DEGRADE]},
    )
    ws2.status = WorkspaceStatus.gate_green
    ws2.gate.degraded = True
    store2 = _boot(project2, ws2, run2)
    assert store2.tests[run2.id].degraded_reasons == []
    assert store2.workspaces[ws2.id].gate.degraded is False
