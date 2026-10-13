"""Wikilinks, tags and backlinks between notes (notes_links.py), and what a rename rewrites."""

from __future__ import annotations

import asyncio

import pytest

from haro import notes, notes_links
from haro.models import NoteRenameRequest, Project

from test_notes import proj  # noqa: F401  (fixture: main, project, tmp_path)
from test_quiescence import clean_store  # noqa: F401  (the fixture `proj` uses)


def run(coro):
    return asyncio.run(coro)


def put(root, rel, text):
    notes.write_note(str(root), rel, text)


# --------------------------------------------------------------------------- #
# parsing
# --------------------------------------------------------------------------- #
def test_wikilinks_with_heading_and_alias_and_a_path():
    links, _ = notes_links.parse("see [[Cache ideas]], [[design/api#auth|the auth part]] and [[x.md]]")
    assert [(l.target, l.anchor, l.alias) for l in links] == [
        ("Cache ideas", None, None),
        ("design/api", "auth", "the auth part"),
        ("x.md", None, None),
    ]


def test_code_is_never_scanned_but_offsets_survive():
    text = "```\n[[in fence]] #fence\n```\nand `[[inline]] #inline` then [[real]] #real"
    links, tags = notes_links.parse(text)
    assert [l.target for l in links] == ["real"]
    assert tags == ["real"]
    l = links[0]
    assert text[l.start : l.end] == "[[real]]"


def test_tags_are_words_not_headings_numbers_urls_or_anchors():
    _, tags = notes_links.parse(
        "# Title\n\n## Sub\n#ui #perf/db #ui-polish\nissue #123 and https://x.dev/#frag, [a](#anchor), a#b"
    )
    assert tags == ["ui", "perf/db", "ui-polish"]


def test_a_first_line_tag_is_not_the_title():
    assert notes._title("#idea\n\nsome text", "fallback") == "fallback"
    assert notes._title("\n# Real title #\n#tag", "fallback") == "Real title"


# --------------------------------------------------------------------------- #
# resolving
# --------------------------------------------------------------------------- #
def test_a_target_resolves_as_path_then_file_name_then_title():
    idx = notes_links.Index({"design/api.md": "API sketch", "api.md": "Public API", "cache.md": "Cache"})
    assert idx.resolve("design/api") == ("design/api.md", "path", False)
    assert idx.resolve("API.md") == ("api.md", "path", False)
    assert idx.resolve("cache") == ("cache.md", "path", False)  # a top-level note: path and name agree
    assert notes_links.Index({"design/only.md": "Only"}).resolve("only") == ("design/only.md", "stem", False)
    assert idx.resolve("API sketch") == ("design/api.md", "title", False)
    assert idx.resolve("nope") == (None, "none", False)


def test_a_shared_file_name_resolves_to_the_first_path_and_says_so():
    idx = notes_links.Index({"b/idea.md": "B", "a/idea.md": "A"})
    assert idx.resolve("idea") == ("a/idea.md", "stem", True)
    assert idx.resolve("b/idea") == ("b/idea.md", "path", False)


# --------------------------------------------------------------------------- #
# backlinks and mentions
# --------------------------------------------------------------------------- #
def test_backlinks_mentions_and_outgoing_for_a_note(tmp_path):
    put(tmp_path, "cache.md", "# Cache design\n\nplan #perf\nsee [[missing note]]")
    put(tmp_path, "a.md", "# A\n\nwe use [[cache]] a lot")
    put(tmp_path, "b.md", "# B\n\nrevisit the Cache design someday")
    put(tmp_path, "c.md", "# C\n\n```\n[[cache]] Cache design\n```")
    out = notes_links.links_for(str(tmp_path), "cache.md")
    assert out["tags"] == ["perf"]
    assert [o["target"] for o in out["outgoing"]] == ["missing note"]
    assert out["outgoing"][0]["path"] is None
    assert [b["path"] for b in out["backlinks"]] == ["a.md"]
    assert out["backlinks"][0]["snippet"] == "we use [[cache]] a lot"
    assert [m["path"] for m in out["mentions"]] == ["b.md"]  # not a.md (linked), not c.md (code)


def test_a_missing_note_is_a_note_error(tmp_path):
    with pytest.raises(notes.NoteError, match="does not exist"):
        notes_links.links_for(str(tmp_path), "nope.md")


def test_the_route_reads_links(proj):  # noqa: F811
    main, p, root = proj
    put(root, "x.md", "# X\n\n[[y]]")
    put(root, "y.md", "# Y")
    out = run(main.get_note_links(p.id, "y.md"))
    assert [b["path"] for b in out["backlinks"]] == ["x.md"]


# --------------------------------------------------------------------------- #
# rename rewrites
# --------------------------------------------------------------------------- #
def test_rename_rewrites_links_by_name_and_keeps_heading_and_alias(proj):  # noqa: F811
    main, p, root = proj
    put(root, "old-name.md", "# Old name\n\nbody")
    put(root, "a.md", "see [[old-name]] and [[old-name#part|the part]] and [[old-name.md]]")
    put(root, "b.md", "by title: [[Old name]]\n```\n[[old-name]]\n```")
    out = run(main.rename_project_note(p.id, NoteRenameRequest(path="old-name.md", new_path="new-name.md")))
    assert out["path"] == "new-name.md"
    assert out["rewritten"] == ["a.md"]
    a = notes.read_note(str(root), "a.md")["content"]
    assert a == "see [[new-name]] and [[new-name#part|the part]] and [[new-name]]"
    b = notes.read_note(str(root), "b.md")["content"]
    assert "[[Old name]]" in b and "```\n[[old-name]]\n```" in b  # a title link and code stay


def test_a_move_into_a_folder_rewrites_to_the_stem_when_it_is_unique(proj):  # noqa: F811
    main, p, root = proj
    put(root, "idea.md", "# Idea")
    put(root, "a.md", "[[idea]]")
    out = run(main.rename_project_note(p.id, NoteRenameRequest(path="idea.md", new_path="ideas/idea.md")))
    assert out["rewritten"] == []  # the stem is unchanged and still resolves
    assert notes.read_note(str(root), "a.md")["content"] == "[[idea]]"


def test_a_name_that_becomes_ambiguous_is_written_as_a_path(proj):  # noqa: F811
    main, p, root = proj
    put(root, "tmp.md", "# T")
    put(root, "sub/plan.md", "# Existing plan")
    put(root, "a.md", "[[tmp]]")
    run(main.rename_project_note(p.id, NoteRenameRequest(path="tmp.md", new_path="x/plan.md")))
    # `plan` now names two notes (x/plan.md and sub/plan.md): the rewrite names the path instead.
    assert notes.read_note(str(root), "a.md")["content"] == "[[x/plan]]"


def test_a_note_edited_since_the_plan_is_left_alone(tmp_path):
    put(tmp_path, "t.md", "# T")
    put(tmp_path, "a.md", "[[t]]")
    plan = notes_links.plan_rename(str(tmp_path), "t.md", "u.md")
    notes.write_note(str(tmp_path), "a.md", "[[t]] edited meanwhile")
    assert notes_links.apply_plan(str(tmp_path), plan) == ([], ["a.md"])
    assert notes.read_note(str(tmp_path), "a.md")["content"] == "[[t]] edited meanwhile"


# --------------------------------------------------------------------------- #
# review fixes
# --------------------------------------------------------------------------- #
def test_masking_is_linear_on_a_long_run_of_backticks():
    import time

    t0 = time.perf_counter()
    notes_links.mask_code("x" + "`" * 20000 + "\n" + "a `b` [[c]]\n" * 5000)
    assert time.perf_counter() - t0 < 1.0


def test_inline_code_spans_close_on_a_run_of_the_same_length():
    masked = notes_links.mask_code("``a ` [[x]] ``  [[y]]  `z")
    assert "[[x]]" not in masked and "[[y]]" in masked


def test_fences_match_their_own_marker_and_an_inline_triple_is_not_one():
    text = "```x``` [[a]]\n```\n[[b]]\n```\n[[c]]\n~~~\n```\n[[d]]\n~~~\n[[e]]"
    links, _ = notes_links.parse(text)
    assert [l.target for l in links] == ["a", "c", "e"]
    indented = notes_links.parse("    ```\n[[a]]")[0]  # four spaces: code, not a fence
    assert [l.target for l in indented] == ["a"]


def test_unicode_tags_and_title_with_a_trailing_hash():
    assert notes_links.parse("#naïve #日本語 é#no")[1] == ["naïve", "日本語"]
    assert notes._title("# C#\n", "x") == "C#"
    assert notes._title("# Title ##\n", "x") == "Title"


def test_a_new_name_that_would_hijack_a_link_pins_it_to_the_note_it_meant(proj):  # noqa: F811
    main, p, root = proj
    put(root, "tmp.md", "# T")
    put(root, "sub/plan.md", "# Existing plan")
    put(root, "a.md", "see [[plan]] and [[plan#x|y]]")
    out = run(main.rename_project_note(p.id, NoteRenameRequest(path="tmp.md", new_path="plan.md")))
    assert out["rewritten"] == ["a.md"]
    assert notes.read_note(str(root), "a.md")["content"] == "see [[sub/plan]] and [[sub/plan#x|y]]"
    # and the link still reaches the same note
    assert notes_links.links_for(str(root), "sub/plan.md")["backlinks"][0]["path"] == "a.md"


def test_a_title_link_a_new_name_beats_is_pinned_too(proj):  # noqa: F811
    main, p, root = proj
    put(root, "tmp.md", "# T")
    put(root, "sub/x.md", "# Cache")
    put(root, "a.md", "[[Cache]]")
    run(main.rename_project_note(p.id, NoteRenameRequest(path="tmp.md", new_path="cache.md")))
    assert notes.read_note(str(root), "a.md")["content"] == "[[sub/x]]"


def test_the_renamed_note_keeps_its_own_links_pointing_at_itself(proj):  # noqa: F811
    main, p, root = proj
    put(root, "old-name.md", "# Old name\n\nsee [[old-name]] and `[[old-name]]`")
    out = run(main.rename_project_note(p.id, NoteRenameRequest(path="old-name.md", new_path="new-name.md")))
    assert out["rewritten"] == ["new-name.md"]
    assert notes.read_note(str(root), "new-name.md")["content"] == "# Old name\n\nsee [[new-name]] and `[[old-name]]`"


def test_a_note_that_is_not_utf8_is_never_rewritten(proj):  # noqa: F811
    main, p, root = proj
    put(root, "t.md", "# T")
    (root / ".haro" / "notes").mkdir(parents=True, exist_ok=True)
    raw = b"[[t]] \xff\xfe bytes"
    (root / ".haro" / "notes" / "b.md").write_bytes(raw)
    out = run(main.rename_project_note(p.id, NoteRenameRequest(path="t.md", new_path="u.md")))
    assert out["rewritten"] == []
    assert (root / ".haro" / "notes" / "b.md").read_bytes() == raw


def test_a_case_only_rename_rewrites_nothing(proj):  # noqa: F811
    main, p, root = proj
    put(root, "Idea.md", "# Idea")
    put(root, "a.md", "[[Idea]]")
    out = run(main.rename_project_note(p.id, NoteRenameRequest(path="Idea.md", new_path="idea.md")))
    assert out["rewritten"] == [] and out["skipped"] == []
    assert notes.read_note(str(root), "a.md")["content"] == "[[Idea]]"
