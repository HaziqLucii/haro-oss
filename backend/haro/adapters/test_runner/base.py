"""The ``TestRunnerAdapter`` seam — the mirror image of ``AgentAdapter``.

An adapter runs a project's test suite in a worktree and returns a *normalized*
result: an overall pass/fail plus per-case detail. The gate logic (runner.py)
and the UI never learn which runner produced it, so adding pytest/jest/go-test
later is purely additive. Vitest is the first (and, in v1, only) implementation.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Literal

TestCaseStatus = Literal["passed", "failed", "skipped"]

# An async sink the adapter calls with incremental events (live cells) as the
# suite runs. The gate wires this to the WebSocket ``test`` channel.
EmitFn = Callable[[dict], Awaitable[None]]


@dataclass
class CaseResult:
    file: str
    name: str
    status: TestCaseStatus
    duration_ms: float | None = None
    message: str | None = None
    # Raw failure stack (file:line frames) — kept off the live cell events and used
    # only for "failure → blame" (matching frames against the diff). None when passing.
    stack: str | None = None


@dataclass
class TestRef:
    """A test's identity for impact analysis (no result yet)."""

    file: str
    name: str


@dataclass
class ImpactResult:
    """What impact analysis returns: the full suite vs. the diff's blast radius."""

    all_tests: list[TestRef] = field(default_factory=list)
    impacted: list[TestRef] = field(default_factory=list)
    supported: bool = True
    error: str | None = None


@dataclass
class TestResult:
    """What an adapter returns from one gate run.

    ``ok`` is the single source of truth the merge gate reads: True → green,
    False → red. ``error`` is set when the suite couldn't run at all (deps
    missing, no test files, runner crash) — that is also a non-green gate.
    """

    ok: bool
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    duration_ms: float | None = None  # sum of per-test durations
    wall_ms: float | None = None       # wall-clock time of the whole run
    cases: list[CaseResult] = field(default_factory=list)
    error: str | None = None
    #: True only when the adapter ACTUALLY ran this suite under a sandbox (e.g.
    #: bubblewrap) — never set just because sandboxing was requested. See
    #: ``sandbox.py`` (usp-critique-round3.md Move D). ``gate.py`` compares this
    #: against what the project asked for and degrades (never silently claims
    #: "sandboxed") when they don't match.
    sandboxed: bool = False
    #: A short identity for the sandbox profile actually used, from
    #: ``sandbox.profile_hash`` — not a security hash, the same "did this
    #: change" role ``receipt.diff_fingerprint`` plays for diffs. ``None`` when
    #: ``sandboxed`` is False.
    sandbox_profile: str | None = None


class TestRunnerAdapter(ABC):
    name: str = "abstract"

    @abstractmethod
    async def run(
        self,
        *,
        cwd: str,
        emit: EmitFn | None = None,
        changed_since: str | None = None,
        only: list[tuple[str, str]] | None = None,
    ) -> TestResult:
        """Run the suite in ``cwd`` and return a normalized TestResult.

        If ``emit`` is provided, call it with incremental events as tests run so
        the UI can paint a live grid:
            {"kind": "run_started"}
            {"kind": "cell", "cell": {id, file, name, status, duration_ms, message}}
        where ``status`` is ``running`` while a test is in flight, then
        ``passed``/``failed``/``skipped``.

        If ``changed_since`` (a git ref) is given, run only the tests impacted by
        changes since that ref — the fast "run impacted only" gate.

        If ``only`` (a list of ``(file, full_test_name)`` pairs) is given, run just
        those tests — the "re-run failed only" inner loop. Adapters narrow as
        precisely as they can (Vitest: file filters + a name pattern; others may
        fall back to the failing files). ``only`` takes precedence over
        ``changed_since``. An empty match is treated as a pass (nothing to fail),
        like an empty impacted run.

        Must never raise for an *expected* failure (tests red, no tests, deps
        missing) — encode those in the returned TestResult so the gate can
        record a proper red/error status. Reserve exceptions for the truly
        unexpected.
        """
        raise NotImplementedError

    async def analyze_impact(self, *, cwd: str, base_ref: str) -> ImpactResult:
        """Return the full test set and the subset impacted by changes vs base_ref.

        Default: unsupported (runners without module-graph awareness). Vitest
        overrides this with dry ``vitest list`` calls (no execution).
        """
        return ImpactResult(supported=False)
