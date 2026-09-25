"""`main._unique_slug` — the duplicate-title guard for workspace creation.

Two backlog items with the same title slugify to the same string, which used to
collide on both the worktree path (a hard 409) and the ``haro/<slug>`` branch.
``_unique_slug`` bumps ``foo`` → ``foo-2`` → ``foo-3`` across BOTH namespaces so a
same-titled task is picked up as a distinct workspace instead of failing."""

import asyncio
import subprocess
from pathlib import Path

from haro import config, store as store_mod
from haro.main import _unique_slug
from haro.models import Project


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _project(tmp_path: Path) -> Project:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "a.txt").write_text("x\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    return Project(name="proj", path=str(repo), default_branch="main")


def _use_tmp_root(tmp_path, monkeypatch):
    """Point store.worktree_path at an isolated root so dir checks are hermetic."""
    monkeypatch.setattr(config.settings, "worktree_root", str(tmp_path / "wt"))


def test_free_slug_is_unchanged(tmp_path, monkeypatch):
    _use_tmp_root(tmp_path, monkeypatch)
    proj = _project(tmp_path)
    slug, suffix = asyncio.run(_unique_slug(proj, "fix-login"))
    assert (slug, suffix) == ("fix-login", 0)


def test_branch_collision_bumps(tmp_path, monkeypatch):
    _use_tmp_root(tmp_path, monkeypatch)
    proj = _project(tmp_path)
    _run("branch", "haro/fix-login", cwd=proj.path)
    slug, suffix = asyncio.run(_unique_slug(proj, "fix-login"))
    assert (slug, suffix) == ("fix-login-2", 2)


def test_worktree_dir_collision_bumps(tmp_path, monkeypatch):
    _use_tmp_root(tmp_path, monkeypatch)
    proj = _project(tmp_path)
    # A leftover worktree dir (no matching branch) must still force a bump.
    store_mod.store.worktree_path(proj, "fix-login").mkdir(parents=True)
    slug, suffix = asyncio.run(_unique_slug(proj, "fix-login"))
    assert (slug, suffix) == ("fix-login-2", 2)


def test_skips_over_multiple_taken(tmp_path, monkeypatch):
    _use_tmp_root(tmp_path, monkeypatch)
    proj = _project(tmp_path)
    _run("branch", "haro/fix-login", cwd=proj.path)
    store_mod.store.worktree_path(proj, "fix-login-2").mkdir(parents=True)
    slug, suffix = asyncio.run(_unique_slug(proj, "fix-login"))
    assert (slug, suffix) == ("fix-login-3", 3)
