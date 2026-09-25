"""A check that could not run must never read as a clean green (backlog/double-gate.md §0).

This is the worst failure this product can have, and it is not hypothetical: for weeks the
coverage guard was on while `coverage()` returned `None` every time, and the tamper alarm was
on while its base inventory came back empty — and both produced an ordinary, confident green.
`[]` findings read as "test suite intact", which satisfied `trust.no_tamper` and would have
let a rung arm on a check that never happened.

So §0's rule: an ENABLED check that no-ops records a reason, a degraded run is not shippable,
and it cannot bank a streak. The escape hatch is deliberate and needs no new config key —
turn the check off, and it stops being a check you asked for.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import integrate, trust
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import Project, TestRun, Workspace, WorkspaceStatus
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


class _Green(TestRunnerAdapter):
    name = "vitest"

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return RunResult(ok=True, total=2, passed=2, failed=0, cases=[])


def _setup(tmp_path, workflow: str = ""):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main",
    )
    store.workspaces[ws.id] = ws
    haro = tmp_path / ".haro"
    haro.mkdir(exist_ok=True)
    haro.joinpath("settings.toml").write_text(workflow)
    return store, hub, ws, project


# --- the four enabled-but-no-op checks -------------------------------------- #

def test_coverage_guard_on_but_unmeasurable_degrades_the_run(tmp_path, monkeypatch):
    """THE bug that hid for weeks: guard on, no number, clean green."""
    store, hub, ws, project = _setup(tmp_path, "[workflow]\ncoverage_guard = 'warn'\ntamper_alarm = 'off'\ncode_to_check = 'off'\n")

    async def no_coverage(**_kw):
        return None  # what a broken coverage setup actually returns

    monkeypatch.setattr("haro.analytics.coverage_delta", no_coverage)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    assert run.status == RunStatus.passed          # the tests really did pass
    assert run.degraded_reasons                     # …but the run is not a clean green
    assert "coverage" in run.degraded_reasons[0]
    assert ws.gate.degraded is True                 # and the glance feed says so


def test_coverage_guard_in_block_mode_blocks_an_unmeasurable_run(tmp_path, monkeypatch):
    """`block` means it (backlog/gate.md). §0's `degraded` flag only reaches
    `ship_preflight`; the workspace *status* is what the dashboard, the regression ribbon
    and the merge firewall's verdict oracle read — so an unmeasured guard has to land on the
    verdict, not just on the ship button."""
    store, hub, ws, project = _setup(tmp_path, "[workflow]\ncoverage_guard = 'block'\ntamper_alarm = 'off'\ncode_to_check = 'off'\n")

    async def no_coverage(**_kw):
        return {"delta": None, "note": "install `@vitest/coverage-v8`"}

    monkeypatch.setattr("haro.analytics.coverage_delta", no_coverage)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    assert run.status == RunStatus.passed        # the tests passed…
    assert run.coverage_blocked is True          # …but the guard the project armed didn't run
    assert ws.status == WorkspaceStatus.gate_red
    assert "@vitest/coverage-v8" in run.coverage_note  # and it names the actual cause


def test_tamper_alarm_on_with_no_base_inventory_degrades(tmp_path, monkeypatch):
    """The fail-OPEN one: an empty inventory makes removed-test detection impossible, and
    `[]` findings otherwise read as "suite intact" straight into trust.no_tamper."""
    store, hub, ws, project = _setup(tmp_path, "[workflow]\ntamper_alarm = 'warn'\ncoverage_guard = 'off'\ncode_to_check = 'off'\n")

    async def no_inventory(**_kw):
        return None, None  # base, current

    async def fake_diff(*_a, **_k):
        return "", None

    monkeypatch.setattr("haro.analytics.test_inventories", no_inventory)
    monkeypatch.setattr("haro.git_ops.diff", fake_diff)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    assert run.tamper_findings == []                # still no findings…
    assert run.degraded_reasons                     # …but we no longer call that clean
    assert "inventory" in run.degraded_reasons[0]
    assert run.tamper_measured is False              # and no downstream consumer can call it clean either


def test_quality_gate_on_with_every_scanner_unavailable_degrades(tmp_path, monkeypatch):
    """The tamper alarm's fail-open twin, one scanner category over: every configured
    scanner unavailable still leaves `quality_findings == []` (the tri-state's own
    "measured clean" value) unless something else says nobody actually looked."""
    store, hub, ws, project = _setup(
        tmp_path,
        "[quality]\nenabled = true\n[workflow]\ntamper_alarm = 'off'\ncoverage_guard = 'off'\ncode_to_check = 'off'\n"
        "[gate]\nverified_hunks = false\n",
    )
    (tmp_path / "changed.py").write_text("x = 1\n")

    async def fake_changed_files(*_a, **_k):
        return [{"path": "changed.py"}]

    from haro.quality import QualityReport

    async def all_unavailable(**_kw):
        return QualityReport(
            degraded=["[quality] gitleaks could not run: not installed",
                      "[quality] semgrep could not run: not installed"],
        )

    monkeypatch.setattr("haro.git_ops.changed_files", fake_changed_files)
    monkeypatch.setattr("haro.quality.analyze", all_unavailable)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    assert run.quality_findings == []                # still no findings…
    assert run.degraded_reasons                       # …but we no longer call that clean
    assert "could not run" in run.degraded_reasons[0]
    assert run.quality_measured is False


def test_a_disabled_check_never_degrades(tmp_path):
    """The escape hatch, and the thing that stops this crying wolf: degradation is only
    ever about a check the project ASKED for."""
    store, hub, ws, project = _setup(
        tmp_path,
        "[workflow]\ncoverage_guard = 'off'\ntamper_alarm = 'off'\ncode_to_check = 'off'\n"
        "[gate]\nverified_hunks = false\n",
    )
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    assert run.degraded_reasons == []
    assert ws.gate.degraded is False
    assert ws.status == WorkspaceStatus.gate_green


def test_a_healthy_run_with_every_check_on_is_not_degraded(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, "[workflow]\ncoverage_guard = 'warn'\ntamper_alarm = 'warn'\n")

    async def cov(**_kw):
        return {"delta": {"lines": 1.0}}

    async def inv(**_kw):
        return [], []

    async def fake_diff(*_a, **_k):
        return "", None

    monkeypatch.setattr("haro.analytics.coverage_delta", cov)
    monkeypatch.setattr("haro.analytics.test_inventories", inv)
    monkeypatch.setattr("haro.git_ops.diff", fake_diff)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))

    assert store.latest_test(ws.id).degraded_reasons == []


# --- a degraded run is not shippable --------------------------------------- #

def test_ship_preflight_refuses_a_degraded_green(tmp_path, monkeypatch):
    """At the choke point, not in the UI — so the auto rungs clear the same bar and an
    unverified green cannot be auto-merged either."""
    from haro.models import GateSummary

    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(tmp_path), base_ref="main")
    ws.status = WorkspaceStatus.gate_green
    ws.gate = GateSummary(status=RunStatus.passed, degraded=True)
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")

    async def clean(*_a, **_k):
        return True

    monkeypatch.setattr("haro.git_ops.is_clean", clean)

    with pytest.raises(integrate.ShipRefused) as e:
        asyncio.run(integrate.ship_preflight(
            workspace=ws, project=project, merge_mode="both", busy=None, action="merge"))
    assert "degraded" in str(e.value).lower()
    assert "unverified" in str(e.value).lower()


def test_ship_preflight_allows_a_healthy_green(tmp_path, monkeypatch):
    from haro.models import GateSummary

    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(tmp_path), base_ref="main")
    ws.status = WorkspaceStatus.gate_green
    ws.gate = GateSummary(status=RunStatus.passed, degraded=False)
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")

    async def clean(*_a, **_k):
        return True

    async def not_merged(*_a, **_k):
        return False

    monkeypatch.setattr("haro.git_ops.is_clean", clean)
    monkeypatch.setattr("haro.git_ops.branch_merged", not_merged)
    asyncio.run(integrate.ship_preflight(
        workspace=ws, project=project, merge_mode="both", busy=None, action="merge"))


# --- a degraded run cannot bank trust -------------------------------------- #

def _run(**over) -> TestRun:
    r = TestRun(workspace_id="w", runner="vitest", scope="all")
    r.status = RunStatus.passed
    for k, v in over.items():
        setattr(r, k, v)
    return r


def test_a_degraded_run_is_not_a_clean_green():
    assert trust._is_clean_green(_run()) is True
    assert trust._is_clean_green(_run(degraded_reasons=["coverage could not be measured"])) is False


def test_the_streak_row_names_degradation_as_the_reason():
    """A 0/3 streak beside a green gate is a mystery unless the row says what reset it."""
    assert "degraded" in (trust._break_reason(_run(degraded_reasons=["x"])) or "")


def test_a_degraded_latest_run_drops_the_whole_report_to_unmet():
    """One edit, both effects: streak is required, so breaking it drops `met` without a
    separate condition to maintain."""
    from haro.config import ProjectSettings

    ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/tmp/x", base_ref="main")
    settings = ProjectSettings(trust_enabled=True, trust_streak_required=1)
    degraded = _run(degraded_reasons=["the coverage guard is on but coverage could not be measured"])

    report = trust.evaluate(ws, degraded, [degraded], settings)
    assert report.streak == 0
    assert report.met is False
    assert report.armed is False
