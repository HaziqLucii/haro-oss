"""Item-level backlog edits (check, edit, delete, reorder, move) and the routes on them.

Items are addressed by position plus the text the caller saw, so an agent or the merge tick
changing the file meanwhile gives a 409 rather than an edit to the wrong line. Handlers are
called directly with ``asyncio.run``, like the rest of the suite.
"""

from __future__ import annotations

import asyncio

import pytest
from fastapi import HTTPException

from haro import backlog
from haro.models import Project, TodoItemOpRequest, TodoRenameRequest, Workspace
from haro.store import store

from test_quiescence import clean_store  # noqa: F401

DOC = """# Plan

- [ ] first
- [x] second
  wrapped line
- [ ] third

## Later

- [ ] fourth
"""


def texts(doc: str) -> list[str]:
    return [b["text"] for b in backlog.parse_todo(doc)]


def test_items_know_their_line_range():
    items = backlog.parse_todo(DOC)
    lines = DOC.splitlines()
    assert [lines[i["line"]] for i in items][1] == "- [x] second"
    assert items[1]["end"] - items[1]["line"] == 2  # the wrapped line belongs to it


def test_check_and_uncheck_touch_only_the_box():
    out = backlog.set_done(DOC, 0, "first", True)
    assert out == DOC.replace("- [ ] first", "- [x] first")
    assert backlog.set_done(out, 0, "first", False) == DOC


def test_check_keeps_indent_and_marker():
    doc = "* [ ] a\n  * [ ] nested\n"
    out = backlog.set_done(doc, 1, "nested", True)
    assert out == "* [ ] a\n  * [x] nested\n"


def test_a_stale_position_is_refused_not_applied():
    with pytest.raises(backlog.StaleItem):
        backlog.set_done(DOC, 0, "something else", True)
    with pytest.raises(backlog.StaleItem):
        backlog.delete_item(DOC, 9, "first")


def test_edit_replaces_the_whole_item_and_keeps_its_state():
    out = backlog.edit_item(DOC, 1, "second wrapped line", "second, reworded\nand wrapped")
    assert "- [x] second, reworded\n  and wrapped\n- [ ] third" in out
    assert texts(out) == ["first", "second, reworded and wrapped", "third", "fourth"]


def test_edit_drops_blank_lines_outside_a_fence_and_keeps_them_inside():
    out = backlog.edit_item(DOC, 0, "first", "head\n\ntail\n```\na\n\nb\n```")
    item = backlog.parse_todo(out)[0]
    assert item["text"].startswith("head tail")
    assert "a\n\nb" in item["body"]


def test_edit_needs_some_text():
    with pytest.raises(backlog.BacklogError):
        backlog.edit_item(DOC, 0, "first", "   \n")


def test_delete_removes_the_wrapped_lines_too():
    out = backlog.delete_item(DOC, 1, "second wrapped line")
    assert "second" not in out and "wrapped" not in out
    assert texts(out) == ["first", "third", "fourth"]


def test_move_swaps_neighbours():
    assert texts(backlog.move_item(DOC, 2, "third", -1)) == ["first", "third", "second wrapped line", "fourth"]
    assert texts(backlog.move_item(DOC, 0, "first", 1)) == ["second wrapped line", "first", "third", "fourth"]


def test_move_across_a_heading_joins_the_neighbouring_section():
    up = backlog.move_item(DOC, 3, "fourth", -1)
    assert up.index("- [ ] fourth") < up.index("## Later")
    assert up.index("- [ ] fourth") > up.index("- [ ] third")
    down = backlog.move_item(DOC, 2, "third", 1)
    assert down.index("- [ ] third") > down.index("## Later")
    assert down.index("- [ ] third") < down.index("- [ ] fourth")


def test_move_at_either_end_changes_nothing():
    assert backlog.move_item(DOC, 0, "first", -1) == DOC
    assert backlog.move_item(DOC, 3, "fourth", 1) == DOC


def test_move_keeps_every_line():
    out = backlog.move_item(DOC, 1, "second wrapped line", 1)
    assert sorted(out.splitlines()) == sorted(DOC.splitlines())


def test_ops_work_on_a_file_without_a_trailing_newline():
    doc = "- [ ] a\n- [ ] b"
    assert backlog.move_item(doc, 1, "b", -1) == "- [ ] b\n- [ ] a\n"
    assert backlog.move_item(doc, 0, "a", 1) == "- [ ] b\n- [ ] a\n"
    assert texts(backlog.move_item("# H\n- [ ] a\n\n- [ ] b", 0, "a", 1)) == ["b", "a"]


def test_an_edit_with_an_open_fence_cannot_swallow_the_items_after_it():
    doc = "- [ ] a\n- [ ] b\n- [ ] c\n"
    out = backlog.edit_item(doc, 0, "a", "a\n```\ncode")
    assert texts(out) == ["a", "b", "c"]
    assert texts(backlog.delete_item(out, 0, "a")) == ["b", "c"]


def test_a_checkbox_inside_a_fence_is_not_an_item():
    doc = "- [ ] real\n```\n- [ ] shown\n```\n- [ ] last\n"
    assert texts(doc) == ["real", "last"]
    assert backlog.set_done(doc, 1, "last", True).endswith("- [x] last\n")


# -- file level (apply_item_op, rename) -------------------------------------------------


def make_repo(tmp_path, content=DOC):
    (tmp_path / "backlog").mkdir()
    (tmp_path / "backlog" / "plan.md").write_text(content)
    return tmp_path


def test_move_to_another_file_appends_and_removes(tmp_path):
    repo = make_repo(tmp_path)
    out = backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 1, "second wrapped line", to_rel="backlog/other.md")
    assert out["to"] == "backlog/other.md"
    assert "second" not in (repo / "backlog/plan.md").read_text()
    moved = (repo / "backlog/other.md").read_text()
    assert moved.startswith("# Other") and "- [x] second" in moved and "  wrapped line" in moved


def test_a_move_to_a_path_outside_the_backlog_is_refused_and_nothing_changes(tmp_path):
    repo = make_repo(tmp_path)
    with pytest.raises(backlog.BacklogError):
        backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 0, "first", to_rel="src/app.py")
    assert (repo / "backlog/plan.md").read_text() == DOC


def test_a_move_to_the_same_file_under_another_name_changes_nothing(tmp_path):
    repo = make_repo(tmp_path)
    (repo / "backlog" / "link.md").symlink_to(repo / "backlog" / "plan.md")
    out = backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 0, "first", to_rel="backlog/link.md")
    assert out["to"] is None
    assert (repo / "backlog/plan.md").read_text() == DOC


def test_a_file_that_is_not_utf8_is_a_backlog_error_not_a_crash(tmp_path):
    repo = make_repo(tmp_path)
    (repo / "backlog" / "bad.md").write_bytes(b"- [ ] caf\xe9\n")
    with pytest.raises(backlog.BacklogError):
        backlog.apply_item_op(str(repo), "backlog/bad.md", "check", 0, "caf")
    with pytest.raises(backlog.BacklogError):
        backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 0, "first", to_rel="backlog/bad.md")
    assert (repo / "backlog/plan.md").read_text() == DOC


def test_ops_cannot_leave_the_project(tmp_path):
    repo = make_repo(tmp_path)
    with pytest.raises(backlog.BacklogError):
        backlog.apply_item_op(str(repo), "../x.md", "check", 0, "first")


def test_rename_refuses_an_existing_target_and_an_ineligible_name(tmp_path):
    repo = make_repo(tmp_path)
    (repo / "backlog/b.md").write_text("- [ ] b\n")
    with pytest.raises(backlog.BacklogError):
        backlog.rename_todo(str(repo), "backlog/plan.md", "backlog/b.md")
    with pytest.raises(backlog.BacklogError):
        backlog.rename_todo(str(repo), "backlog/plan.md", "src/plan.py")
    assert backlog.rename_todo(str(repo), "backlog/plan.md", "backlog/sub/new.md") == ("backlog/plan.md", "backlog/sub/new.md")
    assert (repo / "backlog/sub/new.md").read_text() == DOC


# -- routes ----------------------------------------------------------------------------


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def seeded(clean_store, tmp_path, monkeypatch):  # noqa: F811
    from haro import main

    async def no_save(_store):
        return None

    monkeypatch.setattr(main.db, "save_snapshot", no_save)
    monkeypatch.setattr(main, "store", store)  # an earlier test may have swapped it
    repo = make_repo(tmp_path)
    proj = Project(name="demo", path=str(repo), default_branch="main")
    store.add_project(proj)
    ws = Workspace(
        project_id=proj.id, name="w", branch="b", worktree_path=str(tmp_path / "wt"),
        base_ref="main", seed_key="backlog/plan.md::third",
    )
    store.add_workspace(ws)
    return main, proj, ws, repo


def op(**kw):
    return TodoItemOpRequest(file="backlog/plan.md", **kw)


def test_route_check_writes_the_file(seeded):
    main, proj, _, repo = seeded
    run(main.todo_item_op(proj.id, op(index=0, expect="first", op="check")))
    assert "- [x] first" in (repo / "backlog/plan.md").read_text()


def test_route_answers_409_for_a_stale_item_and_leaves_the_file(seeded):
    main, proj, _, repo = seeded
    with pytest.raises(HTTPException) as e:
        run(main.todo_item_op(proj.id, op(index=0, expect="not there", op="delete")))
    assert e.value.status_code == 409
    assert (repo / "backlog/plan.md").read_text() == DOC


def test_route_answers_400_for_a_bad_request_and_404_for_an_unknown_project(seeded):
    main, proj, _, _ = seeded
    with pytest.raises(HTTPException) as e:
        run(main.todo_item_op(proj.id, op(index=0, expect="first", op="move")))
    assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        run(main.todo_item_op("nope", op(index=0, expect="first", op="check")))
    assert e.value.status_code == 404


def test_editing_an_item_repoints_the_workspace_seeded_from_it(seeded):
    main, proj, ws, _ = seeded
    run(main.todo_item_op(proj.id, op(index=2, expect="third", op="edit", body="third, reworded")))
    assert ws.seed_key == "backlog/plan.md::third, reworded"


def test_moving_an_item_to_another_file_repoints_its_workspace(seeded):
    main, proj, ws, _ = seeded
    run(main.todo_item_op(proj.id, op(index=2, expect="third", op="move", to_file="backlog/other.md")))
    assert ws.seed_key == "backlog/other.md::third"


def test_renaming_a_file_repoints_its_workspaces(seeded):
    main, proj, ws, repo = seeded
    run(main.rename_todo_file(proj.id, TodoRenameRequest(path="backlog/plan.md", new_path="backlog/roadmap.md")))
    assert ws.seed_key == "backlog/roadmap.md::third"
    assert (repo / "backlog/roadmap.md").exists() and not (repo / "backlog/plan.md").exists()


# -- sub-items: a parent travels with its children ----------------------------------------

NESTED = """# P

- [ ] A
  - [ ] A1
  - [ ] A2
- [ ] B
  - [ ] B1
- [ ] C
"""


def test_nesting_is_reported_on_each_item():
    items = backlog.parse_todo(NESTED)
    assert [(i["text"], i["depth"], i["children"]) for i in items] == [
        ("A", 0, 2), ("A1", 1, 0), ("A2", 1, 0), ("B", 0, 1), ("B1", 1, 0), ("C", 0, 0),
    ]


def test_a_heading_ends_the_family():
    doc = "- [ ] A\n## Next\n  - [ ] X\n"
    assert [i["children"] for i in backlog.parse_todo(doc)] == [0, 0]


def test_blank_lines_do_not_end_the_family():
    doc = "- [ ] A\n\n  - [ ] A1\n"
    assert [i["children"] for i in backlog.parse_todo(doc)] == [1, 0]


def test_deleting_a_parent_takes_its_children_and_a_child_only_itself():
    assert texts(backlog.delete_item(NESTED, 0, "A")) == ["B", "B1", "C"]
    assert texts(backlog.delete_item(NESTED, 1, "A1")) == ["A", "A2", "B", "B1", "C"]


def test_moving_a_parent_moves_its_children_with_it():
    assert texts(backlog.move_item(NESTED, 3, "B", -1)) == ["B", "B1", "A", "A1", "A2", "C"]
    assert texts(backlog.move_item(NESTED, 0, "A", 1)) == ["B", "B1", "A", "A1", "A2", "C"]
    assert texts(backlog.move_item(NESTED, 3, "B", 1)) == ["A", "A1", "A2", "C", "B", "B1"]


def test_a_child_moves_only_among_its_siblings():
    assert texts(backlog.move_item(NESTED, 1, "A1", 1)) == ["A", "A2", "A1", "B", "B1", "C"]
    assert backlog.move_item(NESTED, 1, "A1", -1) == NESTED  # first child: no sibling above
    assert backlog.move_item(NESTED, 2, "A2", 1) == NESTED  # last child: B is not a sibling
    assert backlog.move_item(NESTED, 4, "B1", -1) == NESTED


def test_the_indent_survives_a_move():
    out = backlog.move_item(NESTED, 3, "B", -1)
    assert "- [ ] B\n  - [ ] B1\n- [ ] A\n  - [ ] A1" in out


def test_moving_a_parent_to_another_file_takes_the_family_dedented(tmp_path):
    repo = make_repo(tmp_path, NESTED)
    backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 0, "A", to_rel="backlog/other.md")
    assert (repo / "backlog/other.md").read_text() == "# Other\n\n- [ ] A\n  - [ ] A1\n  - [ ] A2\n"
    assert texts((repo / "backlog/plan.md").read_text()) == ["B", "B1", "C"]


def test_moving_a_nested_item_to_another_file_dedents_it(tmp_path):
    repo = make_repo(tmp_path, NESTED)
    backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 1, "A1", to_rel="backlog/other.md")
    assert (repo / "backlog/other.md").read_text().endswith("- [ ] A1\n")


def test_quick_capture_files_into_the_inbox(seeded):
    from haro.models import TodoItemAppendRequest

    main, proj, _, repo = seeded
    run(main.add_todo_item(proj.id, TodoItemAppendRequest(title="look at the flaky gate", inbox=True)))
    assert (repo / "backlog/inbox.md").read_text() == "# Inbox\n\n- [ ] look at the flaky gate\n"
    run(main.add_todo_item(proj.id, TodoItemAppendRequest(title="second", inbox=True)))
    assert texts((repo / "backlog/inbox.md").read_text()) == ["look at the flaky gate", "second"]


def test_a_child_never_leaves_its_parent_across_a_heading():
    doc = "- [ ] A\n  - [ ] a1\n## H\n  - [ ] c\n"
    assert backlog.move_item(doc, 1, "a1", 1) == doc
    assert backlog.move_item(doc, 2, "c", -1) == doc


def test_tab_indented_children_belong_to_a_two_space_parent():
    doc = "  - [ ] A\n\t- [ ] a1\n  - [ ] B\n"
    items = backlog.parse_todo(doc)
    assert items[0]["children"] == 1 and items[1]["depth"] == 1
    assert texts(backlog.delete_item(doc, 0, "A")) == ["B"]


def test_a_moved_family_has_lf_endings_even_from_a_crlf_file(tmp_path):
    repo = make_repo(tmp_path, "- [ ] A\r\n  - [ ] a1\r\n- [ ] B\r\n")
    backlog.apply_item_op(str(repo), "backlog/plan.md", "move", 0, "A", to_rel="backlog/other.md")
    moved = (repo / "backlog/other.md").read_bytes()
    assert b"\r" not in moved and b"- [ ] A\n  - [ ] a1\n" in moved
