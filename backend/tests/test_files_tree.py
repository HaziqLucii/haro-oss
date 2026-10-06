"""`files.build_tree`: git-backed so .gitignore is respected, with the filesystem walk as
the fallback for a non-git directory. Driven with ``asyncio.run`` (no pytest-asyncio in the
gate env), like the other async file tests."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

from haro import files


def _tree(base: Path) -> list[dict]:
    return asyncio.run(files.build_tree(base))


def _paths(nodes: list[dict]) -> set[str]:
    out: set[str] = set()
    for n in nodes:
        out.add(n["path"])
        out |= _paths(n.get("children", []))
    return out


def _git(base: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
        cwd=base, check=True, capture_output=True,
    )


def _repo(tmp_path: Path) -> Path:
    _git(tmp_path, "init", "-q")
    return tmp_path


def test_ignored_files_are_absent(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / ".gitignore").write_text("dist/\n*.log\n")
    (repo / "src").mkdir()
    (repo / "src" / "a.ts").write_text("a")
    (repo / "dist").mkdir()
    (repo / "dist" / "out.js").write_text("x")
    (repo / "debug.log").write_text("x")
    paths = _paths(_tree(repo))
    assert "src/a.ts" in paths and ".gitignore" in paths
    assert not {p for p in paths if p.startswith("dist") or p.endswith(".log")}


def test_untracked_and_tracked_files_appear(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "tracked.txt").write_text("t")
    _git(repo, "add", "tracked.txt")
    _git(repo, "commit", "-q", "-m", "init")
    (repo / "new.txt").write_text("n")
    assert {"tracked.txt", "new.txt"} <= _paths(_tree(repo))


def test_empty_untracked_dir_is_present(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "empty").mkdir()
    (repo / "f.txt").write_text("f")
    tree = _tree(repo)
    node = next(n for n in tree if n["name"] == "empty")
    assert node["dir"] is True and node["children"] == []


def test_deleted_on_disk_tracked_file_is_absent(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "keep.txt").write_text("k")
    (repo / "gone.txt").write_text("g")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", "init")
    (repo / "gone.txt").unlink()
    paths = _paths(_tree(repo))
    assert "keep.txt" in paths and "gone.txt" not in paths


def test_shape_and_ordering_dirs_first_case_insensitive(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "b.txt").write_text("b")
    (repo / "A.txt").write_text("a")
    (repo / "zdir").mkdir()
    (repo / "zdir" / "inner.txt").write_text("i")
    tree = _tree(repo)
    assert [n["name"] for n in tree] == ["zdir", "A.txt", "b.txt"]
    zdir = tree[0]
    assert zdir == {
        "name": "zdir", "path": "zdir", "dir": True,
        "children": [{"name": "inner.txt", "path": "zdir/inner.txt", "dir": False}],
    }
    assert tree[1] == {"name": "A.txt", "path": "A.txt", "dir": False}


def test_ignore_components_are_dropped(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "node_modules").mkdir()
    (repo / "node_modules" / "x.js").write_text("x")
    (repo / "a.txt").write_text("a")
    paths = _paths(_tree(repo))
    assert "a.txt" in paths
    assert not {p for p in paths if "node_modules" in p}


def test_non_git_directory_falls_back_to_walk(tmp_path: Path):
    (tmp_path / ".gitignore").write_text("*.log\n")
    (tmp_path / "x.log").write_text("x")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "y.txt").write_text("y")
    (tmp_path / "node_modules").mkdir()
    paths = _paths(_tree(tmp_path))
    assert paths == {".gitignore", "x.log", "sub", "sub/y.txt"}  # no git, so no gitignore


def test_nested_repo_shows_its_files(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "top.txt").write_text("t")
    inner = repo / "vendor" / "inner"
    inner.mkdir(parents=True)
    _git(inner, "init", "-q")
    (inner / "lib").mkdir()
    (inner / "lib" / "x.ts").write_text("x")
    (inner / "readme.md").write_text("r")
    tree = _tree(repo)
    paths = _paths(tree)
    assert {"vendor/inner", "vendor/inner/lib", "vendor/inner/lib/x.ts", "vendor/inner/readme.md"} <= paths
    assert not any(".git" in p.split("/") for p in paths)
    vendor = next(n for n in tree if n["name"] == "vendor")
    node = vendor["children"][0]
    assert node["dir"] is True and node["children"]
    assert files.read_file(str(repo), "vendor/inner/lib/x.ts")["content"] == "x"


def test_submodule_gitlink_is_a_folder_with_its_files(tmp_path: Path):
    repo = _repo(tmp_path)
    (repo / "top.txt").write_text("t")
    sub = repo / "sub"
    sub.mkdir()
    (sub / "a.ts").write_text("a")
    (sub / "deep").mkdir()
    (sub / "deep" / "b.ts").write_text("b")
    sha = "1" * 40
    _git(repo, "update-index", "--add", "--cacheinfo", f"160000,{sha},sub")
    tree = _tree(repo)
    node = next(n for n in tree if n["name"] == "sub")
    assert node["dir"] is True
    paths = _paths(tree)
    assert {"sub/a.ts", "sub/deep", "sub/deep/b.ts", "top.txt"} <= paths
    assert files.read_file(str(repo), "sub/deep/b.ts")["content"] == "b"
