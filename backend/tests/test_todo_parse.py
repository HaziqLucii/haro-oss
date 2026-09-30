"""Parser tests for the backlog (``main._parse_todo``).

Guards the two shapes the backlog UI + click-to-workspace flow depend on:
``text`` is the compact one-paragraph view (continuation folded, code stripped)
that drives the checklist display and the short branch name; ``body`` is the
full item (continuation + fenced code, dedented) seeded as the agent's brief.
Regression cover for wrapped items rendering cut-off and for a "see this
example:" item losing its code block on the way to the agent.
"""

from haro.main import _parse_todo, _parse_todo_doc


def test_wrapped_item_folds_into_text():
    md = """\
## Group
- [ ] Short title — first line of detail
      wraps onto a second line
      and a third.
"""
    (item,) = _parse_todo(md)
    assert item["heading"] == "Group"
    assert item["done"] is False
    # continuation lines are folded into one paragraph, not truncated at line 1
    assert item["text"] == (
        "Short title — first line of detail wraps onto a second line and a third."
    )


def test_done_marker():
    (item,) = _parse_todo("- [x] finished thing\n")
    assert item["done"] is True
    assert item["text"] == "finished thing"


def test_fenced_code_stays_out_of_text_but_lands_in_body():
    md = """\
- [ ] Add a config example:
      ```toml
      [gate]
      runner = "command"
      ```
"""
    (item,) = _parse_todo(md)
    # compact display line has no code fence noise
    assert item["text"] == "Add a config example:"
    assert "```" not in item["text"]
    # the agent brief keeps the whole example, dedented, fences intact
    assert item["body"] == (
        'Add a config example:\n```toml\n[gate]\nrunner = "command"\n```'
    )


def test_body_defaults_to_text_when_single_line():
    (item,) = _parse_todo("- [ ] just one line\n")
    assert item["text"] == "just one line"
    assert item["body"] == "just one line"


def test_heading_and_blank_line_end_an_item():
    md = """\
- [ ] item one
      continued
- [ ] item two
"""
    a, b = _parse_todo(md)
    assert a["text"] == "item one continued"
    assert b["text"] == "item two"


# ── _parse_todo_doc: notes + items interleaved in document order ────────────────
def test_doc_keeps_notes_around_items_in_order():
    md = """\
# Gate rework

Some context about why. Not a task.

## Tasks
- [ ] Split the runner — extract the vitest path
- [ ] Wire the impact map
"""
    blocks = _parse_todo_doc(md)
    kinds = [b["kind"] for b in blocks]
    # consecutive non-item lines (heading + prose + "## Tasks") merge into ONE note
    # block, then the two items — notes rendered before the tasks they precede.
    assert kinds == ["note", "item", "item"]
    assert "# Gate rework" in blocks[0]["md"]
    assert "Some context about why" in blocks[0]["md"]
    assert "## Tasks" in blocks[0]["md"]
    assert blocks[1]["text"] == "Split the runner — extract the vitest path"
    assert blocks[2]["text"] == "Wire the impact map"


def test_doc_headings_interleave_when_items_sit_between():
    # The key guarantee: a heading that follows an item starts a fresh note block,
    # so per-section headings render in place instead of collapsing together.
    md = "## Section A\n- [ ] t1\n## Section B\n- [ ] t2\n"
    blocks = _parse_todo_doc(md)
    assert [b["kind"] for b in blocks] == ["note", "item", "note", "item"]
    assert blocks[2]["md"].strip() == "## Section B"


def test_doc_notes_only_file_has_no_items():
    md = "# Just notes\n\nNo checklist here, only prose.\n"
    blocks = _parse_todo_doc(md)
    assert [b["kind"] for b in blocks] == ["note"]
    assert _parse_todo(md) == []  # the items-only wrapper sees nothing seedable


def test_doc_note_between_two_items():
    md = """\
- [ ] first task

A note explaining the second.

- [x] second task
"""
    blocks = _parse_todo_doc(md)
    assert [b["kind"] for b in blocks] == ["item", "note", "item"]
    assert blocks[1]["md"].strip() == "A note explaining the second."
    assert blocks[2]["done"] is True


def test_doc_item_blocks_match_parse_todo():
    md = "# H\n\nnote\n\n- [ ] a — x\n      wraps\n- [x] b\n"
    items_from_doc = [b for b in _parse_todo_doc(md) if b["kind"] == "item"]
    assert items_from_doc == _parse_todo(md)  # wrapper is a pure filter over the doc
