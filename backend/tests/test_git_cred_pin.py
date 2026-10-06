"""A repo that pins its own credential helper keeps it under haro's network git calls.

haro resets the credential helper list so a stale absolute path in ~/.gitconfig cannot break
push; but a repo-local helper is an explicit choice (pin one GitHub account whatever `gh` has
active), and the reset used to erase it. Pinned repos are now left alone for network commands;
everything else keeps the PATH-relative `gh` helper.
"""

from __future__ import annotations

import asyncio
import subprocess

from haro import git_ops


def run(coro):
    return asyncio.run(coro)


def _repo(path):
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    git_ops._local_cred_cache.clear()
    return str(path)


def _pin(repo):
    pin = "!f() { echo username=pinned; }; f"
    for value in ("", pin):
        subprocess.run(
            ["git", "-C", repo, "config", "--local", "--add", "credential.helper", value], check=True
        )
    git_ops._local_cred_cache.clear()


def test_unpinned_repo_keeps_haros_override(tmp_path):
    repo = _repo(tmp_path)
    assert run(git_ops._pinned_credentials(("fetch", "origin"), repo)) is False


def test_a_repo_local_helper_is_left_in_charge_for_network_commands(tmp_path):
    repo = _repo(tmp_path)
    _pin(repo)
    for cmd in ("fetch", "push", "pull", "ls-remote", "clone"):
        assert run(git_ops._pinned_credentials((cmd, "origin"), repo)) is True, cmd


def test_local_commands_never_pay_for_the_lookup(tmp_path):
    repo = _repo(tmp_path)
    _pin(repo)
    assert run(git_ops._pinned_credentials(("status", "--porcelain"), repo)) is False
    assert run(git_ops._pinned_credentials((), repo)) is False
