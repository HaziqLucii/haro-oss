"""The review queue: agent-written work waiting for the developer, in lines."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import config, main, review_queue
from haro.models import AgentRun, Workspace, WorkspaceStatus


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    )


def _repo(tmp_path: Path, name: str, lines: int) -> Path:
    repo = tmp_path / name
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    (repo / "a.txt").write_text("base\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "base")
    (repo / "b.txt").write_text("x\n" * lines)
    return repo


@pytest.fixture
def made(tmp_path):
    made: list[Workspace] = []

    def make(name, lines, *, status=WorkspaceStatus.gate_green, mode="agent", ran=True, plan=False):
        repo = _repo(tmp_path, name, lines)
        w = Workspace(project_id="p", name=name, branch=name, worktree_path=str(repo), base_ref="main", status=status, mode=mode)
        main.store.add_workspace(w)
        if ran:
            main.store.add_run(AgentRun(workspace_id=w.id, adapter="claude-code", task="t", plan=plan))
        made.append(w)
        return w

    yield make
    for w in made:
        for r in [r for r in main.store.runs.values() if r.workspace_id == w.id]:
            main.store.runs.pop(r.id, None)
        main.store.remove_workspace(w.id)


def queue():
    return asyncio.run(review_queue.build_review_queue(main.store))


def ids(q):
    return {i.workspace_id: i.lines for i in q.workspaces}


def test_counts_lines_of_agent_work_waiting(made):
    a = made("a", 40)
    b = made("b", 10, status=WorkspaceStatus.idle)
    q = queue()
    assert ids(q)[a.id] == 40 and ids(q)[b.id] == 10
    assert q.total_lines >= 50
    assert [i.lines for i in q.workspaces] == sorted((i.lines for i in q.workspaces), reverse=True)


def test_leaves_out_what_is_not_waiting(made):
    running = made("running", 5, status=WorkspaceStatus.agent_running)
    merged = made("merged", 5, status=WorkspaceStatus.merged)
    manual = made("manual", 5, mode="manual")
    no_run = made("norun", 5, ran=False)
    plan_only = made("planonly", 5, plan=True)
    empty = made("empty", 0)
    got = ids(queue())
    for w in (running, merged, manual, no_run, plan_only, empty):
        assert w.id not in got


def test_a_workspace_that_cannot_be_read_is_skipped(made):
    w = made("gone", 5)
    Path(w.worktree_path, ".git").rename(Path(w.worktree_path, ".git-x"))
    assert w.id not in ids(queue())


def test_cap_reads_the_user_global_file(tmp_path, monkeypatch):
    f = tmp_path / "settings.toml"
    monkeypatch.setenv("HARO_USER_CONFIG", str(f))
    assert config.review_cap() == 3
    f.write_text("[agent]\nreview_cap = 5\n")
    assert config.review_cap() == 5
    f.write_text("[agent]\nreview_cap = 0\n")
    assert config.review_cap() == 0
    f.write_text("[agent]\nreview_cap = 'x'\n")
    assert config.review_cap() == 3


def test_endpoint_returns_the_queue(made):
    w = made("ep", 7)
    q = asyncio.run(main.get_review_queue())
    assert ids(q)[w.id] == 7


def test_reading_never_touches_the_index(made):
    w = made("pure", 6)
    repo = Path(w.worktree_path)
    before = subprocess.run(["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True).stdout
    queue()
    after = subprocess.run(["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True).stdout
    assert before == after and "?? b.txt" in after


def test_tracked_edits_and_new_files_both_count(made):
    w = made("mixed", 3)
    repo = Path(w.worktree_path)
    (repo / "a.txt").write_text("changed\nmore\n")
    got = {i.workspace_id: i for i in queue().workspaces}[w.id]
    assert got.files == 2
    assert got.lines == 3 + 2 + 1


def test_a_fresh_read_after_a_status_change_sees_it(made):
    w = made("flip", 4, status=WorkspaceStatus.agent_running)
    assert w.id not in ids(queue())
    w.status = WorkspaceStatus.gate_green
    assert ids(queue())[w.id] == 4
