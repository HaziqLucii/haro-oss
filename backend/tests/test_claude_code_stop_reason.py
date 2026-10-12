"""A safeguard refusal and a failed run's subtype, as the adapter reports them.

A refusal is a normal reply with ``stop_reason: "refusal"`` (and ``stop_details.category``), and
the CLI may still close the run as a success. These pin that haro turns it into an ``error``
that says why, instead of a ``done`` that sends an untouched tree to the gate.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from haro.adapters import claude_code as cc
from haro.adapters.claude_code import ClaudeCodeAdapter


def run(coro):
    return asyncio.run(coro)


class _Stdin:
    def write(self, data: bytes):
        pass

    async def drain(self):
        pass

    def is_closing(self):
        return False

    def close(self):
        pass


class _Stdout:
    def __init__(self, lines):
        self._lines = [json.dumps(o).encode() + b"\n" for o in lines]

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._lines:
            raise StopAsyncIteration
        return self._lines.pop(0)


class _Err:
    async def read(self):
        return b""


class _Proc:
    def __init__(self, lines):
        self.stdin = _Stdin()
        self.stdout = _Stdout(lines)
        self.stderr = _Err()
        self.returncode = None
        self.pid = None

    async def wait(self):
        self.returncode = 0
        return 0


def _events(monkeypatch, lines):
    proc = _Proc(lines)

    async def fake_exec(*cmd, **kwargs):
        return proc

    monkeypatch.setattr(cc.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(cc.shutil, "which", lambda name: "/usr/bin/" + name)

    async def go():
        return [ev async for ev in ClaudeCodeAdapter().run(task="t", cwd="/tmp/wt")]

    return run(go())


def _result(**extra):
    return {"type": "result", "subtype": "success", "result": "", "usage": {}, **extra}


def _final(events):
    return [e for e in events if e.type in ("done", "error")][-1]


def test_a_refusal_on_the_result_line_is_an_error_naming_the_category(monkeypatch):
    ev = _final(
        _events(
            monkeypatch,
            [_result(stop_reason="refusal", stop_details={"category": "cyber"})],
        )
    )
    assert ev.type == "error"
    assert "declined" in ev.payload["message"]
    assert "cyber" in ev.payload["message"]
    assert "vulnerabilities in source code" in ev.payload["message"]
    assert ev.payload["subtype"] == "refusal"
    assert ev.payload["refusal_category"] == "cyber"


def test_a_refusal_on_the_last_turn_counts_when_the_result_line_is_silent(monkeypatch):
    assistant = {
        "type": "assistant",
        "message": {
            "content": [{"type": "text", "text": ""}],
            "stop_reason": "refusal",
            "stop_details": {"category": "reasoning_extraction"},
        },
    }
    ev = _final(_events(monkeypatch, [assistant, _result()]))
    assert ev.type == "error"
    assert "Remove that instruction" in ev.payload["message"]


def test_a_refusal_without_a_category_still_says_it_was_declined(monkeypatch):
    ev = _final(_events(monkeypatch, [_result(stop_reason="refusal")]))
    assert ev.type == "error"
    assert ev.payload["message"].startswith("The model declined this request.")


def test_a_normal_end_of_turn_is_still_done(monkeypatch):
    assistant = {
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"},
    }
    ev = _final(_events(monkeypatch, [assistant, _result(stop_reason="end_turn", result="ok")]))
    assert ev.type == "done"


def test_a_sub_agents_refusal_does_not_fail_the_run(monkeypatch):
    inner = {
        "type": "assistant",
        "parent_tool_use_id": "toolu_x",
        "message": {"content": [], "stop_reason": "refusal", "stop_details": {"category": "bio"}},
    }
    ev = _final(_events(monkeypatch, [inner, _result(result="done")]))
    assert ev.type == "done"


@pytest.mark.parametrize(
    "subtype,expect",
    [
        ("error_max_turns", "turn limit"),
        ("error_max_budget_usd", "budget cap"),
        ("error_during_execution", "error while running"),
    ],
)
def test_a_failed_run_keeps_its_subtype_and_says_what_it_means(monkeypatch, subtype, expect):
    ev = _final(_events(monkeypatch, [{"type": "result", "subtype": subtype, "usage": {}}]))
    assert ev.type == "error"
    assert ev.payload["subtype"] == subtype
    assert expect in ev.payload["message"]


def test_the_cli_s_own_error_text_wins_over_the_subtype_wording(monkeypatch):
    ev = _final(
        _events(
            monkeypatch,
            [{"type": "result", "subtype": "error_max_turns", "result": "ran out", "usage": {}}],
        )
    )
    assert ev.payload["message"] == "ran out"


def test_a_refusal_on_an_error_result_still_names_the_category(monkeypatch):
    ev = _final(
        _events(
            monkeypatch,
            [
                {
                    "type": "result",
                    "subtype": "error_during_execution",
                    "is_error": True,
                    "result": "request failed",
                    "usage": {},
                    "stop_reason": "refusal",
                    "stop_details": {"category": "bio"},
                }
            ],
        )
    )
    assert ev.type == "error"
    assert ev.payload["refusal_category"] == "bio"
    assert "declined" in ev.payload["message"]


def test_an_earlier_turns_refusal_does_not_fail_a_later_turn(monkeypatch):
    refused = {
        "type": "assistant",
        "message": {"content": [], "stop_reason": "refusal", "stop_details": {"category": "cyber"}},
    }
    later = {
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": "fine"}], "stop_reason": None},
    }
    events = _events(monkeypatch, [refused, _result(result="first"), later, _result(result="second")])
    finals = [e for e in events if e.type in ("done", "error")]
    assert [e.type for e in finals] == ["error", "done"]


@pytest.mark.parametrize("category", [["x"], {"a": 1}, 7, ""])
def test_an_odd_category_value_does_not_crash_the_stream(monkeypatch, category):
    ev = _final(
        _events(
            monkeypatch,
            [_result(stop_reason="refusal", stop_details={"category": category})],
        )
    )
    assert ev.type == "error"
    assert ev.payload["refusal_category"] is None
