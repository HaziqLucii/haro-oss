"""`git_ops.show_file` — the base (committed-at-base_ref) side of the code
editor's per-file working-vs-base diff. Covers the modified / new-file / binary
cases the editor renders differently."""

import asyncio
import subprocess
from pathlib import Path

from haro import git_ops


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "a.txt").write_text("base line\n")
    (repo / "logo.png").write_bytes(b"\x89PNG\r\n\x00\xff\x00binary")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    return repo


def test_show_file_returns_committed_content(tmp_path):
    repo = _repo(tmp_path)
    # working tree edits it, but show_file reports the committed base content.
    (repo / "a.txt").write_text("edited working\n")
    r = asyncio.run(git_ops.show_file(repo, "main", "a.txt"))
    assert r == {"content": "base line\n", "exists": True}


def test_show_file_missing_at_base_is_new_file(tmp_path):
    repo = _repo(tmp_path)
    r = asyncio.run(git_ops.show_file(repo, "main", "brand-new.ts"))
    assert r == {"content": "", "exists": False}


def test_show_file_binary_reports_error(tmp_path):
    repo = _repo(tmp_path)
    r = asyncio.run(git_ops.show_file(repo, "main", "logo.png"))
    assert r["exists"] is True
    assert r["error"] == "binary file"
    assert r["content"] == ""


def test_show_file_resolves_commit_and_parent_refs(tmp_path):
    """The commit-by-commit diff view fetches a file at ``<sha>`` and ``<sha>^`` to
    show one commit's before/after — show_file must resolve those revision refs."""
    repo = _repo(tmp_path)
    (repo / "a.txt").write_text("second commit\n")
    _run("commit", "-am", "second", cwd=repo)
    # HEAD carries the new content; HEAD^ (its parent) the original.
    after = asyncio.run(git_ops.show_file(repo, "HEAD", "a.txt"))
    before = asyncio.run(git_ops.show_file(repo, "HEAD^", "a.txt"))
    assert after == {"content": "second commit\n", "exists": True}
    assert before == {"content": "base line\n", "exists": True}


def test_show_file_parent_of_first_commit_is_new_file(tmp_path):
    """A file added in the very first commit has no parent revision — the ``<sha>^``
    lookup must degrade to the new-file (all-additions) shape, not error."""
    repo = _repo(tmp_path)
    r = asyncio.run(git_ops.show_file(repo, "HEAD^", "a.txt"))
    assert r == {"content": "", "exists": False}
