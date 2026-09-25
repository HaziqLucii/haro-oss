"""Analytics must run the runner where the GATE runs it: `[gate] dir`.

The regression these pin was live and quiet. Every analytics read invoked the runner at
the worktree/checkout ROOT, which is wrong the moment a project sets `[gate] dir` — and
haro itself sets `"frontend"`. Two different failures came out of the one mistake:

  * `coverage()` could not run (no package.json / no node_modules at the root), so
    "Coverage holds vs base" was **unsatisfiable on any gate-dir project**, and the note
    blamed a red suite while the gate was showing 245 passed.
  * `_list()` appeared to work, which is worse: with nothing installed at the root, `npx`
    downloaded a vitest and ran it CONFIG-LESS. The tamper alarm's "which tests existed at
    base" reference was therefore built by a different runner than the gate uses.

So these assert the *cwd* the adapter is handed, not the result — the cwd IS the bug.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import analytics
from haro.models import Project, Workspace
from haro.store import Store


def _project(tmp_path, gate_dir: str | None) -> Project:
    haro = tmp_path / ".haro"
    haro.mkdir(exist_ok=True)
    haro.joinpath("settings.toml").write_text(
        f"[gate]\ndir = '{gate_dir}'\n" if gate_dir else "[gate]\n"
    )
    return Project(id="p", name="proj", path=str(tmp_path), default_branch="main")


def _workspace(project: Project, wt) -> Workspace:
    return Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(wt), base_ref="origin/main",
    )


class _SpyAdapter:
    """Records the cwd it was invoked with; returns nothing useful on purpose."""

    def __init__(self):
        self.coverage_cwds: list[str] = []
        self.list_cwds: list[str] = []
        self.run_cwds: list[str] = []

    async def coverage(self, *, cwd):
        self.coverage_cwds.append(cwd)
        return None

    async def _list(self, cwd, **_kw):
        self.list_cwds.append(cwd)
        return None

    async def run(self, *, cwd, **_kw):
        self.run_cwds.append(cwd)

        class _R:
            cases: list = []

        return _R()


@pytest.fixture
def spy(monkeypatch):
    s = _SpyAdapter()
    monkeypatch.setattr(analytics, "VitestAdapter", lambda: s)
    # ensure_deps touches the filesystem; record its args instead.
    dep_calls: list[tuple[str, str]] = []
    monkeypatch.setattr(analytics, "ensure_deps", lambda a, b: dep_calls.append((a, b)))
    s.dep_calls = dep_calls  # type: ignore[attr-defined]
    return s


# --- the resolver itself ---------------------------------------------------- #

def test_resolve_appends_the_gate_dir_to_both_paths(tmp_path):
    p = _project(tmp_path, "frontend")
    cwd, dep_root = analytics._resolve(p, "/some/worktree")
    assert cwd == "/some/worktree/frontend"
    assert dep_root == str(tmp_path / "frontend")


def test_resolve_is_a_no_op_without_a_gate_dir(tmp_path):
    p = _project(tmp_path, None)
    assert analytics._resolve(p, "/some/worktree") == ("/some/worktree", str(tmp_path))


# --- coverage: the condition that was unsatisfiable ------------------------- #

def test_current_coverage_runs_in_the_gate_dir(tmp_path, spy):
    """The exact bug behind "Coverage holds vs base" never being satisfiable on haro."""
    project = _project(tmp_path, "frontend")
    wt = tmp_path / "wt"
    ws = _workspace(project, wt)
    store = Store()
    store.workspaces[ws.id] = ws

    asyncio.run(analytics.coverage_delta(store=store, workspace=ws, project=project))

    assert spy.coverage_cwds[0] == str(wt / "frontend")
    # ensure_deps must point at the deps too, or it silently no-ops on a gate-dir project.
    assert spy.dep_calls[0] == (str(wt / "frontend"), str(tmp_path / "frontend"))


def test_baseline_coverage_runs_in_the_gate_dir(tmp_path, spy, monkeypatch):
    project = _project(tmp_path, "frontend")
    made: dict = {}

    async def fake_add(_proj, wt, ref):
        made["wt"] = wt

    async def fake_remove(_proj, _wt):
        return None

    monkeypatch.setattr(analytics.git_ops, "add_detached_worktree", fake_add)
    monkeypatch.setattr(analytics.git_ops, "remove_worktree", fake_remove)

    asyncio.run(analytics._baseline_coverage(Store(), project, "origin/main"))

    assert spy.coverage_cwds == [str(analytics.Path(made["wt"]) / "frontend")]


# --- inventory: the one that silently used a config-less runner ------------- #

def test_inventories_list_in_the_gate_dir(tmp_path, spy):
    """`_list` at the root only 'worked' because npx fetched a config-less vitest, so the
    tamper alarm's base reference came from a different runner than the gate's."""
    project = _project(tmp_path, "frontend")
    wt = tmp_path / "wt"
    ws = _workspace(project, wt)
    store = Store()
    store.workspaces[ws.id] = ws

    asyncio.run(analytics.test_inventories(store=store, workspace=ws, project=project))

    assert str(wt / "frontend") in spy.list_cwds
    assert str(wt) not in spy.list_cwds


def test_flaky_detector_runs_in_the_gate_dir(tmp_path, spy):
    project = _project(tmp_path, "frontend")
    wt = tmp_path / "wt"
    asyncio.run(analytics.detect_flaky(workspace=_workspace(project, wt), project=project, runs=2))
    assert spy.run_cwds == [str(wt / "frontend")] * 2


# --- the note must stop guessing the cause --------------------------------- #

def _run(status: str):
    from haro.models import TestRun, TestRunStatus

    r = TestRun(workspace_id="w", runner="vitest")
    r.status = TestRunStatus(status)
    return r


def test_a_green_suite_with_no_coverage_names_the_missing_provider(tmp_path, spy):
    """THE misleading message. The gate was green (245 passed) and the UI still said "the
    suite must be green" — sending a dev after a red suite that did not exist."""
    project = _project(tmp_path, "frontend")
    ws = _workspace(project, tmp_path / "wt")
    store = Store()
    store.workspaces[ws.id] = ws
    green = _run("passed")
    green.workspace_id = ws.id
    store.add_test(green)

    out = asyncio.run(analytics.coverage_delta(store=store, workspace=ws, project=project))
    note = out["note"]
    assert "coverage-v8" in note  # says what to actually install
    assert "must be green" not in note  # and stops blaming a green suite


def test_a_red_suite_still_says_the_suite_must_be_green(tmp_path, spy):
    project = _project(tmp_path, "frontend")
    ws = _workspace(project, tmp_path / "wt")
    store = Store()
    store.workspaces[ws.id] = ws
    red = _run("failed")
    red.workspace_id = ws.id
    store.add_test(red)

    note = asyncio.run(analytics.coverage_delta(store=store, workspace=ws, project=project))["note"]
    assert "must be green" in note


def test_no_gate_run_yet_says_so(tmp_path, spy):
    project = _project(tmp_path, "frontend")
    ws = _workspace(project, tmp_path / "wt")
    store = Store()
    store.workspaces[ws.id] = ws

    note = asyncio.run(analytics.coverage_delta(store=store, workspace=ws, project=project))["note"]
    assert "no gate run yet" in note
