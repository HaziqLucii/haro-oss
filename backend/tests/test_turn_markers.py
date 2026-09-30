"""Per-turn markers in the persisted transcript — the "rewind to here" anchors.

``Store.append_event`` tags every event with a monotonic per-workspace ``turn``
ordinal: a ``user`` event (a prompt echo, or an auto-fix announce) opens a new turn,
and every agent event that follows shares it until the next ``user`` event. ``turns``
derives the rewindable boundaries (one per ``user`` event) the UI lists rewind points
from. These pin: (a) the ordinal increments only on ``user`` events, (b) token
coalescing never breaks turn continuity, (c) the derivation carries prompt + kind, and
(d) a real driven run threads consistent turns onto its emitted events.
"""

import asyncio

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, Workspace
from haro.runner import run_agent
from haro.store import Store


def _user(text: str, run_id: str = "user") -> dict:
    return {"run_id": run_id, "workspace_id": "w", "ts": 0.0, "type": "user",
            "payload": {"text": text}}


def _agent(ev_type: str, **payload) -> dict:
    return {"run_id": "r", "workspace_id": "w", "ts": 0.0, "type": ev_type,
            "payload": payload}


def test_turn_increments_only_on_user_events():
    store = Store()
    store.append_event("w", _user("first"))
    store.append_event("w", _agent("tool_call", tool="Read"))
    store.append_event("w", _agent("done", tokens_in=1))
    store.append_event("w", _user("second"))
    store.append_event("w", _agent("token", text="hi"))
    turns = [e["turn"] for e in store.events_for("w")]
    assert turns == [1, 1, 1, 2, 2]


def test_agent_event_before_any_user_defaults_to_turn_one():
    store = Store()
    store.append_event("w", _agent("token", text="orphan"))
    assert store.events_for("w")[0]["turn"] == 1


def test_token_coalescing_preserves_the_turn():
    """Consecutive same-run tokens coalesce into one entry (store's compaction) — the
    surviving entry must keep its turn, since tokens never cross a ``user`` event."""
    store = Store()
    store.append_event("w", _user("go"))
    for chunk in ("a", "b", "c"):
        store.append_event("w", {"run_id": "r", "workspace_id": "w", "ts": 0.0,
                                 "type": "token", "payload": {"text": chunk}})
    toks = [e for e in store.events_for("w") if e["type"] == "token"]
    assert len(toks) == 1  # coalesced
    assert toks[0]["payload"]["text"] == "abc"
    assert toks[0]["turn"] == 1


def test_turns_derivation_one_marker_per_user_event():
    store = Store()
    store.append_event("w", _user("build it"))
    store.append_event("w", _agent("done"))
    store.append_event("w", _user("gate red…", run_id="autofix"))
    markers = store.turns("w")
    assert [m["turn"] for m in markers] == [1, 2]
    assert [m["prompt"] for m in markers] == ["build it", "gate red…"]
    assert [m["kind"] for m in markers] == ["user", "autofix"]


class _Adapter(AgentAdapter):
    name = "stub"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        yield NormalizedEvent("token", {"text": "working"})
        yield NormalizedEvent("done", {"session_id": "s", "tokens_in": 1, "tokens_out": 2})


def test_driven_run_threads_turns_onto_emitted_events():
    """A full run: the prompt echo opens turn 1; the adapter's token + done inherit it,
    so the whole transcript reads as a single coherent turn."""
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w",
                   worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    # Mirror main.py: echo the user's prompt into the transcript before the run.
    store.append_event(ws.id, {"run_id": "user", "workspace_id": ws.id, "ts": 0.0,
                               "type": "user", "payload": {"text": "do it"}})
    run = AgentRun(workspace_id=ws.id, adapter="stub", task="do it")
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=_Adapter(), workspace=ws, run=run,
        test_adapter=None, project_path=None, auto_gate=False,
    ))
    assert all(e["turn"] == 1 for e in store.events_for(ws.id))
    assert [m["turn"] for m in store.turns(ws.id)] == [1]
