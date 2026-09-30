"""A plan run's final result text is captured onto `Workspace.plan_text` (Phase 3 of
notes/workflow-roles-plan.md), so the refuter later audits the diff against the plan
the dev actually approved, not just the one-line task. Mirrors
test_plan_done_tag.py's driving pattern (`plan: True` tagging) for the same
`_drive_agent` code path.
"""

import asyncio

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, Workspace
from haro.runner import run_agent
from haro.store import Store


class _PlanAwareAdapter(AgentAdapter):
    name = "plan-aware"

    def __init__(self, result: str) -> None:
        self.result = result

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False):
        yield NormalizedEvent("done", {"session_id": "sess-1", "result": self.result})


def _run(*, plan: bool, result: str = "the approved plan text") -> Workspace:
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w",
                   worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="plan-aware", task="t", plan=plan)
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=_PlanAwareAdapter(result), workspace=ws, run=run,
        test_adapter=None, project_path=None, auto_gate=False, plan=plan,
    ))
    return ws


def test_a_plan_runs_done_result_is_captured_as_plan_text():
    ws = _run(plan=True, result="1. Add retry logic\n2. Add a test for the timeout")
    assert ws.plan_text == "1. Add retry logic\n2. Add a test for the timeout"


def test_a_non_plan_run_never_touches_plan_text():
    ws = _run(plan=False, result="some implementation summary")
    assert ws.plan_text is None


def test_plan_text_is_capped_so_a_huge_plan_cannot_blow_the_refuter_prompt():
    huge = "x" * 20_000
    ws = _run(plan=True, result=huge)
    assert ws.plan_text is not None
    assert len(ws.plan_text) == 16_000


def test_a_later_plan_run_overwrites_the_earlier_plan_text():
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w",
                   worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)

    for text in ("first plan", "revised plan after feedback"):
        run = AgentRun(workspace_id=ws.id, adapter="plan-aware", task="t", plan=True)
        store.add_run(run)
        asyncio.run(run_agent(
            store=store, hub=hub, adapter=_PlanAwareAdapter(text), workspace=ws, run=run,
            test_adapter=None, project_path=None, auto_gate=False, plan=True,
        ))
    assert ws.plan_text == "revised plan after feedback"
