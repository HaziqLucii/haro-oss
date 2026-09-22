"""Test-inventory baseline: the tamper alarm's "which tests existed at base_ref"
reference (backlog/tamper-alarm.md §1). Mirrors the coverage-baseline caching:
compute the ``vitest list`` set once in a throwaway detached worktree, keyed by
``(project_id, base_ref)`` in ``store.test_inventory_baselines``.

These cover the caching + wiring orchestration (compute-once, cache-hit skips IO,
degrade to None). The actual ``vitest list`` / git-worktree IO is stubbed — the
matching/delta logic on the resulting inventories is unit-tested in test_tamper.py.
"""

import asyncio

from haro import analytics
from haro.adapters.test_runner.base import TestRef as Ref  # aliased: pytest tries to collect Test*
from haro.models import Project, Workspace
from haro.store import Store


def _store_proj_ws():
    store = Store()
    project = Project(id="p", name="proj", path="/tmp/proj", default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path="/tmp/wt", base_ref="main",
    )
    store.workspaces[ws.id] = ws
    return store, project, ws


def _stub_git(monkeypatch, calls):
    async def fake_add(*a, **k):
        calls.append("add")

    async def fake_remove(*a, **k):
        calls.append("remove")

    monkeypatch.setattr(analytics.git_ops, "add_detached_worktree", fake_add)
    monkeypatch.setattr(analytics.git_ops, "remove_worktree", fake_remove)
    monkeypatch.setattr(analytics, "ensure_deps", lambda *a, **k: None)


def test_baseline_inventory_computes_once_then_caches(monkeypatch):
    store, project, _ = _store_proj_ws()
    calls: list[str] = []
    _stub_git(monkeypatch, calls)

    listed = [Ref(file="a.test.ts", name="does x")]

    async def fake_list(self, cwd, *, changed_since=None):
        calls.append("list")
        return listed

    monkeypatch.setattr(analytics.VitestAdapter, "_list", fake_list)

    first = asyncio.run(analytics._baseline_inventory(store, project, "main"))
    assert first == listed
    assert store.test_inventory_baselines[("p", "main")] == listed
    # Second call is a cache hit: no worktree churn, no second `vitest list`.
    second = asyncio.run(analytics._baseline_inventory(store, project, "main"))
    assert second == listed
    assert calls.count("list") == 1
    assert calls.count("add") == 1


def test_baseline_inventory_caches_none_on_git_error(monkeypatch):
    store, project, _ = _store_proj_ws()

    async def boom(*a, **k):
        raise analytics.git_ops.GitError(["worktree", "add"], 128, "bad ref")

    async def fake_remove(*a, **k):
        pass

    monkeypatch.setattr(analytics.git_ops, "add_detached_worktree", boom)
    monkeypatch.setattr(analytics.git_ops, "remove_worktree", fake_remove)
    monkeypatch.setattr(analytics, "ensure_deps", lambda *a, **k: None)

    result = asyncio.run(analytics._baseline_inventory(store, project, "gone"))
    assert result is None
    # A cached None is a real answer (base_ref unlistable) — don't recompute it.
    assert ("p", "gone") in store.test_inventory_baselines


def test_test_inventories_returns_base_and_current(monkeypatch):
    store, project, ws = _store_proj_ws()
    base = [Ref(file="a.test.ts", name="keep"), Ref(file="a.test.ts", name="drop")]
    current = [Ref(file="a.test.ts", name="keep")]

    monkeypatch.setattr(analytics, "ensure_deps", lambda *a, **k: None)

    async def fake_list(self, cwd, *, changed_since=None):
        return current

    async def fake_baseline(store_, project_, base_ref):
        return base

    monkeypatch.setattr(analytics.VitestAdapter, "_list", fake_list)
    monkeypatch.setattr(analytics, "_baseline_inventory", fake_baseline)

    got_base, got_current = asyncio.run(
        analytics.test_inventories(store=store, workspace=ws, project=project)
    )
    assert got_base == base
    assert got_current == current
