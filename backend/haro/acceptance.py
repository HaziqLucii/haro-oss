"""Test-first tasks: the agent drafts the acceptance test, haro proves it red, the dev
approves it, and the gate holds the build to it (backlog/test-first.md).

The verdicts here come from running real code, never from a model:

* Phase A edits are checked AFTER the run against the git diff: only brand-new test files
  may appear. Deny rules on tracked non-test files are a speed bump on top (an allow-list
  of "test files only" is not expressible in the CLI's deny syntax, and a new source file
  cannot be denied by path), so the diff scan is the guarantee.
* Red proof: the drafted tests run in the worktree, whose source is provably unchanged, so
  the run IS base behaviour. Every collected case must fail. One pass, one skip, or zero
  collected blocks approval.
* Approval records a sha256 per file. The build run gets anchored edit-deny rules for those
  files (a speed bump: the agent has a shell), and the gate re-hashes them and requires
  every approved case present and passing. That check is what enforces the contract.

Zero-collected is deliberately a rejection even when the file fails to import: a test that
cannot be collected cannot be shown to fail for the right reason. The draft prompt tells the
agent to import the not-yet-existing code inside the test body.
"""

from __future__ import annotations

import hashlib
import re
import time
from pathlib import Path
from typing import Any

from . import git_ops
from .adapters.test_runner.base import TestRunnerAdapter
from .models import (
    status_payload,
    AcceptanceCase,
    AcceptanceCheck,
    AcceptanceFile,
    TestFirstState,
    Workspace,
    WorkspaceStatus,
)
from .protect_tests import escape_glob
from .tamper import is_test_file, parse_file_diffs

_MISSING_MODULE_RE = re.compile(
    r"ModuleNotFoundError|ImportError|No module named|Cannot find module|Failed to resolve import|Error: Cannot find package",
    re.I,
)
_PY_TEST_RE = re.compile(r"(?:^|/)(?:test_[^/]*\.py|[^/]*_test\.py)$|(?:^|/)tests?/[^/]*\.py$")

#: Above this many tracked non-test files the Phase A deny list is skipped (one rule per
#: file per edit tool; 2000 rules ran fine, this leaves headroom). The diff scan still holds.
MAX_DRAFT_DENY_FILES = 1000

DRAFT_ADDENDUM = (
    "TEST-FIRST TASK, PHASE A. Write ONLY a failing acceptance test for the task, in a NEW "
    "test file. Do not change source code and do not edit existing test files. The test must "
    "be collected and run, then FAIL because the feature does not exist yet: import the code "
    "under test inside the test body (not at module top) so a missing module fails the test "
    "instead of breaking collection. Use a real assertion on the behaviour the task asks for. "
    "Do not skip, xfail or stub anything. Stop when the test is written."
)


def build_addendum(files: list[str]) -> str:
    listed = ", ".join(files)
    return (
        "TEST-FIRST TASK, PHASE B. The acceptance test is approved and is the contract. Make it "
        f"pass by changing source code. Do NOT modify these files: {listed}. Do not add skips, "
        "weaken assertions or change test configuration. The task is done when the approved "
        "test passes and those files are unchanged."
    )


def is_test_path(path: str | None) -> bool:
    """JS test files (the tamper alarm's rule) plus pytest naming and ``tests/`` modules."""
    if not path:
        return False
    return is_test_file(path) or bool(_PY_TEST_RE.search(path.replace("\\", "/")))


def sha256_of(worktree_path: str | Path, rel: str) -> str | None:
    try:
        return hashlib.sha256((Path(worktree_path) / rel).read_bytes()).hexdigest()
    except OSError:
        return None


def anchored(path: str) -> str:
    return "/" + escape_glob(path)


def draft_deny_patterns(tracked: list[str]) -> list[str]:
    """Anchored deny rules for every tracked non-test file, or ``[]`` past the cap."""
    non_tests = sorted(p for p in set(tracked) if not is_test_path(p))
    if len(non_tests) > MAX_DRAFT_DENY_FILES:
        return []
    return [anchored(p) for p in non_tests]


def build_deny_patterns(state: TestFirstState) -> list[str]:
    return [anchored(f.path) for f in state.files]


class DraftScan:
    """The diff vs base_ref, split into what Phase A may produce and what it may not."""

    def __init__(self, added_tests: list[str], violations: list[str]) -> None:
        self.added_tests = added_tests
        self.violations = violations


def scan_draft(diff_text: str) -> DraftScan:
    added: list[str] = []
    bad: list[str] = []
    for fd in parse_file_diffs(diff_text):
        path = fd.path or "?"
        if fd.old_path is None and fd.new_path and is_test_path(fd.new_path):
            added.append(fd.new_path)
        elif fd.old_path is not None and is_test_path(fd.path):
            bad.append(f"{path} (existing test file changed: write the test in a NEW file)")
        else:
            bad.append(path)
    return DraftScan(sorted(added), sorted(bad))


def _matches(case_file: str, rel: str) -> bool:
    """A runner-reported case file against a gate-dir-relative path. pytest's junit gives
    ``tests/test_x`` (module, no extension) or ``tests/test_x/Class`` for methods."""
    cf = case_file.replace("\\", "/")
    if cf.startswith("./"):
        cf = cf[2:]
    stem = rel.rsplit(".", 1)[0] if "." in rel.rsplit("/", 1)[-1] else rel
    return cf == rel or cf == stem or cf.startswith(stem + "/")


def _tail(text: str | None, n: int = 400) -> str:
    text = (text or "").strip()
    return text if len(text) <= n else "..." + text[-n:]


def judge_red(files: list[tuple[str, str]], result: Any) -> tuple[list[AcceptanceCase], str | None]:
    """``(cases, reject_reason)`` from one run of the drafted files. ``files`` are
    ``(path, gate-relative file)`` pairs; ``result`` is a ``TestResult``. A reason means
    approval is blocked. All cases failing is the only accepted shape."""
    rels = [rel for _p, rel in files]
    mine = [c for c in result.cases if any(_matches(c.file, r) for r in rels)]
    if not mine:
        names = ", ".join(rels)
        msg = (
            f"No test case was collected from {names}. If it imports code that does not exist "
            "yet at the top of the file, the file fails to load before any test registers: move "
            "that import inside the test body (await import(...) / import inside the test function)."
        )
        if result.error and _MISSING_MODULE_RE.search(result.error):
            msg += f" The runner reported a missing module: {_tail(result.error)}"
        elif result.error:
            msg += f" Runner output: {_tail(result.error)}"
        return [], msg
    passed = [c for c in mine if c.status == "passed"]
    if passed:
        names = ", ".join(c.name for c in passed[:5])
        more = f" (+{len(passed) - 5} more)" if len(passed) > 5 else ""
        return [], (
            f"{len(passed)} of {len(mine)} drafted test(s) already pass on base ({names}{more}): "
            "they do not pin the new behaviour. Ask the agent to assert something the code "
            "cannot do yet."
        )
    skipped = [c for c in mine if c.status != "failed"]
    if skipped:
        return [], (
            f"{len(skipped)} drafted test(s) were skipped, not failed: a skipped test cannot "
            "prove the feature is missing."
        )
    return [AcceptanceCase(file=c.file, name=c.name, message=_tail(c.message)) for c in mine], None


def _publish_payload(ws: Workspace) -> dict:
    msg = status_payload(ws)
    if ws.test_first is not None:
        msg["test_first"] = ws.test_first.model_dump()
    return msg


async def publish(hub: Any, ws: Workspace) -> None:
    await hub.publish(ws.id, _publish_payload(ws))


def reject(ws: Workspace, reason: str) -> None:
    tf = ws.test_first
    if tf is None or tf.phase == "approved":
        return
    tf.phase = "rejected"
    tf.reject_reason = reason
    tf.files, tf.cases, tf.proved_at = [], [], None


async def finish_draft(
    *,
    hub: Any,
    workspace: Workspace,
    adapter: TestRunnerAdapter,
    gate_dir: str = "",
    dep_root: str | None = None,
    gen: int = 0,
) -> None:
    """Prove the draft red and move the state to ``review`` or ``rejected``. Never raises:
    any engine failure lands as a rejection with the reason, not a silent pass."""
    from . import gate  # lazy: gate imports this module for the acceptance check

    tf = workspace.test_first
    if tf is None or tf.phase == "approved" or (gen and tf.gen != gen):
        return
    tf.phase = "proving"
    workspace.status = WorkspaceStatus.agent_running
    await publish(hub, workspace)
    try:
        diff_text, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
        scan = scan_draft(diff_text)
        if scan.violations:
            reject(workspace, (
                "The draft changed files other than new test files: "
                + ", ".join(scan.violations[:8])
                + ". Phase A may only add a test. Ask the agent to redo it, or revert those files."
            ))
        elif not scan.added_tests:
            reject(workspace, "The agent added no test file. Ask it to write the acceptance test.")
        else:
            prefix = gate_dir.strip("/") + "/" if gate_dir else ""
            outside = [p for p in scan.added_tests if prefix and not p.startswith(prefix)]
            if outside:
                reject(workspace, (
                    f"The test file(s) {', '.join(outside)} sit outside the gate directory "
                    f"'{gate_dir}', so the gate would never run them."
                ))
            else:
                files = [(p, p[len(prefix):]) for p in scan.added_tests]
                cwd = str(Path(workspace.worktree_path) / gate_dir) if gate_dir else workspace.worktree_path
                gate.ensure_deps(cwd, dep_root or workspace.worktree_path)
                result = await adapter.run(cwd=cwd, only=[(rel, "") for _p, rel in files])
                cases, reason = judge_red(files, result)
                if reason:
                    reject(workspace, reason)
                else:
                    tf.files = [
                        AcceptanceFile(path=p, file=rel, sha256=sha256_of(workspace.worktree_path, p) or "")
                        for p, rel in files
                    ]
                    tf.cases = cases
                    tf.proved_at = time.time()
                    tf.reject_reason = None
                    tf.phase = "review"
    except Exception as exc:  # noqa: BLE001: a proof that could not run is a rejection, never a pass
        reject(workspace, f"Proving the test red failed to run: {type(exc).__name__}: {exc}")
    if workspace.test_first is not tf or tf.phase == "approved" or (gen and tf.gen != gen):
        return  # superseded while proving: never overwrite a later state
    workspace.status = WorkspaceStatus.idle
    await publish(hub, workspace)


def interrupted(workspace: Workspace, why: str, gen: int = 0) -> None:
    """The drafting run ended without finishing (error, stopped, backend restart)."""
    tf = workspace.test_first
    if tf is not None and tf.phase in ("drafting", "proving") and not (gen and tf.gen != gen):
        reject(workspace, why)


async def verify_unchanged_since_proof(workspace: Workspace) -> str | None:
    """A refusal reason when approval would be stale: a drafted file's bytes changed after
    the proof, or a non-test file changed. ``None`` when the proof still describes the tree."""
    tf = workspace.test_first
    if tf is None or tf.phase != "review":
        return "there is no acceptance test waiting for approval"
    for f in tf.files:
        if sha256_of(workspace.worktree_path, f.path) != f.sha256:
            return f"{f.path} changed after it was proven red: redraft so it is proven again"
    diff_text, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
    scan = scan_draft(diff_text)
    if scan.violations:
        return "non-test files changed after the proof: " + ", ".join(scan.violations[:5])
    return None


def check_acceptance(
    tf: TestFirstState, worktree_path: str, cases: list[Any], excused: set[str] | None = None
) -> AcceptanceCheck:
    """Compare a gate run's cases and the files on disk against the approved contract.
    ``excused`` are test names a flaky re-run turned green: for the contract that still
    counts as failing, since a flake is exactly what "passing" must not be built on."""
    changed = [f.path for f in tf.files if sha256_of(worktree_path, f.path) != f.sha256]
    missing: list[str] = []
    failing: list[str] = []
    passing = 0
    for ac in tf.cases:
        hits = [c for c in cases if c.name == ac.name and _matches(c.file, ac.file)]
        if not hits:
            missing.append(ac.name)
        elif all(c.status == "passed" for c in hits) and ac.name not in (excused or set()):
            passing += 1
        else:
            failing.append(ac.name)
    return AcceptanceCheck(
        approved_at=tf.approved_at,
        total=len(tf.cases),
        passing=passing,
        changed=changed,
        missing=missing,
        failing=failing,
        ok=not changed and not missing and not failing and len(tf.cases) > 0,
    )


def receipt_line(check: AcceptanceCheck) -> str:
    when = time.strftime("%H:%M", time.localtime(check.approved_at)) if check.approved_at else "?"
    head = f"Acceptance test (approved {when}): {check.passing}/{check.total} passing"
    if check.ok:
        return head + ", unchanged."
    bits = []
    if check.changed:
        bits.append("file changed: " + ", ".join(check.changed))
    if check.missing:
        bits.append("missing: " + ", ".join(check.missing))
    if check.failing:
        bits.append("failing: " + ", ".join(check.failing))
    return head + ", " + "; ".join(bits) + "."
