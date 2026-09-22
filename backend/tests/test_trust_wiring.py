"""The IO shell around the pure ``trust.evaluate`` (backlog/autonomy-ladder.md §1):
``build_trust_report`` reads the facts from the store, ``run_gate`` re-broadcasts the
report on the ``status`` channel (piggybacking the ``GateSummary`` publish), and
``GET /workspaces/{id}/trust`` returns it. The ladder *logic* is proven in
``test_trust.py``; here we prove only the wiring."""

from __future__ import annotations

import asyncio

import pytest
from fastapi import HTTPException

# Aliased: pytest would otherwise try to *collect* these Test*-named imports.
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.gate import build_trust_report, run_gate
from haro.hub import Hub
from haro import main as main_mod
from haro.models import Project, TestRun, Workspace
from haro.store import Store


class _Adapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, result: RunResult):
        self._result = result

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return self._result


def _seed(store: Store, tmp_path) -> tuple[Workspace, Project]:
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main",
    )
    store.workspaces[ws.id] = ws
    return ws, project


def test_build_trust_report_reads_store(tmp_path):
    store = Store()
    ws, _ = _seed(store, tmp_path)
    # Two greens for this workspace's project — the streak substrate.
    for _ in range(2):
        store.add_test(TestRun(workspace_id=ws.id, project_id=ws.project_id, runner="vitest",
                               scope="all", status="passed"))
    from haro.config import load_project_settings

    report = build_trust_report(store, ws, load_project_settings(str(tmp_path)))
    # Every ladder condition is present + the streak reflects the store's run history.
    keys = {c["key"] for c in report.to_dict()["conditions"]}
    assert keys == {"merge_result", "coverage", "full_scope", "no_flaky", "no_tamper",
                    "quality", "streak"}
    assert report.streak == 2


def test_run_gate_rebroadcasts_trust_on_status(tmp_path):
    store, hub = Store(), Hub()
    ws, project = _seed(store, tmp_path)
    q = hub.subscribe(ws.id)
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])

    asyncio.run(run_gate(store=store, hub=hub, adapter=_Adapter(result),
                         workspace=ws, project_path=project.path))

    envelopes = []
    while not q.empty():
        envelopes.append(q.get_nowait())
    trust_status = [e for e in envelopes if e.get("channel") == "status" and "trust" in e]
    assert trust_status, "run_gate did not piggyback a trust report on the status channel"
    # Rides the SAME envelope as the gate summary (one publish, not two).
    assert "gate" in trust_status[-1]
    report = trust_status[-1]["trust"]
    assert {"conditions", "streak", "met", "armed", "enabled"} <= report.keys()
    # Denormalized onto the workspace for the dashboard trust meter (same rule as
    # GateSummary) — a compact glance subset, no fetch-per-card.
    assert ws.trust is not None
    assert ws.trust.streak == report["streak"]
    assert ws.trust.streak_required == report["streak_required"]
    assert ws.trust.met == report["met"]


def test_get_trust_endpoint(tmp_path, monkeypatch):
    store = Store()
    ws, _ = _seed(store, tmp_path)
    monkeypatch.setattr(main_mod, "store", store)

    body = asyncio.run(main_mod.get_trust(ws.id))
    assert {c["key"] for c in body["conditions"]} == {
        "merge_result", "coverage", "full_scope", "no_flaky", "no_tamper", "quality", "streak"
    }

    with pytest.raises(HTTPException) as exc:
        asyncio.run(main_mod.get_trust("nope"))
    assert exc.value.status_code == 404


def test_get_trust_route_wired():
    r = next((r for r in main_mod.app.routes
              if getattr(r, "path", None) == "/workspaces/{ws_id}/trust"
              and "GET" in getattr(r, "methods", set())), None)
    assert r is not None and r.endpoint.__name__ == "get_trust"
