"""Opening a past workspace must not error (the reported bug).

An ARCHIVED or merged workspace keeps its row for history while `remove_worktree` tears the
directory down, so `ws.worktree_path` points at nothing. Every git call then dies with
"fatal: not a git repository", and the four call sites failed in four different ways:

  * `pr_status` raised straight through the endpoint  -> HTTP 500 (what the user hit)
  * `log`       raised straight through the endpoint  -> HTTP 500
  * `commit` / `create_pr` surfaced a cryptic          -> 400 "fatal: not a git repository"
  * `status`    swallowed the GitError and returned ahead/behind/dirty all ZERO

That last one is the worst and the reason these tests assert on `worktree_missing` rather
than just "no exception": a measured-looking zero for something we could not measure is the
same failure the gate's `degraded` signal exists to prevent (backlog/double-gate.md §0).

A husk left by an interrupted `git worktree remove` (directory present, `.git` gone) hits the
identical path, which is why the guard is `git_ops.worktree_valid` rather than `os.path.isdir`.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import git_panel
from haro.git_ops import GitError

GONE = "/tmp/haro-does-not-exist-ever/wt"


def test_worktree_gone_detects_a_missing_path():
    assert git_panel.worktree_gone(GONE) is True


def test_worktree_gone_detects_a_husk(tmp_path):
    """Directory present, `.git` link gone — an interrupted `git worktree remove`. Any git
    command inside still dies, so `isdir` would not have been enough."""
    husk = tmp_path / "husk"
    husk.mkdir()
    assert git_panel.worktree_gone(str(husk)) is True


def test_a_real_repo_is_not_gone(tmp_path):
    """Built on the spot rather than pointing at a checkout that only exists on one
    machine — the first version hardcoded an absolute path and failed the moment CI ran it."""
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    assert git_panel.worktree_gone(str(repo)) is False


# --- reads degrade, and say so --------------------------------------------- #

def test_status_reports_unknown_instead_of_a_measured_looking_zero():
    """It already returned zeros before this fix, silently. Zeros are indistinguishable
    from "clean branch, nothing ahead", which is a lie about an unmeasurable thing."""
    out = asyncio.run(git_panel.status(GONE, "feat/x", "main"))
    assert out["worktree_missing"] is True
    assert out["ahead"] == 0 and out["behind"] == 0 and out["dirty"] == 0
    assert out["branch"] == "feat/x"  # still echoes what we DO know


def test_pr_status_degrades_instead_of_raising():
    """THE reported 500. Reuses the same {supported, reason} shape it already returns for
    no-remote / no-gh, so the frontend needed no new branch."""
    out = asyncio.run(git_panel.pr_status(GONE, "feat/x"))
    assert out["supported"] is False
    assert "no worktree" in out["reason"]
    assert "archived" in out["reason"]  # names the likely cause


def test_log_returns_an_empty_history_instead_of_raising():
    assert asyncio.run(git_panel.log(GONE, "main")) == []


# --- writes refuse loudly, with something actionable ----------------------- #

def test_commit_refuses_with_a_human_message():
    """A write must NOT quietly no-op. It refuses, and the message says why rather than
    'fatal: not a git repository'."""
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.commit(GONE, "some message"))
    assert "no worktree" in e.value.stderr
    assert "not a git repository" not in e.value.stderr


def test_create_pr_refuses_with_a_human_message():
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.create_pr(GONE, "feat/x", "main"))
    assert "no worktree" in e.value.stderr


# --- the endpoints no longer 500 ------------------------------------------- #

def test_the_status_response_model_carries_the_flag():
    """The flag has to survive serialization, or the UI can't tell unknown from clean."""
    from haro.models import GitStatusResponse

    out = asyncio.run(git_panel.status(GONE, "feat/x", "main"))
    resp = GitStatusResponse(**out)
    assert resp.worktree_missing is True
    assert GitStatusResponse(branch="b", base_ref="main").worktree_missing is False


# --- the endpoint layer: the exact two paths that returned 500 -------------- #
# Called directly rather than over HTTP (no httpx in this env, same reason the other
# route tests drive coroutines with asyncio.run). These are the two handlers from the
# reported traceback: main.git_pr -> git_panel.pr_status -> git_ops.has_remote -> boom.

@pytest.fixture
def archived_ws(tmp_path):
    """An archived workspace registered in the module-level store, fully restored after.

    The store is a process-wide singleton, so a leaked row poisons every later test that
    walks it. The first version of these tests cleaned up the workspace but not the
    project, and the project carried a path that happens to exist on the author's machine
    — so `test_worktree_scan.py` inherited a nonexistent repo path and blew up on CI while
    passing locally. Snapshot both dicts and put them back."""
    from haro import main
    from haro.models import Project, Workspace, WorkspaceStatus

    projects = dict(main.store.projects)
    workspaces = dict(main.store.workspaces)

    project = Project(id="p-archived-test", name="proj", path=str(tmp_path), default_branch="main")
    main.store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="an archived workspace", branch="feat/gone",
        worktree_path=GONE, base_ref="main",
    )
    ws.status = WorkspaceStatus.archived
    main.store.workspaces[ws.id] = ws
    try:
        yield ws
    finally:
        main.store.projects.clear()
        main.store.projects.update(projects)
        main.store.workspaces.clear()
        main.store.workspaces.update(workspaces)


def test_git_pr_endpoint_no_longer_raises(archived_ws):
    """The reported bug, at the handler that produced the 500."""
    from haro import main

    resp = asyncio.run(main.git_pr(archived_ws.id))
    assert resp.supported is False
    assert "no worktree" in (resp.reason or "")


def test_git_log_endpoint_no_longer_raises(archived_ws):
    """Same class, one endpoint over — it had no GitError guard at all either."""
    from haro import main

    out = asyncio.run(main.git_log(archived_ws.id))
    assert out["commits"] == []
    assert out["worktree_missing"] is True


def test_git_status_endpoint_flags_unknown(archived_ws):
    from haro import main

    resp = asyncio.run(main.git_status(archived_ws.id))
    assert resp.worktree_missing is True
    assert resp.dirty == 0