"""Stopping a run must not make the next one amnesiac.

The session id is what lets a follow-up ``claude --resume`` continue the same
conversation. It used to be persisted only when the adapter emitted a terminal
``done``/``error`` event — but a user stop cancels the stream *before* any such
event fires, so the id was dropped and the next run started a fresh, contextless
session. The fix persists the id the moment the adapter surfaces it (at the
bootstrap ``system`` event); these tests pin both halves.
"""

import asyncio

from haro.adapters.base import NormalizedEvent
from haro.adapters.claude_code import ClaudeCodeAdapter
from haro.models import AgentRun, Workspace
from haro.runner import _drive_agent
from haro.store import Store


class _FakeHub:
    async def publish(self, *_a, **_k):
        pass


class _StallingAdapter:
    """Yields a bootstrap event carrying the session id, then blocks forever —
    standing in for a long-running agent the user stops mid-turn."""

    name = "claude-code"

    def __init__(self, session_id: str):
        self._session_id = session_id
        self.emitted = asyncio.Event()

    async def run(self, **_kwargs):
        yield NormalizedEvent("token", {"system": True, "model": "claude-opus-4-8",
                                        "session_id": self._session_id})
        self.emitted.set()
        await asyncio.Event().wait()  # never resolves → simulate an in-flight agent


def _workspace() -> Workspace:
    return Workspace(project_id="p", name="w", branch="feat",
                     worktree_path="/tmp/wt", base_ref="main")


def test_stop_persists_session_id_for_the_next_run():
    async def scenario():
        store, hub = Store(), _FakeHub()
        ws = _workspace()
        assert ws.last_session_id is None
        run = AgentRun(workspace_id=ws.id, adapter="claude-code", model=None,
                       effort=None, task="do a thing")
        adapter = _StallingAdapter("sess-abc123")

        task = asyncio.create_task(_drive_agent(
            store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
            instructions=None, max_budget_usd=None, cost_warn_usd=0.0,
        ))
        await adapter.emitted.wait()  # bootstrap event processed
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

        # Session id captured at bootstrap survives the stop → next run resumes.
        assert ws.last_session_id == "sess-abc123"

    asyncio.run(scenario())


def test_bootstrap_event_is_tagged_system():
    # The run loop attaches the session id to whichever normalized event is tagged
    # `system` — pin that the init line still produces exactly that tag, so the
    # eager-persist hook has something to fire on.
    adapter = ClaudeCodeAdapter()
    init = {"type": "system", "subtype": "init", "model": "claude-opus-4-8"}
    events = adapter._normalize(init, resuming=False, effort=None)
    assert events and events[0].payload.get("system") is True
