"""PytestAdapter JUnit parsing + the cross-runner blame tie-in.

The gate is runner-agnostic (Vitest / pytest behind the same seam); this covers
pytest's JUnit-XML → normalized CaseResult mapping, including the traceback → stack
capture that lets "failure → blame" work for Python too.
"""

import tempfile

from haro.adapters.test_runner.pytest_adapter import _parse_junit
from haro.blame import blame_message, changed_lines

JUNIT = """<?xml version="1.0" encoding="utf-8"?>
<testsuites>
  <testsuite name="pytest" tests="3" failures="1" skipped="1">
    <testcase classname="tests.test_math" name="test_ok" file="tests/test_math.py" time="0.01"/>
    <testcase classname="tests.test_math" name="test_add" file="tests/test_math.py" time="0.02">
      <failure message="assert 2 == 3">def test_add():
&gt;       assert add(1, 1) == 3
E       assert 2 == 3

tests/test_math.py:7: AssertionError</failure>
    </testcase>
    <testcase classname="tests.test_math" name="test_skip" file="tests/test_math.py" time="0.0">
      <skipped message="not ready"/>
    </testcase>
  </testsuite>
</testsuites>
"""


def _parse(xml: str):
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
        f.write(xml)
        path = f.name
    return _parse_junit(path)


def test_parse_junit_maps_pass_fail_skip():
    cases = _parse(JUNIT)
    by_name = {c.name: c for c in cases}
    assert by_name["test_ok"].status == "passed"
    assert by_name["test_add"].status == "failed"
    assert by_name["test_skip"].status == "skipped"
    assert by_name["test_add"].duration_ms == 20.0  # 0.02s → ms
    assert by_name["test_add"].message == "assert 2 == 3"


def test_failure_traceback_captured_as_stack():
    add = {c.name: c for c in _parse(JUNIT)}["test_add"]
    assert add.stack is not None
    assert "tests/test_math.py:7" in add.stack  # the frame blame keys off


def test_blame_matches_pytest_traceback_to_the_diff():
    # a diff whose added line is new-side line 7 — exactly where the traceback points
    diff = (
        "diff --git a/tests/test_math.py b/tests/test_math.py\n"
        "--- a/tests/test_math.py\n"
        "+++ b/tests/test_math.py\n"
        "@@ -5,4 +5,4 @@\n"
        " def test_add():\n"
        "     x = 1\n"
        "-    assert add(x, 1) == 2\n"
        "+    assert add(1, 1) == 3\n"
    )
    changed = changed_lines(diff)
    add = {c.name: c for c in _parse(JUNIT)}["test_add"]
    hunks = blame_message(add.stack, changed)
    assert hunks == [{"file": "tests/test_math.py", "line": 7, "code": "assert add(1, 1) == 3"}]
