"""The refuter's wiring into `gate.run_gate` (Phase 3 of notes/workflow-roles-plan.md).

Same entry rule as plan compliance: full scope, tests passed, quality not blocked —
and the same `[]`-vs-`None` discipline: `TestRun.review` stays `None` (not measured)
whenever roles/review are off, so a consumer can't mistake "never asked" for "clean".
Driving harness mirrors test_degraded_gate.py (`_Green` adapter + a real `run_gate`
call against `.haro/settings.toml`); the ship-refusal half mirrors
test_quality_gate.py's `_green_ws`/`_preflight` pair.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import integrate
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import AgentRun, GateSummary, Project, Workspace, WorkspaceStatus
from haro.models import TestRunStatus as RunStatus
from haro.models import ReviewMustFix, ReviewVerdict
from haro.store import Store


class _Green(TestRunnerAdapter):
    name = "vitest"

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return RunResult(ok=True, total=2, passed=2, failed=0, cases=[])


def _setup(tmp_path, roles_toml: str = ""):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(project_id=project.id, name="w", branch="feat",
                   worktree_path=str(tmp_path), base_ref="main")
    store.workspaces[ws.id] = ws
    store.add_run(AgentRun(workspace_id=ws.id, adapter="claude-code", task="add retry logic"))
    haro = tmp_path / ".haro"
    haro.mkdir(exist_ok=True)
    haro.joinpath("settings.toml").write_text(roles_toml)
    return store, hub, ws, project


def _stub_refuter(monkeypatch, verdict: ReviewVerdict):
    async def fake(**_kw):
        return verdict

    monkeypatch.setattr("haro.review.run_refuter", fake)


def _pass_verdict(**kw) -> ReviewVerdict:
    base = dict(ran_at=0, model="sonnet", verdict="pass", summary="looks right")
    base.update(kw)
    return ReviewVerdict(**base)


def _fail_verdict(**kw) -> ReviewVerdict:
    base = dict(
        ran_at=0, model="sonnet", verdict="fail", summary="off-by-one",
        must_fix=[ReviewMustFix(file="a.py", line=3, title="off-by-one", cited="+ x")],
    )
    base.update(kw)
    return ReviewVerdict(**base)


def _run_gate(store, hub, ws, project, *, only=None, changed_since=None):
    return asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path,
        only=only, changed_since=changed_since,
    ))


# --- roles/review off ⇒ untouched -------------------------------------------- #

def test_roles_off_never_measures_review(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, "")
    _stub_refuter(monkeypatch, _fail_verdict())  # would fail if it ran
    _run_gate(store, hub, ws, project)
    run = store.latest_test(ws.id)
    assert run.review is None
    assert run.review_blocked is False
    assert ws.status == WorkspaceStatus.gate_green


def test_roles_on_but_review_enforce_off_never_measures_review(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path, "[roles]\nenabled = true\nreview = \"opus:high\"\n"
    )
    _stub_refuter(monkeypatch, _fail_verdict())
    _run_gate(store, hub, ws, project)
    run = store.latest_test(ws.id)
    assert run.review is None


def test_roles_on_but_no_review_role_configured_never_measures_review(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path, "[roles]\nenabled = true\nreview_enforce = \"warn\"\n"
    )
    _stub_refuter(monkeypatch, _fail_verdict())
    _run_gate(store, hub, ws, project)
    run = store.latest_test(ws.id)
    assert run.review is None


# --- warn policy --------------------------------------------------------------- #

def test_warn_mode_records_a_fail_verdict_but_stays_green(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path,
        "[roles]\nenabled = true\nreview = \"opus:high\"\nreview_enforce = \"warn\"\n",
    )
    _stub_refuter(monkeypatch, _fail_verdict())
    _run_gate(store, hub, ws, project)
    run = store.latest_test(ws.id)
    assert run.review is not None and run.review.verdict == "fail"
    assert run.review_blocked is False
    assert ws.status == WorkspaceStatus.gate_green


# --- degraded, never red for an error ---------------------------------------- #

def test_a_refuter_error_degrades_the_run_rather_than_reddening_it(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path,
        "[roles]\nenabled = true\nreview = \"opus:high\"\nreview_enforce = \"warn\"\n",
    )
    _stub_refuter(monkeypatch, ReviewVerdict(ran_at=0, model="sonnet", error="the claude CLI was not found"))
    _run_gate(store, hub, ws, project)
    run = store.latest_test(ws.id)
    assert run.status == RunStatus.passed  # the tests really did pass
    assert run.review_blocked is False     # an error must never silently block either
    assert ws.status == WorkspaceStatus.gate_green
    assert any("refuter" in r for r in run.degraded_reasons)
    assert ws.gate.degraded is True


def test_a_crashing_refuter_call_degrades_rather_than_sinking_the_green(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path,
        "[roles]\nenabled = true\nreview = \"opus:high\"\nreview_enforce = \"warn\"\n",
    )

    async def boom(**_kw):
        raise RuntimeError("kaboom")

    monkeypatch.setattr("haro.review.run_refuter", boom)
    _run_gate(store, hub, ws, project)
    run = store.latest_test(ws.id)
    assert run.status == RunStatus.passed
    assert any("refuter" in r for r in run.degraded_reasons)


# --- impacted / re-run-failed scope never runs it ---------------------------- #
# Two DIFFERENT narrow scopes, both must refuse the refuter: `only` (a re-run of
# just the previously-failing tests) and `changed_since` (the impacted-only fast
# gate) are independent knobs on `run_gate` — a bug caught by an independent
# refuter pass found the entry condition only checked the first, so a project on
# `[gate] default_scope = "impacted"` paid a refuter call on every fast gate.

def test_a_reran_failed_scope_never_runs_the_refuter(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path,
        "[roles]\nenabled = true\nreview = \"opus:high\"\nreview_enforce = \"warn\"\n",
    )
    called = False

    async def fake(**_kw):
        nonlocal called
        called = True
        return _fail_verdict()

    monkeypatch.setattr("haro.review.run_refuter", fake)
    _run_gate(store, hub, ws, project, only=[("a.test.ts", "x")])
    assert called is False


def test_an_impacted_only_fast_gate_never_runs_the_refuter(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path,
        "[roles]\nenabled = true\nreview = \"opus:high\"\nreview_enforce = \"warn\"\n",
    )
    called = False

    async def fake(**_kw):
        nonlocal called
        called = True
        return _fail_verdict()

    monkeypatch.setattr("haro.review.run_refuter", fake)
    test = _run_gate(store, hub, ws, project, changed_since="main")
    assert test.scope == "impacted"  # confirms this actually exercised the scope this test is named for
    assert called is False
    assert test.review is None


# --- ship_preflight ----------------------------------------------------------- #

def _green_ws(tmp_path, **gate_kw):
    ws = Workspace(project_id="p", name="w", branch="feat",
                   worktree_path=str(tmp_path), base_ref="main")
    ws.status = WorkspaceStatus.gate_green
    ws.gate = GateSummary(status=RunStatus.passed, **gate_kw)
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    return ws, project


def _preflight(ws, project, monkeypatch):
    async def clean(*_a, **_k):
        return True

    monkeypatch.setattr("haro.git_ops.is_clean", clean)
    return asyncio.run(integrate.ship_preflight(
        workspace=ws, project=project, merge_mode="both", busy=None, action="merge"))


def test_ship_refuses_a_review_blocked_workspace(tmp_path, monkeypatch):
    ws, project = _green_ws(tmp_path, review_verdict="fail", review_must_fix=2, review_blocking=True)
    with pytest.raises(integrate.ShipRefused) as e:
        _preflight(ws, project, monkeypatch)
    assert "refuter" in str(e.value).lower()
    assert "2" in str(e.value)


def test_ship_is_unaffected_by_a_warn_mode_fail_verdict(tmp_path, monkeypatch):
    # An LLM verdict never blocks a merge on its own (2026-09-17): review_enforce has
    # no "block" value left, so gate.py can never construct review_blocking=True. This
    # pins ship_preflight's own behavior directly (a warn-mode fail must not refuse ship)
    # independent of whether gate.py can still produce that shape.
    ws, project = _green_ws(tmp_path, review_verdict="fail", review_must_fix=2, review_blocking=False)
    _preflight(ws, project, monkeypatch)  # must not raise


def test_a_project_without_roles_is_unaffected(tmp_path, monkeypatch):
    ws, project = _green_ws(tmp_path)  # review_verdict None, review_blocking False
    _preflight(ws, project, monkeypatch)
