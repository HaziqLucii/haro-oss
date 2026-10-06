"""The merge gate — the product's north star made executable.

Runs a workspace's test suite via a TestRunnerAdapter, flips the workspace to
``gate_green`` or ``gate_red``, and streams the whole thing to the UI over the
``test``/``status`` channels. A red (or errored) gate is what blocks a merge.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from . import acceptance, git_ops, protect_tests, secrets_scan, trust, xp_hooks
from .adapters.test_runner.base import TestRef, TestRunnerAdapter
from .config import ProjectSettings, load_project_settings
from .hub import Hub
from .models import (
    status_payload,
    GateSummary,
    TamperFinding,
    UncheckedRow,
    TestCaseResult,
    TestRun,
    TestRunStatus,
    TrustSummary,
    Workspace,
    WorkspaceStatus,
)
from .store import Store

log = logging.getLogger(__name__)

_PROTECTED_SUFFIX = " · tests were edit-protected for this run"


def tamper_is_blocking(block_mode: bool, findings: list) -> bool:
    """The one rule for ``TestRun.tamper_blocked``: ``block`` mode plus any alarm finding.
    (Acceptance findings are added after this is evaluated and gate via ``acceptance_blocked``.)"""
    return block_mode and bool(findings)


def run_is_green(test: TestRun) -> bool:
    """The gate's green conjunction, shared with the boot-time migration in ``db.py``."""
    return (
        test.status == TestRunStatus.passed
        and not test.coverage_blocked
        and not test.merge_conflict
        and not test.tamper_blocked
        and not test.acceptance_blocked
    )


def drop_vacuous_findings(test: TestRun) -> bool:
    """Migration for runs saved before ``vacuous`` stopped being a tamper finding (2026-09-30).

    Strips those findings, then recomputes ``tamper_blocked`` / ``tamper_note`` from what
    remains with the gate's own rules. A saved ``tamper_blocked`` means the run was in
    ``block`` mode. Returns True when the run changed."""
    from . import tamper

    if not any(f.kind == "vacuous" for f in test.tamper_findings):
        return False
    test.tamper_findings = [f for f in test.tamper_findings if f.kind != "vacuous"]
    alarm = [f for f in test.tamper_findings if not f.kind.startswith("acceptance_")]
    test.tamper_blocked = tamper_is_blocking(test.tamper_blocked, alarm)
    note = tamper.summarize(
        [tamper.TamperFinding(kind=f.kind, file=f.file, detail=f.detail, test=f.test) for f in test.tamper_findings]
    )
    if note and test.tests_protected:
        note += _PROTECTED_SUFFIX
    test.tamper_note = note
    return True


def build_trust_report(store: Store, workspace: Workspace, settings: ProjectSettings) -> trust.TrustReport:
    """Assemble the autonomy-ladder report from facts already in the store.

    The IO shell around the pure ``trust.evaluate``: it fetches the workspace's latest
    gate run + the project-wide run history (the streak substrate) and hands them to the
    evaluator. Shared by ``run_gate``'s status re-broadcast and the ``GET
    /workspaces/{id}/trust`` endpoint so the two can't drift (backlog/autonomy-ladder.md).
    """
    return trust.evaluate(
        workspace,
        store.latest_test(workspace.id),
        store.project_test_history(workspace.project_id),
        settings,
    )


def _trust_summary(report: trust.TrustReport) -> TrustSummary:
    """Compact glance subset of the full trust report for the workspace's denormalized
    ``trust`` field — the dashboard meter's source, same rule as ``GateSummary``."""
    return TrustSummary(
        enabled=report.enabled,
        streak=report.streak,
        streak_required=report.streak_required,
        auto_action=report.auto_action,  # type: ignore[arg-type]
        met=report.met,
        armed=report.armed,
    )


async def _publish_status(
    hub: Hub, ws: Workspace, *, gate: dict | None = None, trust: dict | None = None
) -> None:
    msg = status_payload(ws)
    if ws.test_first is not None:
        msg["test_first"] = ws.test_first.model_dump()
    if gate is not None:
        # Carry the gate summary alongside the status so the dashboard's glance view
        # (N failing) updates live off the same coarse feed, no fetch-per-card.
        msg["gate"] = gate
    if trust is not None:
        # Piggyback the trust report on the same publish so the ④-ship checklist +
        # dashboard trust meter refresh whenever a gate verdict lands, no extra fetch.
        msg["trust"] = trust
    await hub.publish(ws.id, msg)


async def _publish_snapshot(hub: Hub, ws_id: str, test: TestRun) -> None:
    """Final authoritative gate result (summary + reconciled cases)."""
    await hub.publish(ws_id, {"channel": "test", "kind": "snapshot", "test": test.model_dump()})


async def _attach_secret_rows(workspace: Workspace, test: TestRun, gate_cwd: str) -> None:
    """Advisory secrets scan: merge gitleaks findings into the "code to check" rows.

    Deliberately touches nothing but ``unchecked_items``/``unchecked_note``: no blocked
    flag, no ``degraded_reasons``. A scan that could not run (``None``) adds nothing.
    """
    from . import unchecked

    rows = await git_ops.changed_files(workspace.worktree_path, workspace.base_ref)
    root = Path(gate_cwd)
    changed = [
        str(r.get("path") or "") for r in rows
        if r.get("path") and (root / str(r["path"])).exists()
    ]
    found = await secrets_scan.scan(cwd=gate_cwd, changed_files=changed)
    if not found:
        return
    new = [
        UncheckedRow(kind=i.kind, file=i.file, detail=i.detail, count=i.count, key=i.key,
                     line=i.line, rule=i.rule)
        for i in unchecked.secret_items(found)
    ]
    test.unchecked_items = new + list(test.unchecked_items or [])
    test.unchecked_note = unchecked.summarize(
        [unchecked.UncheckedItem(kind=r.kind, file=r.file, detail=r.detail, count=r.count)
         for r in test.unchecked_items]
    )


def _holds_packages(node_modules: Path) -> bool:
    """Does this ``node_modules`` actually hold installed packages?

    The distinction the "hands off" rule below needs: a *package-less*
    ``node_modules`` is a build cache, not an install. Packages always live under a
    plain name (``vitest``) or a scope (``@vitest``), and every real install also
    writes ``.bin``; a runner's cache writes only dot-entries (``.vite``,
    ``.cache``, ``.package-lock.json``). So: any ``.bin`` or any non-dot entry means
    a real install.
    """
    try:
        for entry in os.scandir(node_modules):
            if entry.name == ".bin" or not entry.name.startswith("."):
                return True
    except OSError:
        return False
    return False


def ensure_deps(worktree_path: str, project_path: str) -> str | None:
    """Make the worktree's node_modules resolvable before running the gate.

    Fresh worktrees are created from a commit and node_modules is gitignored, so
    the worktree starts dependency-less. As a v1 stopgap we symlink the project's
    node_modules in (v2 replaces this with the ``[scripts] setup`` hook). Returns
    a human note about what happened, or None if nothing was needed.

    **Respect a foreign tool's own install** (backlog/merge-firewall.md §2): an
    *adopted* worktree may already carry a real ``node_modules`` a foreign tool
    provisioned. We never clobber it with the symlink stopgap — an existing
    *install* means "already provisioned, hands off." ``exists()`` alone misses a
    *dangling* symlink (it follows the link), which the foreign tool may have
    left (a relative/now-broken link); ``os.symlink`` would then raise
    ``FileExistsError`` and cry wolf as a ``setup`` failure, so we also treat a
    symlink of any kind as provisioned.

    **But "exists" is not "provisioned"** (backlog/gate.md, found in the
    autonomy-ladder dogfood): an agent that runs ``npx vitest`` itself makes vitest
    write ``node_modules/.vite/…``, which *creates* ``node_modules`` as a real
    directory holding no packages at all. Read as provisioned, that silently
    cancelled the symlink for every later run in that worktree — vitest still ran
    via ``npx``, but ``@vitest/coverage-v8`` could not resolve, so the coverage
    guard measured nothing and a green gate carried no coverage number. A
    package-less directory is therefore *not* an install: we clear the stray cache
    (regenerable by construction) and symlink as usual. Only ever when the project
    has real packages to offer — we never delete without something better to put
    there.
    """
    wt_nm = Path(worktree_path) / "node_modules"
    # A link of any kind (live or dangling) is somebody's deliberate provisioning.
    if wt_nm.is_symlink():
        return None
    stray_cache = wt_nm.is_dir() and not _holds_packages(wt_nm)
    if wt_nm.exists() and not stray_cache:
        return None
    proj_nm = Path(project_path) / "node_modules"
    if not proj_nm.exists():
        return "project has no node_modules: run `npm install` in the repo first"
    if not _holds_packages(proj_nm):
        # Same trap one level up: the project root can carry a runner cache too, and
        # symlinking a package-less dir would provision nothing while reading as success.
        return "project has no node_modules packages: run `npm install` in the repo first"
    if stray_cache:
        try:
            shutil.rmtree(wt_nm)
        except OSError as exc:
            return f"could not symlink node_modules: {exc}"
    try:
        os.symlink(proj_nm, wt_nm, target_is_directory=True)
    except OSError as exc:
        return f"could not symlink node_modules: {exc}"
    # Keep the "symlinked …" prefix on both paths: ``lifecycle._provision_deps`` and
    # ``classify_gate_error`` both classify this note by prefix.
    if stray_cache:
        return "symlinked node_modules from project root (cleared a package-less cache dir)"
    return "symlinked node_modules from project root"


def auto_gate_allowed(workspace: Workspace, setup_state: dict | None) -> bool:
    """May this workspace be *auto*-gated right now? (backlog/merge-firewall.md §2)

    Managed workspaces always may — haro created them and provisioned their deps on
    create. An **adopted** (foreign) worktree is agentless and only gets provisioned at
    adopt time; until that setup reports ``ok`` an auto-gate would fail for *environment*
    reasons (missing node_modules/toolchain), so the Merge Firewall would cry wolf on a
    worktree it just took over. Hold the auto-gate until ``setup_state`` is ``ok``.

    A *manual* gate is never subject to this — the user explicitly asked to run it, and
    its ``error_kind="setup"`` verdict renders "environment, not code" with a re-run-setup
    affordance rather than a plain red. See ``run_gate``'s ``trigger`` guard.
    """
    if workspace.kind != "adopted":
        return True
    return (setup_state or {}).get("status") == "ok"


def classify_gate_error(error: str | None, dep_note: str | None) -> str:
    """Why a gate *couldn't run* — so the UI can say "the gate never ran" (fix your
    setup) instead of showing a scary raw log that reads like a test failure.

    - ``setup``    — deps/toolchain missing (vitest/npx absent, unresolved imports,
                     ``ensure_deps`` couldn't provide node_modules, or a ``command``
                     gate that never launched — binary absent / no command configured).
    - ``no_tests`` — the runner started but matched no test files.
    - ``runner``   — anything else (timeout, config error, unexpected crash).
    """
    text = (error or "").lower()
    dep_problem = bool(dep_note) and (
        dep_note.startswith("could not symlink") or dep_note.startswith("project has no node_modules")
    )
    setup_markers = (
        "not found on path",
        "cannot find module",
        "cannot find package",
        "err_module_not_found",
        "command not found",
        "no such file or directory",
        # ``CommandAdapter`` non-launch phrasings (a gate command that never ran is a
        # setup problem, not a failing suite) — matched explicitly so the coupling is
        # intentional, not incidental via "not found on path".
        "gate command not found",
        "could not launch gate command",
        "no gate command configured",
    )
    if dep_problem or any(m in text for m in setup_markers):
        return "setup"
    if "no test" in text:  # "no tests found" / "No test files found"
        return "no_tests"
    return "runner"


def reconcile_flaky(
    first_failed: set[tuple[str, str]], rerun_failed: set[tuple[str, str]]
) -> tuple[set[tuple[str, str]], set[tuple[str, str]]]:
    """Split the first run's failures using a confirmation re-run.

    - ``flaky`` — failed, then *passed* on the re-run (nondeterministic).
    - ``real``  — failed both times (a genuine, reproducible failure).
    """
    return first_failed - rerun_failed, first_failed & rerun_failed


def retried_all_passed(targets: set[tuple[str, str]], retry) -> bool:
    """True only when the retry is itself green and EVERY case matching a target key
    passed.

    A missing case (the filter matched nothing, an adapter that ignores ``only`` and
    dropped the test), a skip, a runner error or a red retry all read as "not proven".
    Every case with the key must pass: two tests sharing a name are one key, and a dict
    keeping only the last status would let a failing twin hide behind a passing one."""
    if retry.error or not retry.ok:
        return False
    statuses: dict[tuple[str, str], list[str]] = {}
    for c in retry.cases:
        statuses.setdefault((c.file, c.name), []).append(c.status)
    return all(statuses.get(t) and all(s == "passed" for s in statuses[t]) for t in targets)


def retry_eligible(result, cases) -> set[tuple[str, str]]:
    """The failing ``(file, name)`` set, or empty when the failures cannot be fully
    explained by individual cases (so nothing may be excused by a per-test retry).

    Refuses when the run has failures no case shows (a file that failed to import, an
    unhandled error) or when the failed-case count differs from the distinct failing keys
    (duplicate names make the key ambiguous)."""
    if getattr(result, "unattributed_failures", 0):
        return set()
    failed = [(c.file, c.name) for c in cases if c.status == "failed"]
    keys = set(failed)
    if len(failed) != len(keys) or result.failed != len(failed):
        return set()
    return keys


def _release_gate_task(store: Store, ws_id: str) -> None:
    """Drop this workspace's ``gate_tasks`` entry only if it is OURS (or already done):
    another gate that registered itself meanwhile must keep its busy marker."""
    entry = store.gate_tasks.get(ws_id)
    if entry is not None and (entry is asyncio.current_task() or entry.done()):
        store.gate_tasks.pop(ws_id, None)


UNMEASURED_COVERAGE = "the coverage guard is on but coverage could not be measured for this run"


def unmeasured_coverage_note(cause: str | None) -> str:
    """One string for the unmeasured case, so the degraded reason and the coverage row
    can't drift. ``cause`` is ``analytics.coverage_delta``'s own diagnosis (missing
    provider · red suite · no run yet) — the guard names its blind spot instead of
    leaving the dev to guess which of the three it hit."""
    return UNMEASURED_COVERAGE + (f": {cause}" if cause else "")


def evaluate_coverage_guard(
    delta_lines: float | None,
    mode: str,
    tolerance: float,
    *,
    unmeasured_cause: str | None = None,
) -> tuple[str, str | None]:
    """Decide the coverage guard's action for a green gate.

    Returns ``("ok"|"warn"|"block", note)``. A drop only trips the guard when it
    exceeds ``tolerance`` (percentage points); ``mode`` picks warn vs block.

    **A missing number trips the guard too** (backlog/gate.md). This used to return
    ``("ok", None)`` for ``delta_lines is None``, which meant ``coverage_guard =
    "block"`` never blocked precisely when the measurement failed — and the measurement
    is the easiest half to break (see ``ensure_deps`` above: running the suite by hand
    was enough). "No number" is strictly less information than a measured drop, so it
    cannot be the one case that passes: under ``block`` it blocks, under ``warn`` it
    warns, and either way it carries the reason. ``off`` still means off — that's the
    escape hatch, and it needs no new key.
    """
    if mode not in ("warn", "block"):
        return "ok", None
    if delta_lines is None:
        return mode, unmeasured_coverage_note(unmeasured_cause)
    if delta_lines < -abs(tolerance):
        return mode, f"line coverage dropped {abs(delta_lines):.2f}% vs base"
    return "ok", None


async def prepare_merge_result(
    *, worktree_path: str, project_path: str, base_ref: str
) -> tuple[str | None, list[str], str | None]:
    """Produce a temp worktree holding the workspace's content *merged onto the
    latest base_ref*, so the gate tests what will actually ship.

    Returns ``(merge_root, conflicts, note)``:
      - ``merge_root`` — temp worktree to run the gate in; None when base is already
        contained (no merge needed → run the real worktree) or on conflict/failure.
      - ``conflicts`` — files that wouldn't merge (non-empty → a red gate, no run).
      - ``note`` — a verdict line whenever the merge result WAS gated, including the
        already-contained case. ``note is None`` with no conflicts is therefore the
        caller's signal that the check genuinely could not run (§0 degraded), which is
        why the no-op below returns a note rather than sharing the failure's empty one.
    Never raises: any git hiccup degrades to "run the worktree as-is"."""
    try:
        if await git_ops.is_ancestor(worktree_path, base_ref, "HEAD"):
            # Base already contained: the worktree IS the merge result, so the check ran
            # and passed by definition. Must NOT read as "could not merge" — that would
            # degrade (and block shipping for) every workspace whose base hasn't moved.
            return None, [], f"gated the merge result: {base_ref} already contained"
        snap = await git_ops.snapshot_worktree_commit(worktree_path)
        parent = tempfile.mkdtemp(prefix="synth-merge-")
        dest = str(Path(parent) / "wt")
        conflicts = await git_ops.create_merge_worktree(project_path, snap, base_ref, dest)
        if conflicts:
            await git_ops.remove_worktree(project_path, dest)
            shutil.rmtree(parent, ignore_errors=True)
            return None, conflicts, None
        return dest, [], f"gated the merge result: {base_ref} merged in"
    except Exception:  # noqa: BLE001 — merge-prep must fall back, never sink the gate
        return None, [], None


@dataclass(frozen=True)
class VacuousTest:
    """A new test that already passes at ``base_ref``. Deliberately NOT a
    ``tamper.TamperFinding``: it must not be foldable into ``tamper_findings`` by accident."""

    file: str
    test: str


async def _red_first_check(
    *,
    adapter: TestRunnerAdapter,
    project_path: str,
    base_ref: str,
    current_cwd: str,
    gate_dir: str,
    dep_root: str,
    added: list[TestRef],
) -> list:
    """Re-run each newly-added test against ``base_ref`` in a throwaway worktree,
    overlaying only the CURRENT content of the test files that hold them (the new
    test, the OLD implementation) — never a full checkout of the worktree. A test
    that already passes there is ``vacuous``: it guards existing behaviour rather
    than the change it ships alongside. Advisory only (decision 2026-09-30): the
    caller routes these to the "code to check" pane as ``vacuous_test`` rows and
    never into ``tamper_findings``, because a test that passes at base weakens
    nothing (a legitimate negative-case test passes there by design).

    Mirrors ``prepare_merge_result``'s throwaway-worktree idiom above. The caller
    wraps this in its own try/except (an engine crash degrades, never sinks a
    green), so nothing here needs to be defensive about that.
    """
    files = sorted({t.file for t in added})
    base_wt = tempfile.mkdtemp(prefix="haro-redfirst-")
    try:
        await git_ops.add_detached_worktree(project_path, base_wt, base_ref)
        base_cwd = str(Path(base_wt) / gate_dir) if gate_dir else base_wt
        for rel in files:
            src = Path(current_cwd) / rel
            if not src.exists():
                continue  # a file the diff deleted has nothing to overlay
            dst = Path(base_cwd) / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
        ensure_deps(base_cwd, dep_root)
        result = await adapter.run(cwd=base_cwd, only=[(t.file, t.name) for t in added])
        if result.error:
            # The runner didn't run at all at base_ref (missing toolchain in the
            # throwaway checkout, a `only` filter that matched nothing there, …) —
            # NOT the same as "every added test correctly failed at base". §0's
            # rule applies here too: unmeasured must never read as clean, so this
            # raises into the caller's except (which degrades, never sinks green)
            # instead of returning `[]` findings that look identical to a real pass.
            raise RuntimeError(f"red-first check could not run at {base_ref}: {result.error}")
        vacuous = {(c.file, c.name) for c in result.cases if c.status == "passed"}
        return [
            VacuousTest(file=t.file, test=t.name)
            for t in added
            if (t.file, t.name) in vacuous
        ]
    finally:
        await git_ops.remove_worktree(project_path, base_wt)


async def run_gate(
    *,
    store: Store,
    hub: Hub,
    adapter: TestRunnerAdapter,
    workspace: Workspace,
    project_path: str,
    changed_since: str | None = None,
    only: list[tuple[str, str]] | None = None,
    trigger: str = "manual",
    settings: ProjectSettings | None = None,
) -> TestRun:
    """Execute the gate once and record/broadcast the result.

    If ``changed_since`` is set, only the tests impacted by the diff vs that ref
    run (the "run impacted only" fast gate). If ``only`` is set (a list of
    ``(file, test_name)`` pairs), just those tests run — the "re-run failed only"
    inner loop; it takes precedence over ``changed_since``.

    ``trigger`` records what kicked the run off ("auto" post-agent gate, "manual"
    hand-triggered, "autofix" a re-gate inside the fix loop) — the trust ladder's
    "green-first-try" signal: only non-``autofix`` greens climb the streak
    (see ``trust._is_clean_green``, backlog/autonomy-ladder.md).

    ``settings`` overrides the project's parsed config for THIS run (the CLI, the
    reproduce re-run and the merge train pass their own).
    """
    # Merge Firewall cry-wolf guard (backlog/merge-firewall.md §2): never AUTO-gate an
    # adopted (foreign) worktree until its provisioning finished ``ok``. An unprovisioned
    # foreign checkout gates red for environment reasons (missing deps/toolchain), which
    # would make the firewall cry wolf on work it only just adopted. A manual gate
    # (trigger="manual", POST /tests) is always honored — its error_kind="setup" verdict
    # renders "environment, not code" with a re-run-setup path instead of a plain red.
    # The gate symlinks node_modules and its reporters write into the worktree: an assist
    # job's git guard cannot tell those from the assistant's, so it stands down (assist.py).
    store.note_internal_write(workspace.id)
    if trigger != "manual" and not auto_gate_allowed(workspace, store.setup_state.get(workspace.id)):
        held = TestRun(workspace_id=workspace.id, project_id=workspace.project_id, runner=adapter.name)
        held.trigger = trigger  # type: ignore[assignment]  # validated Literal on the model
        return held  # not recorded/published: the gate never ran, status is untouched

    # The authoritative gate always wins the worktree: drop any advisory Live Gate run in
    # flight (backlog/live-gate.md) so the two never compete for the same node_modules /
    # vitest cache. The watch loop's own ``busy_reason`` check keeps it from restarting
    # while this runs. Idempotent + a no-op when watch is off.
    store.cancel_watch(workspace.id)

    test = TestRun(workspace_id=workspace.id, project_id=workspace.project_id, runner=adapter.name)
    test.trigger = trigger  # type: ignore[assignment]  # validated Literal on the model
    test.scope = "failed" if only else ("impacted" if changed_since else "all")
    store.add_test(test)

    workspace.status = WorkspaceStatus.tests_running
    await _publish_status(hub, workspace)

    # Monorepo support: run the gate in a configured subdir (e.g. "frontend").
    settings = settings or load_project_settings(project_path)
    gate_dir = settings.gate_dir
    dep_root = str(Path(project_path) / gate_dir) if gate_dir else project_path

    # Gate the thing that actually ships: optionally run against the worktree MERGED
    # onto the latest base_ref (a throwaway merged worktree), so a green survives a
    # base change that landed after this workspace branched. A base⇄worktree conflict
    # is itself a red gate — no tests run, the work can't cleanly integrate. Skipped
    # for a partial "re-run failed" (a diagnostic loop, not a ship verdict).
    base_dir = workspace.worktree_path
    merge_root: str | None = None
    if settings.gate_merge_result and only is None and project_path:
        merge_root, conflicts, note = await prepare_merge_result(
            worktree_path=workspace.worktree_path,
            project_path=project_path,
            base_ref=workspace.base_ref,
        )
        if conflicts:
            test.merge_conflict = True
            test.merge_note = (
                f"can’t merge {workspace.base_ref} into this workspace: "
                f"{len(conflicts)} file(s) conflict ({', '.join(conflicts[:5])}). "
                "Merge base in and resolve before the gate can vouch for the ship result."
            )
            test.status = TestRunStatus.failed
            test.ended_at = time.time()
            workspace.status = WorkspaceStatus.gate_red
            workspace.gate = GateSummary(status=test.status, scope=test.scope, ended_at=test.ended_at)
            await _publish_snapshot(hub, workspace.id, test)
            report = build_trust_report(store, workspace, settings)
            workspace.trust = _trust_summary(report)
            await _publish_status(
                hub, workspace, gate=workspace.gate.model_dump(), trust=report.to_dict()
            )
            _release_gate_task(store, workspace.id)
            return test
        if merge_root:
            base_dir = merge_root
            test.merge_note = note
        elif note:
            # Base already contained — no merge to do, so the worktree IS the merge
            # result. The check ran; record its verdict line and do NOT degrade.
            test.merge_note = note
        elif not conflicts:
            # `prepare_merge_result` swallows git hiccups and falls back to "run the
            # worktree as-is". That fallback is right (a git blip must not sink a gate) but
            # it must not be SILENT: the project asked for the merge result to be gated, so
            # a green here vouches for less than the user believes (§0).
            test.degraded_reasons.append(
                f"merge-result gating was requested but {workspace.base_ref} could not be "
                "merged for the run: this green covers the worktree alone"
            )

    gate_cwd = str(Path(base_dir) / gate_dir) if gate_dir else base_dir
    dep_note = ensure_deps(gate_cwd, dep_root)

    # Live cells stream over the same ``test`` channel as the final snapshot.
    async def emit(ev: dict) -> None:
        await hub.publish(workspace.id, {"channel": "test", **ev})

    try:
        result = await adapter.run(cwd=gate_cwd, emit=emit, changed_since=changed_since, only=only)
    except Exception as exc:  # noqa: BLE001 — an unexpected runner crash is still a red gate
        result = None
        test.status = TestRunStatus.error
        test.error = f"{type(exc).__name__}: {exc}"
        test.error_kind = classify_gate_error(test.error, dep_note)

    if result is not None:
        test.total = result.total
        test.passed = result.passed
        test.failed = result.failed
        test.skipped = result.skipped
        test.duration_ms = result.duration_ms
        test.wall_ms = result.wall_ms
        test.cases = [
            TestCaseResult(
                file=c.file,
                name=c.name,
                status=c.status,
                duration_ms=c.duration_ms,
                message=c.message,
                stack=c.stack,
            )
            for c in result.cases
        ]
        if result.error:
            test.status = TestRunStatus.error
            # Surface the dep hint when the failure is likely a missing toolchain.
            test.error = result.error if not dep_note else f"{result.error}\n({dep_note})"
            test.error_kind = classify_gate_error(result.error, dep_note)
        elif result.ok:
            test.status = TestRunStatus.passed
        else:
            test.status = TestRunStatus.failed
        test.sandbox_profile = result.sandbox_profile if result.sandboxed else None

    # Linux-first sandboxing, step 1 (usp-critique-round3.md Move D): the project
    # asked for `[gate] sandbox` but didn't get it — not sandboxed, only on an
    # otherwise-green run (a red is already blocked, and a partial re-run is
    # diagnostic, not a ship verdict). "requested but not achieved" always
    # degrades — this must never read as a silent, unsandboxed green claiming
    # to be offline. Two distinct causes, so the reason names which:
    if settings.gate_sandbox and only is None and result is not None and test.status == TestRunStatus.passed and not test.sandbox_profile:
        if adapter.name != "vitest":
            test.degraded_reasons.append(
                f"sandboxing is on but the {adapter.name} runner doesn't support it yet: "
                "this green was NOT run offline"
            )
        else:
            test.degraded_reasons.append(
                "sandboxing is on but bwrap is not installed: this green was NOT run offline"
            )

    # Flaky-aware green: a red gate gets ONE silent confirmation re-run. Failures that
    # don't reproduce are suspected-flaky — surfaced, and (if they're the only failures)
    # not allowed to block green. A red that couldn't-run (error) is never re-run here.
    # (A partial "re-run failed only" is a diagnostic inner loop, not a merge
    # verdict — skip the flaky confirmation + coverage extra runs on it.)
    confirm_ran = False
    if settings.flaky_rerun and only is None and result is not None and test.status == TestRunStatus.failed:
        first_failed = {(c.file, c.name) for c in test.cases if c.status == "failed"}
        if first_failed:
            confirm_ran = True
            try:
                rerun = await adapter.run(cwd=gate_cwd, emit=None, changed_since=changed_since)
            except Exception:  # noqa: BLE001 — a crashed re-run just leaves the gate red
                rerun = None
            if rerun is not None and not rerun.error and rerun.total > 0:
                rerun_failed = {(c.file, c.name) for c in rerun.cases if c.status == "failed"}
                flaky, real = reconcile_flaky(first_failed, rerun_failed)
                if flaky:
                    test.flaky_tests = sorted({name for _f, name in flaky})
                    # A flake passed on re-run, so it's not red: reflect that in the grid.
                    for c in test.cases:
                        if (c.file, c.name) in flaky:
                            c.status = "passed"
                    test.passed = sum(1 for c in test.cases if c.status == "passed")
                    test.failed = sum(1 for c in test.cases if c.status == "failed")
                    if not real:  # every failure was flaky → the gate is green
                        test.status = TestRunStatus.passed

    # Known-flaky retry-once (``[gate] flaky_retry``): a red FULL-scope run whose failures
    # are ALL in the project's known-flaky set gets exactly those tests re-run once. This
    # is not the confirmation re-run above: that one may excuse ANY failure and is opt-in;
    # this only ever excuses tests the project was already told are flaky, hence on by
    # default. Skipped when the confirmation re-run already retried this run.
    if (
        settings.flaky_retry
        and not confirm_ran
        and only is None
        and test.scope == "all"
        and result is not None
        and test.status == TestRunStatus.failed
        and not result.error
    ):
        failing = retry_eligible(result, test.cases)
        known = store.known_flaky_ids(workspace.project_id) if workspace.project_id else set()
        if failing and failing <= known:
            try:
                retry = await adapter.run(cwd=gate_cwd, emit=None, only=sorted(failing))
            except Exception:  # noqa: BLE001: a crashed retry just leaves the gate red
                retry = None
            if retry is not None:
                if retried_all_passed(failing, retry):
                    test.flaky_retried = sorted(f"{f}::{n}" for f, n in failing)
                    for c in test.cases:
                        if (c.file, c.name) in failing:
                            c.status = "passed"
                    test.passed = sum(1 for c in test.cases if c.status == "passed")
                    test.failed = sum(1 for c in test.cases if c.status == "failed")
                    test.status = TestRunStatus.passed

    # Coverage guard: only an otherwise-green gate is measured (a red gate is already
    # blocked, and coverage is an extra run we keep off the common path). ``block`` mode
    # downgrades the verdict without pretending a test failed — so it won't trigger the
    # auto-fix loop (which keys on test failures, not this).
    if settings.coverage_guard in ("warn", "block") and only is None and test.status == TestRunStatus.passed and project_path:
        from . import analytics  # lazy: analytics imports gate.ensure_deps

        project = store.get_project(workspace.project_id)
        if project:
            try:
                cov = await analytics.coverage_delta(store=store, workspace=workspace, project=project)
            except Exception:  # noqa: BLE001 — a coverage failure must not sink a green gate
                cov = None
            delta_lines = ((cov or {}).get("delta") or {}).get("lines") if cov else None
            test.coverage_delta = delta_lines
            action, note = evaluate_coverage_guard(
                delta_lines,
                settings.coverage_guard,
                settings.coverage_tolerance,
                # Why there's no number, straight from the measurement (missing provider ·
                # red suite · no run yet) rather than re-guessed here.
                unmeasured_cause=(cov or {}).get("note") if cov else None,
            )
            if action != "ok":
                test.coverage_note = note
                # ``block`` means it: an unmeasured guard blocks like a measured drop does
                # (backlog/gate.md). The verdict is where this has to land — `degraded`
                # alone only reaches `ship_preflight`, while the workspace *status* is what
                # the dashboard, the ribbon and the merge firewall's oracle read.
                test.coverage_blocked = action == "block"
            if delta_lines is None:
                # The guard is ON and we still have no number. Before §0 this left a clean
                # green with `coverage_delta = None`, which is exactly how a broken coverage
                # setup stayed invisible for weeks (see analytics `_resolve`). Recorded even
                # under ``warn``, where the run stays green: a degraded green is unverified,
                # so it can't bank a streak or ship (backlog/double-gate.md §0).
                test.degraded_reasons.append(note or UNMEASURED_COVERAGE)

    # Tamper alarm: like the coverage guard, only an otherwise-green gate is measured —
    # a red is already blocked, and a partial "re-run failed" (``only``) is a diagnostic
    # loop, not a ship verdict. It records the test-suite-integrity findings (the
    # ``green*`` signal) with no extra test *run*: a dry ``vitest list`` (cached at
    # base_ref) diffed against the worktree, plus the diff text vs base_ref. A crash in
    # the engine (a git hiccup, ``vitest list`` failing) degrades to NO findings — it
    # must never sink a verdict the tests already earned; and a None inventory (deps
    # missing) collapses to the diff-text-only signals. ``warn`` (the default) records
    # findings but stays green; ``block`` folds ``tamper_blocked`` into the green
    # conjunction below so a tampered suite can't merge; ``off`` skips the check.
    # The alarm's one ADVISORY output, held aside for the code-to-check block below rather
    # than stamped on the run: a base test retitled *and* re-asserted in place. It is not
    # evidence the suite got weaker (it is equally what a deliberate contract change looks
    # like), so it must never reach the verdict — and keeping it out of ``tamper_findings``
    # is what makes that structural instead of a filter every consumer has to remember.
    tamper_rewrites: list = []
    # New tests that already pass at base_ref. Advisory for the same structural reason:
    # never in ``tamper_findings``, so no consumer (verdict, streak, receipt, XP) can treat
    # one as tampering. It weakens nothing; it renders as a ``vacuous_test`` row below.
    vacuous_tests: list = []
    # Partial runs (``only``) are analysed too: the analysis is diff and inventory based, and
    # skipping it let a failed-scope re-run turn a tamper-blocked workspace green.
    if settings.tamper_alarm in ("warn", "block") and test.status == TestRunStatus.passed and project_path:
        from . import analytics, tamper  # lazy: analytics imports gate.ensure_deps

        project = store.get_project(workspace.project_id)
        if project:
            try:
                diff_text, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
                base_inv, wt_inv = await analytics.test_inventories(
                    store=store, workspace=workspace, project=project
                )
                tamper_report = tamper.analyze(diff_text, base_inv or [], wt_inv or [])
                findings = list(tamper_report.findings)
                # Red-first check (usp-critique-round3.md Move C): a genuinely NEW
                # test that already passes at base_ref guards existing behaviour, not
                # this change (possibly the correlated-error gap where the same model
                # wrote the test and the implementation from the same misreading).
                # Surfaced as an advisory row, never a tamper finding: it weakens
                # nothing. Bounded to diffs that actually add tests, so the common
                # "no new tests" path costs nothing extra. Needs a real base inventory:
                # with none, every test would read as "added". Its only consumer is the
                # code-to-check block below (full scope, ``code_to_check = "warn"``), so it
                # does not run when that block can't use it.
                added = tamper.added_tests(base_inv or [], wt_inv or [])
                # `adapter.name == "vitest"` only: `only=[(file, name), ...]` is a
                # VitestAdapter-specific filter (`only_args`). A project gated via
                # CommandAdapter (e.g. `[gate] runner = "command"` on an otherwise
                # vitest-flavored JS project — analytics.test_inventories reads the
                # actual vitest test files regardless of the configured runner, so
                # `added` can be non-empty there too) would silently ignore `only`
                # and re-run its WHOLE command instead — paying a throwaway worktree
                # + a full extra suite run for a check that can never find anything
                # (code review round-3: "silent no-op with real cost", not a false green).
                if (
                    only is None
                    and settings.code_to_check == "warn"
                    and base_inv is not None
                    and added
                    and project_path
                    and adapter.name == "vitest"
                ):
                    try:
                        vacuous_tests.extend(
                            await _red_first_check(
                                adapter=adapter,
                                project_path=project_path,
                                base_ref=workspace.base_ref,
                                current_cwd=gate_cwd,
                                gate_dir=gate_dir,
                                dep_root=dep_root,
                                added=added,
                            )
                        )
                    except Exception:  # noqa: BLE001 — advisory: skipped silently, like the secrets scan
                        # No degraded_reasons entry on purpose: a degraded green is refused at
                        # ship and by the merge train, and an advisory row must never do that.
                        log.warning("red-first check failed for workspace %s", workspace.id, exc_info=True)
                test.tamper_findings = [
                    TamperFinding(kind=f.kind, file=f.file, detail=f.detail, test=f.test)
                    for f in findings
                ]
                test.tamper_note = tamper.summarize(findings)
                tamper_rewrites = list(tamper_report.rewrites)
                # ``block`` mode downgrades the verdict without pretending a test failed
                # (mirrors the coverage guard) — so it won't trigger the auto-fix loop,
                # which keys on test failures, not this.
                test.tamper_blocked = tamper_is_blocking(settings.tamper_alarm == "block", test.tamper_findings)
                if base_inv is None:
                    # The nastiest of the four: with no base inventory the removed-test
                    # signal degrades to `[]`, and `[]` reads as "test suite intact vs base"
                    # — which satisfies `trust.no_tamper` and lets a rung arm on a check
                    # that never ran. Unmeasured is not clean, so `tamper_measured` is
                    # explicitly False here (not left at its default None — we DO know
                    # this specific run didn't complete) — the diff-text-only signals that
                    # DID run are still recorded above (findings/note), but the alarm
                    # cannot vouch for "clean" without the removed-test half of its job.
                    test.tamper_measured = False
                    test.degraded_reasons.append(
                        "the tamper alarm is on but the base test inventory was unavailable: "
                        "removed tests could not be detected for this run"
                    )
                else:
                    # Stamped only on the fully-completed path — never in the except
                    # branch below (a crashed engine also leaves `tamper_findings == []`
                    # but has NOT actually verified anything), and never above when the
                    # base inventory was unavailable (see the branch above).
                    test.tamper_measured = True
            except Exception:  # noqa: BLE001 — a tamper-engine crash must not sink a green gate
                test.tamper_measured = False  # we know this run's engine didn't complete
                test.degraded_reasons.append(
                    "the tamper alarm is on but its engine failed for this run"
                )

    # Test-first contract (backlog/test-first.md): the approved acceptance test must be
    # present, passing and byte-identical. Independent of ``[workflow] tamper_alarm`` on
    # purpose (even "off" or "warn" blocks): this is the task's contract, not a heuristic.
    # A full-scope run only, like every ship verdict; a partial re-run is diagnostic.
    tf = workspace.test_first
    partial = only is not None
    if (
        tf is not None
        and tf.phase == "approved"
        and result is not None
        and test.status in (TestRunStatus.passed, TestRunStatus.failed)
    ):
        excused = set(test.flaky_tests) | {n.split("::", 1)[-1] for n in test.flaky_retried}
        check = acceptance.check_acceptance(tf, workspace.worktree_path, test.cases, excused=excused)
        test.acceptance = check
        if not check.ok:
            # A partial run (re-run failed, impacted) may not contain the approved cases, so
            # "not all present and passing" blocks it too: it can never vouch for the contract.
            test.acceptance_blocked = True
            from . import tamper as _tamper  # lazy, mirrors the imports above

            only_unrun = partial and not check.changed and not check.failing
            for path in check.changed:
                test.tamper_findings.append(TamperFinding(
                    kind="acceptance_changed", file=path,
                    detail="approved acceptance test file changed after approval",
                ))
            if not only_unrun:
                for name in check.missing:
                    test.tamper_findings.append(TamperFinding(
                        kind="acceptance_missing", file=tf.files[0].path if tf.files else "",
                        test=name, detail="approved acceptance test is no longer in the run",
                    ))
            note = _tamper.summarize([
                _tamper.TamperFinding(kind=f.kind, file=f.file, detail=f.detail, test=f.test)
                for f in test.tamper_findings
            ])
            if only_unrun:
                hint = "run the full gate: the acceptance contract is checked on a full-scope run"
                note = f"{note} · {hint}" if note else hint
            test.tamper_note = note

    # Protected-tests context (backlog/protected-tests.md): a finding on a run whose agent
    # had deny rules on the existing tests got past the Edit/Write tools, i.e. via the
    # shell, so it reads as deliberate. Context on the finding, never a verdict input.
    test.tests_protected = protect_tests.runs_protected(
        r for r in store.runs.values() if r.workspace_id == workspace.id
    )
    if test.tests_protected and test.tamper_findings and test.tamper_note:
        test.tamper_note += _PROTECTED_SUFFIX

    # Code to check (backlog/code-to-check.md): the DIFF-level signal. Same entry rule as the
    # tamper alarm above — an otherwise-green, full-scope run only, because a red is already
    # blocked and a partial re-run is diagnostic rather than a ship verdict. Every other guard
    # on this gate is suite-level, so none of them can notice that the lines the agent just
    # added were executed by nothing at all; these rows are exactly that gap.
    #
    # Advisory by construction: there is no `unchecked_blocked` twin, so this can never
    # downgrade a verdict the tests earned. The rows inform the rail pane, and §4 decides
    # later (on real counts) whether `no_unchecked` earns a place on the ladder.
    #
    # Per-line coverage is the substrate for BOTH diff-level signals — this pane and
    # **Verified Hunks** (backlog/verified-hunks.md), the per-line "executed by the green
    # suite" annotation on the ④ ship diff. It costs one coverage-instrumented test run, so
    # it is measured ONCE here and shared, which is also why turning verified hunks on adds
    # nothing to the gate when code-to-check is already on: it only makes the run cache the
    # map it already had (see store.set_line_hits).
    diff_signals = settings.code_to_check == "warn" or settings.verified_hunks
    if diff_signals and only is None and test.status == TestRunStatus.passed and project_path:
        from . import unchecked  # lazy, mirroring the tamper/analytics imports above

        diff_text = ""
        line_hits = None       # lenient (accumulate) — code to check
        strict_hits = None     # minimum — Verified Hunks (see _line_hits' `strict`)
        measured = False
        try:
            diff_text, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
            # None (no provider installed, a crash, a runner that cannot report it) degrades
            # to the coverage-free rules rather than reporting the whole diff as unchecked.
            # Measured at 0.87s vs 0.43s on haro's own suite, which is why this sits on the
            # gate path at all.
            if hasattr(adapter, "coverage_line_maps"):
                # ONE run, two aggregations: the two consumers need opposite tie-breaks
                # where statements overlap on a line, but must not cost two suite runs.
                pair = await adapter.coverage_line_maps(cwd=gate_cwd, repo_root=base_dir)
                if pair is not None:
                    line_hits, strict_hits = pair
            elif hasattr(adapter, "coverage_lines"):
                line_hits = await adapter.coverage_lines(cwd=gate_cwd, repo_root=base_dir)
                strict_hits = line_hits
            measured = True
        except Exception:  # noqa: BLE001 — an advisory signal must never sink a green gate
            # "No rows" must not be mistaken for "nothing to check", which is the same
            # fail-open shape the guards above guard against.
            test.degraded_reasons.append(
                "the diff-level gate signals are on but reading the diff or coverage "
                "failed for this run"
            )

        # Verified Hunks: cache the map **together with the diff it describes**, because the
        # annotation is only valid against that exact diff — a line inserted afterwards
        # renumbers everything below it, and a green dot on the wrong line is precisely the
        # overclaim this feature cannot survive (verified_hunks.annotate compares the two).
        if settings.verified_hunks and measured:
            try:
                gate_head = await git_ops.head_sha(workspace.worktree_path)
            except Exception:  # noqa: BLE001 — an unborn branch/git hiccup: display only
                gate_head = None
            store.set_line_hits(
                workspace.id,
                sha=gate_head,
                # The STRICT map: this pane tells a reviewer which lines the green suite
                # actually ran, so a line only counts as executed when every statement
                # touching it ran.
                line_hits=strict_hits,
                diff=diff_text,
                scope=gate_dir,
                runner=getattr(adapter, "name", ""),
            )

        if settings.code_to_check == "warn" and measured:
            try:
                report = unchecked.analyze(
                    diff_text,
                    line_hits=line_hits,
                    tamper_findings=test.tamper_findings,
                    scope=gate_dir,
                    # The alarm's advisory half. This pane is where it can be *seen*: a
                    # rewritten assertion leaves the suite the same size, so a run carrying
                    # one is usually a plain green with no chip at all
                    # (notes/e2e-gate-test-plan.md §8.8).
                    tamper_rewrites=tamper_rewrites,
                    vacuous_tests=vacuous_tests,
                    base_ref=workspace.base_ref,
                )
                test.unchecked_items = [
                    UncheckedRow(
                        kind=i.kind, file=i.file, detail=i.detail, count=i.count, key=i.key
                    )
                    for i in report.items
                ]
                test.unchecked_note = report.note
                # None = no per-line map, 0 = a map that said nothing about this diff,
                # N = N files genuinely executed. Only the last lets the pane claim the
                # changed lines ran; see models.TestRun.unchecked_covered_files.
                test.unchecked_covered_files = report.covered_files
            except Exception:  # noqa: BLE001 — an advisory signal must never sink a green gate
                test.degraded_reasons.append(
                    "code to check is on but its engine failed for this run"
                )

    # Secrets scan: advisory "code to check" rows, never part of green/red. Same entry rule
    # as the other diff-level signals (a green, full-scope run). A missing gitleaks is a
    # silent skip: the verdict never depends on this scan having run.
    if (
        settings.secrets_scan
        and only is None
        and test.scope == "all"
        and test.status == TestRunStatus.passed
    ):
        try:
            await _attach_secret_rows(workspace, test, gate_cwd)
        except Exception:  # noqa: BLE001: an advisory scan must never sink a green gate
            pass

    # Prune ticks to the live claims, once, after every row source (code to check AND
    # secrets) has contributed. A key survives only while its row does, so the list stays the
    # size of the current diff instead of accumulating every claim the workspace ever raised,
    # and a claim that comes BACK (the lines went uncovered again) arrives unticked.
    if test.unchecked_items is not None and workspace.checked_rows:
        live = {r.key for r in test.unchecked_items}
        workspace.checked_rows = [k for k in workspace.checked_rows if k in live]

    # A throwaway merged worktree has served its purpose — remove it (idempotent).
    if merge_root:
        try:
            await git_ops.remove_worktree(project_path, merge_root)
            shutil.rmtree(Path(merge_root).parent, ignore_errors=True)
        except Exception:  # noqa: BLE001 — cleanup failure must not sink the verdict
            pass

    # Freeze the diff fingerprint AT GATE TIME (see TestRun.diff_fingerprint) — the
    # `Verified-by:` trailer and an `--attest` statement both need "what did the
    # gate measure", not "what does the tree look like right now". Same rule as
    # every other diff-level signal: full-scope only (a partial re-run is a
    # diagnostic loop, not a ship verdict), best-effort.
    if only is None and project_path:
        try:
            from .receipt import diff_fingerprint as _diff_fingerprint

            fp_diff_text, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
            test.diff_fingerprint = _diff_fingerprint(fp_diff_text)
        except Exception:  # noqa: BLE001 — evidence, never the verdict
            pass

    test.ended_at = time.time()
    green = run_is_green(test)
    workspace.status = WorkspaceStatus.gate_green if green else WorkspaceStatus.gate_red

    if not green:
        # Verified Hunks §1, "green-only": a red gate means NO badges at all, never stale
        # ones. Dropping the cached map here (rather than only refusing to serve it) is what
        # keeps that invariant local to the one function that knows the verdict — an earlier
        # green's proof must not sit in memory waiting to be drawn over a tree that just
        # failed. It is re-measured on the next green run.
        store.drop_line_hits(workspace.id)

    # Denormalize the result onto the workspace for the dashboard's glance view.
    workspace.gate = GateSummary(
        status=test.status,
        total=test.total,
        passed=test.passed,
        failed=test.failed,
        scope=test.scope,
        error_kind=test.error_kind,
        ended_at=test.ended_at,
        # Star the glance view: the count + compact reason travel with the summary so a
        # ``green*`` reads as green* on the dashboard card and in the attention banner —
        # off the coarse status feed alone, no fetch-per-card (backlog/tamper-alarm.md §3).
        tamper_count=len(test.tamper_findings),
        tamper_note=test.tamper_note,
        # Rows still awaiting a look — ticked-off ones are done, so the dashboard badge
        # agrees with the pane's badge instead of nagging about finished work. None when
        # the pass never ran, so a card can't print a confident 0 for an absent check.
        unchecked_count=(
            None
            if test.unchecked_items is None
            else sum(1 for r in test.unchecked_items if r.key not in set(workspace.checked_rows))
        ),
        degraded=bool(test.degraded_reasons),
    )

    await _publish_snapshot(hub, workspace.id, test)
    # Re-broadcast the trust report on the same status publish now that this run is
    # recorded — the ladder's conditions + streak are recomputed off the fresh verdict.
    report = build_trust_report(store, workspace, settings)
    workspace.trust = _trust_summary(report)
    await _publish_status(
        hub, workspace, gate=workspace.gate.model_dump(), trust=report.to_dict()
    )

    # Coarse cross-workspace signal for the gate verdict — rides the global feed
    # (see hub._GLOBAL_CHANNELS) so the UI can raise an OS-level desktop notification
    # for *any* workspace, even when the haro window is backgrounded. ``workspace_kind``
    # is denormalized so the client needn't look the workspace up: an *adopted*
    # (agentless) worktree never emits ``agent_done``, so its gate flip is the moment
    # the beep should fire — the frontend keys the sound off this. ``workspace_mode`` says the
    # same for a manual workspace: no agent ``done`` precedes its gate, the verdict is the finish.
    await hub.publish(
        workspace.id,
        {
            "channel": "notify",
            "kind": "gate_green" if green else "gate_red",
            "workspace_id": workspace.id,
            "workspace_name": workspace.name,
            "workspace_kind": workspace.kind,
            "workspace_mode": workspace.mode,
            "passed": test.passed,
            "failed": test.failed,
            "total": test.total,
        },
    )

    await xp_hooks.on_gate_finished(store, hub, workspace, test, green=green)
    _release_gate_task(store, workspace.id)
    return test


async def run_watch(
    *,
    store: Store,
    hub: Hub,
    adapter: TestRunnerAdapter,
    workspace: Workspace,
    project_path: str,
    related: list[str] | None = None,
    force: bool = False,
) -> TestRun | None:
    """The Live Gate's ADVISORY run — a vital sign, never a verdict (backlog/live-gate.md).

    Deliberately a separate function rather than a flag on ``run_gate``, and that is the
    whole safety argument: there is no code path from here to any of the writes that make
    work shippable. It does NOT touch ``workspace.status``, ``workspace.gate``,
    ``store.tests``/``test_history`` (so neither the regression ribbon nor the trust
    streak can see it), and it never emits the ``notify`` gate beep. A cheap continuous
    green that could satisfy the merge gate would be Goodhart-via-convenience — exactly
    the hole ``backlog/autonomy-ladder.md`` (full scope required) and the tamper alarm
    exist to close. The ceremonial full-scope ``run_gate`` stays the only thing that can
    vouch for a ship.

    ``related=[path]`` narrows the run to the tests that depend on those files (the "run the
    tests touching this file" action) instead of the diff's blast radius, and ``force``
    bypasses the ``[gate] watch`` opt-in for that explicit request. ``force`` never bypasses
    the busy check, and the run stays on the ``watch`` channel with every advisory
    guarantee below.

    Always **impacted-only** (``changed_since=base_ref``): a full suite on every save is
    how you make a watch loop hated. For the same reason it skips every extra-run
    ship-verdict stage ``run_gate`` performs — merge-result prep, the flaky confirmation
    re-run, the coverage guard, the tamper alarm (the ``analytics.py`` "keep it off the
    hot path" rule).

    Streams on its own ``watch`` channel, never ``test``: the ``test`` channel drives the
    authoritative grid in ``GatePanel``, and watch cells landing there would clobber a
    real verdict mid-review. Returns None when the run was refused or crashed — a broken
    watch loop must be invisible, not alarming.
    """
    if store.busy_reason(workspace.id):  # setup/agent/gate in flight — never fight the real gate
        return None

    settings = load_project_settings(project_path)
    if not settings.gate_watch and not force:
        return None

    test = TestRun(workspace_id=workspace.id, project_id=workspace.project_id, runner=adapter.name)
    test.trigger = "watch"  # type: ignore[assignment]  # validated Literal on the model
    test.scope = "impacted"

    gate_dir = settings.gate_dir
    dep_root = str(Path(project_path) / gate_dir) if gate_dir else project_path
    gate_cwd = str(Path(workspace.worktree_path) / gate_dir) if gate_dir else workspace.worktree_path

    async def emit(ev: dict) -> None:
        await hub.publish(workspace.id, {"channel": "watch", **ev})

    store.note_internal_write(workspace.id)  # vitest may write snapshots, deps get linked
    try:
        ensure_deps(gate_cwd, dep_root)
        if related:
            # Callers pass worktree-relative paths; the runner resolves them against its cwd.
            rel_to_cwd = [
                os.path.relpath(Path(workspace.worktree_path) / r, gate_cwd) for r in related
            ]
            # A leading dash would read as a runner flag once the gate dir is stripped.
            rel_to_cwd = [f"./{r}" if r.startswith("-") else r for r in rel_to_cwd]
            result = await adapter.run(cwd=gate_cwd, emit=emit, related=rel_to_cwd)
        else:
            result = await adapter.run(
                cwd=gate_cwd, emit=emit, changed_since=workspace.base_ref, only=None
            )
    except Exception:  # noqa: BLE001 — an advisory loop must never surface its own failure
        store.watch_runs.pop(workspace.id, None)
        return None

    if result is None:
        return None

    test.total = result.total
    test.passed = result.passed
    test.failed = result.failed
    test.skipped = result.skipped
    test.duration_ms = result.duration_ms
    test.wall_ms = result.wall_ms
    test.cases = [
        TestCaseResult(
            file=c.file,
            name=c.name,
            status=c.status,
            duration_ms=c.duration_ms,
            message=c.message,
            stack=c.stack,
        )
        for c in result.cases
    ]
    if result.error:
        test.status = TestRunStatus.error
        test.error = result.error
    elif result.ok:
        test.status = TestRunStatus.passed
    else:
        test.status = TestRunStatus.failed
    test.ended_at = time.time()

    # In-memory only (never db.py): ephemeral advisory state has no business surviving a
    # restart or entering the streak substrate. Serves the rail's rehydrate-on-reload.
    store.watch_runs[workspace.id] = test
    await hub.publish(
        workspace.id, {"channel": "watch", "kind": "snapshot", "test": test.model_dump()}
    )
    return test
