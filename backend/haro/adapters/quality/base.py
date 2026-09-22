"""The ``QualityRunnerAdapter`` seam — the mirror image of ``TestRunnerAdapter``.

An adapter runs one scanner over a worktree's *diff* and returns *normalized* findings:
``{tool, severity, file, line, rule, message}``. The orchestrator (``quality.py``) and the
UI never learn which scanner produced a finding, so adding trivy/bandit/tsc later is purely
additive — the same bet the test-runner seam makes.

**Unavailable is not clean.** The one rule this seam exists to enforce: a scanner the
project asked for that isn't installed must come back ``available=False`` with a reason,
NEVER an empty finding list. An empty list means "I looked and found nothing"; those are
different answers and conflating them is exactly the silent-pass failure §0 of
backlog/double-gate.md was written to prevent. ``quality.py`` turns ``available=False``
into a *degraded* run, which is not shippable — so a missing binary can never read as a
clean quality gate.

Scanners are diff-scoped on purpose. The gate reports on the CHANGE, not on the repo's
standing debt: a project adopting haro on a legacy codebase must not face a wall of
pre-existing findings it never introduced (that's the cry-wolf kill condition in
backlog/double-gate.md). Adapters therefore receive the changed files and, where the tool
supports it, the base ref to diff against.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Literal

Severity = Literal["high", "medium", "low", "info"]

#: Ranked worst-first. ``[quality] severity_threshold`` names the weakest severity that
#: still blocks; anything below it is reported but advisory.
SEVERITY_ORDER: tuple[Severity, ...] = ("high", "medium", "low", "info")


def rel_path(raw: str, root: str) -> str:
    """Normalize a scanner's reported path to repo-relative, the vocabulary the diff and the
    file tree speak.

    Load-bearing, not cosmetic: gitleaks echoes whatever ``--source`` it was given, so an
    absolute source yields absolute ``File`` values. Comparing those against repo-relative
    changed files matches nothing, and the scanner reports a serene "clean" on every real
    secret. That is the most dangerous shape a bug in this feature can take, so the
    normalization lives here where every adapter shares it.
    """
    from pathlib import Path

    p = str(raw or "").replace("\\", "/")
    if not p:
        return ""
    if p.startswith("./"):
        p = p[2:]
    if Path(p).is_absolute():
        try:
            return str(Path(p).resolve().relative_to(Path(root).resolve()))
        except (ValueError, OSError):
            return Path(p).name  # outside the worktree: keep something human-readable
    return p


def at_or_above(severity: str, threshold: str) -> bool:
    """Is ``severity`` at least as serious as ``threshold``? Unknown values sort last,
    so a scanner emitting a severity we don't model degrades to advisory rather than
    silently blocking a merge on a label nobody chose."""
    try:
        return SEVERITY_ORDER.index(severity) <= SEVERITY_ORDER.index(threshold)  # type: ignore[arg-type]
    except ValueError:
        return False


@dataclass
class QualityFinding:
    """One normalized finding. ``file`` is repo-relative (so it joins against the diff
    and the editor's file tree); ``line`` is 1-indexed, or None when the tool reports at
    file scope."""

    tool: str
    severity: Severity
    file: str
    rule: str
    message: str
    line: int | None = None

    def key(self) -> tuple:
        """Identity for de-duplication across scanners that overlap (semgrep and a lint
        rule both flagging one line)."""
        return (self.file, self.line, self.rule, self.message)


@dataclass
class QualityResult:
    """What one adapter returns from one scan.

    ``available=False`` + ``error`` is the "couldn't run" answer (binary missing, crash,
    timeout, unparseable output). ``available=True`` with an empty ``findings`` is the
    genuinely clean answer. The orchestrator treats them very differently.
    """

    tool: str
    available: bool = True
    error: str | None = None
    findings: list[QualityFinding] = field(default_factory=list)
    duration_ms: float | None = None

    @classmethod
    def unavailable(cls, tool: str, reason: str) -> "QualityResult":
        return cls(tool=tool, available=False, error=reason)


class QualityRunnerAdapter(ABC):
    name: str = "abstract"

    @abstractmethod
    async def scan(
        self,
        *,
        cwd: str,
        changed_files: list[str],
        base_ref: str,
        config: dict | None = None,
    ) -> QualityResult:
        """Scan the change in ``cwd`` and return normalized findings.

        ``changed_files`` are repo-relative paths added/modified vs ``base_ref`` (already
        filtered to existing files, so an adapter can pass them straight to a CLI).
        ``config`` carries the scanner's slice of ``[quality]`` for tool-specific keys.

        Must never raise for an *expected* failure — a missing binary, a non-zero exit, a
        timeout, or garbage output are all encoded in the returned ``QualityResult`` so
        the orchestrator can record an honest degraded verdict. Reserve exceptions for the
        truly unexpected.
        """
        raise NotImplementedError
