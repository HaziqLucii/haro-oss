"""PytestAdapter — run a Python project's pytest suite, normalized like Vitest.

Uses pytest's JUnit XML (``--junit-xml``) for robust, standard parsing — no plugin
needed. Results arrive as a final snapshot rather than streamed cell-by-cell (the
live grid still fills from the snapshot; live streaming for pytest is a later
enhancement). Impact analysis + coverage aren't supported yet, so the gate simply
runs the full suite — which is exactly what "gate the backend" needs to start.

Selected per-project via ``.haro/settings.toml`` ``[gate] runner = "pytest"``;
the default stays Vitest, so no other project is affected.
"""

from __future__ import annotations

import asyncio
import os
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from .base import CaseResult, EmitFn, TestResult, TestRunnerAdapter

_TIMEOUT_S = 300


class PytestAdapter(TestRunnerAdapter):
    name = "pytest"

    def _python(self, cwd: str) -> list[str]:
        """The interpreter to run pytest with. Uses the ambient python (the one
        running the backend), which has the project's deps + pytest installed —
        worktrees are deps-free, and a bind-mounted host ``.venv`` isn't runnable
        in-container. (A per-project interpreter override can come later.)"""
        return ["python"]

    async def run(
        self,
        *,
        cwd: str,
        emit: EmitFn | None = None,
        changed_since: str | None = None,
        only: list[tuple[str, str]] | None = None,
    ) -> TestResult:
        if emit:
            await emit({"kind": "run_started"})

        fd, junit = tempfile.mkstemp(suffix=".xml", prefix="synth-pytest-")
        os.close(fd)
        cmd = [
            *self._python(cwd),
            "-m", "pytest", "-q",
            "-p", "no:cacheprovider",
            f"--junit-xml={junit}",
            "-o", "junit_family=xunit2",
        ]
        # Re-run failed only: pytest has no live cells yet, so narrow to the failing
        # tests' *files* (positional args) — a robust coarse re-run without brittle
        # `-k` name expressions. (changed_since / impact isn't supported yet → all.)
        if only:
            for f in sorted({f for f, _ in only if f}):
                cmd.append(f)

        started = time.monotonic()
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=cwd,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
        except FileNotFoundError:
            return TestResult(ok=False, error="`python`/`pytest` not found: add pytest to the project.")

        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            return TestResult(ok=False, error=f"pytest timed out after {_TIMEOUT_S}s")

        wall_ms = (time.monotonic() - started) * 1000
        code = proc.returncode or 0
        text = out.decode(errors="replace")

        if code == 5:  # pytest's "no tests collected"
            _rm(junit)
            return TestResult(ok=False, error="no tests found", wall_ms=wall_ms)

        cases = _parse_junit(junit)
        _rm(junit)

        if not cases and code != 0:
            # couldn't even run (import/collection error) — surface the tail
            tail = "\n".join(text.strip().splitlines()[-15:])
            return TestResult(ok=False, error=tail or f"pytest exited {code}", wall_ms=wall_ms)

        passed = sum(1 for c in cases if c.status == "passed")
        failed = sum(1 for c in cases if c.status == "failed")
        skipped = sum(1 for c in cases if c.status == "skipped")
        duration_ms = sum((c.duration_ms or 0) for c in cases)

        if emit:
            for i, c in enumerate(cases):
                await emit({
                    "kind": "cell",
                    "cell": {
                        "id": f"{c.file}::{c.name}::{i}",
                        "file": c.file,
                        "name": c.name,
                        "status": c.status,
                        "duration_ms": c.duration_ms,
                        "message": c.message,
                    },
                })

        return TestResult(
            ok=(failed == 0 and code == 0),
            total=len(cases),
            passed=passed,
            failed=failed,
            skipped=skipped,
            duration_ms=duration_ms,
            wall_ms=wall_ms,
            cases=cases,
        )


def _rm(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _parse_junit(path: str) -> list[CaseResult]:
    cases: list[CaseResult] = []
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, FileNotFoundError, OSError):
        return cases
    for suite in root.iter("testsuite"):
        for tc in suite.findall("testcase"):
            file = tc.get("file") or tc.get("classname", "").replace(".", "/")
            name = tc.get("name", "?")
            t = tc.get("time")
            duration_ms = float(t) * 1000 if t else None
            status = "passed"
            message = None
            stack = None
            fail = tc.find("failure")
            err = tc.find("error")
            skip = tc.find("skipped")
            if fail is not None or err is not None:
                status = "failed"
                node = fail if fail is not None else err
                message = (node.get("message") or (node.text or "")).strip()[:500]
                # The element body is the full traceback — keep it (capped) so
                # "failure → blame" can match its ``file:line`` frames to the diff.
                stack = (node.text or "").strip()[-4000:] or None
            elif skip is not None:
                status = "skipped"
                message = (skip.get("message") or "").strip()[:500] or None
            cases.append(
                CaseResult(
                    file=file, name=name, status=status,
                    duration_ms=duration_ms, message=message, stack=stack,
                )
            )
    return cases
