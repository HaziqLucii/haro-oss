"""``--agents`` (Phase 2 of notes/workflow-roles-plan.md): haro injects its own
read-only scout sub-agent onto the argv rather than relying on
``~/.claude/agents/scout.md`` being on disk — that file never travels with the
project and vanishes outright under ``[agent] sandbox`` (see sandbox.py's
default-deny ``$HOME``). ``test_agents_flag.py`` pins the adapter argv + the
sandboxed-argv-survives property + the delegation-summary rendering;
``test_roles.py`` covers ``scout_agent_json``/``scout_instructions`` in isolation.
The run-path *threading* (runner only passes ``agents`` to adapters that accept
it) mirrors test_fast_mode_thread.py's pattern, folded in here since it's the
same feature.
"""

from __future__ import annotations

import asyncio
import json

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.adapters.claude_code import ClaudeCodeAdapter
from haro.config import RoleConfig
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, Workspace
from haro.roles import scout_agent_json
from haro.runner import run_agent
from haro.store import Store

SCOUT = scout_agent_json(RoleConfig(model="haiku"))


class _EmptyStdout:
    def __aiter__(self):
        return self

    async def __anext__(self):
        raise StopAsyncIteration


class _EmptyStderr:
    async def read(self):
        return b""


class _FakeProc:
    def __init__(self):
        self.stdout = _EmptyStdout()
        self.stderr = _EmptyStderr()
        self.returncode = None
        self.pid = -1

    async def wait(self):
        self.returncode = 0
        return 0


def _capture_cmd(**run_kwargs) -> list[str]:
    """Run the adapter with a stubbed subprocess and return the argv it built."""
    captured: dict[str, list[str]] = {}

    async def fake_exec(*cmd, **_kwargs):
        captured["cmd"] = list(cmd)
        return _FakeProc()

    async def scenario():
        import haro.adapters.claude_code as mod

        orig = mod.asyncio.create_subprocess_exec
        mod.asyncio.create_subprocess_exec = fake_exec
        try:
            adapter = ClaudeCodeAdapter()
            async for _ in adapter.run(task="do a thing", cwd="/tmp/wt", **run_kwargs):
                pass
        finally:
            mod.asyncio.create_subprocess_exec = orig
        return captured["cmd"]

    return asyncio.run(scenario())


# --------------------------------------------------------------------------- #
# Adapter argv
# --------------------------------------------------------------------------- #
def test_no_agents_kwarg_emits_no_agents_flag():
    cmd = _capture_cmd()
    assert "--agents" not in cmd


def test_empty_agents_dict_emits_no_agents_flag():
    # An empty dict is falsy — same as omitting it entirely, never a bare `--agents {}`.
    cmd = _capture_cmd(agents={})
    assert "--agents" not in cmd


def test_agents_dict_is_emitted_as_json():
    cmd = _capture_cmd(agents=SCOUT)
    assert "--agents" in cmd
    raw = cmd[cmd.index("--agents") + 1]
    assert json.loads(raw) == SCOUT


def test_scout_is_registered_read_only_with_the_role_model():
    cmd = _capture_cmd(agents=scout_agent_json(RoleConfig(model="haiku", effort="low")))
    raw = json.loads(cmd[cmd.index("--agents") + 1])
    scout = raw["scout"]
    assert scout["tools"] == ["Read", "Grep", "Glob"]
    assert scout["model"] == "haiku"
    assert "prompt" in scout and scout["prompt"]
    assert "description" in scout and scout["description"]


# --------------------------------------------------------------------------- #
# Sandboxed argv (survives wrap_agent_command)
# --------------------------------------------------------------------------- #
def test_agents_flag_survives_the_sandbox_wrapper(monkeypatch):
    """`[agent] sandbox = true` wraps the whole `cmd` in bwrap (sandbox.py's
    wrap_agent_command) — `--agents` must still be present verbatim on the wrapped
    argv, since it's what makes scout work even though the profile never binds
    `~/.claude/agents`."""
    import haro.adapters.claude_code as mod

    captured: dict[str, list[str]] = {}

    async def fake_exec(*cmd, **_kwargs):
        captured["cmd"] = list(cmd)
        return _FakeProc()

    monkeypatch.setattr(mod.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(mod.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(mod.sandbox_mod, "bwrap_available", lambda: True)
    import haro.sandbox as sandbox_module

    monkeypatch.setattr(sandbox_module.shutil, "which", lambda name: "/usr/bin/claude")

    async def scenario():
        adapter = ClaudeCodeAdapter(sandbox=True)
        async for _ in adapter.run(task="do a thing", cwd="/tmp/wt", agents=SCOUT):
            pass

    asyncio.run(scenario())
    cmd = captured["cmd"]
    assert cmd[0] == "bwrap"
    assert "claude" in cmd
    assert "--agents" in cmd
    assert json.loads(cmd[cmd.index("--agents") + 1]) == SCOUT


# --------------------------------------------------------------------------- #
# Delegation summary rendering
# --------------------------------------------------------------------------- #
def _normalize_assistant(content: list[dict]) -> list[NormalizedEvent]:
    adapter = ClaudeCodeAdapter()
    return adapter._normalize({"type": "assistant", "message": {"content": content}})


def test_a_scout_delegation_renders_as_an_arrow_summary():
    events = _normalize_assistant([
        {"type": "tool_use", "name": "Agent",
         "input": {"subagent_type": "scout", "description": "map the pages"}},
    ])
    assert len(events) == 1
    assert events[0].type == "tool_call"
    assert events[0].payload["summary"] == "↳ scout: map the pages"


def test_the_task_tool_name_is_also_recognized():
    # "Task" was the delegating tool's name before the 2.1.x rename to "Agent".
    events = _normalize_assistant([
        {"type": "tool_use", "name": "Task",
         "input": {"subagent_type": "scout", "description": "find the config"}},
    ])
    assert events[0].payload["summary"] == "↳ scout: find the config"


def test_a_delegation_with_no_description_still_renders_the_arrow():
    events = _normalize_assistant([
        {"type": "tool_use", "name": "Agent", "input": {"subagent_type": "scout"}},
    ])
    assert events[0].payload["summary"] == "↳ scout"


def test_an_ordinary_tool_use_is_unaffected():
    events = _normalize_assistant([
        {"type": "tool_use", "name": "Grep", "input": {"pattern": "foo"}},
    ])
    assert events[0].payload["summary"] == "foo"


def test_an_agent_tool_use_with_no_subagent_type_falls_back_to_the_ordinary_summary():
    # Guards against a malformed/future tool_use shape crashing the summary instead
    # of just describing it like any other tool call.
    events = _normalize_assistant([
        {"type": "tool_use", "name": "Agent", "input": {"prompt": "do something"}},
    ])
    assert events[0].payload["summary"] == "do something"


# --------------------------------------------------------------------------- #
# Delegation lifecycle (running -> done/error), for the agent-manager card
#
# The completion signal is `system:task_notification`, NOT the tool_result that
# closes the delegating tool_use — verified against a live, timestamped capture
# of a `run_in_background: true` delegation: that tool_result is just "Async
# agent launched successfully", arriving ~0.1-0.2s after the start regardless
# of how long the sub-agent actually ran (haro's own production transcripts
# showed this exact gap on real delegations that took 10-30s for real).
# task_notification fires at the true finish time in both the backgrounded and
# synchronous case, so it's the only correlation source used.
# --------------------------------------------------------------------------- #
def _normalize_task_notification(**fields) -> list[NormalizedEvent]:
    adapter = ClaudeCodeAdapter()
    adapter._pending_delegates["toolu_1"] = "scout"
    return adapter._normalize({"type": "system", "subtype": "task_notification", **fields})


def test_a_delegation_tool_use_registers_a_pending_entry_with_a_running_payload():
    adapter = ClaudeCodeAdapter()
    events = adapter._normalize({
        "type": "assistant",
        "message": {"content": [
            {"type": "tool_use", "id": "toolu_1", "name": "Agent",
             "input": {"subagent_type": "scout", "description": "map it"}},
        ]},
    })
    assert events[0].payload["delegate"] == {
        "id": "toolu_1", "subagent_type": "scout", "description": "map it", "status": "running",
    }
    assert adapter._pending_delegates == {"toolu_1": "scout"}


def test_a_completed_task_notification_closes_the_delegation_as_done():
    events = _normalize_task_notification(tool_use_id="toolu_1", status="completed")
    assert len(events) == 1
    assert events[0].payload["delegate"] == {"id": "toolu_1", "subagent_type": "scout", "status": "done"}
    # The handback must read as a distinct, explicit event in the stream, not a
    # silent side-card-only update — this IS the sub-agent handing its result
    # back to the driving agent.
    assert events[0].payload["summary"] == "↳ scout: done — sent back to main agent"


def test_a_non_completed_task_notification_closes_the_delegation_as_error():
    events = _normalize_task_notification(tool_use_id="toolu_1", status="failed")
    assert events[0].payload["delegate"]["status"] == "error"


def test_a_task_notification_for_an_unrelated_id_is_ignored():
    events = _normalize_task_notification(tool_use_id="toolu_other", status="completed")
    assert events == []


def test_a_task_notification_for_a_nested_inner_task_does_not_close_the_delegation():
    # A sub-agent's OWN inner task (e.g. its own Bash call) gets its own
    # task_notification with a DIFFERENT tool_use_id — verified against a live
    # capture. It must not be mistaken for the delegation's own completion.
    events = _normalize_task_notification(tool_use_id="toolu_inner_bash", status="completed")
    assert events == []
    adapter_state_untouched = ClaudeCodeAdapter()
    adapter_state_untouched._pending_delegates["toolu_1"] = "scout"
    adapter_state_untouched._normalize({
        "type": "system", "subtype": "task_notification",
        "tool_use_id": "toolu_inner_bash", "status": "completed",
    })
    assert adapter_state_untouched._pending_delegates == {"toolu_1": "scout"}


def test_the_delegating_tool_result_no_longer_closes_the_delegation():
    """Regression test for the actual bug: a tool_result matching the delegating
    call's own id must NOT close it out, even though it used to (and looks, at a
    glance, like the obvious signal) — for a backgrounded delegation that
    tool_result is just the launch acknowledgment, not the real result."""
    adapter = ClaudeCodeAdapter()
    adapter._pending_delegates["toolu_1"] = "scout"
    events = adapter._normalize({
        "type": "user",
        "message": {"content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "is_error": False},
        ]},
    })
    assert events == []
    assert adapter._pending_delegates == {"toolu_1": "scout"}  # still pending


def test_a_string_content_user_event_is_a_harmless_no_op():
    """A plain-text user turn's `content` is a STRING, not a list of blocks — the
    `user` branch is now an unconditional no-op regardless of shape, but this
    pins that a string content (17% of real transcripts) is still handled
    without blowing up, now that `content` is no longer even inspected."""
    adapter = ClaudeCodeAdapter()
    adapter._pending_delegates["toolu_1"] = "scout"
    events = adapter._normalize({"type": "user", "message": {"content": "a plain string prompt"}})
    assert events == []


def test_a_pending_delegation_left_when_the_process_exits_is_swept_as_error():
    """The subprocess exiting without a tool_result for an in-flight delegation
    (crash, or an odd exit) must not leave that row stuck on "running" forever
    in the agent-manager card — see claude_code.py's end-of-stream sweep."""
    line = json.dumps({
        "type": "assistant",
        "message": {"content": [
            {"type": "tool_use", "id": "toolu_1", "name": "Agent",
             "input": {"subagent_type": "scout", "description": "map it"}},
        ]},
    }).encode() + b"\n"

    class _LinesStdout:
        def __init__(self, lines):
            self._lines = list(lines)

        def __aiter__(self):
            return self

        async def __anext__(self):
            if not self._lines:
                raise StopAsyncIteration
            return self._lines.pop(0)

    class _Proc:
        def __init__(self):
            self.stdout = _LinesStdout([line])
            self.stderr = _EmptyStderr()

        async def wait(self):
            return 0

    adapter = ClaudeCodeAdapter()

    async def scenario():
        return [
            ev
            async for ev in adapter._stream(_Proc(), cwd="/tmp/wt", resume=None, effort=None)
        ]

    events = asyncio.run(scenario())
    delegate_statuses = [
        ev.payload["delegate"]["status"] for ev in events if "delegate" in ev.payload
    ]
    assert delegate_statuses == ["running", "error"]
    assert adapter._pending_delegates == {}


# --------------------------------------------------------------------------- #
# A delegated sub-agent's OWN inner turns (parent_tool_use_id) are suppressed —
# verified against a live `claude -p ... --output-format stream-json` capture: a
# delegated sub-agent's own tool calls, their results, and its final text all
# carry a top-level `parent_tool_use_id` pointing back at the delegating
# Task/Agent tool_use id. Without this, those inner turns rendered as ordinary
# top-level rows with no indication they belonged to the sub-agent, not the
# driving agent.
# --------------------------------------------------------------------------- #
def test_a_sub_agents_own_tool_use_is_suppressed():
    adapter = ClaudeCodeAdapter()
    events = adapter._normalize({
        "type": "assistant",
        "parent_tool_use_id": "toolu_1",
        "message": {"content": [
            {"type": "tool_use", "id": "toolu_inner", "name": "Read",
             "input": {"file_path": "readme.txt"}},
        ]},
    })
    assert events == []


def test_a_sub_agents_own_final_text_is_suppressed():
    adapter = ClaudeCodeAdapter()
    events = adapter._normalize({
        "type": "assistant",
        "parent_tool_use_id": "toolu_1",
        "message": {"content": [{"type": "text", "text": "the file contains hello world"}]},
    })
    assert events == []


def test_a_sub_agents_own_tool_result_is_suppressed():
    adapter = ClaudeCodeAdapter()
    adapter._pending_delegates["toolu_1"] = "scout"
    events = adapter._normalize({
        "type": "user",
        "parent_tool_use_id": "toolu_1",
        "message": {"content": [
            {"type": "tool_result", "tool_use_id": "toolu_inner", "is_error": False},
        ]},
    })
    assert events == []
    # An inner tool_result must never be mistaken for the delegation's OWN
    # closing result — the pending entry survives untouched.
    assert adapter._pending_delegates == {"toolu_1": "scout"}


def test_a_top_level_event_with_no_parent_is_unaffected():
    # No `parent_tool_use_id` key at all (the common case) must behave exactly
    # as before — this guard only fires when the field is present and truthy.
    events = _normalize_assistant([{"type": "tool_use", "name": "Grep", "input": {"pattern": "foo"}}])
    assert events[0].payload["summary"] == "foo"


# --------------------------------------------------------------------------- #
# Run-path threading (runner only passes `agents` to adapters that accept it)
# --------------------------------------------------------------------------- #
class _AgentsAwareAdapter(AgentAdapter):
    name = "agents-aware"

    def __init__(self) -> None:
        self.seen_agents = "unset"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False, fast=False,
                  agents=None):
        self.seen_agents = agents
        yield NormalizedEvent("done", {"session_id": "sess-1"})


class _AgentsBlindAdapter(AgentAdapter):
    """A future/local adapter with no `--agents` support."""

    name = "agents-blind"

    def __init__(self) -> None:
        self.called = False

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        self.called = True
        yield NormalizedEvent("done", {})


def _fixture():
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    return store, hub, ws


def test_agents_reaches_an_adapter_that_accepts_it(monkeypatch):
    async def fake_gate(**kwargs):
        from haro.models import TestRun as RunModel, TestRunStatus as RunStatus

        return RunModel(workspace_id="w", runner="vitest", status=RunStatus.passed)

    monkeypatch.setattr("haro.runner.run_gate", fake_gate)
    store, hub, ws = _fixture()
    adapter = _AgentsAwareAdapter()
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        test_adapter=object(), project_path="/tmp/proj", auto_gate=True, agents=SCOUT,
    ))
    assert adapter.seen_agents == SCOUT
    assert run.status == AgentRunStatus.done


def test_agents_is_hidden_from_adapters_that_cant_take_it(monkeypatch):
    async def fake_gate(**kwargs):
        from haro.models import TestRun as RunModel, TestRunStatus as RunStatus

        return RunModel(workspace_id="w", runner="vitest", status=RunStatus.passed)

    monkeypatch.setattr("haro.runner.run_gate", fake_gate)
    store, hub, ws = _fixture()
    adapter = _AgentsBlindAdapter()
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        test_adapter=object(), project_path="/tmp/proj", auto_gate=True, agents=SCOUT,
    ))
    assert adapter.called is True  # no unexpected-kwarg crash
    assert run.status == AgentRunStatus.done


def test_no_agents_configured_never_touches_an_agents_aware_adapter(monkeypatch):
    async def fake_gate(**kwargs):
        from haro.models import TestRun as RunModel, TestRunStatus as RunStatus

        return RunModel(workspace_id="w", runner="vitest", status=RunStatus.passed)

    monkeypatch.setattr("haro.runner.run_gate", fake_gate)
    store, hub, ws = _fixture()
    adapter = _AgentsAwareAdapter()
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        test_adapter=object(), project_path="/tmp/proj", auto_gate=True,
    ))
    # run_kwargs never set `agents` at all, so the adapter saw its own default (None),
    # not the pre-run "unset" sentinel — `run()` always executes, just without the kwarg.
    assert adapter.seen_agents is None
