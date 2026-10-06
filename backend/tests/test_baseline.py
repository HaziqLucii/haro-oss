"""First-run baseline gate (baseline.py + ``/projects/{id}/baseline``).

A real tmp git repo, a stubbed ``RunnerAdapter`` (no vitest/pytest is launched), and
the module-level ``main.store`` for the route tests. What is pinned: a clean checkout on
the default branch is tested in place; a dirty checkout or another checked-out branch goes
through a throwaway worktree that is gone afterwards even when the runner blows up; the
user's checkout is never written; one baseline per project (409); the result persists on
the Project and old project rows without the field still load.
"""

import asyncio
import os
import subprocess
import tempfile
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import baseline, git_ops, main
from haro.config import load_project_settings
from haro.adapters.test_runner.base import CaseResult
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.adapters.test_runner.base import TestRunnerAdapter as RunnerAdapter
from haro.hub import Hub
from haro.models import BaselineResult, BaselineState, Project
from haro.store import Store


def run(coro):
    return asyncio.run(coro)


def _git(cwd, *args):
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    }
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=env
    ).stdout


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    (root / "a.txt").write_text("one\n")
    _git(root, "add", ".")
    _git(root, "commit", "-q", "-m", "init")
    return root


def _project(repo) -> Project:
    return Project(name="demo", path=str(repo), default_branch="main")


class StubAdapter(RunnerAdapter):
    """Records the cwd it ran in and whether that dir existed then."""

    name = "pytest"

    def __init__(self, result: RunResult | None = None, *, raises: Exception | None = None,
                 cells: int = 0, gate: asyncio.Event | None = None):
        self.result = result or RunResult(
            ok=True, total=2, passed=2,
            cases=[CaseResult("t.py", "a", "passed"), CaseResult("t.py", "b", "passed")],
            wall_ms=1500,
        )
        self.raises = raises
        self.cells = cells
        self.gate = gate
        self.cwd: str | None = None
        self.existed = False
        self.calls = 0

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        self.calls += 1
        self.cwd = cwd
        self.existed = Path(cwd).is_dir()
        if emit:
            await emit({"kind": "run_started"})
            for i in range(self.cells):
                await emit({"kind": "cell", "cell": {"id": f"c{i}", "status": "running"}})
                await emit({"kind": "cell", "cell": {"id": f"c{i}", "status": "passed"}})
        if self.gate:
            await self.gate.wait()
        if self.raises:
            raise self.raises
        return self.result


def _drive(repo, adapter, project=None):
    """Run one baseline; return (result, project, feed events)."""
    project = project or _project(repo)
    store, hub = Store(), Hub()
    store.projects[project.id] = project

    async def go():
        q = hub.subscribe_global()
        result = await baseline.run_baseline(store=store, hub=hub, project=project, adapter_for=lambda _p: adapter)
        events = []
        while not q.empty():
            events.append(q.get_nowait())
        return result, events

    result, events = run(go())
    return result, project, events


def _worktrees(repo) -> list[str]:
    out = _git(repo, "worktree", "list", "--porcelain")
    return [line for line in out.splitlines() if line.startswith("worktree ")]


def _snapshot(repo) -> str:
    return _git(repo, "status", "--porcelain", "--ignored")


def test_a_clean_checkout_also_runs_in_a_temp_worktree_and_stays_byte_identical(repo):
    (repo / ".gitignore").write_text("dist/\n*.pyc\n")
    _git(repo, "add", ".gitignore")
    _git(repo, "commit", "-qm", "ignore")
    (repo / "dist").mkdir()
    (repo / "dist" / "old.js").write_text("old\n")
    before = _snapshot(repo)
    assert before.strip() == "!! dist/"

    class Writer(StubAdapter):
        async def run(self, *, cwd, **kw):
            (Path(cwd) / "new.snap").write_text("snapshot\n")
            (Path(cwd) / "dist").mkdir(exist_ok=True)
            (Path(cwd) / "dist" / "bundle.js").write_text("built\n")
            (Path(cwd) / "a.txt").write_text("mutated by the runner\n")
            return await super().run(cwd=cwd, **kw)

    adapter = Writer(cells=3)
    result, project, events = _drive(repo, adapter)
    assert Path(adapter.cwd).resolve() != repo.resolve()
    assert not Path(adapter.cwd).exists()
    assert _snapshot(repo) == before
    assert (repo / "a.txt").read_text() == "one\n"
    assert not (repo / "new.snap").exists()
    assert sorted(p.name for p in (repo / "dist").iterdir()) == ["old.js"]
    assert len(_worktrees(repo)) == 1
    assert result.status == "passed" and result.passed == 2 and result.total == 2
    assert result.duration_s == 1.5
    assert result.sha == _git(repo, "rev-parse", "main").strip()
    assert result.coverage_pct is None
    assert project.baseline is result
    kinds = [e["kind"] for e in events]
    assert kinds[0] == "started" and kinds[-1] == "done"
    assert kinds.count("cell") == 3
    assert all(e["channel"] == "baseline" and e["project_id"] == project.id for e in events)
    assert [e["passed"] for e in events if e["kind"] == "cell"] == [1, 2, 3]
    assert events[-1]["result"]["status"] == "passed"


def test_the_worktree_is_seeded_like_a_workspace(repo):
    (repo / ".gitignore").write_text(".env*\n.npmrc\n")
    (repo / ".haro").mkdir()
    (repo / ".haro" / ".env").write_text("SEED=1\n")
    (repo / ".npmrc").write_text("//registry/:_authToken=x\n")
    (repo / ".haro" / "settings.toml").write_text('[files]\ninclude = [".npmrc"]\n')
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "config")
    seen = {}

    class Peek(StubAdapter):
        async def run(self, *, cwd, **kw):
            seen["env"] = (Path(cwd) / ".env").read_text()
            seen["npmrc"] = (Path(cwd) / ".npmrc").read_text()
            return await super().run(cwd=cwd, **kw)

    _drive(repo, Peek())
    assert seen == {"env": "SEED=1\n", "npmrc": "//registry/:_authToken=x\n"}


def test_the_runner_comes_from_the_default_branchs_committed_config(repo):
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text('[gate]\nrunner = "pytest"\n')
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "gate")
    seen = []

    def factory(root):
        seen.append((root, load_project_settings(root).gate_runner))
        return StubAdapter()

    project = _project(repo)
    store, hub = Store(), Hub()
    run(baseline.run_baseline(store=store, hub=hub, project=project, adapter_for=factory))
    root, runner = seen[0]
    assert runner == "pytest"
    assert Path(root).resolve() != repo.resolve()


def test_a_configured_setup_script_is_not_run_and_the_result_says_so(repo):
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text('[scripts]\nsetup = "npm ci"\n')
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "setup")
    result, _p, _e = _drive(repo, StubAdapter())
    assert "setup script was not run" in result.note
    _git(repo, "rm", "-q", ".haro/settings.toml")
    _git(repo, "commit", "-qm", "drop")
    again, _p, _e = _drive(repo, StubAdapter())
    assert again.note is None


def test_stale_baseline_worktrees_from_a_killed_run_are_swept(repo, tmp_path):
    stale_parent = tmp_path / (baseline.TMP_PREFIX + "dead")
    stale = stale_parent / "wt"
    run(git_ops.add_detached_worktree(str(repo), str(stale), "main"))
    assert len(_worktrees(repo)) == 2
    _drive(repo, StubAdapter())
    assert len(_worktrees(repo)) == 1
    assert not stale_parent.exists()


def test_the_adopt_scan_ignores_baseline_worktrees(repo, tmp_path):
    stale = tmp_path / (baseline.TMP_PREFIX + "live") / "wt"
    run(git_ops.add_detached_worktree(str(repo), str(stale), "main"))
    other = tmp_path / "foreign" / "wt"
    run(git_ops.add_worktree(str(repo), other, "foreign-branch", "main"))
    project = _project(repo)
    rows = run(main._scan_foreign_worktrees(project))
    paths = [Path(r["path"]).resolve() for r in rows]
    assert other.resolve() in paths
    assert stale.resolve() not in paths


def test_dirty_checkout_uses_a_temp_worktree_and_leaves_the_checkout_alone(repo):
    (repo / "a.txt").write_text("edited\n")
    (repo / "scratch.txt").write_text("untracked\n")
    adapter = StubAdapter()
    result, _project_, _events = _drive(repo, adapter)
    assert result.status == "passed"
    assert Path(adapter.cwd).resolve() != repo.resolve()
    assert adapter.existed
    assert not Path(adapter.cwd).exists()
    assert not Path(adapter.cwd).parent.exists()
    assert len(_worktrees(repo)) == 1
    assert (repo / "a.txt").read_text() == "edited\n"
    assert (repo / "scratch.txt").exists()


def test_other_branch_checked_out_tests_the_default_branch(repo):
    _git(repo, "checkout", "-q", "-b", "feature")
    (repo / "a.txt").write_text("feature change\n")
    _git(repo, "commit", "-qam", "feature")
    seen = {}

    class Peek(StubAdapter):
        async def run(self, *, cwd, **kw):
            seen["content"] = (Path(cwd) / "a.txt").read_text()
            return await super().run(cwd=cwd, **kw)

    result, _p, _e = _drive(repo, Peek())
    assert seen["content"] == "one\n"
    assert _git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip() == "feature"
    assert result.sha == _git(repo, "rev-parse", "main").strip()
    assert len(_worktrees(repo)) == 1


def test_temp_worktree_is_removed_even_when_the_runner_crashes(repo):
    (repo / "a.txt").write_text("edited\n")
    adapter = StubAdapter(raises=RuntimeError("boom"))
    result, project, events = _drive(repo, adapter)
    assert result.status == "error" and "boom" in (result.error or "")
    assert adapter.existed and not Path(adapter.cwd).exists()
    assert len(_worktrees(repo)) == 1
    assert project.baseline.status == "error"
    assert events[-1]["kind"] == "error"


def test_temp_worktree_is_removed_when_the_run_is_cancelled(repo):
    (repo / "a.txt").write_text("edited\n")
    gate = asyncio.Event()
    adapter = StubAdapter(gate=gate)
    project = _project(repo)

    hub = Hub()
    events = []

    async def go():
        q = hub.subscribe_global()
        task = asyncio.create_task(baseline.run_baseline(
            store=Store(), hub=hub, project=project, adapter_for=lambda _p: adapter))
        while not adapter.calls:
            await asyncio.sleep(0.01)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        while not q.empty():
            events.append(q.get_nowait())

    run(go())
    assert not Path(adapter.cwd).exists()
    assert len(_worktrees(repo)) == 1
    assert project.baseline is None
    assert events[-1]["kind"] == "error"
    assert events[-1]["message"] == "baseline stopped"
    assert events[-1]["result"] is None


def test_failed_lists_at_most_twenty_ids(repo):
    cases = [CaseResult("t.py", f"n{i}", "failed") for i in range(25)]
    adapter = StubAdapter(RunResult(ok=False, total=25, failed=25, cases=cases))
    result, _p, events = _drive(repo, adapter)
    assert result.status == "failed" and result.failed == 25
    assert len(result.failing_ids) == 20 and result.failing_ids[0] == "t.py::n0"
    assert events[-1]["kind"] == "done"


def test_failed_without_a_failing_case_says_why(repo):
    adapter = StubAdapter(RunResult(ok=False, total=4, passed=4, cases=[CaseResult("t.py", "a", "passed")]))
    result, _p, _e = _drive(repo, adapter)
    assert result.status == "failed" and result.failed == 0 and result.failing_ids == []
    assert "no failing test case" in result.error


def test_no_tests_is_its_own_status(repo):
    adapter = StubAdapter(RunResult(ok=False, error="no tests found"))
    result, _p, _e = _drive(repo, adapter)
    assert result.status == "no_tests" and result.total == 0


def test_a_runner_that_could_not_start_is_an_error(repo):
    adapter = StubAdapter(RunResult(ok=False, error="`python`/`pytest` not found: add pytest."))
    result, _p, _e = _drive(repo, adapter)
    assert result.status == "error" and "pytest" in result.error


def test_unknown_default_branch_is_an_error_not_a_crash(repo):
    project = _project(repo)
    project.default_branch = "nope"
    adapter = StubAdapter()
    result, _p, _e = _drive(repo, adapter, project)
    assert result.status == "error" and adapter.calls == 0
    assert len(_worktrees(repo)) == 1


def test_coverage_is_measured_only_for_a_green_vitest_run(repo):
    class Vitest(StubAdapter):
        name = "vitest"

        async def coverage(self, *, cwd):
            return {"lines": 81.234, "statements": 80, "functions": 70, "branches": 60}

    result, _p, _e = _drive(repo, Vitest())
    assert result.coverage_pct == 81.23

    red = Vitest(RunResult(ok=False, total=1, failed=1, cases=[CaseResult("a", "b", "failed")]))
    result, _p, _e = _drive(repo, red)
    assert result.coverage_pct is None

    class NoCoverage(Vitest):
        async def coverage(self, *, cwd):
            return None

    result, _p, _e = _drive(repo, NoCoverage())
    assert result.status == "passed" and result.coverage_pct is None


def test_the_result_persists_on_the_project_and_old_rows_still_load(repo):
    result, project, _e = _drive(repo, StubAdapter())
    back = Project.model_validate_json(project.model_dump_json())
    assert back.baseline == result
    legacy = project.model_dump()
    legacy.pop("baseline")
    assert Project.model_validate(legacy).baseline is None


@pytest.fixture
def routed(repo, monkeypatch):
    project = _project(repo)
    main.store.add_project(project)
    saved = []

    async def fake_save(store):
        saved.append(store)

    monkeypatch.setattr(main.db, "save_snapshot", fake_save)
    yield project, saved
    task = main.store.baseline_tasks.pop(project.id, None)
    if task and not task.done():
        task.cancel()
    main.store.remove_project(project.id)


def test_route_runs_in_background_persists_and_refuses_a_second_run(routed, monkeypatch):
    project, saved = routed
    gate = asyncio.Event()
    adapter = StubAdapter(gate=gate)
    monkeypatch.setattr(main, "_test_adapter", lambda _p: adapter)

    async def go():
        assert main.store.baseline_running(project.id) is False
        state = await main.get_baseline(project.id)
        assert (state.running, state.result) == (False, None)
        assert state.head_sha

        first = await main.run_project_baseline(project.id)
        assert first.running is True and first.result is None
        while not adapter.calls:
            await asyncio.sleep(0.01)
        assert (await main.get_baseline(project.id)).running is True
        with pytest.raises(HTTPException) as exc:
            await main.run_project_baseline(project.id)
        assert exc.value.status_code == 409

        gate.set()
        await main.store.baseline_tasks[project.id]
        done = await main.get_baseline(project.id)
        assert done.running is False and done.result.status == "passed"

        again = await main.run_project_baseline(project.id)
        assert again.result.status == "passed"
        await main.store.baseline_tasks[project.id]

    run(go())
    assert saved, "the finished run must be snapshotted"
    assert adapter.calls == 2


def test_route_404s_for_an_unknown_project():
    for fn in (main.get_baseline, main.run_project_baseline):
        with pytest.raises(HTTPException) as exc:
            run(fn("proj_missing"))
        assert exc.value.status_code == 404


def test_baseline_never_touches_a_workspace_or_a_test_run(repo):
    store, hub = Store(), Hub()
    project = _project(repo)
    store.projects[project.id] = project
    run(baseline.run_baseline(store=store, hub=hub, project=project, adapter_for=lambda _p: StubAdapter()))
    assert not store.workspaces and not store.tests
    assert isinstance(project.baseline, BaselineResult)


def test_a_baseline_on_the_same_repo_never_sweeps_another_live_one(repo):
    """Git lists every worktree of the repo from any project path on it (a monorepo
    subfolder here), so the sweep must skip dirs that are live, not projects that are."""
    (Path(repo) / "sub").mkdir()
    (Path(repo) / "sub" / "a.txt").write_text("x")
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "sub")

    class Slow:
        name = "command"

        async def run(self, *, cwd, emit=None, **_k):
            await asyncio.sleep(1.0)
            alive = Path(cwd).exists()
            return RunResult(
                ok=alive, passed=1 if alive else 0, failed=0 if alive else 1, total=1,
                error=None if alive else f"cwd vanished {cwd}",
            )

    class Fast(Slow):
        async def run(self, *, cwd, emit=None, **_k):
            return RunResult(ok=True, passed=1, total=1)

    async def go():
        store, hub = Store(), Hub()
        a = Project(id="A", name="a", path=str(repo), default_branch="main")
        b = Project(id="B", name="b", path=str(Path(repo) / "sub"), default_branch="main")
        store.projects = {"A": a, "B": b}
        ta = asyncio.create_task(
            baseline.run_baseline(store=store, hub=hub, project=a, adapter_for=lambda _p: Slow())
        )
        await asyncio.sleep(0.4)
        rb = await baseline.run_baseline(store=store, hub=hub, project=b, adapter_for=lambda _p: Fast())
        return await ta, rb

    ra, rb = run(go())
    assert ra.status == "passed", ra.error
    assert rb.status == "passed"
    assert not [w for w in _worktrees(repo) if baseline.TMP_PREFIX in w]


def test_a_dir_owned_by_another_live_process_is_not_swept(repo, tmp_path):
    parent = Path(tempfile.mkdtemp(prefix=baseline.TMP_PREFIX))
    wt = parent / "wt"
    run(git_ops.add_detached_worktree(str(repo), str(wt), "main"))
    (parent / baseline.OWNER_FILE).write_text(str(os.getppid()))  # a live process, not us
    run(baseline.sweep_stale(_project(repo)))
    assert wt.exists()
    (parent / baseline.OWNER_FILE).write_text("999999")  # a dead pid
    run(baseline.sweep_stale(_project(repo)))
    assert not wt.exists()


def test_a_missing_project_folder_does_not_crash_the_sweep(tmp_path):
    gone = Project(id="G", name="g", path=str(tmp_path / "gone"), default_branch="main")
    assert run(baseline.sweep_stale(gone)) == []


def _runner_seen(repo):
    seen = []

    def factory(root):
        seen.append(load_project_settings(root).gate_runner)
        return StubAdapter()

    project = _project(repo)
    store, hub = Store(), Hub()
    result = run(baseline.run_baseline(store=store, hub=hub, project=project, adapter_for=factory))
    return seen[0], result


def test_an_untracked_settings_file_decides_the_runner_and_the_note_says_so(repo):
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text('[gate]\nrunner = "pytest"\n')
    runner, result = _runner_seen(repo)
    assert runner == "pytest"
    assert "used your uncommitted .haro/settings.toml" in result.note


def test_an_edited_settings_file_beats_the_committed_one(repo):
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text('[gate]\nrunner = "vitest"\n')
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "gate")
    (repo / ".haro" / "settings.toml").write_text('[gate]\nrunner = "pytest"\n')
    runner, result = _runner_seen(repo)
    assert runner == "pytest"
    assert "uncommitted .haro/settings.toml" in result.note
    assert 'runner = "pytest"' in (repo / ".haro" / "settings.toml").read_text()


def test_a_matching_committed_settings_file_adds_no_note(repo):
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text('[gate]\nrunner = "pytest"\n')
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "gate")
    runner, result = _runner_seen(repo)
    assert runner == "pytest"
    assert result.note is None


def test_no_settings_file_anywhere_adds_no_note(repo):
    _runner, result = _runner_seen(repo)
    assert result.note is None


def test_a_clean_settings_file_committed_on_another_branch_loses_to_main(repo):
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text(
        '[gate]\nrunner = "command"\ncommand = "true"\n'
    )
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "main gate")
    _git(repo, "checkout", "-q", "-b", "feat")
    (repo / ".haro" / "settings.toml").write_text(
        '[gate]\nrunner = "command"\ncommand = "false"\n'
    )
    _git(repo, "commit", "-qam", "feat gate")
    assert _git(repo, "status", "--porcelain").strip() == ""
    seen = []

    def factory(root):
        seen.append(load_project_settings(root).gate_command)
        return StubAdapter()

    project = _project(repo)
    result = run(
        baseline.run_baseline(store=Store(), hub=Hub(), project=project, adapter_for=factory)
    )
    assert seen == ["true"]
    assert result.note is None
