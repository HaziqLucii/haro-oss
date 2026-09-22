"""Winner-only fan-out — the IO shell around the pure judge in ``race.py``.

``race.py`` decides; this *does*. Same split as ``trust.py`` → ``rungs.py`` and
``merge_queue.py`` → ``main.run_merge_queue``, and for the same reason: the ranking is
the part that has to be provably deterministic, so everything that touches git, the
store, subprocesses or the clock is quarantined here (backlog/winner-fanout.md).

The shape of a race:

    preflight  §0  refuse to start uncapped / on a suite too thin to referee with
    seed       §1  N sibling workspaces via the ordinary create-workspace machinery
    dispatch   §1  the SAME prompt down every lane, each with its own model/effort
    supervise  §0  watch the summed spend; stop the survivors at the race ceiling
    judge      §2  hand the gate facts to ``race.judge`` and store its verdict
    ceremony   §3  soft-archive the losers — row, transcript and branch all kept

The two ideas worth not breaking:

* **A lane's green must mean the same thing as its rivals' green.** Lanes force
  merge-result gating, the flaky confirmation re-run and full-scope, whatever the
  project's own defaults are, because ranking is a comparison and a comparison
  between differently-strict verdicts is meaningless.
* **Losers are soft-archived, never deleted.** ``main._teardown_workspace`` drops the
  store row; this keeps it and removes only the checkout, so the scorecard's loser rows
  stay clickable and their branches stay diffable. Purging is a separate, explicit act.
"""

from __future__ import annotations

import asyncio
import dataclasses
import time
from pathlib import Path
from typing import Awaitable, Callable, Optional

from . import git_ops, race
from .adapters import ClaudeCodeAdapter
from .adapters.test_runner.base import TestRunnerAdapter
from .config import ProjectSettings, RaceLaneConfig
from .hub import Hub
from .lifecycle import quiesce_workspace, run_archive
from .models import (
    AgentRun,
    Project,
    RaceLane,
    RaceRun,
    StartRaceRequest,
    TestRun,
    TestRunStatus,
    Workspace,
    WorkspaceStatus,
)
from .runner import run_agent
from .store import DEFAULT_SESSION, SETUP_SESSION, Store

#: How often the budget watchdog re-sums the lanes' spend. Cost only becomes visible
#: when a run reports its terminal ``done`` event, so a tighter poll buys nothing —
#: this is "notice promptly when a lane lands", not "sample a live meter".
_BUDGET_POLL_SECS = 3.0

#: Seed the lane workspace names as ``<task> · <model>-<effort>`` so the sidebar rows,
#: the branch names and the scorecard all read the same way.
_LANE_SEP = " · "

#: split_authors' per-role prompt addendum (usp-critique-round3.md Move C). Neither
#: lane is told the other exists beyond "there is another lane" — telling a lane
#: WHAT the other lane will write would let it hedge/compensate, which defeats the
#: point of splitting authorship in the first place.
_ROLE_PROMPTS = {
    "tests_only": (
        "\n\nSPLIT-AUTHOR CONSTRAINT (part of a two-lane race): write ONLY test "
        "changes for this task — add or modify test files that specify the required "
        "behaviour. Do NOT modify implementation/source files; another lane is "
        "writing those independently."
    ),
    "impl_only": (
        "\n\nSPLIT-AUTHOR CONSTRAINT (part of a two-lane race): write ONLY "
        "implementation changes for this task. Do NOT modify test files; another "
        "lane is writing those independently."
    ),
}


def _augment_task_for_role(task: str, role: str) -> str:
    """The lane's actual prompt: the shared race task plus its role constraint, if
    any. An ordinary (non-split_authors) lane has ``role == ""`` and gets the task
    back unchanged."""
    extra = _ROLE_PROMPTS.get(role)
    return f"{task}{extra}" if extra else task


class RaceRefused(Exception):
    """§0 said no. Carries every refusal at once — a misconfigured project usually
    trips more than one, and discovering them one 400 at a time is a bad loop."""

    def __init__(self, refusals: list[str]) -> None:
        super().__init__("; ".join(refusals))
        self.refusals = refusals


# The create-workspace seed machinery, injected rather than imported: it lives in
# ``main.py`` (it needs the slug/port/setup plumbing the REST layer already owns), and
# importing main from here would be a cycle. Same trick ``merge_queue`` uses for its
# git calls — the shell's own dependencies stay injectable, so a test can race without
# creating a single worktree.
SeedFn = Callable[..., Awaitable[Workspace]]


# --------------------------------------------------------------------------- #
# §0 — preflight
# --------------------------------------------------------------------------- #
def resolve_lanes(
    psettings: ProjectSettings, override: Optional[list[dict]] = None
) -> list[RaceLaneConfig]:
    """The lane grid for this race: a per-request override, else the project's
    ``[race] lanes``, always truncated to ``[race] max_lanes``.

    The cap is applied *here*, after the override, on purpose: a client picking its own
    lanes must not be able to widen the fleet past the project's ceiling."""
    lanes: list[RaceLaneConfig] = []
    for item in override or []:
        model = str(item.get("model", "")).strip().lower()
        if model:
            lanes.append(RaceLaneConfig(model=model, effort=str(item.get("effort", "")).strip().lower()))
    lanes = lanes or list(psettings.race_lanes)
    if psettings.race_policy == "split_authors":
        # Two role-tagged lanes, not a ranked grid (usp-critique-round3.md Move C):
        # one writes tests, the other writes the implementation, so no single model
        # can encode the same misreading into both halves. Whatever grid was
        # configured collapses to its first entry's model/effort — split_authors
        # measures whether splitting authorship catches something a single author's
        # correlated tests+impl would miss, not model×effort.
        base = lanes[0] if lanes else RaceLaneConfig(model="sonnet", effort="")
        return [
            RaceLaneConfig(model=base.model, effort=base.effort, role="tests_only"),
            RaceLaneConfig(model=base.model, effort=base.effort, role="impl_only"),
        ]
    return lanes[: max(2, psettings.race_max_lanes)]


async def suite_size(
    adapter: TestRunnerAdapter, *, cwd: str, base_ref: str
) -> Optional[int]:
    """How many tests the suite holds at ``base_ref`` — the pre-flight thin-suite input.

    ``None`` when the runner can't tell us (no module graph: pytest, the generic
    command adapter). That is explicitly *not* a refusal — see ``race.preflight`` — but
    it does mean the judge-time impacted check is the only thin-suite guard left."""
    try:
        result = await adapter.analyze_impact(cwd=cwd, base_ref=base_ref)
    except Exception:  # noqa: BLE001 — an unmeasurable suite is unknown, not a crash
        return None
    if not result.supported:
        return None
    return len(result.all_tests)


async def preflight_race(
    *,
    project: Project,
    psettings: ProjectSettings,
    test_adapter: TestRunnerAdapter,
    lanes: Optional[list[RaceLaneConfig]] = None,
) -> tuple[race.Preflight, list[RaceLaneConfig], Optional[int]]:
    """Run §0's hard gate for real: measure the suite, then ask the pure decision.

    Exposed on its own (``GET /projects/{id}/race/preflight``) so the composer can grey
    the race button out *and say why* before anyone spends a dollar. A refusal found
    after three worktrees exist is a refusal that already cost money."""
    lanes = lanes or resolve_lanes(psettings)
    gate_root = str(Path(project.path) / psettings.gate_dir) if psettings.gate_dir else project.path
    tests = await suite_size(test_adapter, cwd=gate_root, base_ref=project.default_branch)
    pf = race.preflight(
        enabled=psettings.race_enabled,
        lane_count=len(lanes),
        max_budget_usd=psettings.max_budget_usd,
        max_total_usd=psettings.race_max_total_usd,
        suite_tests=tests,
        min_suite_tests=psettings.race_min_suite_tests,
    )
    return pf, lanes, tests


# --------------------------------------------------------------------------- #
# §1 — race machinery
# --------------------------------------------------------------------------- #
def lane_gate_settings(psettings: ProjectSettings) -> ProjectSettings:
    """The project's config with the three things a race cannot do without forced on.

    ``gate_merge_result`` — the winner's green has to be the *merge result's* green, or
    a race just crowns whoever branched most recently. ``flaky_rerun`` — without the
    confirmation re-run a lane's flake is invisible, and the judge would rank a coin
    toss. ``gate_default_scope = "all"`` — an impacted-only gate deliberately runs less
    of the suite, and "we ran less of the suite for the winner" is not a claim this
    feature can afford to make.

    Note every one of these only ever makes a lane's gate *stricter*, which is why
    overriding project config here is defensible rather than a back door."""
    return dataclasses.replace(
        psettings,
        gate_merge_result=True,
        flaky_rerun=True,
        gate_default_scope="all",
    )


async def start_race(
    *,
    store: Store,
    hub: Hub,
    project: Project,
    psettings: ProjectSettings,
    req: StartRaceRequest,
    seed_workspace: SeedFn,
    test_adapter: TestRunnerAdapter,
) -> RaceRun:
    """Seed the lanes and hand the race to a background supervisor.

    Returns as soon as the workspaces exist, like ``create_workspace`` does — the
    agents, the gates, the judging and the ceremony all happen under
    ``store.race_tasks[race.id]`` and report over the global feed.

    Raises ``RaceRefused`` when §0 says no, **before** creating anything: the refusal
    has to be free, or the check that exists to stop N× spend has itself cost N
    worktrees."""
    lanes = resolve_lanes(psettings, req.lanes)
    pf, lanes, _tests = await preflight_race(
        project=project, psettings=psettings, test_adapter=test_adapter, lanes=lanes
    )
    if not pf.ok:
        raise RaceRefused(pf.refusals)

    first_line = next((ln.strip() for ln in req.task.splitlines() if ln.strip()), "")
    base_name = ((req.name or first_line).strip() or "race")[:60]

    run = RaceRun(
        project_id=project.id,
        task=req.task,
        policy=psettings.race_policy,
        max_total_usd=pf.max_total_usd,
    )
    store.add_race(run)

    # Seed the siblings one at a time. `git worktree add` serializes on the repo's
    # index lock anyway (git_ops._cwd_locks), so a gather here would buy nothing but a
    # harder-to-read failure mode.
    try:
        for lane in lanes:
            ws = await seed_workspace(
                project=project,
                name=f"{base_name}{_LANE_SEP}{lane.label}",
                base_ref=req.base_ref,
                seed_key=req.seed_key,
                race_id=run.id,
            )
            run.lanes.append(
                RaceLane(
                    workspace_id=ws.id, name=ws.name, branch=ws.branch,
                    model=lane.model, effort=lane.effort, role=lane.role, status="pending",
                )
            )
    except Exception:
        # A half-seeded race must be settled, not left `running` with no supervisor — a
        # spinner nobody owns is the one state the UI can't recover from. The lanes that
        # WERE created stay: they're real worktrees, and silently tearing down a
        # workspace the user can already see would be worse than an honest failed race.
        run.status = "failed"
        run.reason = "could not seed every lane — the lanes that were created are kept"
        run.ended_at = time.time()
        await _publish_race(hub, run, kind="race_done")
        raise

    await _publish_race(hub, run, kind="race_started")
    store.race_tasks[run.id] = asyncio.create_task(
        _supervise(
            store=store, hub=hub, project=project, psettings=psettings,
            run=run, test_adapter=test_adapter,
        )
    )
    return run


async def _run_lane(
    *,
    store: Store,
    hub: Hub,
    project: Project,
    psettings: ProjectSettings,
    run: RaceRun,
    lane: RaceLane,
    test_adapter: TestRunnerAdapter,
) -> None:
    """Drive ONE lane: wait out its provisioning, run the agent, gate it, record facts.

    Never raises for an expected failure — a lane that errors is a *result* (a red
    scorecard row), not an exception that should take its siblings down. Cancellation
    is the one thing that propagates, because that's the budget ceiling stopping us."""
    ws = store.get_workspace(lane.workspace_id)
    if ws is None:
        lane.status = "error"
        lane.note = "workspace vanished before the lane could start"
        return

    # Lanes are born `setting_up` (the create path provisions deps in the background)
    # and an agent may not start until that finishes — the same rule `start_agent`
    # enforces. Awaiting the setup task is how a race avoids racing its own installs.
    setup = store.active_task(ws.id, SETUP_SESSION)
    if setup is not None and not setup.done():
        try:
            await setup
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 — a failed setup surfaces as the lane's gate error
            pass

    lane.status = "running"
    await _publish_race(hub, run, kind="race_lane")

    # split_authors (usp-critique-round3.md Move C): the shared race task gets a
    # role-specific constraint appended before it becomes the actual prompt, so the
    # lane's transcript shows exactly what it was told — not the bare shared task,
    # which would silently under-describe what a "tests_only"/"impl_only" lane did.
    lane_task = _augment_task_for_role(run.task, lane.role)
    agent_run = AgentRun(
        workspace_id=ws.id,
        adapter="claude-code",
        model=lane.model,
        effort=lane.effort or None,
        task=lane_task,
    )
    store.add_run(agent_run)
    # Echo the prompt into the lane's transcript so each sibling reads as a normal
    # conversation — a loser's transcript is the thing §3 keeps, so it has to be whole.
    store.append_event(
        ws.id,
        {"run_id": "user", "workspace_id": ws.id, "ts": time.time(), "type": "user",
         "payload": {"text": lane_task}},
        DEFAULT_SESSION,
    )
    # Register THIS coroutine as the lane's agent task so the ⏹ stop button, the
    # busy guards and the teardown paths all see a running agent (main.start_agent
    # registers the equivalent handle for a hand-started run).
    current = asyncio.current_task()
    if current is not None:
        store.set_active_task(ws.id, DEFAULT_SESSION, current)

    async def on_gate(test: TestRun) -> None:
        await _stamp_lane(
            store=store, project=project, psettings=psettings, run=run, lane=lane,
            test=test, test_adapter=test_adapter,
        )
        await _publish_race(hub, run, kind="race_lane")

    await run_agent(
        store=store,
        hub=hub,
        # Races are Claude-Code-only, and deliberately so: a lane IS a (model, reasoning
        # effort) point, which is a Claude concept — the local backend has no effort knob
        # and racing one local model against itself would measure sampling noise, not
        # whether the extra spend bought anything. The composer disables the race button
        # on the local backend rather than silently billing a "no cloud" user for three
        # cloud runs. Making lanes adapter-aware is the follow-up if a rival adapter
        # ever grows a comparable knob.
        adapter=ClaudeCodeAdapter(sandbox=psettings.agent_sandbox),
        workspace=ws,
        run=agent_run,
        test_adapter=test_adapter,
        project_path=project.path,
        auto_gate=True,
        instructions=psettings.instructions,
        max_budget_usd=psettings.max_budget_usd,
        cost_warn_usd=psettings.cost_warn_usd,
        auto_fix=psettings.auto_fix,
        auto_fix_max_rounds=psettings.auto_fix_max_rounds,
        # Forced full-scope + merge-result + flaky-confirmed: see lane_gate_settings.
        gate_scope="all",
        gate_settings=lane_gate_settings(psettings),
        on_gate=on_gate,
    )


async def _stamp_lane(
    *,
    store: Store,
    project: Project,
    psettings: ProjectSettings,
    run: RaceRun,
    lane: RaceLane,
    test: TestRun,
    test_adapter: TestRunnerAdapter,
) -> None:
    """Copy a settled gate's facts onto the lane, and measure the two the gate doesn't
    record: the diff's blast radius and its size.

    Both extra measurements are paid for **per race**, not per gate — that's why they
    live here and not in ``run_gate``. ``impacted_tests`` is a reserved field on
    ``TestRun`` that nothing populated until now; filling it here means the thin-suite
    guard reads exactly what backlog/winner-fanout.md §2 says it reads.
    """
    ws = store.get_workspace(lane.workspace_id)
    # The workspace status — not the raw TestRun status — is the verdict, because it's
    # the one that already folds in coverage/tamper/merge blocking (see gate.run_gate's
    # `green` conjunction). Reading `test.status == passed` here would call a
    # coverage-blocked run green and hand the race to the lane that broke coverage.
    lane.green = bool(ws and ws.status == WorkspaceStatus.gate_green)
    if lane.green:
        lane.status = "green"
    elif test.status == TestRunStatus.error:
        lane.status = "error"
    else:
        lane.status = "red"
    lane.wall_ms = test.wall_ms
    lane.coverage_delta = test.coverage_delta
    lane.merge_conflict = test.merge_conflict
    lane.flaky = list(test.flaky_tests)
    lane.degraded = bool(test.degraded_reasons)
    lane.tamper_count = len(test.tamper_findings)
    lane.finished_at = test.ended_at
    lane.cost_usd = _lane_cost(store, lane.workspace_id)

    if ws is None:
        return
    gate_cwd = str(Path(ws.worktree_path) / psettings.gate_dir) if psettings.gate_dir else ws.worktree_path
    try:
        impact = await test_adapter.analyze_impact(cwd=gate_cwd, base_ref=ws.base_ref)
        if impact.supported:
            names = [t.name for t in impact.impacted]
            lane.impacted_count = len(names)
            # Fill the reserved TestRun field so the record carries the same number the
            # judge saw — a scorecard you can't reconcile with the run is not evidence.
            test.impacted_tests = names
    except Exception:  # noqa: BLE001 — an unmeasurable blast radius stays 0 and the
        pass          # thin-suite guard then (correctly) refuses to auto-judge.
    try:
        files = await git_ops.changed_files(ws.worktree_path, ws.base_ref)
        lane.diff_lines = sum(int(f.get("added", 0)) + int(f.get("removed", 0)) for f in files)
    except Exception:  # noqa: BLE001 — diff size is only the last tie-break link
        pass


def _lane_cost(store: Store, ws_id: str) -> float:
    """Everything this lane's workspace has spent, across its agent run and any
    auto-fix rounds. Summing the runs (rather than reading the first one) is what makes
    ``cheapest_green`` honest when a lane needed three tries to get there."""
    return round(sum(r.cost_usd or 0.0 for r in store.runs.values() if r.workspace_id == ws_id), 6)


async def _watch_budget(*, store: Store, hub: Hub, run: RaceRun, tasks: list[asyncio.Task]) -> None:
    """§0's race-level ceiling: stop the survivors once the lanes' summed spend crosses
    ``max_total_usd``.

    N× token spend is the headline risk of this whole feature, so the ceiling is
    enforced by *cancelling work*, not by a warning nobody reads. Cancelled lanes are
    recorded as ``stopped`` with the reason on the scorecard — a race that hit its
    ceiling must never be mistaken for one where those lanes simply lost."""
    while True:
        await asyncio.sleep(_BUDGET_POLL_SECS)
        if all(t.done() for t in tasks):
            return
        spent = sum(_lane_cost(store, l.workspace_id) for l in run.lanes)
        run.spent_usd = round(spent, 4)
        if run.max_total_usd <= 0 or spent < run.max_total_usd:
            continue
        stopped = cancel_lanes(
            run, tasks,
            note=f"stopped at the race budget ceiling (${run.max_total_usd:.2f} total)",
        )
        if stopped:
            # The race is stopped, not merely finished — `judge_race` preserves this
            # status so a ceiling hit can never be misread as "those lanes just lost".
            run.status = "stopped"
            await _publish_race(
                hub, run, kind="race_budget",
                detail=f"race stopped {stopped} lane(s) at ${run.max_total_usd:.2f}",
            )
        return


def cancel_lanes(run: RaceRun, tasks: list[asyncio.Task], *, note: str) -> int:
    """Cancel every still-running lane and record why. Returns how many were stopped.

    Cancelling the **lane** tasks — never the supervisor — is deliberate: the supervisor's
    ``finally`` is what judges whatever finished and settles the race, and a cancelled
    supervisor would die at its first ``await`` inside that block, leaving a race stuck on
    ``running`` with no owner. The spend already happened; refusing to show the result
    would be the worst of both."""
    stopped = 0
    for task, lane in zip(tasks, run.lanes):
        if task.done():
            continue
        task.cancel()
        lane.status = "stopped"
        lane.note = note
        stopped += 1
    return stopped


def request_stop(store: Store, run: RaceRun) -> int:
    """Stop a running race by hand: cancel its remaining lanes and let the supervisor
    judge what's finished. Returns how many lanes were stopped."""
    tasks = store.race_lane_tasks.get(run.id) or []
    run.status = "stopped"
    run.reason = run.reason or "stopped by hand"
    return cancel_lanes(run, tasks, note="stopped by hand")


async def _supervise(
    *,
    store: Store,
    hub: Hub,
    project: Project,
    psettings: ProjectSettings,
    run: RaceRun,
    test_adapter: TestRunnerAdapter,
) -> None:
    """Run every lane concurrently under the budget watchdog, then judge + hold the
    ceremony. Always settles the race, even when everything went wrong — a race stuck
    on ``running`` forever is the one outcome with no recovery path in the UI."""
    from . import db  # lazy: db imports store/models, and this module is imported early

    tasks = [
        asyncio.create_task(
            _run_lane(
                store=store, hub=hub, project=project, psettings=psettings,
                run=run, lane=lane, test_adapter=test_adapter,
            )
        )
        for lane in run.lanes
    ]
    # Published so the budget watchdog AND a hand-stop can reach the lanes without
    # cancelling *this* coroutine — see `cancel_lanes` for why that distinction matters.
    store.race_lane_tasks[run.id] = tasks
    watchdog = asyncio.create_task(
        _watch_budget(store=store, hub=hub, run=run, tasks=tasks)
    )
    try:
        await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        watchdog.cancel()
        store.race_lane_tasks.pop(run.id, None)
        for lane in run.lanes:
            lane.cost_usd = _lane_cost(store, lane.workspace_id)
            if lane.status in ("pending", "running"):
                # The lane never reached a verdict (cancelled, crashed, or the agent
                # errored before the gate). Say so rather than leaving it mid-flight.
                lane.status = "stopped" if lane.note else "error"
        run.spent_usd = round(sum(l.cost_usd for l in run.lanes), 4)
        try:
            await judge_race(store=store, hub=hub, project=project, psettings=psettings, run=run)
        except Exception as exc:  # noqa: BLE001 — a broken judge must still settle the race
            run.status = "failed"
            run.reason = f"the judge failed: {type(exc).__name__}: {exc}"
        run.ended_at = time.time()
        store.race_tasks.pop(run.id, None)
        await _publish_race(hub, run, kind="race_done")
        await db.save_snapshot(store)


# --------------------------------------------------------------------------- #
# §2 — judging (the shell; the decision is race.judge)
# --------------------------------------------------------------------------- #
def lane_facts(run: RaceRun) -> list[race.LaneFacts]:
    """Adapt the persisted lane cache into the judge's input dataclass.

    A deliberately dumb copy: if this function ever grows a rule, that rule has
    escaped the pure judge and the determinism claim goes with it."""
    return [
        race.LaneFacts(
            workspace_id=l.workspace_id, name=l.name, model=l.model, effort=l.effort,
            status=l.status, green=l.green, cost_usd=l.cost_usd, wall_ms=l.wall_ms,
            coverage_delta=l.coverage_delta, merge_conflict=l.merge_conflict,
            flaky=list(l.flaky), degraded=l.degraded, tamper_count=l.tamper_count,
            impacted_count=l.impacted_count, diff_lines=l.diff_lines,
            finished_at=l.finished_at,
        )
        for l in run.lanes
    ]


def _judge_split_authors(run: RaceRun) -> RaceRun:
    """split_authors' verdict: there is nothing to RANK — one lane wrote tests, the
    other wrote the implementation, so a "winner" would just mean "the lane whose
    half happens to gate green alone", which is meaningless (the tests-only lane has
    no implementation to test; the impl-only lane has no new test proving its
    behaviour). This never calls ``race.judge``: recording both lane ids is the
    entire verification bar (usp-critique-round3.md Move C, §"Verification"), and a
    human combines + reviews both branches by hand — same as an honest tie, no
    ``winner_id`` means ``judge_race``'s archive-losers ceremony never fires, so
    both worktrees stay live to be combined."""
    tests_lane = next((l for l in run.lanes if l.role == "tests_only"), None)
    impl_lane = next((l for l in run.lanes if l.role == "impl_only"), None)
    run.verdict = {
        "kind": "split_authors",
        "tests_lane_id": tests_lane.workspace_id if tests_lane else None,
        "impl_lane_id": impl_lane.workspace_id if impl_lane else None,
    }
    run.winner_id = None
    run.tie = [l.workspace_id for l in (tests_lane, impl_lane) if l is not None]
    if tests_lane is None or impl_lane is None:
        run.refused = "split_authors race did not end up with both a tests_only and an impl_only lane"
    else:
        run.refused = None
        run.reason = (
            "split_authors: two independent lanes, one tests-only and one impl-only — "
            "review and combine both by hand rather than picking a single winner"
        )
    if run.status != "stopped":
        run.status = "refused" if run.refused else "judged"
    return run


async def judge_race(
    *,
    store: Store,
    hub: Hub,
    project: Project,
    psettings: ProjectSettings,
    run: RaceRun,
) -> RaceRun:
    """Ask the judge, store the verdict, then run the ceremony.

    The verdict is *stored*, not recomputed on read: the losers are about to lose their
    worktrees, so a later re-judge would be scoring a different world. The scorecard a
    human acted on is the one the record has to keep."""
    if (run.policy or psettings.race_policy) == "split_authors":
        return _judge_split_authors(run)
    ranking = race.judge(
        lane_facts(run),
        policy=run.policy or psettings.race_policy,
        min_impacted_tests=psettings.race_min_impacted_tests,
    )
    run.verdict = ranking.to_dict()
    run.winner_id = ranking.winner_id
    run.tie = list(ranking.tie)
    run.refused = ranking.refused
    run.reason = ranking.reason
    # `stopped` outranks both: it's the only status that explains why some lanes have no
    # verdict at all, and losing it would let a budget-capped race read as a clean result.
    if run.status != "stopped":
        run.status = "refused" if ranking.refused else "judged"

    # §3's ceremony runs only when there IS a winner: a tie or a refusal means the
    # human still has to look at every lane, and archiving their worktrees would
    # destroy exactly the thing they were asked to compare.
    if ranking.winner_id:
        await archive_losers(store=store, hub=hub, project=project, psettings=psettings, run=run)
    return run


# --------------------------------------------------------------------------- #
# §3 — ceremony: the losers' afterlife
# --------------------------------------------------------------------------- #
async def soft_archive_lane(
    *,
    store: Store,
    hub: Hub,
    project: Project,
    psettings: ProjectSettings,
    workspace: Workspace,
) -> None:
    """Retire a losing lane WITHOUT dropping it (backlog/winner-fanout.md §3).

    The difference from ``main._teardown_workspace`` is everything that makes this
    reversible-ish:

    * a **checkpoint commit first**, because an agent's work is nearly always
      uncommitted and ``worktree remove --force`` would take the loser's whole diff
      with it — "keep loser branches so the diff stays diffable" is only true if the
      diff was committed to the branch before the checkout went away;
    * ``remove_worktree`` is called **without the branch**, so the ref survives;
    * the store row, its transcript and its ``test_history`` all stay, so the
      scorecard's loser rows remain inspectable;
    * status becomes ``archived`` and the port goes back to the pool.

    Best-effort throughout: failing to retire a loser must never invalidate a race a
    winner already won.
    """
    from . import git_panel  # lazy: git_panel pulls the `gh` layer we don't need on import

    await quiesce_workspace(store=store, workspace=workspace)
    try:
        await git_panel.commit(
            workspace.worktree_path,
            f"haro: race lane snapshot ({workspace.name})",
        )
    except Exception:  # noqa: BLE001 — nothing to commit / a git hiccup is not fatal
        pass
    try:
        await run_archive(workspace=workspace, project=project, psettings=psettings)
    except Exception:  # noqa: BLE001
        pass
    try:
        # NO branch argument: this is the whole point. The three-arg call in
        # `_teardown_workspace` also runs `git branch -D`, which would make the loser's
        # diff unrecoverable the moment the ceremony ran.
        await git_ops.remove_worktree(project.path, workspace.worktree_path)
    except Exception:  # noqa: BLE001
        pass
    store.release_port(workspace.port)
    workspace.port = None
    workspace.status = WorkspaceStatus.archived
    await hub.publish(
        workspace.id,
        {"channel": "status", "workspace_id": workspace.id, "status": workspace.status.value},
    )


async def archive_losers(
    *, store: Store, hub: Hub, project: Project, psettings: ProjectSettings, run: RaceRun
) -> None:
    """Soft-archive every lane that isn't the winner. Idempotent."""
    if run.losers_archived or not run.winner_id:
        return
    for lane in run.lanes:
        if lane.workspace_id == run.winner_id or lane.archived:
            continue
        ws = store.get_workspace(lane.workspace_id)
        if ws is None or ws.status == WorkspaceStatus.archived:
            lane.archived = True
            continue
        await soft_archive_lane(
            store=store, hub=hub, project=project, psettings=psettings, workspace=ws
        )
        lane.archived = True
    run.losers_archived = True
    await _publish_race(hub, run, kind="race_archived")


async def purge_losers(
    *, store: Store, hub: Hub, project: Project, run: RaceRun
) -> dict:
    """Delete the losing lanes' branches and drop their rows — the explicit
    "I'm done second-guessing" action (§3).

    Kept out of the ceremony on purpose. Archiving is cheap and reversible-ish; this is
    neither, so it is a button a human presses after reading the scorecard, not
    something that happens while they were looking at the winner."""
    purged: list[str] = []
    for lane in run.lanes:
        if lane.workspace_id == run.winner_id:
            continue
        ws = store.get_workspace(lane.workspace_id)
        if ws is not None:
            try:
                # Now WITH the branch: this is the deliberate, irreversible half.
                await git_ops.remove_worktree(project.path, ws.worktree_path, ws.branch)
            except Exception:  # noqa: BLE001
                pass
            store.release_port(ws.port)
            store.remove_workspace(ws.id)
        lane.archived = True
        purged.append(lane.workspace_id)
    run.losers_purged = True
    await _publish_race(hub, run, kind="race_purged")
    return {"purged": purged}


# --------------------------------------------------------------------------- #
# Broadcast
# --------------------------------------------------------------------------- #
async def _publish_race(hub: Hub, run: RaceRun, *, kind: str, detail: str = "") -> None:
    """Announce race lifecycle on the global feed so the dashboard can group the
    siblings under ONE race card instead of N loose workspaces (§1).

    Rides ``notify`` (already a global channel) and carries the whole ``RaceRun``:
    the card renders straight off the feed with no fetch-per-race, the same
    denormalize-onto-the-event rule ``GateSummary``/``TrustSummary`` follow. It uses
    ``broadcast_global`` rather than ``publish`` because a race belongs to a *project*,
    not to any one of its workspaces."""
    await hub.broadcast_global(
        {
            "channel": "notify",
            "kind": kind,
            "project_id": run.project_id,
            "race_id": run.id,
            "detail": detail,
            "race": run.model_dump(),
        }
    )
