"""Pull requests are only offered where ``gh`` can open one: a non-GitHub remote says so."""

from __future__ import annotations

import asyncio

import pytest

from haro import git_ops, git_panel


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def gitlab_remote(monkeypatch, tmp_path):
    async def yes(path):
        return True

    async def no(path):
        return False

    monkeypatch.setattr(git_ops, "has_remote", yes)
    monkeypatch.setattr(git_ops, "gh_remote", no)
    monkeypatch.setattr(git_panel, "worktree_gone", lambda p: False)
    return str(tmp_path)


def test_pr_status_says_why_there_is_no_pr_support(gitlab_remote):
    out = run(git_panel.pr_status(gitlab_remote, "feat"))
    assert out["supported"] is False
    assert "not on GitHub" in out["reason"]
    assert "Merge into main" in out["reason"]


def test_creating_a_pr_is_refused_with_the_same_reason(gitlab_remote):
    with pytest.raises(git_ops.GitError) as e:
        run(git_panel.create_pr(gitlab_remote, "feat", "origin/main"))
    assert "not on GitHub" in e.value.stderr


def test_a_pr_comment_is_refused_with_the_same_reason(gitlab_remote):
    with pytest.raises(git_ops.GitError) as e:
        run(git_panel.comment_pr(gitlab_remote, "feat", "hello"))
    assert "not on GitHub" in e.value.stderr
