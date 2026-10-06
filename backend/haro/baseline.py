"""First-run baseline gate: one full-scope gate run on the project's default branch.

The question it answers is "is main green before any agent touches it?": a red main
makes every workspace's gate red from the start, and the dev should hear that on day
one rather than blame the first agent. It is evidence, never a merge verdict: the
result lives on ``Project.baseline``, no workspace or ``TestRun`` is created, and
nothing here can block or allow a merge.

The suite ALWAYS runs in a throwaway ``git worktree add --detach`` at the default
branch, never in the user's checkout, even when that checkout is clean and on the
branch. A runner writes as it goes (vitest creates missing ``.snap`` files, command
runners build into ``dist/`` and ``coverage/``, python writes ``__pycache__``), the
checkout can change during a long run after a one-time "is it clean" check, and its
ignored files (``.env``, ``dist/``) are visible in place but absent from every
workspace. The temp worktree is removed in a ``finally``; a kill -9 that skips it is
swept by ``sweep_stale`` (each baseline start, and backend boot). All git goes through
``git_ops``, so the per-cwd lock still serialises against every other call on the repo.

The worktree is seeded the way a new workspace is (``.haro/.env`` and ``[files]
include`` copies) and the runner is chosen from ``.haro/settings.toml`` read from that
worktree: the default branch's committed one, unless the checkout's own file is untracked
or modified against the checkout's HEAD (First run's "Use this preset" writes it uncommitted, and a baseline that
ignored it would run a runner the user never chose), in which case the checkout's file is
copied in and the result's note says so. ``[gate] dir`` and dependency provisioning are the gate's (``ensure_deps``
symlinks the checkout's ``node_modules``, as it does for a workspace). The project's
``setup`` script is NOT run (``lifecycle.run_setup`` is bound to a workspace and its
store/hub); when one is configured the result's ``note`` says so. Coverage is the one
extra run and only vitest can do it; every other runner reports "not measured".
"""

from __future__ import annotations

import asyncio
import os
import shutil
import tempfile
import time
from pathlib import Path
from typing import Callable

from . import git_ops
from .adapters.test_runner.base import TestRunnerAdapter
from .config import ProjectSettings, copy_worktree_includes, load_project_settings, seed_worktree_env
from .gate import classify_gate_error, ensure_deps
from .hub import Hub
from .models import BaselineResult, Project
from .store import Store

MAX_FAILING_IDS = 20
TMP_PREFIX = "haro_baseline_run_"
OWNER_FILE = "owner"

#: Temp dirs of baselines running in this process. Git lists every worktree of a repo from
#: any project path on it (a monorepo subfolder, a linked worktree), so a sweep must know
#: which baseline dirs are live, not which projects are.
_LIVE: set[str] = set()

#: Builds the gate's runner from a project root; called with the temp worktree so the
#: default branch's own ``[gate]`` config decides.
AdapterFor = Callable[[str], TestRunnerAdapter]


def is_baseline_worktree(path: str | Path) -> bool:
    """True for a path inside one of this module's temp dirs, so the adopt-foreign
    scan never offers a baseline's worktree as somebody else's checkout."""
    return TMP_PREFIX in str(path)


async def _publish(hub: Hub, project_id: str, kind: str, **extra) -> None:
    await hub.broadcast_global({"channel": "baseline", "project_id": project_id, "kind": kind, **extra})


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists but not ours to signal
    return True


def _still_owned(parent: Path) -> bool:
    """A baseline dir is live when this process runs it, or when the process that wrote its
    ``owner`` pid (another haro backend on the same repo) is still alive."""
    if os.path.realpath(parent) in _LIVE:
        return True
    try:
        pid = int((parent / OWNER_FILE).read_text().strip())
    except (OSError, ValueError):
        return False
    return pid != os.getpid() and _pid_alive(pid)


async def sweep_stale(project: Project) -> list[str]:
    """Remove baseline worktrees a killed process left registered on the project repo
    (``git worktree remove --force`` + prune). Returns a note per removal. Never raises."""
    notes: list[str] = []
    try:
        rows = await git_ops.list_worktrees(project.path)
    except (git_ops.GitError, OSError):
        return notes
    for row in rows:
        path = row["path"]
        if not is_baseline_worktree(path):
            continue
        parent = Path(path).parent
        if _still_owned(parent):
            continue
        try:
            await git_ops.remove_worktree(project.path, path)
        except Exception:  # noqa: BLE001: a sweep must never break a run or boot
            continue
        shutil.rmtree(parent, ignore_errors=True)
        notes.append(f"removed stale baseline worktree {path}")
    return notes


async def sweep_stale_all(store: Store) -> list[str]:
    notes: list[str] = []
    for project in store.list_projects():
        notes.extend(await sweep_stale(project))
    return notes


USED_CHECKOUT_SETTINGS = "used your uncommitted .haro/settings.toml"


async def _seed(project: Project, wt: str) -> tuple[ProjectSettings, bool]:
    """Seed the worktree like a new workspace; return the settings that apply to it and
    whether the checkout's own ``settings.toml`` replaced the committed one.

    The committed ``.haro/settings.toml`` arrives with the checkout and loses to the
    project folder's file when that one is untracked or modified there (a clean file on
    another branch is that branch's config, not this project's, so main's wins); the gitignored
    personal ``settings.local.toml`` is copied in so the dev's own overrides still
    apply, and the user-global layer loads as always."""
    shared = Path(project.path) / ".haro" / "settings.toml"
    shared_dst = Path(wt) / ".haro" / "settings.toml"
    used_checkout = False
    try:
        dirty = shared.is_file() and await git_ops.path_changed(
            project.path, ".haro/settings.toml"
        )
    except (git_ops.GitError, OSError):
        dirty = False
    if dirty:
        try:
            mine = shared.read_bytes()
            committed = shared_dst.read_bytes() if shared_dst.is_file() else None
            if mine != committed:
                shared_dst.parent.mkdir(parents=True, exist_ok=True)
                shared_dst.write_bytes(mine)
                used_checkout = True
        except OSError:
            pass
    local = Path(project.path) / ".haro" / "settings.local.toml"
    dst = Path(wt) / ".haro" / "settings.local.toml"
    if local.is_file() and not dst.exists():
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(local, dst)
        except OSError:
            pass
    settings = load_project_settings(wt)
    seed_worktree_env(project.path, wt)
    copy_worktree_includes(project.path, wt, settings.include_files)
    return settings, used_checkout


async def _measure(
    *,
    project: Project,
    root: str,
    adapter: TestRunnerAdapter,
    settings: ProjectSettings,
    hub: Hub,
    sha: str | None,
    seed_note: str | None = None,
) -> BaselineResult:
    gate_dir = settings.gate_dir
    cwd = str(Path(root) / gate_dir) if gate_dir else root
    dep_root = str(Path(project.path) / gate_dir) if gate_dir else project.path
    # node_modules provisioning is meaningless for pytest, and its "no node_modules" note
    # would misclassify a missing-tests run as a setup failure.
    dep_note = ensure_deps(cwd, dep_root) if adapter.name != "pytest" else None
    note = " · ".join(
        n
        for n in (
            seed_note,
            "the project's setup script was not run: dependencies come from the checkout"
            if (settings.setup or "").strip()
            else None,
        )
        if n
    ) or None

    counts = {"passed": 0, "failed": 0, "skipped": 0}
    seen: dict[str, str] = {}

    async def emit(ev: dict) -> None:
        if ev.get("kind") != "cell":
            return
        cell = ev.get("cell") or {}
        status = cell.get("status")
        if status not in counts:
            return  # a "running" cell is not a result yet
        key = str(cell.get("id") or f"{cell.get('file')}::{cell.get('name')}")
        prev = seen.get(key)
        if prev == status:
            return
        if prev:
            counts[prev] -= 1
        seen[key] = status
        counts[status] += 1
        await _publish(hub, project.id, "cell", status=status, **counts)

    started = time.monotonic()
    try:
        result = await adapter.run(cwd=cwd, emit=emit)
    except Exception as exc:  # noqa: BLE001: a runner crash is an "error" baseline, not a 500
        return BaselineResult(
            status="error", runner=adapter.name, sha=sha, note=note,
            duration_s=round(time.monotonic() - started, 2),
            error=f"{type(exc).__name__}: {exc}",
        )
    wall_s = (result.wall_ms / 1000) if result.wall_ms else (time.monotonic() - started)
    duration_s = round(wall_s, 2)

    if result.error:
        error = result.error if not dep_note else f"{result.error}\n({dep_note})"
        kind = classify_gate_error(result.error, dep_note)
        return BaselineResult(
            status="no_tests" if kind == "no_tests" else "error",
            runner=adapter.name, sha=sha, duration_s=duration_s, error=error, note=note,
        )

    failing = [f"{c.file}::{c.name}" for c in result.cases if c.status == "failed"]
    out = BaselineResult(
        status="passed" if result.ok else "failed",
        passed=result.passed, failed=result.failed, skipped=result.skipped,
        total=result.total, duration_s=duration_s, failing_ids=failing[:MAX_FAILING_IDS],
        runner=adapter.name, sha=sha, note=note,
    )
    if out.status == "failed" and not failing:
        out.error = (
            "the runner reported failure but no failing test case "
            "(an unhandled error, or a module that failed to load)"
        )
    # Vitest only emits coverage from a passing run, so only a green baseline is measured.
    coverage = getattr(adapter, "coverage", None)
    if out.status == "passed" and adapter.name == "vitest" and coverage is not None:
        try:
            cov = await coverage(cwd=cwd)
        except Exception:  # noqa: BLE001: a coverage failure must not sink a passing baseline
            cov = None
        lines = (cov or {}).get("lines")
        if lines is not None:
            out.coverage_pct = round(float(lines), 2)
    return out


async def run_baseline(
    *,
    store: Store,
    hub: Hub,
    project: Project,
    adapter_for: AdapterFor,
) -> BaselineResult | None:
    """Run the baseline once, record it on ``project.baseline`` and broadcast it.

    Never raises for an expected failure (encoded as ``status="error"``); the caller
    persists the store. On cancellation (shutdown, project removal) an ``error`` event
    ("baseline stopped") frees clients stuck on "running", nothing is recorded, and the
    cancel propagates after the temp worktree is removed.
    """
    await _publish(hub, project.id, "started", branch=project.default_branch)
    tmp_parent: str | None = None
    wt: str | None = None
    runner: str | None = None
    try:
        sha: str | None = None
        try:
            sha = await git_ops.rev_parse(project.default_branch, project.path)
        except git_ops.GitError:
            pass
        await sweep_stale(project)
        tmp_parent = tempfile.mkdtemp(prefix=TMP_PREFIX)
        _LIVE.add(os.path.realpath(tmp_parent))
        (Path(tmp_parent) / OWNER_FILE).write_text(str(os.getpid()))
        wt = str(Path(tmp_parent) / "wt")
        await git_ops.add_detached_worktree(project.path, wt, project.default_branch)
        settings, used_checkout = await _seed(project, wt)
        adapter = adapter_for(wt)
        runner = adapter.name
        result = await _measure(
            project=project, root=wt, adapter=adapter, settings=settings, hub=hub, sha=sha,
            seed_note=USED_CHECKOUT_SETTINGS if used_checkout else None,
        )
    except asyncio.CancelledError:
        await _publish(hub, project.id, "error", message="baseline stopped", result=None)
        raise
    except git_ops.GitError as exc:
        result = BaselineResult(
            status="error", runner=runner,
            error=f"could not check out {project.default_branch}: {exc}".strip(),
        )
    except Exception as exc:  # noqa: BLE001: whatever broke, the row must end in a state
        result = BaselineResult(status="error", runner=runner, error=f"{type(exc).__name__}: {exc}")
    finally:
        if wt:
            try:
                await git_ops.remove_worktree(project.path, wt)
            except Exception:  # noqa: BLE001: cleanup must not mask the result
                pass
        if tmp_parent:
            _LIVE.discard(os.path.realpath(tmp_parent))
            shutil.rmtree(tmp_parent, ignore_errors=True)

    project.baseline = result
    await _publish(
        hub, project.id, "error" if result.status == "error" else "done",
        result=result.model_dump(),
    )
    return result
