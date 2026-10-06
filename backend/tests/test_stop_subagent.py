"""Stopping ONE sub-agent through the adapter's stdin control channel.

The CLI is spiked live (2.1.289): with ``--input-format stream-json`` it accepts
``{"type":"control_request","request":{"subtype":"stop_task","task_id":...}}``, reports the task
``stopped`` and the run carries on. These pin haro's side with a scripted fake process:
the prompt goes over stdin, delegations are tracked from ``system/task_started``, a stop
writes the control request, a ``done`` that arrives while sub-agents work is held until they
settle, and stdin is closed once nothing is outstanding so the CLI exits.
"""

from __future__ import annotations

import asyncio
import json

import pytest
from fastapi import HTTPException

from haro import main as main_mod
from haro.adapters import claude_code as cc
from haro.adapters.claude_code import ClaudeCodeAdapter
from haro.models import Workspace


def run(coro):
    return asyncio.run(coro)


class _Stdin:
    def __init__(self):
        self.lines: list[dict] = []
        self.closed = False

    def write(self, data: bytes):
        self.lines.append(json.loads(data.decode()))

    async def drain(self):
        pass

    def is_closing(self):
        return self.closed

    def close(self):
        self.closed = True


class _Stdout:
    """Yields scripted NDJSON lines; ``None`` is a pause (the test releases it)."""

    def __init__(self):
        self.q: asyncio.Queue = asyncio.Queue()

    def feed(self, obj):
        self.q.put_nowait(json.dumps(obj).encode() + b"\n")

    def eof(self):
        self.q.put_nowait(None)

    def __aiter__(self):
        return self

    async def __anext__(self):
        item = await self.q.get()
        if item is None:
            raise StopAsyncIteration
        return item


class _Err:
    async def read(self):
        return b""


class _Proc:
    def __init__(self):
        self.stdin = _Stdin()
        self.stdout = _Stdout()
        self.stderr = _Err()
        self.returncode = None
        self.pid = -1

    async def wait(self):
        self.returncode = 0
        return 0


def _delegation_started(tid="toolu_d"):
    return {
        "type": "assistant",
        "message": {"content": [{
            "type": "tool_use", "id": tid, "name": "Agent",
            "input": {"subagent_type": "Explore", "description": "map it", "run_in_background": True},
        }]},
    }


def _result(text="ok"):
    return {"type": "result", "subtype": "success", "result": text, "usage": {}}


@pytest.fixture
def scripted(monkeypatch):
    """A ClaudeCodeAdapter whose `claude` process is a scripted _Proc."""
    proc = _Proc()

    async def fake_exec(*cmd, **kwargs):
        proc.cmd = list(cmd)
        proc.kwargs = kwargs
        return proc

    monkeypatch.setattr(cc.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(cc.shutil, "which", lambda name: "/usr/bin/" + name)
    monkeypatch.setattr(cc, "_SETTLE_GRACE_S", 0.2)
    return ClaudeCodeAdapter(), proc


async def _drive(adapter, proc, script, **kw):
    events: list = []

    async def consume():
        async for ev in adapter.run(task="do it", cwd="/tmp/wt", **kw):
            events.append(ev)

    t = asyncio.create_task(consume())
    await asyncio.sleep(0.05)
    await script(proc)
    await asyncio.wait_for(t, 5)
    return events


def test_the_prompt_goes_over_stdin_not_argv(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_result())
        p.stdout.eof()

    run(_drive(adapter, proc, script))
    assert "do it" not in proc.cmd
    assert proc.cmd[:4] == ["claude", "-p", "--input-format", "stream-json"]
    assert proc.kwargs["stdin"] is not None
    assert proc.stdin.lines[0] == {"type": "user", "message": {"role": "user", "content": "do it"}}


def test_stdin_closes_when_the_run_has_nothing_outstanding(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_result())
        await asyncio.sleep(0.05)
        assert p.stdin.closed, "the CLI would wait forever for more input"
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    assert [e.type for e in events] == ["done"]


def test_a_done_with_a_sub_agent_still_working_is_held_and_stop_reaches_it(scripted):
    adapter, proc = scripted
    seen: list[str] = []

    async def script(p):
        p.stdout.feed(_delegation_started())
        p.stdout.feed({"type": "system", "subtype": "task_started", "task_id": "task_9", "tool_use_id": "toolu_d"})
        p.stdout.feed(_result("first turn"))
        await asyncio.sleep(0.05)
        assert not p.stdin.closed, "a sub-agent is running: the control channel must stay open"
        assert await adapter.stop_task("toolu_d") is True
        control = p.stdin.lines[-1]
        assert control["type"] == "control_request"
        assert control["request"] == {"subtype": "stop_task", "task_id": "task_9"}
        p.stdout.feed({"type": "system", "subtype": "task_notification", "task_id": "task_9",
                       "tool_use_id": "toolu_d", "status": "stopped"})
        p.stdout.feed(_result("after the stop"))
        await asyncio.sleep(0.05)
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    statuses = [e.payload["delegate"]["status"] for e in events if e.payload.get("delegate")]
    assert statuses == ["running", "stopped"]
    dones = [e for e in events if e.type == "done"]
    assert len(dones) == 1, "the early result is held, only the final one is the run's end"
    assert dones[0].payload["result"] == "after the stop"
    assert proc.stdin.closed


def test_a_held_done_stands_when_nothing_follows_the_last_sub_agent(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_delegation_started())
        p.stdout.feed({"type": "system", "subtype": "task_started", "task_id": "t", "tool_use_id": "toolu_d"})
        p.stdout.feed(_result("only result"))
        await asyncio.sleep(0.05)
        p.stdout.feed({"type": "system", "subtype": "task_notification", "task_id": "t",
                       "tool_use_id": "toolu_d", "status": "completed"})
        await asyncio.sleep(0.5)  # longer than the (test) grace: no follow-up turn comes
        assert proc.stdin.closed
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    dones = [e for e in events if e.type == "done"]
    assert [d.payload["result"] for d in dones] == ["only result"]


def test_a_held_done_is_still_delivered_if_the_stream_ends(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_delegation_started())
        p.stdout.feed({"type": "system", "subtype": "task_started", "task_id": "t", "tool_use_id": "toolu_d"})
        p.stdout.feed(_result("last words"))
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    assert [e.payload.get("result") for e in events if e.type == "done"] == ["last words"]


def test_a_delegation_left_open_by_one_round_does_not_hold_the_next_rounds_done(scripted):
    adapter, proc = scripted

    async def first(p):
        p.stdout.feed(_delegation_started())
        p.stdout.feed({"type": "system", "subtype": "task_started", "task_id": "t", "tool_use_id": "toolu_d"})
        p.stdout.eof()  # crash mid-delegation: no tool_result, no task_notification

    run(_drive(adapter, proc, first))
    assert adapter._open_delegations, "precondition: the round ended with a delegation open"

    proc.stdout = _Stdout()
    proc.stdin = _Stdin()

    async def second(p):
        p.stdout.feed(_result("round two"))
        await asyncio.sleep(0.05)
        assert p.stdin.closed
        p.stdout.eof()

    events = run(_drive(adapter, proc, second))
    assert [e.payload["result"] for e in events if e.type == "done"] == ["round two"]


def test_a_grace_release_does_not_emit_a_second_done_for_the_follow_up_turn(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_delegation_started())
        p.stdout.feed({"type": "system", "subtype": "task_started", "task_id": "t", "tool_use_id": "toolu_d"})
        p.stdout.feed(_result("held"))
        await asyncio.sleep(0.05)
        p.stdout.feed({"type": "system", "subtype": "task_notification", "task_id": "t",
                       "tool_use_id": "toolu_d", "status": "completed"})
        await asyncio.sleep(0.5)  # grace (0.2s in this suite) elapses
        assert p.stdin.closed
        p.stdout.feed(_result("follow-up turn"))
        await asyncio.sleep(0.05)
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    dones = [e for e in events if e.type == "done"]
    assert [d.payload["result"] for d in dones] == ["follow-up turn"]


def test_stopping_during_the_prompt_write_still_kills_the_process(scripted, monkeypatch):
    adapter, proc = scripted
    killed: list = []

    async def blocked_drain():
        await asyncio.Event().wait()

    proc.stdin.drain = blocked_drain

    async def fake_terminate(p, **kw):
        killed.append(p)

    monkeypatch.setattr(cc, "terminate_tree", fake_terminate)

    async def go():
        async def consume():
            async for _ in adapter.run(task="x" * 10, cwd="/tmp/wt"):
                pass

        t = asyncio.create_task(consume())
        await asyncio.sleep(0.05)
        t.cancel()
        with pytest.raises(asyncio.CancelledError):
            await t

    run(go())
    assert killed == [proc]


def test_only_delegations_are_tracked_a_background_bash_does_not_hold_the_run(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed({"type": "system", "subtype": "task_started", "task_id": "bash1", "tool_use_id": "toolu_bash"})
        p.stdout.feed(_result("done despite a dev server"))
        await asyncio.sleep(0.05)
        assert proc.stdin.closed
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    assert [e.type for e in events] == ["done"]
    assert adapter._open_delegations == set()


def test_stop_is_refused_for_unknown_settled_or_stdinless_delegations(scripted):
    adapter, _proc = scripted
    assert run(adapter.stop_task("never-heard-of-it")) is False
    adapter._task_for["toolu_x"] = "t1"  # known id, but not open (already settled)
    assert run(adapter.stop_task("toolu_x")) is False


def test_the_stop_endpoint_reports_each_refusal_and_success(monkeypatch):
    store = main_mod.store  # other suites swap main's store; always go through main
    ws = store.add_workspace(Workspace(project_id="p", name="w", branch="b", worktree_path="/tmp/x", base_ref="main"))
    key = (ws.id, "default")

    async def call(delegation="toolu_d"):
        return await main_mod.stop_sub_agent(ws.id, delegation, "default")

    try:
        with pytest.raises(HTTPException) as e:
            run(main_mod.stop_sub_agent("ws_missing", "x", "default"))
        assert e.value.status_code == 404
        with pytest.raises(HTTPException) as e:
            run(call())
        assert e.value.status_code == 409 and "no agent run" in e.value.detail

        class Blind:  # an adapter with no stop capability
            pass

        store.run_adapters[key] = Blind()
        with pytest.raises(HTTPException) as e:
            run(call())
        assert e.value.status_code == 409 and "cannot stop" in e.value.detail

        class Fake:
            def __init__(self, ok):
                self.ok = ok

            async def stop_task(self, delegation_id):
                return self.ok

        store.run_adapters[key] = Fake(False)
        with pytest.raises(HTTPException) as e:
            run(call())
        assert e.value.status_code == 409 and "not running" in e.value.detail

        store.run_adapters[key] = Fake(True)
        assert run(call()) == {"stopping": True, "delegation_id": "toolu_d"}
    finally:
        store.run_adapters.pop(key, None)
        store.workspaces.pop(ws.id, None)
