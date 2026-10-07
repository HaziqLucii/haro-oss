"""Agent run supervisor.

Bridges an AgentAdapter's normalized event stream to the multiplexed workspace
socket: wraps each event in the ``agent`` channel envelope, mutates run/workspace
status, and — when the agent finishes cleanly and auto-gate is on — hands off
directly to the test gate. This is the one place that owns the agent→gate
handoff, keeping the API handlers thin.

The optional **auto-fix loop** closes that handoff into a cycle: a gate that
comes back red *with real test failures* is fed straight back to the agent and
re-gated, up to a hard round cap or until green. It's opt-in (`[workflow]
auto_fix`), never loops on setup/crash reds (the agent can't fix missing deps by
editing code), and the ⏹ stop button cancels the whole loop.

This module also owns both ways a run can be **held before it spawns**, because
a run's start belongs to the backend for exactly the reason its execution
already did — the client may be gone:

- **waiting for setup** — a run fired at a freshly-created worktree waits for the
  provision task instead of being refused (the old 409 pushed the wait onto a
  view-coupled client queue, which stranded the task if you switched workspace);
- **waiting for a slot** — `[agent] max_parallel` caps how many agent
  subprocesses exist at once across the whole install.

Both surface as `AgentRunStatus.queued` plus a line on the session's own stream,
so a held run reads as "⏳ waiting", never as a hang.
"""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import logging
import time
from pathlib import Path

from . import acceptance, rungs
from .adapters.base import AgentAdapter
from .adapters.test_runner.base import TestRunnerAdapter
from .config import load_project_settings
from .gate import run_gate
from .hub import Hub
from .models import (
    status_payload,
    AgentEvent,
    AgentRun,
    AgentRunStatus,
    TestRun,
    TestRunStatus,
    Workspace,
    WorkspaceStatus,
)
from .store import Store, DEFAULT_SESSION
from . import db

log = logging.getLogger(__name__)

#: How long a queued run waits for the worktree's setup task before giving up.
#: A cold ``npm install`` on a big monorepo can genuinely take minutes, so this is
#: generous — but it is NOT unbounded, which is the point: backlog/agent-session-lifecycle.md's
#: kill condition for backend-owned deferral is "a run silently stuck `queued`
#: because a setup task never settles". A timeout fails the run *loudly* instead.
SETUP_WAIT_TIMEOUT = 900.0

#: Global cap on concurrently-spawned agent subprocesses (`[agent] max_parallel`;
#: 0 ⇒ unlimited). Module-level because the cap is per *install*, not per project or
#: per worktree — N workspaces each spawning an unbounded `claude` is the
#: resource-exhaustion footgun behind the "run many agents in parallel" headline.
#: Rebuilt when the config value changes, and when the running event loop changes
#: (asyncio primitives bind to a loop on first await, and the test suite runs each
#: case in its own ``asyncio.run``).
_slot_sem: asyncio.Semaphore | None = None
_slot_limit: int = 0
_slot_loop: asyncio.AbstractEventLoop | None = None


def _slots(max_parallel: int) -> asyncio.Semaphore | None:
    """The spawn semaphore for this cap, or None when uncapped.

    A rebuild while runs hold permits leaks those permits into the old (discarded)
    semaphore — harmless, and the alternative (tracking live permits across a config
    change) is far more machinery than a rare settings edit deserves."""
    global _slot_sem, _slot_limit, _slot_loop
    n = max(0, int(max_parallel or 0))
    if n == 0:
        return None
    loop = asyncio.get_running_loop()
    if _slot_sem is None or n != _slot_limit or _slot_loop is not loop:
        _slot_sem = asyncio.Semaphore(n)
        _slot_limit = n
        _slot_loop = loop
    return _slot_sem


async def _publish_status(hub: Hub, ws: Workspace) -> None:
    msg = status_payload(ws)
    if ws.test_first is not None:
        msg["test_first"] = ws.test_first.model_dump()
    await hub.publish(ws.id, msg)


async def _notice(hub: Hub, ws: Workspace, run: AgentRun, session_id: str, text: str) -> None:
    """Put a line on ONE session's agent stream without persisting it.

    Published-only on purpose (the pattern the shared-branch queued notice
    established): these lines describe a transient wait, so by the time a client
    reloads the transcript the run is already past it and the line would read as
    stale history."""
    await hub.publish(ws.id, {
        "channel": "agent",
        "session_id": session_id,
        "event": {
            "run_id": run.id, "workspace_id": ws.id, "ts": time.time(),
            "type": "token", "payload": {"text": text},
        },
    })


async def _await_setup(
    *, store: Store, hub: Hub, workspace: Workspace, run: AgentRun, session_id: str
) -> str | None:
    """Hold a run until the worktree's provisioning settles. Returns an error message
    when the wait timed out, else None.

    ``asyncio.wait`` (not ``wait_for``) because a timeout must NOT cancel setup: the
    install is still useful to everyone else even if this one run gave up on it. A
    *failed* setup is not reported here either — it already surfaces on the deps chip
    and as a `setup` gate error, and the agent may well be being asked to fix exactly
    that. We only refuse to wait forever."""
    setup = store.setup_task(workspace.id)
    if setup is None or setup.done():
        return None
    await _notice(
        hub, workspace, run, session_id,
        "⏳ Waiting for setup to finish provisioning this worktree…\n",
    )
    done, _ = await asyncio.wait({setup}, timeout=SETUP_WAIT_TIMEOUT)
    if not done:
        return (
            f"setup has not finished after {int(SETUP_WAIT_TIMEOUT)}s — "
            "not starting the agent. Check the run log, then re-run setup."
        )
    if not setup.cancelled():
        setup.exception()  # mark retrieved; run_setup already reported its own failure
    # Say which it was. A failed provision usually means a red `setup` gate is coming, so
    # "setup finished" on its own would be misleading at exactly the wrong moment — but it
    # still isn't a reason to refuse the run (the agent may be here to fix it).
    state = (store.setup_state.get(workspace.id) or {}).get("status")
    await _notice(
        hub, workspace, run, session_id,
        "⚠ setup finished but FAILED (see the run log) — starting the agent anyway.\n"
        if state == "failed"
        else "◆ setup finished — starting the agent.\n",
    )
    return None


async def _fail_run(
    *, store: Store, hub: Hub, workspace: Workspace, run: AgentRun,
    session_id: str, message: str
) -> None:
    """Settle a run that never got to spawn: a persisted ``error`` event in the
    session's transcript (so the failure survives a reload, unlike a notice) and the
    workspace back to idle."""
    envelope = {
        "run_id": run.id, "workspace_id": workspace.id, "ts": time.time(),
        "type": "error", "payload": {"message": message},
    }
    store.append_event(workspace.id, envelope, session_id)
    await hub.publish(
        workspace.id, {"channel": "agent", "event": envelope, "session_id": session_id}
    )
    if workspace.status in (WorkspaceStatus.agent_running, WorkspaceStatus.setting_up):
        workspace.status = WorkspaceStatus.idle
        await _publish_status(hub, workspace)


@contextlib.asynccontextmanager
async def _spawn_slot(
    *, hub: Hub, workspace: Workspace, run: AgentRun, session_id: str, max_parallel: int
):
    """Hold one of the global agent-spawn slots for the duration of the block.

    Scoped tightly around the subprocess itself — not around the gate or the
    worktree lock — so a slot is never held by a run that isn't actually burning
    CPU/tokens, and a waiting run is honestly reported as ``queued``."""
    sem = _slots(max_parallel)
    if sem is None:
        yield
        return
    if sem.locked():
        run.status = AgentRunStatus.queued
        await _notice(
            hub, workspace, run, session_id,
            f"⏳ Queued: {max_parallel} agent run"
            f"{'s' if max_parallel != 1 else ''} already in flight (max_parallel).\n",
        )
    async with sem:
        yield


def should_autofix(test: TestRun) -> bool:
    """Loop only on genuine *test failures* — never on a gate that couldn't run.

    A ``failed`` status with failing cases is something the agent can act on. An
    ``error`` (deps/config/crash) or a green run is not, so those stop the loop.
    """
    return test.status == TestRunStatus.failed and any(c.status == "failed" for c in test.cases)


def compose_fix_task(test: TestRun, round_no: int, max_rounds: int) -> str:
    """The follow-up prompt for an auto-fix round: the failing tests + their errors.

    Mirrors the manual "fix all → agent" round-trip so the agent gets the same
    structured failure list, tagged with the round so the transcript reads clearly.
    """
    fails = [c for c in test.cases if c.status == "failed"]
    lines = []
    for i, c in enumerate(fails, 1):
        line = f"{i}. {c.name} ({c.file})"
        if c.message:
            line += f"\n   {c.message.splitlines()[0]}"
        lines.append(line)
    body = "\n".join(lines)
    return (
        f"The test gate is still red — {len(fails)} failing "
        f"[auto-fix round {round_no}/{max_rounds}]. Fix these failing tests by editing "
        f"files in this worktree. Do not weaken or delete the tests to make them pass "
        f"unless a test is genuinely wrong:\n\n{body}"
    )


async def _drive_agent(
    *,
    store: Store,
    hub: Hub,
    adapter: AgentAdapter,
    workspace: Workspace,
    run: AgentRun,
    instructions: str | None,
    max_budget_usd: float | None,
    cost_warn_usd: float,
    session_id: str = DEFAULT_SESSION,
    plan: bool = False,
    max_parallel: int = 0,
    agents: dict | None = None,
    deny_edit_paths: list[str] | None = None,
) -> None:
    """Drive ONE agent run to completion: stream events, set run/workspace status,
    then fire the agent-done + cost-warning signals. Re-raises ``CancelledError``
    (after settling the workspace to idle) when the user stops the run.

    ``session_id`` picks which agent session in the workspace this run belongs to
    (transcript keyed by ``(workspace_id, session_id)``). Every ``agent``-channel
    envelope is tagged with it so the UI routes concurrent streams to the right
    switcher tab, and the run ``--resume``\\s that session's OWN Claude conversation
    (``workspace.session_resume``) — sessions don't cross-contaminate context.

    ``plan`` runs the agent in Plan Mode (produces a plan, edits nothing). The
    terminal ``done`` event is tagged ``plan: True`` so the stream can offer the
    approve/feedback review actions — the plan is the gate before any file edit.

    ``agents`` is haro's own ``--agents`` payload (scout, Phase 2 —
    notes/workflow-roles-plan.md); it rides ``drive_kw`` too, so an auto-fix round
    gets the same scout the main run did.

    ``max_parallel`` is the global spawn cap: this is where a run waits for a free
    slot, so the wait brackets the subprocess and nothing else."""

    async def emit(ev_type, payload):
        ev = AgentEvent(run_id=run.id, workspace_id=workspace.id, type=ev_type, payload=payload)
        envelope = ev.model_dump()
        store.append_event(workspace.id, envelope, session_id)  # durable per-session transcript
        # Tag the envelope with the session so the UI routes it to the right stream tab.
        await hub.publish(workspace.id, {"channel": "agent", "event": envelope, "session_id": session_id})

    # This session's own Claude resume id: its per-session entry, falling back to the
    # legacy single-session field for the primary session (pre-multi-session rows only
    # carry ``last_session_id``).
    resume = workspace.session_resume.get(session_id) or (
        workspace.last_session_id if session_id == DEFAULT_SESSION else None
    )
    run_kwargs = dict(
        task=run.task,
        cwd=workspace.worktree_path,
        model=run.model,
        effort=run.effort,
        resume=resume,  # continue THIS session's conversation if we have one
        instructions=instructions,  # project custom instructions (Tier-1)
        max_budget_usd=max_budget_usd,  # hard per-run cost ceiling (runaway guard)
    )
    # Plan Mode is a per-adapter capability — pass it only to adapters whose ``run``
    # actually accepts it (claude-code today). A future adapter that can't plan never
    # sees the flag: hidden, not broken. main.py already forces plan False for such
    # adapters, so the gate-skip below can't strand real edits; this is belt-and-braces.
    if plan and "plan" in inspect.signature(adapter.run).parameters:
        run_kwargs["plan"] = True
    # Sub-agents (scout, Phase 2) are a per-adapter capability too — same
    # feature-detect pattern as plan, so an adapter that can't take
    # `--agents` just runs without one instead of erroring.
    if agents and "agents" in inspect.signature(adapter.run).parameters:
        run_kwargs["agents"] = agents
    # Protected tests (deny rules on the edit tools), same feature-detect pattern. The
    # caller already resolved protection against this adapter, so this is belt-and-braces.
    if deny_edit_paths and "deny_edit_paths" in inspect.signature(adapter.run).parameters:
        run_kwargs["deny_edit_paths"] = deny_edit_paths

    # Everything above is preparation and holds no resources. The slot below brackets
    # the subprocess itself: acquiring it is the moment this run stops being `queued`
    # and starts actually costing money.
    async with _spawn_slot(
        hub=hub, workspace=workspace, run=run, session_id=session_id,
        max_parallel=max_parallel,
    ):
        run.status = AgentRunStatus.running
        workspace.status = WorkspaceStatus.agent_running
        await _publish_status(hub, workspace)
        try:
            # ``aclosing`` is load-bearing, not tidiness: a bare ``async for`` that
            # exits via CancelledError leaves the adapter's async generator SUSPENDED,
            # so its teardown ``finally`` (which kills the `claude` process group) only
            # runs whenever the GC gets round to it. Closing it here makes the kill
            # deterministic — see adapters/claude_code.py.
            agen = adapter.run(**run_kwargs)
            async with contextlib.aclosing(agen):
                async for ev in agen:
                    # Tag a plan run's terminal event so the stream renders the approve /
                    # feedback actions (the plan is a review gate, not an auto-run). `plan` is
                    # already feature-detected upstream, so it's only True for a real plan run.
                    if plan and ev.type == "done":
                        ev.payload["plan"] = True
                        # Phase 3 (notes/workflow-roles-plan.md): capture the plan's own
                        # text so the code reviewer audits the diff against what was actually
                        # approved, not just the one-line task. Capped like the reviewer's
                        # own prompt caps (_PLAN_CAP/_DIFF_CAP in review.py) — this is a
                        # whole CLI turn's result, potentially much longer than either.
                        workspace.plan_text = (ev.payload.get("result") or "")[:16000]
                    # Tag the bootstrap event with this run's role (plan/build) so the
                    # stream badge can show it beside the model/effort it already reads
                    # off this same event (see StreamMeta / claude_code.py's `system:init`
                    # normalization). Empty when `[roles]` is off, so the badge is unchanged.
                    if run.role and ev.payload.get("system"):
                        ev.payload["role"] = run.role
                    await emit(ev.type, ev.payload)
                    # Persist the session id the moment the adapter surfaces it (at the
                    # bootstrap event, not only on done/error) so the next run resumes with
                    # full context. A user stop cancels the stream before any terminal event
                    # fires — persisting eagerly is what keeps a stopped-then-continued run
                    # from starting a fresh, amnesiac session.
                    sid = ev.payload.get("session_id")
                    if sid:
                        # Store THIS session's Claude id under its key so the next run in this
                        # session resumes it; mirror the primary session into last_session_id for
                        # backward-compat (older readers + pre-multi-session persistence).
                        workspace.session_resume[session_id] = sid
                        if session_id == DEFAULT_SESSION:
                            workspace.last_session_id = sid
                    if ev.type == "done":
                        run.status = AgentRunStatus.done
                        run.tokens_in = ev.payload.get("tokens_in", 0)
                        run.tokens_out = ev.payload.get("tokens_out", 0)
                        run.cost_usd = ev.payload.get("cost_usd")
                    elif ev.type == "error":
                        run.status = AgentRunStatus.error
                        run.tokens_in = ev.payload.get("tokens_in", run.tokens_in)
                        run.tokens_out = ev.payload.get("tokens_out", run.tokens_out)
        except asyncio.CancelledError:
            run.status = AgentRunStatus.stopped
            run.ended_at = time.time()
            await emit("error", {"message": "run stopped by user"})
            workspace.status = WorkspaceStatus.idle
            await _publish_status(hub, workspace)
            raise
        except Exception as exc:  # noqa: BLE001 — surface any adapter failure to the UI
            run.status = AgentRunStatus.error
            await emit("error", {"message": f"{type(exc).__name__}: {exc}"})
        finally:
            run.ended_at = time.time()
            # Persist the transcript + run record the instant this run settles, instead
            # of waiting for the 4s autosave or the shutdown flush. Both race a Ctrl+C
            # while the browser still holds WebSockets open (uvicorn's graceful drain
            # can outlast the process), which intermittently dropped the final output on
            # a stop-then-restart. Best-effort: a save hiccup must not sink the run —
            # but it must not be INVISIBLE either. A DB that has started failing every
            # write is a silent data-stop, and this used to swallow it whole.
            try:
                await db.save_snapshot(store)
            except Exception:  # noqa: BLE001
                log.warning(
                    "post-run snapshot failed for workspace %s (run %s)",
                    workspace.id, run.id, exc_info=True,
                )

    # Coarse cross-workspace signal: the agent finished emitting output. Rides the
    # global feed (see hub._GLOBAL_CHANNELS) so the UI can beep for *any* workspace,
    # not just the open one. User-cancelled runs re-raise above and skip this.
    await hub.publish(
        workspace.id,
        {
            "channel": "notify",
            "kind": "agent_done",
            "workspace_id": workspace.id,
            "workspace_name": workspace.name,
            "status": run.status.value,
        },
    )

    # Cumulative-spend heads-up: if THIS run pushed the workspace's total agent
    # spend across the configured threshold, fire a one-shot warning on the global
    # feed. Guarded on the crossing edge (prev below, new at/over) so it beeps once
    # — not on every run after the line is crossed.
    if cost_warn_usd and cost_warn_usd > 0:
        total = sum(
            r.cost_usd or 0.0 for r in store.runs.values() if r.workspace_id == workspace.id
        )
        prev = total - (run.cost_usd or 0.0)
        if prev < cost_warn_usd <= total:
            await hub.publish(
                workspace.id,
                {
                    "channel": "notify",
                    "kind": "cost_warning",
                    "workspace_id": workspace.id,
                    "workspace_name": workspace.name,
                    "total_usd": round(total, 4),
                    "threshold_usd": cost_warn_usd,
                },
            )


async def _announce_autofix(hub: Hub, store: Store, workspace: Workspace, round_no: int, max_rounds: int, test: TestRun, session_id: str = DEFAULT_SESSION) -> None:
    """Mark an auto-fix round in the transcript so the stream reads as a clear
    "the platform is retrying", not a mystery second prompt from the user. Lands in the
    same session as the run it's fixing (auto-fix continues that conversation)."""
    n = sum(1 for c in test.cases if c.status == "failed")
    text = f"↻ Auto-fix round {round_no}/{max_rounds}: gate still red ({n} failing). Sending the failures back to the agent…"
    envelope = {
        "run_id": "autofix",
        "workspace_id": workspace.id,
        "ts": time.time(),
        "type": "user",
        "payload": {"text": text},
    }
    store.append_event(workspace.id, envelope, session_id)
    await hub.publish(workspace.id, {"channel": "agent", "event": envelope, "session_id": session_id})


async def run_agent(
    *,
    store: Store,
    hub: Hub,
    adapter: AgentAdapter,
    workspace: Workspace,
    run: AgentRun,
    test_adapter: TestRunnerAdapter | None = None,
    project_path: str | None = None,
    auto_gate: bool = False,
    instructions: str | None = None,
    max_budget_usd: float | None = None,
    cost_warn_usd: float = 0.0,
    auto_fix: bool = False,
    auto_fix_max_rounds: int = 3,
    gate_scope: str = "all",
    session_id: str = DEFAULT_SESSION,
    plan: bool = False,
    max_parallel: int = 0,
    agents: dict | None = None,
    deny_edit_paths: list[str] | None = None,
    test_first_phase: str | None = None,
    test_first_gen: int = 0,
) -> None:
    """Drive one agent run, auto-run the gate, then optionally auto-fix red gates.

    ``test_first_phase == "draft"`` (backlog/test-first.md) swaps the gate handoff for the
    red proof: the run drafted an acceptance test, and ``acceptance.finish_draft`` proves it
    fails before the dev is asked to approve it. No gate, no auto-fix, on a draft.

    ``session_id`` names the agent session this run + its auto-fix rounds belong to
    (transcript keyed by ``(workspace_id, session_id)``); it rides ``drive_kw`` so every
    ``_drive_agent`` call — the main run and each fix round — tags its stream + resumes
    the same session. The gate still runs on the whole worktree diff (per-workspace, not
    per-session): all sessions share one branch.

    ``gate_scope`` picks the auto-gate's scope: ``"all"`` (full suite) or
    ``"impacted"`` (only the tests the diff vs base_ref affects — the fast gate).
    Impacted keeps the agent→gate loop tight on big suites; the UI nudges the user
    to run the full suite before ship.

    ``plan`` runs the agent in Plan Mode: it produces a plan and edits nothing, so
    there's no diff to gate — the handoff below keeps step ③ idle and returns after
    the plan lands (the dev reviews it, then approves to re-run in auto-edit, or sends
    feedback for another plan turn). The auto-fix loop that shares ``drive_kw`` never
    engages, since it's gated off the (skipped) gate result.

    ``max_parallel`` is the install-wide cap on concurrent agent subprocesses
    (`[agent] max_parallel`, 0 ⇒ unlimited); a run over the cap waits as ``queued``.

    ``agents`` is haro's own ``--agents`` payload (scout, Phase 2 —
    notes/workflow-roles-plan.md), built by ``main.start_agent`` from the project's
    `[roles] scout` config; it rides ``drive_kw`` so every ``_drive_agent`` call
    inherits it, same as ``plan``.
    """
    # Resolve plan-capability ONCE, here, so the gate-skip and the adapter call agree:
    # the gate is skipped iff the adapter actually ran in plan mode. A ``plan=True``
    # against an adapter that can't plan degrades to a normal auto-edit run that IS
    # gated — never a skipped gate on real edits. (main.py already forces plan False
    # for such adapters; this keeps the runner correct on its own too.)
    plan = plan and "plan" in inspect.signature(adapter.run).parameters
    changed_since = workspace.base_ref if gate_scope == "impacted" else None
    # The gate result the autonomy-ladder handoff acts on at the very end: the LAST gate
    # of this run (after any auto-fix rounds), or None when no gate ran at all.
    test: TestRun | None = None
    drive_kw = dict(
        store=store,
        hub=hub,
        adapter=adapter,
        workspace=workspace,
        instructions=instructions,
        max_budget_usd=max_budget_usd,
        cost_warn_usd=cost_warn_usd,
        # Session rides drive_kw so the main run AND every auto-fix round tag the same
        # session's stream and --resume its conversation (the session owns the run, not
        # just turn 1). The gate below is session-agnostic (one shared worktree/branch).
        session_id=session_id,
        # Every drive — the main run and each auto-fix round — takes its own spawn slot,
        # so an auto-fixing run can't hold a global slot through its gate runs.
        max_parallel=max_parallel,
        # Scout (Phase 2) rides drive_kw so an auto-fix round gets the same sub-agent
        # the main run did, not a bare re-implementation prompt with no mapping help.
        agents=agents,
        # Protected tests ride drive_kw so an auto-fix round is fenced like the main run.
        deny_edit_paths=deny_edit_paths,
    )
    try:
        # Backend-owned start deferral: a run fired at a still-provisioning worktree
        # waits HERE rather than being refused, because this task outlives the client
        # that asked for it (backlog/agent-session-lifecycle.md §1). The wait comes
        # BEFORE the worktree lock so a queued run doesn't also block a sibling session
        # that's ready to go.
        stalled = await _await_setup(
            store=store, hub=hub, workspace=workspace, run=run, session_id=session_id
        )
        if stalled:
            # Fail loudly rather than sit `queued` forever — §1's kill condition.
            run.status = AgentRunStatus.error
            run.ended_at = time.time()
            await _fail_run(
                store=store, hub=hub, workspace=workspace, run=run,
                session_id=session_id, message=stalled,
            )
            return

        # Shared-branch serialization: all of a workspace's sessions edit ONE worktree,
        # so their runs serialize on the per-worktree lock (see Store.agent_lock). If
        # it's already held, tell THIS session's stream it's queued — otherwise a 2nd
        # session sits silent behind the lock and reads as a hang.
        lock = store.agent_lock(workspace.id)
        if lock.locked():
            run.status = AgentRunStatus.queued
            await _notice(
                hub, workspace, run, session_id,
                "⏳ Another session is editing this worktree: queued until it finishes.\n",
            )
        # Hold the lock across drive + gate + auto-fix: the gate reads the tree and each
        # auto-fix round edits it again, so a 2nd session must wait for the whole cycle,
        # then layer its edits on a settled tree (and its gate sees the combined diff).
        async with lock:
            try:
                await _drive_agent(run=run, plan=plan, **drive_kw)
            except asyncio.CancelledError:
                if test_first_phase == "draft":
                    acceptance.interrupted(
                        workspace, "The drafting run was stopped before it finished.", gen=test_first_gen
                    )
                    await _publish_status(hub, workspace)
                raise

            if test_first_phase == "draft":
                if run.status == AgentRunStatus.done and test_adapter:
                    settings = load_project_settings(project_path) if project_path else None
                    gate_dir = settings.gate_dir if settings else ""
                    await acceptance.finish_draft(
                        hub=hub, workspace=workspace, adapter=test_adapter, gate_dir=gate_dir,
                        gen=test_first_gen,
                        dep_root=(str(Path(project_path) / gate_dir) if project_path and gate_dir else project_path),
                    )
                else:
                    acceptance.interrupted(
                        workspace, f"The drafting run ended {run.status.value}, so there is no test to prove.",
                        gen=test_first_gen,
                    )
                    if workspace.status == WorkspaceStatus.agent_running:
                        workspace.status = WorkspaceStatus.idle
                    await _publish_status(hub, workspace)
                return

            # Handoff: agent failed, no auto-gate, or a plan-only run (nothing edited, so
            # nothing to gate) → settle to idle and stop. A plan run's review IS the gate
            # for now; step ③ stays idle until an implementation run produces a diff.
            gate_ready = (
                run.status == AgentRunStatus.done
                and auto_gate
                and test_adapter
                and project_path
                and not plan
            )
            if not gate_ready:
                if workspace.status == WorkspaceStatus.agent_running:
                    workspace.status = WorkspaceStatus.idle
                    await _publish_status(hub, workspace)
                return

            test = await run_gate(
                store=store, hub=hub, adapter=test_adapter, workspace=workspace,
                project_path=project_path, changed_since=changed_since, trigger="auto",
            )

            # Auto-fix loop: re-gate after each fix until green, cap reached, the agent
            # stops making progress, or the user cancels (CancelledError propagates out).
            rounds = 0
            while auto_fix and rounds < auto_fix_max_rounds and should_autofix(test):
                rounds += 1
                await _announce_autofix(hub, store, workspace, rounds, auto_fix_max_rounds, test, session_id)
                fix_run = AgentRun(
                    workspace_id=workspace.id,
                    adapter=adapter.name,
                    model=run.model,
                    effort=run.effort,
                    # A fix round is always an implementation turn — "build" when the
                    # parent run carried a role at all (roles off ⇒ "", same as `run.role`
                    # itself would be for a plain submit).
                    role="build" if run.role else "",
                    protect_tests=run.protect_tests,
                    task=compose_fix_task(test, rounds, auto_fix_max_rounds),
                )
                store.add_run(fix_run)
                await _drive_agent(run=fix_run, **drive_kw)
                if fix_run.status != AgentRunStatus.done:
                    break  # agent errored/stopped — leave the gate red, don't spin
                test = await run_gate(
                    store=store, hub=hub, adapter=test_adapter, workspace=workspace,
                    project_path=project_path, changed_since=changed_since, trigger="autofix",
                )

    finally:
        # Identity-checked: only clear the slot if it still holds THIS task, so a run
        # settling can't evict a newer run's stop handle from the same session.
        store.pop_active_task(workspace.id, session_id, asyncio.current_task())

    # Autonomy-ladder handoff (backlog/autonomy-ladder.md §3): the gate has settled and
    # this run has released its slot, so an armed rung can fire — auto_pr, through the
    # very same preflights as the manual ship buttons (see rungs.py). It runs
    # *after* the finally on purpose: the busy guard is a real check, and firing while the
    # agent still held the workspace would refuse every time. A user stop re-raises
    # CancelledError out of the block above and never reaches here, which is right — a
    # cancelled run's gate result isn't a verdict to ship on.
    await rungs.maybe_fire(store=store, hub=hub, workspace=workspace, test=test)
