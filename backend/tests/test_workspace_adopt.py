"""Route-level tests for the Merge Firewall adopt endpoint,
``POST /projects/{project_id}/workspaces/adopt`` (backlog/merge-firewall.md §1).

The adopt path is ``create_workspace`` minus ``git_ops.add_worktree``: the
worktree already exists on disk, so the endpoint only registers it. These tests
cover the HTTP seam — that a genuinely foreign worktree is adopted (branch/base
derived from git, port allocated, snapshotted) and that governed / non-foreign /
detached paths are refused.

No httpx/pytest-asyncio in the gate env, so we drive the async handler directly
with ``asyncio.run`` against the module-level ``store`` singleton (the pattern the
other route tests use).
"""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import git_ops, main
from haro.models import AdoptWorkspaceRequest, Project, Workspace, WorkspaceStatus
from haro.store import SETUP_SESSION


def run(coro):
    return asyncio.run(coro)


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


@pytest.fixture
def setup_spy(monkeypatch):
    """Stub ``run_setup`` so tests exercise the adopt *wiring* (provisioning is
    scheduled, status flips to setting_up) without spawning real setup subprocesses
    or leaving a dangling task under ``asyncio.run``. Records each call's kwargs."""
    calls: list[dict] = []

    async def _spy(*, store, hub, workspace, project, psettings):
        calls.append({"workspace": workspace, "project": project, "psettings": psettings})

    monkeypatch.setattr(main, "run_setup", _spy)
    return calls


async def _adopt(project_id, req):
    """Call the adopt handler, then drain the SETUP_SESSION task it schedules so no
    task is left pending when ``asyncio.run`` tears the loop down."""
    ws = await main.adopt_workspace(project_id, req)
    task = main.store.active_task(ws.id, SETUP_SESSION)
    if task is not None:
        await task
    return ws


@pytest.fixture
def repo(tmp_path):
    """A real (remote-less) git repo with one commit, registered as a project."""
    path = tmp_path / "repo"
    path.mkdir()
    _run("init", "-b", "main", cwd=path)
    _run("config", "user.email", "t@t", cwd=path)
    _run("config", "user.name", "t", cwd=path)
    (path / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=path)
    _run("commit", "-m", "init", cwd=path)
    proj = Project(name="demo", path=str(path), default_branch="main")
    main.store.add_project(proj)
    yield proj
    main.store.remove_project(proj.id)


def test_adopt_registers_foreign_worktree(tmp_path, repo, setup_spy):
    foreign = tmp_path / "elsewhere" / "foreign"
    run(git_ops.add_worktree(repo.path, foreign, "someones-branch", "main"))

    ws = run(_adopt(repo.id, AdoptWorkspaceRequest(path=str(foreign))))

    assert ws.branch == "someones-branch"
    assert git_ops._norm_path(ws.worktree_path) == git_ops._norm_path(str(foreign))
    # No remote → base is the local default branch.
    assert ws.base_ref == "main"
    assert ws.port is not None
    # Default (unnamed) → display name falls back to the branch.
    assert ws.name == "someones-branch"
    # Provisioning runs the create path: the workspace is born setting_up (flips to
    # idle when run_setup finishes) — see test_adopt_runs_create_path_provisioning.
    assert ws.status == WorkspaceStatus.setting_up
    # Adopted worktrees are marked so the UI can hide the ① agent step (they're agentless).
    assert ws.kind == "adopted"
    # It's now in the store, and re-scanning no longer surfaces it as foreign.
    assert ws.id in {w.id for w in main.store.list_workspaces(repo.id)}
    scan = run(main.list_foreign_worktrees(repo.id))
    assert "someones-branch" not in {w["branch"] for w in scan["worktrees"]}


def test_adopt_custom_name(tmp_path, repo, setup_spy):
    foreign = tmp_path / "elsewhere" / "named"
    run(git_ops.add_worktree(repo.path, foreign, "feat-x", "main"))
    ws = run(_adopt(
        repo.id, AdoptWorkspaceRequest(path=str(foreign), name="Legacy work")
    ))
    assert ws.name == "Legacy work"
    assert ws.branch == "feat-x"


def test_adopt_runs_create_path_provisioning(tmp_path, repo, setup_spy):
    """§2 (the cry-wolf fix): adopt seeds the worktree env + include globs and
    schedules run_setup under SETUP_SESSION, exactly like create_workspace."""
    # A `.haro/.env` seed + a gitignored include file the default `.env*` glob matches.
    root = Path(repo.path)
    (root / ".haro").mkdir()
    (root / ".haro" / ".env").write_text("SECRET=1\n")
    (root / ".env.local").write_text("LOCAL=1\n")

    foreign = tmp_path / "elsewhere" / "prov"
    run(git_ops.add_worktree(repo.path, foreign, "prov-branch", "main"))

    ws = run(_adopt(repo.id, AdoptWorkspaceRequest(path=str(foreign))))

    # seed_worktree_env copied `.haro/.env` → `<worktree>/.env`.
    assert (foreign / ".env").read_text() == "SECRET=1\n"
    # copy_worktree_includes copied the `.env*`-matched gitignored file.
    assert (foreign / ".env.local").read_text() == "LOCAL=1\n"
    # run_setup was scheduled under SETUP_SESSION with this workspace + its settings.
    assert len(setup_spy) == 1
    assert setup_spy[0]["workspace"].id == ws.id
    assert setup_spy[0]["project"].id == repo.id


def test_adopt_never_clobbers_foreign_env(tmp_path, repo, setup_spy):
    """A foreign worktree may already carry its own gitignored files — the non-clobber
    seed must leave them intact (respect the foreign tool's environment, § line 44)."""
    root = Path(repo.path)
    (root / ".haro").mkdir()
    (root / ".haro" / ".env").write_text("SECRET=from-project\n")

    foreign = tmp_path / "elsewhere" / "own-env"
    run(git_ops.add_worktree(repo.path, foreign, "own-env-branch", "main"))
    (foreign / ".env").write_text("SECRET=from-foreign-tool\n")

    run(_adopt(repo.id, AdoptWorkspaceRequest(path=str(foreign))))

    assert (foreign / ".env").read_text() == "SECRET=from-foreign-tool\n"


def test_adopt_never_clobbers_foreign_node_modules(tmp_path, repo, monkeypatch):
    """Respect the foreign tool's own install (§ line 60): if an adopted worktree
    already carries a real node_modules, the fallback provisioning must NOT replace
    it with the project-root symlink stopgap.

    Drives the *real* deps fallback (no setup_spy, no `[scripts] setup`) so this
    exercises `run_setup` → `_provision_deps` → `ensure_deps` end-to-end.
    """
    # A project install exists (so the stopgap *would* have something to symlink)…
    (Path(repo.path) / "node_modules" / "vitest").mkdir(parents=True)

    foreign = tmp_path / "elsewhere" / "own-deps"
    run(git_ops.add_worktree(repo.path, foreign, "own-deps-branch", "main"))
    # …but the foreign worktree brought its own real install.
    (foreign / "node_modules" / "left-pad").mkdir(parents=True)

    run(_adopt(repo.id, AdoptWorkspaceRequest(path=str(foreign))))

    nm = foreign / "node_modules"
    assert not nm.is_symlink(), "foreign install was clobbered by the symlink stopgap"
    assert (nm / "left-pad").exists()


def test_adopt_404_unknown_project(tmp_path):
    with pytest.raises(HTTPException) as exc:
        run(main.adopt_workspace("nope", AdoptWorkspaceRequest(path=str(tmp_path))))
    assert exc.value.status_code == 404


def test_adopt_404_no_worktree_at_path(tmp_path, repo):
    with pytest.raises(HTTPException) as exc:
        run(main.adopt_workspace(
            repo.id, AdoptWorkspaceRequest(path=str(tmp_path / "ghost"))
        ))
    assert exc.value.status_code == 404


def test_adopt_409_already_tracked(tmp_path, repo):
    managed = tmp_path / "worktrees" / "managed"
    run(git_ops.add_worktree(repo.path, managed, "haro/managed", "main"))
    main.store.add_workspace(Workspace(
        project_id=repo.id, name="managed", branch="haro/managed",
        worktree_path=str(managed), base_ref="main",
    ))
    with pytest.raises(HTTPException) as exc:
        run(main.adopt_workspace(repo.id, AdoptWorkspaceRequest(path=str(managed))))
    assert exc.value.status_code == 409


def test_adopt_400_main_checkout(repo):
    with pytest.raises(HTTPException) as exc:
        run(main.adopt_workspace(repo.id, AdoptWorkspaceRequest(path=repo.path)))
    assert exc.value.status_code == 400


def test_adopt_400_detached(tmp_path, repo):
    detached = tmp_path / "elsewhere" / "detached"
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo.path, check=True, capture_output=True, text=True
    ).stdout.strip()
    _run("worktree", "add", "--detach", str(detached), head, cwd=repo.path)
    with pytest.raises(HTTPException) as exc:
        run(main.adopt_workspace(repo.id, AdoptWorkspaceRequest(path=str(detached))))
    assert exc.value.status_code == 400
