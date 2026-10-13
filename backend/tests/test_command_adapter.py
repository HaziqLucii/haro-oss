"""CommandAdapter — the generic "run a command, check the exit code" gate.

Covers the thin contract: exit 0 → green, non-zero → red, a missing binary →
an ``error`` result the gate classifies as ``setup`` (not a scary red), plus the
stdout/stderr → ``test`` channel log streaming.
"""

import asyncio

import pytest

from haro.adapters.test_runner import CommandAdapter
from haro.gate import classify_gate_error


def _run(command: str, cwd: str = "/tmp", collect: list | None = None):
    adapter = CommandAdapter(command)

    async def emit(ev):
        if collect is not None:
            collect.append(ev)

    return asyncio.run(adapter.run(cwd=cwd, emit=emit if collect is not None else None))


def test_exit_zero_is_green():
    res = _run("true")
    assert res.ok is True
    assert res.error is None
    assert res.total == 0 and res.passed == 0 and res.failed == 0  # informational


def test_nonzero_exit_is_red_not_error():
    res = _run("false")
    assert res.ok is False
    # A genuine red gate — NOT an error (which would read as "the gate never ran").
    assert res.error is None


def test_missing_binary_is_a_setup_error():
    res = _run("this-command-does-not-exist-xyz")
    assert res.ok is False
    assert res.error is not None
    # 127 from the shell → phrased so the gate classifier tags it setup.
    assert classify_gate_error(res.error, None) == "setup"


def test_empty_command_errors_without_running():
    res = _run("   ")
    assert res.ok is False
    assert res.error is not None and "no gate command" in res.error
    # Unconfigured is a setup problem, not a failing suite.
    assert classify_gate_error(res.error, None) == "setup"


def test_stdout_streams_to_test_channel_as_log_lines():
    events: list = []
    res = _run("echo hello && echo world", collect=events)
    assert res.ok is True
    kinds = [e["kind"] for e in events]
    assert kinds[0] == "run_started"
    lines = [e["line"] for e in events if e["kind"] == "log"]
    assert "hello" in lines and "world" in lines


def test_stderr_is_captured_in_the_log():
    events: list = []
    _run("echo oops 1>&2", collect=events)
    lines = [e["line"] for e in events if e["kind"] == "log"]
    assert "oops" in lines  # stderr is merged into the streamed log


def test_several_lines_run_in_order_and_the_first_failure_is_red():
    # Without `set -e` a shell reports only the LAST line's exit code, so `false` above `true`
    # would read green.
    assert _run("true\ntrue").ok is True
    assert _run("false\ntrue").ok is False
    assert _run("true\nfalse").ok is False


def test_a_second_line_does_not_run_after_the_first_fails(tmp_path):
    marker = tmp_path / "ran"
    res = _run(f"false\ntouch {marker}")
    assert res.ok is False and not marker.exists()


def test_one_line_is_given_to_the_shell_as_typed():
    assert CommandAdapter("make check").script() == "make check"
    assert CommandAdapter("a\r\nb").script() == "set -e\na\nb"
    assert CommandAdapter("  make check\n").script() == "make check"
