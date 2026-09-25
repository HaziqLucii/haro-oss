"""v1.2 "smart gate" analytics: coverage delta + flaky detection.

Both build on the VitestAdapter. Kept out of gate.py so the merge-gate path
stays lean — these are on-demand insights, not part of the green/red verdict.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

from . import git_ops
from .adapters.test_runner import VitestAdapter
from .adapters.test_runner.base import TestRef
from .config import load_project_settings
from .gate import ensure_deps
from .models import Project, Workspace
from .store import Store

_METRICS = ("lines", "statements", "functions", "branches")


def _resolve(project: Project, root: str) -> tuple[str, str]:
    """``(cwd, dep_root)`` for a runner invocation against ``root``, honouring the
    project's ``[gate] dir``. Mirrors ``gate.run_gate``'s own resolution exactly.

    Every analytics read used to run at the worktree/checkout ROOT, which is wrong the
    moment a project sets ``[gate] dir`` (a monorepo — haro itself sets ``"frontend"``).
    The failure was quiet and confusing rather than loud: on haro the root has no
    ``package.json``, no vitest config and no ``node_modules``, so

      * ``coverage()`` died with ``Cannot find dependency '@vitest/coverage-v8'`` and the
        caller reported "the suite must be green to measure it" — while the suite was
        green. That made "Coverage holds vs base" unsatisfiable on ANY project with a
        gate dir, with a message pointing at the wrong cause.
      * ``_list()`` appeared to *work*, which was worse: with no local install, ``npx``
        downloaded a vitest and ran it **config-less**, globbing the tree. It happened to
        find haro's tests, but a config-less list ignores the project's include/exclude
        rules and aliases, so the tamper alarm's "which tests existed at base" reference
        was being built by a different runner than the gate uses.

    ``ensure_deps`` was equally misdirected: it symlinks ``<root>/node_modules`` from
    ``<project>/node_modules``, and on a gate-dir project neither path is where the deps
    live, so it silently no-opped.
    """
    gate_dir = load_project_settings(project.path).gate_dir
    if not gate_dir:
        return root, project.path
    return str(Path(root) / gate_dir), str(Path(project.path) / gate_dir)


async def _baseline_coverage(store: Store, project: Project, base_ref: str) -> dict | None:
    """Coverage of the pristine base_ref, computed once in a throwaway detached
    worktree and cached. None if base_ref's suite isn't green (no summary emitted)."""
    key = (project.id, base_ref)
    if key in store.coverage_baselines:
        return store.coverage_baselines[key]

    wt = tempfile.mkdtemp(prefix="haro_baseline_")
    result: dict | None = None
    try:
        await git_ops.add_detached_worktree(project.path, wt, base_ref)
        cwd, dep_root = _resolve(project, wt)
        ensure_deps(cwd, dep_root)
        result = await VitestAdapter().coverage(cwd=cwd)
    except git_ops.GitError:
        result = None
    finally:
        try:
            await git_ops.remove_worktree(project.path, wt)
        except git_ops.GitError:
            pass
    store.coverage_baselines[key] = result
    return result


def _unmeasurable_note(store: Store, workspace: Workspace) -> str:
    """Why coverage came back None, decided from the gate's OWN last verdict rather than
    guessed. Three genuinely different situations, and telling them apart is the whole
    point: the previous single message blamed a red suite even when the gate was green,
    which is how a missing coverage provider stayed invisible."""
    run = store.latest_test(workspace.id)
    if run is None:
        return "no gate run yet: run the gate, then coverage can be measured"
    if getattr(run.status, "value", run.status) == "passed":
        # Green suite + no coverage output ⇒ the runner could not REPORT coverage. On
        # vitest that is almost always the opt-in provider missing (`@vitest/coverage-v8`).
        return (
            "the suite is green but the runner reported no coverage: install the gate "
            "runner's coverage provider (for vitest: `@vitest/coverage-v8`)"
        )
    return "the suite must be green to measure coverage: the last gate run wasn't"


async def coverage_delta(*, store: Store, workspace: Workspace, project: Project) -> dict:
    """Current worktree coverage vs. the base_ref baseline."""
    cwd, dep_root = _resolve(project, workspace.worktree_path)
    ensure_deps(cwd, dep_root)
    current = await VitestAdapter().coverage(cwd=cwd)
    baseline = await _baseline_coverage(store, project, workspace.base_ref)

    delta = None
    if current and baseline:
        delta = {
            m: round((current.get(m) or 0) - (baseline.get(m) or 0), 2)
            for m in _METRICS
            if current.get(m) is not None and baseline.get(m) is not None
        }

    note = None
    if current is None:
        # Don't guess the cause. The old wording always said "the suite must be green",
        # which sent a dev hunting a red suite while the real problem was that coverage
        # could not RUN at all (a missing provider) — and it said it while the gate was
        # showing 245 passed. The gate's own last verdict already knows which world we are
        # in, so read it instead of assuming.
        note = _unmeasurable_note(store, workspace)
    elif baseline is None:
        note = (
            f"baseline unavailable: coverage could not be measured at {workspace.base_ref} "
            "(its suite must be green, and the gate's runner must be able to report coverage)"
        )
    return {"supported": True, "base_ref": workspace.base_ref, "current": current,
            "baseline": baseline, "delta": delta, "note": note}


async def _baseline_inventory(store: Store, project: Project, base_ref: str) -> list[TestRef] | None:
    """The test inventory (``vitest list``) of the pristine base_ref, computed once in
    a throwaway detached worktree and cached — the tamper alarm's "which tests existed
    before" reference. Twin of ``_baseline_coverage``, but ``_list`` is a *dry* list
    (no execution), so it succeeds even when base_ref's suite is red; None only when
    base_ref can't be checked out or vitest can't list."""
    key = (project.id, base_ref)
    if key in store.test_inventory_baselines:
        return store.test_inventory_baselines[key]

    wt = tempfile.mkdtemp(prefix="haro_inv_")
    result: list[TestRef] | None = None
    try:
        await git_ops.add_detached_worktree(project.path, wt, base_ref)
        cwd, dep_root = _resolve(project, wt)
        ensure_deps(cwd, dep_root)
        result = await VitestAdapter()._list(cwd=cwd)
    except git_ops.GitError:
        result = None
    finally:
        try:
            await git_ops.remove_worktree(project.path, wt)
        except git_ops.GitError:
            pass
    store.test_inventory_baselines[key] = result
    return result


async def test_inventories(
    *, store: Store, workspace: Workspace, project: Project
) -> tuple[list[TestRef] | None, list[TestRef] | None]:
    """``(base_ref baseline inventory, current worktree inventory)`` — the two test
    sets the tamper alarm's removed-test signal diffs (``tamper.removed_tests``).

    The current side is listed fresh from the worktree; the base side is cached per
    ``(project, base_ref)``. Either can be None when ``vitest list`` couldn't run
    (missing deps, no runner) — the caller degrades to diff-text-only tamper signals
    rather than sinking the gate, per the "an alarm that slows the gate gets switched
    off forever" kill condition."""
    cwd, dep_root = _resolve(project, workspace.worktree_path)
    ensure_deps(cwd, dep_root)
    current = await VitestAdapter()._list(cwd=cwd)
    baseline = await _baseline_inventory(store, project, workspace.base_ref)
    return baseline, current


async def detect_flaky(*, workspace: Workspace, project: Project, runs: int) -> dict:
    """Re-run the suite ``runs`` times; flag tests whose pass/fail flips.

    Flakiness = nondeterminism: a test that both passes and fails across
    otherwise-identical runs. Deterministic suites report zero flaky tests."""
    cwd, dep_root = _resolve(project, workspace.worktree_path)
    ensure_deps(cwd, dep_root)
    adapter = VitestAdapter()

    # test-key -> {"passed": n, "failed": n, "name": ..., "file": ...}
    tally: dict[tuple[str, str], dict] = {}
    for _ in range(runs):
        result = await adapter.run(cwd=cwd)
        for c in result.cases:
            key = (c.file, c.name)
            rec = tally.setdefault(key, {"file": c.file, "name": c.name, "passed": 0, "failed": 0})
            if c.status == "passed":
                rec["passed"] += 1
            elif c.status == "failed":
                rec["failed"] += 1

    flaky = [
        {"file": r["file"], "name": r["name"], "passed": r["passed"], "failed": r["failed"]}
        for r in tally.values()
        if r["passed"] > 0 and r["failed"] > 0
    ]
    return {"runs": runs, "checked": len(tally), "flaky": flaky, "stable": len(flaky) == 0}
