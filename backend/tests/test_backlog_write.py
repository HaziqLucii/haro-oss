"""Tests for the backlog write path (``haro.backlog``) — the in-app create/edit
endpoint's guts. Guards the two things that matter: a write only ever lands on a
backlog-eligible path, and it can never escape the project root (traversal / absolute
/ symlink-out)."""

import pytest

from haro import backlog


# ── is_backlog_path: what counts as an editable backlog doc ─────────────────────
@pytest.mark.parametrize(
    "rel,ok",
    [
        ("backlog/gate.md", True),       # under the backlog dir, any name
        ("backlog/notes/ui.md", True),   # nested under the backlog dir
        ("TODO.md", True),               # legacy: name contains 'todo'
        ("docs/todo.txt", True),         # todo-named, doc ext, anywhere
        ("backlog/logo.png", False),     # under dir but not a doc extension
        ("src/main.py", False),          # neither rule
        ("README.md", False),            # doc ext but not backlog
        ("", False),
    ],
)
def test_is_backlog_path(rel, ok):
    assert backlog.is_backlog_path(rel, "backlog") is ok


def test_is_backlog_path_custom_dir():
    assert backlog.is_backlog_path("tasks/x.md", "tasks") is True
    assert backlog.is_backlog_path("backlog/x.md", "tasks") is False  # dir doesn't match


# ── is_backlog_path: additive [backlog] files globs ──────────────────────────────
def test_is_backlog_path_extra_globs():
    globs = ["ROADMAP.md", "docs/backlog*"]
    assert backlog.is_backlog_path("ROADMAP.md", "backlog", globs) is True
    assert backlog.is_backlog_path("docs/backlog-notes.md", "backlog", globs) is True
    assert backlog.is_backlog_path("ROADMAP.md", "backlog") is False  # no globs passed
    assert backlog.is_backlog_path("docs/other.md", "backlog", globs) is False
    # extension guard still applies even to a matching glob
    assert backlog.is_backlog_path("docs/backlog.png", "backlog", ["docs/backlog*"]) is False


# ── write_todo: happy path + creation ───────────────────────────────────────────
def test_write_creates_file_and_folder(tmp_path):
    rel = backlog.write_todo(str(tmp_path), "backlog/feature.md", "# F\n\n- [ ] do it")
    assert rel == "backlog/feature.md"
    f = tmp_path / "backlog" / "feature.md"
    assert f.exists()
    assert f.read_text().endswith("\n")  # trailing newline ensured
    assert "- [ ] do it" in f.read_text()


def test_write_overwrites_existing(tmp_path):
    (tmp_path / "TODO.md").write_text("old\n")
    backlog.write_todo(str(tmp_path), "TODO.md", "new content\n")
    assert (tmp_path / "TODO.md").read_text() == "new content\n"


# ── write_todo: guards ──────────────────────────────────────────────────────────
def test_write_rejects_non_backlog_path(tmp_path):
    with pytest.raises(backlog.BacklogError):
        backlog.write_todo(str(tmp_path), "src/main.py", "x")
    assert not (tmp_path / "src").exists()  # nothing written


def test_write_rejects_traversal(tmp_path):
    with pytest.raises(backlog.BacklogError):
        backlog.write_todo(str(tmp_path), "../escape.md", "x")


def test_write_rejects_absolute(tmp_path):
    with pytest.raises(backlog.BacklogError):
        backlog.write_todo(str(tmp_path), "/etc/todo.md", "x")


def test_write_respects_custom_backlog_dir(tmp_path):
    rel = backlog.write_todo(str(tmp_path), "tasks/x.md", "- [ ] y", backlog_dir="tasks")
    assert rel == "tasks/x.md"
    assert (tmp_path / "tasks" / "x.md").exists()
    # a path under the default `backlog/` is NOT eligible when the dir is `tasks`
    with pytest.raises(backlog.BacklogError):
        backlog.write_todo(str(tmp_path), "backlog/x.md", "z", backlog_dir="tasks")


def test_write_respects_extra_globs(tmp_path):
    rel = backlog.write_todo(
        str(tmp_path), "ROADMAP.md", "- [ ] y", extra_globs=["ROADMAP.md"]
    )
    assert rel == "ROADMAP.md"
    assert (tmp_path / "ROADMAP.md").exists()
    with pytest.raises(backlog.BacklogError):
        backlog.write_todo(str(tmp_path), "ROADMAP.md", "z")  # no glob configured


# ── append_item: the gate's "send to backlog" outlet (Move 3) ───────────────────
def test_append_item_creates_the_file_with_a_heading(tmp_path):
    rel = backlog.append_item(
        str(tmp_path), "backlog/follow-ups.md", "Untested: src/pricing.ts:41-58",
        "ws: pricing-rounding",
    )
    assert rel == "backlog/follow-ups.md"
    text = (tmp_path / "backlog" / "follow-ups.md").read_text()
    assert text == (
        "# Follow Ups\n\n"
        "- [ ] Untested: src/pricing.ts:41-58 (ws: pricing-rounding)\n"
    )


def test_append_item_appends_to_an_existing_file_without_a_heading(tmp_path):
    (tmp_path / "backlog").mkdir()
    f = tmp_path / "backlog" / "follow-ups.md"
    f.write_text("# Follow Ups\n\n- [ ] first one\n")
    backlog.append_item(str(tmp_path), "backlog/follow-ups.md", "second one")
    assert f.read_text() == "# Follow Ups\n\n- [ ] first one\n- [ ] second one\n"


def test_append_item_omits_the_parenthetical_when_evidence_is_empty(tmp_path):
    backlog.append_item(str(tmp_path), "backlog/follow-ups.md", "just a title")
    text = (tmp_path / "backlog" / "follow-ups.md").read_text()
    assert "just a title\n" in text
    assert "(" not in text.split("\n\n", 1)[1]


def test_append_item_collapses_embedded_newlines_to_one_line(tmp_path):
    backlog.append_item(str(tmp_path), "backlog/follow-ups.md", "line one\nline two", "e1\ne2")
    text = (tmp_path / "backlog" / "follow-ups.md").read_text()
    assert text.count("- [ ]") == 1  # one item, not split across lines
    assert "line one line two (e1 e2)" in text


def test_append_item_rejects_a_non_backlog_path(tmp_path):
    with pytest.raises(backlog.BacklogError):
        backlog.append_item(str(tmp_path), "src/main.py", "x")
    assert not (tmp_path / "src").exists()


def test_append_item_rejects_traversal(tmp_path):
    with pytest.raises(backlog.BacklogError):
        backlog.append_item(str(tmp_path), "../escape.md", "x")
