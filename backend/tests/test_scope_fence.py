"""Scope fence: the pattern matcher, and the snapshot/revert against a real git repo."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import scope_fence
from haro.scope_fence import Fence


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout


def _write(repo: Path, rel: str, text: str) -> None:
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


@pytest.fixture
def repo(tmp_path) -> Path:
    r = tmp_path / "repo"
    r.mkdir()
    _git(r, "init", "-q", "-b", "main")
    _write(r, ".gitignore", "build/\n")
    _write(r, "src/a.ts", "a0\n")
    _write(r, "src/b.ts", "b0\n")
    _write(r, "docs/readme.md", "r0\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    return r


# ---- matcher ---------------------------------------------------------------- #

@pytest.mark.parametrize("patterns,path,expected", [
    (["src/a.ts"], "src/a.ts", True),
    (["src/a.ts"], "src/b.ts", False),
    (["src"], "src/deep/x.ts", True),
    (["src/"], "src/deep/x.ts", True),
    (["src"], "srcs/x.ts", False),
    (["src/**/*.ts"], "src/a.ts", True),
    (["src/**/*.ts"], "src/x/y/z.ts", True),
    (["src/**/*.ts"], "src/a.md", False),
    (["*.md"], "docs/readme.md", True),
    (["*.md"], "readme.md", True),
    (["docs/*"], "docs/readme.md", True),
    (["docs/*"], "docs/sub/x.md", True),
    (["docs/*.md"], "docs/sub/x.md", False),
    (["./src/a.ts", "/docs"], "docs/readme.md", True),
    (["src/[ab].ts"], "src/b.ts", True),
    (["src/[!a].ts"], "src/a.ts", False),
    ([], "src/a.ts", False),
    (["src/**/"], "src/x/y.ts", True),
    (["components/*/"], "components/button/index.ts", True),
    ([".", "docs"], "anything/at/all.ts", True),
    (["/"], "anything/at/all.ts", True),
    (["[^a].ts"], "a.ts", True),
    (["[^a].ts"], "b.ts", False),
    (["*.ts"], "weird\nname.ts", True),
])
def test_fence_allows(patterns, path, expected):
    assert Fence.build(patterns).allows(path) is expected


def test_normalize_drops_blanks_and_duplicates_and_caps_the_list():
    assert scope_fence.normalize([" ./a ", "", "a", "/b/"]) == ["a", "b/"]
    with pytest.raises(scope_fence.ScopeError):
        scope_fence.normalize([f"f{i}" for i in range(scope_fence.MAX_PATTERNS + 1)])


# ---- snapshot and revert ---------------------------------------------------- #

def _run(coro):
    return asyncio.run(coro)


def test_an_untouched_tree_reverts_nothing_and_makes_no_ref(repo):
    before = _run(scope_fence.snapshot_tree(str(repo)))
    res = _run(scope_fence.enforce(str(repo), Fence.build(["src/a.ts"]), before, "run_1"))
    assert res.reverted == [] and res.backup_ref is None
    assert _git(repo, "for-each-ref", "refs/haro/scope/") == ""


def test_out_of_scope_edits_are_reverted_to_the_start_of_the_run_not_to_head(repo):
    # The developer's own uncommitted work, present before the agent starts.
    _write(repo, "src/a.ts", "a-stub\n")
    _write(repo, "docs/readme.md", "r-by-hand\n")
    _git(repo, "add", "docs/readme.md")  # staged on purpose: the index must come out untouched
    staged_before = _git(repo, "diff", "--cached", "--name-only")

    before = _run(scope_fence.snapshot_tree(str(repo)))

    _write(repo, "src/a.ts", "a-by-agent\n")          # in scope: kept
    _write(repo, "src/new.ts", "n\n")                 # in scope? no: only src/a.ts is
    _write(repo, "docs/readme.md", "r-by-agent\n")    # out of scope: back to r-by-hand
    (repo / "src/b.ts").unlink()                      # out of scope delete: restored
    _write(repo, "lib/x.ts", "x\n")                   # out of scope add: removed
    _write(repo, "build/out.js", "ignored\n")         # ignored: never fenced

    res = _run(scope_fence.enforce(str(repo), Fence.build(["src/a.ts"]), before, "run_2"))

    assert (repo / "src/a.ts").read_text() == "a-by-agent\n"
    assert (repo / "docs/readme.md").read_text() == "r-by-hand\n"
    assert (repo / "src/b.ts").read_text() == "b0\n"
    assert not (repo / "lib/x.ts").exists() and not (repo / "lib").exists()
    assert not (repo / "src/new.ts").exists()
    assert (repo / "build/out.js").exists()
    assert res.reverted == ["docs/readme.md", "lib/x.ts", "src/b.ts", "src/new.ts"]
    assert _git(repo, "diff", "--cached", "--name-only") == staged_before


def test_the_reverted_work_is_kept_under_a_backup_ref(repo):
    before = _run(scope_fence.snapshot_tree(str(repo)))
    _write(repo, "docs/readme.md", "r-by-agent\n")
    res = _run(scope_fence.enforce(str(repo), Fence.build(["src"]), before, "run_3"))
    assert res.backup_ref == "refs/haro/scope/run_3"
    assert _git(repo, "show", f"{res.backup_ref}:docs/readme.md") == "r-by-agent\n"
    assert (repo / "docs/readme.md").read_text() == "r0\n"


def test_a_directory_in_the_fence_allows_new_files_under_it(repo):
    before = _run(scope_fence.snapshot_tree(str(repo)))
    _write(repo, "src/deep/new.ts", "n\n")
    res = _run(scope_fence.enforce(str(repo), Fence.build(["src/"]), before, "run_4"))
    assert res.reverted == [] and (repo / "src/deep/new.ts").exists()


def test_a_path_with_glob_characters_is_restored_literally(repo):
    _write(repo, "app/[id]/page.ts", "p0\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "more")
    before = _run(scope_fence.snapshot_tree(str(repo)))
    _write(repo, "app/[id]/page.ts", "p-agent\n")
    res = _run(scope_fence.enforce(str(repo), Fence.build(["src"]), before, "run_5"))
    assert res.reverted == ["app/[id]/page.ts"]
    assert (repo / "app/[id]/page.ts").read_text() == "p0\n"


def test_a_malformed_glob_is_a_scope_error_not_a_crash():
    with pytest.raises(scope_fence.ScopeError):
        Fence.build(["src/[z-a].ts"])


def test_an_added_symlink_is_removed_and_its_target_is_left_alone(repo):
    before = _run(scope_fence.snapshot_tree(str(repo)))
    (repo / "link.ts").symlink_to("src/a.ts")  # added outside the fence, pointing INTO it
    res = _run(scope_fence.enforce(str(repo), Fence.build(["src/a.ts"]), before, "run_s"))
    assert res.reverted == ["link.ts"] and res.failed == []
    assert not (repo / "link.ts").is_symlink() and not (repo / "link.ts").exists()
    assert (repo / "src/a.ts").read_text() == "a0\n"


def test_a_file_replaced_by_a_directory_is_restored(repo):
    before = _run(scope_fence.snapshot_tree(str(repo)))
    (repo / "docs/readme.md").unlink()
    _write(repo, "docs/readme.md/inner.txt", "x\n")
    res = _run(scope_fence.enforce(str(repo), Fence.build(["src"]), before, "run_d"))
    assert res.failed == []
    assert (repo / "docs/readme.md").read_text() == "r0\n"
    assert sorted(res.reverted) == ["docs/readme.md", "docs/readme.md/inner.txt"]


def test_one_path_git_cannot_restore_does_not_stop_the_others(repo, monkeypatch):
    before = _run(scope_fence.snapshot_tree(str(repo)))
    _write(repo, "docs/readme.md", "r-agent\n")
    _write(repo, "src/b.ts", "b-agent\n")
    real = scope_fence.git_ops._git

    async def flaky_git(*args, **kw):
        if "restore" in args and args[-1] == "docs/readme.md":
            raise scope_fence.git_ops.GitError(list(args), 1, "nope")
        return await real(*args, **kw)

    monkeypatch.setattr(scope_fence.git_ops, "_git", flaky_git)
    res = _run(scope_fence.enforce(str(repo), Fence.build(["lib"]), before, "run_f"))
    assert res.failed == ["docs/readme.md"]
    assert res.reverted == ["src/b.ts"]
    assert (repo / "src/b.ts").read_text() == "b0\n"
    assert res.backup_ref == "refs/haro/scope/run_f"
