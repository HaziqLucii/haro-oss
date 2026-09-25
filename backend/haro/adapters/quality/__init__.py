"""Quality scanners — the deterministic half of the Double Gate (backlog/double-gate.md §1)."""

from .base import (
    QualityFinding,
    QualityResult,
    QualityRunnerAdapter,
    SEVERITY_ORDER,
    at_or_above,
)
from .gitleaks import GitleaksAdapter
from .lint import LintAdapter
from .semgrep import SemgrepAdapter

#: Registry the orchestrator resolves `[quality] scanners` against. Keys are the
#: names a user writes in settings.toml.
ADAPTERS: dict[str, type[QualityRunnerAdapter]] = {
    "gitleaks": GitleaksAdapter,
    "semgrep": SemgrepAdapter,
    "lint": LintAdapter,
}

__all__ = [
    "ADAPTERS",
    "GitleaksAdapter",
    "LintAdapter",
    "QualityFinding",
    "QualityResult",
    "QualityRunnerAdapter",
    "SEVERITY_ORDER",
    "SemgrepAdapter",
    "at_or_above",
]
