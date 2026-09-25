"""WS multiplexing — the ``agent`` channel carries a ``session_id`` so the UI can route
concurrent streams, and each session ``--resume``\\s its OWN Claude conversation
(backlog/agent-modes.md §4, "WS multiplexing").

Two halves:
- **Runner**: driving a run in two different sessions of one workspace tags every
  ``agent`` envelope with its session id, keeps each session's transcript separate, and
  threads a per-session resume id (session A's Claude id never leaks into session B).
- **Routes**: ``GET /sessions`` enumerates a workspace's sessions (always incl. the
  primary), ``GET /events``/``POST /rewind`` are scoped by the ``session`` selector.

No httpx/pytest-asyncio in the gate env, so async handlers/runner are driven directly
with ``asyncio.run`` (the same pattern the other route/adapter tests use).
"""

from __future__ import annotations

import asyncio

from haro import main
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, RewindRequest, Workspace
from haro.runner import run_agent
from haro.store import Store, DEFAULT_SESSION


class _RecordingAdapter(AgentAdapter):
    """Mirrors ClaudeCodeAdapter's ``run`` signature. Records the ``resume`` it was
    called with each turn and yields a fresh, monotonic Claude session id — so a test
    can assert which session's id was resumed on the next turn."""

    name = "recording"

    def __init__(self) -> None:
        self.resumes: list[str | None] = []
        self._n = 0

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        self.resumes.append(resume)
        self._n += 1
        yield NormalizedEvent("token", {"text": f"work {self._n}"})
        yield NormalizedEvent("done", {"session_id": f"claude-{self._n}"})


def _fixture():
    store, hub = Store(), Hub()
    ws = Workspace(
        project_id="p", name="w", branch="haro/w",
        worktree_path="/tmp/wt", base_ref="main",
    )
    store.add_workspace(ws)
    return store, hub, ws


def _run(store, hub, adapter, ws, session_id):
    """Drive one un-gated agent run in ``session_id`` (auto_gate off — no worktree)."""
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        auto_gate=False, session_id=session_id,
    ))
    return run


def _agent_envelopes(hub, ws_id):
    return [e for e in hub.history(ws_id) if e.get("channel") == "agent"]


# --- runner: independent streams --------------------------------------------- #
def test_two_sessions_stream_independently():
    store, hub, ws = _fixture()
    adapter = _RecordingAdapter()

    run_main = _run(store, hub, adapter, ws, DEFAULT_SESSION)
    run_s2 = _run(store, hub, adapter, ws, "s2")

    assert run_main.status == AgentRunStatus.done
    assert run_s2.status == AgentRunStatus.done

    # Each session has its OWN transcript — the s2 run didn't append to main's.
    main_evs = store.events_for(ws.id, DEFAULT_SESSION)
    s2_evs = store.events_for(ws.id, "s2")
    assert [e["payload"].get("text") for e in main_evs if e["type"] == "token"] == ["work 1"]
    assert [e["payload"].get("text") for e in s2_evs if e["type"] == "token"] == ["work 2"]

    # The switcher's set enumerates both, primary first.
    assert store.sessions(ws.id) == [DEFAULT_SESSION, "s2"]


def test_agent_envelopes_carry_session_id():
    store, hub, ws = _fixture()
    adapter = _RecordingAdapter()
    _run(store, hub, adapter, ws, DEFAULT_SESSION)
    _run(store, hub, adapter, ws, "s2")

    envs = _agent_envelopes(hub, ws.id)
    # Every agent envelope is tagged, and the tags partition by session.
    assert all("session_id" in e for e in envs)
    main_ids = {id(e) for e in envs if e["session_id"] == DEFAULT_SESSION}
    s2_ids = {id(e) for e in envs if e["session_id"] == "s2"}
    assert main_ids and s2_ids and not (main_ids & s2_ids)


# --- runner: per-session resume threads -------------------------------------- #
def test_per_session_resume_is_independent():
    store, hub, ws = _fixture()
    adapter = _RecordingAdapter()

    _run(store, hub, adapter, ws, DEFAULT_SESSION)  # turn 1: fresh → yields claude-1
    _run(store, hub, adapter, ws, "s2")             # turn 2: fresh → yields claude-2
    _run(store, hub, adapter, ws, DEFAULT_SESSION)  # turn 3: resumes main's OWN id
    _run(store, hub, adapter, ws, "s2")             # turn 4: resumes s2's OWN id

    # Turns 1 & 2 start cold; turns 3 & 4 resume each session's own last Claude id —
    # main never resumes s2's thread and vice-versa.
    assert adapter.resumes == [None, None, "claude-1", "claude-2"]
    assert ws.session_resume == {DEFAULT_SESSION: "claude-3", "s2": "claude-4"}
    # Backward-compat: the primary session mirrors into last_session_id.
    assert ws.last_session_id == "claude-3"


def test_legacy_last_session_id_resumes_primary():
    # A pre-multi-session workspace only carries last_session_id (no session_resume
    # entry). The primary session must fall back to it on its first resume.
    store, hub, ws = _fixture()
    ws.last_session_id = "legacy-abc"
    adapter = _RecordingAdapter()
    _run(store, hub, adapter, ws, DEFAULT_SESSION)
    assert adapter.resumes == ["legacy-abc"]


# --- routes: session-scoped read + rewind ------------------------------------ #
def _seed_route_ws():
    """Register a workspace with two seeded session transcripts on the module store."""
    ws = Workspace(
        project_id="p", name="w", branch="haro/w",
        worktree_path="/tmp/wt", base_ref="main",
    )
    main.store.add_workspace(ws)
    main.store.append_event(ws.id, {"run_id": "user", "workspace_id": ws.id, "ts": 1.0,
                                    "type": "user", "payload": {"text": "main task"}})
    main.store.append_event(ws.id, {"run_id": "user", "workspace_id": ws.id, "ts": 2.0,
                                    "type": "user", "payload": {"text": "s2 task"}}, "s2")
    return ws


def test_sessions_route_lists_all_incl_primary():
    ws = _seed_route_ws()
    try:
        out = asyncio.run(main.get_sessions(ws.id))
        assert out["sessions"] == [DEFAULT_SESSION, "s2"]
    finally:
        main.store.remove_workspace(ws.id)


def test_events_route_is_session_scoped():
    ws = _seed_route_ws()
    try:
        main_evs = asyncio.run(main.get_events(ws.id))["events"]  # default session
        s2_evs = asyncio.run(main.get_events(ws.id, session="s2"))["events"]
        assert [e["payload"]["text"] for e in main_evs] == ["main task"]
        assert [e["payload"]["text"] for e in s2_evs] == ["s2 task"]
    finally:
        main.store.remove_workspace(ws.id)


def test_rewind_route_targets_the_named_session():
    ws = _seed_route_ws()
    try:
        # Rewind s2's turn 1 → drops only s2's transcript; main is untouched.
        res = asyncio.run(main.rewind_session(ws.id, RewindRequest(turn=1, checkpoint=False, session_id="s2")))
        assert res.prompt == "s2 task"
        assert res.dropped == 1
        assert store_events_text(ws.id, "s2") == []
        assert store_events_text(ws.id, DEFAULT_SESSION) == ["main task"]
    finally:
        main.store.remove_workspace(ws.id)


def store_events_text(ws_id, session):
    return [e["payload"]["text"] for e in main.store.events_for(ws_id, session)]
