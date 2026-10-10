"""Gate Receipt (usp-critique-plan.md idea 1, week 2-3): the exportable evidence
packet a reviewer reads instead of the diff.

Every field here is read off facts the gate (or an on-demand pass a human already
triggered) already computed — ``build_receipt`` runs no test. The
one lookup it makes is the linked GitHub login for the authorship line (cached, time-boxed,
never fatal; see ``_author``). It reuses exactly the same sources the ship step and the trust checklist
already read: ``store.latest_test`` (suite/tamper), ``store.get_line_hits``
+ ``verified_hunks.annotate`` (per-line proof, same as ``GET .../verified-hunks``),
and the workspace's own model/effort/cost.

Three sinks live elsewhere, all built on this one assembly:
  - ``GET /workspaces/{id}/receipt`` — the ④ ship step render.
  - ``POST /workspaces/{id}/receipt/pr-comment`` — posts the markdown via ``gh``.
  - ``integrate.py``'s local-merge path — writes the markdown as a ``git notes``
    on the merge commit (remote/gh merges skip this: pushing a notes ref to a
    shared remote is a bigger, riskier action than this feature earns yet).
"""

from __future__ import annotations

import asyncio
import hashlib
import re
import statistics
import traceback

from . import git_ops, scope_fence
from .xp_hooks import norm_path
from .acceptance import receipt_line as acceptance_line
from . import verified_hunks as verified_hunks_svc
from .new_dependencies import new_dependencies
from .models import (
    Receipt,
    ReceiptAgent,
    ReceiptPlan,
    ReceiptGuard,
    ReceiptNewDependency,
    ReceiptReading,
    ReceiptResearch,
    ReceiptSuite,
    ReceiptHandEdits,
    ReceiptScope,
    ReceiptTamper,
    ReceiptVerifiedHunks,
    QUICK_VIEW_SECONDS,
    TestRunStatus,
    Workspace,
    WorkspaceStatus,
)


def diff_fingerprint(diff_text: str) -> str:
    """Cheap identity key for a diff snapshot (did the tree move since the gate measured it).
    Not a security hash, just a short identity check."""
    return hashlib.sha256(diff_text.encode()).hexdigest()[:16]


def written_by(
    workspace: Workspace, model: str | None, author: str | None = None, hand_files: int = 0
) -> str:
    """Plain-words authorship for the receipt. The arrow is ASCII on purpose: this string
    lands verbatim in the markdown sinks (PR comment, git note). ``author`` is the dev's
    GitHub login when one is linked; without it the human side reads "you"."""
    human = author or "you"
    switches = workspace.mode_switches
    if not switches:
        if workspace.mode == "manual":
            return human
        if hand_files:
            s = "" if hand_files == 1 else "s"
            return f"{human} and the agent ({hand_files} file{s} edited by hand)"
        return f"agent \u00b7 {model}" if model else "agent"
    parts = []
    before = "agent" if switches[0].to == "manual" else "manual"
    for sw in switches:
        parts.append(f"{before} -> {sw.to} at {sw.at.astimezone().strftime('%H:%M')}")
        before = sw.to
    return f"{human} and the agent ({', '.join(parts)})"


async def _author(store, workspace: Workspace) -> str | None:
    """The GitHub login haro resolves for this workspace's project (a per-project override,
    the account that can push to the repo, or the stored default), or None. A bare terminal
    account is not named: it is a guess, and a wrong name on a receipt is worse than "you".
    A repo with no github.com origin has no account to name and costs no lookup. Cached by
    ``github_accounts``, bounded, and any failure just means no name."""
    try:
        from . import github_accounts

        project = store.get_project(workspace.project_id)
        url = await git_ops.get_remote(workspace.worktree_path)
        slug = git_ops.github_slug(url) if url else None
        if not slug:
            return None
        res = await asyncio.wait_for(
            github_accounts.resolve(slug, project.gh_account if project else None),
            _AUTHOR_BUDGET,
        )
    except Exception:  # noqa: BLE001 (incl. TimeoutError): the receipt must never cost on this
        return None
    return res.login if res.source in ("override", "auto", "default") else None


_AUTHOR_BUDGET = 3.0


async def _xp_line(store, workspace: Workspace) -> str | None:
    """"XP: +N (labels)": the merge awards actually paid once merged, a preview before. XP is a
    side note on the receipt, so a failure here must not cost the receipt."""
    try:
        from . import xp_hooks

        if workspace.status == WorkspaceStatus.merged:
            return xp_hooks.merged_line(store, workspace.id)
        return xp_hooks.merge_preview(store, workspace, await xp_hooks.merge_changed_paths(workspace))
    except Exception:  # noqa: BLE001
        return None


async def build_receipt(*, store, workspace: Workspace, settings) -> Receipt:
    run = store.latest_test(workspace.id)

    if run is None:
        verdict = "none"
    else:
        # Mirrors gate.py's own `green` conjunction (the block that sets
        # `workspace.status`). `workspace.status` itself isn't used instead because it
        # also changes for unrelated lifecycle reasons (merged, archived) that don't mean
        # "not gated".
        blocked = bool(run.coverage_blocked or run.merge_conflict or run.tamper_blocked or run.acceptance_blocked)
        passed = run.status == TestRunStatus.passed and not blocked
        # `degraded` is a GREEN-only qualifier, not a fourth independent state: some
        # `degraded_reasons` writers (e.g. a merge-result git hiccup) fire before the
        # suite even runs, so a genuinely failed/blocked run can carry degraded_reasons
        # too. Labeling that "DEGRADED" instead of "RED" would be a worse
        # mischaracterization than the one this field exists to prevent — a failing
        # suite is the one thing this artifact must never soften. The reasons still
        # render in their own section below regardless of which label wins.
        if not passed:
            verdict = "red"
        elif list(getattr(run, "degraded_reasons", []) or []):
            verdict = "degraded"
        else:
            verdict = "green"

    suite = ReceiptSuite(
        runner=(run.runner if run else settings.gate_runner or "vitest"),
        scope=(run.scope if run else "all"),
        total=run.total if run else 0,
        passed=run.passed if run else 0,
        failed=run.failed if run else 0,
        skipped=run.skipped if run else 0,
        impacted_count=(len(run.impacted_tests) if run and run.impacted_tests else None),
    )

    # `run.tamper_measured` (models.py) is the authoritative "did the alarm actually
    # complete on this run" signal — `tamper_findings == []` alone can't answer that
    # (it's also `[]` when the alarm is off, scoped to a partial re-run, or its engine
    # crashed). Reading only the project's `tamper_alarm` setting here would have missed
    # exactly those cases, so this defers entirely to what gate.py itself observed.
    tamper = ReceiptTamper(
        measured=bool(run and run.tamper_measured),
        clean=not bool(run and run.tamper_findings),
        findings_count=len(run.tamper_findings) if run else 0,
        note=run.tamper_note if run else None,
        protected=bool(run and run.tests_protected),
    )

    # The last GREEN gate's cached per-line coverage snapshot — same source
    # `GET .../verified-hunks` reads. `sha` is the sha it measured — NOT a live
    # `rev_parse HEAD`, which on the merge path is read *before* `integrate.commit_all`
    # stages the agent's work and so would name the wrong commit.
    snap = store.get_line_hits(workspace.id) or {}
    gate_sha = snap.get("sha")

    verified_hunks = await _build_verified_hunks(store, workspace, settings, snap)
    agent_run = store.latest_run(workspace.id)
    scope = _build_scope(store, workspace)
    reading = await _build_reading(workspace)
    hand = await _build_hand_edits(store, workspace)
    saved_plans = [p for p in getattr(workspace, "plans", []) if p.saved]
    log = getattr(workspace, "research_log", None)
    lookups = getattr(log, "count", 0)
    research_unverified = bool(getattr(log, "unverified", False)) or any(
        getattr(e, "guard_note", None) for e in getattr(log, "entries", [])
    )

    return Receipt(
        workspace_id=workspace.id,
        branch=workspace.branch,
        base_ref=workspace.base_ref,
        xp=await _xp_line(store, workspace),
        verdict=verdict,
        gate_sha=gate_sha,
        digest=run.diff_fingerprint if run else None,
        written_by=written_by(
            workspace,
            agent_run.model if agent_run else None,
            await _author(store, workspace),
            hand_files=len(hand.paths) + len(hand.shared),
        ),
        sandbox_profile=run.sandbox_profile if run else None,
        degraded_reasons=list(getattr(run, "degraded_reasons", []) or []) if run else [],
        suite=suite,
        tamper=tamper,
        scope=scope,
        guard=_build_guard(store, workspace),
        new_dependencies=await _build_dependencies(workspace),
        reading=reading,
        hand_edits=hand,
        acceptance=(
            run.acceptance
            if run and workspace.test_first is not None and workspace.test_first.phase == "approved"
            else None
        ),
        verified_hunks=verified_hunks,
        agent=ReceiptAgent(
            model=agent_run.model if agent_run else None,
            effort=agent_run.effort if agent_run else None,
            cost_usd=agent_run.cost_usd if agent_run else None,
        ),
        plan=ReceiptPlan(
            plans=len(saved_plans),
            steps=sum(len(p.steps) for p in saved_plans),
            done=sum(1 for p in saved_plans for st in p.steps if st.done),
            unverified=any(p.guard_note for p in saved_plans),
        ) if saved_plans else None,
        research=ReceiptResearch(lookups=lookups, unverified=research_unverified) if lookups else None,
    )


async def _build_reading(workspace: Workspace) -> ReceiptReading:
    """How the diff was read in haro: the review step's Viewed marks measured against the files
    that are changed NOW, so a file added after the report counts as not viewed. The client
    reports the marks (haro cannot see what a person read), so this is a record of what was done
    in the app, never a claim that the change was understood."""
    rec = workspace.review_record
    try:
        changed = {
            norm_path(p) for p in await git_ops.working_changed_paths(workspace.worktree_path, workspace.base_ref)
        }
    except Exception:  # noqa: BLE001 - a broken diff read must not break the receipt
        changed = None
    seen = list({norm_path(v.path): v for v in rec.viewed if changed is None or norm_path(v.path) in changed}.values())
    seconds = [v.seconds for v in seen]
    return ReceiptReading(
        recorded=rec.reported_at is not None,
        files=len(changed) if changed is not None else rec.files,
        viewed=len(seen),
        median_seconds=round(statistics.median(seconds), 1) if seconds else None,
        quick_views=sum(1 for s in seconds if s < QUICK_VIEW_SECONDS),
        reason=rec.reason,
    )


async def _build_hand_edits(store, workspace: Workspace) -> ReceiptHandEdits:
    """What changed in the worktree that no agent run touched. Unknown (not guessed) when there
    is no agent run, a run has no record of its edits, or the worktree cannot be read."""
    runs = [r for r in store.runs.values() if r.workspace_id == workspace.id and not r.plan]
    if not runs:
        return ReceiptHandEdits()
    unrecorded = sum(1 for r in runs if r.touched is None)
    if unrecorded:
        return ReceiptHandEdits(unrecorded_runs=unrecorded)
    try:
        if workspace.setup_tree:  # everything after the first setup, so setup's own changes never count
            changed = await scope_fence.changed_since(workspace.worktree_path, workspace.setup_tree)
        else:
            changed = await git_ops.working_changed_paths(workspace.worktree_path, workspace.base_ref)
    except Exception:  # noqa: BLE001 - a merged or archived worktree: say nothing
        return ReceiptHandEdits()
    agent = {p for r in runs for p in (r.touched or [])}
    saved = set(workspace.hand_saved_paths)
    return ReceiptHandEdits(
        known=True,
        paths=sorted(p for p in changed if p not in agent),
        shared=sorted(p for p in changed if p in agent and p in saved),
    )


def _build_scope(store, workspace: Workspace) -> ReceiptScope:
    runs = [r for r in store.runs.values() if r.workspace_id == workspace.id and not r.plan]
    fenced = [r for r in runs if r.scope]
    return ReceiptScope(
        patterns=list(dict.fromkeys(p for r in fenced for p in r.scope)),
        fenced_runs=len(fenced),
        editing_runs=len(runs),
        reverted=sorted({p for r in fenced for p in r.scope_reverted}),
        unchecked_runs=sum(1 for r in fenced if r.scope_error),
        blocked=sorted({p for r in fenced for p in r.fence_blocked}),
    )


def _build_guard(store, workspace: Workspace) -> ReceiptGuard:
    refused = [x for r in store.runs.values() if r.workspace_id == workspace.id for x in r.guard_refused]
    return ReceiptGuard(refused=list(dict.fromkeys(refused))[:20])


async def _build_dependencies(workspace: Workspace) -> list[ReceiptNewDependency]:
    try:
        changed = await git_ops.working_changed_paths(workspace.worktree_path, workspace.base_ref)
        return await new_dependencies(workspace.worktree_path, workspace.base_ref, changed)
    except Exception:  # noqa: BLE001 - a broken manifest read must not break the receipt
        return []


async def _build_verified_hunks(
    store, workspace: Workspace, settings, snap: dict
) -> ReceiptVerifiedHunks:
    if not settings.verified_hunks:
        return ReceiptVerifiedHunks(note="per-line proof is off for this project")
    runner = settings.gate_runner or "vitest"
    if runner != "vitest":
        return ReceiptVerifiedHunks(note=f"per-line coverage is vitest-only (this gate runs {runner})")
    if workspace.status != WorkspaceStatus.gate_green:
        # Green-only, same rule `GET .../verified-hunks` enforces (main.py) — a red gate
        # must show no proof at all rather than a previous green's. Belt-and-suspenders
        # with `gate.run_gate` dropping the cache on red: the invariant should hold even
        # if it's only ever checked in one of the two places.
        return ReceiptVerifiedHunks(note="no green gate has measured this tree yet")

    if not snap or not snap.get("line_hits"):
        return ReceiptVerifiedHunks(note="no green gate has measured this tree yet")

    try:
        current_diff, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
    except Exception as exc:  # noqa: BLE001 — a broken diff read must not break the receipt
        traceback.print_exc()
        detail = exc.stderr if isinstance(exc, git_ops.GitError) else f"{type(exc).__name__}: {exc}"
        return ReceiptVerifiedHunks(note=f"could not read the diff: {detail}")

    report = verified_hunks_svc.annotate(
        snap.get("diff") or "",
        current_diff,
        snap.get("line_hits"),
        scope=snap.get("scope") or "",
    )
    # Excludes STALE files from the percentage exactly like `verified_hunks.summarize()`
    # does (a file whose added lines moved since the gate ran carries no real line data,
    # so counting its lines as "0% executed" would understate the true proof coverage) —
    # reusing `summarize()`'s own note keeps the "N files changed since the gate ran"
    # caveat attached to the number instead of getting silently dropped.
    live = [f for f in report.files if not f.stale]
    added = sum(f.added for f in live)
    executed = sum(f.executed for f in live)
    percentage = round(100 * executed / added, 1) if added else None
    untested = sorted(f.path for f in live if f.added and f.unexecuted)
    return ReceiptVerifiedHunks(
        supported=True,
        percentage=percentage,
        untested_files=untested,
        note=report.note,
    )


def _md(text: str) -> str:
    """Text that came from a file or a command, safe inside a markdown line and a code span."""
    return re.sub(r"[`\r\n]", "", _clean(text))


def _clean(text: str) -> str:
    """Dynamic strings (branch names, gate notes, degraded reasons) can carry an em-dash
    from their source; the public receipt must have none."""
    return re.sub(r"[ \t]*\u2014[ \t]*", ": ", text)


#: Runners whose gate is a pass or fail, not a test count (a shell command, a linter's JSON).
_COUNTLESS_RUNNERS = frozenset({"command", "offense"})


def _no_count(suite: ReceiptSuite) -> bool:
    """A command or linter gate ran and reported no test count. A vitest or pytest run with
    zero tests is not this: "0 passed" there is the signal that something is wrong."""
    return suite.runner in _COUNTLESS_RUNNERS and suite.total == 0 and not suite.failed


def pr_line(receipt: Receipt, attestation_sha: str | None) -> str:
    """One plain markdown line for a PR body: verdict and counts, plus the
    reproduce command only when a verified attestation exists for this tree.
    Text only (no badge image, no external service) so it renders anywhere."""
    if receipt.verdict == "none":
        return "Gate: not gated"
    s = receipt.suite
    if _no_count(s):
        # A command or linter gate has no test count; "0 passed, 0 failed" reads like nothing ran.
        line = f"Gate: {receipt.verdict} (no test count)"
    else:
        line = f"Gate: {receipt.verdict}, {s.passed} passed, {s.failed} failed"
    if s.skipped:
        line += f", {s.skipped} skipped"
    if attestation_sha:
        sha = attestation_sha[:12]
        line += f" \u00b7 attested {sha} \u00b7 reproduce: haro verify {sha} --rerun"
    return line


def reading_line(r: ReceiptReading) -> str:
    """One bounded sentence about how the diff was read in haro. It says what the review step
    recorded and nothing about whether the change was understood."""
    if not r.recorded:
        return "- Review in haro: no Viewed marks were recorded"
    parts = [f"Viewed {r.viewed} of {r.files} {'file' if r.files == 1 else 'files'}"]
    if r.median_seconds is not None:
        parts.append(f"median {r.median_seconds:g} s open per file")
    if r.quick_views:
        parts.append(f"{r.quick_views} marked Viewed in under {QUICK_VIEW_SECONDS:g} s")
    return "- Review in haro: " + ", ".join(parts)


def render_markdown(receipt: Receipt) -> str:
    lines: list[str] = []
    verdict_label = {
        "green": "GREEN", "red": "RED", "degraded": "DEGRADED", "none": "NOT GATED",
    }[receipt.verdict]
    lines.append(f"# haro gate receipt: {verdict_label}")
    lines.append("")
    lines.append(f"- Branch: `{receipt.branch}` → `{receipt.base_ref}`")
    if receipt.written_by:
        lines.append(f"- Written by: {receipt.written_by}")
    if receipt.hand_edits.unrecorded_runs:
        lines.append(
            f"  - hand edits cannot be listed: haro has no record of what {receipt.hand_edits.unrecorded_runs} "
            "agent run(s) touched"
        )
    if receipt.hand_edits.paths:
        listed = ", ".join(f"`{p}`" for p in receipt.hand_edits.paths[:10])
        more = f" and {len(receipt.hand_edits.paths) - 10} more" if len(receipt.hand_edits.paths) > 10 else ""
        lines.append(f"  - edited by hand, outside the agent's runs: {listed}{more}")
    if receipt.hand_edits.shared:
        lines.append(
            "  - edited by the agent and by hand: "
            + ", ".join(f"`{p}`" for p in receipt.hand_edits.shared[:10])
        )
    if receipt.plan is not None:
        n = receipt.plan.steps
        edits = "unverified" if receipt.plan.unverified else receipt.plan.ai_edits
        lines.append(f"- Plan: haro AI \u00b7 {n} step{'s' if n != 1 else ''} \u00b7 AI edits: {edits}")
    if receipt.research is not None:
        n = receipt.research.lookups
        tail = " \u00b7 AI edits: unverified" if receipt.research.unverified else ""
        lines.append(f"- Research: {n} lookup{'s' if n != 1 else ''}{tail}")
    lines.append(reading_line(receipt.reading))
    for dep in receipt.new_dependencies:
        lines.append(
            f"- New in {_md(dep.path)} (named there now, not at the base; no registry was checked): "
            + ", ".join(f"`{_md(n)}`" for n in dep.names)
        )
    if receipt.guard.refused:
        lines.append(
            "- Refused before they ran (a text match, not a complete list): "
            + ", ".join(_md(x) for x in receipt.guard.refused)
        )
    if receipt.reading.reason:
        lines.append(f"- Approval reason: {_clean(receipt.reading.reason)} (typed by the developer)")
    if receipt.gate_sha:
        lines.append(f"- Tree the gate measured: `{receipt.gate_sha[:12]}`")
    if _no_count(receipt.suite):
        lines.append(
            f"- Suite: ran, no test count ({receipt.suite.runner}, scope={receipt.suite.scope})"
        )
    else:
        lines.append(
            f"- Suite: {receipt.suite.passed}/{receipt.suite.total} passed "
            f"({receipt.suite.runner}, scope={receipt.suite.scope})"
        )
    if receipt.suite.impacted_count is not None:
        lines.append(f"- Impacted tests run: {receipt.suite.impacted_count}")
    if receipt.sandbox_profile:
        lines.append(f"- Sandbox: offline (bwrap, profile `{receipt.sandbox_profile}`)")

    if receipt.degraded_reasons:
        lines.append("")
        lines.append("## Degraded: a check this project asked for could not run")
        for reason in receipt.degraded_reasons:
            lines.append(f"- {reason}")

    lines.append("")
    lines.append("## Tests that can't be fooled")
    if receipt.tamper.measured:
        state = "clean" if receipt.tamper.clean else f"{receipt.tamper.findings_count} finding(s)"
        lines.append(f"- Tamper alarm: {state}" + (f": {receipt.tamper.note}" if receipt.tamper.note else ""))
    else:
        lines.append("- Tamper alarm: not measured")
    if receipt.acceptance is not None:
        lines.append("- " + acceptance_line(receipt.acceptance))
    if receipt.tamper.protected:
        lines.append("- Existing tests were edit-protected for the agent (tamper alarm still checks the diff).")
    if receipt.scope.patterns:
        listed = ", ".join(f"`{p}`" for p in receipt.scope.patterns)
        lines.append(
            f"- Agent edits fenced to {listed} ({receipt.scope.fenced_runs} of "
            f"{receipt.scope.editing_runs} agent runs)"
        )
        if receipt.scope.unchecked_runs:
            lines.append(
                f"  - the fence could not check {receipt.scope.unchecked_runs} run(s): review the whole diff"
            )
        if receipt.scope.blocked:
            lines.append(
                f"  - {len(receipt.scope.blocked)} file(s) the agent tried to edit outside the fence, refused before the write: "
                + ", ".join(f"`{p}`" for p in receipt.scope.blocked[:10])
            )
        if receipt.scope.reverted:
            lines.append(
                f"  - {len(receipt.scope.reverted)} out-of-scope change(s) reverted: "
                + ", ".join(f"`{p}`" for p in receipt.scope.reverted[:10])
            )
    lines.append("")
    lines.append("## Proof per line")
    if receipt.verified_hunks.supported and receipt.verified_hunks.percentage is not None:
        lines.append(f"- Verified hunks: {receipt.verified_hunks.percentage}% of added lines executed by the suite")
        if receipt.verified_hunks.note:
            lines.append(f"  ({receipt.verified_hunks.note})")
        if receipt.verified_hunks.untested_files:
            lines.append("- Untested files:")
            for f in receipt.verified_hunks.untested_files[:20]:
                lines.append(f"  - `{f}`")
    else:
        lines.append(f"- Verified hunks: {receipt.verified_hunks.note or 'not available'}")

    if receipt.agent.model:
        agent_bits = [receipt.agent.model]
        if receipt.agent.effort:
            agent_bits.append(receipt.agent.effort)
        agent_line = "/".join(agent_bits)
        if receipt.agent.cost_usd is not None:
            agent_line += f", ${receipt.agent.cost_usd:.2f}"
        lines.append("")
        lines.append(f"_Agent: {agent_line}_")

    return _clean("\n".join(lines) + "\n")
