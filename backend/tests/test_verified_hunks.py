"""Verified Hunks, the pure engine (backlog/verified-hunks.md §2).

The load-bearing assertions here are all about *not overclaiming*. This engine's whole
value is that a reviewer can believe it, so the tests care less about counting correctly
(easy) than about the four ways a per-line badge could lie:

  1. a line whose evidence has shifted underneath it (the stale case),
  2. a non-coverable line being called untested,
  3. a language or subtree the runner never instrumented being called untested,
  4. a missing coverage provider reading as "nothing was executed".
"""

from __future__ import annotations

from haro.verified_hunks import annotate

# Four added lines in one file. Lines 1 + 2 ran, line 3 never ran, line 4 is a comment
# and so is absent from the statement map entirely.
DIFF = (
    "diff --git a/src/math.ts b/src/math.ts\n"
    "--- a/src/math.ts\n"
    "+++ b/src/math.ts\n"
    "@@ -0,0 +1,4 @@\n"
    "+export const add = (a: number, b: number) => a + b\n"
    "+export const sub = (a: number, b: number) => a - b\n"
    "+export const wild = () => { throw new Error('never called') }\n"
    "+// a trailing comment\n"
)

HITS = {"src/math.ts": {1: 3, 2: 1, 3: 0}}


def _by_path(report):
    return {f.path: f for f in report.files}


def test_lines_split_into_executed_never_executed_and_non_coverable():
    report = annotate(DIFF, DIFF, HITS)
    f = _by_path(report)["src/math.ts"]
    assert (f.added, f.executed, f.unexecuted, f.noncoverable) == (4, 2, 1, 1)
    assert f.lines == {1: 3, 2: 1, 3: 0, 4: None}
    assert not f.stale and f.in_map


def test_a_comment_line_is_never_counted_as_untested():
    """The rule that keeps the signal usable: 'add a test for your comment' is the kind of
    row that gets a whole feature switched off."""
    f = _by_path(annotate(DIFF, DIFF, HITS))["src/math.ts"]
    assert f.lines[4] is None
    assert f.noncoverable == 1
    assert f.unexecuted == 1  # line 3 only — the comment is not in this number


def test_a_file_that_moved_since_the_gate_ran_carries_no_line_data():
    """THE honesty test. Agent edits are uncommitted, so a line can be inserted without
    HEAD moving; reusing the old map would paint 'executed' on code the suite never saw."""
    edited = DIFF.replace(
        "+export const add = (a: number, b: number) => a + b\n",
        "+export const add = (a: number, b: number) => a + b\n+export const sneaky = () => 1\n",
    )
    report = annotate(DIFF, edited, HITS)
    f = _by_path(report)["src/math.ts"]
    assert f.stale
    assert f.lines == {}, "a stale file must make no per-line claim at all"
    assert (f.executed, f.unexecuted) == (0, 0)
    assert report.stale
    assert "changed since the gate ran" in (report.note or "")


def test_a_file_absent_from_the_map_reports_at_file_level_only():
    """Nothing imports it ⇒ nothing in it ran (true), but with no statementMap we cannot
    say which of its lines were even coverable — so no per-line dots are invented."""
    report = annotate(DIFF, DIFF, {"src/other.ts": {1: 1}})
    f = _by_path(report)["src/math.ts"]
    assert not f.in_map
    assert (f.added, f.unexecuted, f.executed) == (4, 4, 0)
    assert f.lines == {}


def test_a_language_the_runner_never_instrumented_is_absent_not_untested():
    """A vitest coverage map has nothing to say about Python either way. Reporting it would
    be crying wolf across a language boundary (the false positive unchecked.py hit first)."""
    py_diff = (
        "diff --git a/backend/haro/gate.py b/backend/haro/gate.py\n"
        "--- a/backend/haro/gate.py\n"
        "+++ b/backend/haro/gate.py\n"
        "@@ -0,0 +1,3 @@\n"
        "+def a():\n"
        "+    return 1\n"
        "+# done\n"
    )
    report = annotate(py_diff, py_diff, HITS)
    assert report.files == []


def test_a_sibling_package_outside_the_gate_subtree_is_absent():
    """In a monorepo the runner only sees its own subtree, so a sibling's .ts shares the
    extension while being genuinely out of reach."""
    other = DIFF.replace("src/math.ts", "packages/api/src/math.ts")
    report = annotate(other, other, {"frontend/src/x.ts": {1: 1}}, scope="frontend")
    assert report.files == []


def test_no_coverage_provider_yields_an_empty_report_not_an_all_untested_one():
    assert annotate(DIFF, DIFF, None).files == []
    assert annotate(DIFF, DIFF, {}).files == []


def test_a_test_file_is_not_annotated():
    """Test files ARE the checking; badging them would invite 'cover your coverage'."""
    t = DIFF.replace("src/math.ts", "src/math.test.ts")
    report = annotate(t, t, {"src/math.test.ts": {1: 1}})
    assert report.files == []


def test_the_note_leads_with_executed_and_never_says_verified():
    report = annotate(DIFF, DIFF, HITS)
    assert report.note == "2 of 4 added lines executed · 1 never executed"
    lowered = (report.note or "").lower()
    assert "verif" not in lowered and "proven" not in lowered and "correct" not in lowered


def test_a_malformed_diff_is_silent_rather_than_alarming():
    assert annotate("", "", HITS).files == []
    assert annotate("not a diff at all", "not a diff at all", HITS).files == []
