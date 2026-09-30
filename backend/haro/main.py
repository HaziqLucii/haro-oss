"""haro FastAPI app (v0).

REST control plane + one WebSocket per workspace. The route surface mirrors the
sketch in notes/product-spec.md; v0 implements the subset needed to close the
loop: register project → create workspace (worktree) → run agent (streamed) →
diff → archive.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import inspect
import json
import os
import re
import shutil
import time
import traceback
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import archive_queue
from . import baseline as baseline_svc
from . import assist as assist_svc
from . import research as research_svc
from . import attest as attest_svc
from . import reproduce as reproduce_svc
from . import backlog as backlog_svc
from . import blame as blame_svc
from . import db
from . import editors as editors_svc
from . import files as filesvc
from . import firewall as firewall_svc
from . import git_ops
from .run_check import missing_script
from . import issues as issues_svc
from . import issue_detail as issue_detail_svc
from . import merge_queue
from . import git_panel
from . import presets
from . import acceptance
from . import protect_tests
from . import review as reviewsvc
from . import rungs
from . import xp as xp_svc
from . import xp_hooks
from .roles import scout_agent_json, scout_instructions
from . import trust as trust_svc
from . import update
from . import usage as usage_svc
from . import verified_hunks as verified_hunks_svc
from . import mutation as mutation_svc
from . import receipt as receipt_svc
from . import analytics as analytics_svc
from .models import MutationResponse, MutationSurvivor
from .models import ReceiptResponse
from .models import XpActivityRequest, XpActivityResponse, XpAward, XpEvent, XpRules, XpStatus
from .adapters import AgentAdapter, ClaudeCodeAdapter, LocalModelAdapter
from .adapters.test_runner import (
    CommandAdapter,
    OffenseAdapter,
    PytestAdapter,
    TestRunnerAdapter,
    VitestAdapter,
)
from .analytics import coverage_delta, detect_flaky
from .config import (
    copy_worktree_includes,
    load_project_settings,
    read_env,
    read_instructions,
    seed_worktree_env,
    settings,
    write_env,
    write_instructions,
    write_project_agent,
    write_project_firewall,
    write_project_gate,
    write_project_merge_mode,
    write_project_roles,
    write_project_scripts,
)
from .gate import build_trust_report, ensure_deps, run_gate
from .haro_skill import install_haro_skill
from .hub import Hub
from .integrate import ShipRefused, integrate, ship_preflight
from .lifecycle import (
    quiesce_workspace,
    run_archive,
    run_setup,
    script_env,
    start_run,
    stop_all_runs,
    stop_run,
    sweep_orphan_runs,
)
from .terminal import set_winsize, spawn_shell
from .models import (
    BaselineState,
    AssistJob,
    AssistPlanRequest,
    AssistResearchRequest,
    ManPage,
    ManualPlan,
    PatchPlanRequest,
    PinnedDoc,
    PinnedDocsRequest,
    PlanStep,
    RECENT_ASKS,
    ResearchEntry,
    ResearchResponse,
    ModeSwitch,
    SetModeRequest,
    StagePathsRequest,
    WorkspaceMode,
    status_payload,
    AdoptWorkspaceRequest,
    AgentRun,
    AgentRunStatus,
    ApplyPresetRequest,
    ApproveTestFirstRequest,
    CancelTestFirstRequest,
    ArchiveQueueRequest,
    ArchiveQueueRun,
    BlameEntry,
    BlameResponse,
    CheckedRowRequest,
    CommitRequest,
    ContextAttachRequest,
    ContextUploadRequest,
    CreateEntryRequest,
    CreateProjectRequest,
    CreateWorkspaceRequest,
    DeleteEntryRequest,
    RenameEntryRequest,
    RenameWorkspaceRequest,
    MkdirRequest,
    DiffResponse,
    EditorInfo,
    OpenInRequest,
    OpenInResponse,
    AgentConfig,
    AgentUpdateRequest,
    RolesConfig,
    RolesUpdateRequest,
    LocalModelsResponse,
    EnvConfig,
    EnvUpdateRequest,
    FirewallInstallRequest,
    FirewallInstallResult,
    FirewallVerdict,
    GateConfig,
    KnownFlaky,
    GateUpdateRequest,
    GitStatusResponse,
    ImpactResponse,
    MergeRequest,
    MergeQueueItem,
    MergeQueueResult,
    PrStatusResponse,
    DefaultBranchRequest,
    Project,
    InstructionsConfig,
    InstructionsUpdateRequest,
    RemoteConfig,
    RemoteUpdateRequest,
    RewindRequest,
    RewindResponse,
    TodoItemAppendRequest,
    TodoWriteRequest,
    ReviewRequest,
    ReviewResult,
    ReviewVerdict,
    WorkflowConfig,
    WorkflowUpdateRequest,
    RunScriptInfo,
    ScriptsConfig,
    ScriptsUpdateRequest,
    StackDetection,
    StartAgentRequest,
    TestFirstState,
    TestRun,
    TestRunStatus,
    VerifiedFile,
    VerifiedHunksResponse,
    Workspace,
    WorkspaceStatus,
    WriteFileRequest,
)
from .runner import run_agent
from .store import store, Store, DEFAULT_SESSION, SETUP_SESSION
from .watcher import watch_forever


async def _autosave() -> None:
    """Periodically snapshot the store to SQLite so a crash loses at most a few seconds."""
    while True:
        await asyncio.sleep(4)
        try:
            await db.save_snapshot(store)
        except Exception:  # noqa: BLE001 — autosave must never crash the app
            pass


async def _update_watcher() -> None:
    """Drive the desktop self-update. Broadcasts status on the notify feed so the
    UI pill stays live, and — only while idle (no agent/gate work a restart would
    kill) — applies either a queued manual update (``pending``) or, in ``auto``
    mode, any available update. Applying spawns a detached rebuild that restarts
    the app, so we return once it's launched."""
    while True:
        await asyncio.sleep(20)
        try:
            st = await update.status(store)
            await hub.broadcast_global({"channel": "notify", "kind": "update_status", **st})
            if not (st["supported"] and st["available"]) or st["busy"]:
                continue
            if st["pending"] or st["mode"] == "auto":
                await hub.broadcast_global({"channel": "notify", "kind": "update_applying"})
                if await update.apply():
                    return  # rebuild launched; it will restart us
        except Exception:  # noqa: BLE001 — the watcher must never crash the app
            pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load persisted state on boot, reconcile with the filesystem, autosave while up,
    and flush on shutdown — so workspaces/history survive restarts."""
    # Coarse per-step boot timing, printed in the same style as the [reconcile]/
    # [sweep] notes below. Lands in ~/.haro/backend.log for the desktop build, so
    # a slow launch is diagnosable without attaching a profiler. Purely additive —
    # doesn't change step order (reconcile/mark_broken/sweep_orphan_runs must stay
    # ahead of `yield`: they set statuses the UI reads on first fetch and free
    # ports before "run" is offered).
    boot_start = time.perf_counter()

    def _step(label: str, t0: float) -> None:
        print(f"[boot] {label} {(time.perf_counter() - t0) * 1000:.0f}ms")

    # A freshly relaunched build is done updating — drop any leftover rebuild-progress
    # milestone so the new app doesn't render a stale "still updating" bar.
    update.clear_progress()
    # Ship the "haro" platform-expert skill at user level so every agent we spawn
    # can answer questions about operating haro itself (see haro_skill.py).
    t0 = time.perf_counter()
    for note in install_haro_skill():
        print(f"[skill] {note}")
    _step("install_haro_skill", t0)
    t0 = time.perf_counter()
    await db.init()
    _step("db.init", t0)
    t0 = time.perf_counter()
    await db.load_into(store)
    _step("db.load_into", t0)
    t0 = time.perf_counter()
    for note in db.reconcile(store):
        print(f"[reconcile] {note}")
    _step("db.reconcile", t0)
    # Husk worktrees (dir present, `.git` gone) that reconcile left in place need a
    # git query to classify — mark unmerged ones `broken` (kept as a repair card),
    # drop merged ones. Async, so it runs here rather than in the sync reconcile.
    t0 = time.perf_counter()
    for note in await db.mark_broken(store):
        print(f"[reconcile] {note}")
    _step("db.mark_broken", t0)
    # Merge Firewall: seed the per-project "adoptable" hint from `git worktree list`
    # so a foreign worktree that appeared while haro was down is surfaced on boot,
    # and later on-demand scans can detect what *newly* appeared. Never auto-adopts.
    t0 = time.perf_counter()
    for note in await baseline_svc.sweep_stale_all(store):
        print(f"[sweep] {note}")
    _step("baseline sweep", t0)
    t0 = time.perf_counter()
    for note in await reconcile_adoptable(store):
        print(f"[adoptable] {note}")
    _step("reconcile_adoptable", t0)
    # Kill dev servers orphaned by a previous unclean exit — run_procs is empty at
    # boot, so a server still bound to a workspace port would desync the UI ("run"
    # available while the old server keeps serving). See lifecycle.sweep_orphan_runs.
    t0 = time.perf_counter()
    for note in sweep_orphan_runs([ws.worktree_path for ws in store.workspaces.values()]):
        print(f"[sweep] {note}")
    _step("sweep_orphan_runs", t0)
    _step("total", boot_start)
    saver = asyncio.create_task(_autosave())
    # Event-driven "always updated": push refresh signals the instant worktree /
    # backlog files change (watcher.py), and detect PRs merged on github.com that
    # emit no local event (merge poll) — so no panel needs a manual refresh.
    watcher_task = asyncio.create_task(watch_forever(hub))
    merge_poll = asyncio.create_task(_poll_merges())
    update_poll = asyncio.create_task(_update_watcher())
    try:
        yield
    finally:
        saver.cancel()
        watcher_task.cancel()
        merge_poll.cancel()
        update_poll.cancel()
        await stop_all_runs(store)  # don't leave dev servers running past shutdown/reload
        try:
            await db.save_snapshot(store)
        except Exception:  # noqa: BLE001
            pass
        await db.close()


app = FastAPI(title="haro", version="0.10.3", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.frontend_origin],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

hub = Hub()

#: Strong references to genuinely fire-and-forget background coroutines. asyncio only
#: keeps a weak reference to a running task, so a bare ``create_task(...)`` whose handle
#: nobody stores can be garbage-collected MID-FLIGHT and silently vanish. Anything with
#: a real owner belongs in that owner's registry instead (``store.active_tasks``,
#: ``store.run_tasks``, ``store.gate_tasks``); this set is only for the few side-effects
#: nothing waits on.
_detached: set[asyncio.Task] = set()


def _detach(coro) -> asyncio.Task:
    """Run ``coro`` in the background, holding a reference until it completes."""
    task = asyncio.create_task(coro)
    _detached.add(task)
    task.add_done_callback(_detached.discard)
    return task


async def _adopt_merged_state(ws: Workspace, data: dict) -> bool:
    """Keep ``ws.status`` in sync with GitHub's PR state — in BOTH directions.

    Promote to ``merged`` only when the PR is MERGED *for this branch's current
    commit* (its ``headRefOid`` == our HEAD). A branch NAME stays MERGED on GitHub
    forever once its first PR lands, so a reused/renamed branch — or new commits
    since the merge — must NOT read as merged. That false-positive is what flipped
    a fresh ``feat/adapter-flag`` run to merged and dimmed its run/stop controls.

    And DEMOTE out of ``merged`` when the PR no longer matches (renamed branch, no
    PR, or fresh commits) so a wrongly-merged workspace un-sticks on the next
    refresh. Shared by ``GET /git/pr`` and the background poll. Returns True if it
    changed the status."""
    # A PR record is the ONLY evidence this function may act on. ``pr_status``
    # degrades to ``supported=False`` (no remote, no ``gh``, worktree gone) or
    # ``exists=False`` (no PR for this branch) — an absence, not a "not merged".
    # Reading it as one demoted every LOCAL merge (no-remote repos, ``[workflow]
    # merge_mode = "merge"``) back to gate_green the moment the ship panel loaded:
    # `integrate` had just set `merged`, and the panel's own PR fetch undid it.
    if not data.get("supported") or not data.get("exists"):
        return False
    merged_now = (data.get("state") or "").upper() == "MERGED"
    head = data.get("head_sha")
    if merged_now and head:
        try:
            if (await git_ops.head_sha(ws.worktree_path)) != head:
                merged_now = False  # merged PR is for a different commit than we're on
        except Exception:  # noqa: BLE001 — can't read HEAD → don't risk a false flip
            merged_now = False

    if merged_now and ws.status != WorkspaceStatus.merged:
        was_green = ws.status == WorkspaceStatus.gate_green
        ws.status = WorkspaceStatus.merged
        if data.get("number") and not ws.last_pr_number:
            ws.last_pr_number = data["number"]
        if was_green:
            await xp_hooks.record_merge(store, hub, ws, await xp_hooks.merge_changed_paths(ws))
    elif not merged_now and ws.status == WorkspaceStatus.merged:
        # Stale/false merged → back to a usable status (green if the last gate
        # passed, else idle) so the agent controls work again.
        ws.status = (
            WorkspaceStatus.gate_green
            if ws.gate and ws.gate.status == "passed"
            else WorkspaceStatus.idle
        )
    else:
        return False

    await hub.publish(ws.id, status_payload(ws))
    await db.save_snapshot(store)
    return True


async def _poll_merges() -> None:
    """Detect PRs merged on github.com — the one case with no local event source
    (a webhook would need broad inbound scope, against haro's local-first stance).

    Bounded on purpose: only workspaces that are green AND live under a remote-linked
    project are polled (i.e. finished work that plausibly has an open PR), and each
    drops out the instant it reads MERGED. Zero open candidates → zero ``gh`` calls,
    so idle cost is nil."""
    while True:
        await asyncio.sleep(30)
        candidates = []
        for ws in list(store.workspaces.values()):
            if ws.status != WorkspaceStatus.gate_green:
                continue
            proj = store.get_project(ws.project_id)
            if proj and proj.remote_url:
                candidates.append(ws)
        for ws in candidates:
            try:
                data = await git_panel.pr_status(ws.worktree_path, ws.branch)
            except Exception:  # noqa: BLE001 — a flaky gh call must not kill the loop
                continue
            await _adopt_merged_state(ws, data)


def _test_adapter(project_path: str | None) -> TestRunnerAdapter:
    """Pick the gate's test runner from ``[gate] runner`` (default: vitest, so
    projects that don't opt into pytest/command behave exactly as before)."""
    settings = load_project_settings(project_path) if project_path else None
    runner = settings.gate_runner if settings else ""
    if runner == "pytest":
        return PytestAdapter()
    if runner == "command":
        return CommandAdapter(settings.gate_command, login_shell=settings.login_shell)
    if runner == "offense":
        return OffenseAdapter(
            settings.gate_command, settings.gate_format, login_shell=settings.login_shell
        )
    return VitestAdapter(sandbox=settings.gate_sandbox if settings else False)


@app.get("/health")
async def health() -> dict:
    return {
        "ok": True,
        "worktree_root": settings.worktree_root,
        # Lets a client tell "the backend on this port owns MY database" from any other haro.
        "db": db.resolved_db_path(),
    }


@app.get("/usage")
async def get_usage(refresh: bool = False) -> dict:
    """Claude subscription usage (session / weekly utilization + reset windows +
    extra-usage credits) — the same feed Claude Desktop's Usage view reads, using
    the user's own Claude Code OAuth token. Read-only; degrades to
    ``{available: false, reason}`` when no fresh token is on this machine. See
    ``usage.py`` for the credential-store and no-refresh rationale."""
    return await usage_svc.get_usage(force=refresh)


@app.get("/update/status")
async def update_status() -> dict:
    """Is a newer local build available, are we busy (agents/gates), and which
    mode (manual/auto). The desktop app polls this + listens on the notify feed."""
    return await update.status(store)


@app.get("/update/progress")
async def update_progress() -> dict | None:
    """The current rebuild milestone (`{pct, label}`) while a self-update is in flight,
    else `null`. Served by the still-alive old app so the banner shows real progress
    (rebuild.sh writes the milestones; see update.progress)."""
    return update.progress()


@app.post("/update/apply")
async def update_apply() -> dict:
    """Apply the self-update. If agents/gates are running, QUEUE it to apply the
    instant they finish (a restart mid-agent would kill the work); if idle, start
    the rebuild+restart now."""
    st = await update.status(store)
    if not st["available"]:
        raise HTTPException(409, "No update available.")
    if st["busy"]:
        update.set_pending(True)
        await hub.broadcast_global(
            {"channel": "notify", "kind": "update_status", **await update.status(store)}
        )
        return {"scheduled": True, "busyReason": st["busyReason"]}
    if not await update.apply():
        raise HTTPException(409, "This build can't self-update (no source stamp).")
    await hub.broadcast_global({"channel": "notify", "kind": "update_applying"})
    return {"applying": True}


@app.get("/update/settings")
async def get_update_settings() -> dict:
    return {"mode": update.get_mode()}


@app.put("/update/settings")
async def put_update_settings(mode: str) -> dict:
    """Set the update preference: ``manual`` (user clicks) or ``auto`` (apply on
    its own once idle). Passed as a query param, e.g. ``?mode=auto``."""
    return {"mode": update.set_mode(mode)}


# --------------------------------------------------------------------------- #
# Projects
# --------------------------------------------------------------------------- #
@app.post("/projects", response_model=Project)
async def create_project(req: CreateProjectRequest) -> Project:
    path = str(Path(req.path).expanduser().resolve())
    if not await git_ops.is_git_repo(path):
        if not req.init:
            raise HTTPException(
                400, f"{path} is not a git repository (pass init=true to run git init)"
            )
        try:
            await git_ops.init_repo(path)
            if req.remote_url and req.remote_url.strip():
                await git_ops.set_remote(path, req.remote_url.strip())
        except git_ops.GitError as exc:
            raise HTTPException(400, f"git init failed: {exc.stderr}") from exc
    if not await git_ops.ref_exists(path, "HEAD"):
        # Every workspace is a worktree branched from a commit, so an empty repo would
        # only fail later, at the first New workspace.
        raise HTTPException(
            400,
            f"{path} has no commits yet. haro branches each workspace from a commit, so "
            "make a first commit (for example: git commit --allow-empty -m init) and add it again.",
        )
    try:
        branch = await git_ops.default_branch(path)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"couldn't read the current branch: {exc.stderr.strip()}") from exc
    remote = await git_ops.get_remote(path)
    project = Project(
        name=req.name or Path(path).name,
        path=path,
        default_branch=branch,
        remote_url=remote,
        stack=presets.detect_stack_logos(path),
    )
    store.add_project(project)
    await db.save_snapshot(store)
    return project


@app.get("/projects", response_model=list[Project])
async def list_projects() -> list[Project]:
    # Backfill stack logos for projects created before the field existed (or
    # scanned under an older detection version). One-shot per project via a
    # version marker so a repo we recognize as "no stack" isn't re-scanned on
    # every list, but a detection upgrade (STACK_SCAN_VERSION bump) re-runs once.
    projects = store.list_projects()
    dirty = False
    for p in projects:
        if p.settings.get("_stack_scan_v") != presets.STACK_SCAN_VERSION:
            p.stack = presets.detect_stack_logos(p.path)
            p.settings["_stack_scan_v"] = presets.STACK_SCAN_VERSION
            p.settings.pop("_stack_scanned", None)  # retire the v1 boolean marker
            dirty = True
    if dirty:
        await db.save_snapshot(store)
    return projects


@app.get("/projects/{project_id}/detect-stack", response_model=StackDetection)
async def detect_project_stack(project_id: str) -> StackDetection:
    """Sniff the project's tree and propose a stack preset (gate + setup/run) for
    the add-project flow. Returns the full ranked candidate list (``custom`` always
    included) plus a single ``proposal`` to auto-fill — ``None`` when detection is
    ambiguous, so the UI asks rather than auto-picking. Read-only: it inspects the
    repo and renders each candidate's ``settings.toml`` fragment; nothing is
    written until the dev confirms a choice."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return presets.detect_stack_response(project.path)


@app.post("/projects/{project_id}/apply-preset")
async def apply_project_preset(project_id: str, req: ApplyPresetRequest) -> dict:
    """Confirm a stack preset from the add-project propose-and-confirm UI: write its
    ``[scripts]`` + ``[gate]`` into the project's ``.haro/settings.toml``
    (shared) or ``.local`` (personal). This is the "write" step the UI gates behind
    the dev inspecting the generated config; nothing is written by detection itself.
    Reuses ``write_project_scripts`` so the on-disk shape matches the in-app editor,
    preserving the existing port range + run mode. ``custom`` (empty gate/scripts)
    is a no-op verdict the dev may still pick — it writes just the managed tables so
    the choice lands without imposing a runner."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    preset = presets.get_preset(req.preset_id)
    if not preset:
        raise HTTPException(404, f"unknown preset {req.preset_id!r}")
    preset = presets.for_repo(preset, project.path)
    ps = load_project_settings(project.path)  # preserve port range + run mode
    path = write_project_scripts(
        project.path,
        setup=preset.setup or None,
        run=preset.run or None,
        archive=ps.archive or None,
        run_mode=ps.run_mode,
        # A preset that needs a login shell (e.g. Shopify via a local npx) turns it
        # on; never clobber a project that already had it on.
        login_shell=preset.login_shell or ps.login_shell,
        port_range=ps.port_range,
        gate=dict(preset.gate),
        target=req.target,
    )
    return {"ok": True, "preset_id": preset.id, "target": req.target, "path": path}


#  Parsing (`parse_todo_doc`/`parse_todo`/`dedent_block`) and the write-back tick
# (`tick_backlog_item`) live in `backlog.py` now — it's the single home for backlog
# markdown. `tick_backlog_item` itself is called from inside `integrate()`
# (integrate.py), on the workspace's WORKTREE, before the merge commit — every
# merge path goes through `integrate()`, so nothing here needs to call it directly
# any more. Aliased under their old names so every call site below (and
# test_todo_parse.py's imports) is unchanged.
_parse_todo_doc = backlog_svc.parse_todo_doc
_parse_todo = backlog_svc.parse_todo
_dedent_block = backlog_svc.dedent_block
tick_backlog_item = backlog_svc.tick_backlog_item  # kept for test_backlog_stage.py's unit tests


async def _discover_todo_files(
    project_path: str, backlog_dir: str = "backlog", backlog_files: list[str] | None = None
) -> list[str]:
    """Repo-relative paths of the project's backlog docs. A file qualifies per
    ``backlog.is_backlog_path``: doc extension AND (lives under ``backlog_dir``,
    its name contains 'todo', or it matches a ``backlog_files`` glob like
    ``"ROADMAP.md"``/``"docs/backlog*"``). Uses ``git ls-files`` (tracked + new,
    honoring .gitignore) so it finds both committed backlogs and a just-created
    one, and never wanders into node_modules."""
    try:
        out = await git_ops._git(
            "ls-files", "--cached", "--others", "--exclude-standard", cwd=project_path
        )
    except git_ops.GitError:
        return []
    rels: list[str] = []
    seen: set[str] = set()
    for rel in out.splitlines():
        rel = rel.strip()
        if not rel or rel in seen or not backlog_svc.is_backlog_path(rel, backlog_dir, backlog_files or ()):
            continue
        seen.add(rel)
        rels.append(rel)
    rels.sort(key=lambda r: (r.count("/"), r.lower()))  # shallowest (repo-root) first
    return rels


def _stage_of(ws: Workspace | None) -> str:
    """The gate's queue, made visible: derive one lifecycle stage per backlog item
    from its seeded workspace, mirroring the gate's own states so an item's status
    IS its gate status (backlog-redesign-plan.md §4) rather than a separate signal
    that can drift from it. No workspace → "ready" (startable); `archived` also
    reads "ready" — most archives remove the workspace from the store outright, but
    a workspace that lingers in the store as `archived` must not shadow a live one
    sharing its seed_key. `merged` is checked next, ahead of both the
    gate states AND `queued`, because a merged workspace's denormalized `gate`
    field can still read stale `gate_green` from before the merge — merged must win
    outright. `queued` is checked before gate_red/gate_green (not after): a
    follow-up run queued behind `[agent] max_parallel` on an already-gated
    workspace leaves `Workspace.status` untouched until it acquires its slot
    (runner._spawn_slot), so a stale green/red must not win over "another run is
    about to change this" — a `stage: "green"` would otherwise deep-link ④ ship
    onto a workspace an agent is mid-edit on.
    `idle`/`setting_up`/`broken` fall back to "running": each is a brief transient
    or an already-surfaced problem state (the workspace card has its own "broken"
    badge), not worth a distinct backlog-stage bucket the plan doesn't ask for."""
    if ws is None or ws.status == WorkspaceStatus.archived:
        return "ready"
    if ws.status == WorkspaceStatus.merged:
        return "shipped"
    run = store.latest_run(ws.id)
    if run is not None and run.status == AgentRunStatus.queued:
        return "queued"
    if ws.status == WorkspaceStatus.gate_red:
        return "red"
    if ws.status == WorkspaceStatus.gate_green:
        return "green"
    return "running"


@app.get("/projects/{project_id}/todo")
async def get_todo(project_id: str) -> dict:
    """The project's backlog: every backlog doc in the repo (files under the
    ``backlog/`` folder, plus any todo-named file — TODO.md, docs/todo.md, …), each
    parsed into an ordered list of ``blocks`` (notes + ``- [ ]`` items) and returned
    as its own tab. A todo flips to done when an agent's branch merges the tick back
    to main. Feeds the Backlog panel, which re-fetches on merge/gate events.

    Each file carries ``items`` (the seedable tasks), ``blocks`` (notes + items in
    document order, for the interleaved render) and ``content`` (the raw markdown,
    for the in-app editor). Each item also carries ``seed_key`` (its stable id) and
    ``seeded_workspace`` (the id of a live workspace already started from it, or
    None) — the UI flags a seeded item "in progress" so it isn't clicked into a
    duplicate."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    root = Path(project.path)
    settings = load_project_settings(project.path)
    rels = await _discover_todo_files(project.path, settings.backlog_dir, settings.backlog_files)
    # Live workspaces seeded from a backlog item, keyed by that item's seed_key.
    # `seeded_all` drives `stage` (a merged-but-not-archived workspace still counts,
    # so its item reads "shipped" rather than silently vanishing); `seeded` is the
    # narrower in-progress LOCK the UI uses to block a duplicate start — merged (and
    # archived, though those are already gone from the store) are excluded from it
    # explicitly rather than relying on eventual archival to release the lock, since
    # a merge doesn't archive on its own (the user archives on their own terms).
    seeded_all: dict[str, Workspace] = {
        ws.seed_key: ws
        for ws in store.workspaces.values()
        if ws.project_id == project_id and ws.seed_key
    }
    seeded = {
        key: ws.id
        for key, ws in seeded_all.items()
        if ws.status not in (WorkspaceStatus.merged, WorkspaceStatus.archived)
    }
    # Tab label = basename, but disambiguate to the full relative path when two
    # files share a basename (e.g. frontend/TODO.md vs backend/TODO.md).
    bases = [r.rsplit("/", 1)[-1] for r in rels]
    files: list[dict] = []
    claimed: set[str] = set()  # every seed_key still matched by a current item
    for rel, base in zip(rels, bases):
        try:
            text = (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        blocks = _parse_todo_doc(text)
        # Item blocks are the same dict refs in ``items``, so enriching them here
        # also enriches the interleaved ``blocks`` the detail pane renders from.
        items = [b for b in blocks if b["kind"] == "item"]
        for it in items:
            it["seed_key"] = f"{rel}::{it['text']}"
            it["seeded_workspace"] = seeded.get(it["seed_key"])
            it["stage"] = _stage_of(seeded_all.get(it["seed_key"]))
            claimed.add(it["seed_key"])
        done = sum(1 for it in items if it["done"])
        files.append(
            {
                "path": rel,
                "label": rel if bases.count(base) > 1 else base,
                "items": items,
                "blocks": blocks,
                "content": text,
                "done": done,
                "pending": len(items) - done,
            }
        )
    # C5: a workspace whose seed_key matches no current item lost its source
    # (edited/removed without the one-for-one rename `put_todo` remaps, the file
    # itself was deleted, or a `[backlog] files` glob change dropped it from
    # discovery) — surfaced here rather than silently dropping it, so the
    # dashboard card can say what happened instead of just looking unseeded.
    # Excludes "issue:<n>" keys (a different, unrelated seed shape) but otherwise
    # doesn't require the file to still be *discovered*: a deleted/un-globbed file
    # is exactly the case most worth surfacing, not the one to stay silent on.
    orphaned = [
        {"workspace_id": ws.id, "seed_key": key}
        for key, ws in seeded_all.items()
        if key not in claimed and "::" in key and not key.startswith("issue:")
    ]
    return {"files": files, "orphaned": orphaned}


@app.put("/projects/{project_id}/todo")
async def put_todo(project_id: str, req: TodoWriteRequest) -> dict:
    """Create or overwrite a backlog markdown file from the in-app editor. The path
    must be backlog-eligible (under the project's backlog folder, or a todo-named
    doc) and stay inside the project — see ``backlog.write_todo``. Writes into the
    project checkout in place; the fs watcher re-fires ``backlog_changed`` so the
    panel refreshes. Committing the change is the project's own git workflow."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    settings = load_project_settings(project.path)

    # C5: a live workspace's seed_key is the item's literal text at seed time. If
    # this edit renames exactly one item (typo fix, wording tweak) with no other
    # add/remove, remap that workspace's seed_key to the new text so it doesn't fall
    # out of the in-progress lock mid-run. Any messier edit is left alone — the
    # workspace just falls back to unseeded (stage "ready") rather than guessing wrong.
    old_texts: set[str] | None = None
    safe_rel: str | None = None
    try:
        safe_rel = backlog_svc._safe_rel(req.path)
        old_raw = (Path(project.path) / safe_rel).read_text(encoding="utf-8", errors="replace")
        old_texts = {b["text"] for b in _parse_todo_doc(old_raw) if b["kind"] == "item"}
    except (backlog_svc.BacklogError, OSError):
        pass

    try:
        written = backlog_svc.write_todo(
            project.path, req.path, req.content,
            backlog_dir=settings.backlog_dir, extra_globs=settings.backlog_files,
        )
    except backlog_svc.BacklogError as e:
        raise HTTPException(400, str(e))
    except OSError as e:
        raise HTTPException(500, f"could not write {req.path}: {e}")

    if old_texts is not None:
        new_texts = {b["text"] for b in _parse_todo_doc(req.content) if b["kind"] == "item"}
        removed = old_texts - new_texts
        added = new_texts - old_texts
        if len(removed) == 1 and len(added) == 1:
            old_key = f"{written}::{next(iter(removed))}"
            new_key = f"{written}::{next(iter(added))}"
            remapped = False
            for ws in store.workspaces.values():
                if ws.project_id == project_id and ws.seed_key == old_key:
                    ws.seed_key = new_key
                    remapped = True
            # Persist the remap: it mutates a Workspace field, not the markdown file
            # itself, so without this a restart before the next snapshot would revert
            # it and the item would fall back to unseeded/orphaned.
            if remapped:
                await db.save_snapshot(store)

    return {"ok": True, "path": written}


@app.post("/projects/{project_id}/todo/items")
async def add_todo_item(project_id: str, req: TodoItemAppendRequest) -> dict:
    """Append one "send to backlog" follow-up (backlog-redesign-plan.md Move 3) — a
    failing test, a mutation survivor, an untested hunk, a refuter finding, or a
    review comment — as a new ``- [ ] <title> (<evidence>)`` line. Defaults to
    ``<[backlog] dir>/follow-ups.md`` (computed against THIS project's own config,
    not a hard-coded literal — a project with a custom `dir` would otherwise 400 on
    every "send to backlog" button) rather than the seed file of the producing
    workspace, so residue is never buried in a spec doc. Same backlog-eligibility
    guard as ``PUT /todo``; the fs watcher's ``backlog_changed`` picks it up live."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    settings = load_project_settings(project.path)
    if not req.title.strip():
        raise HTTPException(400, "title is required")
    file = req.file or f"{settings.backlog_dir}/follow-ups.md"
    try:
        written = backlog_svc.append_item(
            project.path, file, req.title, req.evidence,
            backlog_dir=settings.backlog_dir, extra_globs=settings.backlog_files,
        )
    except backlog_svc.BacklogError as e:
        raise HTTPException(400, str(e))
    except OSError as e:
        raise HTTPException(500, f"could not write {req.file}: {e}")
    return {"ok": True, "path": written}


@app.get("/projects/{project_id}/issues")
async def get_issues(
    project_id: str, refresh: bool = False, state: str | None = None, mine: bool | None = None
) -> dict:
    """GitHub issues for the project, as a second backlog tab.

    Read live via ``gh`` (never persisted — GitHub is the source of truth); a
    clicked issue seeds a workspace through the same path a todo does, linked back
    by ``seed_key = "issue:<number>"`` so the in-progress guard / click-to-jump
    work unchanged. Refetches on the same status/gate events as the todo tab
    (bounded by a short TTL server-side); ``refresh=1`` is the ⟳ force-refresh.

    ``state`` (open|closed|all) defaults to the project's `[backlog] issue_state`
    when omitted. ``mine`` is tri-state, not a plain bool: omitted (the query param
    absent entirely) falls back to the project's configured `issue_assignee`, but
    ``true``/``false`` are explicit UI overrides (@me / anyone) that WIN over that
    config regardless of what it's set to — so a project that opted into
    `issue_assignee = "@me"` can still flip to "All assignees" in the UI, and the
    toggle's label always matches what's actually being asked for.

    Degrades gracefully: no remote / no ``gh`` → ``available: False`` (empty
    state); offline / rate-limited → the last good fetch stamped ``fetched_at``."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    settings = load_project_settings(project.path)
    eff_state = state if state in ("open", "closed", "all") else settings.issue_state
    eff_assignee = settings.issue_assignee if mine is None else ("@me" if mine else "")
    result = await issues_svc.list_issues(
        project.path, force=refresh, state=eff_state, assignee=eff_assignee, limit=settings.issue_limit
    )
    # Same in-progress linkage the todo tab uses: an issue seeded into a live
    # workspace shows ◐ and jumps to it instead of starting a duplicate. See
    # `_stage_of` / get_todo for why `seeded_all` (stage) and `seeded` (the lock,
    # merged/archived excluded) are two different maps.
    seeded_all = {
        ws.seed_key: ws
        for ws in store.workspaces.values()
        if ws.project_id == project_id and ws.seed_key
    }
    seeded = {
        key: ws.id
        for key, ws in seeded_all.items()
        if ws.status not in (WorkspaceStatus.merged, WorkspaceStatus.archived)
    }
    for it in result.get("issues", []):
        it["seed_key"] = f"issue:{it['number']}"
        it["seeded_workspace"] = seeded.get(it["seed_key"])
        it["stage"] = _stage_of(seeded_all.get(it["seed_key"]))
    return result


@app.get("/projects/{project_id}/issues/{number}")
async def get_issue_detail(project_id: str, number: int) -> dict:
    """Full detail (body + comments + labels) for a single GitHub issue, fetched
    on demand when a backlog row is expanded. Read live via ``gh issue view``
    (never persisted — GitHub is the source of truth), same degrade story as the
    list: no remote / no ``gh`` → ``available: False`` with a reason."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return await issue_detail_svc.view_issue(project.path, number)


@app.get("/fs")
async def browse_fs(path: str | None = None) -> dict:
    """Directory browser for the 'add project' folder picker. Confined to
    ``settings.browse_root`` (your repos dir) so it can't wander the filesystem.
    Marks which folders are git repos so the UI can offer them as projects."""
    root = Path(settings.browse_root).expanduser().resolve()
    try:
        target = Path(path).expanduser().resolve() if path else root
    except (OSError, ValueError, RuntimeError):
        target = root
    # clamp within the browse root
    if target != root and root not in target.parents:
        target = root

    entries: list[dict] = []
    try:
        for child in sorted(target.iterdir(), key=lambda c: c.name.lower()):
            if child.is_dir() and not child.name.startswith("."):
                entries.append(
                    {
                        "name": child.name,
                        "path": str(child),
                        "is_git_repo": (child / ".git").exists(),
                    }
                )
    except OSError:
        pass

    return {
        "root": str(root),
        "path": str(target),
        "parent": None if target == root else str(target.parent),
        "is_git_repo": (target / ".git").exists(),
        "entries": entries,
    }


@app.post("/fs/mkdir")
async def mkdir_fs(req: MkdirRequest) -> dict:
    """Create a new sub-folder for a fresh project. Confined to ``browse_root``
    (same clamp as the browser) so it can't create dirs anywhere on disk."""
    root = Path(settings.browse_root).expanduser().resolve()
    try:
        parent = Path(req.parent).expanduser().resolve()
    except (OSError, ValueError, RuntimeError):
        raise HTTPException(400, "invalid parent folder")
    if parent != root and root not in parent.parents:
        raise HTTPException(400, "parent is outside the browse root")
    name = req.name.strip().strip("/")
    if not name or "/" in name or name.startswith("."):
        raise HTTPException(400, "invalid folder name")
    target = parent / name
    try:
        target.mkdir(parents=False, exist_ok=False)
    except FileExistsError:
        raise HTTPException(409, f"'{name}' already exists here")
    except OSError as exc:
        raise HTTPException(400, f"mkdir failed: {exc}")
    return {"path": str(target), "name": name, "parent": str(parent)}


# --------------------------------------------------------------------------- #
# Workspaces
# --------------------------------------------------------------------------- #
async def _unique_slug(project: Project, base_slug: str) -> tuple[str, int]:
    """First slug not already taken by a worktree dir or a ``haro/<slug>`` branch.

    Two backlog items with the same title slugify to the same string, which would
    collide on both the worktree path (a hard 409) and the git branch (``add_worktree``
    fails). Rather than reject the second pickup, bump the slug ``foo`` → ``foo-2`` →
    ``foo-3`` until it's free — mirroring ``_next_branch``'s approach for the continue
    flow, but at creation and across BOTH namespaces. Returns ``(slug, suffix)`` where
    ``suffix`` is 0 when the base was already free (so the caller can tell the user a
    duplicate was auto-renamed)."""
    branches = set(await git_ops.list_branches(project.path))

    def taken(s: str) -> bool:
        return store.worktree_path(project, s).exists() or f"haro/{s}" in branches

    if not taken(base_slug):
        return base_slug, 0
    n = 2
    while taken(f"{base_slug}-{n}"):
        n += 1
    return f"{base_slug}-{n}", n


async def _seed_workspace(
    *,
    project: Project,
    name: str,
    base_ref: str | None = None,
    branch: str | None = None,
    seed_key: str | None = None,
    mode: WorkspaceMode = "agent",
    start_from_test: bool = False,
) -> Workspace:
    """Create one workspace: unique slug → worktree → seeded secrets/includes → port
    → background setup. The whole "seed machinery", extracted from the REST handler.

    Extracted from the REST handler so every caller shares one seed path.
    """
    # Derive a collision-free slug: a duplicate backlog title would otherwise reuse an
    # existing worktree dir + branch. When we bump it (suffix > 0), reflect the same
    # counter in the display name so the two sidebar rows are distinguishable and the
    # UI can flag that a same-titled task already existed.
    slug, suffix = await _unique_slug(project, git_ops.slugify(name))
    name = f"{name} ({suffix})" if suffix else name
    branch = branch or f"haro/{slug}"
    worktree_path = store.worktree_path(project, slug)

    # Choose the base to branch from. With a remote, integrate() merges into
    # `origin/<default>` (via a gh PR), NOT local <default> — so basing a new
    # workspace off local <default> would be born missing already-merged work as
    # that branch drifts behind origin. Fetch and branch off the remote tip instead.
    # An explicit base_ref (e.g. "new workspace from branch X") always wins;
    # offline / no-remote falls back to the local default branch.
    if not base_ref:
        base_ref = project.default_branch
        if await git_ops.has_remote(project.path):
            try:
                await git_ops.fetch(project.path)
                remote_ref = f"origin/{project.default_branch}"
                if await git_ops.ref_exists(project.path, remote_ref):
                    base_ref = remote_ref
            except git_ops.GitError:
                pass  # offline / auth failure — keep the local default branch

    if worktree_path.exists():
        raise HTTPException(409, f"worktree path already exists: {worktree_path}")

    try:
        await git_ops.add_worktree(project.path, worktree_path, branch, base_ref)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git worktree add failed: {exc.stderr}") from exc

    psettings = load_project_settings(project.path)

    # A worktree is a clean checkout — gitignored files from the main repo never land
    # in it. Seed the dedicated `.haro/.env` first, then copy any `[files] include`
    # globs (`.env*` by default, plus `.npmrc`/certs/etc.) from the checkout, so
    # setup/run/tests that read secrets or private-registry auth work in a fresh
    # workspace. Both run before setup; the glob copy never clobbers the `.env` seed.
    seed_worktree_env(project.path, str(worktree_path))
    copy_worktree_includes(project.path, str(worktree_path), psettings.include_files)

    port = store.allocate_port(*psettings.port_range)

    ws = Workspace(
        project_id=project.id,
        name=name,
        branch=branch,
        worktree_path=str(worktree_path),
        base_ref=base_ref,
        port=port,
        status=WorkspaceStatus.setting_up,
        seed_key=seed_key,
        mode=mode,
        start_from_test=start_from_test and mode == "manual",
    )
    store.add_workspace(ws)
    await db.save_snapshot(store)

    # Write-back on pickup: when this workspace was seeded from a GitHub issue
    # (seed_key "issue:<n>") and the project opted in, announce the pickup on GitHub
    # so a teammate doesn't grab the same issue. Fire-and-forget + best-effort — a
    # network call must not block or fail workspace creation, and reads stay live.
    if psettings.issue_writeback and (ws.seed_key or "").startswith("issue:"):
        try:
            number = int(ws.seed_key.split(":", 1)[1])
        except (ValueError, IndexError):
            number = None
        if number is not None:
            _detach(issues_svc.write_back_on_pickup(project.path, number))

    # Provision the worktree in the background (setup script, or deps fallback);
    # the workspace goes idle when it's ready. Tracked under SETUP_SESSION so a run
    # fired during setup is HELD by runner.run_agent until it finishes (it used to be
    # refused here, which pushed the wait onto the client — see start_agent).
    store.set_active_task(ws.id, SETUP_SESSION, asyncio.create_task(
        run_setup(store=store, hub=hub, workspace=ws, project=project, psettings=psettings)
    ))
    return ws


@app.post("/projects/{project_id}/workspaces", response_model=Workspace)
async def create_workspace(project_id: str, req: CreateWorkspaceRequest) -> Workspace:
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return await _seed_workspace(
        project=project,
        name=req.name,
        base_ref=req.base_ref,
        branch=req.branch,
        seed_key=req.seed_key,
        mode=req.mode or "agent",
        start_from_test=req.start_from_test,
    )


@app.post("/projects/{project_id}/workspaces/adopt", response_model=Workspace)
async def adopt_workspace(project_id: str, req: AdoptWorkspaceRequest) -> Workspace:
    """Adopt an existing foreign worktree as a workspace — the ``create_workspace``
    path minus ``git_ops.add_worktree`` (backlog/merge-firewall.md §1). The worktree
    already exists on disk (a native Claude Code / claude-squad / tmux checkout), so
    we only *register* it: derive its branch + base from git, allocate a port, and
    snapshot with ``kind="adopted"`` (§1). It then runs the **exact create-path
    provisioning** (§2) — ``seed_worktree_env`` + ``copy_worktree_includes`` then
    ``run_setup`` under SETUP_SESSION — so a foreign worktree that lacks haro's
    environment doesn't gate red for *deps* reasons and make the firewall cry wolf."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")

    # Re-scan git's own worktree list and match the requested path — the client sends
    # a path, but the branch and the "is it genuinely foreign" verdict come from git,
    # never from the request. Reuses the exact filter list_foreign_worktrees applies.
    # `tracked` spans EVERY project, not just this one: nothing dedupes projects by
    # path, so the same repo can be registered twice, and since an untracked worktree
    # under haro's own root is now adoptable (orphan recovery), scoping this to one
    # project would let project B adopt project A's still-live worktree out from
    # under it.
    target = git_ops._norm_path(req.path)
    tracked = [ws.worktree_path for ws in store.list_workspaces()]
    try:
        rows = await git_ops.list_worktrees(project.path, tracked_paths=tracked)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git worktree list failed: {exc.stderr}") from exc

    row = next((r for r in rows if git_ops._norm_path(r["path"]) == target), None)
    if row is None:
        raise HTTPException(404, f"no git worktree at {req.path}")
    if row["tracked"]:
        raise HTTPException(409, "worktree is already a haro workspace")
    if git_ops._norm_path(row["path"]) == git_ops._norm_path(project.path):
        raise HTTPException(400, "not a foreign worktree (the main checkout)")
    if row["bare"] or row["detached"] or not row["branch"]:
        raise HTTPException(400, "cannot adopt a bare or detached worktree: no branch to gate")

    branch = row["branch"]

    # Same remote-aware base as create_workspace: with a remote, integrate() merges
    # into `origin/<default>`, so gate diffs (coverage/impact) must base off the
    # remote tip, not a local default that may have drifted. Offline / no-remote
    # falls back to the local default branch.
    base_ref = project.default_branch
    if await git_ops.has_remote(project.path):
        try:
            await git_ops.fetch(project.path)
            remote_ref = f"origin/{project.default_branch}"
            if await git_ops.ref_exists(project.path, remote_ref):
                base_ref = remote_ref
        except git_ops.GitError:
            pass  # offline / auth failure — keep the local default branch

    psettings = load_project_settings(project.path)

    # Same provisioning as create_workspace (backlog/merge-firewall.md §2, the cry-wolf
    # fix): a foreign worktree lacks haro's environment, so gating it cold would fail on
    # missing deps/secrets and the merge firewall would flag *environment* as a red
    # verdict. Seed the dedicated `.haro/.env`, then copy `[files] include` globs — both
    # non-clobbering (only fill missing files), so the foreign tool's own `.env`/certs
    # survive. `run_setup` (queued below) then runs the setup script or deps fallback;
    # its `gate.ensure_deps` no-ops when the worktree already has a real node_modules,
    # so a foreign tool's own install is never clobbered by the symlink stopgap (§ line 44).
    seed_worktree_env(project.path, row["path"])
    copy_worktree_includes(project.path, row["path"], psettings.include_files)

    port = store.allocate_port(*psettings.port_range)

    ws = Workspace(
        project_id=project.id,
        name=req.name or branch,
        branch=branch,
        worktree_path=row["path"],
        base_ref=base_ref,
        port=port,
        status=WorkspaceStatus.setting_up,
        kind="adopted",
        source=_guess_worktree_source(row["path"], under_worktree_root=row["under_worktree_root"]),
    )
    store.add_workspace(ws)
    # It's now tracked, so drop it from the "adoptable" hint immediately (the next
    # scan would prune it anyway, but this keeps the count honest without a rescan).
    remaining = [r for r in store.adoptable.get(project.id, []) if r["path"] != row["path"]]
    store.update_adoptable(project.id, remaining)
    await db.save_snapshot(store)

    # Provision in the background exactly like create_workspace: setup script or deps
    # fallback, tracked under SETUP_SESSION so a later auto-gate/agent run waits for it.
    # The workspace flips setting_up → idle when ready (run_setup's `finally`), and the
    # deps chip lights up via store.setup_state.
    store.set_active_task(ws.id, SETUP_SESSION, asyncio.create_task(
        run_setup(store=store, hub=hub, workspace=ws, project=project, psettings=psettings)
    ))
    return ws


@app.get("/projects/{project_id}/branches")
async def list_branches(project_id: str) -> dict:
    """Branches to seed a new workspace from.

    When a remote is connected, list *remote* branches (``origin/*``) and default to
    ``origin/<default>`` — a workspace should branch off the integrated remote tip,
    not a local branch that may have drifted behind (this is the UI half of Option
    A; `create_workspace` handles the empty-base_ref case). Local-only repos keep
    listing local branches. Best-effort ``fetch`` first so the list is current."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    try:
        if await git_ops.has_remote(project.path):
            try:
                await git_ops.fetch(project.path)
            except git_ops.GitError:
                pass  # offline / auth failure — show whatever tracking refs we have
            remotes = await git_ops.list_remote_branches(project.path)
            if remotes:
                default = f"origin/{project.default_branch}"
                if default not in remotes:
                    default = remotes[0]
                return {"branches": remotes, "default": default}
        branches = await git_ops.list_branches(project.path)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git branch failed: {exc.stderr}") from exc
    return {"branches": branches, "default": project.default_branch}


def _guess_worktree_source(path: str, *, under_worktree_root: bool = False) -> str:
    """Best-guess which tool created a foreign worktree, from its path alone — a
    display hint for the adopt UI (backlog/merge-firewall.md §1), never load-bearing.
    Claude Code's native sessions live under ``.claude/worktrees/``; claude-squad
    stamps ``claude-squad`` into its worktree home. A worktree already living under
    haro's OWN worktree root is a desynced haro workspace, not an external tool's
    checkout — tag it ``orphaned`` rather than guessing. Anything else is ``unknown``."""
    if under_worktree_root:
        return "orphaned"
    p = path.replace("\\", "/").lower()
    if "/.claude/worktrees/" in p or p.endswith("/.claude/worktrees"):
        return "claude-code"
    if "claude-squad" in p:
        return "claude-squad"
    return "unknown"


async def _scan_foreign_worktrees(project: Project) -> list[dict]:
    """Scan one project's repo for foreign (unadopted) git worktrees, each tagged
    with a best-guess ``source`` — the Merge Firewall's adopt candidates
    (backlog/merge-firewall.md §1). Shared by the on-demand scan endpoint and the
    boot/on-demand rescan (``reconcile_adoptable``).

    Runs ``git worktree list`` and drops every row haro already governs: workspaces
    it currently manages (``tracked``), the repo's own main checkout, and bare
    entries. A row under haro's own worktree root (``under_worktree_root``) that is
    NOT tracked is an ORPHAN — a workspace the store lost (e.g. a create that never
    made it into a persisted snapshot before the app quit) — not a live haro
    workspace, so it's surfaced too (tagged ``orphaned``) rather than silently
    dropped; without this a lost workspace's worktree/branch could never be
    reclaimed or freed for reuse from the UI. What's left otherwise is genuinely
    foreign — a native Claude Code / claude-squad / tmux checkout. Read-only: it
    only *surfaces* candidates; nothing is ever auto-adopted. Raises
    ``git_ops.GitError``.

    ``tracked`` spans EVERY project, not just this one — nothing dedupes projects
    by path, so the same repo can be registered twice, and since an untracked
    worktree under the root is now adoptable, scoping this to one project would
    let project B's scan list (and adopt) project A's still-live worktree."""
    tracked = [ws.worktree_path for ws in store.list_workspaces()]
    rows = await git_ops.list_worktrees(project.path, tracked_paths=tracked)
    main_checkout = git_ops._norm_path(project.path)
    return [
        {**row, "source": _guess_worktree_source(row["path"], under_worktree_root=row["under_worktree_root"])}
        for row in rows
        if not row["tracked"]
        and not row["bare"]
        and git_ops._norm_path(row["path"]) != main_checkout
        and not baseline_svc.is_baseline_worktree(row["path"])
    ]


async def reconcile_adoptable(store: Store) -> list[str]:
    """Rescan every project for foreign (unadopted) worktrees and refresh the
    per-project "adoptable" hint (``store.adoptable``) — the Merge Firewall's
    boot-time rescan, following the ``db.reconcile(store)`` precedent
    (backlog/merge-firewall.md §1).

    Called from ``lifespan`` on boot: it seeds the baseline (so a later on-demand
    scan can detect what *newly* appeared) and returns human-readable notes the boot
    log prints, exactly like ``db.reconcile`` / ``db.mark_broken``. Deliberately
    **silent** — no global broadcast: no client is connected yet, and every foreign
    worktree would read as "new" against the empty baseline. Live "a foreign
    worktree just appeared" hints ride the on-demand path (``list_foreign_worktrees``).
    A project whose git scan fails is noted and skipped, never fatal to boot."""
    notes: list[str] = []
    for project in store.list_projects():
        try:
            rows = await _scan_foreign_worktrees(project)
        except git_ops.GitError as exc:
            notes.append(f"scan failed for '{project.name}': {exc.stderr.strip()}")
            continue
        store.update_adoptable(project.id, rows)
        if rows:
            notes.append(f"'{project.name}': {len(rows)} adoptable worktree(s)")
    return notes


@app.get("/projects/{project_id}/worktrees")
async def list_foreign_worktrees(project_id: str) -> dict:
    """Foreign (unadopted) git worktrees in the project's repo — the Merge Firewall's
    adopt candidates (backlog/merge-firewall.md §1). This is the **on-demand rescan**:
    every call re-scans ``git worktree list`` (no cache), refreshes the per-project
    ``store.adoptable`` baseline, and — when a foreign worktree has *newly appeared*
    since the last scan — broadcasts an ``adoptable`` hint on the global feed so any
    open client lights up without polling. Read-only: nothing is ever auto-adopted."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    try:
        foreign = await _scan_foreign_worktrees(project)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git worktree list failed: {exc.stderr}") from exc

    new = store.update_adoptable(project.id, foreign)
    if new:
        await hub.broadcast_global({
            "channel": "notify",
            "kind": "adoptable",
            "project_id": project.id,
            "count": len(foreign),
            "new": [
                {"path": r["path"], "branch": r["branch"], "source": r["source"]}
                for r in new
            ],
        })
    return {"worktrees": foreign}


@app.get("/firewall/verdict", response_model=FirewallVerdict)
async def firewall_verdict(repo: str, branch: str) -> FirewallVerdict:
    """Merge Firewall verdict oracle (backlog/merge-firewall.md §3): the repo-level
    git hook curls this to decide whether a push/merge of ``branch`` in ``repo`` may
    proceed. It only *reports* — blocking is the hook + ``[trust]`` config's call.

    Project matched by path (the hook knows its repo dir, not haro's project id;
    ``git_ops._norm_path`` resolves symlinks so worktree/store path strings compare
    equal), workspace by branch (one branch = one worktree per project). ``green`` ⇔
    the workspace's ``status == gate_green`` (which already reflects
    ``gate_merge_result`` and, later, the Double Gate); ``red`` ⇔ the gate ran and
    isn't green; ``unknown`` ⇔ no governed workspace for that (repo, branch) or it
    has no gate verdict yet. Reads the denormalized ``Workspace.gate`` off the store
    — no git/disk call — so the hook's ``--max-time 2`` curl stays fast."""
    target = git_ops._norm_path(repo)
    project = next(
        (p for p in store.list_projects() if git_ops._norm_path(p.path) == target),
        None,
    )
    if project is None:
        return FirewallVerdict(verdict="unknown")

    ws = next(
        (w for w in store.list_workspaces(project.id) if w.branch == branch),
        None,
    )
    if ws is None:
        return FirewallVerdict(verdict="unknown")

    if ws.status == WorkspaceStatus.gate_green:
        verdict = "green"
    elif ws.status == WorkspaceStatus.gate_red:
        verdict = "red"
    else:
        verdict = "unknown"
    return FirewallVerdict(verdict=verdict, workspace_id=ws.id, gate=ws.gate)


async def _disarm_firewall(project: Project) -> FirewallInstallResult:
    """Disarm the Merge Firewall for ``project``: persist posture ``off`` (repo policy,
    so the committed ``settings.toml``) and strip the hook — our fenced block off a
    chained foreign hook, or a slot we wholly own — plus clear ``haro.url``/``haro.strict``.

    Shared by ``POST …/firewall`` with ``firewall="off"`` and the dedicated
    ``DELETE …/firewall`` uninstall, so the two disarm paths can never drift. The
    removal is pure file edits + a ``git config`` unset (``firewall.uninstall_hooks``)
    and never consults gate/verdict state — which, with the hook's fail-open default,
    is what guarantees a stopped or uninstalled haro can't brick a merge."""
    config_path = write_project_firewall(project.path, firewall="off", strict=False)
    try:
        hooks = await firewall_svc.uninstall_hooks(project.path)
    except (OSError, git_ops.GitError) as exc:
        raise HTTPException(500, f"firewall hook uninstall failed: {exc}")
    return FirewallInstallResult(
        firewall="off", strict=False, hooks=hooks, config_path=config_path
    )


@app.post("/projects/{project_id}/firewall", response_model=FirewallInstallResult)
async def install_firewall(
    project_id: str, req: FirewallInstallRequest
) -> FirewallInstallResult:
    """Arm the Merge Firewall (backlog/merge-firewall.md §3): persist the ``[trust]``
    posture, then install (or remove) the repo-level git hook + its ``git config``.

    The posture is repo policy, so it's persisted to the committed ``settings.toml``.
    Enforcement lives in the hook + config, not the setting: ``warn``/``block`` write
    the hook into the shared hooks dir (one install governs every worktree) and set
    ``haro.strict`` — the *effective* strict is ``req.strict or firewall == "block"``,
    since the shipped hook posture is expressed purely through ``haro.strict``; ``off``
    disarms (via ``_disarm_firewall``, shared with ``DELETE``) by stripping exactly what
    we installed. A foreign hook (husky et al. via ``core.hooksPath``) is chained onto,
    never clobbered, so there is no conflict path."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")

    if req.firewall == "off":
        return await _disarm_firewall(project)

    config_path = write_project_firewall(
        project.path, firewall=req.firewall, strict=req.strict
    )
    effective_strict = req.strict or req.firewall == "block"
    try:
        hooks = await firewall_svc.install_hooks(
            project.path,
            backend_url=(req.backend_url or "").strip() or firewall_svc.DEFAULT_BACKEND_URL,
            strict=effective_strict,
        )
    except (OSError, git_ops.GitError) as exc:
        raise HTTPException(500, f"firewall hook install failed: {exc}")

    return FirewallInstallResult(
        firewall=req.firewall,
        strict=effective_strict,
        hooks=hooks,
        config_path=config_path,
    )


@app.delete("/projects/{project_id}/firewall", response_model=FirewallInstallResult)
async def uninstall_firewall(project_id: str) -> FirewallInstallResult:
    """Uninstall the Merge Firewall in one command (backlog/merge-firewall.md §3).

    The idempotent, body-less counterpart to ``POST …/firewall``: DELETE is the natural
    verb for "make it gone", carries no posture payload, and is safe to call when nothing
    is installed (``uninstall_hooks`` no-ops per slot). Removes exactly what we wrote —
    our fenced block from a chained foreign hook (husky et al. left byte-identical), or a
    hook file we wholly own — plus ``haro.url``/``haro.strict``.

    Uninstall is pure file edits + a ``git config`` unset and never reads gate state, so
    it works with the backend otherwise idle; together with the hook's fail-open default
    it upholds the product's core promise: a stopped or removed haro can never brick a
    merge."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return await _disarm_firewall(project)


@app.get("/projects/{project_id}/remote", response_model=RemoteConfig)
async def get_project_remote(project_id: str) -> RemoteConfig:
    """The project's `origin` remote URL (shared by all its worktrees), or null."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    url = await git_ops.get_remote(project.path)
    return RemoteConfig(url=url, web_url=git_ops.web_url_from_remote(url))


@app.put("/projects/{project_id}/remote", response_model=RemoteConfig)
async def set_project_remote(project_id: str, req: RemoteUpdateRequest) -> RemoteConfig:
    """Link the repo to a git remote (or unlink with an empty url). Sets `origin`
    in the shared `.git`, so every workspace inherits it for push / `gh` PR merges."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    url = req.url.strip()
    try:
        if url:
            await git_ops.set_remote(project.path, url)
        else:
            await git_ops.remove_remote(project.path)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git remote failed: {exc.stderr}") from exc
    project.remote_url = url or None  # keep the cached field in sync for the sidebar badge
    await db.save_snapshot(store)
    return RemoteConfig(url=url or None)


@app.put("/projects/{project_id}/default-branch", response_model=Project)
async def set_default_branch(project_id: str, req: DefaultBranchRequest) -> Project:
    """Set the base branch new worktrees branch from. `create_workspace` seeds a new
    worktree off `project.default_branch` (as `origin/<default>` when a remote is
    linked), so this is the project-wide base for every future workspace. Stored bare
    (any `origin/` prefix from the remote branch list is stripped)."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    branch = req.branch.strip()
    if branch.startswith("origin/"):
        branch = branch[len("origin/"):]
    if not branch:
        raise HTTPException(400, "branch is required")
    project.default_branch = branch
    await db.save_snapshot(store)
    return project


@app.get("/projects/{project_id}/workflow", response_model=WorkflowConfig)
async def get_project_workflow(project_id: str) -> WorkflowConfig:
    """The project's `[workflow]` ship policy (merge_mode) for the Git settings tab."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return WorkflowConfig(merge_mode=load_project_settings(project.path).merge_mode)


@app.put("/projects/{project_id}/workflow", response_model=WorkflowConfig)
async def set_project_workflow(
    project_id: str, req: WorkflowUpdateRequest
) -> WorkflowConfig:
    """Set `[workflow] merge_mode` — which ship actions the ④ step offers (PR / merge /
    both). A targeted write that preserves the project's other config tables."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    write_project_merge_mode(project.path, req.merge_mode, target=req.target)
    return WorkflowConfig(merge_mode=load_project_settings(project.path).merge_mode)


_GATE_RUNNERS = ("vitest", "pytest", "command", "offense")


def _gate_config(project_path: str) -> GateConfig:
    """Build the Gate-tab config from the project's effective settings, mapping the
    internal empty-string runner default back to the explicit ``vitest`` the UI shows."""
    s = load_project_settings(project_path)
    return GateConfig(
        runner=s.gate_runner if s.gate_runner in _GATE_RUNNERS else "vitest",
        command=s.gate_command,
        format=s.gate_format,
        gate_dir=s.gate_dir,
        default_scope=s.gate_default_scope,  # type: ignore[arg-type]
        merge_result=s.gate_merge_result,
        flaky_rerun=s.flaky_rerun,
        coverage_guard=s.coverage_guard,  # type: ignore[arg-type]
        coverage_tolerance=s.coverage_tolerance,
        tamper_alarm=s.tamper_alarm,  # type: ignore[arg-type]
        code_to_check=s.code_to_check,  # type: ignore[arg-type]
        watch=s.gate_watch,
        verified_hunks=s.verified_hunks,
        mutation=s.mutation,
        secrets_scan=s.secrets_scan,
        flaky_retry=s.flaky_retry,
        run_on_save=s.run_on_save,
    )


@app.get("/projects/{project_id}/gate", response_model=GateConfig)
async def get_project_gate(project_id: str) -> GateConfig:
    """The project's `[gate]` config (runner/command/dir/scope/guards) for the Gate
    settings tab — where the §2 stack preset's choice lands and a dev overrides it."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return _gate_config(project.path)


@app.put("/projects/{project_id}/gate", response_model=GateConfig)
async def set_project_gate(project_id: str, req: GateUpdateRequest) -> GateConfig:
    """Set the project's gate config — a targeted `[gate]` (+ `[workflow]` guard)
    write that preserves the project's scripts, ports, and ship-mode policy."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    write_project_gate(
        project.path,
        runner=req.runner,
        command=req.command,
        gate_format=req.format,
        gate_dir=req.gate_dir,
        default_scope=req.default_scope,
        merge_result=req.merge_result,
        flaky_rerun=req.flaky_rerun,
        coverage_guard=req.coverage_guard,
        coverage_tolerance=req.coverage_tolerance,
        tamper_alarm=req.tamper_alarm,
        code_to_check=req.code_to_check,
        watch=req.watch,
        verified_hunks=req.verified_hunks,
        mutation=req.mutation,
        secrets_scan=req.secrets_scan,
        flaky_retry=req.flaky_retry,
        run_on_save=req.run_on_save,
        target=req.target,
    )
    return _gate_config(project.path)


def _agent_config(project_path: str) -> AgentConfig:
    """Build the Agent-tab config from the project's effective settings."""
    s = load_project_settings(project_path)
    model = s.default_model if s.default_model in ("opus", "sonnet", "haiku", "fable") else "sonnet"
    effort = s.default_effort if s.default_effort in ("low", "medium", "high", "xhigh", "max") else ""
    return AgentConfig(
        default_model=model,  # type: ignore[arg-type]
        default_effort=effort,  # type: ignore[arg-type]
        max_budget_usd=s.max_budget_usd,
        cost_warn_usd=s.cost_warn_usd,
        max_parallel=s.max_parallel,
        protect_tests=s.protect_tests,  # type: ignore[arg-type]
        adapter=s.agent_adapter,  # type: ignore[arg-type]
        local_base_url=s.local_base_url,
        local_model=s.local_model,
    )


@app.get("/projects/{project_id}/agent", response_model=AgentConfig)
async def get_project_agent(project_id: str) -> AgentConfig:
    """The project's `[agent]` cost/model guardrails (default model + effort, per-run
    budget ceiling, cumulative cost warning) for the Agent settings tab."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return _agent_config(project.path)


@app.put("/projects/{project_id}/agent", response_model=AgentConfig)
async def set_project_agent(project_id: str, req: AgentUpdateRequest) -> AgentConfig:
    """Set the project's agent defaults — a targeted `[agent]` write that preserves the
    project's scripts, gate, ports, and ship-mode config."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    write_project_agent(
        project.path,
        default_model=req.default_model,
        default_effort=req.default_effort,
        max_budget_usd=req.max_budget_usd,
        cost_warn_usd=req.cost_warn_usd,
        max_parallel=req.max_parallel,
        agent_adapter=req.adapter,
        local_base_url=req.local_base_url,
        local_model=req.local_model,
        target=req.target,
        protect_tests=req.protect_tests,
    )
    return _agent_config(project.path)


def _role_shorthand(cfg) -> str:
    """A ``RoleConfig`` (or ``None``) as the Roles tab's "model:effort" string."""
    if not cfg:
        return ""
    return f"{cfg.model}:{cfg.effort}" if cfg.effort else cfg.model


def _roles_config(project_path: str) -> RolesConfig:
    """Build the Roles-tab config from the project's effective settings."""
    s = load_project_settings(project_path)
    return RolesConfig(
        enabled=s.roles_enabled,
        plan=_role_shorthand(s.role_plan),
        build=_role_shorthand(s.role_build),
        review=_role_shorthand(s.role_review),
        scout=_role_shorthand(s.role_scout),
    )


@app.get("/projects/{project_id}/roles", response_model=RolesConfig)
async def get_project_roles(project_id: str) -> RolesConfig:
    """The project's `[roles]` workflow-loop config (plan→scout→build→refute,
    notes/workflow-roles-plan.md) for the Roles settings tab."""
    project = _project_by_id(project_id)
    return _roles_config(project.path)


@app.put("/projects/{project_id}/roles", response_model=RolesConfig)
async def set_project_roles(project_id: str, req: RolesUpdateRequest) -> RolesConfig:
    """Set the project's role config — a targeted `[roles]` write that preserves
    the project's scripts, gate, agent, and other settings tables."""
    project = _project_by_id(project_id)
    write_project_roles(
        project.path,
        enabled=req.enabled,
        role_plan=req.plan,
        role_build=req.build,
        role_review=req.review,
        role_scout=req.scout,
        target=req.target,
    )
    return _roles_config(project.path)


async def _fetch_local_models(base_url: str) -> LocalModelsResponse:
    """Query an OpenAI-compatible local server's ``/v1/models`` for its installed
    model tags — powers the composer's Local-AI model dropdown. Uses a short curl
    subprocess (same no-dep idiom as LocalModelAdapter); any failure (server down,
    bad URL, junk body) reads as unreachable so the UI falls back to a text field."""
    url = base_url.rstrip("/")
    if not url.endswith("/v1"):
        url += "/v1"
    url += "/models"
    try:
        proc = await asyncio.create_subprocess_exec(
            "curl", "-s", "-m", "5", url,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=6)
        if proc.returncode != 0:
            return LocalModelsResponse(reachable=False, base_url=base_url)
        data = json.loads(out.decode(errors="replace"))
        models = [m["id"] for m in data.get("data", []) if isinstance(m, dict) and m.get("id")]
        return LocalModelsResponse(reachable=True, models=models, base_url=base_url)
    except (OSError, asyncio.TimeoutError, json.JSONDecodeError, KeyError, TypeError):
        return LocalModelsResponse(reachable=False, base_url=base_url)


@app.get("/projects/{project_id}/agent/local-models", response_model=LocalModelsResponse)
async def get_local_models(project_id: str) -> LocalModelsResponse:
    """The models installed on the project's configured local server — the live source
    for the composer's Local-AI model dropdown."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return await _fetch_local_models(load_project_settings(project.path).local_base_url)


@app.get("/projects/{project_id}/env", response_model=EnvConfig)
async def get_project_env(project_id: str) -> EnvConfig:
    """The project's worktree `.env` seed (`.haro/.env`) for the Environment
    settings tab — the secrets every new workspace is seeded with."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return EnvConfig(content=read_env(project.path))


@app.put("/projects/{project_id}/env", response_model=EnvConfig)
async def set_project_env(project_id: str, req: EnvUpdateRequest) -> EnvConfig:
    """Save the worktree `.env` seed to `.haro/.env` (always gitignored — it
    holds secrets). Existing workspaces are untouched; new ones are seeded with it."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    write_env(project.path, req.content)
    return EnvConfig(content=read_env(project.path))


@app.post("/projects/{project_id}/push")
async def push_project(project_id: str) -> dict:
    """Publish: push the project's default branch to `origin` (e.g. seed a freshly
    linked remote with local history). Needs a linked remote + working git creds."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    if not await git_ops.get_remote(project.path):
        raise HTTPException(400, "no remote linked: link one first")
    try:
        detail = await git_ops.push(project.path, project.default_branch)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"push failed: {exc.stderr}") from exc
    return {"pushed": True, "branch": project.default_branch, "detail": detail.strip()}


@app.post("/projects/{project_id}/pull")
async def pull_project(project_id: str) -> dict:
    """Sync: fast-forward the project's default branch from `origin` (e.g. bring
    in teammates' merges before branching new workspaces). Needs a linked remote,
    the main checkout on the default branch, and a clean working tree."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    if not await git_ops.get_remote(project.path):
        raise HTTPException(400, "no remote linked: link one first")
    try:
        await git_ops.fetch(project.path)
        detail = await git_ops.pull(project.path, project.default_branch)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"pull failed: {exc.stderr}") from exc
    return {"pulled": True, "branch": project.default_branch, "detail": detail.strip()}


@app.get("/projects/{project_id}/workspaces", response_model=list[Workspace])
async def list_workspaces(project_id: str) -> list[Workspace]:
    return store.list_workspaces(project_id)


@app.get("/workspaces/{ws_id}", response_model=Workspace)
async def get_workspace(ws_id: str) -> Workspace:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    return ws


@app.patch("/workspaces/{ws_id}", response_model=Workspace)
async def rename_workspace(ws_id: str, req: RenameWorkspaceRequest) -> Workspace:
    """Rename a workspace's display name and/or its git branch. The worktree
    directory is keyed off the workspace id/slug, not the branch, so a branch
    rename is just ``git branch -m`` in place — no worktree move needed."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")

    if req.branch is not None:
        new_branch = req.branch.strip()
        if not new_branch:
            raise HTTPException(400, "branch name can't be empty")
        if new_branch != ws.branch:
            try:
                await git_ops.rename_branch(ws.worktree_path, ws.branch, new_branch)
            except git_ops.GitError as exc:
                raise HTTPException(400, f"git branch rename failed: {exc.stderr}") from exc
            ws.branch = new_branch

    if req.name is not None:
        new_name = req.name.strip()
        if not new_name:
            raise HTTPException(400, "name can't be empty")
        ws.name = new_name

    await db.save_snapshot(store)
    return ws


async def _teardown_workspace(ws: Workspace, project: Project) -> None:
    """Stop everything running in a workspace and remove its git worktree.

    Shared by workspace-archive and project-removal so both paths tear down
    identically. Best-effort on the archive script; raises only if the git
    worktree removal itself fails. The on-disk repo is never touched — only
    the worktree (a detachable checkout) is removed."""
    # Stop everything running inside the workspace (the agent in every session, setup,
    # the gate, its PTYs, its dev servers) while the worktree still exists, then run
    # the archive script. The stop half is shared with the race ceremony's *soft*
    # archive so the two teardowns can't drift — see ``lifecycle.quiesce_workspace``;
    # everything below this line is what makes THIS one a hard delete.
    await quiesce_workspace(store=store, workspace=ws)
    psettings = load_project_settings(project.path)
    await run_archive(workspace=ws, project=project, psettings=psettings)

    try:
        await git_ops.remove_worktree(project.path, ws.worktree_path, ws.branch)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git worktree remove failed: {exc.stderr}") from exc

    store.release_port(ws.port)
    ws.status = WorkspaceStatus.archived
    store.remove_workspace(ws.id)


@app.delete("/workspaces/{ws_id}")
async def archive_workspace(ws_id: str) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")

    await _teardown_workspace(ws, project)
    await db.save_snapshot(store)
    return {"archived": ws_id}


async def _archive_candidate(ws: Workspace) -> archive_queue.Candidate:
    """Gather the facts the bulk-archive planner admits on (backlog/bulk-archive.md).

    Every git failure degrades to ``measured=False`` — "I couldn't tell" — never to a
    clean-looking zero, because the planner's default is to skip anything with work at
    stake and a false clean is exactly how that default would throw work away."""
    busy = store.busy_reason(ws.id)
    if not git_ops.worktree_valid(ws.worktree_path):
        # A husk: git already lost this checkout, so there is nothing left to lose.
        return archive_queue.Candidate(id=ws.id, name=ws.name, busy=busy, worktree_missing=True)
    try:
        dirty = not await git_ops.is_clean(ws.worktree_path)
        ahead = await git_ops.ahead_count(ws.worktree_path, ws.base_ref)
    except (git_ops.GitError, ValueError):
        return archive_queue.Candidate(id=ws.id, name=ws.name, busy=busy, measured=False)
    return archive_queue.Candidate(id=ws.id, name=ws.name, busy=busy, dirty=dirty, ahead=ahead)


async def _drain_archive_queue(run: ArchiveQueueRun, project: Project) -> None:
    """The bulk-archive driver task: one teardown at a time, progress on the feed.

    Runs detached from the request that started it (a batch of teardowns outlives its
    HTTP call), so every state change is broadcast rather than returned."""

    async def publish(r: ArchiveQueueRun) -> None:
        await hub.broadcast_global({
            "channel": "notify",
            "kind": "archive_queue",
            "project_id": r.project_id,
            "run": r.model_dump(),
        })

    async def archive_one(ws_id: str) -> None:
        ws = store.get_workspace(ws_id)
        if not ws:
            raise RuntimeError("workspace is gone")
        try:
            await _teardown_workspace(ws, project)
        except HTTPException as exc:
            # The shared teardown speaks HTTP because its other caller is a route;
            # in here that would surface as "400: ..." in the item's reason.
            raise RuntimeError(str(exc.detail)) from exc
        # Snapshot per item, not per batch: a crash mid-queue then leaves the store
        # agreeing with the disk about everything already torn down.
        await db.save_snapshot(store)

    try:
        await archive_queue.run_queue(run, archive_one=archive_one, publish=publish)
    finally:
        run.finished_at = time.time()
        if run.state == "running":
            # The driver itself died (shutdown, cancellation). Say so rather than
            # leaving a queue that reads as still draining with no owner.
            run.state = "canceled"
        for item in run.items:
            if item.outcome in ("queued", "archiving"):
                item.outcome = "canceled"
                item.reason = item.reason or "the queue stopped before this one finished"
        await publish(run)
        await db.save_snapshot(store)


@app.post("/projects/{project_id}/archive-queue", response_model=ArchiveQueueRun)
async def start_archive_queue(
    project_id: str, req: ArchiveQueueRequest, dry: bool = False
) -> ArchiveQueueRun:
    """Bulk archive, through a serial queue (backlog/bulk-archive.md).

    ``dry=true`` is the preview the confirm dialog renders: same model, nothing torn
    down — which workspaces would be archived, and which are held back because
    archiving would throw work away (uncommitted edits, unmerged commits, a running
    agent). ``force`` takes those too.

    A live run drains **one workspace at a time** and reports each outcome on the
    global feed (``notify`` / ``archive_queue``). One queue per project at a time:
    two would be concurrent teardowns again, which is the thing this replaces."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    if not req.workspace_ids:
        raise HTTPException(400, "no workspaces selected")

    seen: set[str] = set()
    candidates: list[archive_queue.Candidate] = []
    for ws_id in req.workspace_ids:
        if ws_id in seen:
            continue
        seen.add(ws_id)
        ws = store.get_workspace(ws_id)
        if not ws or ws.project_id != project_id:
            raise HTTPException(404, f"workspace not in this project: {ws_id}")
        candidates.append(await _archive_candidate(ws))

    items = archive_queue.to_items(archive_queue.plan(candidates, force=req.force))
    run = ArchiveQueueRun(project_id=project_id, dry=dry, force=req.force, items=items)
    if dry:
        # A preview is an answer, not an entity — nothing to store, nothing to stop.
        return run
    if store.archive_running(project_id):
        raise HTTPException(409, "a bulk archive is already running for this project")

    store.add_archive_run(run)
    task = asyncio.create_task(_drain_archive_queue(run, project))
    store.archive_tasks[project_id] = task
    return run


@app.get("/projects/{project_id}/archive-queue", response_model=Optional[ArchiveQueueRun])
async def get_archive_queue(project_id: str) -> Optional[ArchiveQueueRun]:
    """This project's most recent bulk archive — so a reload mid-queue reconnects to
    the run in progress instead of losing sight of a destructive batch."""
    if not store.get_project(project_id):
        raise HTTPException(404, "project not found")
    return store.latest_archive_run(project_id)


@app.post("/archive-queue/{run_id}/stop", response_model=ArchiveQueueRun)
async def stop_archive_queue(run_id: str) -> ArchiveQueueRun:
    """Stop a draining queue **cooperatively**: the teardown in flight finishes, and
    everything still pending is canceled. Cancelling the task outright is how you get
    a half-removed worktree, so the flag is checked between items instead."""
    run = store.get_archive_run(run_id)
    if not run:
        raise HTTPException(404, "archive run not found")
    run.stop_requested = True
    return run


@app.delete("/projects/{project_id}")
async def remove_project(project_id: str) -> dict:
    """Untrack a project: tear down every one of its workspaces (worktrees),
    then drop it from the store. The repository on disk is left untouched —
    haro simply stops tracking it, so re-adding it later is safe."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")

    for ws in store.list_workspaces(project_id):
        await _teardown_workspace(ws, project)

    store.remove_project(project_id)
    await db.save_snapshot(store)
    return {"removed": project_id}


# --------------------------------------------------------------------------- #
# Agent
# --------------------------------------------------------------------------- #
def _refuse_if_manual(ws: Workspace) -> None:
    """Manual mode is a promise that no agent edits this worktree. Every path that can
    start an editing agent calls this first; the read-only review stays allowed."""
    if ws.mode == "manual":
        raise HTTPException(409, "manual mode: the agent is off for this workspace")
    if ws.id in store.mode_switching:
        raise HTTPException(409, "switching mode, try again")
    if store.assist_running(ws.id):
        raise HTTPException(409, "the assistant is working in this workspace: wait for it or stop it")


@app.post("/workspaces/{ws_id}/mode", response_model=Workspace)
async def set_workspace_mode(ws_id: str, req: SetModeRequest) -> Workspace:
    """Flip who writes the code. A dirty tree is checkpointed first so the before and
    after segments stay separable in git (the receipt's `written_by` reads the switches)."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    if ws.mode == req.mode:
        return ws
    if ws.id in store.mode_switching:
        raise HTTPException(409, "switching mode, try again")
    if ws.status in (WorkspaceStatus.archived, WorkspaceStatus.merged):
        raise HTTPException(409, f"a {ws.status.value} workspace can't change mode")
    if store.setup_running(ws_id):
        raise HTTPException(409, "setup is still running: wait for it to finish")
    if store.agent_busy(ws_id) or store.agent_starting.get(ws_id):
        raise HTTPException(409, "stop the agent first")
    if store.assist_running(ws_id):
        raise HTTPException(409, "stop the assistant first")
    gate_task = store.gate_tasks.get(ws_id)
    if ws.status == WorkspaceStatus.tests_running or (gate_task is not None and not gate_task.done()):
        raise HTTPException(409, "a gate run is in progress: wait for it to finish")
    if not git_ops.worktree_valid(ws.worktree_path):
        raise HTTPException(409, "this workspace's worktree is missing")
    # Nothing above awaits, so no agent can slip in between the checks and this mark;
    # while it is set, ``start_agent`` refuses (``_refuse_if_manual``).
    store.mode_switching.add(ws_id)
    try:
        try:
            await git_panel.commit(ws.worktree_path, f"checkpoint: switch to {req.mode} mode")
            sha = await git_ops.head_sha(ws.worktree_path)
        except git_ops.GitError as exc:
            raise HTTPException(400, f"checkpoint failed: {exc.stderr}") from exc
        if store.agent_busy(ws_id) or store.agent_starting.get(ws_id):
            raise HTTPException(409, "stop the agent first")
        ws.mode_switches.append(ModeSwitch(to=req.mode, sha=sha))
        ws.mode = req.mode
    finally:
        store.mode_switching.discard(ws_id)
    await hub.publish(ws.id, status_payload(ws))
    await db.save_snapshot(store)
    return ws


@app.post("/workspaces/{ws_id}/agent", response_model=AgentRun)
async def start_agent(ws_id: str, req: StartAgentRequest) -> AgentRun:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    _refuse_if_manual(ws)
    # Between here and the task registration below there are awaits (git reads). Marking
    # the start makes a concurrent mode switch refuse instead of flipping to manual under
    # an agent that is about to spawn.
    store.agent_starting[ws_id] = store.agent_starting.get(ws_id, 0) + 1
    try:
        return await _start_agent(ws, req)
    finally:
        left = store.agent_starting.get(ws_id, 1) - 1
        if left > 0:
            store.agent_starting[ws_id] = left
        else:
            store.agent_starting.pop(ws_id, None)


async def _start_agent(ws: Workspace, req: StartAgentRequest) -> AgentRun:
    ws_id = ws.id
    # Which agent session this run belongs to (transcript keyed by (ws, session_id)).
    # None ⇒ the primary session, so the single-session path is byte-identical.
    session_id = req.session_id or DEFAULT_SESSION
    # Guard is per *session* now: a workspace hosts N concurrent sessions sharing one
    # worktree, so a 2nd session is allowed to start — its run serializes on the
    # per-worktree lock (Store.agent_lock), it isn't rejected.
    #
    # Setup is deliberately NOT a refusal any more. It used to 409 ("setup is still
    # running"), which pushed the wait onto the client — and the client's queue was
    # scoped to the *selected* workspace, so "create from the backlog → click run →
    # switch away" silently stranded the task forever. The backend now OWNS the wait:
    # the run is accepted as `queued` and ``runner.run_agent`` holds it until
    # provisioning settles. The client fires and forgets.
    existing = store.active_task(ws_id, session_id)
    if existing is not None and not existing.done():
        raise HTTPException(409, "this session already has an agent running")

    # Test-first (backlog/test-first.md): "draft" writes only the acceptance test, "build"
    # is every run after approval. Until the test is approved no build run may start, or the
    # contract the gate enforces would not exist yet.
    tf = ws.test_first
    tf_phase: str | None = None
    run_task = req.task
    if req.test_first:
        if store.agent_busy(ws_id):
            raise HTTPException(409, "an agent session is still active in this workspace")
        if req.plan:
            raise HTTPException(400, "test-first drafting cannot be combined with plan mode")
        if tf is not None and tf.phase == "approved":
            raise HTTPException(409, "the acceptance test is already approved: this workspace is building")
        if tf is None and await git_ops.changed_files(ws.worktree_path, ws.base_ref):
            raise HTTPException(
                409, "test-first needs a workspace with no changes yet: the drafted test is proven against the tree as it is"
            )
        tf_phase = "draft"
    elif tf is not None and not req.plan:
        if tf.phase != "approved":
            raise HTTPException(409, "approve (or redraft) the acceptance test before building")
        tf_phase = "build"

    project = store.get_project(ws.project_id)
    psettings = load_project_settings(project.path) if project else None
    roles_on = bool(psettings and psettings.roles_enabled)
    # Which step of the plan→scout→build→refute loop this run represents. An
    # explicit `req.role` (the approve-plan handoff) always wins — that's what
    # lets "approve" resolve to the BUILD role even though the plan turn it's
    # approving ran under the plan role; otherwise a plan-mode request is the
    # "plan" step and everything else is "build". See workflow-roles-plan.md.
    role_name = req.role or ("plan" if req.plan else "build")
    # Pick the agent backend. A per-run choice (req.adapter) wins; otherwise fall back
    # to the project's default backend (`[agent] adapter`). "local" runs a local model
    # (Ollama / llama.cpp — no cloud); the Claude model/effort/budget knobs don't apply
    # there, so the run's model is the picked local tag (or the project's local_model) and
    # effort is left unset.
    default_adapter = psettings.agent_adapter if psettings else "claude-code"
    use_adapter = (req.adapter or default_adapter).strip().lower()
    if use_adapter == "local":
        # `[agent] sandbox` only wraps ClaudeCodeAdapter's `claude` subprocess today
        # (see sandbox.py) — LocalModelAdapter has no bwrap support at all. Refuse
        # rather than silently running the local model fully unconfined under a
        # flag whose whole point is refusing exactly that (same fail-closed
        # contract as a missing `bwrap` in claude_code.py).
        if psettings and psettings.agent_sandbox:
            raise HTTPException(
                400,
                "[agent] sandbox is on, but the local adapter doesn't support "
                "sandboxing yet — refusing to run it unconfined. Turn off "
                "[agent] sandbox to use the local adapter, or use claude-code.",
            )
        local_model = req.model or (psettings.local_model if psettings else "qwen2.5-coder")
        base_url = psettings.local_base_url if psettings else "http://localhost:11434/v1"
        adapter: AgentAdapter = LocalModelAdapter(base_url=base_url, model=local_model)
        model = local_model
        effort = None
    else:
        adapter = ClaudeCodeAdapter(sandbox=bool(psettings and psettings.agent_sandbox))
        # Resolve model/effort: an explicit per-run pick always wins; otherwise, when
        # `[roles] enabled`, this run's ROLE (plan/build/review/scout) supplies its own
        # model/effort — this is what fixes the "approve a plan, forget to flip the
        # picker" trap, since build always gets its OWN configured model rather than
        # whatever the plan step happened to be running; otherwise fall back to the
        # project's cost-conscious defaults (Sonnet, not the CLI's pricier Opus
        # default; effort left at the CLI default unless a project sets one).
        role_cfg = (
            {
                "plan": psettings.role_plan,
                "build": psettings.role_build,
                "review": psettings.role_review,
                "scout": psettings.role_scout,
            }.get(role_name)
            if roles_on
            else None
        )
        model = (
            req.model
            or (role_cfg.model if role_cfg else None)
            or (psettings.default_model if psettings else None)
            or "sonnet"
        )
        effort = (
            req.effort
            or (role_cfg.effort if role_cfg and role_cfg.effort else None)
            or (psettings.default_effort if psettings and psettings.default_effort else None)
        )
    # Plan Mode is a per-adapter capability: honour the request only when the resolved
    # adapter's ``run`` actually accepts a ``plan`` param (claude-code today). Forcing it
    # False for adapters that can't plan is what keeps runner.py's gate-skip honest — we
    # never skip the gate for an agent that really edited files. Hidden, not broken.
    plan = bool(req.plan) and "plan" in inspect.signature(adapter.run).parameters
    # Scout (Phase 2 — notes/workflow-roles-plan.md): haro injects its own read-only
    # mapping sub-agent via `--agents` when roles are on and a scout role is
    # configured. Feature-detected like plan, so the local adapter (no `agents`
    # param) just never sees it.
    agents = (
        scout_agent_json(psettings.role_scout)
        if roles_on and psettings and psettings.role_scout
        and "agents" in inspect.signature(adapter.run).parameters
        else None
    )
    # Tell the driving agent scout exists and when to reach for it — `--agents` alone
    # only REGISTERS the sub-agent, it doesn't tell the driver to prefer delegating.
    instructions = psettings.instructions if psettings else None
    if agents:
        instructions = f"{instructions}\n\n{scout_instructions()}" if instructions else scout_instructions()
    # Protected tests: deny the agent's edit tools on every test file tracked at base_ref.
    # A per-run choice wins over `[agent] protect_tests`. Refuse loudly when the file list
    # can't be read rather than run unprotected under a setting that says otherwise.
    want_protect = (
        req.protect_tests
        if req.protect_tests is not None
        else bool(psettings and psettings.protect_tests == "existing")
    )
    deny_edit_paths: list[str] | None = None
    protect = want_protect and "deny_edit_paths" in inspect.signature(adapter.run).parameters
    if protect and not plan:
        try:
            deny_edit_paths = await protect_tests.deny_patterns_at(ws.worktree_path, ws.base_ref) or None
            # No test files at base_ref: nothing to protect, so don't label the run protected.
            protect = deny_edit_paths is not None
        except git_ops.GitError as exc:
            raise HTTPException(
                409, f"could not list the test files at {ws.base_ref} to protect them: {exc}"
            ) from exc
    if tf_phase == "draft" and "deny_edit_paths" in inspect.signature(adapter.run).parameters:
        try:
            tracked = await git_ops.list_files_at(ws.worktree_path, ws.base_ref)
            deny_edit_paths = acceptance.draft_deny_patterns(tracked) or None
        except git_ops.GitError:
            deny_edit_paths = None  # the diff scan after the run is the guarantee
    # Last look before spawning. No await from here to set_active_task, and it sits
    # before any state change so a refusal leaves no orphaned run or reset test-first state.
    _refuse_if_manual(ws)
    if tf_phase == "draft":
        instructions = (
            f"{instructions}\n\n{acceptance.DRAFT_ADDENDUM}" if instructions else acceptance.DRAFT_ADDENDUM
        )
        if tf is None:
            ws.test_first = TestFirstState(phase="drafting", task=req.task, gen=1)
        else:
            run_task = (
                f"Redraft the acceptance test for this task, applying the feedback.\n\n"
                f"Task: {tf.task}\n\nFeedback: {req.task}"
            )
            tf.phase, tf.reject_reason, tf.rounds, tf.gen = "drafting", None, tf.rounds + 1, tf.gen + 1
            tf.files, tf.cases, tf.proved_at = [], [], None
    elif tf_phase == "build" and tf is not None:
        if "deny_edit_paths" in inspect.signature(adapter.run).parameters:
            deny_edit_paths = sorted({*(deny_edit_paths or []), *acceptance.build_deny_patterns(tf)})
        instructions = (
            f"{instructions}\n\n" if instructions else ""
        ) + acceptance.build_addendum([f.path for f in tf.files])
    # session_id was resolved up top (the per-session start guard needs it).
    # Born `queued` while the worktree is still provisioning: the run is real and
    # persisted, it just hasn't spawned yet. `runner.run_agent` flips it to `running`
    # the moment it holds a slot, so "⏳ waiting for setup" is a state the UI can
    # read rather than a promise the client has to remember.
    run = AgentRun(
        workspace_id=ws.id, adapter=adapter.name, model=model, effort=effort, task=run_task,
        plan=plan, protect_tests=bool(protect and not plan),
        role=role_name if roles_on else "",
        status=AgentRunStatus.queued if store.setup_running(ws_id) else AgentRunStatus.running,
    )
    store.add_run(run)
    # Echo the prompt into that session's persisted transcript so the conversation reads
    # as a back-and-forth and survives refreshes/restarts.
    store.append_event(
        ws.id,
        {"run_id": "user", "workspace_id": ws.id, "ts": time.time(), "type": "user",
         "payload": {"text": req.task}},
        session_id,
    )

    # ⚠ Nothing may `await` between create_task and set_active_task. The coroutine
    # doesn't start until the next suspension point, so registering immediately after is
    # safe — but an await slipped in here would let `run_agent` reach its `finally` and
    # pop a handle that isn't registered yet (and then this line would register a handle
    # for a dead run). `pop_active_task`'s identity check is the belt to this braces.
    task = asyncio.create_task(
        run_agent(
            store=store,
            hub=hub,
            adapter=adapter,
            workspace=ws,
            run=run,
            test_adapter=_test_adapter(project.path if project else None),
            project_path=project.path if project else None,
            auto_gate=req.run_gate_on_done and tf_phase != "draft",
            test_first_phase=tf_phase if tf_phase == "draft" else None,
            test_first_gen=ws.test_first.gen if tf_phase == "draft" and ws.test_first else 0,
            # Carries the scout paragraph (appended above) when a scout sub-agent was
            # registered for this run.
            instructions=instructions,
            max_budget_usd=psettings.max_budget_usd if psettings else 5.0,
            cost_warn_usd=psettings.cost_warn_usd if psettings else 0.0,
            auto_fix=psettings.auto_fix if psettings else False,
            auto_fix_max_rounds=psettings.auto_fix_max_rounds if psettings else 3,
            gate_scope=psettings.gate_default_scope if psettings else "all",
            # Install-wide cap on concurrent agent subprocesses. Read per start so a
            # settings edit takes effect on the next run, not the next restart.
            max_parallel=psettings.max_parallel if psettings else 0,
            session_id=session_id,
            # Feature-detected above: True only when the resolved adapter's `run`
            # accepts `plan` (claude-code today), so the gate-skip never strands edits.
            plan=plan,
            # Scout sub-agent (feature-detected above; None when roles/scout are off).
            agents=agents,
            deny_edit_paths=deny_edit_paths,
        )
    )
    store.set_active_task(ws_id, session_id, task)
    return run


def gate_block_detail(test: TestRun) -> str:
    """Why a settled, non-green run is blocked, for the merge train's reason line."""
    if test.merge_conflict:
        return "base does not merge cleanly"
    if test.acceptance_blocked:
        return "acceptance test not intact"
    if test.tamper_blocked:
        return "tamper alarm blocked"
    if test.coverage_blocked:
        return "coverage guard blocked"
    if test.failed:
        return f"{test.failed} failing test(s)"
    return "gate is not green"


@app.post("/workspaces/{ws_id}/test-first/approve", response_model=AgentRun)
async def approve_test_first(ws_id: str, req: ApproveTestFirstRequest | None = None) -> AgentRun:
    """Approve the proven-red acceptance test and start the build run (backlog/test-first.md).
    Refused unless the test is in review, the agent is idle, and nothing changed since the
    proof. The hashes recorded at proof time become the contract the gate enforces."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    _refuse_if_manual(ws)
    tf = ws.test_first
    if tf is None or tf.phase != "review":
        raise HTTPException(409, "there is no proven acceptance test waiting for approval")
    if store.agent_busy(ws_id):
        raise HTTPException(409, "an agent session is still active in this workspace")
    stale = await acceptance.verify_unchanged_since_proof(ws)
    if stale:
        raise HTTPException(409, stale)
    tf.phase, tf.approved_at = "approved", time.time()
    req = req or ApproveTestFirstRequest()
    files = ", ".join(f.path for f in tf.files)
    try:
        run = await start_agent(ws_id, StartAgentRequest(
            task=(
                f"{tf.task}\n\nThe acceptance test ({files}) is approved. Make it pass by changing "
                "source code. Do not modify the test file."
            ),
            model=req.model, effort=req.effort,
        ))
    except BaseException:
        tf.phase, tf.approved_at = "review", None
        raise
    return run


@app.post("/workspaces/{ws_id}/test-first/cancel", response_model=Workspace)
async def cancel_test_first(ws_id: str, req: CancelTestFirstRequest | None = None) -> Workspace:
    """Leave test-first mode so ordinary runs work again. Before approval this just drops the
    draft. After approval the gate stops enforcing the contract, so it needs ``confirm``."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    tf = ws.test_first
    if tf is None:
        raise HTTPException(409, "this workspace is not in test-first mode")
    if store.agent_busy(ws_id):
        raise HTTPException(409, "an agent session is still active in this workspace")
    if tf.phase == "approved" and not (req and req.confirm):
        raise HTTPException(409, "the acceptance test is approved: confirm to stop enforcing it")
    ws.test_first = None
    return ws


#: How long ``stop_agent`` waits for a cancelled run to actually finish tearing down
#: before returning anyway. Bounded so a wedged subprocess can't hang the request;
#: the teardown itself continues in the background either way.
_STOP_SETTLE_SECS = 5.0


@app.post("/workspaces/{ws_id}/agent/stop")
async def stop_agent(ws_id: str, session: str = DEFAULT_SESSION) -> dict:
    """Stop the agent in ONE session (default: the primary). Sessions run
    serialized on the worktree lock, so each has its own stop handle.

    Waits (briefly) for the run to actually settle instead of returning the instant
    ``cancel()`` is *requested*. "Stopped" used to be a lie for as long as the process
    took to die — and now that cancellation kills the `claude` process group, there is
    real teardown work to wait for, so the caller can trust that a 200 means gone."""
    task = store.active_task(ws_id, session)
    if not task or task.done():
        raise HTTPException(409, "no agent running in this session")
    task.cancel()
    # shield: a client disconnect must not cancel *this* await into cancelling the
    # teardown we're waiting on. Both outcomes are fine — CancelledError is the run
    # ending as asked, TimeoutError means it's taking longer than we'll block for.
    settled = True
    try:
        await asyncio.wait_for(asyncio.shield(task), timeout=_STOP_SETTLE_SECS)
    except asyncio.TimeoutError:
        settled = False
    except asyncio.CancelledError:
        # The run ended cancelled — exactly what we asked for. Only swallow that:
        # a CancelledError raised while the run is still alive is OUR request being
        # cancelled, and swallowing it would hide a client disconnect.
        if not task.cancelled():
            raise
    return {"stopping": ws_id, "session": session, "settled": settled}


# --------------------------------------------------------------------------- #
# Diff
# --------------------------------------------------------------------------- #
@app.get("/workspaces/{ws_id}/diff", response_model=DiffResponse)
async def get_diff(ws_id: str, commit: str | None = None) -> DiffResponse:
    """`commit` scopes the diff to that single commit's own patch (vs its
    parent) instead of the full working-vs-base_ref view — the commit-by-commit
    review filter in the ship panel."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        if commit:
            text, count = await git_ops.diff_commit(ws.worktree_path, commit)
        else:
            text, count = await git_ops.diff(ws.worktree_path, ws.base_ref)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git diff failed: {exc.stderr}") from exc
    return DiffResponse(base_ref=ws.base_ref, diff=text, files_changed=count, commit=commit)


# --------------------------------------------------------------------------- #
# On-demand AI review ("Review with AI"): never part of the gate verdict
# --------------------------------------------------------------------------- #
@app.post("/workspaces/{ws_id}/review", response_model=ReviewResult | ReviewVerdict)
async def run_review_endpoint(ws_id: str, req: ReviewRequest | None = None):
    """Run an AI review pass over the worktree's current diff vs its base, on demand.

    Body (optional): ``{"model": "opus" | "sonnet" | ...}`` overrides the reviewer model.

    When `[roles] enabled` and a review role is configured, runs the refuter (read-only
    Read/Grep/Glob tools, judged against the latest task/plan when recorded and on the
    diff's own merits when not) and returns a ``ReviewVerdict``
    (``verdict``, ``summary``, ``must_fix[]``, ``notes[]``). Otherwise runs the plain
    tools-off reviewer and returns a ``ReviewResult`` (``summary``, ``findings[]``).
    Both carry ``error`` (couldn't run) and ``nothing_to_review`` (empty diff, not an
    error). Always HTTP 200 for reviewer-side failures; 404 only for an unknown workspace.

    Never writes to a TestRun or the gate summary: the gate verdict is deterministic.
    """
    req = req or ReviewRequest()
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    psettings = load_project_settings(project.path) if project else None
    task = None
    for r in store.runs.values():  # insertion-ordered → last match is the latest run
        if r.workspace_id == ws.id:
            task = r.task

    if psettings and psettings.roles_enabled and psettings.role_review:
        role = psettings.role_review
        return await reviewsvc.run_refuter(
            worktree_path=ws.worktree_path, base_ref=ws.base_ref, task=task,
            plan=ws.plan_text, gate_facts=reviewsvc.gate_facts_brief(store.latest_test(ws.id)),
            model=req.model or role.model, effort=role.effort,
            sandbox=bool(psettings.agent_sandbox), max_budget_usd=psettings.max_budget_usd,
        )

    model = req.model or (psettings.default_model if psettings else None) or "sonnet"
    return await reviewsvc.run_review(
        worktree_path=ws.worktree_path, base_ref=ws.base_ref, task=task, model=model,
        sandbox=bool(psettings and psettings.agent_sandbox),
    )


# --------------------------------------------------------------------------- #
# Manual rail: assist (plan / research) and Docs. The AI here is read-only by construction
# (assist.py); nothing below can start an editing agent.
# --------------------------------------------------------------------------- #
def _assist_guard(ws: Workspace) -> None:
    """Refusals shared by every AI assist start. Not ``_refuse_if_manual``: an assist run is
    not an agent start and is welcome in manual mode. The busy checks matter for the git
    guard: an agent or setup script writing the tree would look like the assistant did."""
    if ws.id in store.mode_switching:
        raise HTTPException(409, "switching mode, try again")
    if ws.status in (WorkspaceStatus.archived, WorkspaceStatus.merged):
        raise HTTPException(409, f"a {ws.status.value} workspace has nothing to plan")
    if store.assist_running(ws.id):
        raise HTTPException(409, "the assistant is already working on something in this workspace")
    if store.agent_busy(ws.id) or store.agent_starting.get(ws.id):
        raise HTTPException(409, "the agent is running in this workspace: wait for it to finish")
    if store.setup_running(ws.id):
        raise HTTPException(409, "setup is still running: wait for it to finish")
    if not git_ops.worktree_valid(ws.worktree_path):
        raise HTTPException(409, "this workspace's worktree is missing")


def _record_research(ws: Workspace, scope: str, query: str) -> ResearchEntry:
    entry = ResearchEntry(scope=scope, query=query)  # type: ignore[arg-type]
    ws.research_log.count += 1
    ws.research_log.entries.append(entry)
    del ws.research_log.entries[:-20]
    xp_hooks.note_research(store, ws, scope)
    return entry


def _repeats_newest_answer(ws: Workspace, entry: ResearchEntry, answer: str) -> bool:
    """The same question with the same answer as the newest stored one: Recent lists it once
    (the client dedupes too, but a reload should not bring the twin back)."""
    for e in reversed(ws.research_log.entries):
        if e is entry or e.scope != "ask" or e.answer is None:
            continue
        return e.query == entry.query and e.answer == answer
    return False


def _trim_recent_asks(ws: Workspace) -> None:
    """Only the newest ``RECENT_ASKS`` ask entries keep their answer; older ones drop it but
    stay in the log, so ``count`` and the receipt are untouched."""
    kept = 0
    for e in reversed(ws.research_log.entries):
        if e.scope != "ask" or e.answer is None:
            continue
        kept += 1
        if kept > RECENT_ASKS:
            e.answer, e.rows, e.note, e.blocked_calls = None, [], None, []


async def _publish_assist(ws_id: str, job: AssistJob, kind: str, **extra) -> None:
    await hub.publish(
        ws_id, {"channel": "assist", "job": job.kind, "job_id": job.id, "kind": kind, **extra}
    )


def _assist_model(psettings, req_model: str | None, req_effort: str | None) -> tuple[str, str | None]:
    """Same order as ``start_agent``: explicit pick > the plan role (when ``[roles]`` is on)
    > ``[agent] default_model`` > sonnet."""
    role = psettings.role_plan if psettings and psettings.roles_enabled else None
    model = (
        req_model
        or (role.model if role else None)
        or (psettings.default_model if psettings else None)
        or "sonnet"
    )
    effort = (
        req_effort
        or (role.effort if role and role.effort else None)
        or (psettings.default_effort if psettings and psettings.default_effort else None)
    )
    return model, effort


def _start_assist(ws: Workspace, job: AssistJob, coro_factory) -> AssistJob:
    """Register the job and run it as a task. Nothing between the guard and here awaits, so
    two concurrent starts cannot both pass ``_assist_guard``."""
    store.assist_jobs[ws.id] = job
    store.assist_writes[ws.id] = set()
    store.assist_internal.discard(ws.id)
    if store.internal_writer_live(ws.id):
        store.assist_internal.add(ws.id)
    store.assist_tasks[ws.id] = asyncio.create_task(coro_factory())
    return job


async def _drive_assist(
    ws: Workspace,
    job: AssistJob,
    *,
    prompt: str,
    system: str,
    model: str,
    effort: str | None,
    project,
    psettings,
    on_success,
) -> None:
    """Run one assist job and settle it: publish started/token/done|error|stopped and keep the
    latest state on ``job``. ``on_success(result)`` stores the outcome and returns the ``done``
    payload; raising ``ValueError`` from it becomes the job's error."""

    async def emit(kind: str, payload: dict) -> None:
        if kind == "started":
            job.status = "running"
        elif kind == "queued":
            job.status = "queued"
        elif kind == "token":
            job.text += payload.get("text", "")
        elif kind == "blocked":
            tool = str(payload.get("tool") or "an unknown tool")
            if tool not in job.blocked_calls:
                job.blocked_calls.append(tool)
        await _publish_assist(ws.id, job, kind, **payload)

    try:
        full_prompt = await assist_svc.resolve_refs(
            ws.worktree_path,
            project.path if project else ws.worktree_path,
            prompt,
            issue_detail_svc.view_issue,
        )
        result = await assist_svc.run_job(
            worktree=ws.worktree_path,
            prompt=full_prompt,
            system=system,
            model=model,
            effort=effort,
            max_budget_usd=psettings.max_budget_usd if psettings else None,
            max_parallel=psettings.max_parallel if psettings else 4,
            emit=emit,
            sandbox=bool(psettings and psettings.agent_sandbox),
            excused=lambda: set(store.assist_writes.get(ws.id, ())),
            internal_writer=lambda: ws.id in store.assist_internal,
        )
        job.cost_usd = result.cost_usd
        job.blocked_calls = result.blocked_calls
        job.guard_note = result.inconclusive
        if result.error:
            job.status, job.error = "error", result.error
            await _publish_assist(ws.id, job, "error", message=result.error)
            return
        if result.stopped:
            job.status = "stopped"
            await _publish_assist(ws.id, job, "stopped")
            return
        try:
            done = await on_success(result)
        except ValueError as exc:
            job.status, job.error = "error", str(exc)
            await _publish_assist(ws.id, job, "error", message=str(exc))
            return
        job.status = "done"
        await db.save_snapshot(store)
        await _publish_assist(
            ws.id, job, "done", cost_usd=result.cost_usd, blocked_calls=result.blocked_calls,
            guard_note=result.inconclusive, **done,
        )
    except asyncio.CancelledError:
        job.status = "stopped"
        await _publish_assist(ws.id, job, "stopped")
    except Exception as exc:  # noqa: BLE001 - a crashed job must settle, not hang the tab
        traceback.print_exc()
        job.status, job.error = "error", f"{type(exc).__name__}: {exc}"
        await _publish_assist(ws.id, job, "error", message=job.error)
    finally:
        store.assist_writes.pop(ws.id, None)
        store.assist_internal.discard(ws.id)


@app.post("/workspaces/{ws_id}/assist/plan", response_model=AssistJob)
async def assist_plan(ws_id: str, req: AssistPlanRequest) -> AssistJob:
    """Ask the read-only assistant for a checklist the dev implements by hand. Returns the
    running job at once; progress and the finished plan arrive on the ``assist`` channel."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    prompt = req.prompt.strip()
    if not prompt:
        raise HTTPException(400, "say what you are building")
    _assist_guard(ws)
    project = store.get_project(ws.project_id)
    psettings = load_project_settings(project.path) if project else None
    model, effort = _assist_model(psettings, req.model, req.effort)
    job = AssistJob(workspace_id=ws.id, kind="plan", query=prompt)

    async def on_success(result) -> dict:
        plan = assist_svc.make_plan(
            prompt=prompt, text=result.text, model=model, effort=effort, cost_usd=result.cost_usd
        )
        plan.guard_note = result.inconclusive
        plan.blocked_calls = list(result.blocked_calls)
        ws.plans.append(plan)
        job.plan_id = plan.id
        await xp_hooks.record_activity(store, hub, "plan_made", ws.id)
        return {"plan": plan.model_dump()}

    return _start_assist(
        ws,
        job,
        lambda: _drive_assist(
            ws, job, prompt=prompt, system=assist_svc.PLAN_SYSTEM, model=model, effort=effort,
            project=project, psettings=psettings, on_success=on_success,
        ),
    )


@app.post("/workspaces/{ws_id}/assist/research", response_model=ResearchResponse)
async def assist_research(ws_id: str, req: AssistResearchRequest) -> ResearchResponse:
    """Point the dev at where to look. ``scope`` defaults to ``ask``, the only one the client
    sends: a read-only assist job (``job_id`` in the reply, the answer on the ``assist``
    channel) whose rows also carry haro's own git lookups for the question's identifiers.
    ``repo``, ``git``, ``man`` and ``web`` remain for the CLI and tests: they answer inline and
    use no AI. Every call is counted on the workspace's ``research_log``."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    query = req.query.strip()
    if not query:
        raise HTTPException(400, "type what to look for")
    project = store.get_project(ws.project_id)

    if req.scope == "ask":
        _assist_guard(ws)
        psettings = load_project_settings(project.path) if project else None
        model, effort = _assist_model(psettings, req.model, req.effort)
        job = AssistJob(workspace_id=ws.id, kind="research", query=query)

        entry: list[ResearchEntry] = []

        async def on_success(result) -> dict:
            if entry:
                entry[0].guard_note = result.inconclusive
            if result.inconclusive:
                ws.research_log.unverified = True
            answer, sources = assist_svc.parse_research(result.text)
            model_shas: set[str] = set()
            rows, dropped = await assist_svc.verify_sources(ws.worktree_path, sources, model_shas)
            before = len(rows)
            rows = await research_svc.merge_git_hits(ws.worktree_path, query, rows, model_shas)
            if len(rows) > before:
                xp_hooks.note_research(store, ws, "git")
            job.answer, job.rows = answer, rows
            note = f"{dropped} source(s) dropped: they pointed at nothing" if dropped else None
            job.note = note
            if entry and not _repeats_newest_answer(ws, entry[0], answer):
                entry[0].answer, entry[0].rows, entry[0].note = answer, list(rows), note
                entry[0].blocked_calls = list(result.blocked_calls)
                _trim_recent_asks(ws)
            return {"answer": answer, "rows": [r.model_dump() for r in rows], "note": note}

        _start_assist(
            ws,
            job,
            lambda: _drive_assist(
                ws, job, prompt=query, system=assist_svc.ASK_SYSTEM, model=model, effort=effort,
                project=project, psettings=psettings, on_success=on_success,
            ),
        )
        entry.append(_record_research(ws, "ask", query))
        await xp_hooks.record_activity(store, hub, "research", ws.id)
        await db.save_snapshot(store)
        return ResearchResponse(scope="ask", query=query, job_id=job.id)

    if req.scope in ("repo", "git") and not git_ops.worktree_valid(ws.worktree_path):
        raise HTTPException(409, "this workspace's worktree is missing")
    if req.scope == "repo":
        rows, note = await research_svc.research_repo(ws.worktree_path, query)
    elif req.scope == "git":
        rows, note = await research_svc.research_git(ws.worktree_path, query)
    elif req.scope == "man":
        rows, note = await research_svc.research_man(query)
    else:
        rows, note = research_svc.research_web(query, project.stack if project else [])
    _record_research(ws, req.scope, query)
    await xp_hooks.record_activity(store, hub, "research", ws.id)
    await db.save_snapshot(store)
    return ResearchResponse(scope=req.scope, query=query, rows=rows, note=note)


@app.get("/workspaces/{ws_id}/assist", response_model=Optional[AssistJob])
async def get_assist_job(ws_id: str) -> AssistJob | None:
    """The latest assist job, for a client that reconnected mid-run: ``text`` and
    ``blocked_calls`` are what the run has produced so far, and a finished job carries its
    ``plan_id`` or ``answer``/``rows``."""
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    return store.assist_jobs.get(ws_id)


@app.post("/workspaces/{ws_id}/assist/stop")
async def stop_assist(ws_id: str) -> dict:
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    task = store.assist_tasks.get(ws_id)
    if task is None or task.done():
        return {"stopped": False}
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    # A task cancelled before its first step never runs its own handler, so settle here too.
    job = store.assist_jobs.get(ws_id)
    if job is not None and job.status in ("running", "queued"):
        job.status = "stopped"
        await _publish_assist(ws_id, job, "stopped")
    store.assist_writes.pop(ws_id, None)
    store.assist_internal.discard(ws_id)
    return {"stopped": True}


def _plan_or_404(ws: Workspace, plan_id: str) -> ManualPlan:
    for p in ws.plans:
        if p.id == plan_id:
            return p
    raise HTTPException(404, "plan not found")


@app.get("/workspaces/{ws_id}/plans", response_model=list[ManualPlan])
async def list_plans(ws_id: str) -> list[ManualPlan]:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    return ws.plans


@app.patch("/workspaces/{ws_id}/plans/{plan_id}", response_model=ManualPlan)
async def patch_plan(ws_id: str, plan_id: str, req: PatchPlanRequest) -> ManualPlan:
    """Edit the title or steps, tick steps (the whole list is sent back), or save the plan."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    plan = _plan_or_404(ws, plan_id)
    if req.title is not None:
        title = req.title.strip()
        if not title:
            raise HTTPException(400, "a plan needs a title")
        plan.title = title[:80]
    if req.steps is not None:
        was = {s.text: s for s in plan.steps}
        steps: list[PlanStep] = []
        for s in req.steps:
            text = s.text.strip()
            if not text:
                continue
            prior = was.get(text)
            done_at = None
            if s.done:
                done_at = prior.done_at if prior and prior.done and prior.done_at else time.time()
            steps.append(PlanStep(text=text, done=s.done, done_at=done_at))
        if not steps:
            raise HTTPException(400, "a plan needs at least one step")
        plan.steps = steps
    if req.saved is not None and req.saved != plan.saved:
        plan.saved = req.saved
        plan.saved_at = time.time() if req.saved else None
    await db.save_snapshot(store)
    return plan


@app.delete("/workspaces/{ws_id}/plans/{plan_id}")
async def delete_plan(ws_id: str, plan_id: str) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    plan = _plan_or_404(ws, plan_id)
    ws.plans.remove(plan)
    await db.save_snapshot(store)
    return {"deleted": plan_id}


async def _drain_baseline(project: Project) -> None:
    """Detached driver for one First-run baseline: the run outlives its HTTP call, so
    progress rides the global feed and the outcome is persisted here."""
    try:
        await baseline_svc.run_baseline(
            store=store, hub=hub, project=project, adapter_for=_test_adapter
        )
    finally:
        await db.save_snapshot(store)


@app.get("/projects/{project_id}/baseline", response_model=BaselineState)
async def get_baseline(project_id: str) -> BaselineState:
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    try:
        head = await git_ops.rev_parse(project.default_branch, project.path)
    except (git_ops.GitError, OSError):
        head = None
    return BaselineState(
        running=store.baseline_running(project_id), result=project.baseline, head_sha=head
    )


@app.post("/projects/{project_id}/baseline", response_model=BaselineState)
async def run_project_baseline(project_id: str) -> BaselineState:
    """Run the project's gate once on its default branch, before any agent has touched
    it (First run). Returns at once with ``running: true``; progress is
    ``{channel: "baseline"}`` on ``/ws`` and the result lands on ``Project.baseline``.
    Never a merge verdict and never touches a workspace."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    if store.baseline_running(project_id):
        raise HTTPException(409, "a baseline run is already in progress for this project")
    store.baseline_tasks[project_id] = asyncio.create_task(_drain_baseline(project))
    return BaselineState(running=True, result=project.baseline)


@app.get("/projects/{project_id}/pinned-docs", response_model=list[PinnedDoc])
async def get_pinned_docs(project_id: str) -> list[PinnedDoc]:
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return project.pinned_docs


@app.put("/projects/{project_id}/pinned-docs", response_model=list[PinnedDoc])
async def put_pinned_docs(project_id: str, req: PinnedDocsRequest) -> list[PinnedDoc]:
    """Replace the pinned web docs. Links only: haro never fetches them."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    docs: list[PinnedDoc] = []
    seen: set[str] = set()
    for d in req.docs:
        url = d.url.strip()
        if not re.match(r"^https?://\S+$", url, re.I):
            raise HTTPException(400, f"not an http(s) link: {url}")
        if url in seen:
            continue
        seen.add(url)
        title = d.title.strip() or re.sub(r"^https?://", "", url).split("/")[0]
        docs.append(PinnedDoc(title=title[:80], url=url))
    project.pinned_docs = docs[:50]
    await db.save_snapshot(store)
    return project.pinned_docs


@app.get("/man/{page}", response_model=ManPage)
async def get_man_page(page: str) -> ManPage:
    """A man page as plain text, read offline (`man -P cat`, overstrikes stripped)."""
    found = await research_svc.read_man_page(page)
    if found is None:
        raise HTTPException(404, f"no manual entry for {page}")
    text, truncated = found
    return ManPage(page=page, text=text, truncated=truncated)


# --------------------------------------------------------------------------- #
# Git & PR panel — in-app git status/log/commit + gh PR status
# --------------------------------------------------------------------------- #
@app.get("/workspaces/{ws_id}/git/status", response_model=GitStatusResponse)
async def git_status(ws_id: str) -> GitStatusResponse:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        data = await git_panel.status(ws.worktree_path, ws.branch, ws.base_ref)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git status failed: {exc.stderr}") from exc
    project = store.get_project(ws.project_id)
    if project:
        data["merge_mode"] = load_project_settings(project.path).merge_mode
    return GitStatusResponse(**data)


@app.get("/workspaces/{ws_id}/git/log")
async def git_log(ws_id: str, limit: int = 30) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    # No worktree ⇒ no history to read. Says so rather than raising (opening an archived
    # workspace used to 500 straight out of `git log`).
    if git_panel.worktree_gone(ws.worktree_path):
        return {"commits": [], "worktree_missing": True}
    commits = await git_panel.log(ws.worktree_path, ws.base_ref, limit=limit)
    return {"commits": commits}


@app.post("/workspaces/{ws_id}/git/commit")
async def git_commit(ws_id: str, req: CommitRequest) -> dict:
    """Checkpoint commit inside the worktree — no merge, no archive (unlike /merge).
    Lets the developer stage progress without leaving haro."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    if not req.message.strip():
        raise HTTPException(400, "commit message is required")
    busy = store.busy_reason(ws_id)
    if busy:
        raise HTTPException(409, f"{busy} is running: wait before committing")
    store.note_internal_write(ws_id)
    try:
        result = await git_panel.commit(
            ws.worktree_path, req.message.strip(), staged_only=req.staged_only
        )
    except git_ops.GitError as exc:
        raise HTTPException(400, f"commit failed: {exc.stderr}") from exc
    return result


async def _stage_paths(ws_id: str, req: StagePathsRequest, action) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    busy = store.busy_reason(ws_id)
    if busy:
        raise HTTPException(409, f"{busy} is running: wait before changing the index")
    store.note_internal_write(ws_id)
    try:
        await action(ws.worktree_path, req.paths)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except git_ops.GitError as exc:
        raise HTTPException(400, f"git failed: {exc.stderr}") from exc
    return {"paths": req.paths}


@app.post("/workspaces/{ws_id}/git/stage")
async def git_stage(ws_id: str, req: StagePathsRequest) -> dict:
    """Changes panel: put these paths in the index (``git add -A -- paths``)."""
    return await _stage_paths(ws_id, req, git_panel.stage)


@app.post("/workspaces/{ws_id}/git/unstage")
async def git_unstage(ws_id: str, req: StagePathsRequest) -> dict:
    """Changes panel: take these paths back out of the index; the files keep their edits."""
    return await _stage_paths(ws_id, req, git_panel.unstage)


@app.get("/workspaces/{ws_id}/git/pr", response_model=PrStatusResponse)
async def git_pr(ws_id: str) -> PrStatusResponse:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    data = await git_panel.pr_status(ws.worktree_path, ws.branch)
    # Reconcile a PR merged directly on GitHub: `gh merge` outside haro (or a
    # maintainer merging the PR) never flips our stored status, which left the UI
    # showing "Continue on a new branch" (it trusts pr.state == MERGED) while the
    # backend refused it (it required status == merged). Adopt ground truth here so
    # the two agree — the same reconcile the background merge poll runs.
    await _adopt_merged_state(ws, data)
    # Hand the panel the reconciled verdict instead of letting it re-derive one from
    # `state`, so the ship step and the workspace status can never disagree.
    return PrStatusResponse(**data, workspace_merged=ws.status == WorkspaceStatus.merged)


@app.post("/workspaces/{ws_id}/git/pr")
async def git_create_pr(ws_id: str) -> dict:
    """Open a PR for this workspace's branch — push + `gh pr create`, no merge.

    The team path (step ④ ship): request review instead of merging directly, for
    when the repo blocks non-maintainers from merging. Shares the merge gate's
    discipline — refused unless the gate is green — and, like merge, requires the
    work to be committed first (the commit is the PR's title/body via `--fill`)."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    # Same shared choke point as merge, in its "pr" flavour (see
    # integrate.ship_preflight) — the ladder's auto_pr rung clears the identical checks.
    try:
        await ship_preflight(
            workspace=ws, project=project,
            merge_mode=load_project_settings(project.path).merge_mode,
            busy=store.busy_reason(ws_id), action="pr",
        )
    except ShipRefused as exc:
        raise HTTPException(exc.status, str(exc)) from exc
    try:
        return await git_panel.create_pr(
            ws.worktree_path, ws.branch, ws.base_ref,
            plan_markdown=assist_svc.plan_markdown(ws.plans) or None,
        )
    except git_ops.GitError as exc:
        raise HTTPException(400, f"create PR failed: {exc.stderr}") from exc


# --------------------------------------------------------------------------- #
# Files (the in-app "code" view)
# --------------------------------------------------------------------------- #
@app.get("/workspaces/{ws_id}/files")
async def list_files(ws_id: str) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    return {"tree": filesvc.build_tree(Path(ws.worktree_path))}


@app.get("/workspaces/{ws_id}/raw")
async def raw_file(ws_id: str, path: str, download: bool = False):
    """Serve a worktree file as raw bytes so the code view can preview images / PDFs
    instead of the 'binary file' text error. ``download=1`` sends it as an attachment
    (the download escape hatch for binary / too-large files the editor can't open)."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        p, media = filesvc.raw_file(ws.worktree_path, path)
    except FileNotFoundError:
        raise HTTPException(404, "file not found")
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return FileResponse(
        p,
        media_type=media,
        content_disposition_type="attachment" if download else "inline",
        filename=p.name if download else None,
    )


@app.get("/workspaces/{ws_id}/file")
async def read_file(ws_id: str, path: str) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        return filesvc.read_file(ws.worktree_path, path)
    except FileNotFoundError:
        raise HTTPException(404, "file not found")
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@app.get("/workspaces/{ws_id}/file/base")
async def read_file_base(ws_id: str, path: str, ref: str | None = None) -> dict:
    """Committed content of ``path`` at ``ref`` (default the workspace's
    ``base_ref``) — the "base"/original side of the code editor's per-file diff.

    The optional ``ref`` lets the diff step through the branch **commit by
    commit** instead of the full squashed working-tree-vs-base view: the UI
    fetches ``<sha>^`` and ``<sha>`` for a single commit's before/after sides.
    A path absent at the ref (a new file) returns empty content with
    ``exists=false``, so it renders as all-additions rather than erroring."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        filesvc.safe_path(ws.worktree_path, path)  # same traversal guard as read_file
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    return await git_ops.show_file(ws.worktree_path, ref or ws.base_ref, path)


@app.get("/workspaces/{ws_id}/tsconfig")
async def workspace_tsconfig(ws_id: str) -> dict:
    """Resolved TS/JS ``compilerOptions`` from the worktree's tsconfig.json (following
    ``extends``), so the code editor's Monaco language service parses files with the
    project's own settings (jsx mode, target, decorators) instead of stock defaults.
    That's the difference between trustworthy inline syntax squiggles and false noise
    (e.g. a TSX `<div>` flagged as a syntax error under the wrong jsx mode).
    ``compilerOptions`` is null when the worktree has no tsconfig."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    return {"compilerOptions": filesvc.resolve_tsconfig(ws.worktree_path)}


@app.post("/workspaces/{ws_id}/context")
async def attach_context(ws_id: str, req: ContextAttachRequest) -> dict:
    """Promote a large pasted block to a git-excluded ``.context/`` file the agent can
    read via an ``@`` mention. Returns the worktree-relative path + a line count so the
    composer can render a chip. Kept out of git (info/exclude) so the attachment never
    dirties the tree or lands in a PR."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    stem = git_ops.slugify(req.name or "pasted")
    rel = f".context/{stem}-{os.urandom(3).hex()}.txt"
    try:
        await git_ops.ensure_excluded(ws.worktree_path, ".context/")
        filesvc.write_file(ws.worktree_path, rel, req.content)
    except (ValueError, OSError, git_ops.GitError) as exc:
        raise HTTPException(400, f"could not save attachment: {exc}")
    lines = req.content.count("\n") + 1 if req.content else 0
    return {"path": rel, "name": Path(rel).name, "lines": lines, "kind": "text"}


# Cap on a single attachment so a stray huge paste/upload can't fill the disk or
# blow up the base64 JSON body. 25 MB comfortably covers screenshots + docs.
_MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024


@app.post("/workspaces/{ws_id}/context/upload")
async def upload_context(ws_id: str, req: ContextUploadRequest) -> dict:
    """Promote a pasted image or a picked file to a git-excluded ``.context/``
    attachment (the binary sibling of ``/context``). The base64 payload is decoded
    to raw bytes and written keeping the original extension, so the code view can
    preview it and Claude Code reads it via the same ``@`` mention. Kept out of git
    (info/exclude) so it never dirties the tree or lands in a PR."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        data = base64.b64decode(req.content_b64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(400, "attachment is not valid base64")
    if not data:
        raise HTTPException(400, "attachment is empty")
    if len(data) > _MAX_ATTACHMENT_BYTES:
        raise HTTPException(400, "attachment too large (max 25 MB)")
    orig = Path(req.name or "upload").name
    stem = git_ops.slugify(Path(orig).stem or "upload")
    ext = Path(orig).suffix.lower()
    rel = f".context/{stem}-{os.urandom(3).hex()}{ext}"
    try:
        await git_ops.ensure_excluded(ws.worktree_path, ".context/")
        filesvc.write_bytes(ws.worktree_path, rel, data)
    except (ValueError, OSError, git_ops.GitError) as exc:
        raise HTTPException(400, f"could not save attachment: {exc}")
    kind = "image" if (req.content_type or "").startswith("image/") else "file"
    return {"path": rel, "name": Path(rel).name, "kind": kind, "size": len(data)}


@app.get("/workspaces/{ws_id}/search")
async def search(ws_id: str, q: str, limit: int = 200) -> dict:
    """Find-in-files across the worktree (ripgrep, or grep fallback)."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    return await filesvc.search_text(ws.worktree_path, q, limit)


@app.get("/editors")
async def list_editors(refresh: bool = False) -> list[EditorInfo]:
    """Detected "Open in..." targets (cached; ``?refresh=1`` re-probes)."""
    return editors_svc.list_editors(editors_svc.get_detection(dict(os.environ), refresh))


@app.post("/workspaces/{ws_id}/open")
async def open_in_editor(ws_id: str, req: OpenInRequest) -> OpenInResponse:
    """Open the worktree (or one file at a line) in an external editor.

    GUI editors and the file manager are spawned detached from the worktree with the
    Shell PTY's env. Terminal editors are NOT spawned: the response carries the exact
    command for the client to type into the Shell tab."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    if not Path(ws.worktree_path).is_dir():
        raise HTTPException(400, "worktree not found on disk")
    if req.line is not None and req.line < 1:
        raise HTTPException(400, "line must be >= 1")
    if req.line is not None and not req.path:
        raise HTTPException(400, "line requires a path")
    try:
        file = editors_svc.resolve_target_path(ws.worktree_path, req.path)
    except FileNotFoundError:
        raise HTTPException(404, "file not found")
    except ValueError as exc:
        raise HTTPException(400, str(exc))

    detection = editors_svc.get_detection(dict(os.environ))
    found = detection.get(req.target)
    if found is not None and not found.available:
        # Installed since the cache was built? Re-probe once before refusing.
        found = editors_svc.get_detection(dict(os.environ), refresh=True).get(req.target)
    if found is None:
        raise HTTPException(400, f"unknown editor target: {req.target}")
    if not found.available:
        raise HTTPException(400, f"{found.label} is not available on this machine")

    if found.kind == "terminal":
        return OpenInResponse(
            mode="shell",
            command=editors_svc.build_shell_command(found, ws.worktree_path, file, req.line),
        )

    project = store.get_project(ws.project_id)
    env = script_env(ws, project) if project else dict(os.environ)
    argv = editors_svc.build_argv(found, str(Path(ws.worktree_path).resolve()), file, req.line)
    try:
        await editors_svc.spawn_detached(argv, ws.worktree_path, env)
    except OSError as exc:
        raise HTTPException(400, f"failed to launch {found.label}: {exc}")
    return OpenInResponse(mode="spawned")


@app.put("/workspaces/{ws_id}/file")
async def write_file(ws_id: str, req: WriteFileRequest) -> dict:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        filesvc.write_file(ws.worktree_path, req.path, req.content)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    store.note_user_write(ws_id, req.path)
    xp_hooks.note_hand_saved(ws, req.path)
    return {"saved": req.path}


@app.post("/workspaces/{ws_id}/fs/create")
async def create_entry(ws_id: str, req: CreateEntryRequest) -> dict:
    """Tree right-click: create a new empty file or a new folder in the worktree."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        filesvc.create_entry(ws.worktree_path, req.path, req.dir)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    store.note_user_write(ws_id, req.path)
    return {"created": req.path, "dir": req.dir}


@app.post("/workspaces/{ws_id}/fs/rename")
async def rename_entry(ws_id: str, req: RenameEntryRequest) -> dict:
    """Tree right-click: rename / move a file or folder within the worktree."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        filesvc.rename_entry(ws.worktree_path, req.path, req.to)
    except FileNotFoundError:
        raise HTTPException(404, "file not found")
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    store.note_user_write(ws_id, req.path)
    store.note_user_write(ws_id, req.to)
    return {"renamed": req.path, "to": req.to}


@app.post("/workspaces/{ws_id}/fs/delete")
async def delete_entry(ws_id: str, req: DeleteEntryRequest) -> dict:
    """Tree right-click: delete a file or folder (recursive) from the worktree."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    try:
        filesvc.delete_entry(ws.worktree_path, req.path)
    except FileNotFoundError:
        raise HTTPException(404, "file not found")
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    store.note_user_write(ws_id, req.path)
    return {"deleted": req.path}


# --------------------------------------------------------------------------- #
# The gate (tests)
# --------------------------------------------------------------------------- #
@app.post("/workspaces/{ws_id}/tests", response_model=TestRun)
async def run_tests(ws_id: str, scope: str = "all") -> TestRun:
    """Manually run the merge gate now (also runs automatically after an agent).

    ``scope=impacted`` runs only the tests affected by the diff vs base_ref —
    the fast gate powered by the Impact Map. ``scope=failed`` re-runs just the
    tests that were red in the last run — the tight inner loop while fixing.
    """
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    busy = store.busy_reason(ws_id)
    if busy:
        raise HTTPException(409, f"{busy} is already running in this workspace")

    changed_since = ws.base_ref if scope == "impacted" else None
    only = None
    if scope == "failed":
        latest = store.latest_test(ws_id)
        only = [(c.file, c.name) for c in (latest.cases if latest else []) if c.status == "failed"]
        if not only:
            raise HTTPException(409, "no failing tests to re-run: run the full gate first")
    # gate_and_fire, not run_gate: a green gate hands off to the autonomy ladder's armed
    # rung (auto_pr — a no-op unless the project opted in). Same handoff the agent→gate
    # path performs, so where the green came from doesn't change what it earns.
    task = asyncio.create_task(
        rungs.gate_and_fire(
            store=store,
            hub=hub,
            adapter=_test_adapter(project.path),
            workspace=ws,
            project_path=project.path,
            changed_since=changed_since,
            only=only,
            trigger="manual",
        )
    )
    store.gate_tasks[ws_id] = task
    # Return the latest snapshot; live updates flow over the WebSocket.
    return store.latest_test(ws_id) or TestRun(workspace_id=ws_id, runner="vitest")


@app.get("/workspaces/{ws_id}/impact", response_model=ImpactResponse)
async def impact(ws_id: str) -> ImpactResponse:
    """The Impact Map: changed files + the tests the diff provably affects."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")

    # The Impact Map is a non-critical "smart insight" panel, and it's fetched
    # automatically the moment a workspace goes idle (see the frontend socket's
    # refreshImpact-on-idle). A git/adapter hiccup here — e.g. a base_ref that
    # doesn't resolve in the worktree, or an env quirk in the container — must
    # NOT surface as a raw 500 ("Internal Server Error" toast) on every fresh
    # workspace. Degrade like analyze_impact does internally: report the reason
    # in `error`/`supported=False`, and print the traceback so the true cause is
    # visible in the backend/container log.
    try:
        ensure_deps(ws.worktree_path, project.path)
        changed = await git_ops.changed_files(ws.worktree_path, ws.base_ref)
        imp = await _test_adapter(project.path).analyze_impact(
            cwd=ws.worktree_path, base_ref=ws.base_ref
        )
    except Exception as exc:  # noqa: BLE001 — a broken insight panel must not 500 the workspace
        traceback.print_exc()
        detail = exc.stderr if isinstance(exc, git_ops.GitError) else f"{type(exc).__name__}: {exc}"
        # supported=True (the runner DOES do impact) + error → the panel shows the
        # reason, matching analyze_impact's own degraded-but-supported convention.
        return ImpactResponse(base_ref=ws.base_ref, supported=True, error=f"impact analysis failed: {detail}")

    impacted_files = sorted({t.file for t in imp.impacted})
    total_test_files = len({t.file for t in imp.all_tests})
    return ImpactResponse(
        base_ref=ws.base_ref,
        supported=imp.supported,
        error=imp.error,
        changed_files=changed,
        total_tests=len(imp.all_tests),
        total_test_files=total_test_files,
        impacted_tests=[{"file": t.file, "name": t.name} for t in imp.impacted],
        impacted_files=impacted_files,
    )


@app.get("/workspaces/{ws_id}/blame", response_model=BlameResponse)
async def blame(ws_id: str) -> BlameResponse:
    """Failure → blame: for each failing test in the latest run, the changed lines
    (vs base_ref) whose stack frames implicate them — "test X is red *because* you
    changed line Y". The reverse of the Impact Map.

    Degrades softly like ``/impact``: a git hiccup or a base_ref that doesn't resolve
    reports the reason in ``error`` instead of 500-ing the workspace.
    """
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    run = store.latest_test(ws_id)
    if not run:
        return BlameResponse(base_ref=ws.base_ref)
    failing = [c for c in run.cases if c.status == "failed"]
    if not failing:
        return BlameResponse(base_ref=ws.base_ref)

    try:
        diff_text, _ = await git_ops.diff(ws.worktree_path, ws.base_ref)
    except Exception as exc:  # noqa: BLE001 — a broken insight panel must not 500 the workspace
        traceback.print_exc()
        detail = exc.stderr if isinstance(exc, git_ops.GitError) else f"{type(exc).__name__}: {exc}"
        return BlameResponse(base_ref=ws.base_ref, error=f"blame failed: {detail}")

    changed = blame_svc.changed_lines(diff_text)
    entries: list[BlameEntry] = []
    for c in failing:
        hunks = blame_svc.blame_message(c.stack or c.message, changed)
        if hunks:
            entries.append(BlameEntry(file=c.file, name=c.name, hunks=hunks))
    return BlameResponse(base_ref=ws.base_ref, entries=entries)


@app.post("/workspaces/{ws_id}/checked")
async def set_row_checked(ws_id: str, req: CheckedRowRequest) -> dict:
    """Tick a "code to check" row off, or put it back (backlog/code-to-check.md).

    This is the difference between a report and a worklist. Four of the eight row kinds — a
    new dependency, a touched secret file, a deletion, a migration — ask for a human's
    confirmation and can never be closed by writing a test, so before this endpoint the pane
    was structurally unable to reach zero on those diffs. Measured on this repo's own
    history: of 20 workspaces that ever raised a row, exactly one reached zero.

    The tick is stored against the row's KEY, which embeds the claim's count, so it survives
    a re-gate that reproduces the same claim and dies on one that does not. It records that
    someone looked; it does not mark anything verified, and it cannot unblock a merge — the
    pane never gated one.
    """
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    key = (req.key or "").strip()
    if not key:
        raise HTTPException(400, "a row key is required")
    checked = [k for k in ws.checked_rows if k != key]
    if req.checked:
        checked.append(key)
    ws.checked_rows = checked
    # Keep the glance badge honest the moment the tick lands, rather than waiting for the
    # next gate to recompute it — the dashboard card reads this, not the row list.
    if ws.gate and ws.gate.unchecked_count is not None:
        latest = store.latest_test(ws_id)
        rows = (latest.unchecked_items or []) if latest else []
        ws.gate.unchecked_count = sum(1 for r in rows if r.key not in set(checked))
    await db.save_snapshot(store)
    return {"checked_rows": ws.checked_rows}


@app.get("/workspaces/{ws_id}/verified-hunks", response_model=VerifiedHunksResponse)
async def get_verified_hunks(ws_id: str) -> VerifiedHunksResponse:
    """Per-line proof for the ④ ship diff (backlog/verified-hunks.md §2).

    Intersects the last green gate's per-line coverage map (cached at gate time — this
    endpoint never runs a suite) with the diff's added lines, so the reviewer sees which
    lines the passing suite actually **executed** and which it never touched.

    Every "we cannot say" case returns ``supported=False`` with a note naming the reason,
    because the reasons want different fixes: the feature is off (Gate settings), the runner
    is not vitest (the honest Vitest-only ceiling), no coverage provider is installed, or no
    green gate has measured this tree yet. Silence with a reason beats a blank surface that
    reads like "nothing to flag".
    """
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")

    def _off(note: str) -> VerifiedHunksResponse:
        return VerifiedHunksResponse(base_ref=ws.base_ref, note=note)

    project = store.get_project(ws.project_id)
    if not project:
        return _off("project not found")
    settings_ = load_project_settings(project.path)
    if not settings_.verified_hunks:
        return _off("per-line proof is off for this project: turn it on in Gate settings")
    runner = settings_.gate_runner or "vitest"
    if runner != "vitest":
        # The Vitest-only ceiling, stated rather than hidden: pytest/command runners have no
        # per-line coverage seam yet, and inventing one badge from a suite-level number
        # would be exactly the overclaim this feature exists to avoid.
        return _off(f"per-line coverage is vitest-only for now (this gate runs {runner})")

    snap = store.get_line_hits(ws_id)
    if ws.status != WorkspaceStatus.gate_green or not snap:
        # Green-only. Vitest emits coverage only on a passing run, and a red gate must show
        # no badges at all rather than a previous green's.
        return _off("no green gate has measured this tree yet: run the full gate")
    if not snap.get("line_hits"):
        return _off(
            "the gate ran but produced no coverage: install a coverage provider "
            "(@vitest/coverage-v8) so lines can be attributed"
        )

    try:
        current_diff, _ = await git_ops.diff(ws.worktree_path, ws.base_ref)
    except Exception as exc:  # noqa: BLE001 — a broken proof surface must not 500 the workspace
        traceback.print_exc()
        detail = exc.stderr if isinstance(exc, git_ops.GitError) else f"{type(exc).__name__}: {exc}"
        return _off(f"could not read the diff: {detail}")

    report = verified_hunks_svc.annotate(
        snap.get("diff") or "",
        current_diff,
        snap.get("line_hits"),
        scope=snap.get("scope") or "",
    )
    return VerifiedHunksResponse(
        base_ref=ws.base_ref,
        gate_sha=snap.get("sha"),
        supported=True,
        stale=report.stale,
        files=[
            VerifiedFile(
                path=f.path,
                in_map=f.in_map,
                stale=f.stale,
                added=f.added,
                executed=f.executed,
                unexecuted=f.unexecuted,
                noncoverable=f.noncoverable,
                # JSON object keys are strings; the client parses them back to line numbers.
                lines={str(k): v for k, v in f.lines.items()},
            )
            for f in report.files
        ],
        note=report.note,
    )


# The JS/TS files whose *added* lines we mutate: real source only, never the tests
# that grade it (mutating a test proves nothing) nor config/type-only files.
def _is_mutable_source(path: str) -> bool:
    p = path.lower()
    if not p.endswith((".ts", ".tsx", ".js", ".jsx", ".mts", ".cts")):
        return False
    if p.endswith(".d.ts"):
        return False
    base = p.rsplit("/", 1)[-1]
    if ".test." in base or ".spec." in base or "vitest.config" in base or "vitest.setup" in base:
        return False
    return True


@app.post("/workspaces/{ws_id}/mutation", response_model=MutationResponse)
async def run_workspace_mutation(ws_id: str) -> MutationResponse:
    """Mutation score for the ③ verify residue (backlog/mutation-gate.md) — the
    "would the tests notice if the code were wrong?" test.

    A green gate proves the suite *passes*; it cannot prove the suite would *fail* if
    the new code were subtly wrong, because the agent authored the tests that grade its
    own code. This mutates each added source line one at a time, re-runs the (impacted)
    suite, and reports the faults the tests can't tell apart (survivors) — the shortlist
    a reviewer should actually read.

    ADVISORY by construction, same stance as verified-hunks: it never sets
    ``workspace.status``/``.gate``/``store.tests`` and there is no ``mutation_blocked``,
    so it can never touch a verdict the tests earned or the trust streak. Every "we
    cannot say" case returns ``supported=False`` with a note naming the reason (off ·
    non-vitest runner · no green gate on this tree yet), because those want different
    fixes. It re-runs the suite once per mutant, so it is on-demand — off the ~1s gate
    path — behind the ``[gate] mutation`` switch.
    """
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")

    def _off(note: str) -> MutationResponse:
        return MutationResponse(base_ref=ws.base_ref, note=note)

    project = store.get_project(ws.project_id)
    if not project:
        return _off("project not found")
    settings_ = load_project_settings(project.path)
    if not settings_.mutation:
        return _off("mutation score is off for this project — turn it on in Gate settings")
    runner = settings_.gate_runner or "vitest"
    if runner != "vitest":
        return _off(f"mutation score is vitest-only for now (this gate runs {runner})")
    if ws.status != WorkspaceStatus.gate_green:
        # Green-only: a mutant is scored against a suite that was passing before the
        # fault, so mutating a red (or never-gated) tree would compare against noise.
        return _off("no green gate on this tree yet — make the gate green, then score its tests")

    try:
        diff_text, _ = await git_ops.diff(ws.worktree_path, ws.base_ref)
    except Exception as exc:  # noqa: BLE001 — a broken analysis surface must not 500 the workspace
        traceback.print_exc()
        detail = exc.stderr if isinstance(exc, git_ops.GitError) else f"{type(exc).__name__}: {exc}"
        return _off(f"could not read the diff: {detail}")

    # Diff-scoped: only the added source lines, per file (never the tests/config).
    added_by_file = blame_svc.changed_lines(diff_text)  # {path: {line_no: text}}
    changed: dict[str, tuple[str, list[int]]] = {}
    for path, lines in added_by_file.items():
        if not _is_mutable_source(path):
            continue
        try:
            source = (Path(ws.worktree_path) / path).read_text()
        except OSError:
            continue
        changed[path] = (source, sorted(lines.keys()))
    if not changed:
        return _off("no mutable source on the added lines (tests/config only)")

    # cwd/dep_root are gate_dir-aware (monorepos) — same resolution the gate uses.
    cwd, dep_root = analytics_svc._resolve(project, ws.worktree_path)
    adapter = _test_adapter(project.path)
    # From here on this endpoint writes into the worktree (deps link, the baseline run, then
    # mutants), so an assist job running alongside must read its git guard as inconclusive.
    store.note_internal_write(ws_id)
    store.mutation_running.add(ws_id)
    try:
        ensure_deps(cwd, dep_root)
        baseline = await adapter.run(cwd=cwd)
    except BaseException:
        store.mutation_running.discard(ws_id)
        raise

    # Baseline sanity — the load-bearing guard. The UNMUTATED suite must actually run
    # tests AND pass right now: if zero tests execute here, every mutant would "pass"
    # vacuously and the score would be a confident lie (0 killed / all survived). A
    # green gate means it passed once; this checks it still runs, on this exact cwd.
    if not baseline.ok or baseline.total == 0:
        store.mutation_running.discard(ws_id)
        return _off(
            "the suite didn't run cleanly on this tree just now "
            f"({baseline.passed}/{baseline.total} passed) — re-run the gate, then score"
        )

    def _write(rel: str, content: str) -> None:
        (Path(ws.worktree_path) / rel).write_text(content)

    # Run the FULL suite per mutant. Impacted-only scoping (run just the tests covering
    # the mutated file) is the obvious speed-up, but a vitest `-t` filter that matches
    # nothing passes VACUOUSLY — which would make every mutant look "survived" (the exact
    # bug this baseline guard exists to catch). Deferred until that scoping carries its
    # own >0-tests check; correctness first, and the diff-scoped mutant count already
    # bounds the full-suite cost.
    async def _run_suite(_wt: str) -> mutation_svc.SuiteVerdict:
        result = await adapter.run(cwd=cwd)
        if result.ok:
            return mutation_svc.SuiteVerdict.PASSED
        # A mutant that fails to compile/parse ran no tests — that is a SKIP, not a
        # catch: counting it as killed would inflate the score exactly where it lies.
        if result.total == 0 and result.error:
            return mutation_svc.SuiteVerdict.ERROR
        return mutation_svc.SuiteVerdict.FAILED

    try:
        report = await mutation_svc.run_mutation(
            worktree_path=ws.worktree_path,
            changed=changed,
            run_suite=_run_suite,
            write_file=_write,
            runner=runner,
        )
    finally:
        store.mutation_running.discard(ws_id)

    resp = MutationResponse(
        base_ref=ws.base_ref,
        gate_sha=(store.get_line_hits(ws_id) or {}).get("sha"),
        # The staleness key the Gate Receipt (receipt.py) actually relies on: `gate_sha`
        # alone can't detect a moved-but-uncommitted tree (haro doesn't commit agent work
        # until merge), so this fingerprints the diff text the mutation pass measured.
        diff_fingerprint=receipt_svc.diff_fingerprint(diff_text),
        supported=report.supported,
        score=report.score,
        killed=report.killed,
        survived=report.survived,
        skipped=report.skipped,
        total_mutants=report.total_mutants,
        budget_capped=report.budget_capped,
        survivors=[
            MutationSurvivor(path=s.file, line=s.line, operator=s.label)
            for s in report.survivors
        ],
        note=report.note,
    )
    store.mutation_runs[ws_id] = resp
    if resp.supported and resp.score is not None:
        xp_hooks.note_mutation(ws, resp.survived)
    return resp


@app.get("/workspaces/{ws_id}/receipt", response_model=ReceiptResponse)
async def get_receipt(ws_id: str) -> ReceiptResponse:
    """The Gate Receipt (usp-critique-plan.md idea 1): the exportable evidence packet
    for the ④ ship step, assembled from facts the gate already computed. Never runs a
    test, a mutation pass, or a gh call — see receipt.py."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    settings_ = load_project_settings(project.path)
    rcpt = await receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_)
    return ReceiptResponse(receipt=rcpt, markdown=receipt_svc.render_markdown(rcpt))


# --------------------------------------------------------------------------- #
# XP, rank, streak (Step 4, xp.py)
# --------------------------------------------------------------------------- #
@app.get("/xp", response_model=XpStatus)
async def get_xp() -> XpStatus:
    return xp_svc.build_status(store.list_xp_events(), time.time())


@app.get("/xp/rules", response_model=XpRules)
async def get_xp_rules() -> XpRules:
    """The award table, straight from ``xp.RULES``: the client renders "How XP works" from it."""
    return xp_svc.rules_payload()


@app.get("/xp/events", response_model=list[XpEvent])
async def get_xp_events(limit: int = 50) -> list[XpEvent]:
    """The newest ledger rows first."""
    return list(reversed(store.list_xp_events()))[: max(1, min(limit, 500))]


@app.post("/xp/activity", response_model=XpActivityResponse)
async def post_xp_activity(req: XpActivityRequest) -> XpActivityResponse:
    """Activities only the client can observe (a Docs read, the Diff view). The server decides
    whether it pays: once per kind per local day, once per workspace for a diff review, and a
    diff review only when the reported files cover every file changed right now."""
    if req.kind not in xp_svc.CLIENT_KINDS:
        raise HTTPException(400, f"unknown activity: {req.kind}")
    # Both client kinds need the workspace: the rate follows its by-hand status.
    if not req.workspace_id:
        raise HTTPException(400, f"{req.kind} needs a workspace")
    ws = store.get_workspace(req.workspace_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    if req.kind == "diff_reviewed":
        awards = await xp_hooks.record_diff_reviewed(store, hub, ws, req.paths)
    else:
        awards = await xp_hooks.record_activity(store, hub, req.kind, ws.id)
    if awards:
        await db.save_snapshot(store)
    return XpActivityResponse(
        awards=[XpAward(kind=a.kind, amount=a.amount, label=a.label, badge=a.badge) for a in awards]
    )


_verifying: set[str] = set()


@app.post("/workspaces/{ws_id}/verify")
async def verify_workspace(ws_id: str) -> dict:
    """Signature check + gate rerun for the workspace's latest saved attestation
    (the ``haro verify <sha> --rerun`` logic, ``reproduce.py``). Slow: it runs the
    whole gate again in a throwaway worktree."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    found = attest_svc.latest_envelope(ws.worktree_path)
    if found is None:
        raise HTTPException(404, "no saved attestation for this workspace (run `haro gate --attest`)")
    sha, envelope = found
    statement = attest_svc.verify_envelope(envelope, attest_svc.ensure_key().public_key())
    if statement is None:
        raise HTTPException(409, "signature does not match: the attestation was tampered with or signed by another key")
    if ws_id in _verifying:
        raise HTTPException(409, "a reproduce is already running for this workspace")
    _verifying.add(ws_id)
    try:
        result = await reproduce_svc.reproduce(ws.worktree_path, statement)
    finally:
        _verifying.discard(ws_id)
    return {"attestation": sha, **result.to_dict()}


@app.post("/workspaces/{ws_id}/receipt/pr-comment")
async def post_receipt_pr_comment(ws_id: str) -> dict:
    """Post the Gate Receipt as a comment on this branch's PR via ``gh`` — the sink
    that carries the evidence to a reviewer who never installed haro. Explicit action
    (a button), never automatic: posting to a shared PR is a visible side effect."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    settings_ = load_project_settings(project.path)
    rcpt = await receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_)
    markdown = receipt_svc.render_markdown(rcpt)
    try:
        return await git_panel.comment_pr(ws.worktree_path, ws.branch, markdown)
    except git_ops.GitError as exc:
        raise HTTPException(400, exc.stderr or str(exc)) from exc


@app.get("/workspaces/{ws_id}/history", response_model=list[TestRun])
async def history(ws_id: str) -> list[TestRun]:
    """All gate runs for the workspace (oldest → newest) — the regression ribbon."""
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    return store.test_history(ws_id)


@app.get("/workspaces/{ws_id}/watch")
async def get_watch(ws_id: str) -> dict:
    """The Live Gate's last ADVISORY run, for the rail's rehydrate-on-reload
    (backlog/live-gate.md). ``enabled`` reflects ``[gate] watch`` so the panel can tell
    "off" from "on but nothing has run yet" — two states that need different empty text.

    ``run`` is never a ship verdict and deliberately isn't in ``store.tests``: it lives in
    the in-memory ``store.watch_runs`` only, so a restart forgets it (by design — a vital
    sign describes *now*)."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    run = store.watch_runs.get(ws_id)
    return {
        "enabled": load_project_settings(project.path).gate_watch,
        "run": run.model_dump() if run else None,
    }


@app.get("/workspaces/{ws_id}/trust")
async def get_trust(ws_id: str) -> dict:
    """The autonomy-ladder report: the merge-policy conditions + project streak, ANDed
    into an earned-auto-merge verdict (backlog/autonomy-ladder.md). Same shape the gate
    re-broadcasts on the ``status`` channel, so the checklist can render off either."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    settings = load_project_settings(project.path)
    return build_trust_report(store, ws, settings).to_dict()


def _require_idle(ws_id: str, what: str) -> tuple[Workspace, Project]:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    busy = store.busy_reason(ws_id)
    if busy:
        raise HTTPException(409, f"{busy} is running: wait before running {what}")
    return ws, project


@app.get("/workspaces/{ws_id}/coverage")
async def coverage(ws_id: str) -> dict:
    """Coverage delta: current worktree coverage vs. the base_ref baseline."""
    ws, project = _require_idle(ws_id, "coverage")
    return await coverage_delta(store=store, workspace=ws, project=project)


@app.post("/workspaces/{ws_id}/flaky")
async def flaky(ws_id: str, runs: int = 5) -> dict:
    """Re-run the suite N times and flag tests whose pass/fail flips."""
    ws, project = _require_idle(ws_id, "the flaky check")
    result = await detect_flaky(workspace=ws, project=project, runs=max(2, min(runs, 20)))
    for f in result.get("flaky", []):
        store.add_known_flaky(
            project.id, f["file"], f["name"], passed=f["passed"], failed=f["failed"]
        )
    if result.get("flaky"):
        await db.save_snapshot(store)
    return result


@app.get("/projects/{project_id}/known-flaky", response_model=list[KnownFlaky])
async def list_known_flaky(project_id: str) -> list[KnownFlaky]:
    """The project's known-flaky tests: the only set ``[gate] flaky_retry`` acts on.
    Populated by ``POST /workspaces/{id}/flaky``."""
    if not store.get_project(project_id):
        raise HTTPException(404, "project not found")
    return store.list_known_flaky(project_id)


@app.delete("/projects/{project_id}/known-flaky")
async def remove_known_flaky(
    project_id: str, file: str | None = None, name: str | None = None
) -> dict:
    """Un-flag one test (``file`` + ``name``), or every test when neither is given."""
    if not store.get_project(project_id):
        raise HTTPException(404, "project not found")
    if (file is None) != (name is None):
        raise HTTPException(400, "pass both file and name, or neither to clear the list")
    removed = store.remove_known_flaky(project_id, file=file, name=name)
    await db.save_snapshot(store)
    return {"removed": removed}


@app.post("/workspaces/{ws_id}/run")
async def run_app(ws_id: str, run_id: str | None = None) -> dict:
    """Start a `run` script (dev server) in the worktree, on its port. ``run_id``
    picks a named run (web/worker/test); omitted → the default run."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    psettings = load_project_settings(project.path)
    store.note_internal_write(ws_id)  # a dev server may write build output into the tree
    try:
        url = await start_run(
            store=store, hub=hub, workspace=ws, project=project,
            psettings=psettings, run_id=run_id,
        )
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"running": True, "url": url}


@app.post("/workspaces/{ws_id}/run/stop")
async def stop_app(ws_id: str, run_id: str | None = None) -> dict:
    """Stop a named run (``run_id``), or every run in the workspace when omitted."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    await stop_run(store=store, workspace=ws, run_id=run_id)
    return {"running": False}


@app.get("/workspaces/{ws_id}/setup")
async def get_setup(ws_id: str) -> dict:
    """Setup ('deps') state for the gate chip: running / ok / failed + exit code."""
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    return store.setup_state.get(ws_id) or {"status": "unknown", "exit": None, "note": None}


@app.post("/workspaces/{ws_id}/setup")
async def rerun_setup(ws_id: str) -> dict:
    """Re-run the setup script on demand (e.g. after fixing a failed provision).
    Blocked while an agent or the gate is mid-run."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    busy = store.busy_reason(ws_id)
    if busy:
        raise HTTPException(409, f"{busy} is running: wait before re-running setup")
    psettings = load_project_settings(project.path)
    store.set_active_task(ws_id, SETUP_SESSION, asyncio.create_task(
        run_setup(store=store, hub=hub, workspace=ws, project=project, psettings=psettings)
    ))
    return {"status": "running"}


def _project_for(ws_id: str) -> Project:
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return project


def _run_infos(ps, ws: Workspace | None = None, root: str | None = None) -> list[RunScriptInfo]:
    """Build the Run-menu list from a project's parsed run scripts, attaching live
    process state (running/url) when a workspace is given, and the static
    ``package.json`` check (``problem``) against ``root`` (the worktree, else the
    project path)."""
    out: list[RunScriptInfo] = []
    if root is None and ws is not None:
        root = ws.worktree_path
    for r in ps.runs:
        running = False
        url = None
        if ws is not None:
            key = (ws.id, r.id)
            proc = store.run_procs.get(key)
            running = proc is not None and proc.returncode is None
            if running:
                port = ws.port if r.default else store.run_ports.get(key)
                url = f"http://localhost:{port}" if port is not None else None
        out.append(
            RunScriptInfo(
                id=r.id, command=r.command, default=r.default, icon=r.icon,
                running=running, url=url,
                problem=missing_script(r.command, root) if root else None,
            )
        )
    return out


@app.get("/workspaces/{ws_id}/scripts", response_model=ScriptsConfig)
async def get_scripts(ws_id: str) -> ScriptsConfig:
    """The workspace's *effective* (inherited) `[scripts]` config
    (setup/run/archive + login_shell + the named `runs`), read-only — the workspace
    preview shows it; scripts are edited project-level via the Setup tab
    (`PUT /projects/{id}/scripts`) so there's a single source of truth."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = _project_for(ws_id)
    ps = load_project_settings(project.path)
    return ScriptsConfig(
        setup=ps.setup, run=ps.run, runs=_run_infos(ps, ws), archive=ps.archive,
        run_mode=ps.run_mode, login_shell=ps.login_shell,
    )


@app.get("/workspaces/{ws_id}/instructions", response_model=InstructionsConfig)
async def get_instructions(ws_id: str) -> InstructionsConfig:
    """The project's custom instructions (Tier-1), split into shared (committed)
    and local (personal) for the in-app editor."""
    project = _project_for(ws_id)
    shared, local = read_instructions(project.path)
    return InstructionsConfig(shared=shared, local=local)


@app.put("/workspaces/{ws_id}/instructions", response_model=InstructionsConfig)
async def put_instructions(ws_id: str, req: InstructionsUpdateRequest) -> InstructionsConfig:
    """Save custom instructions to instructions.local.md (personal) or
    instructions.md (committed → the whole team's agents inherit them). Takes
    effect on the next agent run (appended via `--append-system-prompt`)."""
    project = _project_for(ws_id)
    write_instructions(project.path, req.text, target=req.target)
    shared, local = read_instructions(project.path)
    return InstructionsConfig(shared=shared, local=local)


def _project_by_id(project_id: str) -> Project:
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")
    return project


@app.get("/projects/{project_id}/instructions", response_model=InstructionsConfig)
async def get_project_instructions(project_id: str) -> InstructionsConfig:
    """Same Tier-1 custom instructions as the workspace route, keyed by project
    id — lets the global Settings page edit them without an open workspace."""
    project = _project_by_id(project_id)
    shared, local = read_instructions(project.path)
    return InstructionsConfig(shared=shared, local=local)


@app.put("/projects/{project_id}/instructions", response_model=InstructionsConfig)
async def put_project_instructions(
    project_id: str, req: InstructionsUpdateRequest
) -> InstructionsConfig:
    """Save the project's custom instructions (personal `.local` or committed
    team file) from the global Settings page. Applies on the next agent run."""
    project = _project_by_id(project_id)
    write_instructions(project.path, req.text, target=req.target)
    shared, local = read_instructions(project.path)
    return InstructionsConfig(shared=shared, local=local)


@app.get("/projects/{project_id}/scripts", response_model=ScriptsConfig)
async def get_project_scripts(project_id: str) -> ScriptsConfig:
    """Same `[scripts]` config as the workspace route, keyed by project id — the
    project Setup tab edits it without an open workspace."""
    project = _project_by_id(project_id)
    ps = load_project_settings(project.path)
    return ScriptsConfig(
        setup=ps.setup, run=ps.run, runs=_run_infos(ps, root=project.path), archive=ps.archive,
        run_mode=ps.run_mode, login_shell=ps.login_shell,
    )


@app.put("/projects/{project_id}/scripts", response_model=ScriptsConfig)
async def put_project_scripts(project_id: str, req: ScriptsUpdateRequest) -> ScriptsConfig:
    """Save the project's scripts to settings.local.toml (personal) or settings.toml
    (shared/committed → the whole team inherits it), from the project Setup tab."""
    project = _project_by_id(project_id)
    ps = load_project_settings(project.path)  # preserve the existing port range
    write_project_scripts(
        project.path,
        setup=req.setup or None,
        run=req.run or None,
        archive=req.archive or None,
        run_mode=req.run_mode,
        login_shell=req.login_shell,
        port_range=ps.port_range,
        target=req.target,
    )
    updated = load_project_settings(project.path)
    return ScriptsConfig(
        setup=updated.setup, run=updated.run, runs=_run_infos(updated, root=project.path), archive=updated.archive,
        run_mode=updated.run_mode, login_shell=updated.login_shell,
    )


@app.get("/workspaces/{ws_id}/tests", response_model=TestRun | None)
async def get_tests(ws_id: str) -> TestRun | None:
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    return store.latest_test(ws_id)


@app.get("/workspaces/{ws_id}/sessions")
async def get_sessions(ws_id: str) -> dict:
    """The agent sessions that have a transcript in this workspace (first-seen order) —
    the set the stream's session switcher enumerates. Always includes the primary
    session so a fresh workspace still shows one tab (the UI unions it in too)."""
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    ids = store.sessions(ws_id)
    if DEFAULT_SESSION not in ids:
        ids = [DEFAULT_SESSION, *ids]
    return {"sessions": ids}


@app.get("/workspaces/{ws_id}/events")
async def get_events(ws_id: str, session: str = DEFAULT_SESSION) -> dict:
    """The persisted agent transcript for one session (survives refresh/restart).
    ``session`` defaults to the primary session — the switcher passes a tab's id to
    load that session's own stream."""
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    return {"events": store.events_for(ws_id, session)}


@app.get("/workspaces/{ws_id}/turns")
async def get_turns(ws_id: str, session: str = DEFAULT_SESSION) -> dict:
    """Turn boundaries in a session's persisted transcript — the "rewind to here" anchors.
    Each event carries its ``turn`` ordinal too (see GET /events); this is the
    derived per-turn summary (ordinal + prompt + kind) the UI lists rewind points from."""
    if not store.get_workspace(ws_id):
        raise HTTPException(404, "workspace not found")
    return {"turns": store.turns(ws_id, session)}


@app.post("/workspaces/{ws_id}/rewind", response_model=RewindResponse)
async def rewind_session(ws_id: str, req: RewindRequest) -> RewindResponse:
    """Rewind the session to a turn marker: drop the transcript at/after ``turn`` and
    return that turn's prompt so the composer can re-prompt from there.

    Reconciles the worktree first: when ``checkpoint`` is set (and the tree is dirty) the
    current changes are committed via the Git-panel checkpoint path, so the dropped turns'
    edits aren't lost — they land in git history, recoverable/revertible from the Git
    panel. ``last_session_id`` is kept, so the next run ``--resume``\\s the same Claude
    session and continues from the rewound point."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    busy = store.busy_reason(ws_id)
    if busy:
        raise HTTPException(409, f"stop {busy} before rewinding")
    store.note_internal_write(ws_id)

    checkpoint_sha: str | None = None
    if req.checkpoint:
        # Best-effort safety snapshot — a failed commit must not block the rewind
        # itself (the conversation truncation below is the action's core).
        try:
            res = await git_panel.commit(
                ws.worktree_path, f"chore: haro checkpoint before rewind to turn {req.turn}"
            )
            checkpoint_sha = res.get("committed")
        except git_ops.GitError:
            checkpoint_sha = None

    result = store.rewind(ws_id, req.turn, req.session_id or DEFAULT_SESSION)
    # Persist the truncation immediately so a restart doesn't rehydrate the dropped
    # tail (mirrors runner.py's settle-time snapshot). Best-effort.
    try:
        await db.save_snapshot(store)
    except Exception:  # noqa: BLE001
        pass
    return RewindResponse(checkpoint=checkpoint_sha, **result)


@app.post("/workspaces/{ws_id}/merge")
async def merge(ws_id: str, req: MergeRequest | None = None) -> dict:
    """The discipline, enforced: commit + merge (local or gh PR) — but only when the
    gate is green. Marks the workspace `merged` and keeps it (worktree + port); the
    user archives on their own terms afterwards."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    # One shared choke point (integrate.ship_preflight): gate green, busy guard,
    # commit-first clean tree, merge_mode. The autonomy ladder's auto_pr rung runs
    # this exact function (rungs.py), so "automatic" never means "fewer checks".
    try:
        await ship_preflight(
            workspace=ws, project=project,
            merge_mode=load_project_settings(project.path).merge_mode,
            busy=store.busy_reason(ws_id),
        )
    except ShipRefused as exc:
        raise HTTPException(exc.status, str(exc)) from exc

    store.note_internal_write(ws_id)
    # Default commit/PR message from the workspace name + the last agent task.
    last = store.latest_run(ws_id)
    if req and req.message:
        message = req.message
    else:
        message = f"haro: {ws.name}"
        if last and last.task:
            message += f"\n\n{last.task}"

    # Best-effort receipt: the evidence on BOTH merge paths now (usp-critique-round3.md
    # Move A — previously local-only) — `integrate()` attaches it as a git note on the
    # local path and folds it straight into the PR body on the gh path. A receipt build
    # failing must never block a merge the gate already earned.
    receipt_markdown = None
    digest = None
    pr_line = None
    try:
        settings_ = load_project_settings(project.path)
        rcpt = await receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_)
        receipt_markdown = receipt_svc.render_markdown(rcpt)
        digest = rcpt.digest  # gate-time fingerprint — see TestRun.diff_fingerprint's docstring
        pr_line = receipt_svc.pr_line(rcpt, attest_svc.find_attestation(ws.worktree_path, digest))
    except Exception:  # noqa: BLE001
        traceback.print_exc()

    xp_changed = await xp_hooks.merge_changed_paths(ws)
    try:
        summary = await integrate(
            workspace=ws, project=project, message=message,
            receipt_markdown=receipt_markdown, digest=digest, pr_line=pr_line,
            plan_markdown=assist_svc.plan_markdown(ws.plans) or None,
        )
    except (git_ops.GitError, RuntimeError) as exc:
        detail = getattr(exc, "stderr", None) or str(exc)
        raise HTTPException(400, f"merge failed: {detail}") from exc

    # Merge no longer archives. Keep the workspace (worktree + port) and mark it
    # `merged` (GitHub-style) so the user decides when to archive. Broadcast the
    # status so the gate button + dashboard capsules flip to merged live.
    ws.status = WorkspaceStatus.merged
    # (The seed-file checkbox tick lives inside integrate() itself now — it has to
    # ride the WORKTREE'S copy of the file into this same merge commit, not edit
    # the main checkout after the fact.)
    # Remember the PR number so "Continue on a new branch" can thread the next PR as
    # a follow-up (integrate prepends "Follow-up to #N."). Only the gh path has one.
    ws.last_pr_number = summary.get("pr_number")
    if summary.get("method") != "noop":
        await xp_hooks.record_merge(store, hub, ws, xp_changed)
    await hub.publish(ws.id, status_payload(ws))
    await db.save_snapshot(store)
    return {"merged": True, **summary}


def _next_branch(branch: str, exists: set[str]) -> str:
    """Version-bump a branch for a continued task: ``foo`` → ``foo-v2`` → ``foo-v3``.
    Skips names already taken (in ``exists``) so a re-continue never collides."""
    m = re.search(r"-v(\d+)$", branch)
    stem = branch[: m.start()] if m else branch
    n = (int(m.group(1)) if m else 1) + 1
    while f"{stem}-v{n}" in exists:
        n += 1
    return f"{stem}-v{n}"


@app.post("/workspaces/{ws_id}/continue")
async def continue_workspace(ws_id: str) -> dict:
    """Continue a merged workspace on a fresh branch, keeping the same worktree + agent
    session (--resume carries the chat). Re-branches in place off the *updated* base
    (fetched, so it includes the work just merged) and threads the merged PR into
    ``prior_prs`` so the next PR reads "Follow-up to #N." — the Continue flow."""
    ws = store.get_workspace(ws_id)
    if not ws:
        raise HTTPException(404, "workspace not found")
    if ws.status != WorkspaceStatus.merged:
        raise HTTPException(409, "continue is only available after a merge")
    project = store.get_project(ws.project_id)
    if not project:
        raise HTTPException(404, "project not found")
    if not git_ops.worktree_valid(ws.worktree_path):
        raise HTTPException(409, "this workspace's worktree is missing: archive it instead")
    if not await git_ops.is_clean(ws.worktree_path):
        raise HTTPException(409, "commit or discard your changes before continuing")

    # Branch off the freshly-fetched base so the new branch includes the just-merged
    # work (a "switched to a new branch off origin/<base>" flow).
    if await git_ops.has_remote(project.path):
        try:
            await git_ops.fetch(project.path)
        except git_ops.GitError:
            pass  # offline / auth — branch off whatever base_ref resolves to locally
    existing = set(await git_ops.list_branches(project.path))
    new_branch = _next_branch(ws.branch, existing)
    try:
        await git_ops.checkout_new_branch(ws.worktree_path, new_branch, ws.base_ref)
    except git_ops.GitError as exc:
        raise HTTPException(400, f"could not create the new branch: {exc.stderr}") from exc

    if ws.last_pr_number and ws.last_pr_number not in ws.prior_prs:
        ws.prior_prs.append(ws.last_pr_number)
    ws.last_pr_number = None
    ws.branch = new_branch
    ws.gate = None
    ws.trust = None
    ws.status = WorkspaceStatus.idle
    await hub.publish(ws.id, status_payload(ws))
    await db.save_snapshot(store)
    followups = " / ".join(f"#{n}" for n in ws.prior_prs)
    detail = f"switched to a new branch {new_branch} off {ws.base_ref}"
    if followups:
        detail += f"; the next PR will follow up on {followups}"
    return {"workspace": ws.model_dump(), "branch": new_branch,
            "base_ref": ws.base_ref, "prior_prs": ws.prior_prs, "detail": detail}


@app.post("/projects/{project_id}/merge-queue", response_model=MergeQueueResult)
async def run_merge_queue(project_id: str, dry: bool = False) -> MergeQueueResult:
    """Conflict-aware merge queue: land every *green* workspace in a conflict-safe
    order — the gate is the admission ticket to shipping. Only green + committed +
    idle workspaces are admitted; they merge greedily (each re-checked against the
    advancing base via ``git merge-tree``), and whatever can't land cleanly is
    reported ``blocked`` (rebase + re-gate). ``dry=true`` previews readiness without
    landing anything.

    **The queue inherits the autonomy ladder** (backlog/autonomy-ladder.md §3): once a
    project arms ``[trust] auto_action``, green stops being the whole admission ticket —
    only *rung-complete* workspaces enqueue, exactly the bar ``rungs.maybe_fire`` clears,
    so a batch "merge all green" can't quietly land work the ladder itself would refuse.
    Rung-incomplete workspaces are ``skipped`` with the unmet conditions named and stay
    **manual** (the ④ ship button still merges them): unattended shipping is earned, a
    human clicking merge is not. A project that never armed the ladder keeps the original
    rule untouched.

    NB: strongest for local-merge repos, where each merge advances the local base so
    the next conflict-check sees it; for a remote (gh PR) repo we ``fetch`` after each
    merge so ``origin/<base>`` advances too, keeping the ordering honest."""
    project = store.get_project(project_id)
    if not project:
        raise HTTPException(404, "project not found")

    settings = load_project_settings(project.path)
    remote = await git_ops.has_remote(project.path)
    pr_only = settings.merge_mode == "pr" and remote
    ladder = trust_svc.policy_armed(settings)

    items: list[MergeQueueItem] = []
    candidates: list[merge_queue.Candidate] = []
    #: Ladder-admitted candidates → the report that authorized them, so the merge commit
    #: can cite it (same attribution rule as a rung). Empty when the ladder is unarmed.
    admitted_by: dict[str, trust_svc.TrustReport] = {}
    for ws in store.list_workspaces(project_id):
        if ws.status != WorkspaceStatus.gate_green:
            continue  # only green enqueues — non-green workspaces aren't candidates
        reason: str | None = None
        report: trust_svc.TrustReport | None = None
        if store.busy_reason(ws.id):
            reason = "an agent or the gate is still running"
        elif not git_ops.worktree_valid(ws.worktree_path):
            reason = "worktree missing or broken"
        elif not await git_ops.is_clean(ws.worktree_path):
            reason = "uncommitted changes: commit before queueing"
        elif pr_only:
            reason = 'project is PR-only ([workflow] merge_mode = "pr")'
        elif ladder:
            # Recomputed from the store (cheap + pure) rather than read off the
            # denormalized ws.trust summary, so admission uses the facts as of *now*.
            # "Now" is admission time for the whole batch: a report isn't re-derived as
            # earlier merges advance the base, exactly as the gate verdict behind it
            # isn't re-run. Only *conflicts* are re-checked per landing (below); a
            # mid-queue re-gate would be a different, much larger feature.
            report = build_trust_report(store, ws, settings)
            reason = trust_svc.admission_reason(report)
        if reason:
            items.append(MergeQueueItem(workspace_id=ws.id, name=ws.name, outcome="skipped", reason=reason))
            continue
        if report is not None:
            admitted_by[ws.id] = report
        candidates.append(merge_queue.Candidate(id=ws.id, name=ws.name, branch=ws.branch, base_ref=ws.base_ref))

    async def conflict_check(base_ref: str, branch: str) -> list[str]:
        return await git_ops.merge_tree_conflicts(project.path, base_ref, branch)

    async def merge_one(c: merge_queue.Candidate) -> None:
        ws = store.get_workspace(c.id)
        last = store.latest_run(c.id)
        message = f"haro: {ws.name}" + (f"\n\n{last.task}" if last and last.task else "")
        report = admitted_by.get(c.id)
        if report is not None:
            # Admitted by the ladder ⇒ attributable like a rung: the commit body carries
            # the conditions that authorized it, so `git log` reads the same whether the
            # ladder landed this from the gate handoff or from the queue.
            message += f"\n\n{rungs.report_body(report, 'merge_queue')}"
        xp_changed = await xp_hooks.merge_changed_paths(ws)
        await integrate(
            workspace=ws, project=project, message=message,
            plan_markdown=assist_svc.plan_markdown(ws.plans) or None,
        )
        ws.status = WorkspaceStatus.merged
        await xp_hooks.record_merge(store, hub, ws, xp_changed)
        if remote:
            try:
                await git_ops.fetch(project.path)  # advance origin/<base> for the next check
            except git_ops.GitError:
                pass
        await hub.publish(ws.id, status_payload(ws))

    if dry:
        outcome = await merge_queue.preview_merge_queue(candidates, conflict_check=conflict_check)
        for m in outcome.merged:
            items.append(MergeQueueItem(workspace_id=m["id"], name=m["name"], outcome="ready"))
        for b in outcome.blocked:
            items.append(MergeQueueItem(workspace_id=b["id"], name=b["name"], outcome="blocked",
                                        reason=b.get("reason"), conflicts=b.get("conflicts", [])))
        return MergeQueueResult(dry=True, items=items)

    # The merge train rides on ``[gate] merge_result`` instead of a key of its own: a
    # project that asked for the merged tree to be what the gate vouches for would
    # otherwise get that guarantee on the ship button but not from the batch path.
    train = settings.gate_merge_result

    async def gate_check(c: merge_queue.Candidate) -> merge_queue.GateVerdict:
        # Full scope, merge-result on: ``run_gate`` merges the worktree onto the base as it
        # stands NOW, i.e. after every candidate this run already landed. "manual" so the
        # adopted-worktree auto-gate hold can't return an unrecorded no-op (a false green).
        ws = store.get_workspace(c.id)
        busy = store.busy_reason(c.id)
        if busy:
            return merge_queue.GateVerdict(False, f"{busy} is running: gate already running", error=True)
        if remote:
            # The merged-base claim is only true against a current origin/<base>.
            try:
                await git_ops.fetch(project.path)
            except git_ops.GitError:
                return merge_queue.GateVerdict(
                    False, f"gated against a stale {ws.base_ref}: fetch failed", error=True
                )
        # A registered task, so busy_reason() sees this gate and a POST /tests or the
        # watcher's auto-gate cannot start a second one on the same worktree.
        task = asyncio.create_task(run_gate(
            store=store, hub=hub, adapter=_test_adapter(project.path), workspace=ws,
            project_path=project.path, trigger="manual", settings=settings,
        ))
        store.gate_tasks[c.id] = task
        test = await task
        if ws.status != WorkspaceStatus.gate_green or test.status != TestRunStatus.passed:
            if test.status == TestRunStatus.error:
                detail = test.error or "the gate could not run"
                return merge_queue.GateVerdict(False, f"gate could not run on merged base: {detail}", error=True)
            return merge_queue.GateVerdict(False, gate_block_detail(test))
        if ws.gate and ws.gate.degraded:
            return merge_queue.GateVerdict(
                False, "merged-base gate degraded: a check could not run, so this green is unverified",
                error=True,
            )
        return merge_queue.GateVerdict(True)

    outcome = await merge_queue.run_merge_queue(
        candidates, conflict_check=conflict_check, merge_one=merge_one,
        gate_check=gate_check if train else None,
    )
    for m in outcome.merged:
        items.append(MergeQueueItem(workspace_id=m["id"], name=m["name"], outcome="merged", gate=m.get("gate")))
    for b in outcome.blocked:
        items.append(MergeQueueItem(workspace_id=b["id"], name=b["name"], outcome="blocked",
                                    reason=b.get("reason"), conflicts=b.get("conflicts", []),
                                    gate=b.get("gate")))
    await db.save_snapshot(store)
    return MergeQueueResult(dry=False, train=train, items=items)


# --------------------------------------------------------------------------- #
# WebSocket — multiplexed realtime stream for one workspace
# --------------------------------------------------------------------------- #
@app.websocket("/ws")
async def global_ws(websocket: WebSocket) -> None:
    """Coarse live feed across ALL workspaces (status + gate results) — powers
    the multi-agent dashboard so every workspace's badge stays live at once."""
    await websocket.accept()
    queue = hub.subscribe_global()
    try:
        while True:
            envelope = await queue.get()
            try:
                await websocket.send_json(envelope)
            except (WebSocketDisconnect, RuntimeError):
                # Client vanished between queue.get() and send: a clean close
                # raises WebSocketDisconnect; a socket dropped underneath us
                # surfaces as a uvloop "transport closed" RuntimeError (common
                # with the dev StrictMode connect/disconnect/reconnect). Either
                # way this subscriber is dead — stop and let finally unsubscribe.
                break
    except (WebSocketDisconnect, asyncio.CancelledError):
        # WebSocketDisconnect: clean client close. CancelledError: the server is
        # shutting down and force-cancelled this task at `queue.get()` (uvicorn's
        # graceful-shutdown timeout) — expected, not an error worth a traceback.
        pass
    finally:
        hub.unsubscribe_global(queue)


async def _serve_pty(websocket: WebSocket, proc, master: int, term_key: str) -> None:
    """Pump an accepted WebSocket <-> an already-spawned PTY until either closes.

    The transport behind the shell terminal: a PTY streamed to the client. Registers the process under
    ``term_key`` (a ``{ws_id}:{...}`` composite so the archive sweep's ``ws.id:``
    prefix scan reaps it), reads the master fd, writes keystrokes back, and cleans
    up the reader/pump/proc/fd on disconnect.
    """
    store.term_procs[term_key] = proc
    loop = asyncio.get_event_loop()
    out_q: asyncio.Queue = asyncio.Queue()

    def on_readable() -> None:
        try:
            data = os.read(master, 65536)
        except OSError:
            data = b""
        if not data:
            # EOF — the program exited. STOP watching the fd right now: an EOF'd
            # PTY master stays perpetually "readable", so leaving the reader
            # registered busy-spins on_readable → put_nowait forever, pegging a
            # CPU core for as long as the pane stays open (the program is dead but
            # the socket isn't, so the finally-block's remove_reader hasn't run yet).
            try:
                loop.remove_reader(master)
            except Exception:  # noqa: BLE001
                pass
            out_q.put_nowait(None)  # None = EOF → pump stops
            return
        out_q.put_nowait(data)

    loop.add_reader(master, on_readable)

    async def pump() -> None:
        while True:
            data = await out_q.get()
            if data is None:
                break
            try:
                await websocket.send_bytes(data)
            except Exception:  # noqa: BLE001
                break

    pump_task = asyncio.create_task(pump())
    try:
        while True:
            obj = json.loads(await websocket.receive_text())
            if obj.get("t") == "in":
                os.write(master, obj["d"].encode())
            elif obj.get("t") == "resize":
                set_winsize(master, int(obj.get("r", 24)), int(obj.get("c", 80)))
    except (WebSocketDisconnect, asyncio.CancelledError, Exception):  # noqa: BLE001
        # Includes CancelledError (a BaseException, so not covered by Exception):
        # the server force-cancels this receive loop on shutdown — expected.
        pass
    finally:
        try:
            loop.remove_reader(master)
        except Exception:  # noqa: BLE001
            pass
        pump_task.cancel()
        if proc.returncode is None:
            try:
                proc.terminate()
            except ProcessLookupError:
                pass
        try:
            os.close(master)
        except OSError:
            pass
        store.term_procs.pop(term_key, None)


@app.websocket("/ws/workspaces/{ws_id}/terminal/{shell_id}")
async def terminal_ws(websocket: WebSocket, ws_id: str, shell_id: str) -> None:
    """Interactive shell in the workspace's worktree (xterm.js <-> PTY).

    A workspace can host several concurrent shells, so each PTY is registered
    under a composite ``{ws_id}:{shell_id}`` key — keying by ``ws_id`` alone would
    let a second shell clobber the first's process handle and orphan it.
    """
    await websocket.accept()
    ws = store.get_workspace(ws_id)
    if not ws:
        await websocket.close()
        return
    project = store.get_project(ws.project_id)
    env = script_env(ws, project) if project else dict(os.environ)
    env["TERM"] = "xterm-256color"

    try:
        proc, master = await spawn_shell(ws.worktree_path, env)
    except OSError as exc:
        await websocket.send_bytes(f"failed to start shell: {exc}\r\n".encode())
        await websocket.close()
        return

    await _serve_pty(websocket, proc, master, f"{ws_id}:{shell_id}")


_WS_NO_REPLAY = frozenset({"agent", "assist"})


@app.websocket("/ws/workspaces/{ws_id}")
async def workspace_ws(websocket: WebSocket, ws_id: str) -> None:
    await websocket.accept()
    # Replay recent history so a fresh client isn't staring at a blank pane. Agent
    # events are skipped here — the client loads the durable transcript via GET
    # /events (the in-memory backlog is lossy + wiped on restart), avoiding dupes.
    # Assist events are skipped too: a finished job's ``done`` carries the plan as it was
    # first written, so replaying it would overwrite ticks made since (GET /assist and the
    # workspace's ``plans`` are the truth a client reads on connect).
    try:
        for envelope in hub.history(ws_id):
            if envelope.get("channel") in _WS_NO_REPLAY:
                continue
            await websocket.send_json(envelope)
    except (WebSocketDisconnect, RuntimeError, asyncio.CancelledError):
        # Client gone during replay (disconnect / closed transport), or the server
        # cancelled us on shutdown — nothing subscribed yet, so just return.
        return

    queue = hub.subscribe(ws_id)
    try:
        while True:
            envelope = await queue.get()
            await websocket.send_json(envelope)
    except (WebSocketDisconnect, RuntimeError, asyncio.CancelledError):
        # Clean close raises WebSocketDisconnect; a socket dropped underneath a
        # send surfaces as a uvloop "transport closed" RuntimeError; a shutdown
        # force-cancel raises CancelledError at queue.get(). All mean we're done —
        # let finally unsubscribe.
        pass
    finally:
        hub.unsubscribe(ws_id, queue)


# ---------------------------------------------------------------------------
# Static SPA — packaged / Electron build only.
#
# In dev the UI is served by Vite (:5173), which proxies REST + WS to this
# backend. A packaged desktop build has no Vite, so we serve the *built* SPA
# from this same origin. Because the frontend calls relative URLs
# (``fetch("/projects")``, ``new WebSocket("/ws/...")``), serving it here means
# those resolve against the FastAPI origin with no CORS and no base-path rewrite
# — the Electron window just opens ``http://localhost:<port>``.
#
# Guarded on the build existing (``$HARO_SPA_DIR`` overrides; defaults to the
# repo's ``frontend/dist``) so a plain source checkout without a build is
# unaffected. Mounted LAST, after every route above, so the API + WS routes
# always win and this only catches the leftovers (``/``, ``/assets/*``, icon).
# ``html=True`` serves ``index.html`` at the root for the SPA entry point.
# ---------------------------------------------------------------------------
_spa_dir = Path(
    os.environ.get("HARO_SPA_DIR")
    or Path(__file__).resolve().parents[2] / "frontend" / "dist"
)
class _CacheControlledSPA(StaticFiles):
    """Serve the built SPA with cache headers that make a rebuilt app show up
    immediately. Plain ``StaticFiles`` sets no ``Cache-Control``, so Chromium /
    Electron apply *heuristic* freshness and can keep serving a stale
    ``index.html`` (pointing at an old CSS/JS bundle) from their HTTP cache — even
    across relaunches — so a fresh ``rebuild.sh`` looks like it "didn't take".

    The shell + any non-hashed file is ``no-cache`` (always revalidated; cheap via
    ETag → a 304 when unchanged), so the pointer to the current bundle is never
    pinned. Content-hashed assets (``/assets/<name>.<hash>.*``) are ``immutable``
    and cache forever — a new build is a new filename, so they never go stale."""

    async def get_response(self, path: str, scope):
        response = await super().get_response(path, scope)
        if path.startswith("assets/"):
            response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        else:
            response.headers["Cache-Control"] = "no-cache"
        return response


if _spa_dir.is_dir():
    app.mount("/", _CacheControlledSPA(directory=str(_spa_dir), html=True), name="spa")
