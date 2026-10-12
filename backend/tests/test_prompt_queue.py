"""The prompt queue and steering: prompts typed while the agent is busy.

A queued prompt is held by haro (so it can be removed), starts as its own run when the current
one finishes normally, and can be sent into the running one at its next step ("steer"), which
needs no more than the stdin the CLI already has open. Handlers are called directly.
"""

from __future__ import annotations

import asyncio
import json

import pytest
from fastapi import HTTPException

from haro import main as main_mod
from haro import scope_fence
from haro.adapters.base import AgentAdapter
from haro.adapters.claude_code import ClaudeCodeAdapter
from haro.models import AgentRun, AgentRunStatus, Project, QueuedPrompt, StartAgentRequest, Workspace
from haro.store import DEFAULT_SESSION, store

from test_quiescence import FakeHub, clean_store  # noqa: F401


class _Stdin:
    def __init__(self):
        self.written: list[dict] = []
        self.closed = False

    def write(self, data):
        self.written.append(json.loads(data))

    async def drain(self):
        return None

    def is_closing(self):
        return self.closed


class _Proc:
    def __init__(self):
        self.stdin = _Stdin()


def test_steer_writes_a_next_priority_user_message():
    a = ClaudeCodeAdapter()
    a._proc = _Proc()
    a._tools_open = 1  # a tool call is in flight
    assert asyncio.run(a.steer("use the other table")) is True
    assert a._proc.stdin.written == [{
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": "use the other table"}]},
        "priority": "next",
    }]


def test_steer_is_false_once_stdin_is_closed_or_missing():
    a = ClaudeCodeAdapter()
    a._tools_open = 1
    assert asyncio.run(a.steer("x")) is False  # no process yet
    a._proc = _Proc()
    a._proc.stdin.closed = True
    assert asyncio.run(a.steer("x")) is False


def test_steer_is_refused_once_the_turns_result_has_arrived():
    """Stdin can stay open after the result (sub-agents, background shells); a message then
    would start a second turn the run does not expect."""
    a = ClaudeCodeAdapter()
    a._proc = _Proc()
    a._tools_open = 1
    a._result_seen = True
    assert asyncio.run(a.steer("too late")) is False
    assert a._proc.stdin.written == []


def test_steer_needs_a_tool_call_in_flight():
    """While the model is writing text there is no next step to hand a message over at, and it
    could start a second turn instead."""
    a = ClaudeCodeAdapter()
    a._proc = _Proc()
    assert asyncio.run(a.steer("x")) is False
    assert a._proc.stdin.written == []


def test_an_adapter_that_cannot_take_input_says_no():
    class Plain(AgentAdapter):
        name = "plain"

        def run(self, **kw):  # pragma: no cover
            raise NotImplementedError

    assert asyncio.run(Plain().steer("x")) is False


# -- routes ---------------------------------------------------------------------------


@pytest.fixture
def ws(clean_store, tmp_path, monkeypatch):  # noqa: F811
    hub = FakeHub()
    published: list[dict] = []

    async def publish(ws_id, msg):
        published.append(msg)

    async def no_save(_s):
        return None

    monkeypatch.setattr(main_mod, "store", store)
    monkeypatch.setattr(main_mod.db, "save_snapshot", no_save)
    monkeypatch.setattr(main_mod.hub, "publish", publish)
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(proj)
    w = Workspace(project_id=proj.id, name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(w)
    return w, published


def req(text="do the thing", **kw):
    return StartAgentRequest(task=text, model="sonnet", **kw)


async def busy(w):
    """Register a still-running agent task for the workspace."""
    task = asyncio.ensure_future(asyncio.sleep(30))
    store.set_active_task(w.id, DEFAULT_SESSION, task)
    return task


def test_queueing_needs_a_run_in_progress(ws):
    w, _ = ws
    with pytest.raises(HTTPException) as e:
        asyncio.run(main_mod.queue_prompt(w.id, req()))
    assert e.value.status_code == 409 and w.queued_prompts == []


def test_a_prompt_is_queued_with_its_request_and_published(ws):
    w, published = ws

    async def go():
        t = await busy(w)
        out = await main_mod.queue_prompt(w.id, req("  then add tests  ", effort="high"))
        t.cancel()
        return out

    out = asyncio.run(go())
    (item,) = w.queued_prompts
    assert item.id == out["id"] and item.text == "then add tests"
    assert item.request["model"] == "sonnet" and item.request["effort"] == "high"
    queue_msgs = [m for m in published if m.get("channel") == "queue"]
    assert queue_msgs[-1]["items"] == [{"id": item.id, "text": "then add tests", "session": DEFAULT_SESSION}]


def test_an_empty_prompt_and_a_full_queue_are_refused(ws):
    w, _ = ws

    async def go():
        t = await busy(w)
        with pytest.raises(HTTPException) as e:
            await main_mod.queue_prompt(w.id, req("   "))
        assert e.value.status_code == 400
        for i in range(main_mod._MAX_QUEUED):
            await main_mod.queue_prompt(w.id, req(f"p{i}"))
        with pytest.raises(HTTPException) as e:
            await main_mod.queue_prompt(w.id, req("one more"))
        assert e.value.status_code == 409
        t.cancel()

    asyncio.run(go())


def test_a_queued_prompt_can_be_removed(ws):
    w, _ = ws

    async def go():
        t = await busy(w)
        out = await main_mod.queue_prompt(w.id, req("x"))
        await main_mod.unqueue_prompt(w.id, out["id"])
        with pytest.raises(HTTPException) as e:
            await main_mod.unqueue_prompt(w.id, out["id"])
        assert e.value.status_code == 404
        t.cancel()

    asyncio.run(go())
    assert w.queued_prompts == []


def test_sending_a_queued_prompt_to_a_running_agent_steers_it(ws):
    w, published = ws
    sent: list[str] = []

    class Live:
        async def steer(self, text):
            sent.append(text)
            return True

    async def go():
        t = await busy(w)
        store.run_adapters[(w.id, DEFAULT_SESSION)] = Live()
        out = await main_mod.queue_prompt(w.id, req("use the other table"))
        res = await main_mod.send_queued_prompt(w.id, out["id"])
        t.cancel()
        return res

    assert asyncio.run(go()) == {"sent": "steer"}
    assert sent == ["use the other table"] and w.queued_prompts == []
    row = [m for m in published if m.get("channel") == "agent"][-1]["event"]
    assert row["type"] == "user" and row["payload"] == {"text": "use the other table", "steer": True}
    transcript = store.events[(w.id, DEFAULT_SESSION)]
    assert transcript[-1]["payload"]["steer"] is True


def test_a_run_that_is_not_listening_keeps_the_prompt_queued(ws):
    w, _ = ws

    class Deaf:
        async def steer(self, text):
            return False

    async def go():
        t = await busy(w)
        store.run_adapters[(w.id, DEFAULT_SESSION)] = Deaf()
        out = await main_mod.queue_prompt(w.id, req("later"))
        with pytest.raises(HTTPException) as e:
            await main_mod.send_queued_prompt(w.id, out["id"])
        t.cancel()
        return e.value.status_code

    assert asyncio.run(go()) == 409
    assert [q.text for q in w.queued_prompts] == ["later"]


def test_sending_with_no_run_starts_one(ws, monkeypatch):
    w, _ = ws
    started: list[StartAgentRequest] = []

    async def fake_start(ws_id, r, echo_live=False):
        assert echo_live is True, "a server-started run must show its prompt live"
        started.append(r)
        return AgentRun(adapter="claude-code", workspace_id=ws_id, task=r.task)

    monkeypatch.setattr(main_mod, "_start_counted", fake_start)
    w.queued_prompts.append(QueuedPrompt(text="left over", request={"model": "haiku", "scope": ["src/**"]}))
    out = asyncio.run(main_mod.send_queued_prompt(w.id, w.queued_prompts[0].id))
    assert out["sent"] == "run" and w.queued_prompts == []
    assert started[0].task == "left over" and started[0].model == "haiku" and started[0].scope == ["src/**"]


def test_a_prompt_that_cannot_start_stays_queued(ws, monkeypatch):
    w, _ = ws

    async def refuse(ws_id, r, echo_live=False):
        raise HTTPException(409, "manual mode")

    monkeypatch.setattr(main_mod, "_start_counted", refuse)
    w.queued_prompts.append(QueuedPrompt(text="x"))
    with pytest.raises(HTTPException):
        asyncio.run(main_mod.send_queued_prompt(w.id, w.queued_prompts[0].id))
    assert [q.text for q in w.queued_prompts] == ["x"]


# -- the hand-over after a run ---------------------------------------------------------


def _finish(w, status, started, monkeypatch, *, cancelled=False, boom=False):
    """End a run task the given way, then let the hand-over run."""
    async def fake_start(ws_id, r, echo_live=False):
        started.append(r)
        return AgentRun(adapter="claude-code", workspace_id=ws_id, task=r.task)

    monkeypatch.setattr(main_mod, "_start_counted", fake_start)
    run = AgentRun(adapter="claude-code", workspace_id=w.id, task="first", status=status)

    async def body():
        if boom:
            raise RuntimeError("x")

    async def go():
        t = asyncio.ensure_future(body())
        if cancelled:
            t.cancel()
        try:
            await t
        except BaseException:
            pass
        main_mod._after_run(t, w.id, DEFAULT_SESSION, run)
        await asyncio.gather(*list(main_mod._drains))

    asyncio.run(go())


def test_a_finished_run_starts_the_next_queued_prompt(ws, monkeypatch):
    w, _ = ws
    w.queued_prompts.extend([QueuedPrompt(text="one", request={"effort": "low"}), QueuedPrompt(text="two")])
    started: list[StartAgentRequest] = []
    _finish(w, AgentRunStatus.done, started, monkeypatch)
    assert [r.task for r in started] == ["one"] and started[0].effort == "low"
    assert [q.text for q in w.queued_prompts] == ["two"]


@pytest.mark.parametrize("status,kw", [
    (AgentRunStatus.error, {}),
    (AgentRunStatus.stopped, {}),
    (AgentRunStatus.done, {"cancelled": True}),
    (AgentRunStatus.done, {"boom": True}),
])
def test_a_stopped_or_failed_run_leaves_the_queue_alone(ws, monkeypatch, status, kw):
    w, _ = ws
    w.queued_prompts.append(QueuedPrompt(text="one"))
    started: list[StartAgentRequest] = []
    _finish(w, status, started, monkeypatch, **kw)
    assert started == [] and [q.text for q in w.queued_prompts] == ["one"]


def test_a_queued_prompt_that_cannot_start_stays_queued_and_says_so(ws, monkeypatch):
    w, published = ws

    async def refuse(ws_id, r, echo_live=False):
        raise HTTPException(409, "this session already has an agent running")

    monkeypatch.setattr(main_mod, "_start_counted", refuse)
    w.queued_prompts.extend([QueuedPrompt(text="one"), QueuedPrompt(text="two")])
    run = AgentRun(adapter="claude-code", workspace_id=w.id, task="first", status=AgentRunStatus.done)

    async def go():
        t = asyncio.ensure_future(asyncio.sleep(0))
        await t
        main_mod._after_run(t, w.id, DEFAULT_SESSION, run)
        await asyncio.gather(*list(main_mod._drains))

    asyncio.run(go())
    assert [q.text for q in w.queued_prompts] == ["one", "two"], "nothing typed is lost, order kept"
    said = [m["event"]["payload"]["text"] for m in published if m.get("channel") == "agent"]
    assert any("still in the queue" in t and "already has an agent running" in t for t in said)


def test_a_test_first_task_refuses_queueing(ws):
    from haro.models import TestFirstState

    w, _ = ws
    w.test_first = TestFirstState(phase="drafting")

    async def go():
        t = await busy(w)
        with pytest.raises(HTTPException) as e:
            await main_mod.queue_prompt(w.id, req("follow up"))
        t.cancel()
        return e.value.status_code

    assert asyncio.run(go()) == 409 and w.queued_prompts == []


def test_a_bad_fence_is_refused_when_queueing(ws):
    w, _ = ws

    async def go():
        t = await busy(w)
        with pytest.raises(HTTPException) as e:
            too_many = [f"dir{i}/**" for i in range(scope_fence.MAX_PATTERNS + 1)]
            await main_mod.queue_prompt(w.id, req("x", scope=too_many))
        t.cancel()
        return e.value.status_code

    assert asyncio.run(go()) == 400 and w.queued_prompts == []


def _running(w, **kw):
    run = AgentRun(adapter="claude-code", workspace_id=w.id, task="first", status=AgentRunStatus.running, **kw)
    store.runs[run.id] = run
    return run


def test_a_prompt_queued_with_another_scope_or_mode_is_not_steered(ws):
    w, _ = ws
    steered: list[str] = []

    class Live:
        async def steer(self, text):
            steered.append(text)
            return True

    async def go(item_req, run_kw):
        t = await busy(w)
        store.run_adapters[(w.id, DEFAULT_SESSION)] = Live()
        _running(w, **run_kw)
        item = QueuedPrompt(text="x", request=item_req)
        w.queued_prompts[:] = [item]
        try:
            return await main_mod.send_queued_prompt(w.id, item.id)
        finally:
            t.cancel()

    # same fence: steered
    assert asyncio.run(go({"scope": ["src/**"]}, {"scope": ["src/**"]})) == {"sent": "steer"}
    store.runs.clear()
    # a narrower fence than the run's: its own run instead
    with pytest.raises(HTTPException) as e:
        asyncio.run(go({"scope": ["src/a/**"]}, {"scope": ["src/**"]}))
    assert e.value.status_code == 409 and "scope" in e.value.detail
    store.runs.clear()
    # a plan prompt into a build run
    with pytest.raises(HTTPException) as e:
        asyncio.run(go({"plan": True}, {}))
    assert e.value.status_code == 409 and "plan" in e.value.detail
    assert steered == ["x"], "only the matching one was handed to the agent"


def test_a_server_started_run_shows_its_prompt_live(ws, monkeypatch):
    """The client echoes a prompt it started itself; one the server starts (a queued prompt)
    has nobody to echo it, so it is published."""
    w, published = ws
    published.clear()
    started: dict = {}

    async def fake_agent_start(w_, r, *, echo_live=False):
        started["echo_live"] = echo_live
        return AgentRun(adapter="claude-code", workspace_id=w_.id, task=r.task)

    monkeypatch.setattr(main_mod, "_start_agent", fake_agent_start)
    asyncio.run(main_mod._start_counted(w.id, req("hello"), echo_live=True))
    assert started == {"echo_live": True}
    asyncio.run(main_mod.start_agent(w.id, req("hello")))
    assert started == {"echo_live": False}


def test_the_queue_survives_a_snapshot_round_trip():
    w = Workspace(project_id="p", name="w", branch="b", worktree_path="/x", base_ref="main")
    w.queued_prompts.append(QueuedPrompt(text="keep", request={"model": "haiku"}))
    again = Workspace.model_validate(w.model_dump())
    assert again.queued_prompts[0].text == "keep" and again.queued_prompts[0].request == {"model": "haiku"}
    old = w.model_dump()
    old.pop("queued_prompts")
    assert Workspace.model_validate(old).queued_prompts == []  # rows saved before this field
