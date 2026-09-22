"""Autonomy-ladder rung ACTIONS — what an earned green is allowed to DO.

``trust.py`` computes the ladder (a deterministic conjunction of gate facts, pure of
IO); this is the thin shell that *acts* on it at the gate-green handoff, which is the
reward at the top of the checklist (backlog/autonomy-ladder.md §3). One rung, opt-in
through the committed ``[trust] auto_action``:

  * ``auto_pr`` — push + ``gh pr create``, no merge. The review-ready rung: the
    ladder does the mechanical part, a human still approves. (An `auto_merge` rung that
    shipped straight to the user's own `main` unattended was cut 2026-09-17 — a local
    verdict alone isn't something a stranger's `main` should act on without a human
    looking at the PR first.)

Three properties this module exists to guarantee:

1. **Nothing bypasses the choke point.** The rung clears ``integrate.ship_preflight``
   — the *same* function ``POST /workspaces/{id}/git/pr`` calls (gate green, busy
   guard, clean tree, ``merge_mode``). An auto action is exactly a manual one nobody
   had to click. In particular an uncommitted worktree is **held, never
   auto-committed**: the ladder only ships work somebody labelled with a commit message.
2. **Never silent.** Every fired / held / failed rung publishes a ``notify`` envelope on
   the global feed, like ``gate_green``/``gate_red``. An auto-PR you didn't notice is
   indistinguishable from a bug, so the beep is part of the feature, not a nicety.
3. **Attributable.** The PR body carries the rendered trust report that authorized the
   action — which conditions were met, and the streak behind them. When Gate Receipts
   ship (benched, ``notes/differentiation-bets-round2.md``) they become the durable
   evidence this body cites; until then the report *is* the receipt.

**Where it fires:** wherever an *authoritative* gate settles — the agent→gate handoff
(``runner.run_agent``), the manual ``POST /workspaces/{id}/tests``, and the fs-watcher's
agentless auto-gate for adopted worktrees. One rule, no special cases to remember. Two
things follow from that on purpose: the advisory Live Gate has no path here at all (it
never touches ``workspace.status``, see ``gate.run_watch``), and an impacted or
re-run-failed gate can't fire a rung either, because the ladder's ``full_scope``
condition rejects a partial scope before ``armed`` is ever true.

The fire points are all *settled* moments — the agent's task popped, the gate task
popped — because the busy guard is a real check here, not a formality: firing while the
agent still held its slot would refuse every single time.
"""

from __future__ import annotations

from . import git_panel
from .adapters.test_runner.base import TestRunnerAdapter
from .config import load_project_settings
from .gate import build_trust_report, run_gate
from .hub import Hub
from .integrate import ShipRefused, ship_preflight
from .models import TestRun, Workspace, WorkspaceStatus
from .store import Store
from .trust import TrustReport

#: What each rung calls itself in the PR body + the notification. ``merge_queue``
#: isn't a rung — it's the conflict-aware merge queue reusing ``report_body`` for the
#: workspaces the ladder admitted (``main.run_merge_queue``), so a ladder-authorized
#: merge cites its evidence identically whichever path landed it.
_VERB = {"auto_pr": "Auto-PR’d", "merge_queue": "Merge-queued"}


def report_body(report: TrustReport, action: str) -> str:
    """The rendered trust report, for the commit or PR body that ships under it.

    Deliberately plain text listing every *required* condition and its detail: the
    point is that a reader six months later can see precisely which facts authorized
    an unattended merge, without haro running. Conditions the project dropped from the
    conjunction (``require_<key> = false``) are listed too, marked as not required —
    a policy that skips a condition is exactly the thing a reviewer wants to see.
    """
    required = [c for c in report.conditions if c.required]
    met = sum(1 for c in required if c.met)
    head = (
        f"{_VERB.get(action, action)} by the haro autonomy ladder: {met}/{len(required)} "
        f"trust conditions met, streak {report.streak}/{report.streak_required}."
    )
    rows = [
        f"  {'✓' if c.met else '✕'} {c.key}: {c.detail}"
        + ("" if c.required else " (not required by [trust])")
        for c in report.conditions
    ]
    return "\n".join([head, ""] + rows)


async def _notify(
    hub: Hub,
    workspace: Workspace,
    *,
    action: str,
    state: str,
    detail: str,
    report: TrustReport,
    pr_url: str | None = None,
) -> None:
    """Announce a rung on the global feed (``hub._GLOBAL_CHANNELS``), so an automatic
    ship surfaces in every window — not just the one someone happens to be looking at.

    ``state`` is ``fired`` (it happened), ``held`` (a preflight refused: the reason is
    almost always "commit your changes first") or ``failed`` (the action itself errored,
    e.g. a merge conflict on the remote)."""
    await hub.publish(
        workspace.id,
        {
            "channel": "notify",
            "kind": "rung",
            "workspace_id": workspace.id,
            "workspace_name": workspace.name,
            "action": action,
            "state": state,
            "detail": detail,
            "pr_url": pr_url,
            "streak": report.streak,
        },
    )


async def maybe_fire(
    *, store: Store, hub: Hub, workspace: Workspace, test: TestRun | None
) -> dict | None:
    """Fire the project's armed rung for a workspace whose gate just went green.

    ``test`` is the run that just settled — passed in so a caller that never actually
    gated (a held auto-gate on an unprovisioned adopted worktree returns an unrecorded
    sentinel) can't trigger a rung off some older green. The *facts* come from the store,
    not from this object.

    Returns the outcome dict (``action``/``state``/``detail``) when the ladder had
    something to say, else ``None`` — which is the overwhelmingly common case: the
    ladder is opt-in (``[trust] enabled = false`` by default), ``auto_action`` defaults
    to ``"off"``, and ``armed`` additionally demands every required condition plus the
    project's green streak. Nothing here runs for a project that hasn't asked for it.

    Never raises: this runs at the tail of a gate task, and a rung that failed must
    leave the *verdict* intact (the work is still green and still mergeable by hand).
    Failures are reported through the notification instead.
    """
    if test is None:
        return None
    # Only a green gate hands off. Quiet return, no notification: a red gate is already
    # loudly a red gate, and it disarms the rung by resetting the streak (trust.py).
    if workspace.status != WorkspaceStatus.gate_green:
        return None
    project = store.get_project(workspace.project_id)
    if project is None:
        return None

    settings = load_project_settings(project.path)
    # Recompute from the store rather than trusting the denormalized workspace.trust
    # summary: evaluate() is pure and cheap, and this way the facts the action is
    # attributed to are the facts as of the action.
    report = build_trust_report(store, workspace, settings)
    if not report.armed:
        return None
    action = report.auto_action

    try:
        await ship_preflight(
            workspace=workspace,
            project=project,
            merge_mode=settings.merge_mode,
            busy=store.busy_reason(workspace.id),
            action="pr",
        )
    except ShipRefused as exc:
        # Held, not failed — the rung is armed and will fire on the next green once the
        # reason clears. Announced because "my auto-PR didn't happen" is otherwise an
        # unanswerable question.
        await _notify(hub, workspace, action=action, state="held",
                      detail=str(exc), report=report)
        return {"action": action, "state": "held", "detail": str(exc)}

    body = report_body(report, action)
    try:
        res = await git_panel.create_pr(
            workspace.worktree_path, workspace.branch, workspace.base_ref, body=body
        )
        pr_url = res.get("url")
        detail = (
            f"PR already open for {workspace.branch}"
            if res.get("already_exists")
            else f"opened a PR for {workspace.branch}"
        )
        outcome = {"action": action, "state": "fired", "detail": detail,
                   "pr_url": pr_url}
    except Exception as exc:  # noqa: BLE001 — a failed rung must not sink the verdict
        detail = getattr(exc, "stderr", None) or f"{type(exc).__name__}: {exc}"
        await _notify(hub, workspace, action=action, state="failed",
                      detail=str(detail), report=report)
        return {"action": action, "state": "failed", "detail": str(detail)}

    await _notify(hub, workspace, action=action, state="fired", detail=detail,
                  report=report, pr_url=pr_url)
    return outcome


async def gate_and_fire(
    *,
    store: Store,
    hub: Hub,
    adapter: TestRunnerAdapter,
    workspace: Workspace,
    project_path: str,
    changed_since: str | None = None,
    only: list[tuple[str, str]] | None = None,
    trigger: str = "manual",
) -> TestRun:
    """``run_gate`` then the rung handoff, as one task — for the gate entry points that
    schedule the gate directly (``POST /workspaces/{id}/tests`` and the fs watcher's
    adopted-worktree auto-gate). ``run_gate`` pops its own ``store.gate_tasks`` entry
    before returning, so by the time ``maybe_fire`` runs the busy guard reads clear.

    ``runner.run_agent`` deliberately doesn't use this: it must fire the rung *after*
    releasing the agent's slot, and after any auto-fix rounds have settled."""
    test = await run_gate(
        store=store, hub=hub, adapter=adapter, workspace=workspace,
        project_path=project_path, changed_since=changed_since, only=only,
        trigger=trigger,
    )
    await maybe_fire(store=store, hub=hub, workspace=workspace, test=test)
    return test
