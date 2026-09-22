"""Live Gate — the advisory watch loop (backlog/live-gate.md).

The feature's whole safety argument is one sentence: **a watch run cannot ship anything.**
``gate.run_watch`` is a separate function from ``run_gate`` precisely so there is no code
path from the watch loop to the writes that make work mergeable — ``workspace.status``,
``workspace.gate``, ``store.tests`` (the regression ribbon + trust streak substrate), and
the ``notify`` gate beep. ``test_watch_run_writes_no_verdict_state`` is the tripwire for
that law: if a future refactor lets a watch run touch verdict state, it fails here rather
than quietly turning a continuous impacted-only green into something merge-worthy
(Goodhart-via-convenience — the hole backlog/autonomy-ladder.md and the tamper alarm exist
to close).

The rest covers the §2 wiring: one quiescence debounce, two policies forked on workspace
kind. Async paths run via ``asyncio.run`` (no pytest-asyncio in the gate env) — the
pattern the other watcher/gate tests use.
"""

from __future__ import annotations

import asyncio

import pytest

# Aliased: pytest would otherwise try to *collect* these Test*-named imports.
from haro import watcher
from haro.adapters.test_runner.base import CaseResult, TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.config import ProjectSettings, load_project_settings, write_project_gate
from haro.gate import run_watch
from haro.hub import Hub
from haro.models import Project, Workspace, WorkspaceStatus
from haro.models import TestRun as Run
from haro.models import TestRunStatus as RunStatus
from haro.store import Store, store
from haro.trust import _is_clean_green


def run(coro):
    return asyncio.run(coro)


class _Adapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, result: RunResult | None = None, boom: bool = False):
        self._result = result
        self._boom = boom
        self.calls: list[dict] = []

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        self.calls.append({"cwd": cwd, "changed_since": changed_since, "only": only})
        if self._boom:
            raise RuntimeError("runner exploded")
        if emit:
            await emit({"kind": "run_started"})
            await emit({"kind": "cell", "id": "a.test.ts::a", "status": "passed"})
        return self._result


def _watch_on(tmp_path) -> None:
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir(exist_ok=True)
    (haro_dir / "settings.toml").write_text("[gate]\nwatch = true\n")


def _setup(tmp_path):
    st, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    st.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="origin/main",
    )
    st.workspaces[ws.id] = ws
    return st, hub, ws, project


# --- THE LAW: a watch run writes no verdict state --------------------------- #

def test_watch_run_writes_no_verdict_state(tmp_path):
    """A *green* watch run leaves every merge-relevant write untouched.

    Green is the dangerous case: a red advisory run couldn't make anything mergeable by
    accident, but a green one could if it ever reached ``workspace.status``."""
    _watch_on(tmp_path)
    st, hub, ws, project = _setup(tmp_path)
    before_status = ws.status
    result = RunResult(
        ok=True, total=2, passed=2, failed=0,
        cases=[
            CaseResult(file="a.test.ts", name="a", status="passed"),
            CaseResult(file="a.test.ts", name="b", status="passed"),
        ],
    )

    got = run(run_watch(store=st, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))

    assert got is not None and got.status == RunStatus.passed
    # The law, clause by clause:
    assert ws.status == before_status            # never flips the workspace
    assert ws.gate is None                       # never denormalizes a GateSummary
    assert st.tests == {}                        # never enters the ribbon/streak substrate
    assert st.latest_test(ws.id) is None          # …so no preflight can ever read it
    # …and it IS available to the rail, in memory only.
    assert st.watch_runs[ws.id] is got
    assert got.trigger == "watch"
    assert got.scope == "impacted"


def test_watch_run_emits_no_gate_beep(tmp_path):
    """No ``notify`` envelope: a vital sign must not ring the ship bell."""
    _watch_on(tmp_path)
    st, hub, ws, project = _setup(tmp_path)
    q = hub.subscribe(ws.id)
    result = RunResult(ok=True, total=1, passed=1, cases=[])

    run(run_watch(store=st, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))

    envelopes = []
    while not q.empty():
        envelopes.append(q.get_nowait())
    assert not [e for e in envelopes if e.get("channel") == "notify"]
    # Everything it does emit rides the dedicated `watch` channel — never `test`, whose
    # cells drive the authoritative grid in GatePanel.
    assert {e.get("channel") for e in envelopes} == {"watch"}
    assert {e.get("kind") for e in envelopes} == {"run_started", "cell", "snapshot"}


def test_watch_run_is_always_impacted_only(tmp_path):
    """Fast by construction: the adapter is always called with ``changed_since=base_ref``,
    never a full-suite run — a whole suite on every save is how you make a loop hated."""
    _watch_on(tmp_path)
    st, hub, ws, project = _setup(tmp_path)
    adapter = _Adapter(RunResult(ok=True, total=1, passed=1, cases=[]))

    run(run_watch(store=st, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))

    assert adapter.calls == [{"cwd": str(tmp_path), "changed_since": "origin/main", "only": None}]


# --- refusals: the loop yields to anything authoritative ------------------- #

def test_watch_refuses_when_disabled(tmp_path):
    """``[gate] watch`` off (the default) ⇒ no run, even if something calls it."""
    st, hub, ws, project = _setup(tmp_path)
    adapter = _Adapter(RunResult(ok=True))
    assert run(run_watch(store=st, hub=hub, adapter=adapter, workspace=ws, project_path=project.path)) is None
    assert adapter.calls == []


def test_watch_refuses_when_busy(tmp_path, monkeypatch):
    """A setup/agent/gate in flight ⇒ never fight it for the worktree."""
    _watch_on(tmp_path)
    st, hub, ws, project = _setup(tmp_path)
    monkeypatch.setattr(st, "busy_reason", lambda ws_id: "the gate")
    adapter = _Adapter(RunResult(ok=True))
    assert run(run_watch(store=st, hub=hub, adapter=adapter, workspace=ws, project_path=project.path)) is None
    assert adapter.calls == []


def test_watch_crash_is_invisible(tmp_path):
    """A crashed runner degrades to no result — a broken advisory loop must never surface
    as a red, and must not leave a stale result behind."""
    _watch_on(tmp_path)
    st, hub, ws, project = _setup(tmp_path)
    st.watch_runs[ws.id] = Run(workspace_id=ws.id, runner="vitest")  # a stale previous run

    assert run(run_watch(store=st, hub=hub, adapter=_Adapter(boom=True), workspace=ws, project_path=project.path)) is None
    assert ws.status == WorkspaceStatus.idle
    assert ws.id not in st.watch_runs  # stale result dropped, not left to mislead


def test_watch_records_red_without_blocking_anything(tmp_path):
    """A red watch run is reported to the rail but changes no verdict — the ③ gate stays
    whatever it was, so merge eligibility rests purely on the last real gate."""
    _watch_on(tmp_path)
    st, hub, ws, project = _setup(tmp_path)
    ws.status = WorkspaceStatus.gate_green  # a real green gate happened earlier
    result = RunResult(
        ok=False, total=2, passed=1, failed=1,
        cases=[
            CaseResult(file="a.test.ts", name="a", status="passed"),
            CaseResult(file="a.test.ts", name="b", status="failed", message="boom"),
        ],
    )

    got = run(run_watch(store=st, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path))

    assert got.status == RunStatus.failed
    assert ws.status == WorkspaceStatus.gate_green  # the real verdict is untouched
    assert st.tests == {}


# --- store: single-flight + preemption ------------------------------------- #

def test_cancel_watch_is_idempotent_and_cancels():
    st = Store()
    st.cancel_watch("nope")  # no task → no error

    async def scenario():
        task = asyncio.create_task(asyncio.sleep(5))
        st.watch_tasks["ws1"] = task
        st.cancel_watch("ws1")
        await asyncio.sleep(0)
        return task.cancelled() or task.done(), "ws1" in st.watch_tasks

    cancelled, still_registered = run(scenario())
    assert cancelled
    assert not still_registered


def test_remove_workspace_drops_watch_state():
    st = Store()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/tmp/x", base_ref="main")
    st.workspaces[ws.id] = ws
    st.watch_runs[ws.id] = Run(workspace_id=ws.id, runner="vitest")
    st.remove_workspace(ws.id)
    assert ws.id not in st.watch_runs


# --- §2: one debounce, two policies --------------------------------------- #

def _ws_in_store(clean_store, tmp_path, kind: str):
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(proj)
    ws = store.add_workspace(Workspace(
        project_id=proj.id, name="w", branch="b", worktree_path=str(tmp_path),
        base_ref="origin/main", kind=kind,
    ))
    return proj, ws


@pytest.fixture
def clean_store():
    projects, workspaces = dict(store.projects), dict(store.workspaces)
    store.projects.clear()
    store.workspaces.clear()
    yield store
    store.projects.clear()
    store.projects.update(projects)
    store.workspaces.clear()
    store.workspaces.update(workspaces)


def test_quiet_secs_policy_matrix(clean_store, tmp_path):
    """One seam decides who gets a timer and how long: adopted ⇒ the long ship-verdict
    debounce, managed+watch ⇒ the short you-stopped-typing one, managed alone ⇒ none."""
    _proj, ws = _ws_in_store(clean_store, tmp_path, "managed")
    assert watcher._quiet_secs_for(ws.id) is None  # watch off by default

    _watch_on(tmp_path)
    assert watcher._quiet_secs_for(ws.id) == watcher._WATCH_DEBOUNCE_SECS

    ws.kind = "adopted"  # adopted keeps [trust] quiet_secs, not the watch debounce
    assert watcher._quiet_secs_for(ws.id) == load_project_settings(str(tmp_path)).trust_quiet_secs

    assert watcher._quiet_secs_for("vanished") is None


def test_watch_debounce_is_shorter_than_ship_debounce():
    """The two debounces answer different questions, so they must not be the same number:
    "you stopped typing" (~2s) is not "settled enough to make a ship verdict" (~30s)."""
    assert watcher._WATCH_DEBOUNCE_SECS < ProjectSettings().trust_quiet_secs


def test_quiescence_schedules_advisory_watch_for_managed(clean_store, tmp_path, monkeypatch):
    """Managed + ``[gate] watch`` ⇒ quiescence schedules ``run_watch``, NOT ``run_gate``."""
    _watch_on(tmp_path)
    _proj, ws = _ws_in_store(clean_store, tmp_path, "managed")

    watch_calls: list[dict] = []
    gate_calls: list[dict] = []

    async def fake_watch(**kw):
        watch_calls.append(kw)

    async def fake_gate(**kw):
        gate_calls.append(kw)

    monkeypatch.setattr(watcher, "run_watch", fake_watch)
    # The authoritative seam is ``rungs.gate_and_fire`` (run_gate + the autonomy-ladder
    # handoff): patching it proves the advisory path can't reach *either* half.
    monkeypatch.setattr(watcher.rungs, "gate_and_fire", fake_gate)

    async def scenario():
        await watcher._on_quiescence(_Hub(), ws.id)
        task = store.watch_tasks.get(ws.id)
        if task:
            await task
        return list(watch_calls), list(gate_calls)

    watched, gated = run(scenario())
    assert len(watched) == 1 and watched[0]["workspace"].id == ws.id
    assert gated == []  # nothing authoritative fired
    assert ws.id not in store.gate_tasks


def test_quiescence_supersedes_older_watch_run(clean_store, tmp_path, monkeypatch):
    """Single-flight: a newer save cancels the watch run the previous one started."""
    _watch_on(tmp_path)
    _proj, ws = _ws_in_store(clean_store, tmp_path, "managed")

    async def slow_watch(**kw):
        await asyncio.sleep(5)

    monkeypatch.setattr(watcher, "run_watch", slow_watch)

    async def scenario():
        await watcher._on_quiescence(_Hub(), ws.id)
        first = store.watch_tasks[ws.id]
        await watcher._on_quiescence(_Hub(), ws.id)  # a second save
        second = store.watch_tasks[ws.id]
        await asyncio.sleep(0)
        assert first is not second
        cancelled = first.cancelled()
        second.cancel()
        return cancelled

    assert run(scenario())


class _Hub:
    async def publish(self, workspace_id, envelope):
        return None

    async def broadcast_global(self, envelope):
        return None


# --- trust: a watch run can never climb the ladder ------------------------- #

def test_watch_trigger_never_counts_as_clean_green():
    """Two locks on the same door: the impacted ``scope`` already disqualifies a watch run,
    and the explicit trigger check keeps a hypothetical full-scope watch mode out too."""
    impacted = Run(workspace_id="w", runner="vitest", scope="impacted", status=RunStatus.passed, trigger="watch")
    assert not _is_clean_green(impacted)

    # The belt-and-braces case: same run, but pretend it was full scope.
    full = Run(workspace_id="w", runner="vitest", scope="all", status=RunStatus.passed, trigger="watch")
    assert not _is_clean_green(full)

    # Control: an ordinary full-scope manual green still counts.
    real = Run(workspace_id="w", runner="vitest", scope="all", status=RunStatus.passed, trigger="manual")
    assert _is_clean_green(real)


# --- config: parse + round-trip ------------------------------------------- #

def test_gate_watch_defaults_off():
    assert ProjectSettings().gate_watch is False


def test_gate_watch_parsed(tmp_path):
    _watch_on(tmp_path)
    assert load_project_settings(str(tmp_path)).gate_watch is True


def test_gate_watch_write_round_trip(tmp_path):
    """``write_project_gate`` persists the opt-in and omits the default, so an untouched
    project's settings.toml stays minimal (the convention every other gate key follows)."""
    kw = dict(
        runner="vitest", command="", gate_format="", gate_dir="", default_scope="all",
        merge_result=False, flaky_rerun=False, coverage_guard="off", coverage_tolerance=0.0,
    )
    path = write_project_gate(str(tmp_path), watch=True, **kw)
    assert "watch = true" in open(path).read()
    assert load_project_settings(str(tmp_path)).gate_watch is True

    write_project_gate(str(tmp_path), watch=False, **kw)
    assert "watch" not in open(path).read()
    assert load_project_settings(str(tmp_path)).gate_watch is False
