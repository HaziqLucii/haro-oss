"""Watcher quiescence + adopted-worktree watch-set tests (backlog/merge-firewall.md §4).

Adopted worktrees are agentless, so runner.py's agent→gate handoff never fires for
them. The watcher instead (a) adds their (possibly out-of-tree) paths to the watch set,
and (b) debounces ``fs_changed`` into a per-workspace quiescence timer that marks a
settled worktree — the seam the auto-gate hangs off.

No httpx/pytest-asyncio in the gate env, so async paths are driven directly with
``asyncio.run`` against the module-level ``store`` singleton (the pattern the other
watcher/route tests use). The timer tests monkeypatch the module-global
``_quiet_secs_for``/``_on_quiescence`` seams so they run in milliseconds without touching
the real config loader.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import watcher
from haro.config import ProjectSettings, load_project_settings
from haro.models import Project, Workspace
from haro.store import store


def run(coro):
    return asyncio.run(coro)


class FakeHub:
    """Records envelopes instead of touching real WebSocket subscribers."""

    def __init__(self) -> None:
        self.published: list[tuple[str, dict]] = []
        self.broadcast: list[dict] = []

    async def publish(self, workspace_id, envelope):
        self.published.append((workspace_id, envelope))

    async def broadcast_global(self, envelope):
        self.broadcast.append(envelope)


@pytest.fixture
def clean_store():
    projects = dict(store.projects)
    workspaces = dict(store.workspaces)
    store.projects.clear()
    store.workspaces.clear()
    yield store
    store.projects.clear()
    store.projects.update(projects)
    store.workspaces.clear()
    store.workspaces.update(workspaces)


# --- watch set ------------------------------------------------------------- #

def test_desired_roots_adds_adopted_outside_tree(clean_store, tmp_path, monkeypatch):
    """An adopted worktree living OUTSIDE the repo tree (a claude-squad dir) is added as
    its own watch root; one living UNDER the project path is deduped away."""
    proj_dir = tmp_path / "repo"
    proj_dir.mkdir()
    # Point the worktree root somewhere empty so it doesn't add a stray root.
    monkeypatch.setattr(watcher.settings, "worktree_root", str(tmp_path / "wt"))

    proj = Project(name="demo", path=str(proj_dir), default_branch="main")
    store.add_project(proj)

    outside = tmp_path / "squad" / "foreign"
    outside.mkdir(parents=True)
    inside = proj_dir / "nested-wt"
    inside.mkdir()

    store.add_workspace(Workspace(
        project_id=proj.id, name="far", branch="b1",
        worktree_path=str(outside), base_ref="main", kind="adopted",
    ))
    store.add_workspace(Workspace(
        project_id=proj.id, name="near", branch="b2",
        worktree_path=str(inside), base_ref="main", kind="adopted",
    ))

    roots = watcher._desired_roots()
    assert str(outside) in roots  # out-of-tree adopted worktree watched directly
    assert str(inside) not in roots  # collapsed under the project path
    assert str(proj_dir) in roots


def test_desired_roots_skips_managed(clean_store, tmp_path, monkeypatch):
    """A managed worktree is NOT added as an extra root (it lives under worktree_root,
    which is watched wholesale)."""
    monkeypatch.setattr(watcher.settings, "worktree_root", str(tmp_path / "wt"))
    managed = tmp_path / "elsewhere"
    managed.mkdir()
    proj = Project(name="demo", path=str(tmp_path / "repo"), default_branch="main")
    (tmp_path / "repo").mkdir()
    store.add_project(proj)
    store.add_workspace(Workspace(
        project_id=proj.id, name="m", branch="b", worktree_path=str(managed),
        base_ref="main", kind="managed",
    ))
    assert str(managed) not in watcher._desired_roots()


# --- quiescence timer ------------------------------------------------------ #

def test_quiescence_fires_after_quiet(monkeypatch):
    fired: list[str] = []
    monkeypatch.setattr(watcher, "_quiet_secs_for", lambda ws_id: 0.02)

    async def fake_fire(hub, ws_id):
        fired.append(ws_id)

    monkeypatch.setattr(watcher, "_on_quiescence", fake_fire)

    async def scenario():
        q = watcher._Quiescence(FakeHub())
        q.arm("ws1")
        await asyncio.sleep(0.05)
        return list(fired)

    assert run(scenario()) == ["ws1"]


def test_quiescence_rearm_resets_and_fires_once(monkeypatch):
    fired: list[str] = []
    monkeypatch.setattr(watcher, "_quiet_secs_for", lambda ws_id: 0.05)

    async def fake_fire(hub, ws_id):
        fired.append(ws_id)

    monkeypatch.setattr(watcher, "_on_quiescence", fake_fire)

    async def scenario():
        q = watcher._Quiescence(FakeHub())
        q.arm("ws1")
        await asyncio.sleep(0.03)  # under quiet_secs → not yet
        assert fired == []
        q.arm("ws1")  # a fresh change resets the clock
        await asyncio.sleep(0.03)  # 0.06 total elapsed, but only 0.03 since re-arm
        assert fired == []
        await asyncio.sleep(0.04)  # now quiet long enough since the re-arm
        return list(fired)

    assert run(scenario()) == ["ws1"]  # exactly one fire despite two arms


def test_quiescence_non_adopted_never_fires(monkeypatch):
    """`_quiet_secs_for` returning None (managed / vanished) arms no live timer."""
    fired: list[str] = []
    monkeypatch.setattr(watcher, "_quiet_secs_for", lambda ws_id: None)

    async def fake_fire(hub, ws_id):
        fired.append(ws_id)

    monkeypatch.setattr(watcher, "_on_quiescence", fake_fire)

    async def scenario():
        q = watcher._Quiescence(FakeHub())
        q.arm("ws1")
        await asyncio.sleep(0.03)
        return list(fired)

    assert run(scenario()) == []


# --- _dispatch wiring ------------------------------------------------------ #

def test_dispatch_arms_every_dirty_workspace(clean_store, tmp_path):
    """``_dispatch`` arms a timer for every dirty workspace, adopted or managed.

    The *policy* decision (which kinds actually get a timer, and how long) lives in the
    single ``_quiet_secs_for`` seam — ``_fire_after`` re-reads it and drops the timer when
    it returns None. Keeping the fork in one place is what let the Live Gate
    (backlog/live-gate.md §2) reuse this debounce for managed worktrees without a second
    watcher; see ``test_live_gate.py`` for the policy matrix itself."""
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(proj)
    adopted_wt = tmp_path / "adopted"
    managed_wt = tmp_path / "managed"
    adopted_wt.mkdir()
    managed_wt.mkdir()
    ws_a = store.add_workspace(Workspace(
        project_id=proj.id, name="a", branch="ba", worktree_path=str(adopted_wt),
        base_ref="main", kind="adopted",
    ))
    ws_m = store.add_workspace(Workspace(
        project_id=proj.id, name="m", branch="bm", worktree_path=str(managed_wt),
        base_ref="main", kind="managed",
    ))

    armed: list[str] = []

    class RecordingQ:
        def arm(self, ws_id):
            armed.append(ws_id)

    from watchfiles import Change

    changes = {
        (Change.modified, str(adopted_wt / "f.py")),
        (Change.modified, str(managed_wt / "g.py")),
    }
    hub = FakeHub()
    run(watcher._dispatch(hub, changes, RecordingQ()))

    fs_ids = {wid for wid, env in hub.published if env["kind"] == "changed"}
    assert fs_ids == {ws_a.id, ws_m.id}
    assert set(armed) == {ws_a.id, ws_m.id}


# --- quiescence auto-gate (_on_quiescence) --------------------------------- #

def _adopted_ws(clean_store, tmp_path, **over):
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(proj)
    ws = store.add_workspace(Workspace(
        project_id=proj.id, name="a", branch="ba", worktree_path=str(tmp_path),
        base_ref="origin/main", kind="adopted", **over,
    ))
    return proj, ws


def _stub_run_gate(monkeypatch):
    """Replace the watcher's authoritative-gate seam with an awaitable recorder; return
    the calls list. That seam is ``rungs.gate_and_fire`` — ``run_gate`` plus the
    autonomy-ladder handoff (backlog/autonomy-ladder.md §3) — and it takes ``run_gate``'s
    kwargs, so these tests still assert on ``trigger``/``changed_since``."""
    calls: list[dict] = []

    async def fake_run_gate(**kw):
        calls.append(kw)

    monkeypatch.setattr(watcher.rungs, "gate_and_fire", fake_run_gate)
    return calls


def test_quiescence_auto_gates_when_idle(clean_store, tmp_path, monkeypatch):
    """A settled, idle adopted worktree schedules an auto-gate at the default scope."""
    _proj, ws = _adopted_ws(clean_store, tmp_path)
    calls = _stub_run_gate(monkeypatch)

    async def scenario():
        await watcher._on_quiescence(FakeHub(), ws.id)
        # run_gate is scheduled on its own task — let it run.
        task = store.gate_tasks.get(ws.id)
        if task:
            await task
        return list(calls)

    got = run(scenario())
    assert len(got) == 1
    assert got[0]["trigger"] == "auto"
    assert got[0]["workspace"].id == ws.id
    assert got[0]["changed_since"] is None  # default_scope="all" → full suite


def test_quiescence_impacted_scope_passes_base_ref(clean_store, tmp_path, monkeypatch):
    """`[gate] default_scope = "impacted"` runs impacted-only (changed_since=base_ref)."""
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir()
    (haro_dir / "settings.toml").write_text("[gate]\ndefault_scope = 'impacted'\n")
    _proj, ws = _adopted_ws(clean_store, tmp_path)
    calls = _stub_run_gate(monkeypatch)

    async def scenario():
        await watcher._on_quiescence(FakeHub(), ws.id)
        task = store.gate_tasks.get(ws.id)
        if task:
            await task
        return list(calls)

    got = run(scenario())
    assert got[0]["changed_since"] == "origin/main"


def test_quiescence_skips_when_busy(clean_store, tmp_path, monkeypatch):
    """busy_reason (setup/agent/gate active) → emit quiescent signal but no gate."""
    _proj, ws = _adopted_ws(clean_store, tmp_path)
    calls = _stub_run_gate(monkeypatch)
    monkeypatch.setattr(store, "busy_reason", lambda ws_id: "the gate")

    async def scenario():
        hub = FakeHub()
        await watcher._on_quiescence(hub, ws.id)
        return list(calls), hub.published

    got, published = run(scenario())
    assert got == []  # no gate scheduled while busy
    assert ws.id not in store.gate_tasks
    # the coarse quiescent signal still fires (the UI's file-tree refresh)
    assert any(env["kind"] == "quiescent" for _wid, env in published)


def test_quiescence_never_authoritatively_gates_managed(clean_store, tmp_path, monkeypatch):
    """A managed worktree never AUTHORITATIVELY auto-gates on quiescence — it gates on
    agent ``done``. With ``[gate] watch`` off (the default) quiescence does nothing at all;
    with it on it schedules the *advisory* ``run_watch`` and still never ``run_gate``
    (backlog/live-gate.md — asserted in ``test_live_gate.py``)."""
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(proj)
    ws = store.add_workspace(Workspace(
        project_id=proj.id, name="m", branch="bm", worktree_path=str(tmp_path),
        base_ref="main", kind="managed",
    ))
    calls = _stub_run_gate(monkeypatch)

    async def scenario():
        await watcher._on_quiescence(FakeHub(), ws.id)
        return list(calls)

    assert run(scenario()) == []
    assert ws.id not in store.gate_tasks
    assert ws.id not in store.watch_tasks  # watch off → not even an advisory run


# --- config parse ---------------------------------------------------------- #

def test_quiet_secs_default(tmp_path):
    assert ProjectSettings().trust_quiet_secs == 30


def test_quiet_secs_parsed_and_clamped(tmp_path):
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir()
    (haro_dir / "settings.toml").write_text("[trust]\nquiet_secs = 5\n")
    assert load_project_settings(str(tmp_path)).trust_quiet_secs == 5

    (haro_dir / "settings.toml").write_text("[trust]\nquiet_secs = 0\n")
    assert load_project_settings(str(tmp_path)).trust_quiet_secs == 1  # clamped ≥ 1

    (haro_dir / "settings.toml").write_text("[trust]\nquiet_secs = 'junk'\n")
    assert load_project_settings(str(tmp_path)).trust_quiet_secs == 30  # junk → default
