"""Event-driven filesystem watch → live "refresh" signals over the hub.

Best-practice "always updated" for LOCAL changes: rather than the frontend polling
on a timer, sit directly on the OS-native file-change API (inotify on Linux,
FSEvents on macOS) via ``watchfiles`` and push a coarse signal the instant a
working-tree file changes. Idle cost is zero — the kernel only wakes us on a real
change — which is precisely why this beats polling.

Two coarse signals (the client re-fetches the small REST payload on receipt; we
deliberately never diff or stream file *contents* over the socket):

  fs_changed(workspace_id)    a file changed inside a workspace's worktree → the
                              code-step file tree + git-status marks are stale.
                              One seam covers agent edits, ``git pull``/merge,
                              terminal edits and setup scripts.
  backlog_changed(project_id) a ``*todo*`` doc changed in a project root → the
                              backlog rail is stale. Covers a ``git pull`` that
                              updates committed ``todo-*.md`` files with no
                              workspace-status change (the case the frontend's
                              statusKey refetch misses — the user's reported bug).

We watch the *worktree root* plus each *registered project path* plus each *adopted
worktree path* (NOT the browse root, which defaults to ``$HOME`` and would exhaust
inotify watches if walked). Managed worktrees live under the worktree root and every
in-repo worktree lives under its project path, so both are already covered; an
**adopted** (foreign) worktree can live anywhere (a ``claude-squad`` dir outside the
repo tree, an arbitrary path), so its ``worktree_path`` is added explicitly — else the
Merge Firewall's quiescence auto-gate (§4) would never see its files change.
``watchfiles.DefaultFilter`` drops ``.git``/``node_modules``/``.venv``/…, so a pull's
working-tree writes fire but internal git churn and dependency noise don't. The watch
set is rebuilt when the set of watched repos changes (a newly registered project OR a
newly adopted worktree), so it starts being watched without a manual restart.
``watchfiles`` batches event bursts (a save/pull is many inotify events), so one storm
collapses to at most one signal per affected entity.

Quiescence (backlog/merge-firewall.md §4): an adopted worktree is agentless, so
runner.py's agent→gate handoff never fires for it. Instead, a *second* debounce layered
on top of ``fs_changed`` — a per-workspace timer (re)armed on every change and firing
after ``[trust] quiet_secs`` seconds of silence — marks the worktree "settled", then
auto-gates it (skip if ``store.busy_reason`` shows setup/agent/gate already running, else
``gate.run_gate`` at the project's ``[gate] default_scope``). Only adopted workspaces are
armed; managed ones already gate on agent ``done``. A manual ``POST /workspaces/{id}/tests``
gate works regardless — it doesn't depend on this trigger.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from watchfiles import DefaultFilter, awatch

from . import backlog as backlog_svc
from . import rungs
from .config import load_project_settings, settings
from .gate import run_watch
from .hub import Hub
from .store import store

# Basename substring + doc extensions that mark a human backlog doc. Mirrors
# ``main._discover_todo_files`` deliberately — a source file like ``todos.py``
# must NOT count as a backlog doc.
_TODO_DOC_EXT = {".md", ".markdown", ".txt", ".rst", ""}


def _under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


# The default backlog folder (`[backlog] dir`). Recognized here by name so a change
# to `backlog/gate.md` fires `backlog_changed` even though its filename has no
# "todo" — cheap because it needs no per-project settings load, so it stays the
# fast path for every fs event. A project with a custom `backlog_dir` or extra
# `[backlog] files` globs falls through to the slower, settings-aware check below,
# which only runs for paths that already have a doc-like extension (a hot rebuild
# full of source-file churn never reaches it).
_BACKLOG_DIR = "backlog"


def _is_todo_doc(path: Path) -> bool:
    if path.suffix.lower() not in _TODO_DOC_EXT:
        return False
    return "todo" in path.name.lower() or _BACKLOG_DIR in path.parts


def _desired_roots() -> list[str]:
    """Existing, non-overlapping paths to watch: the worktree root + each project
    repo + each adopted worktree. Deduped so an ancestor/descendant pair isn't watched
    twice (which would double-fire every event) — most adopted worktrees fall under a
    project path and collapse away here; only ones living outside the repo tree (e.g. a
    ``claude-squad`` dir) survive as extra roots. Sorted for cheap set-equality against
    the live set."""
    candidates: list[Path] = []
    wt = Path(settings.worktree_root).expanduser()
    if wt.is_dir():
        candidates.append(wt)
    for proj in list(store.projects.values()):
        p = Path(proj.path).expanduser()
        if p.is_dir():
            candidates.append(p)
    for ws in list(store.workspaces.values()):
        if ws.kind != "adopted":
            continue
        p = Path(ws.worktree_path).expanduser()
        if p.is_dir():
            candidates.append(p)
    roots: list[Path] = []
    for p in sorted(set(candidates), key=lambda x: len(str(x))):
        if any(_under(p, r) for r in roots):  # already covered by a shorter ancestor
            continue
        roots.append(p)
    return sorted(str(p) for p in roots)


async def _watch_membership(current: list[str], stop: asyncio.Event) -> None:
    """Trip ``stop`` (→ awatch restart) once the set of repos to watch changes,
    so a newly-registered/removed project is picked up without a backend restart."""
    while not stop.is_set():
        await asyncio.sleep(3)
        if _desired_roots() != current:
            stop.set()
            return


# The Live Gate's debounce (backlog/live-gate.md §2). Deliberately NOT ``[trust]
# quiet_secs`` (~8s), which answers a different question — "settled enough to make a ship
# verdict" — where this one answers "you stopped typing". A constant until dogfooding
# proves it wrong; §4 promotes it to a config key only if it does.
_WATCH_DEBOUNCE_SECS = 2.0


def _quiet_secs_for(ws_id: str) -> float | None:
    """The quiescence debounce (seconds) for a workspace, or ``None`` if no policy wants
    one (the workspace is gone, its project is gone, or it's a managed worktree in a
    project without ``[gate] watch``).

    Two policies share this one timer, forked on workspace kind at fire time (see
    ``_on_quiescence``): an **adopted** worktree settles into an authoritative auto-gate
    at ``[trust] quiet_secs`` (backlog/merge-firewall.md §4), a **managed** one into the
    Live Gate's advisory watch run at the shorter ``_WATCH_DEBOUNCE_SECS``."""
    ws = store.workspaces.get(ws_id)
    if ws is None:
        return None
    proj = store.projects.get(ws.project_id)
    if proj is None:
        return None
    settings = load_project_settings(proj.path)
    if ws.kind == "adopted":
        return float(settings.trust_quiet_secs)
    return _WATCH_DEBOUNCE_SECS if settings.gate_watch else None


async def _on_quiescence(hub: Hub, ws_id: str) -> None:
    """Fired once a worktree has been silent for its debounce — the "settled" point.

    One timer, two policies, forked on workspace kind:

    * **adopted** — the Merge Firewall's agentless auto-gate (backlog/merge-firewall.md
      §4). Adopted worktrees never emit an agent ``done``, so quiescence is their ONLY
      auto-gate trigger: schedule the authoritative ``run_gate`` at the project's ``[gate]
      default_scope`` under ``trigger="auto"``. The ``auto`` trigger means §2's cry-wolf
      guard still holds the run until provisioning is ``ok`` (``gate.auto_gate_allowed``).
    * **managed + ``[gate] watch``** — the Live Gate's ADVISORY ``run_watch``
      (backlog/live-gate.md). A managed worktree already gates authoritatively on agent
      ``done``; this covers the gap that leaves — *your own* edits in ② code or the
      terminal, which nothing verified until you remembered to press a button. It can
      never ship anything (see ``gate.run_watch``).

    Re-checks the workspace still exists (it may have been archived, or the timer raced a
    delete), emits the coarse ``quiescent`` signal either way, then skips when
    ``store.busy_reason`` reports a setup/agent/gate in flight — don't pile a second run
    on, and don't fight a running setup. A manual ``POST /workspaces/{id}/tests`` bypasses
    all of this (``trigger="manual"``, always honored)."""
    ws = store.workspaces.get(ws_id)
    if ws is None:
        return
    await hub.publish(ws_id, {"channel": "fs", "kind": "quiescent", "workspace_id": ws_id})

    if store.busy_reason(ws_id):  # setup/agent/gate already running — leave it be
        return
    proj = store.projects.get(ws.project_id)
    if proj is None:
        return

    # Lazy import: main.py imports this module at load time, so importing it back at the
    # top would cycle. By the time a quiescence timer fires, main is fully loaded.
    from .main import _test_adapter

    settings = load_project_settings(proj.path)

    if ws.kind != "adopted":
        # Managed: the advisory Live Gate. ``run_watch`` re-reads ``[gate] watch`` and
        # re-checks busy itself, so a policy flip mid-debounce can't slip through.
        if not settings.gate_watch:
            return
        store.cancel_watch(ws_id)  # single-flight: a newer save supersedes an older run
        store.watch_tasks[ws_id] = asyncio.create_task(
            run_watch(
                store=store,
                hub=hub,
                adapter=_test_adapter(proj.path),
                workspace=ws,
                project_path=proj.path,
            )
        )
        return

    # Adopted: the authoritative agentless auto-gate. Via ``gate_and_fire`` so a green
    # hands off to the autonomy ladder's armed rung like every other authoritative gate
    # (a no-op unless the project opted into `[trust] auto_action`; an uncommitted foreign
    # worktree is held by the clean-tree preflight, so nobody's work-in-progress ships).
    scope = settings.gate_default_scope
    changed_since = ws.base_ref if scope == "impacted" else None
    task = asyncio.create_task(
        rungs.gate_and_fire(
            store=store,
            hub=hub,
            adapter=_test_adapter(proj.path),
            workspace=ws,
            project_path=proj.path,
            changed_since=changed_since,
            trigger="auto",
        )
    )
    store.gate_tasks[ws_id] = task


class _Quiescence:
    """Per-workspace quiescence debounce (backlog/merge-firewall.md §4 +
    backlog/live-gate.md §2).

    Each fs change to a worktree (re)arms a timer; when the worktree stays quiet for its
    debounce the timer fires ``_on_quiescence``, which forks on workspace kind — an
    adopted worktree into the authoritative auto-gate, a managed one under ``[gate]
    watch`` into the advisory Live Gate. ``watchfiles`` already collapses raw inotify
    storms into ~500ms batches; this is a *second*, longer debounce that waits for the
    whole burst (a pull, a multi-file save, a formatter-on-save, a setup script) to finish
    before treating the worktree as settled. Timers are per-``ws_id`` so a busy worktree
    can't starve a quiet sibling, and ``_fire_after`` re-reads the policy on fire — so a
    workspace with no policy for a timer simply drops it."""

    def __init__(self, hub: Hub) -> None:
        self._hub = hub
        self._timers: dict[str, asyncio.Task] = {}

    def arm(self, ws_id: str) -> None:
        old = self._timers.get(ws_id)
        if old is not None and not old.done():
            old.cancel()
        self._timers[ws_id] = asyncio.create_task(self._fire_after(ws_id))

    async def _fire_after(self, ws_id: str) -> None:
        secs = _quiet_secs_for(ws_id)
        if secs is None:  # workspace vanished, or no policy wants a timer — nothing to arm
            self._timers.pop(ws_id, None)
            return
        try:
            await asyncio.sleep(secs)
        except asyncio.CancelledError:
            return  # a fresh change re-armed us; the newer timer owns the entry
        self._timers.pop(ws_id, None)
        await _on_quiescence(self._hub, ws_id)

    def cancel_all(self) -> None:
        for t in self._timers.values():
            t.cancel()
        self._timers.clear()


async def _dispatch(hub: Hub, changes: set, quiescence: _Quiescence) -> None:
    """Map a batch of ``(Change, path)`` to at-most-one signal per affected entity."""
    paths = [Path(p) for _, p in changes]
    workspaces = list(store.workspaces.values())
    projects = list(store.projects.values())

    fs_dirty: set[str] = set()
    backlog_dirty: set[str] = set()
    for path in paths:
        for ws in workspaces:
            if _under(path, Path(ws.worktree_path)):
                fs_dirty.add(ws.id)
                break
        if _is_todo_doc(path):
            for proj in projects:
                if _under(path, Path(proj.path)):
                    backlog_dirty.add(proj.id)
                    break
        elif path.suffix.lower() in _TODO_DOC_EXT:
            # Doc-like but not the default convention — check each owning project's
            # actual `backlog_dir`/`backlog_files` config (a custom dir name, or a
            # glob like "ROADMAP.md"). Bounded to doc-extension paths, so this
            # settings load never fires on ordinary source-file churn.
            for proj in projects:
                proj_root = Path(proj.path)
                if not _under(path, proj_root):
                    continue
                proj_settings = load_project_settings(proj.path)
                rel = path.relative_to(proj_root).as_posix()
                if backlog_svc.is_backlog_path(rel, proj_settings.backlog_dir, proj_settings.backlog_files):
                    backlog_dirty.add(proj.id)
                break

    for ws_id in fs_dirty:
        await hub.publish(ws_id, {"channel": "fs", "kind": "changed", "workspace_id": ws_id})
        # (Re)arm the quiescence timer when *some* policy wants one: an agentless adopted
        # worktree (authoritative auto-gate) or a managed one under `[gate] watch` (the
        # advisory Live Gate). ``_quiet_secs_for`` is the single place that decides, and
        # ``arm`` no-ops when it returns None — so no workspace pays for a timer it can't use.
        quiescence.arm(ws_id)
    for pid in backlog_dirty:
        await hub.broadcast_global(
            {"channel": "notify", "kind": "backlog_changed", "project_id": pid}
        )


async def watch_forever(hub: Hub) -> None:
    """Long-lived task: translate filesystem changes into hub refresh signals.

    Never raises out (a transient watch error is logged and retried) so it can't
    take the app down; cancelled on shutdown."""
    try:
        Path(settings.worktree_root).expanduser().mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    # One registry for the whole task lifetime: quiescence timers must survive an
    # awatch restart (a membership change or transient error) so an in-flight quiet
    # period isn't reset just because a new project was registered.
    quiescence = _Quiescence(hub)
    try:
        while True:
            roots = _desired_roots()
            if not roots:
                await asyncio.sleep(5)  # nothing registered yet — recheck shortly
                continue
            stop = asyncio.Event()
            rechecker = asyncio.create_task(_watch_membership(roots, stop))
            try:
                async for changes in awatch(
                    *roots,
                    watch_filter=DefaultFilter(),
                    stop_event=stop,
                    debounce=500,
                    step=50,
                ):
                    await _dispatch(hub, changes, quiescence)
            except asyncio.CancelledError:
                rechecker.cancel()
                raise
            except Exception as exc:  # noqa: BLE001 — watch must survive transient FS errors
                print(f"[watch] restarting after error: {exc}")
                await asyncio.sleep(2)
            finally:
                rechecker.cancel()
    except asyncio.CancelledError:
        quiescence.cancel_all()
        raise
