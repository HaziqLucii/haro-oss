"""Project notes: markdown pages in ``.haro/notes/``. Paths stay inside the folder, a save with a
stale etag is refused, and a change fires ``notes_changed``. Handlers are called directly."""

from __future__ import annotations

import asyncio

import pytest
from fastapi import HTTPException

from haro import notes, watcher
from haro.models import NoteRenameRequest, NoteWriteRequest, Project
from haro.store import store

from test_quiescence import FakeHub, clean_store  # noqa: F401


def run(coro):
    return asyncio.run(coro)


def test_a_note_round_trips_and_creates_the_folder(tmp_path):
    out = notes.write_note(str(tmp_path), "ideas.md", "# Ideas\n\nfirst")
    got = notes.read_note(str(tmp_path), "ideas.md")
    assert got["content"] == "# Ideas\n\nfirst" and got["etag"] == out["etag"]
    assert (tmp_path / ".haro/notes/ideas.md").is_file()


def test_subfolders_are_allowed(tmp_path):
    notes.write_note(str(tmp_path), "design/api.md", "x")
    assert [n["path"] for n in notes.list_notes(str(tmp_path))] == ["design/api.md"]


@pytest.mark.parametrize("bad", ["../x.md", "/etc/x.md", "a/../../x.md", "x.txt", "", ".hidden.md", "a/.b.md", "x"])
def test_bad_names_are_refused(tmp_path, bad):
    with pytest.raises(notes.NoteError):
        notes.write_note(str(tmp_path), bad, "x")
    with pytest.raises(notes.NoteError):
        notes.read_note(str(tmp_path), bad)


def test_a_symlink_out_of_the_folder_is_refused(tmp_path):
    root = tmp_path / ".haro/notes"
    root.mkdir(parents=True)
    outside = tmp_path / "secret"
    outside.mkdir()
    (root / "link").symlink_to(outside)
    with pytest.raises(notes.NoteError):
        notes.write_note(str(tmp_path), "link/x.md", "x")


def test_a_stale_etag_is_refused_and_leaves_the_file(tmp_path):
    first = notes.write_note(str(tmp_path), "n.md", "one")
    (tmp_path / ".haro/notes/n.md").write_text("changed elsewhere")
    with pytest.raises(notes.NoteConflict) as e:
        notes.write_note(str(tmp_path), "n.md", "two", etag=first["etag"])
    assert e.value.etag == notes.etag_of(b"changed elsewhere")
    assert (tmp_path / ".haro/notes/n.md").read_text() == "changed elsewhere"


def test_the_current_etag_saves_and_no_etag_overwrites_on_purpose(tmp_path):
    a = notes.write_note(str(tmp_path), "n.md", "one")
    b = notes.write_note(str(tmp_path), "n.md", "two", etag=a["etag"])
    assert b["etag"] == notes.etag_of(b"two")
    notes.write_note(str(tmp_path), "n.md", "three")
    assert notes.read_note(str(tmp_path), "n.md")["content"] == "three"


def test_an_etag_for_a_deleted_file_conflicts(tmp_path):
    a = notes.write_note(str(tmp_path), "n.md", "one")
    notes.delete_note(str(tmp_path), "n.md")
    with pytest.raises(notes.NoteConflict):
        notes.write_note(str(tmp_path), "n.md", "two", etag=a["etag"])


def test_a_note_over_the_size_limit_is_refused(tmp_path):
    with pytest.raises(notes.NoteError):
        notes.write_note(str(tmp_path), "big.md", "x" * (notes.MAX_BYTES + 1))


def test_no_scratch_file_is_left_behind(tmp_path):
    notes.write_note(str(tmp_path), "n.md", "one")
    assert [p.name for p in (tmp_path / ".haro/notes").iterdir()] == ["n.md"]


def test_list_is_newest_first_with_titles(tmp_path):
    import os

    notes.write_note(str(tmp_path), "old.md", "# Old idea\n")
    notes.write_note(str(tmp_path), "new.md", "no heading here\nsecond")
    os.utime(tmp_path / ".haro/notes/old.md", (1, 1))
    listed = notes.list_notes(str(tmp_path))
    assert [n["path"] for n in listed] == ["new.md", "old.md"]
    assert [n["title"] for n in listed] == ["new", "Old idea"]


def test_search_matches_title_and_text_with_snippets(tmp_path):
    notes.write_note(str(tmp_path), "a.md", "# Caching\n\nuse a Redis cache\nand a CDN")
    notes.write_note(str(tmp_path), "b.md", "# Other\n\nnothing")
    hits = notes.list_notes(str(tmp_path), "REDIS")
    assert [h["path"] for h in hits] == ["a.md"]
    assert hits[0]["snippets"] == ["use a Redis cache"]
    assert [h["path"] for h in notes.list_notes(str(tmp_path), "caching")] == ["a.md"]


def test_rename_and_delete(tmp_path):
    notes.write_note(str(tmp_path), "a.md", "x")
    notes.write_note(str(tmp_path), "b.md", "y")
    with pytest.raises(notes.NoteError):
        notes.rename_note(str(tmp_path), "a.md", "b.md")
    assert notes.rename_note(str(tmp_path), "a.md", "sub/c.md") == ("a.md", "sub/c.md")
    assert (tmp_path / ".haro/notes/sub/c.md").read_text() == "x"
    notes.delete_note(str(tmp_path), "sub/c.md")
    with pytest.raises(notes.NoteError):
        notes.delete_note(str(tmp_path), "sub/c.md")


def test_an_empty_project_lists_nothing(tmp_path):
    assert notes.list_notes(str(tmp_path)) == []


# -- routes ---------------------------------------------------------------------------


@pytest.fixture
def proj(clean_store, tmp_path, monkeypatch):  # noqa: F811
    from haro import main

    monkeypatch.setattr(main, "store", store)
    p = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(p)
    return main, p, tmp_path


def test_routes_save_read_list_rename_delete(proj):
    main, p, repo = proj
    saved = run(main.write_project_note(p.id, NoteWriteRequest(path="a.md", content="# A\nhello")))
    assert saved["ok"] and saved["etag"]
    assert run(main.read_project_note(p.id, "a.md"))["content"] == "# A\nhello"
    assert [n["title"] for n in run(main.list_project_notes(p.id))["notes"]] == ["A"]
    assert run(main.list_project_notes(p.id, "hello"))["notes"][0]["snippets"] == ["hello"]
    assert run(main.rename_project_note(p.id, NoteRenameRequest(path="a.md", new_path="b.md")))["path"] == "b.md"
    run(main.delete_project_note(p.id, "b.md"))
    assert run(main.list_project_notes(p.id))["notes"] == []


def test_a_stale_save_answers_409_with_the_current_etag(proj):
    main, p, repo = proj
    first = run(main.write_project_note(p.id, NoteWriteRequest(path="a.md", content="one")))
    (repo / ".haro/notes/a.md").write_text("edited elsewhere")
    res = run(main.write_project_note(p.id, NoteWriteRequest(path="a.md", content="two", etag=first["etag"])))
    assert res.status_code == 409
    import json

    body = json.loads(res.body)
    assert body["reason"] == "changed" and body["etag"] == notes.etag_of(b"edited elsewhere")


def test_routes_answer_400_for_a_bad_path_and_404_for_an_unknown_project(proj):
    main, p, _ = proj
    with pytest.raises(HTTPException) as e:
        run(main.write_project_note(p.id, NoteWriteRequest(path="../x.md", content="x")))
    assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        run(main.list_project_notes("nope"))
    assert e.value.status_code == 404


# -- the watcher -----------------------------------------------------------------------


def test_a_changed_note_fires_notes_changed_but_a_backlog_doc_does_not(clean_store, tmp_path):  # noqa: F811
    from watchfiles import Change

    p = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(p)
    hub = FakeHub()
    note = str(tmp_path / ".haro/notes/ideas.md")
    other = str(tmp_path / "docs/readme.md")
    run(watcher._dispatch(hub, {(Change.modified, note), (Change.modified, other)}, watcher._Quiescence(hub)))
    assert {"channel": "notify", "kind": "notes_changed", "project_id": p.id} in hub.broadcast
    assert len([m for m in hub.broadcast if m.get("kind") == "notes_changed"]) == 1


# -- review findings -------------------------------------------------------------------


def test_creating_a_note_never_replaces_one_that_exists(tmp_path):
    notes.write_note(str(tmp_path), "ideas.md", "precious")
    with pytest.raises(notes.NoteError, match="already exists"):
        notes.write_note(str(tmp_path), "ideas.md", "# Ideas\n\n", create_only=True)
    assert (tmp_path / ".haro/notes/ideas.md").read_text() == "precious"
    assert [p.name for p in (tmp_path / ".haro/notes").iterdir()] == ["ideas.md"]  # no scratch file


def test_creating_a_note_with_only_a_different_case_does_not_replace_it(tmp_path):
    notes.write_note(str(tmp_path), "ideas.md", "precious")
    folder = tmp_path / ".haro/notes"
    insensitive = (folder / "IDEAS.md").exists()
    if insensitive:  # macOS default: the same file under another spelling
        with pytest.raises(notes.NoteError):
            notes.write_note(str(tmp_path), "Ideas.md", "# Ideas\n\n", create_only=True)
        assert (folder / "ideas.md").read_text() == "precious"


def test_create_makes_a_new_note(tmp_path):
    out = notes.write_note(str(tmp_path), "new.md", "# New\n\n", create_only=True)
    assert out["etag"] == notes.etag_of(b"# New\n\n")


def test_a_rename_may_change_only_the_case(tmp_path):
    notes.write_note(str(tmp_path), "a.md", "x")
    folder = tmp_path / ".haro/notes"
    notes.rename_note(str(tmp_path), "a.md", "A.md")
    assert [p.name for p in folder.iterdir()] == ["A.md"]


@pytest.mark.parametrize("bad", ["a\x00b.md", "a\\b.md", "x" * 250 + ".md"])
def test_odd_names_are_note_errors_not_crashes(tmp_path, bad):
    with pytest.raises(notes.NoteError):
        notes.write_note(str(tmp_path), bad, "x")


def test_writing_onto_a_folder_is_refused_and_leaves_no_scratch_file(tmp_path):
    (tmp_path / ".haro/notes/x.md").mkdir(parents=True)
    with pytest.raises(notes.NoteError):
        notes.write_note(str(tmp_path), "x.md", "x")
    assert not [p for p in (tmp_path / ".haro/notes").iterdir() if p.name.endswith(".haro-tmp")]


def test_a_symlinked_note_is_neither_listed_nor_searched(tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("API_KEY=hunter2\n")
    folder = tmp_path / ".haro/notes"
    folder.mkdir(parents=True)
    (folder / "leak.md").symlink_to(secret)
    notes.write_note(str(tmp_path), "real.md", "ordinary")
    assert [n["path"] for n in notes.list_notes(str(tmp_path))] == ["real.md"]
    assert notes.list_notes(str(tmp_path), "hunter2") == []


def test_search_reaches_past_the_list_cap_but_reads_only_the_head(tmp_path, monkeypatch):
    monkeypatch.setattr(notes, "MAX_NOTES", 2)
    for i in range(4):
        notes.write_note(str(tmp_path), f"n{i}.md", f"body {i}")
    assert len(notes.list_notes(str(tmp_path))) == 2
    assert [n["path"] for n in notes.list_notes(str(tmp_path), "body 0")] == ["n0.md"]


def test_the_list_reads_only_enough_for_a_title(tmp_path):
    notes.write_note(str(tmp_path), "big.md", "# Title\n" + "x" * 500_000)
    assert notes.list_notes(str(tmp_path))[0]["title"] == "Title"


def test_the_create_flag_reaches_the_route(proj):
    main, p, _ = proj
    run(main.write_project_note(p.id, NoteWriteRequest(path="a.md", content="one")))
    with pytest.raises(HTTPException) as e:
        run(main.write_project_note(p.id, NoteWriteRequest(path="a.md", content="two", create=True)))
    assert e.value.status_code == 400 and "already exists" in e.value.detail
