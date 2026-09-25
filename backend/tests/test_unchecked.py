"""Code to check — the pure signal engine (backlog/code-to-check.md §1).

The tests that matter most here are the NEGATIVES. A pane that wants to reach zero is
worthless if ordinary work keeps it non-zero, and #213 already taught this codebase what a
crying-wolf alarm costs: a test-only diff, a fully-executed diff, and a CSS/markdown edit
must all produce exactly nothing.

Hand-written unified diffs rather than a real repo, because the engine is pure.
"""

from __future__ import annotations

from haro import unchecked


def diff(*chunks: str) -> str:
    return "\n".join(chunks) + "\n"


def added(path: str, *lines: str, start: int = 1) -> str:
    """A diff chunk that adds `lines` to `path` starting at line `start`."""
    body = "\n".join(f"+{l}" for l in lines)
    return diff(
        f"diff --git a/{path} b/{path}",
        f"--- a/{path}",
        f"+++ b/{path}",
        f"@@ -0,0 +{start},{len(lines)} @@",
        body,
    )


# --- the negatives: ordinary work must produce nothing --------------------- #

def test_test_only_diff_is_clean():
    """Adding tests is the opposite of unchecked work."""
    d = added("src/math.test.ts", "it('adds', () => expect(add(1,2)).toBe(3))")
    r = unchecked.analyze(d, line_hits={})
    assert r.items == []
    assert r.note is None


def test_fully_executed_diff_is_clean():
    """Every added line has a hit, so there is nothing to check. This is the state the
    pane exists to let you reach."""
    d = added("src/math.ts", "export const add = (a,b) => a+b", "export const sub = (a,b) => a-b", start=10)
    hits = {"src/math.ts": {10: 3, 11: 1}}
    r = unchecked.analyze(d, line_hits=hits)
    assert r.items == []


def test_non_code_edits_are_clean():
    """A CSS tweak, a markdown edit and an HTML change file nothing: coverage would never
    mention them, so reporting them would make the pane permanently non-zero."""
    d = added("src/styles/gate.css", ".cell { color: red }") \
        + added("README.md", "docs") \
        + added("index.html", "<div/>")
    r = unchecked.analyze(d, line_hits={})
    assert r.items == []


def test_no_coverage_provider_degrades_to_risk_rules_only():
    """line_hits=None means no provider installed. It must NOT mean 'everything is
    unchecked' — that would turn a missing devDependency into a wall of false rows."""
    d = added("src/math.ts", "export const add = (a,b) => a+b")
    assert unchecked.analyze(d, line_hits=None).items == []

    # …but the coverage-free rules still fire, because they never needed coverage.
    d2 = d + added("package.json", '  "asyncpg": "^0.30"')
    kinds = [i.kind for i in unchecked.analyze(d2, line_hits=None).items]
    assert kinds == ["new_dep"]


def test_empty_and_malformed_diffs_are_silent():
    for bad in ("", "not a diff at all", "@@ -1 +1 @@\n+orphan hunk"):
        r = unchecked.analyze(bad, line_hits={})
        assert r.items == [] and r.note is None


# --- coverage tier 1: the file nothing imports ----------------------------- #

def test_file_absent_from_coverage_map_is_the_stronger_signal():
    """Absent from the map means no test even imports it. A percentage would hide this,
    because an unimported file has no percentage."""
    d = added("src/components/CodePanel.tsx", "export function CodePanel() {}", "// two", "// three", start=5)
    # A .ts in the map must still put a changed .tsx in scope: same runner, same family.
    r = unchecked.analyze(d, line_hits={"src/other.ts": {1: 1}})
    assert [i.kind for i in r.items] == ["no_test_file"]
    item = r.items[0]
    assert item.file == "src/components/CodePanel.tsx"
    assert item.count == 3
    assert "no test imports" in item.detail


# --- coverage tier 2: imported, but these lines never ran ------------------ #

def test_partially_executed_file_counts_only_the_cold_lines():
    d = added("src/rungs.py", "def a(): pass", "def b(): pass", "def c(): pass", start=100)
    hits = {"src/rungs.py": {100: 5, 101: 0, 102: 0}}
    r = unchecked.analyze(d, line_hits=hits)
    assert [i.kind for i in r.items] == ["untested_lines"]
    assert r.items[0].count == 2
    assert "2 of 3 added lines never ran" in r.items[0].detail


def test_a_line_missing_from_the_map_is_non_coverable_not_cold():
    """Absence means NON-COVERABLE, not "never ran" — the opposite of what this test used
    to assert ("v8 omits lines it never instrumented; absence is a zero, not unknown").

    Measured against real istanbul output on the Phase 9 E2E fixture: of 31 added lines in
    `currency.js`, 11 were absent from the map and **every one** was a comment, a blank, a
    function signature or a closing brace. Not one was an uninstrumented statement, because
    istanbul's `statementMap` carries every statement. Treating absence as cold therefore
    counted braces as untested — it inflated this row and made it contradict Verified Hunks
    about the same file on the same screen (23 lines "never ran" vs 13 never executed).
    `verified_hunks.py` already had it right; this module now agrees.
    """
    d = added("src/a.ts", "const x = 1", "const y = 2", start=1)
    r = unchecked.analyze(d, line_hits={"src/a.ts": {1: 1}})
    assert r.items == [], "a line absent from the map must not be reported as never-run"


def test_a_line_present_and_zero_is_still_cold():
    """The distinction that makes the above safe: present-with-0 is a real cold line and
    must still be flagged, or this row would stop reporting anything at all."""
    d = added("src/a.ts", "const x = 1", "const y = 2", start=1)
    r = unchecked.analyze(d, line_hits={"src/a.ts": {1: 1, 2: 0}})
    assert [i.kind for i in r.items] == ["untested_lines"]
    assert r.items[0].count == 1


# --- the boring risk rules ------------------------------------------------- #

def test_dependency_manifest_and_lockfile_both_flag():
    d = added("package.json", '  "left-pad": "^1"') + added("frontend/package-lock.json", '  "left-pad": {}')
    kinds = [i.kind for i in unchecked.analyze(d, line_hits={}).items]
    assert kinds == ["new_dep", "new_dep"]


def test_secret_paths_flag_without_reading_content():
    d = added(".haro/.env", "TOKEN=abc") + added("certs/server.pem", "----BEGIN----")
    items = unchecked.analyze(d, line_hits={}).items
    assert [i.kind for i in items] == ["secret", "secret"]
    # We never claim to have found a secret, only that a secret-bearing file moved.
    assert all("touched" in i.detail for i in items)


def test_deletion_flags_but_a_rename_does_not():
    """A rename moves content; a deletion removes it. Conflating them would fire on every
    refactor, which is exactly how an alarm gets ignored."""
    deletion = diff(
        "diff --git a/src/old.ts b/src/old.ts",
        "--- a/src/old.ts",
        "+++ /dev/null",
        "@@ -1 +0,0 @@",
        "-export const gone = 1",
    )
    assert [i.kind for i in unchecked.analyze(deletion, line_hits={}).items] == ["deleted"]

    rename = diff(
        "diff --git a/src/old.ts b/src/new.ts",
        "rename from src/old.ts",
        "rename to src/new.ts",
    )
    assert unchecked.analyze(rename, line_hits={}).items == []


def test_migration_paths_flag():
    d = added("backend/migrations/0003_add_column.py", "def up(): pass")
    kinds = [i.kind for i in unchecked.analyze(d, line_hits={}).items]
    assert "migration" in kinds


# --- tamper findings are folded in, not recomputed ------------------------- #

class _Finding:
    def __init__(self, kind, file, detail, test=None):
        self.kind, self.file, self.detail, self.test = kind, file, detail, test


def test_tamper_findings_arrive_as_rows():
    """The pane is the ONE place that answers 'what has nothing checked', so a green* also
    shows up here rather than only on the gate verdict."""
    r = unchecked.analyze(
        "", line_hits={},
        tamper_findings=[_Finding("removed", "src/math.test.ts", "test removed", "adds numbers")],
    )
    assert [i.kind for i in r.items] == ["suite_weakened"]
    assert "adds numbers" in r.items[0].detail


def test_rewrites_arrive_as_their_own_row_kind():
    """A retitled-and-re-asserted test is a different claim from a weakened suite, so it gets
    its own row rather than being folded into `suite_weakened` — and it lands here at all
    because the green* chip doesn't render on the clean green that carries it (§8.8)."""
    r = unchecked.analyze(
        "", line_hits={},
        tamper_rewrites=[
            _Finding("rewritten", "src/stats.test.js", 'retitled and re-asserted (was "returns 0")',
                     "mean > throws on an empty list")
        ],
    )
    assert [i.kind for i in r.items] == ["assertion_rewritten"]
    assert "throws on an empty list" in r.items[0].detail
    assert "returns 0" in r.items[0].detail
    assert r.note == "1 assertion rewritten"


# --- ordering + the glance note -------------------------------------------- #

def test_rows_sort_by_severity_tier_not_discovery_order():
    d = added("package.json", '  "x": "1"') + added("src/a.ts", "const a=1") + added(".env", "K=v")
    kinds = [i.kind for i in unchecked.analyze(d, line_hits={}).items]  # no map ⇒ risk rows only
    # secret outranks new_dep; src/a.ts contributes nothing without coverage.
    assert kinds.index("secret") < kinds.index("new_dep")


def test_note_is_a_compact_one_liner():
    d = added("src/a.ts", "const a=1", "const b=2", "const c=3") + added("package.json", '  "x": "1"')
    # a.ts is absent from a map that DOES instrument the js family, so it is in scope.
    r = unchecked.analyze(d, line_hits={"src/known.ts": {1: 1}})
    assert r.note == "1 file no test imports · 1 dep change"


def test_note_pluralizes_and_sums_lines():
    d = added("src/a.ts", "x", "y", start=1) + added("src/b.ts", "z", start=1)
    hits = {"src/a.ts": {1: 0, 2: 0}, "src/b.ts": {1: 0}}
    assert unchecked.analyze(d, line_hits=hits).note == "3 lines never ran"


def test_clean_report_has_no_note():
    assert unchecked.analyze("", line_hits={}).note is None


# --- cross-language false positives: the bug real data caught --------------- #
# haro's own gate runs vitest in frontend/, so its coverage map holds only .ts/.tsx. Before
# `runner_scope`, a diff touching backend/haro/gate.py was reported as "no test imports this
# file" — but a JS coverage report has nothing to say about Python either way. That is a
# textbook cry-wolf row, and #213 already showed what those cost.

def test_a_python_file_is_not_flagged_by_a_javascript_coverage_map():
    d = added("backend/haro/gate.py", "def run_gate(): pass", "def other(): pass")
    js_map = {"frontend/src/gate.ts": {1: 1}}
    assert unchecked.analyze(d, line_hits=js_map).items == []


def test_the_same_engine_scopes_itself_to_python_for_a_pytest_gate():
    """Runner-agnostic: the map defines the universe, so no per-runner branching."""
    d = added("backend/haro/gate.py", "def run_gate(): pass", "def b(): pass", "def c(): pass")
    py_map = {"backend/haro/other.py": {1: 1}}
    assert [i.kind for i in unchecked.analyze(d, line_hits=py_map).items] == ["no_test_file"]


def test_an_empty_coverage_map_stays_silent():
    """No instrumented files means we cannot tell what is in scope. Silence beats guessing."""
    d = added("src/a.ts", "const a = 1")
    assert unchecked.analyze(d, line_hits={}).items == []


def test_monorepo_scope_excludes_a_sibling_package():
    """A sibling package's .ts shares the extension but the gate never saw it."""
    d = (added("frontend/src/a.ts", "a", "b", "c")
         + added("other-app/src/b.ts", "a", "b", "c"))
    m = {"frontend/src/known.ts": {1: 1}}
    files = [i.file for i in unchecked.analyze(d, line_hits=m, scope="frontend").items]
    assert files == ["frontend/src/a.ts"]


def test_runner_scope_infers_extensions_from_the_map():
    assert unchecked.runner_scope({"a/b.ts": {}, "c.tsx": {}, "d.py": {}}) == {"js", "py"}
    assert unchecked.runner_scope({}) == set()


def test_tsx_is_in_scope_when_the_map_only_holds_ts():
    """The flaw that family-grouping fixes: .ts and .tsx are one runner, so a map full of
    .ts must not exclude a changed .tsx."""
    d = added("frontend/src/components/New.tsx", "export const New = () => (", "  null", ")")
    m = {"frontend/src/gate.ts": {1: 1}}
    assert [i.kind for i in unchecked.analyze(d, line_hits=m).items] == ["no_test_file"]


# --- the cry-wolf floor: report on the CHANGE, not on standing test debt ---- #

def test_a_trivial_edit_to_an_untested_file_files_no_row():
    """Measured on #205: without this floor an em-dash sweep filed 22 rows, 15 of them for
    one- and two-line edits. 'Write a test for AnalysisPanel.tsx because you fixed a comma'
    is not work anyone will do, and an unclearable pane is wallpaper."""
    d = added("frontend/src/components/AnalysisPanel.tsx", "  <span>fixed</span>")
    m = {"frontend/src/gate.ts": {1: 1}}
    assert unchecked.analyze(d, line_hits=m).items == []


def test_a_substantial_addition_to_an_untested_file_does_file_a_row():
    d = added("frontend/src/components/New.tsx", "a", "b", "c", "d")
    m = {"frontend/src/gate.ts": {1: 1}}
    items = unchecked.analyze(d, line_hits=m).items
    assert [i.kind for i in items] == ["no_test_file"]
    assert items[0].count == 4


def test_declaration_only_files_are_never_flagged():
    """A .d.ts is erased at runtime, so it can never appear in a coverage map: flagging it
    would be a guaranteed false positive."""
    d = added("frontend/src/vite-env.d.ts", "declare module '*.svg'", "declare const x: number", "// three")
    m = {"frontend/src/gate.ts": {1: 1}}
    assert unchecked.analyze(d, line_hits=m).items == []


def test_biggest_rows_lead_within_a_tier():
    """A 142-line untested addition must outrank a 3-line one, or the first rows a human
    reads are just whatever the diff listed first."""
    d = (added("frontend/src/small.ts", "a", "b", "c")
         + added("frontend/src/big.ts", *[f"l{i}" for i in range(40)]))
    m = {"frontend/src/gate.ts": {1: 1}}
    files = [i.file for i in unchecked.analyze(d, line_hits=m).items]
    assert files == ["frontend/src/big.ts", "frontend/src/small.ts"]


def test_detail_pluralizes_the_line_count():
    m = {"frontend/src/gate.ts": {1: 1}}
    d = added("frontend/src/x.ts", "a", "b", "c")
    assert "3 added lines" in unchecked.analyze(d, line_hits=m).items[0].detail


# --- the row key: what a tick-off is stored against ------------------------ #

def test_row_key_is_stable_across_identical_reports():
    """A tick has to survive a re-gate that reproduces the same claim, or the pane asks the
    same question forever and stops being a worklist."""
    m = {"frontend/src/gate.ts": {1: 1}}
    d = added("frontend/src/x.ts", "a", "b", "c")
    first = unchecked.analyze(d, line_hits=m).items[0]
    second = unchecked.analyze(d, line_hits=m).items[0]
    assert first.key == second.key


def test_row_key_moves_when_the_claim_grows():
    """"I looked at these 3 unexecuted lines" stops being true at 4, so the key must move and
    the tick must die with it. This is the whole semantics of ticking a row off."""
    m = {"frontend/src/gate.ts": {1: 1}}
    three = unchecked.analyze(added("frontend/src/x.ts", "a", "b", "c"), line_hits=m).items[0]
    four = unchecked.analyze(added("frontend/src/x.ts", "a", "b", "c", "d"), line_hits=m).items[0]
    assert three.key != four.key


def test_two_claims_in_one_file_get_separate_keys():
    """Countless kinds fall back to their detail: two removed tests in the same file are two
    questions, and ticking one must not answer the other."""
    a = unchecked.UncheckedItem(kind="suite_weakened", file="src/a.test.ts", detail="removed (one)")
    b = unchecked.UncheckedItem(kind="suite_weakened", file="src/a.test.ts", detail="removed (two)")
    assert a.key != b.key


def test_keys_within_one_report_are_unique():
    d = (added("frontend/src/a.ts", "x", "y", "z")
         + added("frontend/src/b.ts", "x", "y", "z")
         + added("package.json", '  "left-pad": "^1.0.0"'))
    items = unchecked.analyze(d, line_hits={"frontend/src/gate.ts": {1: 1}}).items
    keys = [i.key for i in items]
    assert len(keys) == len(set(keys)) and len(keys) >= 3


# --- covered_files: the number that decides whether empty means clean ------ #

def test_covered_files_is_none_without_a_coverage_map():
    """None, not 0. No provider means we cannot say anything about execution, and the pane
    must not render its earned "every changed line ran" over that."""
    report = unchecked.analyze(added("src/x.py", "a = 1", "b = 2", "c = 3"), line_hits=None)
    assert report.covered_files is None


def test_covered_files_is_zero_when_the_map_says_nothing_about_this_diff():
    """The everyday case that used to render as clean: a Python change under a vitest gate.
    A map existed, it just was not in the room for any of these files."""
    report = unchecked.analyze(
        added("backend/haro/gate.py", "a = 1", "b = 2", "c = 3"),
        line_hits={"frontend/src/gate.ts": {1: 1}},
    )
    assert report.items == []          # correctly silent: wrong language for this runner
    assert report.covered_files == 0   # ...and honest about WHY it is silent


def test_covered_files_counts_only_files_the_suite_executed():
    """A file absent from the map was executed by nothing, so it cannot count toward the
    number that licenses the clean state — even when the floor suppresses its row."""
    m = {"frontend/src/known.ts": {1: 1, 2: 1}}
    d = (added("frontend/src/known.ts", "a", start=1)
         + added("frontend/src/ghost.ts", "b", start=1))  # 1 line: under the row floor
    report = unchecked.analyze(d, line_hits=m)
    assert report.items == []
    assert report.covered_files == 1
