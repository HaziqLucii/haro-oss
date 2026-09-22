"""The project's own linter, whatever it is — run via ``[quality] lint_cmd``.

The other two adapters wrap a *known* tool, so they can parse a known JSON shape. This one
cannot: the command is whatever the project already uses (``eslint``, ``ruff check``,
``tsc --noEmit``, ``golangci-lint``, a Makefile target), and haro has no business dictating
which. So the contract is deliberately the loosest one that still produces useful findings:

  **non-zero exit ⇒ the linter objects.** Everything else is best-effort enrichment.

Enrichment is a single regex over ``path:line[:col]: message``, which is the near-universal
compiler/linter convention (eslint's default and compact formats, ruff, flake8, tsc, gcc,
shellcheck, go vet). When it matches we get real ``file:line`` findings the UI can deep-link;
when it doesn't, we still report **one** finding carrying the tail of the output, because
"your linter failed and here is what it said" beats a green gate.

There is no attempt to invent severities: a linter that exits non-zero is telling you it
found something it considers an error, so findings are reported at the configured
``[quality] lint_severity`` (default ``medium``) rather than a guess per line.
"""

from __future__ import annotations

import asyncio
import re
import time

from .base import QualityFinding, QualityResult, QualityRunnerAdapter, rel_path

_TIMEOUT_S = 300
#: `path:line:col: message` / `path:line: message` — anchored at line start so a colon in
#: prose can't fake a match. Windows drive letters are tolerated by requiring 2+ path chars.
_LINE_RE = re.compile(r"^\s*([^\s:][^:]{1,255}?):(\d+)(?::(\d+))?[:\s]\s*(.+?)\s*$")
_MAX_FINDINGS = 50


class LintAdapter(QualityRunnerAdapter):
    name = "lint"

    async def scan(
        self,
        *,
        cwd: str,
        changed_files: list[str],
        base_ref: str,
        config: dict | None = None,
    ) -> QualityResult:
        started = time.monotonic()
        cmd = str((config or {}).get("lint_cmd") or "").strip()
        if not cmd:
            return QualityResult.unavailable(
                self.name,
                "no [quality] lint_cmd is set — set one, or drop \"lint\" from "
                "[quality] scanners",
            )
        severity = str((config or {}).get("lint_severity") or "medium")
        if not changed_files:
            return QualityResult(tool=self.name, duration_ms=0.0)

        # Run through a shell so a project can write a pipeline or use its own env, the same
        # bargain `[scripts] setup`/`run` already make. This is the user's own command from
        # their own committed config, not agent-supplied input.
        try:
            proc = await asyncio.create_subprocess_shell(
                cmd, cwd=cwd,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except asyncio.TimeoutError:
            return QualityResult.unavailable(self.name, f"lint_cmd timed out after {_TIMEOUT_S}s")
        except OSError as exc:
            return QualityResult.unavailable(self.name, f"lint_cmd could not start: {exc}")

        if proc.returncode == 0:
            return QualityResult(tool=self.name, duration_ms=(time.monotonic() - started) * 1000)

        text = (out or b"").decode(errors="replace")
        changed = set(changed_files)
        findings: list[QualityFinding] = []
        for raw in text.splitlines():
            m = _LINE_RE.match(raw)
            if not m:
                continue
            path = rel_path(m.group(1), cwd)
            # Diff-scoped like every other signal: a linter run over the whole project must
            # not drown this change in the repo's standing debt.
            if path not in changed:
                continue
            findings.append(
                QualityFinding(
                    tool=self.name, severity=severity, file=path,
                    line=int(m.group(2)) or None,
                    rule="lint", message=m.group(4)[:300],
                )
            )
            if len(findings) >= _MAX_FINDINGS:
                break

        if not findings:
            # It objected but we couldn't attribute it to a changed line. Report the failure
            # itself rather than swallowing it — an unexplained non-zero linter is still a
            # reason not to ship, and the tail is what the human needs to see.
            tail = "\n".join(text.strip().splitlines()[-4:]) or f"lint_cmd exited {proc.returncode}"
            findings.append(
                QualityFinding(
                    tool=self.name, severity=severity, file="", line=None, rule="lint",
                    message=f"lint_cmd exited {proc.returncode}: {tail[:300]}",
                )
            )
        return QualityResult(
            tool=self.name,
            findings=findings,
            duration_ms=(time.monotonic() - started) * 1000,
        )
