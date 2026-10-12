"""Snapshots written before the 2026-09-30 backend removals (race x N, the composer `fast`
toggle) must still boot.

An old DB carries a `races` table nothing reads any more, workspace rows with `race_id`,
agent-run rows with `fast`, and settings files with a `[race]` table. None of
that may crash hydrate, reconcile, the autosave, or config loading.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from haro import db
from haro.config import load_project_settings
from haro.models import AgentRun, Project, StartAgentRequest, Workspace
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


def _legacy_rows(tmp_path):
    project = Project(name="p", path=str(tmp_path), default_branch="main")
    live_dir = tmp_path / "wt-live"
    live_dir.mkdir()
    live = Workspace(
        project_id=project.id, name="live", branch="b", worktree_path=str(live_dir), base_ref="main"
    ).model_dump(mode="json")
    live["race_id"] = "race_old"
    gone = Workspace(
        project_id=project.id, name="loser", branch="b2",
        worktree_path=str(tmp_path / "wt-gone"), base_ref="main", status="archived",
    ).model_dump(mode="json")
    gone["race_id"] = "race_old"
    run = AgentRun(workspace_id=live["id"], adapter="claude-code", task="t").model_dump(mode="json")
    run["fast"] = True
    return project, live, gone, run


def test_a_pre_removal_snapshot_hydrates_and_the_orphan_races_table_is_left_alone(sqlite_db, tmp_path):
    project, live, gone, run = _legacy_rows(tmp_path)
    race = {"id": "race_old", "project_id": project.id, "status": "running", "lanes": [
        {"workspace_id": live["id"], "status": "running"}], "verdict": {"winner": "x"}}

    async def go():
        assert await db.init()
        con = db._conn
        await con.execute("CREATE TABLE IF NOT EXISTS races (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        rows = [
            ("projects", project.id, project.model_dump_json()),
            ("workspaces", live["id"], json.dumps(live)),
            ("workspaces", gone["id"], json.dumps(gone)),
            ("agent_runs", run["id"], json.dumps(run)),
            ("races", "race_old", json.dumps(race)),
        ]
        for table, rid, data in rows:
            await con.execute(f"INSERT INTO {table}(id, data) VALUES(?, ?)", (rid, data))
        await con.commit()

        store = Store()
        await db.load_into(store)
        notes = db.reconcile(store)
        await db.save_snapshot(store)
        cur = await con.execute("SELECT id FROM races")
        left = await cur.fetchall()
        return store, notes, left

    store, notes, left = _run(go())
    assert live["id"] in store.workspaces
    assert not hasattr(store.workspaces[live["id"]], "race_id")
    assert run["id"] in store.runs
    assert not hasattr(store.runs[run["id"]], "fast")
    assert "races" not in db._hydrated
    assert left == [("race_old",)]
    assert gone["id"] not in store.workspaces
    assert any("loser" in n for n in notes)
    assert not any("race" in n for n in notes)


def test_a_fresh_database_never_creates_the_races_table(sqlite_db):
    async def go():
        assert await db.init()
        cur = await db._conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        return {r[0] for r in await cur.fetchall()}

    assert "races" not in _run(go())


def test_removed_config_tables_are_ignored(tmp_path):
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir()
    (haro_dir / "settings.toml").write_text(
        '[race]\nenabled = true\nmax_lanes = 4\n[[race.lanes]]\nmodel = "opus"\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert not hasattr(ps, "race_enabled")


def test_an_old_client_still_sending_fast_or_race_fields_is_ignored():
    req = StartAgentRequest.model_validate({"task": "t", "fast": True, "plan": True})
    assert req.plan is True
    assert not hasattr(req, "fast")

