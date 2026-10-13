"""A plan run tags its terminal ``done`` event ``plan: True`` in the transcript.

The composer's approval bar (Approve → implement / Give feedback) is driven by
``awaitingPlan`` on the frontend, which fires when the last terminal event is a
plan ``done``. That signal is the ``plan: True`` flag the runner writes onto the
``done`` payload in ``_drive_agent`` — so pin it here (the gate-skip + feature-
detect behavior lives in ``test_plan_mode_thread.py``; this pins the UI's data
dependency). A non-plan run must NOT carry the flag, or the bar would show for a
normal auto-edit run.
"""

import asyncio

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, Workspace
from haro.runner import run_agent
from haro.store import Store


class _PlanAwareAdapter(AgentAdapter):
    """Mirrors ClaudeCodeAdapter: its ``run`` accepts ``plan``."""

    name = "plan-aware"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False):
        yield NormalizedEvent("done", {"session_id": "sess-1", "tokens_in": 1, "tokens_out": 2})


def _done_events(store: Store, ws_id: str) -> list[dict]:
    return [e for e in store.events_for(ws_id) if e.get("type") == "done"]


def _run(*, plan: bool) -> list[dict]:
    """Drive a plan-mode run (gate is skipped for it anyway) and return its done
    events from the persisted transcript."""
    store, hub = Store(), Hub()
    ws = Workspace(
        project_id="p", name="w", branch="haro/w",
        worktree_path="/tmp/wt", base_ref="main",
    )
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="plan-aware", task="t", plan=plan)
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=_PlanAwareAdapter(), workspace=ws, run=run,
        # auto_gate off keeps the non-plan case from trying to run a real gate; the
        # done-tagging under test happens in _drive_agent, before any gate handoff.
        test_adapter=None, project_path=None, auto_gate=False, plan=plan,
    ))
    return _done_events(store, ws.id)


def test_plan_run_tags_done_event():
    done = _run(plan=True)
    assert len(done) == 1
    assert done[0]["payload"].get("plan") is True


def test_non_plan_run_leaves_done_untagged():
    done = _run(plan=False)
    assert len(done) == 1
    assert done[0]["payload"].get("plan") is not True
