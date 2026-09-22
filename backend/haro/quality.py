"""The Double Gate's deterministic half (backlog/double-gate.md §1).

Where `gate.py` asks "did the suite pass?", this asks the questions a passing suite
structurally cannot answer: **did we just commit a credential, ship a known-dangerous
pattern, or break the project's own linter?** Tests can be green through all three.

The design follows the backlog's *cheap-first* principle. Deterministic scanners do the
fast, reliable work here; the LLM reviewer (§3) is reserved for the one thing tools can't
do — plan compliance — and runs only after this is clean. That ordering is a cost decision
and a trust decision at once: a machine that says "line 12 has a GitHub token" is checkable,
while a model that says "this looks insecure" is an opinion, and the hard wall should be
built out of the checkable part.

Three rules this module exists to hold:

1. **Diff-scoped.** Findings are filtered to the files this change touched. Adopting haro on
   a legacy codebase must not open with a wall of pre-existing debt nobody here introduced;
   that is the cry-wolf kill condition, and a quality gate that cries wolf gets turned off
   and then protects nothing.
2. **Unavailable is never clean.** A scanner the project asked for that isn't installed
   makes the run *degraded* (§0), which is not shippable and cannot bank a trust streak. The
   alternative — a missing binary reading as a clean bill of health — is precisely the
   silent pass the whole Double Gate was written to prevent.
3. **Severity is policy, not vibes.** Only findings at or above ``[quality]
   severity_threshold`` block, and only under ``enforce = "block"``. Everything else is
   recorded and shown. Secrets are always emitted `high` by their adapter, because there is
   no threshold at which leaking a credential is acceptable.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Awaitable, Callable

from .adapters.quality import ADAPTERS, QualityFinding, QualityResult, at_or_above

#: An async sink for incremental per-scanner events, wired by `gate.py` to the WS
#: ``quality`` channel so the UI can paint scanners live the way the test grid paints cells.
EmitFn = Callable[[dict], Awaitable[None]]


@dataclass
class QualityReport:
    """The verdict for one quality pass."""

    findings: list[QualityFinding] = field(default_factory=list)
    #: The subset at/above the severity threshold — what `blocked` is computed from.
    blocking: list[QualityFinding] = field(default_factory=list)
    #: Reasons a requested scanner could not run. Non-empty ⇒ the run is DEGRADED.
    degraded: list[str] = field(default_factory=list)
    #: Scanners that actually produced an answer (clean or not).
    ran: list[str] = field(default_factory=list)
    note: str | None = None

    @property
    def clean(self) -> bool:
        return not self.findings


def summarize(report: QualityReport) -> str | None:
    """The compact chip line, e.g. ``2 secrets · 1 lint``. None when clean, because a
    verdict with nothing to say should say nothing rather than render an empty chip."""
    if not report.findings:
        return None
    counts: dict[str, int] = {}
    for f in report.findings:
        counts[f.tool] = counts.get(f.tool, 0) + 1
    parts = [f"{n} {tool}" for tool, n in sorted(counts.items(), key=lambda kv: -kv[1])]
    note = " · ".join(parts)
    if report.blocking and len(report.blocking) != len(report.findings):
        note += f" ({len(report.blocking)} blocking)"
    return note


def _dedupe(findings: list[QualityFinding]) -> list[QualityFinding]:
    """Collapse the same problem reported by two scanners (semgrep and a lint rule both
    flagging one line). Keeps the first, which — because scanners run in the configured
    order and gitleaks leads — favours the more specific tool."""
    seen: set[tuple] = set()
    out: list[QualityFinding] = []
    for f in findings:
        k = f.key()
        if k in seen:
            continue
        seen.add(k)
        out.append(f)
    return out


async def analyze(
    *,
    cwd: str,
    changed_files: list[str],
    base_ref: str,
    settings,
    emit: EmitFn | None = None,
) -> QualityReport:
    """Run the configured scanners over the change and return one normalized verdict.

    Never raises for an expected failure: a missing binary, a crash or a timeout becomes a
    ``degraded`` reason, so a broken scanner can neither sink a green the tests earned nor
    masquerade as a clean quality gate.
    """
    report = QualityReport()
    names = list(getattr(settings, "quality_scanners", []) or [])
    if not names or not changed_files:
        return report

    threshold = str(getattr(settings, "quality_severity_threshold", "medium"))
    config = {
        "lint_cmd": getattr(settings, "quality_lint_cmd", "") or "",
        "lint_severity": getattr(settings, "quality_lint_severity", "medium"),
        "semgrep_config": getattr(settings, "quality_semgrep_config", "") or "",
    }

    async def _one(name: str) -> QualityResult:
        adapter_cls = ADAPTERS.get(name)
        if adapter_cls is None:
            return QualityResult.unavailable(
                name, f"unknown scanner '{name}' — expected one of {', '.join(sorted(ADAPTERS))}"
            )
        if emit:
            await emit({"kind": "scanner_started", "tool": name})
        try:
            return await adapter_cls().scan(
                cwd=cwd, changed_files=changed_files, base_ref=base_ref, config=config
            )
        except Exception as exc:  # noqa: BLE001 — a scanner crash is degraded, never a red
            return QualityResult.unavailable(name, f"{name} crashed: {exc}")

    # Scanners are independent read-only passes, so they run concurrently — the whole point
    # of the deterministic tier is that it is cheap enough to sit on the gate path.
    results = await asyncio.gather(*(_one(n) for n in names))

    collected: list[QualityFinding] = []
    for res in results:
        if not res.available:
            report.degraded.append(f"[quality] {res.tool} could not run: {res.error}")
            if emit:
                await emit({"kind": "scanner_done", "tool": res.tool, "status": "unavailable",
                            "error": res.error})
            continue
        report.ran.append(res.tool)
        collected.extend(res.findings)
        if emit:
            await emit({"kind": "scanner_done", "tool": res.tool,
                        "status": "findings" if res.findings else "clean",
                        "count": len(res.findings), "duration_ms": res.duration_ms})

    report.findings = _dedupe(collected)
    report.blocking = [f for f in report.findings if at_or_above(f.severity, threshold)]
    report.note = summarize(report)
    return report
