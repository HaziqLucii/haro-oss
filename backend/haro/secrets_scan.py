"""Advisory secrets scan: gitleaks over the diff, surfaced as "code to check" rows.

Not part of the verdict. Green/red is deterministic tests plus the suite-level guards; this
is a courtesy pass that says "line 12 of x.py looks like a credential". It must never set a
blocked flag, degrade a run, or refuse a ship, so:

* a missing gitleaks (or a crash, timeout, unreadable report) returns ``None`` and the
  caller skips silently, at most leaving a one-line note in the log;
* findings are scoped to files the change touched, so a legacy repo's standing debt does
  not drown the pane.

Verified against gitleaks 8.21.2:

* ``detect --no-git --source <dir>`` scans a directory; haro points it at a temp dir holding
  only the changed files, so it can never walk node_modules or build output. It scans files, which is what haro needs: an
  agent's edits are usually uncommitted, so a git-history scan would miss the diff. It
  honours ``.gitignore``, so a worktree full of dependencies costs nothing.
* Exit code 1 means "leaks found", not "failed to run". Only an exit code outside {0, 1},
  a missing binary, a timeout or an unreadable report means the scan did not happen.
* ``--redact`` and keeping only ``RuleID``/``Description``/``File``/``StartLine`` means the
  credential itself never reaches the store, the WS feed, the database or the UI.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

#: Short on purpose: the scan sits before the gate publishes its verdict, and a missing
#: secret row is cheaper than a slow gate.
_TIMEOUT_S = 20
_MAX_FILE_BYTES = 2_000_000


@dataclass
class SecretFinding:
    file: str
    line: int | None
    rule: str
    message: str


def _rel_path(raw: str, root: str) -> str:
    """Repo-relative path. gitleaks echoes whatever ``--source`` it was given, so an
    absolute source yields absolute ``File`` values; comparing those against relative
    changed files would match nothing and report every real secret as clean."""
    p = str(raw or "").replace("\\", "/")
    if not p:
        return ""
    if p.startswith("./"):
        p = p[2:]
    if Path(p).is_absolute():
        try:
            return str(Path(p).resolve().relative_to(Path(root).resolve()))
        except (ValueError, OSError):
            return Path(p).name
    return p


def _stage(cwd: str, changed_files: list[str], dest: Path) -> list[str]:
    """Copy just the changed files into ``dest`` (paths preserved) so gitleaks never walks
    node_modules or build output. gitleaks has no file-list flag, and line numbers survive
    because whole files are copied."""
    staged: list[str] = []
    root = Path(cwd).resolve()
    for rel in changed_files:
        src = (root / rel)
        try:
            if src.is_symlink() or not src.is_file() or src.stat().st_size > _MAX_FILE_BYTES:
                continue
            src.resolve().relative_to(root)
            out = dest / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, out)
        except (OSError, ValueError):
            continue
        staged.append(rel)
    return staged


async def scan(
    *, cwd: str, changed_files: list[str], binary: str = "gitleaks"
) -> list[SecretFinding] | None:
    """Findings on ``changed_files`` (possibly empty), or ``None`` when the scan did not
    run for any reason. ``None`` and ``[]`` are different answers, and only the caller's
    silence makes ``None`` safe: nothing downstream may read it as a verdict."""
    if not changed_files:
        return []
    if shutil.which(binary) is None:
        log.info("secrets scan skipped: %s is not installed", binary)
        return None

    out_dir = tempfile.mkdtemp(prefix="haro_gitleaks_")
    src_dir = Path(out_dir) / "src"
    src_dir.mkdir()
    report = Path(out_dir) / "report.json"
    try:
        staged = _stage(cwd, changed_files, src_dir)
        if not staged:
            return []
        cmd = [
            binary, "detect", "--no-git", "--source", str(src_dir),
            "--report-format", "json", "--report-path", str(report),
            "--no-banner", "--redact",
        ]
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=str(src_dir),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except (asyncio.TimeoutError, OSError) as exc:
            if proc is not None and proc.returncode is None:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
                await proc.wait()
            log.info("secrets scan skipped: gitleaks %s", type(exc).__name__)
            return None
        if proc.returncode not in (0, 1):
            log.info("secrets scan skipped: gitleaks exited %s", proc.returncode)
            return None
        try:
            raw = json.loads(report.read_text()) if report.exists() else []
        except (OSError, ValueError):
            log.info("secrets scan skipped: gitleaks report unreadable")
            return None
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)

    changed = set(staged)
    findings: list[SecretFinding] = []
    seen: set[tuple] = set()
    for row in raw if isinstance(raw, list) else []:
        if not isinstance(row, dict):
            continue
        path = _rel_path(row.get("File") or "", str(src_dir))
        if path not in changed:
            continue
        rule = str(row.get("RuleID") or "secret")
        line = int(row.get("StartLine") or 0) or None
        if (path, line, rule) in seen:
            continue
        seen.add((path, line, rule))
        findings.append(
            SecretFinding(
                file=path, line=line, rule=rule,
                message=str(row.get("Description") or f"possible secret ({rule})"),
            )
        )
    return findings
