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


# --- pytest parity, weakened matchers, widened timeouts -----------------------

from haro.tamper import (  # noqa: E402
    is_python_test_file,
    python_removed_tests,
    weakened_assertions,
    widened_timeouts,
)


def _diff(path, body, old=None):
    return (
        f"diff --git a/{old or path} b/{path}\n--- a/{old or path}\n+++ b/{path}\n@@ -1,9 +1,9 @@\n"
        + body
    )


def _kinds(diff):
    return sorted(f.kind for f in analyze(diff, [], []).findings)


def test_is_python_test_file():
    assert is_python_test_file("tests/test_gate.py")
    assert is_python_test_file("pkg/gate_test.py")
    assert not is_python_test_file("backend/tests/helpers/util.py")
    assert not is_python_test_file("backend/tests/conftest.py")
    assert not is_python_test_file("backend/tests/__init__.py")
    assert not is_python_test_file("backend/haro/gate.py")
    assert is_test_file("tests/test_gate.py")


def test_python_deleted_test_function_is_removed():
    d = _diff("tests/test_a.py", " import pytest\n-def test_adds():\n-    assert add(1, 2) == 3\n def test_other():\n     assert 1\n")
    fs = python_removed_tests(parse_file_diffs(d), {})
    assert [(f.kind, f.file, f.test) for f in fs] == [("removed", "tests/test_a.py", "test_adds")]


def test_python_moved_or_renamed_test_is_not_removed():
    moved = _diff("tests/test_a.py", "-def test_x():\n-    assert 1\n+def test_x():\n+    assert 1\n")
    assert python_removed_tests(parse_file_diffs(moved), {}) == []
    retitle = _diff("tests/test_a.py", "-def test_adds_two_numbers():\n+def test_adds_two_numbers_ok():\n")
    assert python_removed_tests(parse_file_diffs(retitle), {}) == []
    renamed_file = (
        "diff --git a/tests/test_old.py b/tests/test_new.py\nrename from tests/test_old.py\nrename to tests/test_new.py\n"
    )
    assert python_removed_tests(parse_file_diffs(renamed_file), rename_map(parse_file_diffs(renamed_file))) == []


def test_python_consolidation_into_another_file_is_not_removed():
    d = (
        _diff("tests/test_a.py", "-def test_x():\n-    assert 1\n")
        + _diff("tests/test_b.py", "+def test_x():\n+    assert 1\n")
    )
    assert python_removed_tests(parse_file_diffs(d), {}) == []


def test_python_test_disabled_by_renaming_out_of_collection_is_removed():
    d = _diff("tests/test_a.py", "-def test_x():\n+def _test_x():\n")
    assert [f.test for f in python_removed_tests(parse_file_diffs(d), {})] == ["test_x"]


def test_python_deleted_test_file_reports_its_tests():
    d = "diff --git a/tests/test_a.py b/tests/test_a.py\n--- a/tests/test_a.py\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-def test_x():\n-    assert 1\n"
    assert _kinds(d) == ["removed"]


def test_python_skip_and_xfail_spellings():
    for line, kind in [
        ("+@pytest.mark.skip(reason='x')", "skip"),
        ("+@pytest.mark.skipif(sys.platform == 'win32', reason='x')", "skip"),
        ("+@unittest.skip('x')", "skip"),
        ("+@unittest.skipIf(True, 'x')", "skip"),
        ("+    pytest.skip('later')", "skip"),
        ("+    self.skipTest('later')", "skip"),
        ("+@pytest.mark.xfail(reason='x')", "xfail"),
        ("+@unittest.expectedFailure", "xfail"),
        ("+    pytest.xfail('known')", "xfail"),
    ]:
        d = _diff("tests/test_a.py", f" def test_x():\n{line}\n     assert 1\n")
        assert _kinds(d) == [kind], line


def test_python_reindented_skip_nets_to_zero_and_comments_are_ignored():
    d = _diff("tests/test_a.py", "-@pytest.mark.skip\n+    @pytest.mark.skip\n+# pytest.skip('doc')\n")
    assert _kinds(d) == []


def test_python_modifiers_in_non_test_module_are_ignored():
    d = _diff("backend/haro/gate.py", "+    pytest.skip('x')\n")
    assert _kinds(d) == []


def test_python_assertion_delta_counts_assert_selfassert_raises_approx():
    d = _diff(
        "tests/test_a.py",
        "-    assert a == 1\n-    self.assertEqual(a, 1)\n-    with pytest.raises(ValueError):\n-        f()\n",
    )
    fs = assertion_deltas(parse_file_diffs(d))
    assert [(f.kind, f.detail) for f in fs] == [("assertions", "3 fewer assertions")]


def test_python_assertion_added_is_silent():
    d = _diff("tests/test_a.py", "+    assert a == 1\n")
    assert assertion_deltas(parse_file_diffs(d)) == []


def test_python_config_files():
    cfg = config_tamper(parse_file_diffs(_diff("backend/tests/conftest.py", "+import os\n")))
    assert [f.kind for f in cfg] == ["config"]
    assert [f.kind for f in config_tamper(parse_file_diffs(_diff("pytest.ini", "-addopts = -x\n")))] == ["config"]
    assert config_tamper(parse_file_diffs(_diff("setup.cfg", "+[flake8]\n+max-line-length = 99\n"))) == []
    assert [f.kind for f in config_tamper(parse_file_diffs(_diff("setup.cfg", "+[tool:pytest]\n+testpaths = a\n")))] == ["config"]
    assert [f.kind for f in config_tamper(parse_file_diffs(_diff("tox.ini", "+[pytest]\n+addopts = -k 'not slow'\n")))] == ["config"]
    assert [f.kind for f in config_tamper(parse_file_diffs(_diff("pyproject.toml", "+addopts = '--ignore=tests/slow'\n")))] == ["config"]
    assert config_tamper(parse_file_diffs(_diff("pyproject.toml", "+name = 'x'\n"))) == []


def test_summarize_new_kinds():
    fs = [
        TamperFinding(kind="xfail", file="a", detail=""),
        TamperFinding(kind="weakened", file="a", detail=""),
        TamperFinding(kind="timeout", file="a", detail=""),
        TamperFinding(kind="timeout", file="b", detail=""),
    ]
    assert summarize(fs) == "1 xfail · 1 weakened · 2 timeouts widened"


def _weak(path, old, new):
    body = "".join(f"-{l}\n" for l in old) + "".join(f"+{l}\n" for l in new)
    return weakened_assertions(parse_file_diffs(_diff(path, body)))


def test_js_strict_to_loose_is_weakened():
    for old, new in [
        ("expect(x).toBe(2);", "expect(x).toBeTruthy();"),
        ("expect(x).toEqual({a: 1});", "expect(x).toBeDefined();"),
        ("expect(x).toStrictEqual(y);", "expect(x).toEqual(y);"),
        ("expect(x).toMatchObject({a: 1});", "expect(x).not.toBeNull();"),
        ("expect(x).toHaveLength(3);", "expect(x).not.toBeUndefined();"),
        ("expect(fn).toHaveBeenCalledWith(1, 2);", "expect(fn).toHaveBeenCalled();"),
        ("expect(fn).toHaveBeenCalledTimes(2);", "expect(fn).toHaveBeenCalled();"),
        ("expect(() => f()).toThrow('bad');", "expect(() => f()).toThrow();"),
        ("expect(x).toEqual(1);", "expect(x).toEqual(expect.anything());"),
        ("expect(x.length).toBe(3);", "expect(x.length).toBeGreaterThanOrEqual(0);"),
        ("expect(x).toBeCloseTo(0.12345, 5);", "expect(x).toBeCloseTo(0.12345, 1);"),
        ("expect(x).toBeCloseTo(0.12345, 5);", "expect(x).toBeCloseTo(0.12345);"),
    ]:
        fs = _weak("src/a.test.ts", [f"  {old}"], [f"  {new}"])
        assert [f.kind for f in fs] == ["weakened"], (old, new)
        assert fs[0].file == "src/a.test.ts"


def test_js_legit_refactors_are_not_weakened():
    for old, new in [
        ("expect(x).toBe(2);", "expect(y).toBeTruthy();"),
        ("expect(x).toBe(2);", "expect(x).toBe(3);"),
        ("expect(x).toBe(true);", "expect(x).toBeTruthy();"),
        ("expect(x).toBeTruthy();", "expect(x).toBe(1);"),
        ("expect(x).toEqual(y);", "expect(x).toStrictEqual(y);"),
        ("expect(x).toBeCloseTo(1, 2);", "expect(x).toBeCloseTo(1, 5);"),
        ("expect(x).toThrow();", "expect(x).toThrow('bad');"),
        ("expect(x).toBe(2);", "expect(x).toBe(2);"),
    ]:
        assert _weak("src/a.test.ts", [f"  {old}"], [f"  {new}"]) == [], (old, new)


def test_js_replacing_one_assertion_with_two_is_not_paired():
    fs = _weak(
        "src/a.test.ts",
        ["  expect(x).toBe(2);"],
        ["  expect(x).toBe(2);", "  expect(x).toBeDefined();"],
    )
    assert fs == []
    fs = _weak(
        "src/a.test.ts",
        ["  expect(x).toEqual(a);"],
        ["  expect(x).toEqual(b);", "  expect(x).toBeDefined();"],
    )
    assert fs == []


def test_js_weakening_ignored_outside_test_files():
    assert _weak("src/a.ts", ["  expect(x).toBe(2);"], ["  expect(x).toBeTruthy();"]) == []


def test_js_weakened_suppresses_the_assertion_delta_for_that_file():
    d = _diff("src/a.test.ts", "-  expect(x).toBe(2);\n+  expect(x).toBeTruthy();\n-  expect(y).toBe(1);\n")
    rep = analyze(d, [], [])
    assert sorted(f.kind for f in rep.findings) == ["weakened"]
    assert rep.note == "1 weakened"


def test_python_strict_to_loose_is_weakened():
    for old, new in [
        ("    assert x == y", "    assert x"),
        ("    assert x == 3", "    assert x is not None"),
        ("    assert x == 3", "    assert x != None"),
        ("    assert x == pytest.approx(1.0, rel=1e-6)", "    assert x == pytest.approx(1.0, rel=0.1)"),
        ("    assert x == pytest.approx(1.0)", "    assert x == pytest.approx(1.0, abs=1)"),
        ("    with pytest.raises(ValueError):", "    with pytest.raises(Exception):"),
        ("    with pytest.raises(ValueError, match='x'):", "    with pytest.raises(BaseException):"),
    ]:
        fs = _weak("tests/test_a.py", [old], [new])
        assert [f.kind for f in fs] == ["weakened"], (old, new)


def test_python_legit_refactors_are_not_weakened():
    for old, new in [
        ("    assert x == y", "    assert z"),
        ("    assert x == 3", "    assert x == 4"),
        ("    assert x", "    assert x == 1"),
        ("    assert x == pytest.approx(1.0, rel=0.1)", "    assert x == pytest.approx(1.0, rel=1e-6)"),
        ("    with pytest.raises(Exception):", "    with pytest.raises(ValueError):"),
        ("    assert x == 3  # was 2", "    assert x == 3"),
        ("    assert x == 1 and y == 2", "    assert x"),
    ]:
        assert _weak("tests/test_a.py", [old], [new]) == [], (old, new)


def _timeouts(path, old, new):
    body = "".join(f"-{l}\n" for l in old) + "".join(f"+{l}\n" for l in new)
    return widened_timeouts(parse_file_diffs(_diff(path, body)))


def test_js_per_test_timeout_added_or_raised():
    fs = _timeouts("src/a.test.ts", [], ["it('slow', async () => { await x(); }, 30000);"])
    assert [f.kind for f in fs] == ["timeout"] and "added" in fs[0].detail
    fs = _timeouts("src/a.test.ts", ["it('slow', fn, 5000);"], ["it('slow', fn, 30_000);"])
    assert [f.kind for f in fs] == ["timeout"] and "raised from 5000ms to 30000ms" in fs[0].detail
    fs = _timeouts("src/a.test.ts", [], ["test('slow', { timeout: 60000 }, async () => {});"])
    assert [f.kind for f in fs] == ["timeout"]


def test_js_closing_arg_form_needs_a_test_declaration_and_a_real_value():
    body = " it('slow', async () => {\n   await x();\n-}, 5000);\n+}, 20000);\n"
    assert [f.kind for f in widened_timeouts(parse_file_diffs(_diff("src/a.test.ts", body)))] == ["timeout"]
    body = " setTimeout(() => {\n   done();\n+}, 500);\n"
    assert widened_timeouts(parse_file_diffs(_diff("src/a.test.ts", body))) == []
    body = " await waitFor(() => {\n   expect(x);\n+}, { timeout: 4000 });\n"
    assert widened_timeouts(parse_file_diffs(_diff("src/a.test.ts", body))) == []


def test_js_timeout_lowered_or_unchanged_is_silent():
    assert _timeouts("src/a.test.ts", ["it('a', fn, 30000);"], ["it('a', fn, 10000);"]) == []
    assert _timeouts("src/a.test.ts", ["it('a', fn, 30000);"], ["  it('a', fn, 30000);"]) == []
    assert _timeouts("src/a.test.ts", ["it('a', fn, 30000);"], []) == []


def test_js_config_timeouts():
    fs = _timeouts("vitest.config.ts", ["    testTimeout: 5000,"], ["    testTimeout: 60000,"])
    assert [f.kind for f in fs] == ["timeout"] and "testTimeout raised" in fs[0].detail
    assert [f.kind for f in _timeouts("vite.config.ts", [], ["    hookTimeout: 100000,"])] == ["timeout"]
    assert [f.kind for f in _timeouts("src/setup.test.ts", [], ["vi.setConfig({ testTimeout: 90000 });"])] == ["timeout"]
    assert [f.kind for f in _timeouts("src/setup.test.ts", [], ["jest.setTimeout(90000);"])] == ["timeout"]
    assert _timeouts("vitest.config.ts", ["    testTimeout: 60000,"], ["    testTimeout: 5000,"]) == []


def test_python_timeout_marker_and_ini():
    fs = _timeouts("tests/test_a.py", [], ["@pytest.mark.timeout(300)"])
    assert [f.kind for f in fs] == ["timeout"] and "300s" in fs[0].detail
    assert [f.kind for f in _timeouts("tests/test_a.py", ["@pytest.mark.timeout(10)"], ["@pytest.mark.timeout(60)"])] == ["timeout"]
    assert _timeouts("tests/test_a.py", ["@pytest.mark.timeout(60)"], ["@pytest.mark.timeout(10)"]) == []
    assert [f.kind for f in _timeouts("pytest.ini", ["timeout = 30"], ["timeout = 300"])] == ["timeout"]
    assert [f.kind for f in _timeouts("pytest.ini", [], ["addopts = --timeout=120"])] == ["timeout"]
    assert [f.kind for f in _timeouts("pyproject.toml", [], ["[tool.pytest.ini_options]", "timeout = 600"])] == ["timeout"]
    assert _timeouts("pyproject.toml", [], ["[tool.other]", "timeout = 600"]) == []


def test_analyze_surfaces_timeout_for_config_edit():
    d = _diff("vitest.config.ts", "-    testTimeout: 5000,\n+    testTimeout: 60000,\n")
    rep = analyze(d, [], [])
    assert [f.kind for f in rep.findings] == ["timeout"]
    assert rep.note == "1 timeout widened"


# --- refuter round 1 regressions ----------------------------------------------

import time  # noqa: E402


def _ctx_diff(path, lines):
    """lines already carry their own ' ', '+' or '-' prefix."""
    return _diff(path, "".join(l + "\n" for l in lines))


def test_timeout_signal_ignores_non_test_source_files():
    for path, lines in [
        ("src/v.ts", ["+  return re.test(s) && clamp(n, 2)"]),
        ("src/api.ts", ["+  if (URL_RE.test(u)) return fetchWith(u, { timeout: 10 })"]),
        ("src/poll.ts", [" if (/^x/.test(s)) start()", "+setInterval(() => {", "+  tick()", "+}, 5000);"]),
        ("src/api.ts", ["+  const opts = { timeout: 60000 };"]),
    ]:
        assert widened_timeouts(parse_file_diffs(_ctx_diff(path, lines))) == [], path
        assert _kinds(_ctx_diff(path, lines)) == [], path


def test_timeout_call_regex_does_not_match_method_calls():
    d = _ctx_diff("src/a.test.ts", ["+  expect(re.test(s)).toBe(true); check(a, 5000)"])
    assert widened_timeouts(parse_file_diffs(d)) == []


def test_closing_timeout_only_counts_when_it_closes_the_declaration():
    nested_debounce = [" it('x', async () => {", "+  const fn = debounce(() => {", "+    calls++", "+  }, 2000);"]
    assert widened_timeouts(parse_file_diffs(_ctx_diff("src/a.test.ts", nested_debounce))) == []
    nested_wait = [
        " it('x', async () => {",
        "+  await waitFor(() => {",
        "+    expect(x).toBeInTheDocument()",
        "+  }, { timeout: 3000 })",
    ]
    assert widened_timeouts(parse_file_diffs(_ctx_diff("src/a.test.ts", nested_wait))) == []
    opener_out_of_view = ["+  await run();", "+}, 30000);"]
    assert widened_timeouts(parse_file_diffs(_ctx_diff("src/a.test.ts", opener_out_of_view))) == []


def test_closing_timeout_still_flags_the_declaration_itself():
    closing = ["+it('slow', async () => {", "+  await run();", "+}, 30000)"]
    assert [f.kind for f in widened_timeouts(parse_file_diffs(_ctx_diff("src/a.test.ts", closing)))] == ["timeout"]
    opt = ["+test('x', { timeout: 20000 }, async () => {", "+  await run();", "+});"]
    assert [f.kind for f in widened_timeouts(parse_file_diffs(_ctx_diff("src/a.test.ts", opt)))] == ["timeout"]
    trailing_opt = ["+it('slow', async () => {", "+  await run();", "+}, { timeout: 20000 })"]
    assert [f.kind for f in widened_timeouts(parse_file_diffs(_ctx_diff("src/a.test.ts", trailing_opt)))] == ["timeout"]


def test_pytest_approx_is_not_counted_as_an_assertion():
    d = _diff("tests/test_a.py", "-    assert mean([1, 2]) == pytest.approx(1.5)\n+    assert mean([1, 2]) == 1.5\n")
    assert _kinds(d) == []


def test_timeout_regex_is_linear_on_long_whitespace():
    for tail in (" " * 200_000, "\t" * 200_000):
        line = "+it('x', fn, 1)" + tail + "x"
        d = _ctx_diff("src/a.test.ts", [line, "+foo(a, 1)" + tail])
        t0 = time.perf_counter()
        widened_timeouts(parse_file_diffs(d))
        assert time.perf_counter() - t0 < 0.5


def test_python_helper_under_tests_dir_is_not_a_test_module():
    d = _diff("tests/helpers.py", "-def test_data():\n-    return 1\n")
    assert _kinds(d) == []
    assert not is_python_test_file("tests/helpers.py")


def test_python_retitle_by_extending_the_name_is_not_removed():
    d = _diff("tests/test_a.py", "-def test_parse():\n+def test_parse_empty():\n")
    assert python_removed_tests(parse_file_diffs(d), {}) == []
    d = _diff("tests/test_a.py", "-def test_parse_empty():\n+def test_parse():\n")
    assert [f.test for f in python_removed_tests(parse_file_diffs(d), {})] == ["test_parse_empty"]


def test_python_fold_into_parametrized_test_is_consolidation():
    d = _diff(
        "tests/test_a.py",
        "-def test_add_one():\n-    assert add(1) == 2\n-def test_add_two():\n-    assert add(2) == 3\n"
        "+@pytest.mark.parametrize('n,want', [(1, 2), (2, 3)])\n+def test_add(n, want):\n+    assert add(n) == want\n",
    )
    assert python_removed_tests(parse_file_diffs(d), {}) == []


def test_python_fold_without_parametrize_is_still_removed():
    d = _diff(
        "tests/test_a.py",
        "-def test_add_one():\n-    assert add(1) == 2\n-def test_add_two():\n-    assert add(2) == 3\n"
        "+def test_add():\n+    assert add(1) == 2\n",
    )
    assert [f.test for f in python_removed_tests(parse_file_diffs(d), {})] == ["test_add_two"]


def test_python_unrelated_removal_beside_an_unrelated_add_is_still_removed():
    d = _diff("tests/test_a.py", "-def test_parse():\n+def test_render():\n")
    assert [f.test for f in python_removed_tests(parse_file_diffs(d), {})] == ["test_parse"]


def test_weakening_does_not_pair_across_different_tests_in_a_hunk():
    body = (
        " def test_a():\n-    assert result == 3\n+    assert len(result) == 3\n"
        " def test_b():\n+    assert result\n"
    )
    assert weakened_assertions(parse_file_diffs(_diff("tests/test_a.py", body))) == []
    js = (
        " it('a', () => {\n-  expect(result).toBe(3);\n+  expect(result.length).toBe(3);\n"
        " it('b', () => {\n+  expect(result).toBeTruthy();\n"
    )
    assert weakened_assertions(parse_file_diffs(_diff("src/a.test.ts", js))) == []


def test_weakening_still_pairs_inside_one_test():
    body = " def test_a():\n-    assert result == 3\n+    assert result\n"
    assert [f.kind for f in weakened_assertions(parse_file_diffs(_diff("tests/test_a.py", body)))] == ["weakened"]


def test_timeout_in_a_test_config_replaces_the_generic_config_finding():
    d = _diff("vitest.config.ts", "-    testTimeout: 5000,\n+    testTimeout: 60000,\n")
    rep = analyze(d, [], [])
    assert [f.kind for f in rep.findings] == ["timeout"]
    d = _diff("vitest.config.ts", "-    exclude: ['a'],\n+    exclude: ['a', 'b'],\n")
    assert [f.kind for f in analyze(d, [], []).findings] == ["config"]


# --- refuter round 2 regressions ----------------------------------------------

def test_trimming_a_descriptive_name_does_not_hide_a_deletion():
    d = _diff(
        "tests/test_auth.py",
        '-def test_login_rejects_bad_password():\n-    assert not login("u", "bad")\n+def test_login():\n+    assert True\n',
    )
    assert [f.test for f in python_removed_tests(parse_file_diffs(d), {})] == ["test_login_rejects_bad_password"]


def test_shortening_into_a_parametrized_test_needs_a_many_to_one_fold():
    one = _diff(
        "tests/test_a.py",
        "-def test_add_zero():\n-    assert add(0) == 0\n"
        "+@pytest.mark.parametrize('n', [0])\n+def test_add(n):\n+    assert add(n) == n\n",
    )
    assert [f.test for f in python_removed_tests(parse_file_diffs(one), {})] == ["test_add_zero"]


_FOLD = (
    "-def test_add_one():\n-    assert add(1) == 2\n-def test_add_two():\n-    assert add(2) == 3\n"
    "+@pytest.mark.parametrize('n,want', [(1, 2), (2, 3)])\n+def test_add(n, want):\n+    assert add(n) == want\n"
)


def test_parametrize_fold_is_not_also_an_assertion_loss():
    assert _kinds(_diff("tests/test_a.py", _FOLD)) == []


def test_fold_into_an_assertion_free_test_is_still_a_loss():
    d = _diff(
        "tests/test_a.py",
        "-def test_add_one():\n-    assert add(1) == 2\n-def test_add_two():\n-    assert add(2) == 3\n"
        "+@pytest.mark.parametrize('n,want', [(1, 2), (2, 3)])\n+def test_add(n, want):\n+    add(n)\n",
    )
    assert _kinds(d) == ["assertions"]


def test_widened_exclude_beside_a_timeout_keeps_the_config_finding():
    d = _diff(
        "vitest.config.ts",
        "-    exclude: ['node_modules'],\n+    exclude: ['node_modules', 'src/**/*.test.ts'],\n"
        "-    testTimeout: 5000,\n+    testTimeout: 60000,\n",
    )
    assert _kinds(d) == ["config", "timeout"]


def test_mid_argument_options_object_must_belong_to_the_test_call():
    d = _ctx_diff("src/a.test.ts", ["+it('x', async () => { await poll(fn, { timeout: 5000 }, 3) })"])
    assert widened_timeouts(parse_file_diffs(d)) == []
    d = _ctx_diff("src/a.test.ts", ["+it('x', { timeout: 5000 }, async () => { await poll(fn) })"])
    assert [f.kind for f in widened_timeouts(parse_file_diffs(d))] == ["timeout"]


def test_timeout_scan_is_linear_on_a_long_line_of_calls():
    for unit in ("it(a, 1)", "it('x', { timeout: 5 }, {", "it(a, {"):
        line = "+" + unit * (200_000 // len(unit))
        d = _ctx_diff("src/a.test.ts", [line])
        t0 = time.perf_counter()
        widened_timeouts(parse_file_diffs(d))
        assert time.perf_counter() - t0 < 0.5, unit


# --- refuter round 3 regressions ----------------------------------------------

def _fold_diff(param_line, target="test_add", body="assert add(n) == want"):
    return _diff(
        "tests/test_a.py",
        "-def test_add_one():\n-    assert add(1) == 2\n-def test_add_two():\n-    assert add(2) == 3\n"
        f"+{param_line}\n+def {target}(n, want):\n+    {body}\n",
    )


def test_fold_dropping_a_case_is_not_a_fold():
    d = _fold_diff("@pytest.mark.parametrize('x,y', [(1, 2)])")
    assert python_removed_tests(parse_file_diffs(d), {}) != []
    assert "removed" in _kinds(d)


def test_fold_into_an_empty_parameter_set_is_not_a_fold():
    for arg in ("[]", "()"):
        d = _fold_diff(f"@pytest.mark.parametrize('x,y', {arg})")
        assert "removed" in _kinds(d), arg


def test_fold_with_an_unreadable_parameter_list_is_not_a_fold():
    d = _fold_diff("@pytest.mark.parametrize('x,y', CASES)")
    assert "removed" in _kinds(d)


def test_shortening_fold_with_too_few_cases_reports_every_deleted_test():
    d = _diff(
        "tests/test_auth.py",
        "-def test_login_rejects_bad_password():\n-    assert not login('u', 'bad')\n"
        "-def test_login_rejects_empty():\n-    assert not login('u', '')\n"
        "+@pytest.mark.parametrize('pw', ['x'])\n+def test_login(pw):\n+    assert login('u', pw) is not None\n",
    )
    assert sorted(f.test for f in python_removed_tests(parse_file_diffs(d), {})) == [
        "test_login_rejects_bad_password",
        "test_login_rejects_empty",
    ]


def test_legit_fold_with_enough_cases_stays_silent_single_and_multi_line():
    assert _kinds(_fold_diff("@pytest.mark.parametrize('n,want', [(1, 2), (2, 3)])")) == []
    d = _diff(
        "tests/test_a.py",
        "-def test_add_one():\n-    assert add(1) == 2\n-def test_add_two():\n-    assert add(2) == 3\n"
        "+@pytest.mark.parametrize(\n+    'n,want',\n+    [\n+        (1, 2),\n+        (2, 3),\n+        (3, 4),\n+    ],\n+)\n"
        "+def test_add(n, want):\n+    assert add(n) == want\n",
    )
    assert _kinds(d) == []
