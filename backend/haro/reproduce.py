"""Reproducible verify: re-run the gate on the attested tree and compare verdicts.

``haro verify <sha>`` alone proves a saved statement was not altered. This module
answers the stronger question: does the gate, run again on the tree that was
attested, reach the same verdict? The signature check stays the caller's job
(``attest.verify_envelope``); everything here starts from a statement that already
verified.

The tree is materialized in a throwaway detached worktree so the user's checkout is
never touched. A statement written by ``haro gate --attest`` carries
``predicate["reproduce"]`` (``tree``: a snapshot commit of the exact worktree
content, pinned under ``refs/haro/attested/`` so gc cannot drop it). An older
statement has no such field, so its tree falls back to a snapshot of the CURRENT
worktree: that only reproduces when the tree has not moved, which the fingerprint
check below turns into an honest "does not match" rather than a false pass.

Comparison covers deterministic fields only (verdict, runner, scope, pass/fail/skip
totals, failing test ids). Durations, timestamps and cost are never compared.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import git_ops
from . import receipt as receipt_svc
from .adapters.test_runner import (
    CommandAdapter,
    OffenseAdapter,
    PytestAdapter,
    TestRunnerAdapter,
    VitestAdapter,
)
from .config import ProjectSettings, load_project_settings
from .gate import run_gate
from .hub import Hub
from .models import Project, Receipt, TestRun, Workspace
from .store import Store

ATTESTED_REF_PREFIX = "refs/haro/attested/"

OK = 0
FAILED_TO_RUN = 1
MISMATCH = 2


def make_adapter(settings: ProjectSettings) -> TestRunnerAdapter:
    runner = settings.gate_runner
    if runner == "pytest":
        return PytestAdapter()
    if runner == "command":
        return CommandAdapter(settings.gate_command, login_shell=settings.login_shell)
    if runner == "offense":
        return OffenseAdapter(settings.gate_command, settings.gate_format, login_shell=settings.login_shell)
    return VitestAdapter(sandbox=settings.gate_sandbox)


def failed_ids(run: TestRun | None) -> list[str]:
    if run is None:
        return []
    return sorted(f"{c.file}::{c.name}" for c in run.cases if c.status == "failed")


async def pin_tree(repo: str, sha12: str) -> dict:
    """Snapshot the worktree as a commit and pin it, so a later ``--rerun`` can
    check the exact attested content out even after the working tree moves on."""
    tree = await git_ops.snapshot_worktree_commit(repo, "haro: attested tree")
    await git_ops._git("update-ref", ATTESTED_REF_PREFIX + sha12, tree, cwd=repo)
    return {"tree": tree}


def settings_fingerprint(settings: ProjectSettings) -> str:
    """Stable identity of the [gate] settings that decide WHAT gets run, so a rerun
    can refuse to compare against a different command than the one attested."""
    keys = {
        "runner": settings.gate_runner, "command": settings.gate_command,
        "format": settings.gate_format, "dir": settings.gate_dir,
        "merge_result": settings.gate_merge_result, "sandbox": settings.gate_sandbox,
        "login_shell": settings.login_shell,
    }
    return hashlib.sha256(json.dumps(keys, sort_keys=True).encode()).hexdigest()[:16]


def reproduce_fields(
    run: TestRun | None, *, base_ref: str, base_sha: str, settings: ProjectSettings, pinned: dict
) -> dict:
    """The ``predicate["reproduce"]`` block: what a rerun needs beyond the receipt.
    Added under a new key so envelopes signed before it existed still verify and
    read as before. ``base_sha`` is the base ref RESOLVED at attest time: a symbolic
    ``main`` moves with every commit, which would make an untouched pinned tree
    look changed. ``base_ref`` stays for display only."""
    return {
        **pinned, "base_ref": base_ref, "base_sha": base_sha,
        "failed_ids": failed_ids(run), "settings_fingerprint": settings_fingerprint(settings),
    }


def compare(attested: dict, rerun: Receipt, rerun_failed: list[str]) -> list[dict]:
    """Field-by-field differences between the attested predicate and a fresh
    receipt. Empty list means reproduced. Pure: no I/O, no clocks."""
    suite = attested.get("suite") or {}
    pairs: list[tuple[str, object, object]] = [
        ("verdict", attested.get("verdict"), rerun.verdict),
        ("runner", suite.get("runner"), rerun.suite.runner),
        ("scope", suite.get("scope"), rerun.suite.scope),
        ("total", suite.get("total"), rerun.suite.total),
        ("passed", suite.get("passed"), rerun.suite.passed),
        ("failed", suite.get("failed"), rerun.suite.failed),
        ("skipped", suite.get("skipped"), rerun.suite.skipped),
    ]
    reproduce_block = attested.get("reproduce") or {}
    if "failed_ids" in reproduce_block:
        pairs.append(("failed_ids", sorted(reproduce_block["failed_ids"]), sorted(rerun_failed)))
    return [{"field": name, "attested": a, "rerun": b} for name, a, b in pairs if a != b]


@dataclass
class ReproduceResult:
    code: int
    reproduced: bool = False
    message: str = ""
    differences: list[dict] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    attested_verdict: str | None = None
    rerun_verdict: str | None = None

    def to_dict(self) -> dict:
        return {
            "reproduced": self.reproduced,
            "exit_code": self.code,
            "message": self.message,
            "attested_verdict": self.attested_verdict,
            "rerun_verdict": self.rerun_verdict,
            "differences": self.differences,
            "notes": self.notes,
        }

    def render(self) -> str:
        lines = [self.message, *(f"  note: {n}" for n in self.notes)]
        for d in self.differences:
            lines.append(f"  {d['field']}: attested {d['attested']!r}, rerun {d['rerun']!r}")
        return "\n".join(lines)


async def reproduce(repo: str, statement: dict) -> ReproduceResult:
    """Re-run the gate on the attested tree; never raises for an expected failure."""
    predicate = statement.get("predicate") or {}
    subject = (statement.get("subject") or [{}])[0]
    attested_digest = (subject.get("digest") or {}).get("sha256")
    repro = predicate.get("reproduce") or {}
    attested_verdict = predicate.get("verdict")
    suite = predicate.get("suite") or {}

    if suite.get("scope") == "failed":
        return ReproduceResult(FAILED_TO_RUN, message="error: a failed-only attestation cannot be reproduced")

    notes: list[str] = []
    try:
        base = repro.get("base_sha")
        if not base:
            base = repro.get("base_ref") or predicate.get("base_ref") or await git_ops.default_branch(repo)
            notes.append(
                f"attestation predates base_sha: diffing against the current tip of {base}, "
                "so new commits there can read as a tree mismatch"
            )
        tree = repro.get("tree")
        if tree:
            try:
                await git_ops._git("cat-file", "-e", f"{tree}^{{commit}}", cwd=repo)
            except git_ops.GitError:
                return ReproduceResult(
                    FAILED_TO_RUN,
                    message="error: the attested tree is no longer in this repository (gc'd or a different clone)",
                )
        else:
            tree = await git_ops.snapshot_worktree_commit(repo, "haro: verify snapshot")
    except git_ops.GitError as exc:
        return ReproduceResult(FAILED_TO_RUN, message=f"error: {exc.stderr or exc}")

    parent = tempfile.mkdtemp(prefix="haro-reproduce-")
    dest = str(Path(parent) / "wt")
    try:
        try:
            await git_ops.add_detached_worktree(repo, dest, tree)
        except git_ops.GitError as exc:
            return ReproduceResult(
                FAILED_TO_RUN, message=f"error: could not check out the attested tree: {exc.stderr or exc}"
            )

        diff_text, _ = await git_ops.diff(dest, base)
        if attested_digest and receipt_svc.diff_fingerprint(diff_text) != attested_digest:
            return ReproduceResult(
                MISMATCH,
                message="MISMATCH: tree does not match the attestation",
                attested_verdict=attested_verdict, notes=notes,
            )

        settings = load_project_settings(repo)
        attested_settings = repro.get("settings_fingerprint")
        if attested_settings and attested_settings != settings_fingerprint(settings):
            return ReproduceResult(
                MISMATCH, message="MISMATCH: gate settings changed since attesting",
                attested_verdict=attested_verdict, notes=notes,
            )
        try:
            adapter = make_adapter(settings)
        except Exception as exc:  # noqa: BLE001: an unpickable gate command etc.
            return ReproduceResult(FAILED_TO_RUN, message=f"error: could not set up the gate runner: {exc}")

        store, hub = Store(), Hub()
        project = Project(id="reproduce", name=Path(repo).name, path=repo, default_branch=base)
        store.projects[project.id] = project
        workspace = Workspace(
            project_id=project.id,
            name="reproduce",
            branch=predicate.get("branch") or "reproduce",
            worktree_path=dest,
            base_ref=base,
        )
        store.workspaces[workspace.id] = workspace

        run = await run_gate(
            store=store, hub=hub, adapter=adapter, workspace=workspace,
            project_path=repo, settings=settings,
            changed_since=base if suite.get("scope") == "impacted" else None,
        )
        rcpt = await receipt_svc.build_receipt(store=store, workspace=workspace, settings=settings)
    except Exception as exc:  # noqa: BLE001: surfaced as a CLI failure, cleanup runs below
        return ReproduceResult(FAILED_TO_RUN, message=f"error: rerun failed: {type(exc).__name__}: {exc}")
    finally:
        try:
            await git_ops.remove_worktree(repo, dest)
        except Exception:  # noqa: BLE001: cleanup must not mask the result
            pass
        shutil.rmtree(parent, ignore_errors=True)

    diffs = compare(predicate, rcpt, failed_ids(run))
    if diffs:
        return ReproduceResult(
            MISMATCH, message="MISMATCH: the rerun did not reproduce the attested verdict",
            differences=diffs, notes=notes, attested_verdict=attested_verdict, rerun_verdict=rcpt.verdict,
        )
    return ReproduceResult(
        OK, reproduced=True,
        message=f"REPRODUCED: {rcpt.verdict}, {rcpt.suite.passed} passed, {rcpt.suite.failed} failed",
        notes=notes, attested_verdict=attested_verdict, rerun_verdict=rcpt.verdict,
    )
