"""Gate Receipt (usp-critique-plan.md idea 1, week 2-3): the exportable evidence
packet a reviewer reads instead of the diff.

Every field here is read off facts the gate (or an on-demand pass a human already
triggered) already computed — ``build_receipt`` runs no test, no mutation pass, no
gh call. It reuses exactly the same sources the ship step and the trust checklist
already read: ``store.latest_test`` (suite/tamper), ``store.get_line_hits``
+ ``verified_hunks.annotate`` (per-line proof, same as ``GET .../verified-hunks``),
``store.mutation_runs`` (whatever score was last computed on demand, never
recomputed here), and the workspace's own model/effort/cost.

Three sinks live elsewhere, all built on this one assembly:
  - ``GET /workspaces/{id}/receipt`` — the ④ ship step render.
  - ``POST /workspaces/{id}/receipt/pr-comment`` — posts the markdown via ``gh``.
  - ``integrate.py``'s local-merge path — writes the markdown as a ``git notes``
    on the merge commit (remote/gh merges skip this: pushing a notes ref to a
    shared remote is a bigger, riskier action than this feature earns yet).
"""

from __future__ import annotations

import hashlib
import re
import traceback

from . import git_ops
from .acceptance import receipt_line as acceptance_line
from . import verified_hunks as verified_hunks_svc
from .models import (
    Receipt,
    ReceiptAgent,
    ReceiptPlan,
    ReceiptResearch,
    ReceiptMutation,
    ReceiptSuite,
    ReceiptTamper,
    ReceiptVerifiedHunks,
    TestRunStatus,
    Workspace,
    WorkspaceStatus,
)


def diff_fingerprint(diff_text: str) -> str:
    """Cheap staleness key for a diff snapshot (used to detect a mutation score
    measured against a tree that has since moved — see `MutationResponse.diff_fingerprint`).
    Not a security hash, just a short identity check."""
    return hashlib.sha256(diff_text.encode()).hexdigest()[:16]


def written_by(workspace: Workspace, model: str | None) -> str:
    """Plain-words authorship for the receipt. The arrow is ASCII on purpose: this string
    lands verbatim in the markdown sinks (PR comment, git note)."""
    switches = workspace.mode_switches
    if not switches:
        if workspace.mode == "manual":
            return "you, by hand"
        return f"agent \u00b7 {model}" if model else "agent"
    parts = []
    before = "agent" if switches[0].to == "manual" else "manual"
    for sw in switches:
        parts.append(f"{before} -> {sw.to} at {sw.at.astimezone().strftime('%H:%M')}")
        before = sw.to
    return f"you and the agent ({', '.join(parts)})"


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
        flaky_retried=list(run.flaky_retried) if run else [],
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
    mutation = await _build_mutation(store, workspace)
    agent_run = store.latest_run(workspace.id)
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
        written_by=written_by(workspace, agent_run.model if agent_run else None),
        sandbox_profile=run.sandbox_profile if run else None,
        degraded_reasons=list(getattr(run, "degraded_reasons", []) or []) if run else [],
        suite=suite,
        tamper=tamper,
        acceptance=(
            run.acceptance
            if run and workspace.test_first is not None and workspace.test_first.phase == "approved"
            else None
        ),
        verified_hunks=verified_hunks,
        mutation=mutation,
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


async def _build_mutation(store, workspace: Workspace) -> ReceiptMutation:
    cached = store.mutation_runs.get(workspace.id)
    if cached is None:
        return ReceiptMutation(ran=False, note="mutation score has not been run for this tree")
    # Best-effort staleness, keyed on the DIFF TEXT rather than `gate_sha` (a commit
    # sha): haro doesn't commit agent work until merge, so HEAD can sit still for a
    # workspace's entire lifetime while its uncommitted diff keeps moving underneath
    # it — comparing shas alone would miss the dominant case entirely. An older cached
    # score with no `diff_fingerprint`, or a diff read that fails, degrades to "can't
    # say" (stays False) rather than a false positive.
    stale = False
    if cached.diff_fingerprint:
        try:
            current_diff, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
            stale = diff_fingerprint(current_diff) != cached.diff_fingerprint
        except Exception:  # noqa: BLE001 — a broken diff read must not break the receipt
            traceback.print_exc()
    note = cached.note
    if stale:
        note = "tree changed since this score was measured: re-run mutation to refresh it"
    return ReceiptMutation(
        supported=cached.supported,
        ran=True,
        stale=stale,
        score=cached.score,
        survivors=cached.survivors,
        note=note,
    )


def flaky_retry_line(retried: list[str]) -> str:
    n = len(retried)
    return f"- Green after retrying {n} known-flaky test{'s' if n != 1 else ''}: " + ", ".join(
        _clean(t.split("::", 1)[-1]) for t in retried
    )


def _clean(text: str) -> str:
    """Dynamic strings (branch names, gate notes, degraded reasons) can carry an em-dash
    from their source; the public receipt must have none."""
    return re.sub(r"[ \t]*\u2014[ \t]*", ": ", text)


def pr_line(receipt: Receipt, attestation_sha: str | None) -> str:
    """One plain markdown line for a PR body: verdict and counts, plus the
    reproduce command only when a verified attestation exists for this tree.
    Text only (no badge image, no external service) so it renders anywhere."""
    if receipt.verdict == "none":
        return "Gate: not gated"
    s = receipt.suite
    line = f"Gate: {receipt.verdict}, {s.passed} passed, {s.failed} failed"
    if s.skipped:
        line += f", {s.skipped} skipped"
    if attestation_sha:
        sha = attestation_sha[:12]
        line += f" \u00b7 attested {sha} \u00b7 reproduce: haro verify {sha} --rerun"
    return line


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
    if receipt.plan is not None:
        n = receipt.plan.steps
        edits = "unverified" if receipt.plan.unverified else receipt.plan.ai_edits
        lines.append(f"- Plan: haro AI \u00b7 {n} step{'s' if n != 1 else ''} \u00b7 AI edits: {edits}")
    if receipt.research is not None:
        n = receipt.research.lookups
        tail = " \u00b7 AI edits: unverified" if receipt.research.unverified else ""
        lines.append(f"- Research: {n} lookup{'s' if n != 1 else ''}{tail}")
    if receipt.gate_sha:
        lines.append(f"- Tree the gate measured: `{receipt.gate_sha[:12]}`")
    lines.append(
        f"- Suite: {receipt.suite.passed}/{receipt.suite.total} passed "
        f"({receipt.suite.runner}, scope={receipt.suite.scope})"
    )
    if receipt.suite.impacted_count is not None:
        lines.append(f"- Impacted tests run: {receipt.suite.impacted_count}")
    if receipt.suite.flaky_retried:
        lines.append(flaky_retry_line(receipt.suite.flaky_retried))
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
    if receipt.mutation.ran and receipt.mutation.supported and receipt.mutation.score is not None:
        stale = " (stale, tree changed since scored)" if receipt.mutation.stale else ""
        lines.append(f"- Mutation score: {receipt.mutation.score}%{stale}")
        for s in receipt.mutation.survivors[:10]:
            lines.append(f"  - survivor: `{s.path}:{s.line}` ({s.operator})")
    else:
        lines.append(f"- Mutation score: {receipt.mutation.note or 'not run'}")

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
