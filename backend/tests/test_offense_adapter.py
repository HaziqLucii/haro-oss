"""OffenseAdapter — JSON linter output → the same live grid as tests.

Covers the pluggable parsers (theme-check / eslint / ruff) + the adapter contract:
error offenses → red (``failed``) cells that block the gate, warnings → amber
(``skipped``) cells that don't, a clean run → green with an empty grid, and the
"couldn't run" cases (bad JSON, missing binary, unknown format) → setup/runner
errors rather than a scary red.
"""

import asyncio
import json

import pytest

from haro.adapters.test_runner import OffenseAdapter
from haro.adapters.test_runner.offense import (
    _parse_eslint,
    _parse_ruff,
    _parse_theme_check,
)
from haro.gate import classify_gate_error


def _gate_on(tmp_path, payload, fmt: str, collect: list | None = None):
    """Run the adapter over a `cat`-ed JSON fixture — the linter stands in for any
    tool that prints this format to stdout."""
    fixture = tmp_path / "out.json"
    fixture.write_text(payload if isinstance(payload, str) else json.dumps(payload))
    adapter = OffenseAdapter(f"cat {fixture}", fmt)

    async def emit(ev):
        if collect is not None:
            collect.append(ev)

    return asyncio.run(adapter.run(cwd=str(tmp_path), emit=emit if collect is not None else None))


# --------------------------------------------------------------------------- #
# Parsers
# --------------------------------------------------------------------------- #
def test_parse_theme_check_severity_and_1based_line():
    data = [
        {
            "path": "templates/index.liquid",
            "offenses": [
                {"check": "UnusedAssign", "message": "unused", "severity": 0, "start_row": 4, "start_column": 2},
                {"check": "SpaceInsideBraces", "message": "spacing", "severity": 2, "start_row": 9, "start_column": 0},
            ],
        }
    ]
    offs = _parse_theme_check(data)
    assert [o.severity for o in offs] == ["error", "warning"]
    # rows/cols are 0-based in the JSON; we present them 1-based.
    assert (offs[0].line, offs[0].col) == (5, 3)
    assert offs[0].rule == "UnusedAssign"


def test_parse_eslint_severity():
    data = [
        {
            "filePath": "/proj/src/a.js",
            "messages": [
                {"ruleId": "no-unused-vars", "severity": 2, "message": "x", "line": 1, "column": 5},
                {"ruleId": "eqeqeq", "severity": 1, "message": "y", "line": 3, "column": 1},
            ],
        }
    ]
    offs = _parse_eslint(data)
    assert [o.severity for o in offs] == ["error", "warning"]
    assert offs[0].line == 1 and offs[0].rule == "no-unused-vars"


def test_parse_ruff_all_errors():
    data = [
        {"code": "F401", "message": "unused import", "filename": "/proj/a.py", "location": {"row": 1, "column": 8}},
    ]
    offs = _parse_ruff(data)
    assert offs[0].severity == "error"
    assert offs[0].line == 1 and offs[0].rule == "F401"


# --------------------------------------------------------------------------- #
# Adapter contract
# --------------------------------------------------------------------------- #
def test_error_offense_blocks_the_gate(tmp_path):
    payload = [{"filePath": str(tmp_path / "a.js"), "messages": [
        {"ruleId": "no-x", "severity": 2, "message": "boom", "line": 2, "column": 3}]}]
    res = _gate_on(tmp_path, payload, "eslint")
    assert res.ok is False  # an error-severity offense is a red gate
    assert res.failed == 1 and res.skipped == 0 and res.total == 1
    cell = res.cases[0]
    assert cell.status == "failed"
    assert cell.file == "a.js:2:3"  # path made relative to cwd + line:col
    assert cell.message == "boom"


def test_warnings_alone_stay_green_as_amber_cells(tmp_path):
    payload = [{"filePath": str(tmp_path / "a.js"), "messages": [
        {"ruleId": "style", "severity": 1, "message": "nit", "line": 1, "column": 1}]}]
    res = _gate_on(tmp_path, payload, "eslint")
    # Warnings render amber (skipped) but never block a merge — like a skipped test.
    assert res.ok is True
    assert res.skipped == 1 and res.failed == 0
    assert res.cases[0].status == "skipped"


def test_clean_run_is_green_with_empty_grid(tmp_path):
    res = _gate_on(tmp_path, [], "ruff")
    # Zero offenses is the SUCCESS case, not a "no tests found" error.
    assert res.ok is True and res.error is None
    assert res.total == 0 and res.cases == []


def test_cells_stream_to_the_test_channel(tmp_path):
    events: list = []
    payload = [{"code": "E1", "message": "bad", "filename": str(tmp_path / "a.py"),
                "location": {"row": 7, "column": 2}}]
    res = _gate_on(tmp_path, payload, "ruff", collect=events)
    assert events[0]["kind"] == "run_started"
    cells = [e["cell"] for e in events if e["kind"] == "cell"]
    assert len(cells) == 1
    assert cells[0]["status"] == "failed" and cells[0]["file"] == "a.py:7:2"
    assert res.failed == 1


def test_unparseable_output_is_a_runner_error(tmp_path):
    res = _gate_on(tmp_path, "not json at all", "eslint")
    assert res.ok is False and res.error is not None
    # Tool ran but produced no offenses JSON → a runner error, not a red suite.
    assert classify_gate_error(res.error, None) == "runner"


def test_missing_binary_is_a_setup_error(tmp_path):
    adapter = OffenseAdapter("this-binary-does-not-exist-xyz --output json", "eslint")
    res = asyncio.run(adapter.run(cwd=str(tmp_path)))
    assert res.ok is False
    assert classify_gate_error(res.error, None) == "setup"


def test_unknown_format_is_a_setup_error(tmp_path):
    res = _gate_on(tmp_path, [], "mystery-lint")
    assert res.ok is False and "unknown offense format" in res.error


def test_empty_command_errors_without_running(tmp_path):
    res = asyncio.run(OffenseAdapter("  ", "eslint").run(cwd=str(tmp_path)))
    assert res.ok is False and "no gate command" in res.error
    assert classify_gate_error(res.error, None) == "setup"


def test_json_recovered_from_trailing_noise(tmp_path):
    # Some tools print the JSON then a human summary line — we still recover it.
    payload = json.dumps([]) + "\n✓ 0 problems\n"
    res = _gate_on(tmp_path, payload, "ruff")
    assert res.ok is True and res.total == 0
