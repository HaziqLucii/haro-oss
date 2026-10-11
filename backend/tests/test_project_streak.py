"""Project-level trust streak substrate — ``Store.project_test_history``.

The trailing-consecutive-green streak (``backlog/autonomy-ladder.md``) is computed
*across all of a project's workspaces*, not one. These pin the store method that
gathers that history from ``store.tests`` (the persisted ``test_runs`` snapshot): it
(a) unions runs across the project's workspaces in chronological order, (b) keeps a
workspace's runs after it merges + archives — the trust substrate must not evaporate on
success — (c) isolates one project from another, (d) re-attributes legacy runs written
before ``TestRun.project_id`` existed via the live-workspace join, and (e) feeds
``trust.evaluate`` end-to-end so a red anywhere in the project resets the streak.
"""

from haro.models import TestRun, Workspace
from haro.store import Store
from haro.trust import evaluate

from test_trust import _settings  # reuse the all-prerequisites-on policy


def _ws(store: Store, ws_id: str, project_id: str) -> Workspace:
    ws = Workspace(
        id=ws_id, project_id=project_id, name=ws_id, branch=f"feat/{ws_id}",
        worktree_path=f"/tmp/{ws_id}", base_ref="main",
    )
    return store.add_workspace(ws)


def _run(store: Store, ws_id: str, project_id, at: float, **kw) -> TestRun:
    base = dict(workspace_id=ws_id, project_id=project_id, runner="vitest",
                scope="all", status="passed", started_at=at)
    base.update(kw)
    return store.add_test(TestRun(**base))


def test_gathers_across_workspaces_chronologically():
    store = Store()
    _ws(store, "a", "p")
    _ws(store, "b", "p")
    _run(store, "a", "p", at=1.0)
    _run(store, "b", "p", at=2.0)
    _run(store, "a", "p", at=3.0)
    hist = store.project_test_history("p")
    assert [t.started_at for t in hist] == [1.0, 2.0, 3.0]
    assert {t.workspace_id for t in hist} == {"a", "b"}


def test_isolated_per_project():
    store = Store()
    _ws(store, "a", "p")
    _ws(store, "x", "q")
    _run(store, "a", "p", at=1.0)
    _run(store, "x", "q", at=2.0)
    assert [t.workspace_id for t in store.project_test_history("p")] == ["a"]
    assert [t.workspace_id for t in store.project_test_history("q")] == ["x"]


def test_runs_survive_workspace_removal():
    # Merging a workspace archives + removes it (main.py), but its greens must keep
    # counting toward the project streak — the substrate can't evaporate on success.
    store = Store()
    _ws(store, "a", "p")
    _run(store, "a", "p", at=1.0)
    _run(store, "a", "p", at=2.0)
    store.remove_workspace("a")
    hist = store.project_test_history("p")
    assert len(hist) == 2  # attributable by TestRun.project_id, not a live-workspace join


def test_legacy_runs_reattributed_via_live_workspace():
    # Runs persisted before project_id existed hydrate with None; while their workspace
    # is still live they're re-attributed by the join, so an in-flight project keeps its
    # history across the upgrade.
    store = Store()
    _ws(store, "a", "p")
    _run(store, "a", None, at=1.0)      # legacy row: no project_id
    _run(store, "a", "p", at=2.0)       # post-upgrade row
    assert len(store.project_test_history("p")) == 2
    # After the workspace is gone the legacy None row can no longer be attributed
    # (expected loss); only the project_id-stamped row survives.
    store.remove_workspace("a")
    hist = store.project_test_history("p")
    assert [t.started_at for t in hist] == [2.0]


def test_streak_spans_workspaces_and_a_red_anywhere_resets():
    store = Store()
    _ws(store, "a", "p")
    _ws(store, "b", "p")
    _run(store, "a", "p", at=1.0)                     # green
    _run(store, "b", "p", at=2.0, status="failed")   # red in a *different* workspace
    _run(store, "a", "p", at=3.0)                     # green
    _run(store, "b", "p", at=4.0)                     # green
    latest = _run(store, "a", "p", at=5.0)            # green (the workspace under eval)
    report = evaluate(
        store.get_workspace("a"), latest,
        store.project_test_history("p"), _settings(trust_streak_required=3),
    )
    assert report.streak == 3  # only the three trailing greens after the cross-workspace red
