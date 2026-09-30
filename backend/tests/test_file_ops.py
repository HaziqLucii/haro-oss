"""`files.create_entry` / `rename_entry` / `delete_entry` — the worktree tree
right-click ops (new file/folder, rename/move, delete). All paths are resolved
*inside* the worktree; traversal outside it is refused, existing paths aren't
clobbered, and the root can't be deleted."""

from pathlib import Path

import pytest

from haro import files


def test_create_file_and_nested_folder(tmp_path: Path):
    files.create_entry(str(tmp_path), "src/new.ts", is_dir=False)
    f = tmp_path / "src" / "new.ts"
    assert f.is_file() and f.read_text() == ""

    files.create_entry(str(tmp_path), "src/lib", is_dir=True)
    assert (tmp_path / "src" / "lib").is_dir()


def test_create_refuses_existing(tmp_path: Path):
    (tmp_path / "a.txt").write_text("keep")
    with pytest.raises(ValueError):
        files.create_entry(str(tmp_path), "a.txt", is_dir=False)
    assert (tmp_path / "a.txt").read_text() == "keep"


def test_rename_moves_file(tmp_path: Path):
    (tmp_path / "a.txt").write_text("body")
    files.rename_entry(str(tmp_path), "a.txt", "sub/b.txt")
    assert not (tmp_path / "a.txt").exists()
    assert (tmp_path / "sub" / "b.txt").read_text() == "body"


def test_rename_refuses_overwrite(tmp_path: Path):
    (tmp_path / "a.txt").write_text("a")
    (tmp_path / "b.txt").write_text("b")
    with pytest.raises(ValueError):
        files.rename_entry(str(tmp_path), "a.txt", "b.txt")
    assert (tmp_path / "b.txt").read_text() == "b"


def test_rename_missing_source(tmp_path: Path):
    with pytest.raises(FileNotFoundError):
        files.rename_entry(str(tmp_path), "nope.txt", "x.txt")


def test_delete_file_and_folder(tmp_path: Path):
    (tmp_path / "a.txt").write_text("x")
    files.delete_entry(str(tmp_path), "a.txt")
    assert not (tmp_path / "a.txt").exists()

    d = tmp_path / "dir"
    d.mkdir()
    (d / "inner.txt").write_text("y")
    files.delete_entry(str(tmp_path), "dir")
    assert not d.exists()


def test_delete_refuses_root(tmp_path: Path):
    with pytest.raises(ValueError):
        files.delete_entry(str(tmp_path), "")


def test_ops_refuse_traversal(tmp_path: Path):
    with pytest.raises(ValueError):
        files.create_entry(str(tmp_path), "../escape.txt", is_dir=False)
    with pytest.raises(ValueError):
        files.rename_entry(str(tmp_path), "../x", "y")
    with pytest.raises(ValueError):
        files.delete_entry(str(tmp_path), "../etc")
