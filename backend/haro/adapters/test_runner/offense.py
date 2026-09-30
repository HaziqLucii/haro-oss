"""OffenseAdapter — turn a JSON-emitting linter/checker into the live grid.

Many quality tools don't run "tests"; they emit *offenses* — each a problem at
``file:line`` with a severity. ``shopify theme check --output json``,
``eslint -f json`` and ``ruff check --output-format json`` all speak this shape.
This adapter runs the configured command, parses its JSON via a small pluggable
per-format parser, and maps each offense to a grid cell so step ③ shows the same
clickable severity grid as Vitest instead of a raw log:

- an **error**-severity offense → a red (``failed``) cell,
- a **warning**/info offense → an amber (``skipped``) cell.

Selected per-project via ``.haro/settings.toml``::

    [gate]
    runner  = "offense"
    command = "shopify theme check --output json"
    format  = "theme-check"   # theme-check | eslint | ruff

The **JSON is the source of truth, not the exit code** — linters exit non-zero
merely because they found something. The gate is **red iff there is at least one
error-severity offense**; warnings alone stay green (amber cells, still
mergeable), mirroring how a skipped test never blocks a merge. A clean run (zero
offenses) is a *green* gate with an empty grid, NOT a "no tests" error.

Impact analysis / coverage / scoped re-runs need a module graph we don't have, so
``changed_since`` and ``only`` are ignored — the whole command always runs. New
JSON formats plug in by adding a parser to ``PARSERS`` (see ``_parse_*``); nothing
else changes.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Callable

from .base import CaseResult, EmitFn, TestResult, TestRunnerAdapter

_TIMEOUT_S = 300
_LAUNCH_FAIL_CODES = (126, 127)


@dataclass
class Offense:
    """One normalized offense record, independent of the tool that produced it."""

    file: str
    message: str
    severity: str = "error"  # "error" (→ red) | "warning" (→ amber)
    line: int | None = None
    col: int | None = None
    rule: str = ""


# A parser turns a tool's already-decoded JSON into normalized offenses. It may
# raise on an unexpected shape — the adapter catches that and reports a parse error.
Parser = Callable[[Any], list[Offense]]


def _parse_theme_check(data: Any) -> list[Offense]:
    """`shopify theme check --output json`: a list of files, each with offenses.

    Rows/columns are 0-based in the JSON; severity is numeric (0 = error,
    1 = suggestion, 2 = style) — only 0 blocks, the rest are warnings."""
    out: list[Offense] = []
    for entry in data or []:
        path = entry.get("path") or entry.get("file") or "(unknown)"
        for off in entry.get("offenses", []) or []:
            sev = off.get("severity", 0)
            row = off.get("start_row")
            col = off.get("start_column")
            out.append(
                Offense(
                    file=path,
                    message=off.get("message", "").strip() or "(no message)",
                    severity="error" if sev == 0 else "warning",
                    line=(row + 1) if isinstance(row, int) else None,
                    col=(col + 1) if isinstance(col, int) else None,
                    rule=off.get("check", ""),
                )
            )
    return out


def _parse_eslint(data: Any) -> list[Offense]:
    """`eslint -f json`: a list of files, each with `messages`. severity 2 = error,
    1 = warning; line/column are 1-based; a fatal parse error is severity 2."""
    out: list[Offense] = []
    for entry in data or []:
        path = entry.get("filePath") or "(unknown)"
        for msg in entry.get("messages", []) or []:
            out.append(
                Offense(
                    file=path,
                    message=msg.get("message", "").strip() or "(no message)",
                    severity="error" if msg.get("severity", 2) == 2 else "warning",
                    line=msg.get("line"),
                    col=msg.get("column"),
                    rule=msg.get("ruleId") or "",
                )
            )
    return out


def _parse_ruff(data: Any) -> list[Offense]:
    """`ruff check --output-format json`: a flat list of violations. Ruff has no
    error/warning split in JSON, so every violation is treated as an error."""
    out: list[Offense] = []
    for v in data or []:
        loc = v.get("location") or {}
        out.append(
            Offense(
                file=v.get("filename") or "(unknown)",
                message=v.get("message", "").strip() or "(no message)",
                severity="error",
                line=loc.get("row"),
                col=loc.get("column"),
                rule=v.get("code") or "",
            )
        )
    return out


PARSERS: dict[str, Parser] = {
    "theme-check": _parse_theme_check,
    "eslint": _parse_eslint,
    "ruff": _parse_ruff,
}


class OffenseAdapter(TestRunnerAdapter):
    name = "offense"

    def __init__(self, command: str, fmt: str, *, login_shell: bool = False) -> None:
        self.command = (command or "").strip()
        #: JSON format key; selects the parser from ``PARSERS``.
        self.format = (fmt or "").strip().lower()
        self.login_shell = login_shell

    async def run(
        self,
        *,
        cwd: str,
        emit: EmitFn | None = None,
        changed_since: str | None = None,
        only: list[tuple[str, str]] | None = None,
    ) -> TestResult:
        if not self.command:
            return TestResult(
                ok=False,
                error='no gate command configured: set `[gate] command` in .haro/settings.toml',
            )
        parser = PARSERS.get(self.format)
        if parser is None:
            known = ", ".join(sorted(PARSERS))
            return TestResult(
                ok=False,
                error=f'unknown offense format "{self.format}": set `[gate] format` to one of: {known}',
            )

        if emit:
            await emit({"kind": "run_started"})

        started = time.monotonic()
        try:
            proc = await self._spawn(cwd)
            out, err = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except (FileNotFoundError, OSError) as exc:
            return TestResult(ok=False, error=f"could not launch gate command: {exc}")
        except asyncio.TimeoutError:
            self._kill(proc)
            return TestResult(
                ok=False,
                error=f"gate command timed out after {_TIMEOUT_S}s",
                wall_ms=(time.monotonic() - started) * 1000,
            )

        wall_ms = (time.monotonic() - started) * 1000
        code = proc.returncode or 0
        stdout = out.decode(errors="replace")
        stderr = err.decode(errors="replace").strip()

        data = _extract_json(stdout)
        if data is None:
            # No parseable JSON. A non-launch exit (127/126) reads as a setup problem;
            # otherwise the tool errored *before* producing offenses (bad config, crash).
            tail = "\n".join((stderr or stdout).strip().splitlines()[-15:])
            if code in _LAUNCH_FAIL_CODES:
                return TestResult(
                    ok=False,
                    error=f"gate command not found on PATH (exit {code}): {self.command}"
                    + (f"\n{tail}" if tail else ""),
                    wall_ms=wall_ms,
                )
            return TestResult(
                ok=False,
                error=f"could not parse {self.format} JSON output (exit {code})"
                + (f"\n{tail}" if tail else ""),
                wall_ms=wall_ms,
            )

        try:
            offenses = parser(data)
        except (AttributeError, TypeError, KeyError, ValueError) as exc:
            return TestResult(
                ok=False,
                error=f"could not read {self.format} offenses: {type(exc).__name__}: {exc}",
                wall_ms=wall_ms,
            )

        cases = await self._emit_cells(offenses, cwd, emit)
        failed = sum(1 for c in cases if c.status == "failed")
        skipped = sum(1 for c in cases if c.status == "skipped")
        return TestResult(
            ok=failed == 0,  # warnings alone stay green; only errors block the gate.
            total=len(cases),
            passed=0,
            failed=failed,
            skipped=skipped,
            wall_ms=wall_ms,
            cases=cases,
        )

    async def _emit_cells(
        self, offenses: list[Offense], cwd: str, emit: EmitFn | None
    ) -> list[CaseResult]:
        cases: list[CaseResult] = []
        for i, off in enumerate(offenses):
            rel = _rel(off.file, cwd)
            loc = rel + (f":{off.line}" if off.line else "") + (f":{off.col}" if off.line and off.col else "")
            name = f"{off.rule}: {off.message}" if off.rule else off.message
            # error → red (failed cell), warning/info → amber (skipped cell). Matches
            # the existing grid palette, so no new cell status is needed.
            status = "failed" if off.severity == "error" else "skipped"
            cr = CaseResult(file=loc, name=name, status=status, message=off.message)
            cases.append(cr)
            if emit:
                await emit(
                    {
                        "kind": "cell",
                        "cell": {
                            "id": f"{loc}:{i}",
                            "file": cr.file,
                            "name": cr.name,
                            "status": status,
                            "duration_ms": None,
                            "message": cr.message,
                        },
                    }
                )
        return cases

    async def _spawn(self, cwd: str):
        kwargs = dict(
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        if self.login_shell:
            shell = os.environ.get("SHELL", "/bin/sh")
            return await asyncio.create_subprocess_exec(shell, "-lc", self.command, **kwargs)
        return await asyncio.create_subprocess_shell(self.command, **kwargs)

    @staticmethod
    def _kill(proc) -> None:
        try:
            proc.kill()
        except ProcessLookupError:
            pass


def _rel(path: str, cwd: str) -> str:
    if not path:
        return "(unknown)"
    try:
        return os.path.relpath(path, cwd)
    except ValueError:
        return path


def _extract_json(text: str) -> Any | None:
    """Decode the tool's JSON, tolerating leading/trailing noise (progress lines,
    a trailing summary). Returns None if no JSON value can be recovered."""
    text = (text or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # Fall back to the first bracketed value — most tools emit a top-level array,
    # sometimes after progress noise or before a trailing summary line.
    start = min((i for i in (text.find("["), text.find("{")) if i != -1), default=-1)
    if start == -1:
        return None
    try:
        value, _ = json.JSONDecoder().raw_decode(text, start)
        return value
    except json.JSONDecodeError:
        return None
