"""Semgrep — static security patterns over the changed files.

Verified against **semgrep 1.171.0**:

* ``semgrep scan --config <cfg> --json --quiet <files…>`` exits **0 whether or not it finds
  anything** (unlike gitleaks), so the exit code is purely a ran/didn't-run signal here.
* Findings live at ``results[]`` with ``check_id``, ``path``, ``start.line`` and
  ``extra.{severity,message}``; ``severity`` is ``ERROR``/``WARNING``/``INFO``.
* Rule-level problems come back in ``errors[]`` rather than on the exit code, so we surface
  those as a degraded scan instead of quietly reporting "clean".

**Offline by default.** The registry packs (``p/security-audit`` and friends) are better
rulesets, but semgrep fetches them over the network on first use, and a quality gate that
needs the internet to say anything is not one you can lean on. So the default config is a
small bundled ruleset shipped with haro (``assets/quality/semgrep-rules.yaml``). Point
``[quality] semgrep_config`` at a registry pack or your own YAML to replace it — that is the
expected move once a project cares enough to tune it.

Scoped to the changed files for the same reason every other signal here is: the gate reports
on the CHANGE. Running the whole repo would bury a real finding in a project's standing debt.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import time
from pathlib import Path

from .base import QualityFinding, QualityResult, QualityRunnerAdapter, rel_path

_TIMEOUT_S = 300
#: semgrep's severities → ours. ERROR is semgrep's "this is a bug", not "the scan failed".
_SEVERITY = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}
_BUNDLED_RULES = Path(__file__).resolve().parents[2] / "assets" / "quality" / "semgrep-rules.yaml"
#: Semgrep parses by language; handing it a lockfile or a PNG just wastes time.
_SCANNABLE = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".rb", ".java",
    ".php", ".rs", ".c", ".cpp", ".cs", ".scala", ".kt", ".swift", ".sh", ".bash",
}


class SemgrepAdapter(QualityRunnerAdapter):
    name = "semgrep"

    async def scan(
        self,
        *,
        cwd: str,
        changed_files: list[str],
        base_ref: str,
        config: dict | None = None,
    ) -> QualityResult:
        started = time.monotonic()
        cfg = config or {}
        binary = cfg.get("semgrep_cmd") or "semgrep"
        if shutil.which(binary) is None:
            return QualityResult.unavailable(
                self.name,
                f"`{binary}` is not installed — `pip install semgrep`, or drop it from "
                "[quality] scanners",
            )
        targets = [f for f in changed_files if Path(f).suffix.lower() in _SCANNABLE]
        if not targets:
            return QualityResult(tool=self.name, duration_ms=0.0)

        rules = str(cfg.get("semgrep_config") or _BUNDLED_RULES)
        cmd = [binary, "scan", "--config", rules, "--json", "--quiet", "--disable-version-check", *targets]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=cwd,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            out, err = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except asyncio.TimeoutError:
            return QualityResult.unavailable(self.name, f"semgrep timed out after {_TIMEOUT_S}s")
        except OSError as exc:
            return QualityResult.unavailable(self.name, f"semgrep could not start: {exc}")

        if proc.returncode != 0:
            detail = (err or b"").decode(errors="replace").strip().splitlines()
            return QualityResult.unavailable(
                self.name,
                f"semgrep exited {proc.returncode}: {detail[-1] if detail else 'no output'}",
            )
        try:
            data = json.loads(out.decode(errors="replace") or "{}")
        except ValueError as exc:
            return QualityResult.unavailable(self.name, f"semgrep output unparseable: {exc}")

        # A broken/unreachable ruleset shows up here, NOT on the exit code. Reporting
        # "clean" off a scan whose rules failed to load is the silent pass §0 forbids.
        errors = data.get("errors") or []
        if errors and not data.get("results"):
            first = errors[0]
            reason = first.get("long_msg") or first.get("message") or str(first)
            return QualityResult.unavailable(self.name, f"semgrep could not scan: {str(reason)[:200]}")

        changed = set(changed_files)
        findings: list[QualityFinding] = []
        for row in data.get("results") or []:
            path = rel_path(row.get("path") or "", cwd)
            if path not in changed:
                continue
            extra = row.get("extra") or {}
            # `check_id` is namespaced by the rules file ("tmp.rules.haro-js-eval"); the
            # last segment is the rule a human recognises.
            rule = str(row.get("check_id") or "semgrep").split(".")[-1]
            findings.append(
                QualityFinding(
                    tool=self.name,
                    severity=_SEVERITY.get(str(extra.get("severity") or "").upper(), "low"),
                    file=path,
                    line=int((row.get("start") or {}).get("line") or 0) or None,
                    rule=rule,
                    message=str(extra.get("message") or rule).strip(),
                )
            )
        return QualityResult(
            tool=self.name,
            findings=findings,
            duration_ms=(time.monotonic() - started) * 1000,
        )
