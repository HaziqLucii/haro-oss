"""v2 workspace lifecycle scripts.

Runs the project's ``.haro/settings.toml`` ``[scripts]`` — ``setup`` after a
worktree is created, ``archive`` before it's removed — with the documented env
vars available to them:

    HARO_PORT            the workspace's allocated port
    HARO_WORKSPACE_PATH  the worktree path
    HARO_ROOT_PATH       the main repo path

Scripts run through the shell so ``$HARO_*`` expansion works. When a project
has no ``setup`` script we fall back to the node_modules symlink stopgap so the
Vitest gate still works out of the box (see gate.ensure_deps).
"""

from __future__ import annotations

import asyncio
import os
import signal
from pathlib import Path

from .config import ProjectSettings, settings
from .gate import ensure_deps
from .hub import Hub
from .models import Project, Workspace, WorkspaceStatus
from .procs import signal_tree as _signal_tree, terminate_tree
from .store import SETUP_SESSION, Store


def deps_cache_env(cache_root: str) -> dict[str, str]:
    """Point the JS package managers at a shared, persistent cache/store rooted at
    ``cache_root`` — so a fresh worktree's ``setup`` install reuses prior downloads
    (a warm cache) instead of a cold fetch. pnpm's shared *store* is the big win: it
    hardlinks packages into ``node_modules`` rather than copying, making the 2nd+
    worktree's install near-instant.

    Returns the recommended cache/store vars; the caller merges them with
    ``setdefault`` so a user's own env (e.g. an exported ``npm_config_cache``)
    always wins. Empty ``cache_root`` → ``{}`` (sharing disabled).
    """
    if not cache_root:
        return {}
    root = Path(cache_root).expanduser()
    return {
        "npm_config_cache": str(root / "npm"),           # npm download cache
        "npm_config_store_dir": str(root / "pnpm-store"), # pnpm store (hardlink source)
        "YARN_CACHE_FOLDER": str(root / "yarn"),          # yarn (classic)
        "BUN_INSTALL_CACHE_DIR": str(root / "bun"),       # bun
    }


#: Per-project-root install lock: a fresh project with N workspaces created at
#: once must not run N concurrent installs into the same directory (npm/pnpm
#: clobber each other). Keyed by project path; the losers re-check and reuse.
_install_locks: dict[str, asyncio.Lock] = {}


def detect_install_cmd(root: Path) -> str | None:
    """Pick the JS dependency-install command from the lockfile committed at
    ``root``. Returns None when there's no ``package.json`` — i.e. it isn't a JS
    project, so there's nothing to auto-install (a pytest gate provisions itself)."""
    if not (root / "package.json").exists():
        return None
    if (root / "pnpm-lock.yaml").exists():
        return "pnpm install"
    if (root / "yarn.lock").exists():
        return "yarn install"
    if (root / "bun.lockb").exists() or (root / "bun.lock").exists():
        return "bun install"
    return "npm install"  # package-lock.json, or no lockfile at all


def script_env(
    workspace: Workspace, project: Project, *, port: int | None = None
) -> dict[str, str]:
    env = dict(os.environ)
    # Warm deps: only add cache vars the user hasn't set themselves (their config wins).
    for k, v in deps_cache_env(settings.deps_cache_root).items():
        env.setdefault(k, v)
    env["HARO_WORKSPACE_PATH"] = workspace.worktree_path
    env["HARO_ROOT_PATH"] = project.path
    # `port` lets a secondary run override the workspace's primary port (multiple
    # run scripts each get their own); default None → the workspace port.
    eff_port = port if port is not None else workspace.port
    if eff_port is not None:
        env["HARO_PORT"] = str(eff_port)
    return env


async def _publish_status(hub: Hub, ws: Workspace) -> None:
    await hub.publish(ws.id, {"channel": "status", "workspace_id": ws.id, "status": ws.status.value})


async def _publish_setup(hub: Hub, store: Store, ws: Workspace) -> None:
    """Broadcast the setup ('deps') state so the gate chip updates live. Rides the
    status channel with a `setup` field (no `status`), so it never clobbers wsStatus."""
    await hub.publish(
        ws.id,
        {"channel": "status", "workspace_id": ws.id, "setup": store.setup_state.get(ws.id)},
    )


async def _emit(hub: Hub, ws: Workspace, text: str) -> None:
    """Lifecycle/process output (setup, deps) → the 'run' log channel (Dev log tab),
    NOT the agent stream. The agent stream is reserved for the AI's own output."""
    await hub.publish(ws.id, {"channel": "run", "line": text.rstrip("\n")})


async def _spawn(cmd: str, *, cwd: str, env: dict, login_shell: bool, new_session: bool = True):
    """Spawn a lifecycle command. With ``login_shell`` we run it through the user's
    ``$SHELL -lc`` so version managers (nvm, asdf, pyenv, rbenv) that init from a
    login-sourced rc file are on PATH — otherwise a plain non-interactive ``/bin/sh``
    can't find ``nvm`` (it's a shell function, not a binary).

    ``new_session`` puts the command in its OWN process group (``setsid``), so a
    long-lived tree like ``sh → npm → vite → esbuild`` can be killed as a unit with
    ``os.killpg`` — otherwise terminating the shell leaves the grandchildren (the
    ones actually holding the dev-server port) orphaned. It defaults **on**: a setup
    shell used to spawn group-less, so a cancelled setup (workspace deleted mid-install)
    left ``npm install`` running. Every lifecycle child is now killable as a tree."""
    kwargs = dict(
        cwd=cwd, env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        start_new_session=new_session,
    )
    if login_shell:
        shell = env.get("SHELL") or os.environ.get("SHELL", "/bin/sh")
        return await asyncio.create_subprocess_exec(shell, "-lc", cmd, **kwargs)
    return await asyncio.create_subprocess_shell(cmd, **kwargs)


async def _run_shell(cmd: str, *, cwd: str, env: dict, on_line, login_shell: bool = False) -> int:
    """Run a lifecycle command to completion, streaming its output line by line.

    The ``finally`` is what makes a cancelled setup honest: cancelling this coroutine
    (workspace deleted / setup re-run mid-install) used to unwind the read loop and
    leave ``npm install`` churning away detached. Now the whole tree dies with the
    task, and a normal exit costs nothing (``terminate_tree`` no-ops on an exited
    process)."""
    proc = await _spawn(cmd, cwd=cwd, env=env, login_shell=login_shell)
    try:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            await on_line(raw.decode(errors="replace").rstrip("\n") + "\n")
        return await proc.wait()
    finally:
        await terminate_tree(proc)


async def _provision_deps(
    *, store: Store, hub: Hub, workspace: Workspace, project: Project, psettings: ProjectSettings
) -> dict:
    """No setup script configured: make the gate's deps resolvable, then return the
    ``setup_state`` dict to record.

    First try the cheap ``ensure_deps`` symlink of the project's existing
    node_modules. When the project has *never* had an install (nothing to symlink),
    auto-run the JS install ONCE in the project root — picked from the committed
    lockfile — then symlink. This is the fix for "open a fresh project → the Vitest
    gate can't find vitest": previously the fallback only symlinked and, finding
    nothing, still reported the deps chip green while the gate errored ``setup``.
    Non-JS projects (no ``package.json``) keep the plain symlink result."""
    note = ensure_deps(workspace.worktree_path, project.path)
    if note:
        await _emit(hub, workspace, f"◆ {note}\n")
    if note is None or note.startswith("symlinked"):
        return {"status": "ok", "exit": 0, "note": note or "no setup script"}
    if note.startswith("could not symlink"):
        return {"status": "failed", "exit": None, "note": note}

    # note == "project has no node_modules …": auto-install if it's a JS project.
    cmd = detect_install_cmd(Path(project.path))
    if cmd is None:
        return {"status": "failed", "exit": None, "note": note}

    lock = _install_locks.setdefault(project.path, asyncio.Lock())
    async with lock:
        # A sibling workspace may have installed while we waited on the lock.
        if (Path(project.path) / "node_modules").exists():
            resymlink = ensure_deps(workspace.worktree_path, project.path)
            return {"status": "ok", "exit": 0, "note": resymlink or "deps installed by a sibling workspace"}
        await _emit(hub, workspace, f"◆ no deps found, installing in the project root: {cmd}\n")
        try:
            code = await _run_shell(
                cmd,
                cwd=project.path,
                env=script_env(workspace, project),
                on_line=lambda t: _emit(hub, workspace, t),
                login_shell=psettings.login_shell,
            )
        except Exception as exc:  # noqa: BLE001 — a failed spawn is a failed provision, not a crash
            await _emit(hub, workspace, f"✕ install error: {type(exc).__name__}: {exc}\n")
            return {"status": "failed", "exit": None, "note": f"{cmd} failed: {exc}"}
        if code != 0:
            await _emit(hub, workspace, f"✕ install exited {code}\n")
            return {"status": "failed", "exit": code, "note": f"{cmd} exited {code}"}
        await _emit(hub, workspace, "◆ install finished (exit 0)\n")

    # Installed in the project root; symlink it into this worktree for the gate.
    resymlink = ensure_deps(workspace.worktree_path, project.path)
    return {"status": "ok", "exit": 0, "note": resymlink or cmd}


async def run_setup(
    *,
    store: Store,
    hub: Hub,
    workspace: Workspace,
    project: Project,
    psettings: ProjectSettings,
) -> None:
    """Provision the worktree: run the setup script, or fall back to deps symlink.

    Records the outcome in ``store.setup_state`` (the "deps" gate chip): ``running``
    while in flight, then ``ok``/``failed`` with the exit code — so a red gate caused
    by missing deps is diagnosable at a glance, and setup can be re-run on demand."""
    workspace.status = WorkspaceStatus.setting_up
    store.setup_state[workspace.id] = {"status": "running", "exit": None, "note": None}
    await _publish_status(hub, workspace)
    await _publish_setup(hub, store, workspace)
    try:
        if psettings.setup:
            await _emit(hub, workspace, f"◆ setup: {psettings.setup}\n")
            code = await _run_shell(
                psettings.setup,
                cwd=workspace.worktree_path,
                env=script_env(workspace, project),
                on_line=lambda t: _emit(hub, workspace, t),
                login_shell=psettings.login_shell,
            )
            await _emit(
                hub,
                workspace,
                f"◆ setup finished (exit {code})\n" if code == 0 else f"✕ setup exited {code}\n",
            )
            store.setup_state[workspace.id] = {
                "status": "ok" if code == 0 else "failed",
                "exit": code,
                "note": psettings.setup,
            }
        else:
            # No setup script: symlink existing deps, or auto-install them for a
            # fresh JS project so the gate works out of the box.
            store.setup_state[workspace.id] = await _provision_deps(
                store=store, hub=hub, workspace=workspace, project=project, psettings=psettings
            )
    except Exception as exc:  # noqa: BLE001 — never leave the workspace stuck in setting_up
        await _emit(hub, workspace, f"✕ setup error: {type(exc).__name__}: {exc}\n")
        store.setup_state[workspace.id] = {
            "status": "failed",
            "exit": None,
            "note": f"{type(exc).__name__}: {exc}",
        }
    finally:
        # Clear the SETUP_SESSION handle FIRST, then announce "idle". The old order
        # published readiness while ``store.setup_running()`` was still true, so
        # anything that reacted to the idle event (a queued run, a guard route) could
        # be refused by a guard the very event told it had lifted. Release the guard,
        # then say you're ready — never the other way round.
        store.pop_active_task(workspace.id, SETUP_SESSION)
        workspace.status = WorkspaceStatus.idle
        await _publish_status(hub, workspace)
        await _publish_setup(hub, store, workspace)


async def stop_run(
    *, store: Store, workspace: Workspace, run_id: str | None = None
) -> None:
    """Terminate a workspace's dev-server process TREE(s) — SIGTERM the group,
    escalate to SIGKILL if it doesn't exit, so vite/esbuild never orphan.

    ``run_id`` stops just that named run; ``None`` stops *every* run in the
    workspace (used by archive/delete). Releases any per-run port back to the pool."""
    keys = (
        [(workspace.id, run_id)]
        if run_id is not None
        else [k for k in list(store.run_procs) if k[0] == workspace.id]
    )
    for key in keys:
        # Same SIGTERM-group → grace → SIGKILL policy every haro-owned subprocess
        # gets (procs.terminate_tree); a dev server gets a longer grace so a vite
        # tree has time to release its port cleanly.
        await terminate_tree(store.run_procs.get(key), grace=5)
        task = store.run_tasks.pop(key, None)
        if task and not task.done():
            task.cancel()
        store.run_procs.pop(key, None)
        store.release_port(store.run_ports.pop(key, None))


async def quiesce_workspace(*, store: Store, workspace: Workspace) -> None:
    """Stop everything running *inside* a workspace, leaving its worktree on disk.

    The shared first half of every teardown: cancel the agent task in each session
    (plus setup, which rides the same registry under ``SETUP_SESSION``) and the gate
    task, kill the workspace's PTYs, and stop its dev servers. Extracted because two
    callers need exactly this and must not drift — ``main._teardown_workspace`` (hard
    delete: this, then remove the worktree AND the branch AND the store row) and
    ``fanout.soft_archive_lane`` (a race loser: this, then keep the row, the transcript
    and the branch — backlog/winner-fanout.md §3).

    Deliberately does NOT touch the port, the status, or the store row: those are the
    parts the two paths legitimately disagree about, and folding them in here is how
    a "soft" archive would quietly become a hard one.
    """
    tasks = store.workspace_tasks(workspace.id)
    gate = store.gate_tasks.get(workspace.id)
    if gate is not None:
        tasks.append(gate)
    for task in tasks:
        if task and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            except Exception:  # noqa: BLE001 — a dying task's own error is not ours to raise
                pass

    # A workspace may host several shells, keyed `{ws_id}:{shell_id}` — sweep them all.
    for key in [k for k in store.term_procs if k.split(":", 1)[0] == workspace.id]:
        tproc = store.term_procs.pop(key, None)
        if tproc and tproc.returncode is None:
            try:
                tproc.terminate()
            except ProcessLookupError:
                pass
    await stop_run(store=store, workspace=workspace)


async def stop_all_runs(store: Store) -> None:
    """Kill every tracked dev server — called on shutdown/reload so restarts don't
    leave orphaned servers still bound to their ports (the UI would then show 'run'
    while the old server keeps serving). Fast by design to fit the graceful-shutdown
    window: SIGTERM all groups, brief grace, then SIGKILL survivors."""
    procs = [p for p in store.run_procs.values() if p is not None and p.returncode is None]
    for proc in procs:
        _signal_tree(proc, signal.SIGTERM)
    for task in store.run_tasks.values():
        if not task.done():
            task.cancel()
    if procs:
        await asyncio.sleep(1.0)
        for proc in procs:
            _signal_tree(proc, signal.SIGKILL)
    for port in store.run_ports.values():
        store.release_port(port)
    store.run_procs.clear()
    store.run_tasks.clear()
    store.run_ports.clear()


def sweep_orphan_runs(worktree_paths: list[str]) -> list[str]:
    """On boot, kill dev servers left over from a previous process that didn't shut
    down cleanly (a hard kill / crash). Since ``store.run_procs`` is always empty at
    boot, any process whose cmdline references a known worktree path is by definition
    an orphan we no longer track. Signals each matching pid individually (NOT its
    group — a pre-fix orphan may share the backend's own group). Returns boot notes."""
    roots = [p for p in worktree_paths if p]
    if not roots:
        return []
    notes: list[str] = []
    try:
        pids = [e for e in os.listdir("/proc") if e.isdigit()]
    except OSError:
        return []
    for entry in pids:
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if any(root in cmd for root in roots):
            try:
                os.kill(int(entry), signal.SIGKILL)
                notes.append(f"killed orphan dev-server pid {entry}")
            except (ProcessLookupError, PermissionError, ValueError):
                pass
    return notes


def _resolve_run(psettings: ProjectSettings, run_id: str | None):
    """Pick which named run to start: ``run_id`` by id, else the default run."""
    runs = psettings.runs
    if not runs:
        raise ValueError("no `run` script configured in .haro/settings.toml")
    if run_id is not None:
        run = next((r for r in runs if r.id == run_id), None)
        if run is None:
            raise ValueError(f"no run script named {run_id!r} in .haro/settings.toml")
        return run
    return next((r for r in runs if r.default), runs[0])


async def start_run(
    *,
    store: Store,
    hub: Hub,
    workspace: Workspace,
    project: Project,
    psettings: ProjectSettings,
    run_id: str | None = None,
) -> str | None:
    """Start one named ``run`` script (dev server) in the worktree, streaming its
    logs on the 'run' channel tagged with its ``run_id``.

    Each run is independent: starting the same run again replaces its old process
    (a worktree can host several — web/worker/test — concurrently). The default run
    reuses the workspace's primary port; every other run allocates a fresh one from
    the project's ``[ports] range`` and releases it on stop."""
    run = _resolve_run(psettings, run_id)
    key = (workspace.id, run.id)
    await stop_run(store=store, workspace=workspace, run_id=run.id)  # replace this run

    # The default run keeps the workspace's primary port (preview binds to it);
    # secondary runs take a fresh port so two dev servers never collide.
    if run.default:
        port = workspace.port
    else:
        port = store.allocate_port(*psettings.port_range)
        if port is not None:
            store.run_ports[key] = port

    url = f"http://localhost:{port}" if port is not None else None
    proc = await _spawn(
        run.command,
        cwd=workspace.worktree_path,
        env=script_env(workspace, project, port=port),
        login_shell=psettings.login_shell,
        new_session=True,  # own process group → stop_run can kill the whole tree
    )
    store.run_procs[key] = proc

    async def _log(text: str) -> None:
        """Dev-server output goes to its own 'run' log channel (the Dev log tab),
        NOT the agent stream — keeps the agent step clean and gives logs a home."""
        await hub.publish(workspace.id, {"channel": "run", "run_id": run.id, "line": text})

    await hub.publish(
        workspace.id, {"channel": "run", "run_id": run.id, "running": True, "url": url}
    )
    await _log(f"$ {run.command}" + (f"   → {url}" if url else ""))

    async def pump() -> None:
        exit_code: int | None = None
        last_line = ""  # kept so a fast crash (e.g. "address already in use") is explainable
        try:
            assert proc.stdout is not None
            async for raw in proc.stdout:
                text = raw.decode(errors="replace").rstrip("\n")
                if text.strip():
                    last_line = text.strip()
                await _log(text)
            exit_code = await proc.wait()
            await _log(f"· run exited ({exit_code})")
        except asyncio.CancelledError:
            pass
        finally:
            store.run_procs.pop(key, None)
            store.run_tasks.pop(key, None)
            store.release_port(store.run_ports.pop(key, None))
            # A non-zero exit that wasn't a user-initiated stop is a failure worth
            # surfacing in the preview (the run logs live in the agent step).
            failed = exit_code not in (None, 0)
            await hub.publish(
                workspace.id,
                {
                    "channel": "run",
                    "run_id": run.id,
                    "running": False,
                    "url": url,
                    "exit": exit_code,
                    "error": last_line[:200] if failed else None,
                },
            )

    store.run_tasks[key] = asyncio.create_task(pump())
    return url


async def run_archive(
    *, workspace: Workspace, project: Project, psettings: ProjectSettings
) -> None:
    """Best-effort archive script before the worktree is torn down."""
    if not psettings.archive:
        return
    try:
        proc = await asyncio.create_subprocess_shell(
            psettings.archive,
            cwd=workspace.worktree_path,
            env=script_env(workspace, project),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=60)
    except (OSError, asyncio.TimeoutError):
        pass
