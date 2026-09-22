"""Red-first check (usp-critique-round3.md Move C): a genuinely NEW test that
already passes at base_ref (the OLD implementation) never exercised the
behaviour it claims to. ``gate._red_first_check`` overlays just the current
content of the files holding newly-added tests onto a throwaway base_ref
worktree and re-runs exactly those tests there — this exercises the real git
worktree + file-overlay wiring with a controllable fake adapter standing in
for vitest (mirrors test_merge_gate.py's real-repo pattern)."""

import asyncio
import subprocess
from pathlib import Path

from haro import gate, git_ops
from haro.adapters.test_runner.base import CaseResult
from haro.adapters.test_runner.base import TestRef as Ref
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.adapters.test_runner.base import TestRunnerAdapter


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "math.test.js").write_text("// no tests yet\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    return repo


class _RecordingAdapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, result: RunResult):
        self._result = result
        self.calls: list[dict] = []

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        # Snapshot the overlaid file's content HERE, while the throwaway worktree
        # still exists — the caller's `finally` removes it before `run()` returns,
        # so this is the only point a test can see what actually landed there.
        seen = {}
        for f, _name in only or []:
            p = Path(cwd) / f
            if p.exists():
                seen[f] = p.read_text()
        self.calls.append({"cwd": cwd, "only": only, "overlaid": seen})
        return self._result


def test_vacuous_test_flagged_when_it_passes_at_base_ref(tmp_path):
    repo = _repo(tmp_path)
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, "main"))
    # simulate an agent adding a test to the worktree
    (wt / "math.test.js").write_text("it('adds', () => expect(1 + 1).toBe(2))\n")

    added = [Ref(file="math.test.js", name="adds")]
    adapter = _RecordingAdapter(RunResult(
        ok=True, total=1, passed=1, failed=0,
        cases=[CaseResult(file="math.test.js", name="adds", status="passed")],
    ))
    findings = asyncio.run(gate._red_first_check(
        adapter=adapter, project_path=str(repo), base_ref="main",
        current_cwd=str(wt), gate_dir="", dep_root=str(repo), added=added,
    ))

    assert len(findings) == 1
    assert findings[0].kind == "vacuous"
    assert findings[0].file == "math.test.js"
    assert findings[0].test == "adds"
    assert len(adapter.calls) == 1
    call = adapter.calls[0]
    assert call["only"] == [("math.test.js", "adds")]
    # ran in the THROWAWAY worktree, not the live one the test file was copied from
    assert call["cwd"] != str(wt)
    assert "haro-redfirst" in call["cwd"]
    # the overlay actually landed the CURRENT (new-test) content at base_ref
    assert call["overlaid"] == {"math.test.js": "it('adds', () => expect(1 + 1).toBe(2))\n"}
    # the throwaway worktree was cleaned up, not leaked
    rows = asyncio.run(git_ops.list_worktrees(repo))
    assert all("haro-redfirst" not in r["path"] for r in rows)


def test_genuinely_new_test_not_flagged_when_it_fails_at_base_ref(tmp_path):
    repo = _repo(tmp_path)
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, "main"))
    (wt / "math.test.js").write_text("it('adds', () => expect(1 + 1).toBe(2))\n")

    added = [Ref(file="math.test.js", name="adds")]
    adapter = _RecordingAdapter(RunResult(
        ok=False, total=1, passed=0, failed=1,
        cases=[CaseResult(file="math.test.js", name="adds", status="failed")],
    ))
    findings = asyncio.run(gate._red_first_check(
        adapter=adapter, project_path=str(repo), base_ref="main",
        current_cwd=str(wt), gate_dir="", dep_root=str(repo), added=added,
    ))

    assert findings == []


def test_worktree_cleaned_up_even_when_adapter_raises(tmp_path):
    repo = _repo(tmp_path)
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, "main"))
    (wt / "math.test.js").write_text("it('adds', () => expect(1 + 1).toBe(2))\n")

    class _Boom(TestRunnerAdapter):
        name = "vitest"

        async def run(self, *, cwd, emit=None, changed_since=None, only=None):
            raise RuntimeError("vitest crashed")

    added = [Ref(file="math.test.js", name="adds")]
    try:
        asyncio.run(gate._red_first_check(
            adapter=_Boom(), project_path=str(repo), base_ref="main",
            current_cwd=str(wt), gate_dir="", dep_root=str(repo), added=added,
        ))
        raise AssertionError("expected RuntimeError to propagate")
    except RuntimeError:
        pass
    rows = asyncio.run(git_ops.list_worktrees(repo))
    assert all("haro-redfirst" not in r["path"] for r in rows)


def test_base_suite_that_cannot_run_at_all_is_not_silently_clean(tmp_path):
    # A `TestResult(error=...)` (runner missing, nothing matched, …) is NOT the
    # same as "every added test correctly failed at base" — refuter round-3 found
    # this reading as a silent, wrong "clean" (zero vacuous findings, no raise).
    repo = _repo(tmp_path)
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, "main"))
    (wt / "math.test.js").write_text("it('adds', () => expect(1 + 1).toBe(2))\n")

    added = [Ref(file="math.test.js", name="adds")]
    adapter = _RecordingAdapter(RunResult(ok=False, error="`vitest`/`npx` not found on PATH.", cases=[]))
    try:
        asyncio.run(gate._red_first_check(
            adapter=adapter, project_path=str(repo), base_ref="main",
            current_cwd=str(wt), gate_dir="", dep_root=str(repo), added=added,
        ))
        raise AssertionError("expected a RuntimeError, not a silent empty result")
    except RuntimeError as exc:
        assert "could not run" in str(exc)
    rows = asyncio.run(git_ops.list_worktrees(repo))
    assert all("haro-redfirst" not in r["path"] for r in rows)


def test_monorepo_gate_dir_overlay_lands_in_the_right_subdir(tmp_path):
    # gate_dir is a subdir (e.g. "frontend" in a monorepo) — the overlay and the
    # adapter's cwd must both land under <throwaway_worktree>/frontend, matching
    # how `run_gate` computes `gate_cwd` for the live run.
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "frontend").mkdir()
    (repo / "frontend" / "math.test.js").write_text("// no tests yet\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, "main"))
    (wt / "frontend" / "math.test.js").write_text("it('adds', () => expect(1 + 1).toBe(2))\n")

    added = [Ref(file="math.test.js", name="adds")]  # relative to gate_cwd, i.e. frontend/
    adapter = _RecordingAdapter(RunResult(
        ok=True, total=1, passed=1, failed=0,
        cases=[CaseResult(file="math.test.js", name="adds", status="passed")],
    ))
    findings = asyncio.run(gate._red_first_check(
        adapter=adapter, project_path=str(repo), base_ref="main",
        current_cwd=str(wt / "frontend"), gate_dir="frontend", dep_root=str(repo), added=added,
    ))

    assert len(findings) == 1
    call = adapter.calls[0]
    assert call["cwd"].endswith("/frontend")
    assert call["overlaid"] == {"math.test.js": "it('adds', () => expect(1 + 1).toBe(2))\n"}
