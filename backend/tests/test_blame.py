from haro.blame import blame_message, changed_lines, parse_frames

# A representative git diff: one changed source file, one added + one context line.
DIFF = """diff --git a/src/math.ts b/src/math.ts
index 111..222 100644
--- a/src/math.ts
+++ b/src/math.ts
@@ -1,4 +1,4 @@
 export function add(a: number, b: number) {
-  return a + b;
+  return a - b;
 }
@@ -8,2 +8,3 @@ export function mul(a, b) {
   return a * b;
+  // note
 }
"""

# A vitest-style stack for a failure that runs through the changed line.
STACK = """AssertionError: expected 1 to be 2
    at Object.<anonymous> (/home/u/wt/src/math.test.ts:4:23)
    at /home/u/wt/src/math.ts:2:12
"""


def test_parse_frames_extracts_locations_deduped():
    frames = parse_frames(STACK)
    assert ("/home/u/wt/src/math.test.ts", 4) in frames
    assert ("/home/u/wt/src/math.ts", 2) in frames
    # prose without a file:line must not match
    assert parse_frames("expected 1 to be 2") == []


def test_changed_lines_records_added_new_side_numbers():
    changed = changed_lines(DIFF)
    assert "src/math.ts" in changed
    # ``return a - b;`` is the added line at new-side line 2.
    assert changed["src/math.ts"][2] == "  return a - b;"
    # second hunk starts at new-side 8; the added comment is line 9.
    assert changed["src/math.ts"][9] == "  // note"
    # the context/unchanged line 1 was never added, so it isn't recorded.
    assert 1 not in changed["src/math.ts"]


def test_blame_matches_frame_to_changed_line():
    changed = changed_lines(DIFF)
    hunks = blame_message(STACK, changed)
    assert hunks == [{"file": "src/math.ts", "line": 2, "code": "return a - b;"}]


def test_blame_file_level_fallback_when_no_line_hits():
    changed = changed_lines(DIFF)
    # stack passes through the changed file but at a line the diff didn't touch
    stack = "Error\n    at /home/u/wt/src/math.ts:99:1"
    assert blame_message(stack, changed) == [{"file": "src/math.ts", "line": None, "code": None}]


def test_blame_empty_when_stack_touches_nothing_changed():
    changed = changed_lines(DIFF)
    stack = "Error\n    at /home/u/wt/src/other.ts:3:1"
    assert blame_message(stack, changed) == []
    assert blame_message(None, changed) == []
    assert blame_message(STACK, {}) == []
