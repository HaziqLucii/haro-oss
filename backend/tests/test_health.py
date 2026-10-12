"""/health is how the desktop app decides whether a listening backend is its own: it must
name the database the backend writes to."""

from __future__ import annotations

import asyncio
from pathlib import Path

from haro import main as main_mod


def test_health_reports_the_resolved_db_path(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("HARO_DB", str(tmp_path / "x" / ".." / "haro.db"))
    body = asyncio.run(main_mod.health())
    assert body["ok"] is True
    assert isinstance(body["worktree_root"], str)
    assert body["db"] == str((tmp_path / "haro.db").resolve())


def test_health_default_db_is_under_home(monkeypatch, tmp_path: Path):
    monkeypatch.delenv("HARO_DB", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    body = asyncio.run(main_mod.health())
    assert body["db"] == str((tmp_path / ".haro" / "haro.db").resolve())
