"""VitestAdapter — stream a live test grid via a custom Vitest reporter.

Instead of parsing a final JSON blob (v1.0), v1.1 ships a tiny custom reporter
(``vitest_reporter.mjs``) that prints one NDJSON line per test-case event to
stdout. We read those lines as they arrive, push each cell to the ``emit`` sink
(driving the live grid), and assemble the authoritative TestResult from the same
stream — one source of truth for both the live UI and the merge verdict.

Dependency provisioning (a worktree has no node_modules) is handled upstream by
gate.ensure_deps; here we just resolve and run vitest from ``cwd``.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import tempfile
from pathlib import Path

from ... import sandbox as sandbox_mod
from .base import CaseResult, EmitFn, ImpactResult, TestRef, TestResult, TestRunnerAdapter

_TIMEOUT_S = 300
_STREAM_LIMIT = 16 * 1024 * 1024
_REPORTER = Path(__file__).with_name("vitest_reporter.mjs")


def only_args(only: list[tuple[str, str]]) -> list[str]:
    """CLI args to re-run just ``only`` tests: their files as positional path
    filters + a ``-t`` regex OR of the (escaped) full test names. Vitest matches
    ``-t`` against each test's full name, which is what the reporter reports."""
    files = sorted({f for f, _ in only if f})
    return [*files, "-t", "|".join(re.escape(name) for _, name in only)]


def _map_status(raw: str | None) -> str:
    if raw == "passed":
        return "passed"
    if raw == "failed":
        return "failed"
    return "skipped"  # skipped / pending / todo / None


class VitestAdapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, *, sandbox: bool = False) -> None:
        # usp-critique-round3.md Move D, step 1: run under bubblewrap with
        # network denied when requested AND available — see sandbox.py's
        # module docstring for what "requested" vs "available" means and why
        # this degrades rather than silently no-ops.
        self.sandbox = sandbox

    def _resolve_base(self, cwd: str) -> list[str]:
        local_bin = Path(cwd) / "node_modules" / ".bin" / "vitest"
        return [str(local_bin)] if local_bin.exists() else ["npx", "--no-install", "vitest"]

    async def run(
        self,
        *,
        cwd: str,
        emit: EmitFn | None = None,
        changed_since: str | None = None,
        only: list[tuple[str, str]] | None = None,
    ) -> TestResult:
        cmd = [*self._resolve_base(cwd), "run", f"--reporter={_REPORTER}"]
        if only:
            # Re-run just the given tests: restrict to their files (positional
            # path filters) AND to their names (`-t`, matched as a regex against
            # each test's full name — the reporter reports `fullName`).
            cmd += only_args(only)
        elif changed_since:
            cmd += ["--changed", changed_since]

        # Sandboxed only when BOTH requested and actually available (bwrap on
        # PATH) — see sandbox.py. Computed once, applied to whichever
        # TestResult below ends up representing a real run (not the early
        # FileNotFoundError/timeout returns, which gate.py never checks this
        # on anyway — see its "only on an otherwise-passed run" guard).
        sandboxed = self.sandbox and sandbox_mod.bwrap_available()
        sandbox_profile = sandbox_mod.profile_hash(network=False) if sandboxed else None
        if sandboxed:
            cmd = sandbox_mod.wrap_command(cmd)

        loop = asyncio.get_event_loop()
        started = loop.time()
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=cwd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=_STREAM_LIMIT,
            )
        except FileNotFoundError:
            return TestResult(ok=False, error="`vitest`/`npx` not found on PATH.")

        if emit:
            await emit({"kind": "run_started"})

        # id -> CaseResult (final), preserving discovery order for a stable grid.
        cells: dict[str, CaseResult] = {}
        order: list[str] = []
        reason: str | None = None

        def rel(module_id: str | None) -> str:
            if not module_id:
                return "(unknown)"
            try:
                return os.path.relpath(module_id, cwd)
            except ValueError:
                return module_id

        async def push_cell(cell_id: str, cr: CaseResult, status: str) -> None:
            if emit:
                await emit(
                    {
                        "kind": "cell",
                        "cell": {
                            "id": cell_id,
                            "file": cr.file,
                            "name": cr.name,
                            "status": status,
                            "duration_ms": cr.duration_ms,
                            "message": cr.message,
                        },
                    }
                )

        assert proc.stdout is not None
        try:
            while True:
                remaining = _TIMEOUT_S - (loop.time() - started)
                if remaining <= 0:
                    proc.kill()
                    return TestResult(ok=False, error=f"vitest timed out after {_TIMEOUT_S}s")
                try:
                    raw = await asyncio.wait_for(proc.stdout.readline(), timeout=remaining)
                except asyncio.TimeoutError:
                    proc.kill()
                    return TestResult(ok=False, error=f"vitest timed out after {_TIMEOUT_S}s")
                if not raw:
                    break  # EOF

                obj = _parse(raw)
                if obj is None:
                    continue

                g = obj.get("g")
                if g == "module":
                    for t in obj.get("tests", []):
                        cid = t.get("id")
                        if cid and cid not in cells:
                            cr = CaseResult(file=rel(t.get("moduleId")), name=t.get("name") or "(unnamed)", status="skipped")
                            cells[cid] = cr
                            order.append(cid)
                            await push_cell(cid, cr, "running")
                elif g in ("ready", "result"):
                    cid = obj.get("id")
                    if not cid:
                        continue
                    if cid not in cells:
                        cells[cid] = CaseResult(file=rel(obj.get("moduleId")), name=obj.get("name") or "(unnamed)", status="skipped")
                        order.append(cid)
                    cr = cells[cid]
                    cr.file = rel(obj.get("moduleId"))
                    cr.name = obj.get("name") or cr.name
                    if g == "ready":
                        await push_cell(cid, cr, "running")
                    else:  # result — authoritative
                        cr.status = _map_status(obj.get("status"))  # type: ignore[assignment]
                        cr.duration_ms = obj.get("duration")
                        cr.message = obj.get("message")
                        cr.stack = obj.get("stack")
                        await push_cell(cid, cr, cr.status)
                elif g == "end":
                    reason = obj.get("reason")
        finally:
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except asyncio.TimeoutError:
                proc.kill()

        wall_ms = round((loop.time() - started) * 1000, 1)
        ordered = [cells[c] for c in order]
        passed = sum(1 for c in ordered if c.status == "passed")
        failed = sum(1 for c in ordered if c.status == "failed")
        skipped = sum(1 for c in ordered if c.status == "skipped")
        total = len(ordered)
        duration_ms = round(sum(c.duration_ms or 0 for c in ordered), 2)

        if total == 0:
            # A *scoped* run matching nothing is a pass, not an error: an impacted
            # run whose diff touches no tests, or a re-run-failed whose target tests
            # were renamed/removed. Only a *full* run finding nothing is an error.
            if changed_since or only:
                return TestResult(ok=True, total=0, wall_ms=wall_ms,
                                   sandboxed=sandboxed, sandbox_profile=sandbox_profile)
            stderr = (await proc.stderr.read()).decode(errors="replace").strip() if proc.stderr else ""
            return TestResult(ok=False, error=_tail(stderr) or "no tests found", wall_ms=wall_ms)

        ok = reason == "passed" and failed == 0
        return TestResult(
            ok=ok,
            total=total,
            passed=passed,
            failed=failed,
            skipped=skipped,
            duration_ms=duration_ms or None,
            wall_ms=wall_ms,
            cases=ordered,
            sandboxed=sandboxed,
            sandbox_profile=sandbox_profile,
        )


    async def coverage(self, *, cwd: str) -> dict | None:
        """Total coverage percentages ``{lines, statements, functions, branches}``.

        Runs ``vitest run --coverage --coverage.reporter=json-summary`` writing to
        a temp dir (never the worktree). Returns None if coverage couldn't be
        produced — notably Vitest only emits the summary on a *passing* run, so a
        red suite yields None (the caller degrades gracefully)."""
        out_dir = tempfile.mkdtemp(prefix="haro_cov_")
        summary = Path(out_dir) / "coverage-summary.json"
        cmd = [
            *self._resolve_base(cwd),
            "run",
            "--coverage",
            "--coverage.reporter=json-summary",
            f"--coverage.reportsDirectory={out_dir}",
            "--reporter=dot",
        ]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=cwd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                limit=_STREAM_LIMIT,
            )
            await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except (FileNotFoundError, asyncio.TimeoutError):
            return None
        finally:
            pass
        try:
            if not summary.exists():
                return None
            total = json.loads(summary.read_text()).get("total", {})
            return {
                k: total.get(k, {}).get("pct")
                for k in ("lines", "statements", "functions", "branches")
            }
        finally:
            try:
                for p in Path(out_dir).glob("*"):
                    p.unlink()
                Path(out_dir).rmdir()
            except OSError:
                pass

    async def coverage_lines(self, *, cwd: str, repo_root: str | None = None) -> dict | None:
        """Per-line hit counts, ``{repo_relative_path: {line_no: hits}}``.

        The substrate for "code to check" (backlog/code-to-check.md §2). Where
        ``coverage()`` above asks "what percentage" (a suite-level number the ladder's
        ``coverage`` condition reads), this asks "which lines ran" so the signal can be
        intersected with the *diff*. Same shape of call, different reporter: ``json``
        writes ``coverage-final.json``, whose ``statementMap`` (start/end line per
        statement) plus ``s`` (hit count per statement id) collapse into a line map.

        Measured on haro's own 223-test suite: 0.87s with coverage vs 0.43s without, which
        is why this can run on every green gate rather than hiding behind an on-demand
        button.

        Returns **None** on any failure — no coverage provider installed (the common one:
        ``@vitest/coverage-v8`` is an opt-in devDependency and was missing from this very
        repo until it was noticed), non-zero exit, timeout, malformed JSON. The caller must
        treat None as "no coverage rows", never as "everything is unchecked".

        Paths are made repo-relative against ``repo_root`` (falling back to ``cwd``) so
        they join against ``blame.changed_lines``, which speaks git-relative paths. In a
        monorepo the gate runs in a subdir (``[gate] dir``) while the diff is rooted at the
        repo, so passing both is what keeps the two vocabularies aligned.
        """
        raw = await self._coverage_json(cwd=cwd)
        if raw is None:
            return None
        return _line_hits(raw, repo_root or cwd)

    async def _coverage_json(self, *, cwd: str) -> dict | None:
        """One `vitest run --coverage --coverage.reporter=json`, parsed. None on any
        failure (no provider installed, non-zero exit, timeout, malformed JSON)."""
        out_dir = tempfile.mkdtemp(prefix="haro_covlines_")
        final = Path(out_dir) / "coverage-final.json"
        cmd = [
            *self._resolve_base(cwd),
            "run",
            "--coverage",
            "--coverage.reporter=json",
            f"--coverage.reportsDirectory={out_dir}",
            "--reporter=dot",
        ]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=cwd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                limit=_STREAM_LIMIT,
            )
            await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except (FileNotFoundError, asyncio.TimeoutError):
            return None
        try:
            if not final.exists():
                return None
            return json.loads(final.read_text())
        except (OSError, ValueError):
            return None
        finally:
            try:
                for p in Path(out_dir).glob("*"):
                    p.unlink()
                Path(out_dir).rmdir()
            except OSError:
                pass

    async def coverage_line_maps(
        self, *, cwd: str, repo_root: str | None = None
    ) -> tuple[dict, dict] | None:
        """``(lenient, strict)`` line maps from ONE coverage run.

        The two diff-level consumers need opposite tie-breaks on a line that several
        statements overlap, so they cannot share one map — but they must share one
        measurement, because re-running the suite to get the second map is exactly the
        cost this signal is designed not to add.

        ``lenient`` (accumulate) is for **code to check**, whose failure mode is a false
        "no test ran" row: better to call a line checked than to nag about one that was.
        ``strict`` (minimum) is for **Verified Hunks**, whose failure mode is the reverse
        and far worse — telling a reviewer the green suite executed a line it never
        touched, while "collapse the executed" hides it. Under-claiming there is safe: the
        line simply stays in the residue the human reads.
        """
        raw = await self._coverage_json(cwd=cwd)
        if raw is None:
            return None
        root = repo_root or cwd
        return _line_hits(raw, root), _line_hits(raw, root, strict=True)

    async def _list(self, cwd: str, *, changed_since: str | None = None) -> list[TestRef] | None:
        """`vitest list --json` (optionally `--changed <ref>`) — a dry test list,
        no execution. Returns None if the command couldn't run."""
        cmd = [*self._resolve_base(cwd), "list", "--json"]
        if changed_since:
            cmd += ["--changed", changed_since]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=cwd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                limit=_STREAM_LIMIT,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
        except (FileNotFoundError, asyncio.TimeoutError):
            return None
        text = out.decode(errors="replace").strip()
        # `vitest list` prints the JSON array; when nothing matches, output is empty.
        if not text:
            return []
        start = text.find("[")
        if start == -1:
            return []
        try:
            data = json.loads(text[start:])
        except json.JSONDecodeError:
            return None
        refs: list[TestRef] = []
        for t in data:
            f = t.get("file", "")
            try:
                f = os.path.relpath(f, cwd)
            except ValueError:
                pass
            refs.append(TestRef(file=f, name=t.get("name", "(unnamed)")))
        return refs

    async def analyze_impact(self, *, cwd: str, base_ref: str) -> ImpactResult:
        all_tests = await self._list(cwd)
        if all_tests is None:
            return ImpactResult(supported=True, error="could not list tests (vitest missing?)")
        impacted = await self._list(cwd, changed_since=base_ref)
        return ImpactResult(all_tests=all_tests, impacted=impacted or [], supported=True)


def _line_hits(raw: dict, root: str, *, strict: bool = False) -> dict[str, dict[int, int]]:
    """Collapse istanbul-shaped ``coverage-final.json`` into ``{relpath: {line: hits}}``.

    Kept module-level and pure so it is testable without spawning vitest. Each entry has
    ``statementMap`` (statement id → ``{start:{line}, end:{line}}``) and ``s`` (statement id
    → hit count). A statement can span lines, so every line it covers inherits its count.
    Where statements OVERLAP on one line the two callers need opposite answers, which is
    what ``strict`` selects:

    * ``strict=False`` (default) — counts ACCUMULATE, so a line is cold only when every
      statement touching it is cold. Conservative for **code to check**: better to call a
      line checked than to file a false "no test ran" row.
    * ``strict=True`` — the MINIMUM wins, so a line counts as executed only when every
      statement touching it ran. Required by **Verified Hunks**: an enclosing ``if`` that
      spans its own never-taken ``throw`` (istanbul emits `5→7 count=3` around
      `6→6 count=0`) must not paint that ``throw`` as executed. Under-claiming here is the
      safe direction — the line stays in the residue a human reads, rather than being
      hidden by "collapse the executed" behind a claim the suite never earned.

    Absolute paths are made relative to ``root``; anything outside it is dropped rather
    than reported under a path the diff would never match.
    """
    root_p = Path(root).resolve()
    out: dict[str, dict[int, int]] = {}
    for abs_path, entry in (raw or {}).items():
        if not isinstance(entry, dict):
            continue
        try:
            rel = str(Path(entry.get("path") or abs_path).resolve().relative_to(root_p))
        except (ValueError, OSError):
            continue  # outside the repo (a dependency, a virtual module) — not diffable
        stmts = entry.get("statementMap") or {}
        counts = entry.get("s") or {}
        lines: dict[str, int] = out.setdefault(rel, {})  # type: ignore[assignment]
        for sid, loc in stmts.items():
            try:
                start = int(loc["start"]["line"])
                end = int(loc.get("end", {}).get("line", start) or start)
            except (KeyError, TypeError, ValueError):
                continue
            hits = counts.get(sid, 0)
            try:
                hits = int(hits)
            except (TypeError, ValueError):
                hits = 0
            if end < start:
                start, end = end, start
            for ln in range(start, end + 1):
                prev = lines.get(ln)
                if prev is None:
                    lines[ln] = hits  # type: ignore[index]
                elif strict:
                    lines[ln] = min(prev, hits)  # type: ignore[index]
                else:
                    lines[ln] = prev + hits  # type: ignore[index]
    return out


def _parse(raw: bytes) -> dict | None:
    line = raw.decode(errors="replace").strip()
    if not line or "__sg" not in line:
        return None
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) and obj.get("__sg") == 1 else None


def _tail(text: str, limit: int = 2000) -> str:
    return text if len(text) <= limit else "…" + text[-limit:]
