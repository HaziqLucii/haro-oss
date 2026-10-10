"""Automatic checkout sync (project_sync): fast-forward only, never anything else.

Real git repos: a bare ``origin``, a ``clone`` that plays the project's main checkout, and a
``peer`` clone that pushes the commits that make the checkout fall behind.
"""

from __future__ import annotations

import asyncio
import subprocess
from types import SimpleNamespace

import pytest

from haro import project_sync


def run(coro):
    return asyncio.run(coro)


def git(cwd, *args):
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=cwd, check=True, capture_output=True,
    )


@pytest.fixture
def repos(tmp_path):
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    seed = tmp_path / "seed"
    subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True, capture_output=True)
    git(seed, "checkout", "-q", "-b", "main")
    (seed / "todo.md").write_text("- [ ] one\n")
    git(seed, "add", "-A")
    git(seed, "commit", "-q", "-m", "init")
    git(seed, "push", "-q", "origin", "main")
    clone = tmp_path / "clone"
    peer = tmp_path / "peer"
    for d in (clone, peer):
        subprocess.run(["git", "clone", "-q", str(origin), str(d)], check=True, capture_output=True)
    project = SimpleNamespace(
        id=f"p_{tmp_path.name}", path=str(clone), default_branch="main", pull_branch=""
    )
    return SimpleNamespace(project=project, clone=clone, peer=peer, origin=origin)


def peer_push(r, name="todo.md", text="- [x] one\n"):
    (r.peer / name).write_text(text)
    git(r.peer, "add", "-A")
    git(r.peer, "commit", "-q", "-m", f"edit {name}")
    git(r.peer, "push", "-q", "origin", "main")


def test_up_to_date_changes_nothing(repos):
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.UP_TO_DATE and out["behind"] == 0


def test_fast_forwards_a_clean_checkout_on_the_default_branch(repos):
    peer_push(repos)
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.PULLED and out["pulled"] == 1
    assert (repos.clone / "todo.md").read_text() == "- [x] one\n"
    assert project_sync.last[repos.project.id]["state"] == project_sync.PULLED


def test_untracked_files_do_not_block_the_sync(repos):
    (repos.clone / ".haro").mkdir()
    (repos.clone / ".haro" / "instructions.md").write_text("mine\n")
    peer_push(repos)
    assert run(project_sync.sync_project(repos.project))["state"] == project_sync.PULLED
    assert (repos.clone / ".haro" / "instructions.md").read_text() == "mine\n"


def test_another_branch_is_described_never_switched(repos):
    git(repos.clone, "checkout", "-q", "-b", "docs/x")
    peer_push(repos)
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.OTHER_BRANCH
    assert out["branch"] == "docs/x" and out["behind"] == 1
    branch = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repos.clone, capture_output=True, text=True
    ).stdout.strip()
    assert branch == "docs/x"
    assert (repos.clone / "todo.md").read_text() == "- [ ] one\n"


def test_tracked_changes_block_the_sync(repos):
    (repos.clone / "todo.md").write_text("- [ ] one\nlocal edit\n")
    peer_push(repos, name="other.md", text="x\n")
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.DIRTY
    assert (repos.clone / "todo.md").read_text() == "- [ ] one\nlocal edit\n"


def test_a_diverged_main_is_reported_not_merged(repos):
    (repos.clone / "mine.md").write_text("mine\n")
    git(repos.clone, "add", "-A")
    git(repos.clone, "commit", "-q", "-m", "local only")
    peer_push(repos)
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.DIVERGED
    assert out["ahead"] == 1 and out["behind"] == 1


def test_an_untracked_file_in_the_way_is_named(repos):
    (repos.clone / "new-plan.md").write_text("untracked and mine\n")
    peer_push(repos, name="new-plan.md", text="from origin\n")
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.BLOCKED
    assert "new-plan.md" in out["detail"]
    assert (repos.clone / "new-plan.md").read_text() == "untracked and mine\n"


def test_no_remote_and_unreachable_remote(repos, tmp_path):
    bare = SimpleNamespace(
        id="p_none", path=str(tmp_path / "lonely"), default_branch="main", pull_branch=""
    )
    subprocess.run(["git", "init", "-q", bare.path], check=True)
    assert run(project_sync.sync_project(bare))["state"] == project_sync.NO_REMOTE

    git(repos.clone, "remote", "set-url", "origin", str(tmp_path / "does-not-exist.git"))
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.FETCH_FAILED and out["detail"]


def test_switch_to_default_then_pull(repos):
    git(repos.clone, "checkout", "-q", "-b", "docs/x")
    peer_push(repos)
    out = run(project_sync.switch_to_default(repos.project))
    assert out["state"] == project_sync.PULLED and out["branch"] == "main"
    assert (repos.clone / "todo.md").read_text() == "- [x] one\n"


def test_switch_refuses_with_tracked_changes(repos):
    git(repos.clone, "checkout", "-q", "-b", "docs/x")
    (repos.clone / "todo.md").write_text("edited\n")
    with pytest.raises(ValueError, match="uncommitted"):
        run(project_sync.switch_to_default(repos.project))
    branch = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repos.clone, capture_output=True, text=True
    ).stdout.strip()
    assert branch == "docs/x"


def test_pull_branch_replaces_the_default_branch(repos):
    git(repos.peer, "checkout", "-q", "-b", "release")
    (repos.peer / "todo.md").write_text("- [x] release\n")
    git(repos.peer, "add", "-A")
    git(repos.peer, "commit", "-q", "-m", "release work")
    git(repos.peer, "push", "-q", "origin", "release")
    repos.project.pull_branch = "release"

    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.OTHER_BRANCH and out["default_branch"] == "release"

    git(repos.clone, "fetch", "-q", "origin")
    git(repos.clone, "checkout", "-q", "-b", "release", "origin/release~0")
    git(repos.clone, "reset", "-q", "--hard", "main")
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.PULLED and out["branch"] == "release"
    assert (repos.clone / "todo.md").read_text() == "- [x] release\n"


def test_switch_goes_to_the_pull_branch(repos):
    git(repos.peer, "checkout", "-q", "-b", "release")
    git(repos.peer, "push", "-q", "origin", "release")
    repos.project.pull_branch = "release"
    git(repos.clone, "fetch", "-q", "origin")
    git(repos.clone, "branch", "release", "origin/release")
    out = run(project_sync.switch_to_default(repos.project))
    assert out["branch"] == "release"


def test_routes_exist_and_404_for_unknown_projects():
    from fastapi import HTTPException

    from haro import main

    for call in (main.project_sync_status, main.project_sync_now, main.project_sync_switch):
        with pytest.raises(HTTPException) as e:
            run(call("proj_missing"))
        assert e.value.status_code == 404


def test_a_branch_origin_does_not_have_is_named_not_called_unreachable(repos):
    repos.project.pull_branch = "releas"
    out = run(project_sync.sync_project(repos.project))
    assert out["state"] == project_sync.BRANCH_MISSING
    assert "releas" in out["detail"]


def test_a_result_for_a_branch_no_longer_followed_is_not_kept(repos):
    project_sync.last.pop(repos.project.id, None)
    real = project_sync._sync

    async def slow(project):
        out = await real(project)
        project.pull_branch = "other"
        return out

    project_sync._sync = slow
    try:
        run(project_sync.sync_project(repos.project))
    finally:
        project_sync._sync = real
    assert repos.project.id not in project_sync.last


def test_only_projects_with_a_remote_and_auto_pull_on_sync_by_themselves(monkeypatch):
    from haro import main
    from haro.models import Project

    proj = Project(name="p", path="/x", default_branch="main", remote_url="git@h:o/r.git")
    main.store.add_project(proj)
    try:
        started = []
        monkeypatch.setattr(main, "_detach", lambda coro: (started.append(1), coro.close()))

        main._kick_project_sync(proj.id)
        assert started == [1]

        proj.auto_pull = False
        main._kick_project_sync(proj.id)
        assert started == [1]
        assert main._auto_pulls(proj) is False

        proj.auto_pull, proj.remote_url = True, None
        assert main._auto_pulls(proj) is False
    finally:
        main.store.projects.pop(proj.id, None)
