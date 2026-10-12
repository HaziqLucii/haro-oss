"""Changes panel: stage / unstage paths and commit only the index.

Real git in a tmp repo. The load-bearing cases: an unstage keeps the file's edits, a commit with
``staged_only`` leaves the unstaged file uncommitted (the checkbox means something), and a path
that climbs out of the worktree never reaches git.
"""

from __future__ import annotations

import asyncio
import subprocess

import pytest
from fastapi import HTTPException

from haro import git_panel, main
from haro.models import CommitRequest, Project, StagePathsRequest, Workspace
from haro.store import Store


def _git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()


@pytest.fixture
def wired(monkeypatch, tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.com")
    _git(repo, "config", "user.name", "t")
    (repo / "a.txt").write_text("a\n")
    (repo / "b.txt").write_text("b\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "init")
    store = Store()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id="p", name="w", branch="main", worktree_path=str(repo), base_ref="main"
    )
    store.workspaces[ws.id] = ws
    monkeypatch.setattr(main, "store", store)
    return ws, repo


def _run(coro):
    return asyncio.run(coro)


def _staged(repo) -> list[str]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "-z"],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def test_stage_puts_modified_and_untracked_files_in_the_index(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    (repo / "new.txt").write_text("n\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt", "new.txt"])))
    assert sorted(_staged(repo)) == ["a.txt", "new.txt"]


def test_stage_takes_a_deletion(wired):
    ws, repo = wired
    (repo / "b.txt").unlink()
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["b.txt"])))
    assert _staged(repo) == ["b.txt"]


def test_unstage_keeps_the_edit_in_the_worktree(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt"])))
    _run(main.git_unstage(ws.id, StagePathsRequest(paths=["a.txt"])))
    assert _staged(repo) == []
    assert (repo / "a.txt").read_text() == "a2\n"


def test_unstage_a_new_file_leaves_it_untracked(wired):
    ws, repo = wired
    (repo / "new.txt").write_text("n\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["new.txt"])))
    _run(main.git_unstage(ws.id, StagePathsRequest(paths=["new.txt"])))
    assert _staged(repo) == []
    assert (repo / "new.txt").exists()


def test_status_reports_staged_after_stage(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    (repo / "b.txt").write_text("b2\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt"])))
    out = _run(git_panel.status(str(repo), "main", "main"))
    by_path = {f["path"]: f for f in out["files"]}
    assert by_path["a.txt"]["staged"] is True
    assert by_path["b.txt"]["staged"] is False


def test_commit_staged_only_leaves_the_rest_uncommitted(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    (repo / "b.txt").write_text("b2\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt"])))
    res = _run(main.git_commit(ws.id, CommitRequest(message="only a", staged_only=True)))
    assert res["committed"]
    assert _git(repo, "show", "--name-only", "--format=", "HEAD").splitlines() == ["a.txt"]
    assert "b.txt" in _git(repo, "status", "--porcelain")


def test_commit_staged_only_with_nothing_staged_commits_nothing(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    res = _run(main.git_commit(ws.id, CommitRequest(message="x", staged_only=True)))
    assert res["nothing_to_commit"] is True
    assert _git(repo, "log", "--oneline").count("\n") == 0


def test_commit_default_still_takes_everything(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    (repo / "b.txt").write_text("b2\n")
    _run(main.git_commit(ws.id, CommitRequest(message="all")))
    assert _git(repo, "status", "--porcelain") == ""


@pytest.mark.parametrize("bad", [[], ["  "], ["../outside.txt"], ["a.txt", "/etc/passwd"]])
def test_bad_paths_are_a_400_and_stage_nothing(wired, bad):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    with pytest.raises(HTTPException) as e:
        _run(main.git_stage(ws.id, StagePathsRequest(paths=bad)))
    assert e.value.status_code == 400
    assert _staged(repo) == []


def test_unknown_workspace_is_a_404(wired):
    with pytest.raises(HTTPException) as e:
        _run(main.git_stage("nope", StagePathsRequest(paths=["a.txt"])))
    assert e.value.status_code == 404


def test_a_workspace_with_no_worktree_says_why(wired, tmp_path):
    ws, _ = wired
    ws.worktree_path = str(tmp_path / "gone")
    with pytest.raises(HTTPException) as e:
        _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt"])))
    assert e.value.status_code == 400
    assert "no worktree" in e.value.detail


@pytest.mark.parametrize(
    "name", ["with space.txt", "café.txt", 'quo"te.txt', ":lead.txt", "[br].txt", "*.txt"]
)
def test_odd_names_stage_unstage_and_show_up_unquoted_in_status(wired, name):
    ws, repo = wired
    (repo / name).write_text("n\n")
    (repo / "other.txt").write_text("o\n")
    out = _run(git_panel.status(str(repo), "main", "main"))
    assert name in {f["path"] for f in out["files"]}
    _run(main.git_stage(ws.id, StagePathsRequest(paths=[name])))
    assert _staged(repo) == [name]
    out = _run(git_panel.status(str(repo), "main", "main"))
    assert {f["path"]: f["staged"] for f in out["files"]}[name] is True
    _run(main.git_unstage(ws.id, StagePathsRequest(paths=[name])))
    assert _staged(repo) == []


def test_a_directory_named_colon_is_a_literal_path(wired):
    ws, repo = wired
    (repo / ":").mkdir()
    (repo / ":" / "f.txt").write_text("n\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=[":/f.txt"])))
    assert _staged(repo) == [":/f.txt"]


def test_a_glob_path_stages_only_the_file_with_that_name(wired):
    ws, repo = wired
    (repo / "*.txt").write_text("star\n")
    (repo / "c.txt").write_text("c\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["*.txt"])))
    assert _staged(repo) == ["*.txt"]


def test_status_reads_a_rename_as_new_path_with_the_old_one_attached(wired):
    ws, repo = wired
    _git(repo, "mv", "a.txt", "renamed file.txt")
    out = _run(git_panel.status(str(repo), "main", "main"))
    (f,) = [f for f in out["files"] if f["path"] == "renamed file.txt"]
    assert f["orig_path"] == "a.txt"
    assert f["staged"] is True
    assert [g["path"] for g in out["files"]] == ["renamed file.txt"]


def test_unstaging_a_staged_rename_restores_both_sides(wired):
    ws, repo = wired
    _git(repo, "mv", "a.txt", "moved.txt")
    _run(main.git_unstage(ws.id, StagePathsRequest(paths=["moved.txt"])))
    assert _staged(repo) == []
    assert (repo / "moved.txt").exists() and not (repo / "a.txt").exists()


def test_status_marks_a_partly_staged_file(wired):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt"])))
    (repo / "a.txt").write_text("a3\n")
    (repo / "b.txt").write_text("b2\n")
    out = _run(git_panel.status(str(repo), "main", "main"))
    by_path = {f["path"]: f for f in out["files"]}
    assert by_path["a.txt"]["partial"] is True and by_path["a.txt"]["staged"] is True
    assert by_path["b.txt"]["partial"] is False
    _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt"])))
    out = _run(git_panel.status(str(repo), "main", "main"))
    assert {f["path"]: f for f in out["files"]}["a.txt"]["partial"] is False


@pytest.mark.parametrize("action", ["git_stage", "git_unstage"])
def test_stage_and_unstage_refuse_while_busy(wired, monkeypatch, action):
    ws, repo = wired
    (repo / "a.txt").write_text("a2\n")
    monkeypatch.setattr(main.store, "busy_reason", lambda _id: "the gate")
    with pytest.raises(HTTPException) as e:
        _run(getattr(main, action)(ws.id, StagePathsRequest(paths=["a.txt"])))
    assert e.value.status_code == 409
    assert "the gate" in e.value.detail
    assert _staged(repo) == []


def test_a_merge_conflict_is_flagged_and_refused_by_stage(wired):
    ws, repo = wired
    _git(repo, "checkout", "-qb", "other")
    (repo / "a.txt").write_text("theirs\n")
    _git(repo, "commit", "-qam", "theirs")
    _git(repo, "checkout", "-q", "main")
    (repo / "a.txt").write_text("ours\n")
    _git(repo, "commit", "-qam", "ours")
    subprocess.run(["git", "merge", "-q", "other"], cwd=repo, capture_output=True)
    (repo / "b.txt").write_text("b2\n")
    out = _run(git_panel.status(str(repo), "main", "main"))
    a = {f["path"]: f for f in out["files"]}["a.txt"]
    assert a["conflict"] is True and a["staged"] is False and a["partial"] is False
    with pytest.raises(HTTPException) as err:
        _run(main.git_stage(ws.id, StagePathsRequest(paths=["a.txt", "b.txt"])))
    assert err.value.status_code == 400 and "merge conflict" in err.value.detail
    assert "<<<<<<<" in (repo / "a.txt").read_text()
    assert "b.txt" not in _staged(repo)
