"""`files.create_entry` / `rename_entry` / `delete_entry` — the worktree tree
right-click ops (new file/folder, rename/move, delete). All paths are resolved
*inside* the worktree; traversal outside it is refused, existing paths aren't
clobbered, and the root can't be deleted."""

import asyncio
import json
import os
import stat
from pathlib import Path

import pytest

from haro import files, main as main_mod
from haro.models import WriteFileRequest, Workspace


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


# --- etag + atomic, conflict-safe writes ------------------------------------ #

def test_read_returns_etag_and_size(tmp_path: Path):
    (tmp_path / "a.txt").write_text("hello")
    r = files.read_file(str(tmp_path), "a.txt")
    assert r["etag"] == files.etag_of(b"hello")
    assert r["size"] == 5
    assert len(r["etag"]) == 16


def test_etag_round_trip(tmp_path: Path):
    (tmp_path / "a.txt").write_text("v1")
    etag1 = files.read_file(str(tmp_path), "a.txt")["etag"]
    etag2 = files.write_file(str(tmp_path), "a.txt", "v2", expected_etag=etag1)
    assert (tmp_path / "a.txt").read_text() == "v2"
    assert etag2 == files.read_file(str(tmp_path), "a.txt")["etag"] != etag1
    files.write_file(str(tmp_path), "a.txt", "v3", expected_etag=etag2)
    assert (tmp_path / "a.txt").read_text() == "v3"


def test_write_conflict_when_changed_on_disk(tmp_path: Path):
    (tmp_path / "a.txt").write_text("v1")
    etag1 = files.read_file(str(tmp_path), "a.txt")["etag"]
    (tmp_path / "a.txt").write_text("changed elsewhere")
    with pytest.raises(files.FileConflict) as exc:
        files.write_file(str(tmp_path), "a.txt", "mine", expected_etag=etag1)
    assert exc.value.current_etag == files.etag_of(b"changed elsewhere")
    assert (tmp_path / "a.txt").read_text() == "changed elsewhere"


def test_write_missing_when_deleted_on_disk(tmp_path: Path):
    (tmp_path / "a.txt").write_text("v1")
    etag1 = files.read_file(str(tmp_path), "a.txt")["etag"]
    (tmp_path / "a.txt").unlink()
    with pytest.raises(files.FileMissing):
        files.write_file(str(tmp_path), "a.txt", "mine", expected_etag=etag1)
    assert not (tmp_path / "a.txt").exists()


def test_unguarded_write_still_works(tmp_path: Path):
    (tmp_path / "a.txt").write_text("old")
    files.write_file(str(tmp_path), "a.txt", "new")
    assert (tmp_path / "a.txt").read_text() == "new"
    files.write_file(str(tmp_path), "deep/er/b.txt", "created")
    assert (tmp_path / "deep" / "er" / "b.txt").read_text() == "created"


def test_write_keeps_mode_bits(tmp_path: Path):
    f = tmp_path / "run.sh"
    f.write_text("#!/bin/sh\n")
    f.chmod(0o755)
    files.write_file(str(tmp_path), "run.sh", "#!/bin/sh\necho hi\n")
    assert stat.S_IMODE(f.stat().st_mode) == 0o755


def test_write_leaves_no_temp_file(tmp_path: Path):
    (tmp_path / "a.txt").write_text("x")
    files.write_file(str(tmp_path), "a.txt", "y")
    files.write_file(str(tmp_path), "new.txt", "z")
    assert sorted(os.listdir(tmp_path)) == ["a.txt", "new.txt"]


def test_failed_write_cleans_temp_and_keeps_original(tmp_path: Path, monkeypatch):
    (tmp_path / "a.txt").write_text("orig")

    def boom(*_a, **_k):
        raise OSError("disk full")

    monkeypatch.setattr(files.os, "replace", boom)
    with pytest.raises(OSError):
        files.write_file(str(tmp_path), "a.txt", "new")
    assert (tmp_path / "a.txt").read_text() == "orig"
    assert os.listdir(tmp_path) == ["a.txt"]


def test_write_refuses_traversal(tmp_path: Path):
    with pytest.raises(ValueError):
        files.write_file(str(tmp_path), "../escape.txt", "x")


def _put(ws: Workspace, **kw):
    return asyncio.run(main_mod.write_file(ws.id, WriteFileRequest(**kw)))


@pytest.fixture
def ws(tmp_path: Path):
    w = Workspace(
        project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main",
    )
    main_mod.store.workspaces[w.id] = w
    yield w
    main_mod.store.workspaces.pop(w.id, None)


def test_put_success_returns_etag(tmp_path: Path, ws: Workspace):
    (tmp_path / "a.txt").write_text("v1")
    etag = files.read_file(str(tmp_path), "a.txt")["etag"]
    out = _put(ws, path="a.txt", content="v2", expected_etag=etag)
    assert out == {"saved": "a.txt", "etag": files.etag_of(b"v2")}
    assert "a.txt" in ws.hand_saved_paths


def test_put_409_changed_body(tmp_path: Path, ws: Workspace):
    (tmp_path / "a.txt").write_text("v1")
    etag = files.read_file(str(tmp_path), "a.txt")["etag"]
    (tmp_path / "a.txt").write_text("theirs")
    res = _put(ws, path="a.txt", content="mine", expected_etag=etag)
    assert res.status_code == 409
    assert json.loads(res.body) == {
        "detail": "file changed on disk", "reason": "changed", "etag": files.etag_of(b"theirs"),
    }
    assert (tmp_path / "a.txt").read_text() == "theirs"
    assert "a.txt" not in ws.hand_saved_paths  # no XP/assist bookkeeping on a refused save


def test_put_409_deleted_body(tmp_path: Path, ws: Workspace):
    (tmp_path / "a.txt").write_text("v1")
    etag = files.read_file(str(tmp_path), "a.txt")["etag"]
    (tmp_path / "a.txt").unlink()
    res = _put(ws, path="a.txt", content="mine", expected_etag=etag)
    assert res.status_code == 409
    assert json.loads(res.body) == {"detail": "file changed on disk", "reason": "deleted", "etag": None}
    assert not (tmp_path / "a.txt").exists()


def test_put_without_etag_overwrites(tmp_path: Path, ws: Workspace):
    (tmp_path / "a.txt").write_text("v1")
    out = _put(ws, path="a.txt", content="forced")
    assert out["saved"] == "a.txt" and (tmp_path / "a.txt").read_text() == "forced"
