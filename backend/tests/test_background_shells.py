"""Background shells and monitors as rows in the rail's AGENTS list.

Captured live from the CLI (2.1.295): a ``Bash`` with ``run_in_background`` and a ``Monitor``
both start a CLI task (``system/task_started``, ``task_type: "local_bash"``,
``is_backgrounded: true``) and end with ``task_notification`` (``completed`` or ``stopped``).
A foreground ``Bash`` is a task too, with ``is_backgrounded: false``. When the run ends haro
closes stdin and the CLI kills whatever is still running.

haro reports them with the delegation payload (``payload.delegate``) so the client lists,
colours and stops them like sub-agents, but never lets one hold the run's ``done`` back.
"""

from __future__ import annotations

import asyncio

from test_stop_subagent import _result, _drive, run, scripted  # noqa: F401


def _use(tid, name, **inp):
    return {
        "type": "assistant",
        "message": {"content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]},
    }


def _started(tid, task, *, background=True):
    return {
        "type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": tid,
        "description": "d", "is_backgrounded": background, "task_type": "local_bash",
    }


def _ended(tid, task, status):
    return {
        "type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": tid,
        "status": status, "output_file": "", "summary": "s",
    }


def _rows(events):
    return [
        (e.payload["delegate"]["subagent_type"], e.payload["delegate"]["status"],
         e.payload["delegate"]["description"])
        for e in events
        if e.type == "tool_call" and "delegate" in e.payload
    ]


def test_a_background_shell_runs_then_completes(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Bash", command="npm run start", description="dev server",
                           run_in_background=True))
        p.stdout.feed(_started("t1", "b1"))
        p.stdout.feed(_ended("t1", "b1", "completed"))
        p.stdout.feed(_result())
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    assert _rows(events) == [("shell", "running", "dev server"), ("shell", "done", "dev server")]


def test_a_monitor_is_told_apart_from_a_shell(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Monitor", command="tail -f log", description="watch the log"))
        p.stdout.feed(_started("t1", "m1"))
        p.stdout.feed(_ended("t1", "m1", "stopped"))
        p.stdout.feed(_result())
        p.stdout.eof()

    assert _rows(run(_drive(adapter, proc, script))) == [
        ("monitor", "running", "watch the log"),
        ("monitor", "stopped", "watch the log"),
    ]


def test_the_command_stands_in_when_there_is_no_description(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Bash", command="sleep 9", run_in_background=True))
        p.stdout.feed(_started("t1", "b1"))
        p.stdout.feed(_result())
        p.stdout.eof()

    assert _rows(run(_drive(adapter, proc, script)))[0] == ("shell", "running", "sleep 9")


def test_a_foreground_command_is_not_a_shell(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Bash", command="sleep 15"))
        p.stdout.feed(_started("t1", "f1", background=False))
        p.stdout.feed(_ended("t1", "f1", "completed"))
        p.stdout.feed(_result())
        p.stdout.eof()

    assert _rows(run(_drive(adapter, proc, script))) == []


def test_a_shell_left_running_does_not_hold_done_and_is_stopped_with_the_run(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Bash", command="npm run start", run_in_background=True))
        p.stdout.feed(_started("t1", "b1"))
        p.stdout.feed(_result())
        await asyncio.sleep(0.05)
        assert p.stdin.closed  # not held for the shell: the CLI is let go at once
        p.stdout.feed(_ended("t1", "b1", "stopped"))  # the CLI's own late notice: no second row
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    kinds = [e.type for e in events if e.type in ("done", "error") or "delegate" in e.payload]
    assert kinds == ["tool_call", "tool_call", "done"]
    assert _rows(events) == [("shell", "running", "npm run start"),
                             ("shell", "stopped", "npm run start")]


def test_a_single_shell_can_be_stopped(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Bash", command="sleep 99", run_in_background=True))
        p.stdout.feed(_started("t1", "b1"))
        await asyncio.sleep(0.05)
        assert await adapter.stop_task("t1") is True
        assert await adapter.stop_task("unknown") is False
        req = p.stdin.lines[-1]["request"]
        assert req == {"subtype": "stop_task", "task_id": "b1"}
        p.stdout.feed(_ended("t1", "b1", "stopped"))
        await asyncio.sleep(0.05)
        assert await adapter.stop_task("t1") is False  # already settled
        p.stdout.feed(_result())
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    assert _rows(events)[-1][1] == "stopped"


def test_shells_settle_before_a_held_done(scripted):
    """`done` held back by a working sub-agent is released late; the shells the CLI kills when
    stdin finally closes must read stopped before it, not after the run has been finalised."""
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("d1", "Agent", subagent_type="Explore", description="map it",
                           run_in_background=True))
        p.stdout.feed(_started("d1", "tD"))
        p.stdout.feed(_use("t1", "Bash", command="npm run start", run_in_background=True))
        p.stdout.feed(_started("t1", "b1"))
        p.stdout.feed(_result())
        await asyncio.sleep(0.05)
        p.stdout.feed(_ended("d1", "tD", "completed"))
        await asyncio.sleep(0.5)  # past the settle grace: stdin closes, the CLI kills the shell
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    order = [
        e.payload["delegate"]["status"] if "delegate" in e.payload else e.type
        for e in events
        if e.type == "done" or "delegate" in e.payload
    ]
    assert order == ["running", "running", "done", "stopped", "done"]


def test_an_empty_label_falls_back_to_the_kind(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Monitor"))
        p.stdout.feed(_started("t1", "m1"))
        p.stdout.feed(_result())
        p.stdout.eof()

    ev = next(e for e in run(_drive(adapter, proc, script)) if "delegate" in e.payload)
    assert ev.payload["delegate"]["description"] == "monitor"
    assert ev.payload["summary"].startswith("↳ monitor")
    assert ev.payload["delegate"]["kind"] == "monitor"


def test_a_long_description_is_capped(scripted):
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_use("t1", "Bash", command="x", description="d" * 5000, run_in_background=True))
        p.stdout.feed(_started("t1", "b1"))
        p.stdout.feed(_result())
        p.stdout.eof()

    ev = next(e for e in run(_drive(adapter, proc, script)) if "delegate" in e.payload)
    assert len(ev.payload["delegate"]["description"]) == 300


def test_a_cli_that_lingers_on_a_background_task_is_ended_after_the_result(scripted, monkeypatch):
    """With a shell or monitor alive the CLI does not exit when stdin closes (verified live), so
    the run would stay "working" for as long as the task lived. The process group is ended a
    moment after the result instead."""
    from haro.adapters import claude_code as cc

    adapter, proc = scripted
    monkeypatch.setattr(cc, "_EXIT_GRACE_S", 0.2)
    ended = []

    async def fake_terminate(p):
        ended.append(p)
        p.stdout.eof()  # the group is gone: stdout reaches EOF

    monkeypatch.setattr(cc, "terminate_tree", fake_terminate)

    async def script(p):
        p.stdout.feed(_use("t1", "Monitor", command="tail -F log", description="watch"))
        p.stdout.feed(_started("t1", "m1"))
        p.stdout.feed(_result())
        # the CLI stays alive: no eof from the fake process until it is ended

    # Nothing but the end of the process group feeds EOF here, so finishing at all shows the
    # stream ended it (the teardown's own call comes after the stream has finished).
    events = run(_drive(adapter, proc, script))
    assert ended
    assert [e.type for e in events if e.type in ("done", "error")] == ["done"]
    assert _rows(events)[-1] == ("monitor", "stopped", "watch")


def test_a_cli_that_exits_on_its_own_is_left_alone(scripted, monkeypatch):
    from haro.adapters import claude_code as cc

    adapter, proc = scripted
    monkeypatch.setattr(cc, "_EXIT_GRACE_S", 0.2)
    ended = []

    async def fake_terminate(p):
        ended.append(p)

    monkeypatch.setattr(cc, "terminate_tree", fake_terminate)

    async def script(p):
        p.stdout.feed(_result())
        await asyncio.sleep(0.05)
        p.stdout.eof()

    run(_drive(adapter, proc, script))
    assert len(ended) == 1, "only the teardown at the end, not an early kill"



def test_the_leftover_task_result_on_resume_is_not_the_runs_end(scripted, monkeypatch):
    """Live capture (CLI 2.1.295): a resumed process first sends `task_notification: stopped`
    and a `result` with a task-notification origin and `num_turns: 0`, then the real turn.
    Only the real result ends the run, and the exit grace must not start from the first."""
    from haro.adapters import claude_code as cc

    adapter, proc = scripted
    monkeypatch.setattr(cc, "_EXIT_GRACE_S", 0.2)
    ended = []

    async def fake_terminate(p):
        ended.append(p)

    monkeypatch.setattr(cc, "terminate_tree", fake_terminate)

    async def script(p):
        p.stdout.feed(_ended("t0", "b0", "stopped"))
        p.stdout.feed({
            "type": "result", "subtype": "success", "result": "", "num_turns": 0,
            "origin": {"kind": "task-notification"}, "usage": {},
        })
        await asyncio.sleep(0.6)  # the agent thinks for longer than the exit grace
        assert not p.stdin.closed, "stdin is not closed for the leftover result"
        p.stdout.feed(_use("t1", "Bash", command="ls"))
        await asyncio.sleep(0.6)
        p.stdout.feed(_result("the real answer"))
        await asyncio.sleep(0.05)
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    dones = [e for e in events if e.type == "done"]
    assert len(dones) == 1 and dones[0].payload["result"] == "the real answer"
    assert len(ended) == 1, "only the teardown: nothing was killed mid-task"


def test_a_task_notification_turn_with_real_work_still_counts(scripted):
    """A background sub-agent's hand-back, or a shell that finished, starts a CLI turn with a
    task-notification origin and a real model turn: that result is the answer."""
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed({
            "type": "result", "subtype": "success", "result": "handled it", "num_turns": 1,
            "origin": {"kind": "task-notification"}, "usage": {},
        })
        p.stdout.eof()

    events = run(_drive(adapter, proc, script))
    assert [e.payload["result"] for e in events if e.type == "done"] == ["handled it"]
