from difflib import SequenceMatcher

from haro.adapters.test_runner.base import TestRef as Ref  # aliased: avoids pytest collecting the class
from haro.tamper import (
    _FUZZY_THRESHOLD,
    TamperFinding,
    _similar,
    added_modifiers,
    added_tests,
    analyze,
    assertion_deltas,
    config_tamper,
    is_test_file,
    pair_removals,
    parse_file_diffs,
    reconcile,
    removed_tests,
    rename_map,
    snapshot_churn,
    summarize,
)


def _ref(file, name):
    return Ref(file=file, name=name)


# --- diff parsing -------------------------------------------------------------

def test_parse_file_diffs_reads_content_change():
    diff = """diff --git a/src/math.test.ts b/src/math.test.ts
index 111..222 100644
--- a/src/math.test.ts
+++ b/src/math.test.ts
@@ -1,3 +1,2 @@
 it('adds', () => {
-  expect(add(1, 2)).toBe(3);
 });
"""
    fds = parse_file_diffs(diff)
    assert len(fds) == 1
    assert fds[0].old_path == fds[0].new_path == "src/math.test.ts"
    assert fds[0].removed == ["  expect(add(1, 2)).toBe(3);"]
    assert fds[0].added == []


def test_parse_file_diffs_reads_rename_headers():
    diff = """diff --git a/src/old.test.ts b/src/new.test.ts
similarity index 100%
rename from src/old.test.ts
rename to src/new.test.ts
"""
    fds = parse_file_diffs(diff)
    assert fds[0].is_rename
    assert rename_map(fds) == {"src/old.test.ts": "src/new.test.ts"}


def test_is_test_file():
    assert is_test_file("src/math.test.ts")
    assert is_test_file("src/math.spec.tsx")
    assert is_test_file("src/__tests__/math.ts")
    assert not is_test_file("src/math.ts")
    assert not is_test_file(None)


# --- removed / rename-aware matching (the make-or-break) ----------------------

def test_removed_counts_a_genuinely_deleted_test():
    base = [_ref("a.test.ts", "adds"), _ref("a.test.ts", "subtracts")]
    wt = [_ref("a.test.ts", "adds")]
    findings = removed_tests(base, wt, {})
    assert [(f.kind, f.file, f.test) for f in findings] == [("removed", "a.test.ts", "subtracts")]


def test_rename_of_test_file_yields_zero_removed():
    # the classic legit refactor: file renamed, every test kept
    base = [_ref("old.test.ts", "adds"), _ref("old.test.ts", "subtracts")]
    wt = [_ref("new.test.ts", "adds"), _ref("new.test.ts", "subtracts")]
    renames = {"old.test.ts": "new.test.ts"}
    assert removed_tests(base, wt, renames) == []


def test_consolidation_move_without_git_rename_yields_zero_removed():
    # two files merged into one; git didn't flag a rename — same-name tier catches it
    base = [_ref("a.test.ts", "adds"), _ref("b.test.ts", "subtracts")]
    wt = [_ref("merged.test.ts", "adds"), _ref("merged.test.ts", "subtracts")]
    assert removed_tests(base, wt, {}) == []


def test_in_place_retitle_yields_zero_removed():
    # a test renamed in place — fuzzy same-file match suppresses the alarm
    base = [_ref("a.test.ts", "adds two numbers")]
    wt = [_ref("a.test.ts", "adds 2 numbers")]
    assert removed_tests(base, wt, {}) == []


def test_delete_still_counts_even_when_an_unrelated_test_is_added():
    base = [_ref("a.test.ts", "adds"), _ref("a.test.ts", "subtracts")]
    wt = [_ref("a.test.ts", "adds"), _ref("b.test.ts", "totally unrelated behaviour")]
    findings = removed_tests(base, wt, {})
    assert [f.test for f in findings] == ["subtracts"]


# --- modifiers ----------------------------------------------------------------

def test_added_skip_and_only_are_flagged_with_titles():
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,2 +1,2 @@
-it('adds', () => {});
+it.skip('adds', () => {});
+describe.only('suite', () => {});
"""
    findings = added_modifiers(parse_file_diffs(diff))
    kinds = {(f.kind, f.test) for f in findings}
    assert ("skip", "adds") in kinds
    assert ("only", "suite") in kinds


def test_reindented_existing_skip_nets_to_zero():
    # same .skip removed and re-added (a reformat) must not fire
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,2 +1,2 @@
-  it.skip('adds', () => {});
+    it.skip('adds', () => {});
"""
    assert added_modifiers(parse_file_diffs(diff)) == []


def test_modifiers_ignored_in_non_test_files():
    diff = """diff --git a/src/app.ts b/src/app.ts
--- a/src/app.ts
+++ b/src/app.ts
@@ -1 +1 @@
+const x = describe.only;
"""
    assert added_modifiers(parse_file_diffs(diff)) == []


# --- assertions ---------------------------------------------------------------

def test_assertion_delta_reports_net_negative_only():
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,4 +1,2 @@
 it('adds', () => {
-  expect(add(1, 2)).toBe(3);
-  expect(add(2, 2)).toBe(4);
+  expect(add(1, 2)).toBe(3);
 });
"""
    findings = assertion_deltas(parse_file_diffs(diff))
    assert len(findings) == 1
    assert findings[0].kind == "assertions"
    assert findings[0].detail == "1 fewer expect() call"


def test_assertion_delta_silent_when_assertions_added():
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,2 +1,3 @@
 it('adds', () => {
+  expect(add(1, 2)).toBe(3);
 });
"""
    assert assertion_deltas(parse_file_diffs(diff)) == []


# --- snapshots ----------------------------------------------------------------

def test_snapshot_churn_flagged_above_threshold():
    body = "\n".join(f"+line {i}" for i in range(12))
    diff = f"""diff --git a/__snapshots__/a.snap b/__snapshots__/a.snap
--- a/__snapshots__/a.snap
+++ b/__snapshots__/a.snap
@@ -1,12 +1,12 @@
{body}
"""
    finding = snapshot_churn(parse_file_diffs(diff))
    assert finding is not None
    assert finding.kind == "snapshot"
    assert finding.detail == "snapshots 100% of diff"


def test_snapshot_churn_ignored_when_diff_is_tiny():
    diff = """diff --git a/a.snap b/a.snap
--- a/a.snap
+++ b/a.snap
@@ -1 +1 @@
+one line
"""
    assert snapshot_churn(parse_file_diffs(diff)) is None


# --- reconciliation: one act of tampering = one finding -----------------------
# Every case here was observed live on the haro-test sandbox — `vitest list` reports
# what WOULD RUN, so a modifier both trips its own signal and vanishes from the
# inventory. See notes/e2e-gate-test-plan.md Phase 7.

def test_a_deleted_test_file_is_not_also_assertion_gutting():
    # The consolidation case: stats.test.js is deleted and its tests live on in
    # helpers.test.js. Losing every expect() in a vanished file is not a delta.
    diff = """diff --git a/stats.test.ts b/stats.test.ts
deleted file mode 100644
--- a/stats.test.ts
+++ /dev/null
@@ -1,3 +0,0 @@
-it('means', () => { expect(mean([2])).toBe(2); });
-it('medians', () => { expect(median([2])).toBe(2); });
"""
    assert assertion_deltas(parse_file_diffs(diff)) == []


def test_skip_absorbs_the_removal_it_caused():
    # `vitest list` omits a skipped test, so it disappears from the worktree
    # inventory: without reconciliation this reads "1 removed AND 1 skipped".
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1 +1 @@
-it('adds', () => { expect(add(1,1)).toBe(2); });
+it.skip('adds', () => { expect(add(1,1)).toBe(2); });
"""
    report = analyze(diff, [_ref("a.test.ts", "math > adds")], [])
    assert [f.kind for f in report.findings] == ["skip"]
    assert report.note == "1 skipped"


def test_describe_skip_absorbs_every_test_beneath_it():
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1 +1 @@
-describe('math', () => {
+describe.skip('math', () => {
"""
    base = [_ref("a.test.ts", "math > adds"), _ref("a.test.ts", "math > subtracts")]
    report = analyze(diff, base, [])
    assert [f.kind for f in report.findings] == ["skip"]
    assert report.findings[0].detail == ".skip added — 2 tests no longer run"


def test_only_absorbs_the_file_it_silenced_and_says_how_many():
    # `.only` is the quiet killer: the other tests in its file stop running, so they
    # vanish from the inventory. One finding, with the count in its detail.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1 +1 @@
-it('adds', () => {});
+it.only('adds', () => {});
"""
    base = [_ref("a.test.ts", f"math > t{i}") for i in range(4)] + [_ref("a.test.ts", "math > adds")]
    report = analyze(diff, base, [_ref("a.test.ts", "math > adds")])
    assert [f.kind for f in report.findings] == ["only"]
    assert report.findings[0].detail == ".only added — 4 other tests in this file no longer run"
    assert report.note == "1 .only"


def test_two_skips_in_one_file_each_own_their_absorbed_test():
    # Absorption is attributed per modifier, not per file — otherwise both rows would
    # claim "2 tests no longer run" for one skipped test each.
    removed = [
        TamperFinding(kind="removed", file="a.test.ts", test="math > adds", detail="test removed"),
        TamperFinding(kind="removed", file="a.test.ts", test="math > subs", detail="test removed"),
    ]
    modifiers = [
        TamperFinding(kind="skip", file="a.test.ts", test="adds", detail=".skip added"),
        TamperFinding(kind="skip", file="a.test.ts", test="subs", detail=".skip added"),
    ]
    out = reconcile(removed, modifiers, [])
    assert [f.kind for f in out] == ["skip", "skip"]
    assert [f.detail for f in out] == [".skip added", ".skip added"]


def test_reconcile_still_reports_a_removal_no_modifier_explains():
    # The guard on the guard: absorbing must not swallow a real deletion that happens
    # to share a file with a skip.
    removed = [
        TamperFinding(kind="removed", file="a.test.ts", test="math > gone", detail="test removed"),
        TamperFinding(kind="removed", file="a.test.ts", test="math > adds", detail="test removed"),
    ]
    modifiers = [TamperFinding(kind="skip", file="a.test.ts", test="adds", detail=".skip added")]
    kinds = sorted(f.kind for f in reconcile(removed, modifiers, []))
    assert kinds == ["removed", "skip"]


def test_silent_assertion_gutting_still_reported():
    # Nothing else flags b.test.ts, so the assertion heuristic keeps its real job.
    diff = """diff --git a/b.test.ts b/b.test.ts
--- a/b.test.ts
+++ b/b.test.ts
@@ -1,3 +1,2 @@
 it('adds', () => {
-  expect(add(1,1)).toBe(2);
 });
"""
    report = analyze(diff, [], [])
    assert [f.kind for f in report.findings] == ["assertions"]


# --- end-to-end negatives + positives -----------------------------------------

def test_analyze_clean_on_legit_rename_refactor():
    # a pure file rename: no diff hunks, inventories moved wholesale → no findings
    diff = """diff --git a/old.test.ts b/new.test.ts
similarity index 100%
rename from old.test.ts
rename to new.test.ts
"""
    base = [_ref("old.test.ts", "adds")]
    wt = [_ref("new.test.ts", "adds")]
    report = analyze(diff, base, wt)
    assert report.findings == []
    assert report.note is None


def test_analyze_flags_deletion_plus_skip_with_a_note():
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,3 +1,2 @@
-it('subtracts', () => { expect(sub(2,1)).toBe(1); });
+it.skip('adds', () => {});
"""
    base = [_ref("a.test.ts", "adds"), _ref("a.test.ts", "subtracts")]
    wt = [_ref("a.test.ts", "adds")]
    report = analyze(diff, base, wt)
    kinds = sorted(f.kind for f in report.findings)
    assert "removed" in kinds
    assert "skip" in kinds
    assert "1 removed" in report.note
    assert "1 skipped" in report.note


def test_summarize_none_when_clean():
    assert summarize([]) is None


# --- rewritten in place: the advisory signal, never the verdict ----------------
# The §8.8 gap (notes/e2e-gate-test-plan.md): the four tamper signals answer "does this test
# still exist?", so a retitle-plus-re-assert is silent. These pin the decision — it is
# reported on `report.rewrites`, and staying OFF `findings`/`note` is the assertion that
# matters, because `trust.no_tamper`, the streak and `block` mode all read those.

#: The literal round-1 diff from §8.8: two base contracts inverted under new titles.
_REWRITE_DIFF = """diff --git a/src/stats.js b/src/stats.js
--- a/src/stats.js
+++ b/src/stats.js
@@ -1,5 +1,6 @@
 export function mean(xs) {
-  if (!xs.length) return 0;
+  if (!xs.length) throw new Error('mean of an empty list');
   return xs.reduce((a, b) => a + b, 0) / xs.length;
 }
diff --git a/src/stats.test.js b/src/stats.test.js
--- a/src/stats.test.js
+++ b/src/stats.test.js
@@ -1,8 +1,8 @@
 describe('mean', () => {
-  it('returns 0 for an empty list', () => {
-    expect(mean([])).toBe(0);
+  it('throws on an empty list', () => {
+    expect(() => mean([])).toThrow('empty');
   });
 });
@@ -20,6 +20,6 @@
 describe('median', () => {
-  it('returns 0 for an empty list', () => {
-    expect(median([])).toBe(0);
+  it('throws on an empty list', () => {
+    expect(() => median([])).toThrow('empty');
   });
 });
"""

_REWRITE_BASE = [
    _ref("src/stats.test.js", "mean > returns 0 for an empty list"),
    _ref("src/stats.test.js", "median > returns 0 for an empty list"),
]
_REWRITE_WT = [
    _ref("src/stats.test.js", "mean > throws on an empty list"),
    _ref("src/stats.test.js", "median > throws on an empty list"),
]


def test_fuzzy_tier_pins_the_dogfood_ratios_and_their_argument_order():
    # The threshold is a coin flip at this distance, and SequenceMatcher is ORDER-SENSITIVE:
    # _find_match calls _similar(added, removed), which scores 0.812/0.824 (a match); the
    # reverse scores 0.781/0.794 (no match). Pinned so swapping those arguments or nudging
    # _FUZZY_THRESHOLD has to be a deliberate act with a failing test to answer for.
    for base, wt, forward, backward in (
        (_REWRITE_BASE[0], _REWRITE_WT[0], 0.8125, 0.7812),
        (_REWRITE_BASE[1], _REWRITE_WT[1], 0.8235, 0.7941),
    ):
        assert round(SequenceMatcher(None, wt.name, base.name).ratio(), 4) == forward
        assert round(SequenceMatcher(None, base.name, wt.name).ratio(), 4) == backward
        assert _FUZZY_THRESHOLD <= forward
        assert backward < _FUZZY_THRESHOLD
        assert _similar(wt.name, base.name)  # the call _find_match actually makes


def test_retitle_and_reassert_is_a_rewrite_and_not_a_finding():
    report = analyze(_REWRITE_DIFF, _REWRITE_BASE, _REWRITE_WT)
    # The verdict half is untouched: this still reads as a clean green, by design.
    assert report.findings == []
    assert report.note is None
    # The advisory half names both tests.
    assert [f.kind for f in report.rewrites] == ["rewritten", "rewritten"]
    assert sorted(f.test for f in report.rewrites) == [
        "mean > throws on an empty list",
        "median > throws on an empty list",
    ]
    assert all(f.file == "src/stats.test.js" for f in report.rewrites)
    assert "returns 0 for an empty list" in report.rewrites[0].detail


def test_pure_retitle_with_untouched_assertions_is_not_a_rewrite():
    # The refactor the skill promises stays silent: only the title line changed.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,5 +1,5 @@
 describe('mean', () => {
-  it('averages a list', () => {
+  it('averages the list', () => {
     expect(mean([1, 3])).toBe(2);
   });
 });
"""
    base = [_ref("a.test.ts", "mean > averages a list")]
    wt = [_ref("a.test.ts", "mean > averages the list")]
    report = analyze(diff, base, wt)
    assert report.findings == []
    assert report.rewrites == []


def test_one_line_retitle_keeping_its_assertion_is_not_a_rewrite():
    # Title and assertion share a line, so the LINE changed while the assertion didn't —
    # which is why _assertion_text starts at `expect` instead of comparing whole lines.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,2 +1,2 @@
-it('adds two numbers', () => expect(add(1, 1)).toBe(2));
+it('adds 2 numbers', () => expect(add(1, 1)).toBe(2));
"""
    base = [_ref("a.test.ts", "adds two numbers")]
    wt = [_ref("a.test.ts", "adds 2 numbers")]
    assert analyze(diff, base, wt).rewrites == []


def test_reordered_assertions_under_a_retitle_are_not_a_rewrite():
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,5 +1,5 @@
-it('checks both bounds', () => {
+it('checks the bounds', () => {
-  expect(lo).toBe(1);
-  expect(hi).toBe(9);
+  expect(hi).toBe(9);
+  expect(lo).toBe(1);
 });
"""
    base = [_ref("a.test.ts", "checks both bounds")]
    wt = [_ref("a.test.ts", "checks the bounds")]
    assert analyze(diff, base, wt).rewrites == []


def test_body_change_under_an_unchanged_title_is_not_a_rewrite():
    # Not a retitle at all, so it never reaches the pair list: an ordinary test edit
    # alongside a code change is the most common legitimate diff there is.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,3 +1,3 @@
 it('averages a list', () => {
-  expect(mean([1, 3])).toBe(2);
+  expect(mean([1, 3])).toBeCloseTo(2);
 });
"""
    base = [_ref("a.test.ts", "averages a list")]
    wt = [_ref("a.test.ts", "averages a list")]
    report = analyze(diff, base, wt)
    assert report.findings == []
    assert report.rewrites == []


def test_a_retitle_does_not_adopt_an_assertion_from_another_hunk():
    # Hunk 1 retitles; hunk 2 edits a DIFFERENT test's assertion. Attributing across the gap
    # (the flat added/removed lists drop the declarations in between) would report the
    # retitled test as re-asserted — a false positive on two innocent edits.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,5 +1,5 @@
 describe('mean', () => {
-  it('averages a list', () => {
+  it('averages the list', () => {
     expect(mean([1, 3])).toBe(2);
   });
@@ -20,4 +20,4 @@
   it('handles negatives', () => {
-    expect(mean([-1, 1])).toBe(0);
+    expect(mean([-1, 1])).toBeCloseTo(0);
   });
"""
    base = [_ref("a.test.ts", "mean > averages a list"), _ref("a.test.ts", "mean > handles negatives")]
    wt = [_ref("a.test.ts", "mean > averages the list"), _ref("a.test.ts", "mean > handles negatives")]
    report = analyze(diff, base, wt)
    assert report.findings == []
    assert report.rewrites == []


def test_a_deleted_test_is_still_a_removal_not_a_rewrite():
    # The verdict signal keeps priority: matching consumes each added test once, so an
    # unmatched removal can't be laundered into the advisory list.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,4 +1,1 @@
-it('subtracts', () => {
-  expect(sub(2, 1)).toBe(1);
-});
"""
    base = [_ref("a.test.ts", "adds"), _ref("a.test.ts", "subtracts")]
    wt = [_ref("a.test.ts", "adds")]
    report = analyze(diff, base, wt)
    assert [(f.kind, f.test) for f in report.findings] == [("removed", "subtracts")]
    assert report.rewrites == []


def test_pair_removals_splits_unmatched_from_retitled():
    base = [_ref("a.test.ts", "adds two numbers"), _ref("a.test.ts", "subtracts")]
    wt = [_ref("a.test.ts", "adds 2 numbers")]
    unmatched, retitled = pair_removals(base, wt, {})
    assert [t.name for t in unmatched] == ["subtracts"]
    assert [(o.name, n.name) for o, n in retitled] == [("adds two numbers", "adds 2 numbers")]


# --- parser: a hunk body is content, not headers ------------------------------

def test_a_removed_line_that_looks_like_a_path_header_keeps_the_path():
    # A test file that dropped a SQL comment: the diff line reads "--- a comment", which the
    # header branch would swallow and blank old_path with — taking every path-keyed signal
    # (assertion_deltas, the rewrite attribution) down with it.
    diff = """diff --git a/a.test.ts b/a.test.ts
--- a/a.test.ts
+++ b/a.test.ts
@@ -1,3 +1,2 @@
 it('builds sql', () => {
--- a comment
+++ another comment
 });
"""
    fd = parse_file_diffs(diff)[0]
    assert fd.old_path == fd.new_path == "a.test.ts"
    assert fd.removed == ["-- a comment"]  # the source line, minus the diff's own marker
    assert fd.added == ["++ another comment"]


# --- config scope extension (usp-critique-round3.md Move C) ------------------

def _file_diff(path, added_lines=(), removed_lines=()):
    diff = f"""diff --git a/{path} b/{path}
--- a/{path}
+++ b/{path}
@@ -1,1 +1,1 @@
""" + "".join(f"+{l}\n" for l in added_lines) + "".join(f"-{l}\n" for l in removed_lines)
    return parse_file_diffs(diff)


def test_config_tamper_flags_vitest_config_unconditionally():
    fds = _file_diff("vitest.config.ts", added_lines=["exclude: ['**/broken.test.ts']"])
    findings = config_tamper(fds)
    assert [(f.kind, f.file) for f in findings] == [("config", "vitest.config.ts")]


def test_config_tamper_flags_claude_settings_husky_and_vscode_tasks():
    for path in (".claude/settings.json", ".husky/pre-commit", ".vscode/tasks.json"):
        fds = _file_diff(path, added_lines=["anything"])
        findings = config_tamper(fds)
        assert [f.file for f in findings] == [path], path


def test_config_tamper_ignores_unrelated_pyproject_change():
    fds = _file_diff("pyproject.toml", added_lines=['"asyncpg>=0.30",'])
    assert config_tamper(fds) == []


def test_config_tamper_flags_pyproject_pytest_section_change():
    fds = _file_diff("pyproject.toml", removed_lines=["testpaths = [\"tests\"]"])
    findings = config_tamper(fds)
    assert [(f.kind, f.file) for f in findings] == [("config", "pyproject.toml")]


def test_config_tamper_ignores_unrelated_package_json_change():
    fds = _file_diff("package.json", added_lines=['"lodash": "^4.0.0",'])
    assert config_tamper(fds) == []


def test_config_tamper_flags_package_json_test_script_change():
    fds = _file_diff("package.json", removed_lines=['"test": "vitest run",'])
    findings = config_tamper(fds)
    assert [(f.kind, f.file) for f in findings] == [("config", "package.json")]


def test_config_tamper_ignores_unrelated_source_file():
    fds = _file_diff("src/math.ts", added_lines=["export const v = 2"])
    assert config_tamper(fds) == []


def test_analyze_folds_in_config_findings_and_summarize_names_them():
    diff = """diff --git a/vitest.config.ts b/vitest.config.ts
--- a/vitest.config.ts
+++ b/vitest.config.ts
@@ -1,1 +1,1 @@
+exclude: ['**/broken.test.ts']
"""
    report = analyze(diff, [], [])
    assert [(f.kind, f.file) for f in report.findings] == [("config", "vitest.config.ts")]
    assert report.note == "1 test-config file touched"


# --- red-first population (the pure half; the IO half is gate._red_first_check) --

def test_added_tests_returns_only_tests_new_to_the_worktree():
    base = [_ref("a.test.ts", "adds")]
    wt = [_ref("a.test.ts", "adds"), _ref("a.test.ts", "subtracts")]
    assert [t.name for t in added_tests(base, wt)] == ["subtracts"]


def test_added_tests_empty_when_nothing_new():
    base = [_ref("a.test.ts", "adds")]
    wt = [_ref("a.test.ts", "adds")]
    assert added_tests(base, wt) == []


def test_config_tamper_flags_vitest_workspace_and_nested_husky():
    for path in ("vitest.workspace.ts", ".husky/_/husky.sh"):
        fds = _file_diff(path, added_lines=["anything"])
        findings = config_tamper(fds)
        assert [f.file for f in findings] == [path], path


def test_config_tamper_flags_test_block_inside_vite_config():
    # Vitest reads its config from a `test:` block INSIDE vite.config.* by default —
    # a separate vitest.config.* is the opt-out, not the common case.
    fds = _file_diff("vite.config.ts", added_lines=["test: { exclude: ['**/broken.test.ts'] },"])
    findings = config_tamper(fds)
    assert [(f.kind, f.file) for f in findings] == [("config", "vite.config.ts")]


def test_config_tamper_ignores_vite_config_changes_outside_the_test_block():
    fds = _file_diff("vite.config.ts", added_lines=["plugins: [react()]"])
    assert config_tamper(fds) == []


def test_config_tamper_ignores_package_json_dependencies_that_start_with_test():
    for line in ['"testcontainers": "^1.0.0",', '"test-utils": "~2.0.0",', '"testing-library": "1.2.3",']:
        fds = _file_diff("package.json", added_lines=[line])
        assert config_tamper(fds) == [], line


def test_config_tamper_flags_a_bare_runner_name_script_value():
    fds = _file_diff("package.json", removed_lines=['"test": "jest",'])
    findings = config_tamper(fds)
    assert [(f.kind, f.file) for f in findings] == [("config", "package.json")]


def test_config_tamper_catches_a_single_line_exclude_glob_widened():
    # refuter round-3's exact repro: widening an exclude glob on a single line
    # inside vite.config.ts's test: block. The key line itself changes, so it's
    # caught even though the surrounding `test: {` header line does not.
    fds = _file_diff(
        "vite.config.ts",
        added_lines=["    exclude: ['**/node_modules/**', '**/*.broken.test.ts'],"],
        removed_lines=["    exclude: ['**/node_modules/**'],"],
    )
    findings = config_tamper(fds)
    assert [(f.kind, f.file) for f in findings] == [("config", "vite.config.ts")]


def test_config_tamper_known_limitation_deep_multiline_array_edit_is_missed():
    # Documented, accepted limitation (module docstring + _VITE_CONFIG_TEST_BLOCK_RE's
    # comment): a line-based, no-AST heuristic can't see an added array ELEMENT deep
    # inside a multi-line literal when neither the added nor removed line repeats a
    # recognized key. This test exists so the gap stays a known, recorded trade-off
    # rather than a silent regression nobody notices got wider or narrower.
    fds = _file_diff(
        "vite.config.ts",
        added_lines=["      '**/*.broken.test.ts',"],
    )
    assert config_tamper(fds) == []
