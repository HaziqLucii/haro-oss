"""Item metadata beside the backlog files, the unified search, and the note extras (tasks,
templates, daily note, history, review). Handlers are called directly, like the rest of the suite."""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import time
from datetime import date

import pytest
from fastapi import HTTPException

from haro import backlog, backlog_find, backlog_meta, backlog_review, notes, notes_extras, notes_links
from haro.models import (
    BacklogViewsRequest, NoteFromTemplateRequest, Project, QuickCaptureRequest, TodoItemAppendRequest,
    TodoItemOpRequest, TodoMetaRequest, Workspace,
)
from haro.store import store

from test_quiescence import clean_store  # noqa: F401

DOC = "# Plan\n\n- [ ] first\n- [x] second\n- [ ] third\n\n## Later\n\n- [ ] fourth\n"


def run(coro):
    return asyncio.run(coro)


def pairs_of(text, path="backlog/plan.md"):
    return [(path, [b for b in backlog.parse_todo_doc(text) if b["kind"] == "item"])]


# --------------------------------------------------------------------------- #
# metadata: ids, matching, validation
# --------------------------------------------------------------------------- #
def test_an_item_gets_an_entry_lazily_and_the_file_is_sorted_json_lines(tmp_path):
    pairs = pairs_of(DOC)
    snap = backlog_meta.snapshot(str(tmp_path), pairs)
    assert snap.entries == [] and not snap.changed
    e = backlog_meta.ensure(snap, "backlog/plan.md", 2)
    backlog_meta.update(snap, e, tags=["#UI", "perf/db"], pinned=True)
    backlog_meta.persist(str(tmp_path), snap)
    lines = (tmp_path / ".haro/todos/meta.jsonl").read_text().splitlines()
    assert len(lines) == 1 and json.loads(lines[0])["tags"] == ["ui", "perf/db"]
    assert json.loads(lines[0])["text"] == "third"


def test_an_entry_follows_its_item_through_reorder_reword_and_move(tmp_path):
    snap = backlog_meta.snapshot(str(tmp_path), pairs_of(DOC))
    e = backlog_meta.ensure(snap, "backlog/plan.md", 2)  # third
    backlog_meta.persist(str(tmp_path), snap)
    eid = e.id

    def id_of(text, path="backlog/plan.md", index=None):
        s = backlog_meta.snapshot(str(tmp_path), pairs_of(text, path))
        for (p, i), ent in s.matched.items():
            if ent.id == eid:
                return p, i
        return None

    assert id_of(DOC) == ("backlog/plan.md", 2)
    assert id_of("- [ ] third\n- [ ] first\n") == ("backlog/plan.md", 0)  # reordered
    assert id_of("- [x] Third.\n- [ ] first\n") == ("backlog/plan.md", 0)  # normalised text
    assert id_of("- [ ] third\n", "backlog/other.md") == ("backlog/other.md", 0)  # moved file


def test_a_reworded_item_between_the_same_neighbours_is_still_found(tmp_path):
    snap = backlog_meta.snapshot(str(tmp_path), pairs_of(DOC))
    e = backlog_meta.ensure(snap, "backlog/plan.md", 2)
    backlog_meta.persist(str(tmp_path), snap)
    again = backlog_meta.snapshot(
        str(tmp_path), pairs_of("- [ ] first\n- [x] second\n- [ ] something else now\n- [ ] fourth\n")
    )
    assert again.entry_for("backlog/plan.md", 2).id == e.id
    assert again.changed  # the stored text was refreshed
    assert again.entry_for("backlog/plan.md", 2).text == "something else now"


def test_an_item_that_matches_nothing_is_lost_not_guessed(tmp_path):
    snap = backlog_meta.snapshot(str(tmp_path), pairs_of(DOC))
    backlog_meta.ensure(snap, "backlog/plan.md", 2)
    backlog_meta.persist(str(tmp_path), snap)
    again = backlog_meta.snapshot(str(tmp_path), pairs_of("- [ ] unrelated\n- [ ] other\n"))
    assert len(again.lost) == 1 and again.matched == {}


def test_validation_of_tags_depends_and_snooze(tmp_path):
    snap = backlog_meta.snapshot(str(tmp_path), pairs_of(DOC))
    a = backlog_meta.ensure(snap, "backlog/plan.md", 0)
    b = backlog_meta.ensure(snap, "backlog/plan.md", 2)
    with pytest.raises(backlog_meta.MetaError):
        backlog_meta.update(snap, a, tags=["has space"])
    with pytest.raises(backlog_meta.MetaError):
        backlog_meta.update(snap, a, depends=[a.id])
    with pytest.raises(backlog_meta.MetaError):
        backlog_meta.update(snap, a, depends=["zzzzzz"])
    with pytest.raises(backlog_meta.MetaError):
        backlog_meta.update(snap, a, snooze="tomorrow")
    backlog_meta.update(snap, a, depends=[b.id], snooze="2999-01-01")
    assert a.depends == [b.id] and a.snooze == "2999-01-01"


def test_decorate_marks_blocked_and_snoozed(tmp_path):
    pairs = pairs_of(DOC)
    snap = backlog_meta.snapshot(str(tmp_path), pairs)
    first = backlog_meta.ensure(snap, "backlog/plan.md", 0)
    third = backlog_meta.ensure(snap, "backlog/plan.md", 2)
    backlog_meta.update(snap, first, depends=[third.id], snooze="2999-01-01")
    backlog_meta.decorate(snap, pairs)
    items = pairs[0][1]
    assert items[0]["blocked"] and items[0]["blocked_by"] == [third.id] and items[0]["snoozed"]
    assert items[2]["id"] == third.id and not items[2]["blocked"]
    # once the dependency is done, nothing blocks
    items[2]["done"] = True
    backlog_meta.decorate(snap, pairs)
    assert not items[0]["blocked"]


def test_capture_splits_tags_and_dependencies_but_not_issues_or_words():
    assert backlog_meta.split_capture("fix cart bug #ui #perf/db depends:ab12cd see #123 and C#") == (
        "fix cart bug see #123 and C#", ["ui", "perf/db"], ["ab12cd"],
    )


def test_views_round_trip_and_need_names(tmp_path):
    saved = backlog_meta.save_views(
        str(tmp_path), [{"name": "Red UI", "query": "stage:red tag:ui", "layout": "board"}]
    )
    assert saved[0]["layout"] == "board" and saved[0]["id"]
    assert backlog_meta.load_views(str(tmp_path)) == saved
    with pytest.raises(backlog_meta.MetaError):
        backlog_meta.save_views(str(tmp_path), [{"name": " ", "query": ""}])


# --------------------------------------------------------------------------- #
# search
# --------------------------------------------------------------------------- #
CANDS = [
    {"kind": "todo", "title": "fix the cart bug", "text": "", "path": "backlog/a.md", "tags": ["ui"], "stage": "red", "done": False, "mtime": 0},
    {"kind": "todo", "title": "cart refactor", "text": "", "path": "backlog/b.md", "tags": ["perf/db"], "stage": "ready", "done": True, "mtime": 0},
    {"kind": "todo", "title": "old idea", "text": "", "path": "backlog/b.md", "tags": [], "stage": "ready", "done": False, "archived": True, "mtime": 0},
    {"kind": "note", "title": "Cart design", "text": "we keep the cart in redis", "path": "cart.md", "tags": ["ui"], "mtime": 5},
    {"kind": "issue", "title": "#7 cart crashes", "text": "", "path": "issue #7", "number": 7, "tags": ["bug"], "done": False, "mtime": 0},
]


def titles(q):
    return [c["title"] for c in backlog_find.search(CANDS, backlog_find.parse_query(q))]


def test_operators_filter_and_words_are_anded():
    assert titles("cart tag:ui") == ["Cart design", "fix the cart bug"]  # a title that starts with it first
    assert titles("stage:red") == ["fix the cart bug"]
    assert titles("in:notes") == ["Cart design"]
    assert titles("cart -is:done in:todos") == ["fix the cart bug"]
    assert titles("tag:perf") == ["cart refactor"]  # a parent tag matches its children
    assert titles('"cart bug"') == ["fix the cart bug"]
    assert "Cart design" not in titles("cart -redis") and "fix the cart bug" in titles("cart -redis")
    assert titles("path:b.md is:open") == []  # the open one there is archived


def test_archived_is_hidden_unless_asked():
    assert "old idea" not in titles("")
    assert titles("is:archived") == ["old idea"]


def test_an_empty_query_lists_pinned_todos_then_the_newest_notes():
    cands = CANDS + [{"kind": "todo", "title": "pinned one", "text": "", "path": "x.md", "tags": [], "done": False, "pinned": True, "mtime": 0}]
    out = [c["title"] for c in backlog_find.search(cands, backlog_find.Query())]
    assert out[0] == "pinned one" and out[1] == "Cart design"


def test_a_note_hit_shows_the_matching_line():
    q = backlog_find.parse_query("redis")
    hit = backlog_find.search(CANDS, q)[0]
    assert backlog_find.result_row(hit, q.terms)["snippet"] == "we keep the cart in redis"


# --------------------------------------------------------------------------- #
# note extras
# --------------------------------------------------------------------------- #
def test_open_tasks_skip_checked_and_code(tmp_path):
    notes.write_note(str(tmp_path), "a.md", "# A\n\n- [ ] real one\n- [x] done\n```\n- [ ] in code\n```\n1. [ ] numbered\n")
    tasks = notes_extras.open_tasks(str(tmp_path))
    assert [(t["path"], t["line"], t["text"]) for t in tasks] == [
        ("a.md", 3, "real one"), ("a.md", 8, "numbered"),
    ]


def test_templates_built_in_and_a_project_file_replaces_one(tmp_path):
    ids = [t["id"] for t in notes_extras.templates(str(tmp_path))]
    assert {"brainstorm", "decision", "design-doc", "pitch", "spike", "bug", "postmortem", "learning"} <= set(ids)
    (tmp_path / ".haro/templates").mkdir(parents=True)
    (tmp_path / ".haro/templates/spec.md").write_text("# {{title}} (ours)\n")
    (tmp_path / ".haro/templates/weekly.md").write_text("# {{title}}\n")
    by = {t["id"]: t for t in notes_extras.templates(str(tmp_path))}
    assert by["spec"]["source"] == "project" and by["weekly"]["name"] == "Weekly"
    assert notes_extras.fill(by["spec"]["content"], "Cache", date(2026, 10, 12)) == "# Cache (ours)\n"


def test_the_daily_note_has_facts_and_room_to_write():
    text = notes_extras.daily_text(date(2026, 10, 12), {"landed": ["abc1234 fix x"], "red": ["w1"], "tasks": []})
    assert text.startswith("# 2026-10-12\n\n## Landed on the default branch today\n\n- abc1234 fix x")
    assert "## Red gates right now" in text and "## Open tasks" not in text
    assert text.rstrip().endswith("## Notes")


def git(repo, *args, env=None):
    e = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t", **(env or {})}
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=True, env=e).stdout


def test_note_history_revision_and_diff_come_from_git(tmp_path):
    git(tmp_path, "init", "-q")
    notes.write_note(str(tmp_path), "n.md", "# N\n\none\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "first")
    notes.write_note(str(tmp_path), "n.md", "# N\n\none\ntwo\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "second")
    notes.write_note(str(tmp_path), "n.md", "# N\n\none\ntwo\nthree\n")
    rows = notes_extras.history(str(tmp_path), "n.md")
    assert [r["subject"] for r in rows] == ["second", "first"]
    assert notes_extras.revision(str(tmp_path), "n.md", rows[1]["sha"]) == "# N\n\none\n"
    d = notes_extras.diff_to_current(str(tmp_path), "n.md", rows[1]["sha"])
    assert "+two" in d and "+three" in d
    with pytest.raises(notes.NoteError):
        notes_extras.revision(str(tmp_path), "n.md", "not-a-sha; rm -rf")
    assert notes_extras.history(str(tmp_path), "untracked.md") == []


def test_review_helpers():
    files = [{"path": "backlog/a.md", "items": [
        {"text": "old open", "done": False}, {"text": "done", "done": True},
        {"text": "snoozed", "done": False, "snoozed": True},
    ]}]
    now = time.time()
    assert [r["text"] for r in backlog_review.stale_todos(files, {"backlog/a.md": now - 20 * 86400}, now)] == ["old open"]
    assert backlog_review.stale_todos(files, {"backlog/a.md": now - 2 * 86400}, now) == []
    notes_ = [
        {"path": "a.md", "title": "A", "outgoing": ["b.md"], "mtime": now},
        {"path": "b.md", "title": "B", "outgoing": [], "mtime": now - 40 * 86400},
        {"path": "c.md", "title": "C", "outgoing": [], "mtime": now - 50 * 86400},
    ]
    assert [n["path"] for n in backlog_review.unlinked_notes(notes_)] == ["c.md"]
    pick = backlog_review.resurface(notes_, now, date(2026, 10, 12))
    assert pick == backlog_review.resurface(notes_, now, date(2026, 10, 12))  # stable for a day
    assert pick["path"] in {"b.md", "c.md"}


# --------------------------------------------------------------------------- #
# routes
# --------------------------------------------------------------------------- #
@pytest.fixture
def proj(clean_store, tmp_path, monkeypatch):  # noqa: F811
    from haro import main

    async def no_save(_store):
        return None

    async def no_issues(project_id, **_kw):
        return {"available": False, "issues": []}

    monkeypatch.setattr(main.db, "save_snapshot", no_save)
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "get_issues", no_issues)
    git(tmp_path, "init", "-q")
    (tmp_path / "backlog").mkdir()
    (tmp_path / "backlog/plan.md").write_text(DOC)
    p = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(p)
    return main, p, tmp_path


def items_of(main, p):
    return run(main.get_todo(p.id))["files"][0]["items"]


def test_meta_route_gives_the_id_and_get_todo_decorates(proj):
    main, p, root = proj
    assert items_of(main, p)[2]["id"] is None
    out = run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=2, expect="third", tags=["ui"], pinned=True)))
    eid = out["entry"]["id"]
    it = items_of(main, p)[2]
    assert (it["id"], it["tags"], it["pinned"]) == (eid, ["ui"], True)
    assert not (root / "backlog/plan.md").read_text() != DOC  # the project's file is untouched
    with pytest.raises(HTTPException) as e:
        run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=2, expect="changed", tags=["x"])))
    assert e.value.status_code == 409


def test_an_in_app_reword_and_move_keep_the_id(proj):
    main, p, root = proj
    eid = run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=0, expect="first", tags=["ui"])))["entry"]["id"]
    run(main.todo_item_op(p.id, TodoItemOpRequest(file="backlog/plan.md", index=0, expect="first", op="edit", body="first, but now totally different words")))
    assert [i["id"] for i in items_of(main, p)][0] == eid
    run(main.todo_item_op(p.id, TodoItemOpRequest(file="backlog/plan.md", index=0, expect="first, but now totally different words", op="move", to_file="backlog/other.md")))
    found = [(f["path"], i["id"]) for f in run(main.get_todo(p.id))["files"] for i in f["items"] if i["id"]]
    assert found == [("backlog/other.md", eid)]


def test_capture_tags_go_to_the_sidecar_not_the_line(proj):
    main, p, root = proj
    out = run(main.add_todo_item(p.id, TodoItemAppendRequest(title="fix cart bug #ui #perf", inbox=True, parse_tags=True)))
    assert out["tags"] == ["ui", "perf"] and out["id"]
    text = (root / "backlog/inbox.md").read_text()
    assert "- [ ] fix cart bug" in text and "#ui" not in text
    todo = run(main.get_todo(p.id))
    inbox = next(f for f in todo["files"] if f["path"] == "backlog/inbox.md")
    assert inbox["items"][0]["tags"] == ["ui", "perf"]


def test_find_route_searches_todos_and_notes(proj):
    main, p, root = proj
    notes.write_note(str(root), "cart.md", "# Cart design\n\nsee #ui and redis")
    run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=2, expect="third", tags=["ui"])))
    out = run(main.find_in_project(p.id, q="tag:ui"))["results"]
    assert {(r["kind"], r["title"]) for r in out} == {("todo", "third"), ("note", "Cart design")}
    assert run(main.find_in_project(p.id, q="in:notes redis"))["results"][0]["snippet"] == "see #ui and redis"


def test_views_routes(proj):
    main, p, _ = proj
    out = run(main.put_backlog_views(p.id, BacklogViewsRequest(views=[{"name": "Ready", "query": "is:ready", "layout": "board"}])))
    assert run(main.get_backlog_views(p.id))["views"] == out["views"]
    with pytest.raises(HTTPException):
        run(main.put_backlog_views(p.id, BacklogViewsRequest(views=[{"name": "", "query": ""}])))


def test_todo_links_from_notes(proj):
    main, p, root = proj
    eid = run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=2, expect="third", tags=["ui"])))["entry"]["id"]
    notes.write_note(str(root), "n.md", f"# N\n\nneeds [[todo:{eid} the third thing]] and `[[todo:{eid}]]`")
    got = run(main.get_todo_links(p.id, eid))["notes"]
    assert [g["path"] for g in got] == ["n.md"]
    out = notes_links.links_for(str(root), "n.md")["outgoing"][0]
    assert out["todo"]["text"] == "third" and out["todo"]["done"] is False and out["path"] is None


def test_tasks_templates_from_template_and_daily_routes(proj):
    main, p, root = proj
    notes.write_note(str(root), "a.md", "- [ ] write it")
    assert [t["text"] for t in run(main.get_note_tasks(p.id))["tasks"]] == ["write it"]
    assert any(t["id"] == "postmortem" for t in run(main.get_note_templates(p.id))["templates"])
    out = run(main.note_from_template(p.id, NoteFromTemplateRequest(template="decision", path="decisions/cache.md", title="Cache choice")))
    body = notes.read_note(str(root), "decisions/cache.md")["content"]
    assert out["path"] == "decisions/cache.md" and body.startswith("# Cache choice") and "status:: proposed" in body
    with pytest.raises(HTTPException):
        run(main.note_from_template(p.id, NoteFromTemplateRequest(template="decision", path="decisions/cache.md", title="x")))
    first = run(main.open_daily_note(p.id))
    assert first == {"path": f"daily/{date.today().isoformat()}.md", "created": True}
    assert "write it" in notes.read_note(str(root), first["path"])["content"]
    assert run(main.open_daily_note(p.id))["created"] is False


def test_quick_capture_routes(proj):
    main, p, root = proj
    ws = Workspace(project_id=p.id, name="w", branch="b", worktree_path=str(root / "wt"), base_ref="main")
    store.add_workspace(ws)
    out = run(main.quick_note(ws.id, QuickCaptureRequest(text="Cache the price list\nwith redis")))
    assert out["path"] == "inbox/cache-the-price-list.md"
    assert notes.read_note(str(root), out["path"])["content"] == "# Cache the price list\n\nCache the price list\nwith redis\n"
    assert run(main.quick_note(ws.id, QuickCaptureRequest(text="Cache the price list")))["path"] == "inbox/cache-the-price-list-2.md"
    t = run(main.quick_todo(ws.id, QuickCaptureRequest(text="fix cart #ui")))
    assert t["path"] == "backlog/inbox.md" and t["tags"] == ["ui"]
    with pytest.raises(HTTPException):
        run(main.quick_note(ws.id, QuickCaptureRequest(text="  ")))


def test_review_route(proj):
    main, p, root = proj
    old = "2026-01-01T00:00:00"
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "old", env={"GIT_AUTHOR_DATE": old, "GIT_COMMITTER_DATE": old})
    notes.write_note(str(root), "lonely.md", "# Lonely")
    out = run(main.get_review(p.id))
    assert {r["text"] for r in out["stale"]} == {"first", "third", "fourth"}
    assert [n["path"] for n in out["unlinked_notes"]] == ["lonely.md"]
    assert {r["text"] for r in out["not_started"]} == {"first", "third", "fourth"}
    assert out["note_tasks"] == 0


PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 20


def test_images_are_stored_by_what_they_are_and_served_back(proj):
    import base64

    from haro.models import NoteAssetRequest

    main, p, root = proj
    out = run(main.add_note_asset(p.id, NoteAssetRequest(data=base64.b64encode(PNG).decode())))
    assert out["path"].startswith("assets/") and out["path"].endswith(".png")
    assert (root / ".haro/notes" / out["path"]).read_bytes() == PNG
    served = run(main.get_note_asset(p.id, out["path"]))
    assert str(served.path).endswith(out["path"].split("/")[1])
    with pytest.raises(HTTPException):
        run(main.add_note_asset(p.id, NoteAssetRequest(data=base64.b64encode(b"<svg onload=alert(1)>").decode())))
    with pytest.raises(HTTPException):
        run(main.add_note_asset(p.id, NoteAssetRequest(data="not base64!!")))


def test_an_asset_path_cannot_leave_the_assets_folder(proj):
    main, p, root = proj
    (root / ".haro/notes").mkdir(parents=True, exist_ok=True)
    (root / ".haro/secret.png").write_bytes(PNG)
    for bad in ("assets/../../secret.png", "../secret.png", "assets/x.svg", "notes.md", "assets/a/b.png"):
        with pytest.raises(HTTPException):
            run(main.get_note_asset(p.id, bad))


# --------------------------------------------------------------------------- #
# review fixes
# --------------------------------------------------------------------------- #
def test_a_deleted_items_entry_is_dropped_and_does_not_attach_to_the_next_item(proj):
    main, p, root = proj
    run(main.add_todo_item(p.id, TodoItemAppendRequest(title="keep", inbox=True)))
    run(main.add_todo_item(p.id, TodoItemAppendRequest(title="x", inbox=True)))
    run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/inbox.md", index=1, expect="x", snooze="2999-01-01", tags=["old"])))
    run(main.todo_item_op(p.id, TodoItemOpRequest(file="backlog/inbox.md", index=1, expect="x", op="delete")))
    run(main.add_todo_item(p.id, TodoItemAppendRequest(title="y", inbox=True)))
    inbox = next(f for f in run(main.get_todo(p.id))["files"] if f["path"] == "backlog/inbox.md")
    y = next(i for i in inbox["items"] if i["text"] == "y")
    assert y["id"] is None and y["tags"] == [] and not y["snoozed"]
    assert backlog_meta.load(str(root)) == []


def test_reading_the_backlog_never_writes_the_sidecar(proj):
    main, p, root = proj
    run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=0, expect="first", tags=["ui"])))
    path = root / ".haro/todos/meta.jsonl"
    before = path.read_text()
    (root / "backlog/plan.md").write_text(DOC.replace("- [ ] first", "- [ ] first, reworded a bit"))
    run(main.get_todo(p.id))
    assert path.read_text() == before


def test_only_quick_capture_takes_tags_off_the_line(proj):
    main, p, root = proj
    run(main.add_todo_item(p.id, TodoItemAppendRequest(title="add #include guard", inbox=True)))
    assert "#include" in (root / "backlog/inbox.md").read_text()


def test_a_capture_that_cannot_be_stored_is_refused_before_anything_is_written(proj):
    main, p, root = proj
    with pytest.raises(HTTPException) as e:
        run(main.add_todo_item(p.id, TodoItemAppendRequest(title="fix it depends:zzzz9", inbox=True, parse_tags=True)))
    assert e.value.status_code == 400
    assert not (root / "backlog/inbox.md").exists()


def test_parallel_metadata_writes_do_not_lose_updates(proj):
    main, p, root = proj

    async def go():
        await asyncio.gather(*[
            main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=i, expect=t, tags=[f"t{i}"]))
            for i, t in enumerate(["first", "second", "third", "fourth"])
        ])

    run(go())
    assert sorted(t for e in backlog_meta.load(str(root)) for t in e.tags) == ["t0", "t1", "t2", "t3"]


def test_a_dependency_loop_is_refused(proj):
    main, p, root = proj
    a = run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=0, expect="first", tags=["a"])))["entry"]["id"]
    b = run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=2, expect="third", depends=[a])))["entry"]["id"]
    with pytest.raises(HTTPException) as e:
        run(main.set_todo_meta(p.id, TodoMetaRequest(file="backlog/plan.md", index=0, expect="first", depends=[b])))
    assert e.value.status_code == 400


def test_the_assets_folder_cannot_be_a_link_out_of_the_project(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    project = tmp_path / "proj"
    (project / ".haro/notes").mkdir(parents=True)
    os.symlink(outside, project / ".haro/notes/assets")
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 20
    with pytest.raises(notes.NoteError):
        notes_extras.save_asset(str(project), png)
    assert list(outside.iterdir()) == []


def test_every_built_in_template_fills_and_has_its_own_shape():
    from itertools import combinations

    from haro.note_templates import BUILT_IN

    heads: dict[str, set[str]] = {}
    for tid, (name, body) in BUILT_IN.items():
        text = notes_extras.fill(body, "Cache choice", date(2026, 10, 12))
        assert text.startswith("# Cache choice\n"), tid
        assert "{{" not in text, tid
        assert notes._title(text, "x") == "Cache choice", tid
        heads[tid] = {l.strip() for l in body.splitlines() if l.startswith("#")} - {"# {{title}}"}
    for a, b in combinations(heads, 2):
        shared = heads[a] & heads[b]
        assert len(shared) <= max(2, len(heads[a]) // 3), (a, b, shared)
    # the research-based ones carry their format's own parts
    assert {"## Considered Options", "## Decision Outcome", "### Confirmation"} <= heads["decision"]
    assert {"## Non-goals", "## Alternatives considered"} <= heads["design-doc"]
    assert {"## Appetite", "## Rabbit holes", "## No-gos"} <= heads["pitch"]
    assert {"## Timeline", "## Action items", "## Detection"} <= heads["postmortem"]
    assert {"## Hypotheses", "## Five whys", "## Root cause"} <= heads["bug"]


# --------------------------------------------------------------------------- #
# .haro/todos
# --------------------------------------------------------------------------- #
def test_metadata_written_by_an_earlier_build_is_read_then_moved(tmp_path):
    old = tmp_path / ".haro/backlog"
    old.mkdir(parents=True)
    (old / "meta.jsonl").write_text(
        json.dumps({"id": "abc123", "path": "backlog/plan.md", "text": "third", "tags": ["ui"]}) + "\n"
    )
    (old / "views.json").write_text(json.dumps([{"id": "v1", "name": "UI", "query": "tag:ui", "layout": "list"}]))
    assert [e.id for e in backlog_meta.load(str(tmp_path))] == ["abc123"]
    assert backlog_meta.load_views(str(tmp_path))[0]["name"] == "UI"
    snap = backlog_meta.snapshot(str(tmp_path), pairs_of(DOC))
    backlog_meta.persist(str(tmp_path), snap)
    backlog_meta.save_views(str(tmp_path), backlog_meta.load_views(str(tmp_path)))
    assert (tmp_path / ".haro/todos/meta.jsonl").exists() and (tmp_path / ".haro/todos/views.json").exists()
    assert not old.exists()


def test_haro_todos_is_always_a_backlog_folder(tmp_path):
    assert backlog.is_backlog_path(".haro/todos/sap.md")
    assert backlog.is_backlog_path(".haro/todos/sap.md", "docs/plans")
    assert not backlog.is_backlog_path(".haro/todos/meta.jsonl")


def test_new_todo_files_default_to_haro_todos_unless_the_project_has_a_backlog_folder(proj):
    main, p, root = proj
    out = run(main.add_todo_item(p.id, TodoItemAppendRequest(title="one", inbox=True)))
    assert out["path"] == "backlog/inbox.md", "this project already has backlog/plan.md"


# --------------------------------------------------------------------------- #
# files beside the notes (PDFs, sheets, drawings) and the search inside them
# --------------------------------------------------------------------------- #
def _make_pdf(text: str) -> bytes:
    """A one-page PDF with a correct cross-reference table (so a real reader accepts it)."""
    stream = f"BT /F1 12 Tf 20 50 Td ({text}) Tj ET".encode()
    objs = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 100]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>",
        b"<</Length %d>>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return out


PDF = _make_pdf("VPN tunnel status")


def vault(tmp_path):
    n = tmp_path / ".haro/notes"
    (n / "source-materials/deprecated").mkdir(parents=True)
    (n / "banners").mkdir()
    (n / "assets").mkdir()
    (n / "plan.md").write_text("# Plan\n\nsee [[report.pdf]] and ![[banners/hero.png]] and ![[sketch.excalidraw]]\n")
    (n / "source-materials/report.pdf").write_bytes(PDF)
    (n / "source-materials/deprecated/old.pdf").write_bytes(PDF)
    (n / "source-materials/sheet.xlsx").write_bytes(b"PK\x03\x04 not really")
    (n / "source-materials/notes.sql").write_text("select vpn_status from tunnels;")
    (n / "source-materials/run.sh").write_text("echo no")
    (n / "source-materials/app.command").write_text("echo no")
    (n / "banners/hero.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 20)
    (n / "assets/pasted.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 20)
    (n / "sketch.excalidraw.md").write_text("---\nexcalidraw-plugin: parsed\n---\n# Drawing\n")
    (n / "sketch.excalidraw.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 20)
    (n / ".hidden.pdf").write_bytes(PDF)
    return str(tmp_path)


def test_files_beside_the_notes_are_listed_with_their_kind_and_scripts_are_not(tmp_path):
    from haro import note_files

    root = vault(tmp_path)
    got = {f["path"]: f["kind"] for f in note_files.list_files(root)}
    assert got["source-materials/report.pdf"] == "pdf"
    assert got["source-materials/sheet.xlsx"] == "sheet"
    assert got["source-materials/notes.sql"] == "text"
    assert got["sketch.excalidraw.md"] == "drawing"
    assert got["banners/hero.png"] == "image"
    assert not any(p.endswith((".sh", ".command")) or p.startswith("assets/") or "/." in p or p.startswith(".") for p in got)
    # a drawing is a file, not a note
    assert "sketch.excalidraw.md" not in [n["path"] for n in notes.list_notes(root)]
    assert "plan.md" in [n["path"] for n in notes.list_notes(root)]


def test_a_link_finds_its_file_by_path_or_by_name_and_never_escapes(tmp_path):
    from haro import note_files

    root = vault(tmp_path)
    assert note_files.resolve(root, "report.pdf").name == "report.pdf"
    assert note_files.resolve(root, "source-materials/deprecated/old.pdf").name == "old.pdf"
    for bad in ["../x.pdf", "/etc/passwd", "plan.md", ".hidden.pdf"]:
        with pytest.raises(notes.NoteError):
            note_files.resolve(root, bad)
    out = tmp_path / "outside.pdf"
    out.write_bytes(PDF)
    os.symlink(out, tmp_path / ".haro/notes/link.pdf")
    with pytest.raises(notes.NoteError):
        note_files.resolve(root, "link.pdf")


def test_opening_uses_the_system_app_and_only_for_document_and_image_types(tmp_path, monkeypatch):
    from haro import note_files

    root = vault(tmp_path)
    seen = []
    monkeypatch.setattr(note_files.subprocess, "Popen", lambda cmd, **kw: seen.append(cmd))
    assert note_files.open_externally(root, "report.pdf") == "source-materials/report.pdf"
    assert seen[0][0] in ("open", "xdg-open") and seen[0][1].endswith("source-materials/report.pdf")
    for blocked in ["run.sh", "app.command"]:
        with pytest.raises(notes.NoteError):
            note_files.open_externally(root, blocked)
    assert len(seen) == 1


def test_embedded_images_resolve_by_name_and_a_drawing_shows_its_export(tmp_path):
    from haro import note_files

    root = vault(tmp_path)
    assert note_files.image_file(root, "hero.png").name == "hero.png"
    assert note_files.image_file(root, "assets/pasted.png").name == "pasted.png"
    assert note_files.image_file(root, "sketch.excalidraw").name == "sketch.excalidraw.png"
    with pytest.raises(notes.NoteError):
        note_files.image_file(root, "report.pdf")


def test_links_to_files_are_reported_as_files_not_missing_notes(tmp_path):
    root = vault(tmp_path)
    rows = {r["target"]: r for r in notes_links.links_for(root, "plan.md")["outgoing"]}
    assert rows["report.pdf"]["file"] == "source-materials/report.pdf"
    assert rows["banners/hero.png"]["file"] == "banners/hero.png"
    assert rows["sketch.excalidraw"]["file"] == "sketch.excalidraw.md"


def test_the_search_finds_words_inside_a_pdf_and_a_text_file(proj):
    main, p, root = proj
    vault(root)
    out = run(main.find_in_project(p.id, q="tunnel"))["results"]
    kinds = {(r["kind"], r["title"]) for r in out}
    assert ("file", "report.pdf") in kinds and ("file", "old.pdf") in kinds
    assert any(r["kind"] == "file" and "VPN tunnel status" in r["snippet"] for r in out)
    assert ("file", "notes.sql") in {(r["kind"], r["title"]) for r in run(main.find_in_project(p.id, q="in:files vpn_status"))["results"]}
    assert not any(r["kind"] == "file" for r in run(main.find_in_project(p.id, q="in:notes tunnel"))["results"])


def test_file_routes(proj, monkeypatch):
    from haro import note_files

    main, p, root = proj
    vault(root)
    listed = run(main.list_note_files(p.id))["files"]
    assert any(f["name"] == "report.pdf" for f in listed)
    monkeypatch.setattr(note_files.subprocess, "Popen", lambda cmd, **kw: None)
    from haro.models import NoteFileOpenRequest

    assert run(main.open_note_file(p.id, NoteFileOpenRequest(path="report.pdf")))["ok"] is True
    with pytest.raises(HTTPException) as e:
        run(main.open_note_file(p.id, NoteFileOpenRequest(path="../../etc/hosts")))
    assert e.value.status_code == 400


def test_project_plans_lists_every_workspace_plan_newest_first(proj):
    from haro.models import ManualPlan, PlanStep

    main, p, root = proj
    a = Workspace(project_id=p.id, name="first", branch="haro/first", worktree_path=str(root), base_ref="main")
    b = Workspace(project_id=p.id, name="second", branch="haro/second", worktree_path=str(root), base_ref="main")
    other = Workspace(project_id="someone-else", name="elsewhere", branch="x", worktree_path=str(root), base_ref="main")
    a.plans = [ManualPlan(title="Old plan", steps=[PlanStep(text="a", done=True), PlanStep(text="b")], created_at=100.0)]
    b.plans = [ManualPlan(title="New plan", steps=[PlanStep(text="c")], created_at=200.0, saved=True)]
    other.plans = [ManualPlan(title="Not ours", steps=[PlanStep(text="d")])]
    for w in (a, b, other):
        store.add_workspace(w)
    out = run(main.list_project_plans(p.id))["plans"]
    assert [r["plan"]["title"] for r in out] == ["New plan", "Old plan"]
    assert out[0]["workspace_name"] == "second" and out[0]["plan"]["saved"] is True
    assert out[1]["plan"]["steps"][0]["done"] is True
    with pytest.raises(HTTPException) as e:
        run(main.list_project_plans("nope"))
    assert e.value.status_code == 404
