"""A read-only boot (another backend holds the write lock) skips CREATE TABLE, so a
table added since the DB file was made must hydrate as empty instead of failing boot."""

from __future__ import annotations

import asyncio

import aiosqlite
import pytest

from haro import db


def test_missing_table_reads_empty_when_readonly(tmp_path, monkeypatch):
    async def go():
        conn = await aiosqlite.connect(tmp_path / "old.db")
        monkeypatch.setattr(db, "_conn", conn)
        monkeypatch.setattr(db, "_readonly", True)
        try:
            assert await db._fetchall("SELECT data FROM table_added_later") == []
        finally:
            await conn.close()

    asyncio.run(go())


def test_missing_table_still_raises_when_writable(tmp_path, monkeypatch):
    async def go():
        conn = await aiosqlite.connect(tmp_path / "old.db")
        monkeypatch.setattr(db, "_conn", conn)
        monkeypatch.setattr(db, "_readonly", False)
        try:
            with pytest.raises(aiosqlite.OperationalError):
                await db._fetchall("SELECT data FROM table_added_later")
        finally:
            await conn.close()

    asyncio.run(go())
