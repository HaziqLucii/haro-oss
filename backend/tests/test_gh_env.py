"""``gh`` is pinned to the repo's ``origin`` (GH_REPO), not whichever remote it ranks first.

A fork that keeps ``upstream`` for pulls makes ``gh pr create`` aim at the upstream project,
where the pushed branch does not exist ("Head sha can't be blank"). haro pushes to ``origin``,
so every ``gh`` it runs must use ``origin``.
"""

from __future__ import annotations

import asyncio
import subprocess

import pytest

from haro import git_ops, git_panel


def run(coro):
    return asyncio.run(coro)


@pytest.mark.parametrize(
    "url,slug",
    [
        ("https://github.com/acme/widgets.git", "acme/widgets"),
        ("https://github.com/acme/widgets", "acme/widgets"),
        ("https://user@github.com/o/r.git", "o/r"),
        ("git@github.com:o/r.git", "o/r"),
        ("ssh://git@github.com/o/r.git", "o/r"),
        ("https://github.com/o/r.name.git", "o/r.name"),
        ("https://gitlab.com/o/r.git", None),
        ("/some/local/path", None),
        ("", None),
    ],
)
def test_github_slug(url, slug):
    assert git_ops.github_slug(url) == slug


def _repo(tmp_path, **remotes):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    for name, url in remotes.items():
        subprocess.run(["git", "-C", str(tmp_path), "remote", "add", name, url], check=True)
    return str(tmp_path)


def test_gh_env_pins_origin_even_with_an_upstream_remote(tmp_path, monkeypatch):
    monkeypatch.delenv("GH_REPO", raising=False)
    repo = _repo(
        tmp_path,
        origin="https://github.com/acme/widgets.git",
        upstream="https://github.com/activepieces/activepieces.git",
    )
    env = run(git_ops.gh_env(repo))
    assert env is not None and env["GH_REPO"] == "acme/widgets"


def test_gh_env_leaves_gh_alone_without_a_github_origin_or_with_the_users_own(tmp_path, monkeypatch):
    monkeypatch.delenv("GH_REPO", raising=False)
    assert run(git_ops.gh_env(_repo(tmp_path / "a", upstream="https://github.com/o/r.git"))) is None
    assert run(git_ops.gh_env(_repo(tmp_path / "b", origin="https://gitlab.com/o/r.git"))) is None
    assert run(git_ops.gh_env(str(tmp_path / "missing"))) is None
    monkeypatch.setenv("GH_REPO", "mine/chosen")
    assert run(git_ops.gh_env(_repo(tmp_path / "c", origin="https://github.com/o/r.git"))) is None


def test_gh_wrappers_pass_the_pinned_env(tmp_path, monkeypatch):
    monkeypatch.delenv("GH_REPO", raising=False)
    repo = _repo(tmp_path, origin="https://github.com/acme/widgets.git")
    seen: list[dict] = []

    class Proc:
        returncode = 0

        async def communicate(self):
            return b"ok", b""

    real_exec = asyncio.create_subprocess_exec

    async def fake_exec(*args, **kw):
        if args[0] != "gh":  # the git calls that build the env run for real
            return await real_exec(*args, **kw)
        seen.append(kw.get("env"))
        return Proc()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    from haro import integrate, issue_detail, issues

    for mod in (git_panel, integrate, issues, issue_detail):
        run(mod._gh("pr", "view", cwd=repo))
    assert len(seen) == 4
    assert all(e is not None and e["GH_REPO"] == "acme/widgets" for e in seen)
