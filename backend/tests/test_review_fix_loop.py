"""The review-fix loop (Phase 3 of notes/workflow-roles-plan.md): a SECOND bounded
`while` after the test auto-fix loop, driven only by a refuter FAIL with a
surviving must-fix, and only when `review_role` is armed (`review_enforce =
"block"` — "warn" keeps the verdict without ever spending a fix round, per the
plan doc's cost note). `test_autofix.py` pins the pure helpers for the TEST loop;
this pins both the pure helpers here and the end-to-end loop, mirroring
test_fast_mode_thread.py's drive-`run_agent`-with-a-stubbed-gate pattern.
"""

from __future__ import annotations

import asyncio

from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.config import RoleConfig
from haro.hub import Hub
from haro.models import AgentRun, AgentRunStatus, ReviewMustFix, ReviewVerdict, Workspace
from haro.models import TestRun as RunModel
from haro.models import TestRunStatus as RunStatus
from haro.runner import compose_review_fix_task, run_agent, should_review_fix
from haro.store import Store

# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
def _test_run(status: RunStatus = RunStatus.passed, review: ReviewVerdict | None = None) -> RunModel:
    return RunModel(workspace_id="w", runner="vitest", status=status, review=review or None)


def _fail(n: int = 1) -> ReviewVerdict:
    return ReviewVerdict(
        ran_at=0, model="sonnet", verdict="fail",
        must_fix=[ReviewMustFix(file=f"a{i}.py", title=f"issue {i}", cited="+ x") for i in range(n)],
    )


def _pass() -> ReviewVerdict:
    return ReviewVerdict(ran_at=0, model="sonnet", verdict="pass")


def test_should_review_fix_true_on_a_fail_with_must_fix():
    assert should_review_fix(_test_run(review=_fail())) is True


def test_should_not_review_fix_a_pass_verdict():
    assert should_review_fix(_test_run(review=_pass())) is False


def test_should_not_review_fix_when_review_was_never_measured():
    assert should_review_fix(_test_run(review=None)) is False


def test_compose_review_fix_task_lists_must_fix_with_citations():
    verdict = ReviewVerdict(
        ran_at=0, model="sonnet", verdict="fail",
        must_fix=[ReviewMustFix(file="a.py", line=12, title="off-by-one",
                                 detail="loop excludes the last element", cited="range(len(xs) - 1)")],
    )
    task = compose_review_fix_task(verdict, 1, 2)
    assert "refuter round 1/2" in task
    assert "a.py:12" in task
    assert "off-by-one" in task
    assert "loop excludes the last element" in task
    assert "range(len(xs) - 1)" in task
    assert "do not weaken" in task.lower()


# --------------------------------------------------------------------------- #
# End-to-end loop
# --------------------------------------------------------------------------- #
class _BuildAdapter(AgentAdapter):
    """A build-role-aware adapter: records every call, and can be told to error on
    a specific (1-indexed) call to simulate an agent failure mid-loop."""

    name = "build-aware"

    def __init__(self, error_on_call: int | None = None) -> None:
        self.calls = 0
        self.error_on_call = error_on_call

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False, fast=False, agents=None):
        self.calls += 1
        if self.calls == self.error_on_call:
            yield NormalizedEvent("error", {"message": "agent boom"})
            return
        yield NormalizedEvent("done", {"session_id": f"sess-{self.calls}"})


def _fixture():
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w",
                   worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    return store, hub, ws


def _drive(
    adapter, ws, store, hub, *, gate_sequence: list[RunModel], monkeypatch,
    review_role: RoleConfig | None, review_max_rounds: int = 2, run_role: str = "build",
):
    """Drive `run_agent` with `run_gate` stubbed to return `gate_sequence` in order
    (the last entry repeats once exhausted), recording each call's `trigger` kwarg."""
    calls: list[dict] = []

    async def fake_gate(**kwargs):
        calls.append(kwargs)
        i = min(len(calls) - 1, len(gate_sequence) - 1)
        return gate_sequence[i]

    monkeypatch.setattr("haro.runner.run_gate", fake_gate)
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t", role=run_role)
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run,
        test_adapter=object(), project_path="/tmp/proj", auto_gate=True,
        review_role=review_role, review_max_rounds=review_max_rounds,
    ))
    return run, calls


ROLE = RoleConfig(model="opus", effort="high")


def test_review_role_off_never_enters_the_loop(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    run, calls = _drive(
        adapter, ws, store, hub, gate_sequence=[_test_run(review=_fail())],
        monkeypatch=monkeypatch, review_role=None,
    )
    assert adapter.calls == 1  # only the main run — no fix round ever fired
    assert len(calls) == 1     # only the auto-gate, no re-gate


def test_a_pass_verdict_never_enters_the_loop(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    _drive(
        adapter, ws, store, hub, gate_sequence=[_test_run(review=_pass())],
        monkeypatch=monkeypatch, review_role=ROLE,
    )
    assert adapter.calls == 1


def test_loop_runs_a_fix_round_then_stops_once_the_verdict_passes(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    run, calls = _drive(
        adapter, ws, store, hub,
        gate_sequence=[_test_run(review=_fail()), _test_run(review=_pass())],
        monkeypatch=monkeypatch, review_role=ROLE, review_max_rounds=5,
    )
    assert adapter.calls == 2  # main run + exactly one fix round
    assert len(calls) == 2
    assert calls[1]["trigger"] == "autofix"  # re-gate trigger reuses the test auto-fix value


def test_loop_is_bounded_by_review_max_rounds(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    always_fail = _test_run(review=_fail())
    run, calls = _drive(
        adapter, ws, store, hub, gate_sequence=[always_fail],  # every re-gate still fails
        monkeypatch=monkeypatch, review_role=ROLE, review_max_rounds=2,
    )
    assert adapter.calls == 3  # main run + exactly 2 fix rounds, capped
    assert len(calls) == 3


def test_review_max_rounds_zero_never_enters_the_loop(monkeypatch):
    # Edge case an independent refuter pass singled out: `review_rounds` starts at 0,
    # so `0 < 0` must short-circuit before `should_review_fix` ever runs — config
    # already clamps this to [0, 10], but the loop itself must handle 0 safely too.
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    run, calls = _drive(
        adapter, ws, store, hub, gate_sequence=[_test_run(review=_fail())],
        monkeypatch=monkeypatch, review_role=ROLE, review_max_rounds=0,
    )
    assert adapter.calls == 1  # only the main run
    assert len(calls) == 1


def test_the_fix_run_is_tagged_build_role(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    _drive(
        adapter, ws, store, hub,
        gate_sequence=[_test_run(review=_fail()), _test_run(review=_pass())],
        monkeypatch=monkeypatch, review_role=ROLE, run_role="build",
    )
    fix_runs = [r for r in store.runs.values() if r.task.startswith("An independent reviewer")]
    assert len(fix_runs) == 1
    assert fix_runs[0].role == "build"


def test_breaks_on_agent_error_without_spinning_further(monkeypatch):
    store, hub, ws = _fixture()
    # Errors on call #2 — the first fix round's agent run.
    adapter = _BuildAdapter(error_on_call=2)
    run, calls = _drive(
        adapter, ws, store, hub, gate_sequence=[_test_run(review=_fail())],
        monkeypatch=monkeypatch, review_role=ROLE, review_max_rounds=5,
    )
    assert adapter.calls == 2       # main run + the one failed fix attempt
    assert len(calls) == 1          # no re-gate after a fix run that didn't finish


def test_breaks_if_a_review_fix_turns_the_tests_red(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    run, calls = _drive(
        adapter, ws, store, hub,
        gate_sequence=[_test_run(review=_fail()), _test_run(status=RunStatus.failed)],
        monkeypatch=monkeypatch, review_role=ROLE, review_max_rounds=5,
    )
    # One fix round ran, its re-gate came back with the TESTS red — left for a human,
    # never chased with a second round despite max_rounds=5.
    assert adapter.calls == 2
    assert len(calls) == 2


def test_review_fix_round_is_announced_in_the_transcript(monkeypatch):
    store, hub, ws = _fixture()
    adapter = _BuildAdapter()
    _drive(
        adapter, ws, store, hub,
        gate_sequence=[_test_run(review=_fail(n=3)), _test_run(review=_pass())],
        monkeypatch=monkeypatch, review_role=ROLE, review_max_rounds=5,
    )
    announces = [
        e for e in store.events_for(ws.id)
        if e.get("type") == "user" and e.get("run_id") == "reviewfix"
    ]
    assert len(announces) == 1
    assert "3 must-fix" in announces[0]["payload"]["text"]
