"""The autonomy ladder's rung ACTIONS (backlog/autonomy-ladder.md §3).

``test_trust.py`` proves the ladder's *arithmetic* (which conditions are met) and
``test_trust_wiring.py`` proves the report reaches the UI. This file proves what an armed
rung is allowed to DO, and — mostly — what it refuses to do:

  * nothing at all for a project that hasn't opted in (the default),
  * the one rung, ``auto_pr``, opens a PR and never merges (an ``auto_merge`` rung that
    shipped straight to the user's own ``main`` unattended was cut 2026-09-17),
  * the rung clears ``integrate.ship_preflight`` — the *same* preflights as the manual
    ship buttons — so an uncommitted tree, a busy workspace or a merge-only project
    *hold* the rung instead of shipping,
  * a rung never fires silently, and a failed rung never damages the green verdict,
  * and the handoff really is wired where the workspace has settled (the runner test at
    the bottom: firing while the agent still held its slot would refuse every time).

Real git repos + worktrees throughout, so ``is_clean`` / ``branch_merged`` / ``has_remote``
answer for real. Only the one outbound action (``gh pr create``) is stubbed — that's the
network, not the logic.
"""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

from haro import git_ops, rungs
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.adapters.test_runner.base import TestResult as RunResult  # aliased: pytest collects Test*
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.config import ProjectSettings
from haro.hub import Hub
from haro.models import (
    AgentRun,
    Project,
    TamperFinding,
    TestRun,
    Workspace,
    WorkspaceStatus,
)
from haro.store import DEFAULT_SESSION, Store


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git("init", "-b", "main", cwd=repo)
    _git("config", "user.email", "t@t", cwd=repo)
    _git("config", "user.name", "t", cwd=repo)
    (repo / "a.txt").write_text("base\n")
    _git("add", "-A", cwd=repo)
    _git("commit", "-m", "init", cwd=repo)
    return repo


def _worktree(repo: Path, tmp_path: Path) -> Path:
    """A worktree on its own branch with one committed change — i.e. a workspace that
    has something to ship and a clean tree, the state a rung may act on."""
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_detached_worktree(repo, wt, "main"))
    _git("checkout", "-b", "feat", cwd=wt)
    (wt / "b.txt").write_text("work\n")
    _git("add", "-A", cwd=wt)
    _git("commit", "-m", "feat: the work", cwd=wt)
    return wt


def _policy(**kw) -> ProjectSettings:
    """A policy where every condition's prerequisite is ON and the ladder is armed, so a
    clean green fully clears it (same shape as ``test_trust.py::_settings``)."""
    base = dict(
        trust_enabled=True, trust_streak_required=2, trust_auto_action="auto_pr",
        gate_merge_result=True, coverage_guard="block", flaky_rerun=True,
        # The Double Gate joined the conjunction in backlog/double-gate.md §1, so a policy
        # claiming "every prerequisite is ON" has to enable it too.
        quality_enabled=True,
    )
    base.update(kw)
    return ProjectSettings(**base)


def _fixture(tmp_path, monkeypatch, *, greens: int = 2, run_kw: dict | None = None, **policy_kw):
    """A green workspace on a real worktree, its project's run history seeded with
    ``greens`` clean full-scope greens (the streak substrate), under ``_policy(**policy_kw)``."""
    store, hub = Store(), Hub()
    repo = _repo(tmp_path)
    wt = _worktree(repo, tmp_path)
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="rung demo", branch="feat",
        worktree_path=str(wt), base_ref="main",
    )
    ws.status = WorkspaceStatus.gate_green
    store.workspaces[ws.id] = ws
    for _ in range(greens):
        store.add_test(TestRun(
            workspace_id=ws.id, project_id=project.id, runner="vitest",
            scope="all", status="passed", coverage_delta=0.0,
            # [] = measured clean; the default None means "nobody looked" and would leave
            # the quality rung unmet, so a "clean green" fixture has to say so explicitly.
            # quality_measured=True pairs with it: `findings == []` alone is also what
            # every-scanner-unavailable produces, so a genuinely clean measured run has
            # to say so on both fields (see trust.py's `quality_measured` check).
            quality_findings=[], quality_measured=True, **(run_kw or {}),
        ))
    monkeypatch.setattr(rungs, "load_project_settings", lambda _p: _policy(**policy_kw))
    return store, hub, ws, project


def _stub_pr(monkeypatch, *, boom: str | None = None):
    calls: list[dict] = []

    async def fake_create_pr(worktree_path, branch, base_ref, body=None):
        if boom:
            raise RuntimeError(boom)
        calls.append({"branch": branch, "base_ref": base_ref, "body": body})
        return {"created": True, "already_exists": False, "url": "https://x/pull/9"}

    monkeypatch.setattr(rungs.git_panel, "create_pr", fake_create_pr)
    return calls


def _fire(store, hub, ws) -> dict | None:
    return asyncio.run(rungs.maybe_fire(
        store=store, hub=hub, workspace=ws, test=store.latest_test(ws.id)
    ))


def _rung_events(hub: Hub, ws_id: str) -> list[dict]:
    return [e for e in hub.history(ws_id)
            if e.get("channel") == "notify" and e.get("kind") == "rung"]


# --- the ladder is opt-in ---------------------------------------------------- #
def test_default_project_never_fires_a_rung(tmp_path, monkeypatch):
    """Stock settings: `[trust]` disabled, `auto_action = "off"` → the gate is a plain
    merge-blocker and nothing automatic happens."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(rungs, "load_project_settings", lambda _p: ProjectSettings())
    prs = _stub_pr(monkeypatch)

    assert _fire(store, hub, ws) is None
    assert prs == []
    assert ws.status == WorkspaceStatus.gate_green
    assert _rung_events(hub, ws.id) == []  # not even a notification: nothing happened


def test_short_streak_does_not_fire(tmp_path, monkeypatch):
    """Armed policy but the project hasn't earned it yet — one green, two required."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch, greens=1)
    prs = _stub_pr(monkeypatch)

    assert _fire(store, hub, ws) is None
    assert prs == []


def test_tamper_findings_keep_the_rung_disarmed(tmp_path, monkeypatch):
    """A ``green*`` (the suite got weaker) can't fire the rung — the anti-Goodhart
    precondition, live all the way through to the action (backlog/tamper-alarm.md §3)."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch, run_kw={
        "tamper_findings": [TamperFinding(kind="removed", file="a.test.ts", test="adds")],
        "tamper_note": "1 removed",
    })
    prs = _stub_pr(monkeypatch)

    assert _fire(store, hub, ws) is None
    assert prs == []


def test_red_gate_hands_off_nothing(tmp_path, monkeypatch):
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    ws.status = WorkspaceStatus.gate_red
    prs = _stub_pr(monkeypatch)

    assert _fire(store, hub, ws) is None
    assert prs == []
    assert _rung_events(hub, ws.id) == []  # a red gate is already loud; no extra noise


# --- the rung itself ---------------------------------------------------------- #
def test_auto_pr_opens_a_pr_and_does_not_merge(tmp_path, monkeypatch):
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    prs = _stub_pr(monkeypatch)

    outcome = _fire(store, hub, ws)

    assert outcome and outcome["state"] == "fired" and outcome["action"] == "auto_pr"
    assert len(prs) == 1 and prs[0]["branch"] == "feat"
    assert "Auto-PR’d by the haro autonomy ladder" in prs[0]["body"]
    assert ws.status == WorkspaceStatus.gate_green  # still awaiting a human
    events = _rung_events(hub, ws.id)
    assert len(events) == 1 and events[0]["state"] == "fired"
    assert events[0]["action"] == "auto_pr" and events[0]["streak"] == 2
    assert events[0]["pr_url"] == "https://x/pull/9"


def test_auto_pr_body_carries_the_trust_report(tmp_path, monkeypatch):
    """Attributable: the PR body says which conditions authorized the unattended PR."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    prs = _stub_pr(monkeypatch)

    _fire(store, hub, ws)

    body = prs[0]["body"]
    assert "Auto-PR’d by the haro autonomy ladder" in body
    # 7 since the Double Gate's `quality` row joined the conjunction (double-gate.md §1).
    assert "7/7 trust conditions met, streak 2/2" in body
    for key in ("merge_result", "coverage", "full_scope", "no_flaky", "no_tamper", "streak"):
        assert key in body


def test_auto_pr_arms_without_the_tamper_alarm(tmp_path, monkeypatch):
    """The tamper hard precondition was cut with `auto_merge` (2026-09-17): with the
    alarm off and the project's own `[trust]` dropping the condition, `auto_pr` fires —
    a PR still gets a human's eyes before anything ships."""
    store, hub, ws, _ = _fixture(
        tmp_path, monkeypatch, tamper_alarm="off",
        trust_require={"no_tamper": False},
    )
    prs = _stub_pr(monkeypatch)

    assert _fire(store, hub, ws)["state"] == "fired"
    assert len(prs) == 1
    # …and the dropped condition is visible in the body, not quietly omitted.
    assert "not required by [trust]" in prs[0]["body"]


# --- the shared choke point -------------------------------------------------- #
def test_uncommitted_worktree_holds_the_rung(tmp_path, monkeypatch):
    """The load-bearing refusal: the ladder ships committed work only. It never
    auto-commits on the developer's behalf, so nothing lands unlabeled."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    (Path(ws.worktree_path) / "dirty.txt").write_text("unsaved\n")
    prs = _stub_pr(monkeypatch)

    outcome = _fire(store, hub, ws)

    assert prs == []
    assert outcome["state"] == "held"
    assert "commit your changes first" in outcome["detail"]
    assert ws.status == WorkspaceStatus.gate_green
    # Held is announced: "why didn't my auto-PR happen" must be answerable.
    events = _rung_events(hub, ws.id)
    assert len(events) == 1 and events[0]["state"] == "held"


def test_busy_workspace_holds_the_rung(tmp_path, monkeypatch):
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(store, "busy_reason", lambda _ws_id: "an agent")
    prs = _stub_pr(monkeypatch)

    outcome = _fire(store, hub, ws)

    assert prs == []
    assert outcome["state"] == "held" and "an agent is running" in outcome["detail"]


def test_merge_only_project_holds_auto_pr(tmp_path, monkeypatch):
    """`[workflow] merge_mode = "merge"` means merge-only, no PRs — the rung is refused
    exactly as the PR button is."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch, merge_mode="merge")
    prs = _stub_pr(monkeypatch)

    outcome = _fire(store, hub, ws)

    assert prs == []
    assert outcome["state"] == "held" and "merges directly" in outcome["detail"]


def test_failed_action_keeps_the_green_verdict(tmp_path, monkeypatch):
    """A rung that blows up (a remote hiccup, a missing ``gh``) reports itself and
    leaves the workspace green and hand-shippable — it must never damage the verdict."""
    store, hub, ws, _ = _fixture(tmp_path, monkeypatch)
    _stub_pr(monkeypatch, boom="gh pr create failed: not authenticated")

    outcome = _fire(store, hub, ws)

    assert outcome["state"] == "failed" and "not authenticated" in outcome["detail"]
    assert ws.status == WorkspaceStatus.gate_green
    events = _rung_events(hub, ws.id)
    assert len(events) == 1 and events[0]["state"] == "failed"


# --- where the handoff is wired ---------------------------------------------- #
class _Agent(AgentAdapter):
    name = "stub"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None):
        yield NormalizedEvent("done", {"session_id": "c1"})


class _Runner(TestRunnerAdapter):
    name = "vitest"

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return RunResult(ok=True, total=1, passed=1, failed=0, cases=[])


def test_runner_fires_the_rung_after_releasing_the_agent_slot(tmp_path, monkeypatch):
    """The agent→gate→rung handoff fires from a *settled* workspace: the agent's slot is
    already popped, so the busy guard reads clear. Firing inside the run (the obvious
    place) would hold every single rung with "an agent is running"."""
    store, hub, ws, project = _fixture(tmp_path, monkeypatch)
    ws.status = WorkspaceStatus.idle
    seen: dict = {}

    async def spy(*, store, hub, workspace, test):
        seen["busy"] = store.busy_reason(workspace.id)
        seen["status"] = workspace.status
        seen["test"] = test

    monkeypatch.setattr(rungs, "maybe_fire", spy)
    run = AgentRun(workspace_id=ws.id, adapter="stub", task="do it")
    store.add_run(run)

    async def go():
        from haro.runner import run_agent

        task = asyncio.create_task(run_agent(
            store=store, hub=hub, adapter=_Agent(), workspace=ws, run=run,
            test_adapter=_Runner(), project_path=project.path, auto_gate=True,
        ))
        # Registered exactly as POST /workspaces/{id}/runs does, so busy_reason would
        # report "an agent" for the whole run.
        store.set_active_task(ws.id, DEFAULT_SESSION, task)
        await task

    asyncio.run(go())

    assert seen, "the runner never handed off to the autonomy ladder"
    assert seen["busy"] is None          # the agent slot was released first
    assert seen["status"] == WorkspaceStatus.gate_green
    assert seen["test"] is not None      # the gate result the rung would act on


def test_report_body_marks_dropped_conditions(tmp_path, monkeypatch):
    """The rendered report lists every condition, and says when the policy stopped
    requiring one — a reviewer wants to see the exemptions most of all."""
    from haro.trust import Condition, TrustReport

    report = TrustReport(
        enabled=True, streak=4, streak_required=3, auto_action="auto_pr",
        met=True, armed=True,
        conditions=[
            Condition(key="full_scope", met=True, detail="full suite ran"),
            Condition(key="coverage", met=False, detail="guard off", required=False),
        ],
    )
    body = rungs.report_body(report, "auto_pr")
    assert "1/1 trust conditions met, streak 4/3" in body  # only required ones count
    assert "✓ full_scope: full suite ran" in body
    assert "✕ coverage: guard off (not required by [trust])" in body
