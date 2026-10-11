"""POST /projects on a repo with no commits: a clear 400, not a 500 from rev-parse HEAD."""

from __future__ import annotations

import asyncio
import subprocess

import pytest
from fastapi import HTTPException

from haro import git_ops, main
from haro.models import CreateProjectRequest
from haro.store import Store


def _git(*args: str) -> None:
    subprocess.run(["git", *args], check=True, capture_output=True)


def _wire(monkeypatch):
    store = Store()
    monkeypatch.setattr(main, "store", store)

    async def _no_save(_store):
        return None

    monkeypatch.setattr(main.db, "save_snapshot", _no_save)
    return store


def test_an_empty_repo_is_refused_with_a_clear_message(tmp_path, monkeypatch):
    store = _wire(monkeypatch)
    repo = tmp_path / "empty"
    _git("init", "-q", "-b", "main", str(repo))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(main.create_project(CreateProjectRequest(path=str(repo))))
    assert exc.value.status_code == 400
    assert "no commits yet" in exc.value.detail
    assert store.projects == {}


def test_a_repo_with_a_commit_is_added(tmp_path, monkeypatch):
    store = _wire(monkeypatch)
    repo = tmp_path / "repo"
    _git("init", "-q", "-b", "trunk", str(repo))
    _git("-C", str(repo), "-c", "user.email=t@example.com", "-c", "user.name=t",
         "commit", "-q", "--allow-empty", "-m", "init")
    project = asyncio.run(main.create_project(CreateProjectRequest(path=str(repo))))
    assert project.default_branch == "trunk"
    assert project.id in store.projects


def test_default_branch_names_the_unborn_branch(tmp_path):
    repo = tmp_path / "unborn"
    _git("init", "-q", "-b", "dev", str(repo))
    assert asyncio.run(git_ops.default_branch(repo)) == "dev"
