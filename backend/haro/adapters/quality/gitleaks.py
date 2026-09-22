"""Gitleaks — secret detection, the highest-value half of the deterministic quality gate.

Verified against **gitleaks 8.21.2**; every flag and exit code below was checked against the
real binary rather than written from memory:

* ``detect --no-git --source <path>`` scans the *filesystem*, which is what haro needs: an
  agent's edits are usually **uncommitted**, so a git-history scan would miss the very diff
  we are gating. It also honours ``.gitignore`` (confirmed: a planted secret under an
  ignored ``node_modules/`` is not reported), so a worktree full of dependencies costs
  nothing.
* **Exit code 1 means "leaks found", not "failed to run."** Treating non-zero as a crash
  would turn every real secret into a *degraded* verdict — the check would break exactly
  when it worked. Only an exit code outside ``{0, 1}``, a missing binary, a timeout or an
  unreadable report is a genuine failure.
* ``--pipe`` (feeding it ``git diff``) was evaluated and rejected: it returns an empty
  ``File`` and a ``StartLine`` counted in *diff* offsets, so findings could not be
  deep-linked to ``file:line``.

**We never store the secret itself.** gitleaks returns ``Secret`` and ``Match``; carrying
either into a finding would copy the credential into the store, the WS feed, the database
and the UI — turning a leak detector into a leak amplifier. Only the rule, file and line
travel, which is all a human needs to go fix it.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import tempfile
import time
from pathlib import Path

from .base import QualityFinding, QualityResult, QualityRunnerAdapter, rel_path

_TIMEOUT_S = 120


class GitleaksAdapter(QualityRunnerAdapter):
    name = "gitleaks"

    async def scan(
        self,
        *,
        cwd: str,
        changed_files: list[str],
        base_ref: str,
        config: dict | None = None,
    ) -> QualityResult:
        started = time.monotonic()
        binary = (config or {}).get("gitleaks_cmd") or "gitleaks"
        if shutil.which(binary) is None:
            return QualityResult.unavailable(
                self.name,
                f"`{binary}` is not installed — install gitleaks or drop it from "
                "[quality] scanners",
            )
        if not changed_files:
            return QualityResult(tool=self.name, duration_ms=0.0)

        out_dir = tempfile.mkdtemp(prefix="haro_gitleaks_")
        report = Path(out_dir) / "report.json"
        cmd = [
            binary, "detect",
            "--no-git",                 # scan the working tree: agent edits are uncommitted
            "--source", cwd,
            "--report-format", "json",
            "--report-path", str(report),
            "--no-banner",
            "--redact",                 # belt-and-braces: keep raw secrets out of the report
        ]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=cwd,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            _, err = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except asyncio.TimeoutError:
            return QualityResult.unavailable(self.name, f"gitleaks timed out after {_TIMEOUT_S}s")
        except OSError as exc:
            return QualityResult.unavailable(self.name, f"gitleaks could not start: {exc}")

        # 0 = clean, 1 = leaks found. Anything else is a real failure.
        if proc.returncode not in (0, 1):
            detail = (err or b"").decode(errors="replace").strip().splitlines()
            return QualityResult.unavailable(
                self.name,
                f"gitleaks exited {proc.returncode}: {detail[-1] if detail else 'no output'}",
            )
        try:
            raw = json.loads(report.read_text()) if report.exists() else []
        except (OSError, ValueError) as exc:
            return QualityResult.unavailable(self.name, f"gitleaks report unreadable: {exc}")
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)

        changed = set(changed_files)
        findings: list[QualityFinding] = []
        for row in raw if isinstance(raw, list) else []:
            if not isinstance(row, dict):
                continue
            # gitleaks echoes the `--source` it was handed, so an absolute source yields
            # absolute `File` values — normalize or the diff filter below matches nothing
            # and every real secret reports as clean.
            path = rel_path(row.get("File") or "", cwd)
            # Diff-scoped: the gate reports on the CHANGE, so a secret that was already in
            # the repo is somebody else's problem and must not block this merge.
            if path not in changed:
                continue
            rule = str(row.get("RuleID") or "secret")
            findings.append(
                QualityFinding(
                    tool=self.name,
                    # A committed credential is never a "medium". There is no severity
                    # threshold at which leaking one is acceptable, so this is always high.
                    severity="high",
                    file=path,
                    line=int(row.get("StartLine") or 0) or None,
                    rule=rule,
                    # Description only — never `Secret`/`Match` (see the module docstring).
                    message=str(row.get("Description") or f"possible secret ({rule})"),
                )
            )
        return QualityResult(
            tool=self.name,
            findings=findings,
            duration_ms=(time.monotonic() - started) * 1000,
        )
