"""Ticking a "code to check" row off (``POST /workspaces/{id}/checked``).

This endpoint is what makes the pane a worklist instead of a report, and the reason is
measurable: four of the eight row kinds (a new dependency, a touched secret file, a
deletion, a migration) ask for a human's confirmation and can never be closed by writing a
test. Across 125 real gate runs on this repo, of the 20 workspaces that ever raised a row
exactly one reached zero — which is the pane's own documented kill condition.

The handler is called directly rather than through a TestClient, matching how the rest of
this suite drives async endpoints.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import main as main_mod
from haro.models import CheckedRowRequest, GateSummary, TestRun, UncheckedRow, Workspace


@pytest.fixture
def ws(monkeypatch):
    """A workspace with one gate run carrying two rows, one of them already ticked."""
    store = main_mod.store
    w = Workspace(project_id="p", name="w", branch="feat", worktree_path="/tmp/x", base_ref="main")
    rows = [
        UncheckedRow(kind="untested_lines", file="src/a.ts", detail="3 never ran", count=3,
                     key="untested_lines|src/a.ts|3"),
        UncheckedRow(kind="new_dep", file="package.json", detail="dependency graph changed",
                     key="new_dep|package.json|dependency graph changed"),
    ]
    run = TestRun(workspace_id=w.id, project_id="p", runner="vitest", unchecked_items=rows)
    w.gate = GateSummary(status=run.status, unchecked_count=2)
    store.workspaces[w.id] = w
    store.tests[run.id] = run

    async def _noop(*_a, **_k):
        return None

    monkeypatch.setattr(main_mod.db, "save_snapshot", _noop)
    yield w, rows
    store.workspaces.pop(w.id, None)
    store.tests.pop(run.id, None)


def _post(ws_id: str, key: str, checked: bool = True):
    return asyncio.run(main_mod.set_row_checked(ws_id, CheckedRowRequest(key=key, checked=checked)))


def test_ticking_a_row_records_the_key(ws):
    w, rows = ws
    out = _post(w.id, rows[1].key)
    assert out["checked_rows"] == [rows[1].key]
    assert w.checked_rows == [rows[1].key]


def test_ticking_the_same_row_twice_does_not_duplicate_it(ws):
    w, rows = ws
    _post(w.id, rows[0].key)
    out = _post(w.id, rows[0].key)
    assert out["checked_rows"] == [rows[0].key]


def test_unticking_puts_the_row_back(ws):
    """A tick is reversible, because "I looked" is a judgement a person is allowed to
    revise — an irreversible dismiss is how a checklist loses trust."""
    w, rows = ws
    _post(w.id, rows[0].key)
    out = _post(w.id, rows[0].key, checked=False)
    assert out["checked_rows"] == []


def test_the_glance_badge_updates_immediately(ws):
    """The dashboard card reads ``gate.unchecked_count``, not the row list, so the tick has
    to reach it now rather than at the next gate."""
    w, rows = ws
    _post(w.id, rows[0].key)
    assert w.gate.unchecked_count == 1
    _post(w.id, rows[1].key)
    assert w.gate.unchecked_count == 0


def test_a_badge_that_never_measured_stays_none(ws, monkeypatch):
    """None means the pass did not run. Ticking a stale row must not turn that into a
    confident 0 — unmeasured is never clean, here as everywhere else."""
    w, rows = ws
    w.gate.unchecked_count = None
    _post(w.id, rows[0].key)
    assert w.gate.unchecked_count is None


def test_an_unknown_workspace_is_a_404(ws):
    with pytest.raises(main_mod.HTTPException) as exc:
        _post("ws_nope", "k")
    assert exc.value.status_code == 404


def test_an_empty_key_is_refused(ws):
    """A blank key would tick nothing while reporting success, which is worse than an error
    because the user believes the row is answered."""
    w, _ = ws
    with pytest.raises(main_mod.HTTPException) as exc:
        _post(w.id, "   ")
    assert exc.value.status_code == 400
