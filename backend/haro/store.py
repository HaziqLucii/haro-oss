"""In-memory application state for v0.

Everything lives in dicts and dies with the process. That's a deliberate v0
choice: it keeps the vertical slice honest (prove the pipe first) and the entity
shapes in models.py are already persistence-ready, so swapping in SQLite later is
a store change, not an API change.
"""

from __future__ import annotations

import asyncio
import time
from pathlib import Path
from typing import Any

from .config import settings
from .models import AgentRun, ArchiveQueueRun, Project, RaceRun, TestRun, Workspace

#: Max size of a single coalesced token entry before append_event starts a fresh
#: one. Bounds the per-chunk string copy so a long run stays O(n), not O(n²).
_TOKEN_COALESCE_CAP = 16_384

#: A workspace holds N agent sessions, not one — the transcript is keyed by
#: ``(workspace_id, session_id)`` (mirrors how run scripts are keyed by
#: ``(workspace_id, run_id)``). ``DEFAULT_SESSION`` is the primary session every
#: single-session caller lands on when it passes no ``session_id`` — so the old
#: one-session-per-workspace path stays byte-identical, and a second concurrent
#: session is just a second key. The wire/UI that surfaces named sessions is a
#: follow-up (§2 "WS multiplexing" in backlog/agent-modes.md); this establishes the
#: data model those build on.
DEFAULT_SESSION = "main"

#: Reserved "session" id for a workspace's setup/provision task. It shares the
#: ``active_tasks`` registry with real agent sessions so the workspace-busy guards
#: (merge/commit/rewind…) refuse while deps are still installing, but it can never
#: collide with a UI-generated session id (those are never ``__setup__``). Keeping
#: setup out of ``DEFAULT_SESSION`` is what lets the primary agent session reuse that
#: slot the instant setup finishes.
SETUP_SESSION = "__setup__"


class Store:
    def __init__(self) -> None:
        self.projects: dict[str, Project] = {}
        self.workspaces: dict[str, Workspace] = {}
        self.runs: dict[str, AgentRun] = {}
        self.tests: dict[str, TestRun] = {}
        # Winner-only fan-out races, keyed by race id (backlog/winner-fanout.md).
        # Persisted like the other entities: §3 keeps every race outcome as model-
        # calibration data ($/green by model×effort), so a race outlives its lanes.
        self.races: dict[str, RaceRun] = {}
        # Handle to the active race supervisor task per race id (is this race running?).
        self.race_tasks: dict[str, asyncio.Task] = {}
        # The race's per-LANE tasks. The budget ceiling and a hand-stop cancel these,
        # never the supervisor above: the supervisor's `finally` is what judges whatever
        # finished, and a cancelled supervisor would die at its first await inside that
        # block — leaving a race stuck on `running` with no owner. See fanout.cancel_lanes.
        self.race_lane_tasks: dict[str, list[asyncio.Task]] = {}
        # Bulk-archive runs, keyed by run id (backlog/bulk-archive.md). Deliberately
        # NOT persisted: a queue is an in-flight operation, not an entity. A reboot
        # mid-queue leaves whatever hadn't been torn down still intact and archivable
        # by hand, which is the safe half of the failure — resuming a destructive
        # batch across a restart the user never saw finish is not.
        self.archive_runs: dict[str, ArchiveQueueRun] = {}
        # Handle to the active bulk-archive driver per PROJECT id. One at a time per
        # project is the whole point: two queues would be concurrent teardowns again.
        self.archive_tasks: dict[str, asyncio.Task] = {}
        # Handle to the active agent task per *session*, keyed by (workspace_id,
        # session_id) — a workspace hosts N concurrent agent sessions sharing one
        # worktree (SETUP_SESSION rides the same registry for the provision task).
        # Keyed by session so a 2nd session doesn't clobber the 1st's stop handle.
        self.active_tasks: dict[tuple[str, str], asyncio.Task] = {}
        # Per-worktree agent *execution* lock (see ``agent_lock``): all sessions
        # share one working tree, so their runs serialize on this — a 2nd session's
        # run streams immediately but queues here until the 1st releases.
        self._agent_locks: dict[str, asyncio.Lock] = {}
        # Handle to the active gate task per workspace.
        self.gate_tasks: dict[str, asyncio.Task] = {}
        # Live Gate (backlog/live-gate.md): the advisory watch loop's in-flight task and
        # last result, per workspace. Deliberately NOT in ``tests`` and NOT persisted by
        # db.py — a watch run is a vital sign, not a verdict, so it must stay invisible to
        # the regression ribbon, the trust streak and every merge preflight. The task
        # handle gives the fs watcher single-flight + a cancel point when a real gate
        # starts; ``watch_runs`` only serves the rail's rehydrate-on-reload.
        self.watch_tasks: dict[str, asyncio.Task] = {}
        self.watch_runs: dict[str, TestRun] = {}
        # Last mutation-score report per workspace (backlog/mutation-gate.md). Same
        # in-memory-only, NEVER-db.py stance as ``watch_runs``: a mutation score is
        # evidence about the tests, not a verdict, so it must stay invisible to the
        # trust streak, the ribbon and every merge preflight. Serves the rail's
        # rehydrate-on-reload; recomputed on demand by ``POST /workspaces/{id}/mutation``.
        self.mutation_runs: dict[str, "MutationResponse"] = {}
        # Cached baseline coverage keyed by (project_id, base_ref) — computed once.
        self.coverage_baselines: dict[tuple[str, str], dict | None] = {}
        # Cached baseline *test inventory* (the `vitest list` set at base_ref), keyed
        # by (project_id, base_ref) — the tamper alarm's "which tests existed before"
        # reference for its removed-test signal. Same compute-once-in-a-detached-worktree
        # shape as ``coverage_baselines`` (see ``analytics._baseline_inventory``); a
        # cached ``None`` means base_ref couldn't be listed (fall back to diff-only signals).
        self.test_inventory_baselines: dict[tuple[str, str], list | None] = {}
        # Verified Hunks (backlog/verified-hunks.md §1): the last green gate's per-line
        # coverage map + the diff it measured, per workspace. Cached because the map costs
        # an instrumented test run — reopening the diff must never re-run the suite.
        #
        # Keyed by workspace_id with the gate's HEAD sha INSIDE the payload rather than in
        # the key, and that is deliberate: the endpoint has to be able to *report* "the gate
        # ran on an older tree", and a key miss cannot say that — a cache miss and a stale
        # hit are different answers to the reviewer. Payload:
        #   {"sha": str|None, "line_hits": dict|None, "diff": str, "scope": str,
        #    "runner": str, "at": float}
        # Not persisted by db.py: it is measurement, not verdict, and it is worthless the
        # moment the tree moves — a rehydrated map would be stale by construction.
        self.line_hits: dict[str, dict] = {}
        # Ports handed out to workspaces (from each project's configured range).
        self.allocated_ports: set[int] = set()
        # Long-lived "run" (dev-server) processes + their log-pump tasks, keyed by
        # (workspace_id, run_id) — a workspace can run several named commands
        # (web/worker/test) concurrently, each on its own port.
        self.run_procs: dict[tuple[str, str], Any] = {}
        self.run_tasks: dict[tuple[str, str], asyncio.Task] = {}
        # Ports allocated to *non-default* runs (the default run reuses workspace.port),
        # keyed the same way, so stop_run can release them.
        self.run_ports: dict[tuple[str, str], int] = {}
        # Interactive terminal (PTY) processes per workspace.
        self.term_procs: dict[str, Any] = {}
        # Result of the last setup run per workspace (drives the "deps" gate chip):
        #   {"status": "running"|"ok"|"failed", "exit": int|None, "note": str|None}
        self.setup_state: dict[str, dict] = {}
        # Last-scanned foreign (unadopted) worktrees per project — the Merge Firewall's
        # "adoptable" hint (backlog/merge-firewall.md §1). A reconciled cache like the
        # rest of the store: ground truth is `git worktree list`, re-derived on boot +
        # on demand (see main.reconcile_adoptable / list_foreign_worktrees). Keyed by
        # project_id → the tagged rows from the last scan; the diff against it is how a
        # newly-appeared foreign worktree is detected. Never drives auto-adoption.
        self.adoptable: dict[str, list[dict]] = {}
        # Persisted agent conversation per *session* (coalesced token chunks), so the
        # transcript survives refreshes/restarts — not just the in-memory hub backlog.
        # Keyed by (workspace_id, session_id): a workspace can host several concurrent
        # agent sessions sharing one worktree, each with its own transcript.
        self.events: dict[tuple[str, str], list[dict]] = {}
        # (workspace_id, session_id) keys whose transcript changed since the last DB
        # snapshot, so the autosave re-serializes only those — not every session's full
        # transcript every 4s (that cost grew with the running agent's output).
        self._events_dirty: set[tuple[str, str]] = set()

    # -- agent tasks + worktree lock ------------------------------------- #
    def agent_lock(self, ws_id: str) -> asyncio.Lock:
        """The per-worktree agent-execution lock (lazily created).

        Every agent session in a workspace edits the SAME working tree. Git only
        reconciles concurrent edits across *separate* worktrees, at merge time —
        inside one tree two agents writing the same file just clobber each other on
        disk. haro can't intercept the ``claude`` subprocess's individual writes, so
        the only serialization boundary it owns is the whole run: ``run_agent`` holds
        this lock across drive + gate + auto-fix. A 2nd session's run is created and
        streams right away, but its drive awaits here until the 1st releases, then
        layers its edits on a settled tree. Echoes ``git_ops._cwd_locks`` (which
        serializes git subprocesses per cwd for the same shared-index reason)."""
        lock = self._agent_locks.get(ws_id)
        if lock is None:
            lock = asyncio.Lock()
            self._agent_locks[ws_id] = lock
        return lock

    def set_active_task(self, ws_id: str, session_id: str, task: asyncio.Task) -> None:
        self.active_tasks[(ws_id, session_id)] = task

    def active_task(self, ws_id: str, session_id: str) -> asyncio.Task | None:
        return self.active_tasks.get((ws_id, session_id))

    def pop_active_task(
        self, ws_id: str, session_id: str, task: asyncio.Task | None = None
    ) -> None:
        """Clear a session's task handle.

        Pass ``task`` to make it identity-checked: the slot is only cleared when it
        still holds *that* task. A run's own teardown must never evict a handle a
        NEWER run in the same session has already registered — otherwise ⏹ stop and
        the busy guards would silently target nothing (see main.start_agent)."""
        if task is not None and self.active_tasks.get((ws_id, session_id)) is not task:
            return
        self.active_tasks.pop((ws_id, session_id), None)

    def setup_task(self, ws_id: str) -> asyncio.Task | None:
        """The workspace's in-flight provisioning task, or None.

        The handle ``runner.run_agent`` awaits so a run fired during setup is *held*
        by the backend instead of refused (or, worse, queued in a view-coupled client
        buffer). Rides the same ``active_tasks`` registry under ``SETUP_SESSION``."""
        return self.active_tasks.get((ws_id, SETUP_SESSION))

    def workspace_tasks(self, ws_id: str) -> list[asyncio.Task]:
        """Every live task (agent sessions + setup) for a workspace."""
        return [t for (w, _s), t in self.active_tasks.items() if w == ws_id]

    def workspace_busy(self, ws_id: str) -> bool:
        """True while any agent session (or setup) is running in the workspace."""
        return any(not t.done() for t in self.workspace_tasks(ws_id))

    def setup_running(self, ws_id: str) -> bool:
        t = self.active_tasks.get((ws_id, SETUP_SESSION))
        return t is not None and not t.done()

    def busy_reason(self, ws_id: str) -> str | None:
        """A human label for whatever blocks a mutation (setup/agent/gate), or None.

        Shared by the guard routes (commit/PR/merge/rewind/gate/setup) so they refuse —
        with an accurate label — while the workspace is busy. Setup is checked first for
        the clearer message (it also shows up in ``workspace_busy``)."""
        if self.setup_running(ws_id):
            return "setup"
        if self.workspace_busy(ws_id):
            return "an agent"
        gate = self.gate_tasks.get(ws_id)
        if gate is not None and not gate.done():
            return "the gate"
        return None

    # -- projects -------------------------------------------------------- #
    def add_project(self, project: Project) -> Project:
        self.projects[project.id] = project
        return project

    def get_project(self, project_id: str) -> Project | None:
        return self.projects.get(project_id)

    def list_projects(self) -> list[Project]:
        return list(self.projects.values())

    def remove_project(self, project_id: str) -> None:
        """Drop a project and any of its workspaces still lingering in the store.
        Worktree teardown is the caller's job — this only forgets bookkeeping."""
        self.projects.pop(project_id, None)
        self.adoptable.pop(project_id, None)
        for ws in [w for w in self.workspaces.values() if w.project_id == project_id]:
            self.remove_workspace(ws.id)

    def update_adoptable(self, project_id: str, rows: list[dict]) -> list[dict]:
        """Replace a project's cached foreign-worktree set with a fresh scan and
        return the rows that are *newly-appeared* since the last scan — the
        "adoptable" hint (backlog/merge-firewall.md §1). Diffs by resolved path;
        rows all come from the same `git worktree list` output, so the raw path
        string is a stable key. First scan (empty baseline) reports everything as
        new; callers decide whether to broadcast (boot seeds silently, on-demand
        scans announce the delta)."""
        prev = {r["path"] for r in self.adoptable.get(project_id, [])}
        self.adoptable[project_id] = rows
        return [r for r in rows if r["path"] not in prev]

    # -- workspaces ------------------------------------------------------ #
    def add_workspace(self, ws: Workspace) -> Workspace:
        self.workspaces[ws.id] = ws
        return ws

    def get_workspace(self, ws_id: str) -> Workspace | None:
        return self.workspaces.get(ws_id)

    def list_workspaces(self, project_id: str | None = None) -> list[Workspace]:
        vals = self.workspaces.values()
        if project_id:
            return [w for w in vals if w.project_id == project_id]
        return list(vals)

    def remove_workspace(self, ws_id: str) -> None:
        self.workspaces.pop(ws_id, None)
        self.drop_transcript(ws_id)
        self.setup_state.pop(ws_id, None)
        self.cancel_watch(ws_id)
        self.watch_runs.pop(ws_id, None)
        self.mutation_runs.pop(ws_id, None)
        self.drop_line_hits(ws_id)

    def cancel_watch(self, ws_id: str) -> None:
        """Stop the advisory watch loop for a workspace, if one is in flight.

        Called on removal and whenever a real gate starts — the Live Gate must yield the
        worktree to anything authoritative (backlog/live-gate.md). Idempotent."""
        task = self.watch_tasks.pop(ws_id, None)
        if task is not None and not task.done():
            task.cancel()

    def drop_transcript(self, ws_id: str) -> None:
        """Forget every session transcript for a workspace — all ``(ws_id, *)`` keys.
        Used by removal + the boot reconcile, which prune a whole workspace at once."""
        for key in [k for k in self.events if k[0] == ws_id]:
            self.events.pop(key, None)
            self._events_dirty.discard(key)

    # -- agent conversation (persisted, per session) -------------------- #
    def append_event(
        self, workspace_id: str, event: dict, session_id: str = DEFAULT_SESSION
    ) -> None:
        """Append an agent event to a session's persisted transcript, coalescing
        consecutive streamed token chunks (same run) into one entry to keep it compact.
        ``session_id`` defaults to the workspace's primary session, so single-session
        callers are unchanged; a second session id keeps its own transcript + turns."""
        key = (workspace_id, session_id)
        lst = self.events.setdefault(key, [])
        self._events_dirty.add(key)
        p = event.get("payload") or {}
        last = lst[-1] if lst else None
        # -- per-turn marker ------------------------------------------------- #
        # Tag every event with a monotonic per-workspace ``turn`` ordinal so the UI can
        # anchor a "rewind to here" action on a stable boundary. A ``user`` event (the
        # prompt echo, or an auto-fix announce) opens a new turn; every agent event that
        # follows shares that number until the next ``user`` event. Derived from the tail
        # of the transcript, not a separate counter, so it survives hydration on boot and
        # the 4000-event cap below with no extra persisted state. (On a token coalesce
        # below the tag is discarded with the dropped event — the surviving entry already
        # carries the same turn, since consecutive tokens never cross a ``user`` event.)
        prev_turn = last.get("turn", 0) if last else 0
        if event.get("type") == "user":
            event["turn"] = prev_turn + 1
        else:
            event["turn"] = prev_turn or 1
        # Coalesce consecutive streamed token chunks (same run) into one entry to
        # keep the transcript compact — but CAP each entry's size. Every event in a
        # run shares one run_id, so without the cap a whole run's output coalesces
        # into a single ever-growing string, and `text = text + chunk` re-copies it
        # on every chunk → O(n²) CPU + memory that pegs a core on a long run. Once an
        # entry passes the cap we start a fresh token entry, keeping the work linear.
        # The UI renders consecutive token entries contiguously, so this is invisible.
        last_text = (last.get("payload") or {}).get("text") or "" if last else ""
        if (
            event.get("type") == "token"
            and not p.get("system")
            and last is not None
            and last.get("type") == "token"
            and last.get("run_id") == event.get("run_id")
            and not (last.get("payload") or {}).get("system")
            and len(last_text) < _TOKEN_COALESCE_CAP
        ):
            last["payload"]["text"] = last_text + (p.get("text") or "")
        else:
            lst.append(event)
        if len(lst) > 4000:  # bound unbounded growth
            del lst[: len(lst) - 4000]

    def events_for(self, workspace_id: str, session_id: str = DEFAULT_SESSION) -> list[dict]:
        """A session's persisted transcript (empty list if none yet). The read accessor
        callers use instead of reaching into ``self.events`` with a bare workspace id —
        the store is keyed by ``(workspace_id, session_id)`` now."""
        return self.events.get((workspace_id, session_id), [])

    def sessions(self, workspace_id: str) -> list[str]:
        """Session ids that have a transcript in this workspace, first-seen order (dict
        insertion order). The set a session switcher enumerates."""
        return [sid for (wid, sid) in self.events if wid == workspace_id]

    def turns(self, workspace_id: str, session_id: str = DEFAULT_SESSION) -> list[dict]:
        """Turn boundaries in a session's transcript — the anchors a "rewind to here"
        action targets. One entry per ``user`` event (a prompt, or a platform auto-fix /
        review-fix announce): its turn ordinal, the prompt text, when it fired, and
        whether it was a real user prompt, a test auto-fix round, or a refuter
        review-fix round (Phase 3 — notes/workflow-roles-plan.md) (so the UI can tell
        them apart / dim the latter two). Ordered oldest → newest — the same order they
        appear in the stream."""
        out: list[dict] = []
        for ev in self.events.get((workspace_id, session_id), []):
            if ev.get("type") != "user":
                continue
            out.append(
                {
                    "turn": ev.get("turn", 0),
                    "run_id": ev.get("run_id", ""),
                    "ts": ev.get("ts", 0.0),
                    "prompt": (ev.get("payload") or {}).get("text", ""),
                    "kind": (
                        "autofix" if ev.get("run_id") == "autofix"
                        else "reviewfix" if ev.get("run_id") == "reviewfix"
                        else "user"
                    ),
                }
            )
        return out

    def rewind(self, workspace_id: str, turn: int, session_id: str = DEFAULT_SESSION) -> dict:
        """Rewind a session's persisted transcript to just before ``turn``: drop every
        event at or after that turn boundary, and report the prompt that opened it (for
        the composer to prefill) plus how many events were dropped.

        This is the *conversation* half of the "rewind to here" action — the worktree
        half (an optional checkpoint commit before the drop) lives in the route, since
        it needs git. ``last_session_id`` is deliberately untouched: the next run still
        ``--resume``\\s the same Claude session, continuing from the rewound point.

        Events that predate per-turn markers (no integer ``turn``) are always kept —
        there's no boundary to anchor a rewind to them, so they can't be a target."""
        key = (workspace_id, session_id)
        lst = self.events.get(key, [])
        prompt = ""
        for ev in lst:
            if ev.get("type") == "user" and ev.get("turn") == turn:
                prompt = (ev.get("payload") or {}).get("text", "")
                break
        kept = [ev for ev in lst if not (isinstance(ev.get("turn"), int) and ev["turn"] >= turn)]
        dropped = len(lst) - len(kept)
        if dropped:
            self.events[key] = kept
            self._events_dirty.add(key)
        return {"turn": turn, "prompt": prompt, "dropped": dropped}

    # -- runs ------------------------------------------------------------ #
    def add_run(self, run: AgentRun) -> AgentRun:
        self.runs[run.id] = run
        return run

    def get_run(self, run_id: str) -> AgentRun | None:
        return self.runs.get(run_id)

    def latest_run(self, workspace_id: str) -> AgentRun | None:
        runs = [r for r in self.runs.values() if r.workspace_id == workspace_id]
        return max(runs, key=lambda r: r.started_at, default=None)

    # -- test runs ------------------------------------------------------- #
    def add_test(self, test: TestRun) -> TestRun:
        self.tests[test.id] = test
        return test

    def latest_test(self, workspace_id: str) -> TestRun | None:
        tests = [t for t in self.tests.values() if t.workspace_id == workspace_id]
        return max(tests, key=lambda t: t.started_at, default=None)

    def test_history(self, workspace_id: str) -> list[TestRun]:
        """All gate runs for a workspace, oldest → newest (regression ribbon)."""
        tests = [t for t in self.tests.values() if t.workspace_id == workspace_id]
        return sorted(tests, key=lambda t: t.started_at)

    def project_test_history(self, project_id: str) -> list[TestRun]:
        """Every gate run across a project's workspaces, oldest → newest.

        The substrate for the project-level trust streak (backlog/autonomy-ladder.md):
        ``trust._streak`` walks this newest→oldest counting trailing clean full-scope
        greens. Filters ``store.tests`` by ``TestRun.project_id`` (stamped at gate time),
        NOT by a live-workspace join, so a workspace's greens keep counting after it
        merges + archives — ``remove_workspace`` drops the workspace but leaves its runs,
        and ``store.tests`` is snapshotted to Postgres (``db.py`` ``test_runs``) so the
        streak survives a restart. Runs persisted before ``project_id`` existed carry
        ``None``; those are re-attributed via the live-workspace join so an in-flight
        project doesn't lose its history across the upgrade."""
        live = {w.id for w in self.workspaces.values() if w.project_id == project_id}
        tests = [
            t
            for t in self.tests.values()
            if t.project_id == project_id or (t.project_id is None and t.workspace_id in live)
        ]
        return sorted(tests, key=lambda t: t.started_at)

    # -- races ------------------------------------------------------------ #
    def add_race(self, race: RaceRun) -> RaceRun:
        self.races[race.id] = race
        return race

    def get_race(self, race_id: str) -> RaceRun | None:
        return self.races.get(race_id)

    def list_races(self, project_id: str | None = None) -> list[RaceRun]:
        """A project's races, newest first (the scorecard rail's order)."""
        races = [
            r for r in self.races.values()
            if project_id is None or r.project_id == project_id
        ]
        return sorted(races, key=lambda r: r.created_at, reverse=True)

    def race_for_workspace(self, ws_id: str) -> RaceRun | None:
        """The race a workspace is a lane of, via ``Workspace.race_id``.

        Resolved through the workspace rather than by scanning every race's lane list,
        so a soft-archived loser (row kept, worktree gone) still finds its scorecard."""
        ws = self.workspaces.get(ws_id)
        return self.races.get(ws.race_id) if ws and ws.race_id else None

    # -- bulk archive ------------------------------------------------------ #
    def add_archive_run(self, run: ArchiveQueueRun) -> ArchiveQueueRun:
        self.archive_runs[run.id] = run
        return run

    def get_archive_run(self, run_id: str) -> ArchiveQueueRun | None:
        return self.archive_runs.get(run_id)

    def latest_archive_run(self, project_id: str) -> ArchiveQueueRun | None:
        """This project's most recent bulk archive — what a reconnecting client shows
        instead of an empty panel (the run rides the global feed, so a page reload
        mid-queue would otherwise lose the only view of a destructive batch)."""
        runs = [r for r in self.archive_runs.values() if r.project_id == project_id and not r.dry]
        return max(runs, key=lambda r: r.created_at, default=None)

    def archive_running(self, project_id: str) -> bool:
        """Is a bulk archive already draining for this project? One at a time per
        project is the guard that keeps the queue a queue."""
        task = self.archive_tasks.get(project_id)
        return task is not None and not task.done()

    # -- verified hunks (per-line proof) --------------------------------- #
    def set_line_hits(
        self,
        workspace_id: str,
        *,
        sha: str | None,
        line_hits: dict | None,
        diff: str,
        scope: str = "",
        runner: str = "",
    ) -> None:
        """Record the green gate's per-line coverage map and the diff it measured.

        Overwrites rather than accumulating: only the most recent green run's evidence
        can be lined up against the tree in front of the reviewer, so keeping older maps
        would only ever offer a way to annotate a diff with the wrong measurement.
        """
        self.line_hits[workspace_id] = {
            "sha": sha,
            "line_hits": line_hits,
            "diff": diff,
            "scope": scope,
            "runner": runner,
            "at": time.time(),
        }

    def get_line_hits(self, workspace_id: str) -> dict | None:
        return self.line_hits.get(workspace_id)

    def drop_line_hits(self, workspace_id: str) -> None:
        self.line_hits.pop(workspace_id, None)

    # -- port allocation ------------------------------------------------- #
    def allocate_port(self, lo: int, hi: int) -> int | None:
        """First free port in [lo, hi] not already handed out, else None."""
        for p in range(lo, hi + 1):
            if p not in self.allocated_ports:
                self.allocated_ports.add(p)
                return p
        return None

    def release_port(self, port: int | None) -> None:
        if port is not None:
            self.allocated_ports.discard(port)

    # -- worktree path allocation --------------------------------------- #
    def worktree_path(self, project: Project, ws_name_slug: str) -> Path:
        """Where a new worktree lives: <root>/<project_name>/<slug>."""
        root = Path(settings.worktree_root).expanduser()
        return root / project.name / ws_name_slug


store = Store()
