"""git_panel.comment_pr — the Gate Receipt's PR-comment sink (receipt.py,
usp-critique-plan.md idea 1). Zero coverage on this path was flagged in review: the
error-string matching that tells "no PR yet" apart from any other gh failure is the
one thing here that a future `gh` CLI version could silently break.
"""

from __future__ import annotations

import asyncio
import subprocess

import pytest

from haro import git_panel
from haro.git_ops import GitError

GONE = "/tmp/haro-does-not-exist-ever/comment-pr-wt"


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo_with_remote(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    # A fake URL is enough — `has_remote` only checks `git remote` isn't empty, it
    # never has to actually reach it.
    _run("remote", "add", "origin", "https://example.invalid/repo.git", cwd=repo)
    return repo


def test_comment_pr_refuses_on_a_missing_worktree():
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.comment_pr(GONE, "feat/x", "body"))
    assert "no worktree" in e.value.stderr


def test_comment_pr_refuses_with_no_remote(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.comment_pr(str(repo), "feat/x", "body"))
    assert "no git remote" in e.value.stderr


def test_comment_pr_names_the_fix_when_no_pr_exists_yet(tmp_path, monkeypatch):
    repo = _repo_with_remote(tmp_path)

    async def fake_gh(*args, cwd):
        return 1, "", "no pull requests found for branch \"feat\""

    monkeypatch.setattr(git_panel, "_gh", fake_gh)
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.comment_pr(str(repo), "feat", "the receipt body"))
    assert "no open PR" in e.value.stderr
    assert "open one first" in e.value.stderr


def test_comment_pr_surfaces_other_gh_failures_verbatim(tmp_path, monkeypatch):
    repo = _repo_with_remote(tmp_path)

    async def fake_gh(*args, cwd):
        return 1, "", "HTTP 401: Bad credentials"

    monkeypatch.setattr(git_panel, "_gh", fake_gh)
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.comment_pr(str(repo), "feat", "the receipt body"))
    assert "Bad credentials" in e.value.stderr
    assert "no open PR" not in e.value.stderr


def test_comment_pr_posts_successfully(tmp_path, monkeypatch):
    repo = _repo_with_remote(tmp_path)
    seen = {}

    async def fake_gh(*args, cwd):
        seen["args"] = args
        return 0, "https://github.com/o/r/pull/1#issuecomment-1", ""

    monkeypatch.setattr(git_panel, "_gh", fake_gh)
    result = asyncio.run(git_panel.comment_pr(str(repo), "feat", "the receipt body"))
    assert result == {"posted": True, "url": "https://github.com/o/r/pull/1#issuecomment-1"}
    assert seen["args"] == ("pr", "comment", "feat", "--body", "the receipt body")


def test_comment_pr_missing_gh_cli(tmp_path, monkeypatch):
    repo = _repo_with_remote(tmp_path)

    async def fake_gh(*args, cwd):
        return 127, "", "`gh` CLI not found"

    monkeypatch.setattr(git_panel, "_gh", fake_gh)
    with pytest.raises(GitError) as e:
        asyncio.run(git_panel.comment_pr(str(repo), "feat", "body"))
    assert "gh" in e.value.stderr.lower()
