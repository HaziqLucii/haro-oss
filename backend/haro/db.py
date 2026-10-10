"""Local SQLite persistence for haro (aiosqlite).

Snapshot-based, deliberately: the in-memory ``store`` stays the working set (fast,
and the many scattered ``workspace.status = …`` mutations need no write-through),
and we simply **hydrate it on boot** and **autosave snapshots** on a timer + on
shutdown. Each row stores a pydantic ``model_dump_json()`` in a ``data`` text column
keyed by id — so we never chase column migrations for the entity shapes.

Storage: a single SQLite file at ``$HARO_DB`` (default ``~/.haro/haro.db``). haro is
local-first and single-user, so an embedded file DB is the right fit — zero infra to
stand up, and a packaged build ships without a database *service*. If the
file can't be opened, persistence degrades gracefully to ephemeral (the app still
runs) — handy for a throwaway run.

(Migrated from Postgres/asyncpg: the schema is identical — ``(id, data)`` rows of
JSON — so the snapshot/hydrate logic is unchanged; only the driver + SQL dialect
differ. ``jsonb`` → ``TEXT``, ``$1``/``::jsonb`` → ``?``, ``<> ALL($1)`` → ``NOT IN``.)
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import os
import time
from pathlib import Path

import aiosqlite

from .models import (
    AgentRun,
    AgentRunStatus,
    Project,
    TestRun,
    Workspace,
    WorkspaceStatus,
    XpEvent,
)
from .store import DEFAULT_SESSION, Store

#: ``agent_events`` rows are one per (workspace, session). The store key is a tuple,
#: but a row ``id`` is a single TEXT column, so we join with a unit separator that
#: never appears in a workspace/session id. A legacy row written before sessions
#: existed has a bare workspace id (no separator) → the primary session on hydrate,
#: so old transcripts survive the upgrade untouched.
_EVENTS_ROW_SEP = "\x1f"


def _events_row_id(ws_id: str, session_id: str) -> str:
    return f"{ws_id}{_EVENTS_ROW_SEP}{session_id}"


def _split_events_row_id(row_id: str) -> tuple[str, str]:
    ws_id, sep, session_id = row_id.partition(_EVENTS_ROW_SEP)
    return (ws_id, session_id) if sep else (row_id, DEFAULT_SESSION)

_TABLES = ("projects", "workspaces", "agent_runs", "test_runs", "agent_events", "xp_events")
_lock = asyncio.Lock()  # serialize writes (autosave + explicit saves can overlap)
_conn: aiosqlite.Connection | None = None

#: Single-writer guard. Snapshot persistence assumes ONE writer: every
#: ``save_snapshot`` does a full-table sync that DELETEs rows not in *this*
#: process's store. Two overlapping backends (a stale one still draining, the
#: packaged app alongside run.sh, a double-launch) would then delete each other's
#: workspaces. We take an exclusive ``flock`` at boot; a process that can't get it
#: runs READ-ONLY (hydrates + serves, never writes) so it can never clobber.
#: ``flock`` is released automatically when the fd closes or the process dies, so
#: a crashed backend never leaves a stale lock.
_lock_fd: int | None = None
_readonly: bool = False

#: Tables that ``load_into`` actually ran a loader for this session. An empty
#: in-memory collection is only *authoritative* (safe to wipe the whole table)
#: if we know we tried to load it and it was genuinely empty. If a loader was
#: never wired up (the chat-wipe bug: an entity added to ``save_snapshot`` but
#: forgotten in ``load_into``), the store boots empty and the next autosave would
#: ``DELETE`` the real rows. Guarding on this set makes "forgot to load it"
#: non-destructive while still letting a legitimately-emptied table clear.
_hydrated: set[str] = set()

#: Cache of each session's last-serialized transcript blob (keyed by the composite
#: ``agent_events`` row id), so autosave only re-runs ``json.dumps`` for sessions
#: whose events changed (store._events_dirty) — not every transcript on every 4s tick.
_events_blob_cache: dict[str, str] = {}


def _should_wipe(table: str) -> bool:
    """Whether ``_sync`` may run a full-table ``DELETE`` for an empty collection.

    Only tables a loader ran for this session are authoritative when empty; a
    table we never hydrated is suspect (missing/broken loader), so we skip the
    wipe rather than risk erasing rows we simply failed to read back."""
    return table in _hydrated


def resolved_db_path() -> str:
    """The absolute, symlink-resolved DB path, without creating anything (for /health)."""
    return str(Path(os.environ.get("HARO_DB") or "~/.haro/haro.db").expanduser().resolve())


def _db_path() -> str:
    """The SQLite file path. ``$HARO_DB`` overrides; defaults to ``~/.haro/haro.db``
    (the same ``~/.haro`` dir that already holds the npm/deps caches). The parent
    dir is created so a first run on a clean machine doesn't fail to open."""
    p = Path(os.environ.get("HARO_DB") or "~/.haro/haro.db").expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    return str(p)


async def init(retries: int = 15, delay: float = 1.0) -> bool:
    """Open the SQLite file and create tables. Returns True if persistence is
    active; False → degrade to ephemeral.

    ``retries``/``delay`` are accepted for call-site compatibility but unused:
    opening a local file doesn't race a still-starting DB container the way the
    old Postgres pool did."""
    global _conn, _readonly
    try:
        _conn = await aiosqlite.connect(_db_path())
        # WAL: readers don't block the writer (the boot hydrate can overlap the
        # first autosave); busy_timeout: wait rather than raise on a brief lock.
        await _conn.execute("PRAGMA journal_mode=WAL")
        await _conn.execute("PRAGMA busy_timeout=5000")
        _readonly = not await _acquire_write_lock()
        if not _readonly:
            for t in _TABLES:
                await _conn.execute(
                    f"CREATE TABLE IF NOT EXISTS {t} (id TEXT PRIMARY KEY, data TEXT NOT NULL)"
                )
            await _conn.commit()
    except (OSError, aiosqlite.Error) as exc:
        _conn = None
        print(f"[db] SQLite unavailable ({exc}); running WITHOUT persistence")
        return False
    if _readonly:
        print(f"[db] another haro backend holds the write lock: running READ-ONLY, "
              f"no persistence ({_db_path()}). Close the other instance and restart to persist.")
    else:
        print(f"[db] SQLite persistence active ({_db_path()})")
    return True


async def _acquire_write_lock() -> bool:
    """Take the exclusive DB write lock. Waits briefly for a previous backend to
    finish draining (Ctrl+C → up to a few seconds of graceful shutdown), then
    gives up. Returns True if we're the sole writer, False → degrade to read-only.

    ``flock`` is advisory + per-open-file-description and is dropped by the kernel
    when the fd closes or the process dies, so it self-heals across crashes."""
    global _lock_fd
    _lock_fd = os.open(_db_path() + ".lock", os.O_CREAT | os.O_RDWR, 0o644)
    for _ in range(50):  # ~5s grace for a draining predecessor to release
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            await asyncio.sleep(0.1)
    return False


async def close() -> None:
    global _conn, _lock_fd, _readonly
    if _conn is not None:
        await _conn.close()
        _conn = None
    if _lock_fd is not None:
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_UN)
            os.close(_lock_fd)
        except OSError:
            pass
        _lock_fd = None
    _readonly = False


async def _sync(con: aiosqlite.Connection, table: str, rows: dict[str, str]) -> None:
    if rows:
        # A NUL byte truncates a TEXT value in SQLite (C-string). Agent transcripts
        # occasionally capture one from raw subprocess output; strip both the raw
        # byte and its JSON-escaped form so one poisoned event can't corrupt (or
        # silently truncate) the snapshot.
        rows = {k: v.replace("\x00", "").replace("\\u0000", "") for k, v in rows.items()}
        await con.executemany(
            f"INSERT INTO {table}(id, data) VALUES(?, ?) "
            f"ON CONFLICT(id) DO UPDATE SET data = excluded.data",
            list(rows.items()),
        )
        placeholders = ",".join("?" * len(rows))
        await con.execute(
            f"DELETE FROM {table} WHERE id NOT IN ({placeholders})", list(rows.keys())
        )
    elif _should_wipe(table):
        await con.execute(f"DELETE FROM {table}")
    # else: never loaded this session → an empty dict is suspect, not authoritative.
    #       Skip the wipe so a missing/broken loader can't erase the table.


async def _sync_events(con: aiosqlite.Connection, store: Store) -> None:
    """Incremental transcript sync — the one table that grows during an agent run.

    Re-serialize (``json.dumps``) ONLY sessions whose events changed since the
    last save (``store._events_dirty``), reuse cached blobs for the rest, and
    upsert just the changed rows. The old full snapshot re-dumped AND rewrote
    every transcript on every 4s tick — CPU that grew with the running agent's
    output. One row per ``(workspace, session)`` (composite id); removals still
    fall through the DELETE-not-in."""
    changed: dict[str, str] = {}
    current_ids: set[str] = set()
    for key in list(store.events):
        rid = _events_row_id(*key)
        current_ids.add(rid)
        if key in store._events_dirty or rid not in _events_blob_cache:
            blob = json.dumps(store.events[key]).replace("\x00", "").replace("\\u0000", "")
            _events_blob_cache[rid] = blob
            changed[rid] = blob
    store._events_dirty.clear()
    for rid in list(_events_blob_cache):  # forget removed sessions
        if rid not in current_ids:
            _events_blob_cache.pop(rid, None)
    if changed:
        await con.executemany(
            "INSERT INTO agent_events(id, data) VALUES(?, ?) "
            "ON CONFLICT(id) DO UPDATE SET data = excluded.data",
            list(changed.items()),
        )
    ids = list(current_ids)
    if ids:
        placeholders = ",".join("?" * len(ids))
        await con.execute(f"DELETE FROM agent_events WHERE id NOT IN ({placeholders})", ids)
    elif _should_wipe("agent_events"):
        await con.execute("DELETE FROM agent_events")


async def save_snapshot(store: Store) -> None:
    """Upsert the whole store; delete rows that no longer exist in memory."""
    if _conn is None or _readonly:
        # read-only: another backend owns the write lock, so we must NOT run the
        # destructive full-table sync — that's exactly what would clobber its data.
        return
    async with _lock:
        try:
            await _sync(_conn, "projects", {p.id: p.model_dump_json() for p in store.projects.values()})
            await _sync(_conn, "workspaces", {w.id: w.model_dump_json() for w in store.workspaces.values()})
            await _sync(_conn, "agent_runs", {r.id: r.model_dump_json() for r in store.runs.values()})
            await _sync(_conn, "test_runs", {t.id: t.model_dump_json() for t in store.tests.values()})
            await _sync(_conn, "xp_events", {e.id: e.model_dump_json() for e in store.xp_events.values()})
            # agent transcripts: incremental — re-serialize only changed workspaces
            await _sync_events(_conn, store)
            await _conn.commit()
        except Exception:
            # Roll back the partial snapshot so a mid-write failure can't leave the
            # tables inconsistent; the next autosave retries the whole store.
            await _conn.rollback()
            raise


async def _fetchall(sql: str) -> list[tuple]:
    assert _conn is not None
    try:
        async with _conn.execute(sql) as cur:
            return await cur.fetchall()
    except aiosqlite.OperationalError as exc:
        # A read-only boot skips CREATE TABLE, so a table added since the DB was
        # made doesn't exist yet: that is an empty table, not a failed boot.
        if _readonly and "no such table" in str(exc):
            return []
        raise


async def load_into(store: Store) -> None:
    """Hydrate the store from SQLite (best-effort; skips corrupt rows)."""
    if _conn is None:
        return
    for (raw,) in await _fetchall("SELECT data FROM projects"):
        try:
            p = Project.model_validate_json(raw)
            store.projects[p.id] = p
        except ValueError:
            pass
    _hydrated.add("projects")
    for (raw,) in await _fetchall("SELECT data FROM workspaces"):
        try:
            w = Workspace.model_validate_json(raw)
            store.workspaces[w.id] = w
        except ValueError:
            pass
    _hydrated.add("workspaces")
    for (raw,) in await _fetchall("SELECT data FROM agent_runs"):
        try:
            r2 = AgentRun.model_validate_json(raw)
            store.runs[r2.id] = r2
        except ValueError:
            pass
    _hydrated.add("agent_runs")
    for (raw,) in await _fetchall("SELECT data FROM test_runs"):
        try:
            t = TestRun.model_validate_json(raw)
            store.tests[t.id] = t
        except ValueError:
            pass
    _hydrated.add("test_runs")
    # The XP ledger. Same rule as every table here: saved but not hydrated would boot empty
    # and the next autosave would wipe the dev's whole XP history.
    for (raw,) in await _fetchall("SELECT data FROM xp_events"):
        try:
            xe = XpEvent.model_validate_json(raw)
            store.xp_events[xe.id] = xe
        except ValueError:
            pass
    _hydrated.add("xp_events")
    # Agent transcripts: one row per (workspace, session), a JSON array of events.
    # MUST be hydrated here — otherwise store.events boots empty and the very next
    # autosave's _sync runs DELETE FROM agent_events, erasing every transcript. A
    # legacy row id (bare workspace id, no separator) lands on the primary session.
    for rid, data in await _fetchall("SELECT id, data FROM agent_events"):
        try:
            evs = json.loads(data)
            if isinstance(evs, list):
                store.events[_split_events_row_id(rid)] = evs
        except (ValueError, TypeError):
            pass
    _hydrated.add("agent_events")
    _drop_vacuous_tamper(store)


_OLD_RED_FIRST_DEGRADE = "the red-first check is on but its engine failed for this run"


def _drop_vacuous_tamper(store: Store) -> None:
    """`vacuous` used to be a blocking tamper kind (2026-09-30 decision: never). Strip it from
    saved runs and, where the latest run of a red workspace stops being blocked because of it,
    settle the workspace the way the gate would, so old runs read right without a re-gate."""
    from . import gate  # lazy: gate imports the store, keep db free of the cycle

    changed = [t for t in store.tests.values() if gate.drop_vacuous_findings(t)]
    # The red-first engine failing used to degrade a run (so a green could not ship); it is
    # advisory now, so that one reason no longer counts on saved runs either.
    for t in store.tests.values():
        kept = [r for r in t.degraded_reasons if r != _OLD_RED_FIRST_DEGRADE]
        if len(kept) != len(t.degraded_reasons):
            t.degraded_reasons = kept
            if t not in changed:
                changed.append(t)
    if not changed:
        return
    touched = {t.workspace_id for t in changed}
    for wid in touched:
        ws = store.workspaces.get(wid)
        latest = store.latest_test(wid)
        if ws is None or latest is None:
            continue
        if latest.id in {t.id for t in changed}:
            if ws.gate is not None:
                ws.gate.tamper_count = len(latest.tamper_findings)
                ws.gate.tamper_note = latest.tamper_note
                ws.gate.degraded = bool(latest.degraded_reasons)
            if ws.status == WorkspaceStatus.gate_red and gate.run_is_green(latest):
                ws.status = WorkspaceStatus.gate_green
                if ws.gate is not None:
                    ws.gate.status = latest.status


def reconcile(store: Store) -> list[str]:
    """After load: drop dead projects/workspaces, reset transient statuses (their
    tasks/subprocesses died with the previous process), and rebuild the port set.
    Returns human-readable notes for the boot log."""
    from pathlib import Path

    notes: list[str] = []

    for pid, proj in list(store.projects.items()):
        if not Path(proj.path).exists():
            store.projects.pop(pid, None)
            notes.append(f"dropped project '{proj.name}': path gone ({proj.path})")

    transient = {
        WorkspaceStatus.setting_up,
        WorkspaceStatus.agent_running,
        WorkspaceStatus.tests_running,
    }
    store.allocated_ports.clear()
    for wid, ws in list(store.workspaces.items()):
        # A workspace is only real if its project exists AND its worktree directory
        # is present on disk. If the project is gone or the directory is entirely
        # missing, there's nothing to repair — drop it (files, if any, are left on
        # disk untouched; we only prune the store entry).
        dir_exists = Path(ws.worktree_path).exists()
        if ws.project_id not in store.projects or not dir_exists:
            store.workspaces.pop(wid, None)
            store.drop_transcript(wid)
            notes.append(f"dropped workspace '{ws.name}': project or worktree directory gone")
            continue
        # Husk: directory present but `.git` link gone (an interrupted removal).
        # We can't tell here whether the branch still has unmerged work — that needs
        # git, and reconcile is sync. Leave it in the store untouched; the async
        # `mark_broken` pass in main.py's lifespan decides broken (unmerged) vs.
        # drop (already merged in base_ref). Don't reset status or reclaim its port.
        if not (Path(ws.worktree_path) / ".git").exists():
            continue
        if ws.status in transient:
            notes.append(f"reset '{ws.name}' {ws.status.value} → idle (stale task)")
            ws.status = WorkspaceStatus.idle
        if ws.test_first is not None and ws.test_first.phase in ("drafting", "proving"):
            from .acceptance import interrupted

            interrupted(ws, "The backend restarted while the acceptance test was being drafted or proven.")
            notes.append(f"rejected '{ws.name}' test-first draft (backend restarted)")
        if ws.port is not None:
            store.allocated_ports.add(ws.port)

    # An agent run in flight when the process died has no task behind it any more, so
    # its `running`/`queued` row can never progress — it would sit "running" forever,
    # skewing store.latest_run and the run history. Settle it the same way the workspace
    # pass settles a stale `agent_running` status: the previous process's supervision is
    # simply gone. Guarded on there being no live task so this stays correct if it's ever
    # called anywhere but boot (where active_tasks is always empty).
    unsettled = 0
    for run in store.runs.values():
        if run.status not in (AgentRunStatus.running, AgentRunStatus.queued):
            continue
        if store.workspace_busy(run.workspace_id):
            continue
        run.status = AgentRunStatus.stopped
        run.ended_at = run.ended_at or time.time()
        unsettled += 1
    if unsettled:
        notes.append(f"settled {unsettled} interrupted agent run(s) → stopped")

    return notes


async def mark_broken(store: Store) -> list[str]:
    """Async companion to :func:`reconcile`: classify husk worktrees (directory
    present, ``.git`` gone) that reconcile deliberately left in place.

    Deciding requires git (``branch_merged``), which reconcile — being sync —
    can't call. For each husk:

    - branch already merged into ``base_ref`` → the work is safe; drop it.
    - branch has unmerged commits → mark ``broken`` and KEEP it, so the user sees
      a "needs repair" card instead of the workspace silently vanishing.

    Import git_ops lazily to avoid a module-level cycle (git_ops has no db dep,
    but keeping db import-light matters for the ephemeral/no-DB boot path)."""
    from pathlib import Path

    from . import git_ops

    notes: list[str] = []
    for wid, ws in list(store.workspaces.items()):
        if (Path(ws.worktree_path) / ".git").exists():
            continue  # valid worktree, not a husk
        proj = store.projects.get(ws.project_id)
        if proj is None:
            continue  # reconcile already drops project-less workspaces
        merged = await git_ops.branch_merged(proj.path, ws.branch, ws.base_ref)
        if merged:
            store.workspaces.pop(wid, None)
            store.drop_transcript(wid)
            notes.append(f"dropped workspace '{ws.name}': husk worktree, branch already merged")
        else:
            ws.status = WorkspaceStatus.broken
            notes.append(f"marked workspace '{ws.name}' broken: husk worktree with unmerged work")
    return notes
