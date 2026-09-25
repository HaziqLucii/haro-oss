"""CommandAdapter — gate a project with an arbitrary configured command.

The escape hatch for the two-runner set (Vitest/pytest): projects whose gate is
"run this and check the exit code" (a Makefile target, a shell one-liner, a
`go test ./...`, a custom `check.sh`) can gate without a bespoke adapter. Selected
per-project via ``.haro/settings.toml``::

    [gate]
    runner = "command"
    command = "make test"

The contract is deliberately thin — this trades the live grid for universality:

- **exit 0 → green**, **non-zero → red** (a genuine failing gate). There's no
  per-case parsing, so the normalized ``TestResult`` reports the pass/fail via
  ``ok`` with ``total/passed/failed`` left at ``0`` (informational, like a
  couldn't-parse pytest run — the merge gate only ever reads ``ok``).
- **can't launch** (the command's binary isn't on PATH → the shell exits 127)
  becomes an ``error`` result, which the gate classifies as ``error_kind=setup``
  ("the gate never ran — fix your config") rather than a scary red.
- stdout+stderr stream to the WS ``test`` channel as ``{"kind": "log"}`` lines so
  the run is watchable; there's no live grid yet.

Impact analysis / coverage aren't supported (no module graph), so ``changed_since``
and ``only`` are ignored — the gate always runs the whole command.
"""

from __future__ import annotations

import asyncio
import os
import time

from .base import EmitFn, TestResult, TestRunnerAdapter

_TIMEOUT_S = 600
# Conventional shell exit code for "command not found" (127) / "not executable"
# (126). We treat these as *couldn't launch* rather than a red gate, so a typo in
# the configured command reads as a setup problem instead of a failing test suite.
_LAUNCH_FAIL_CODES = (126, 127)


class CommandAdapter(TestRunnerAdapter):
    name = "command"

    def __init__(self, command: str, *, login_shell: bool = False) -> None:
        #: The shell command to run; empty → the gate has nothing to run.
        self.command = (command or "").strip()
        #: Run through ``$SHELL -lc`` so version managers (nvm/asdf/pyenv) that init
        #: from a login rc file put project toolchains on PATH — mirrors lifecycle.
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

        if emit:
            await emit({"kind": "run_started"})

        started = time.monotonic()
        try:
            proc = await self._spawn(cwd)
        except (FileNotFoundError, OSError) as exc:
            # The shell itself couldn't be spawned — a setup problem, not a red gate.
            return TestResult(ok=False, error=f"could not launch gate command: {exc}")

        assert proc.stdout is not None
        tail: list[str] = []
        try:
            async def _pump() -> None:
                async for raw in proc.stdout:  # type: ignore[union-attr]
                    line = raw.decode(errors="replace").rstrip("\n")
                    tail.append(line)
                    if len(tail) > 200:  # keep only the tail for the error summary
                        del tail[0]
                    if emit:
                        await emit({"kind": "log", "line": line})
                await proc.wait()

            await asyncio.wait_for(_pump(), timeout=_TIMEOUT_S)
        except asyncio.TimeoutError:
            self._kill(proc)
            return TestResult(
                ok=False,
                error=f"gate command timed out after {_TIMEOUT_S}s",
                wall_ms=(time.monotonic() - started) * 1000,
            )

        wall_ms = (time.monotonic() - started) * 1000
        code = proc.returncode or 0

        if code == 0:
            # Green: no per-case detail to report, so the counts stay informational.
            return TestResult(ok=True, wall_ms=wall_ms)

        if code in _LAUNCH_FAIL_CODES:
            # Couldn't launch (binary not on PATH). Phrase the error so the gate's
            # classifier tags it ``setup`` — "the gate never ran", not a failing suite.
            summary = "\n".join(tail[-15:]).strip()
            return TestResult(
                ok=False,
                error=f"gate command not found on PATH (exit {code}): {self.command}"
                + (f"\n{summary}" if summary else ""),
                wall_ms=wall_ms,
            )

        # Non-zero exit → a genuine red gate. The detail lives in the streamed log;
        # ``error`` stays unset so the gate records a red (failed), not an error.
        return TestResult(ok=False, wall_ms=wall_ms)

    async def _spawn(self, cwd: str):
        kwargs = dict(
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
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
