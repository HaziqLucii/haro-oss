"""Gate Receipt (usp-critique-plan.md idea 1, week 2-3): the exportable evidence
packet a reviewer reads instead of the diff.

Every field here is read off facts the gate (or an on-demand pass a human already
triggered) already computed — ``build_receipt`` runs no test, no mutation pass, no
gh call. It reuses exactly the same sources the ship step and the trust checklist
already read: ``store.latest_test`` (suite/tamper/quality), ``store.get_line_hits``
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
import traceback

from . import git_ops
from . import verified_hunks as verified_hunks_svc
from .models import (
    Receipt,
    ReceiptAgent,
    ReceiptMutation,
    ReceiptPlanCompliance,
    ReceiptQuality,
    ReceiptReview,
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


async def build_receipt(*, store, workspace: Workspace, settings) -> Receipt:
    run = store.latest_test(workspace.id)

    # The count of quality findings that actually meet the blocking severity
    # threshold (`QualityFindingRow.blocking`, mirrors `GateSummary.quality_blocking`
    # in gate.py) — computed once, up front, because it feeds BOTH the verdict below
    # and `ReceiptQuality`. This is NOT the same question as `run.quality_blocked`:
    # that flag only fires under `[quality] enforce = "block"`. Under "warn" it stays
    # False even with a blocking-severity finding on a changed line, because "warn"
    # only means the AUTOMATED verdict doesn't go red for it — `ship_preflight`
    # (integrate.py) still refuses to merge ANY blocking finding regardless of
    # enforce mode ("a leaked credential must not merge just because the project set
    # the enforcement dial to warn"). Reading only `quality_blocked` here reported
    # exactly that case as GREEN — round 9 of review found this.
    quality_blocking_count = (
        sum(1 for f in run.quality_findings if f.blocking) if run and run.quality_findings else 0
    )

    if run is None:
        verdict = "none"
    else:
        # Mirrors gate.py's own `green` conjunction (the block that sets
        # `workspace.status`) PLUS ship_preflight's independent, mode-agnostic
        # quality-blocking check above — deriving from `run.status`/`run.quality_blocked`
        # alone missed exactly the "warn mode, blocking finding" case ship_preflight
        # still refuses. `workspace.status` itself isn't used instead because it also
        # changes for unrelated lifecycle reasons (merged, archived) that don't mean
        # "not gated".
        blocked = bool(
            run.coverage_blocked or run.merge_conflict or run.tamper_blocked
            or run.quality_blocked or quality_blocking_count
            # The refuter (Phase 3): unlike quality_blocking_count above, review_blocked
            # already IS the enforce-aware flag — it only ever sets under
            # `review_enforce = "block"` itself, so no separate mode-agnostic count is
            # needed here the way quality's severity-threshold split required one.
            or run.review_blocked
        )
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
    )

    # `run.quality_measured` (models.py), not `quality_findings is not None`: the tri-
    # state's `[]` means "measured clean" ONLY when at least one scanner actually ran.
    # When every configured scanner was unavailable, `quality.analyze` still leaves
    # `findings == []` (same shape as a real clean pass) while recording the failure in
    # `degraded_reasons` — reading the tri-state alone would report that as clean.
    # Plan compliance (backlog/double-gate.md §3) is a SEPARATE check from the
    # deterministic scanners above: it runs independently of `[quality] enabled` and
    # can set `quality_blocked` on its own. Without this, a plan-compliance-blocked run
    # rendered "not measured" (the deterministic tier's own honest state) with the
    # actual blocking cause nowhere in the artifact — round 7 of review found this.
    plan = run.plan_compliance if run else None
    quality = ReceiptQuality(
        measured=bool(run and run.quality_measured),
        # Mode-agnostic: True whenever a finding meets the blocking severity threshold,
        # not only under `enforce = "block"` — see the `quality_blocking_count` comment
        # above. This is what ship_preflight actually refuses on.
        blocked=quality_blocking_count > 0,
        findings_count=len(run.quality_findings) if run and run.quality_findings else 0,
        blocking_count=quality_blocking_count,
        note=run.quality_note if run else None,
        plan_compliance=ReceiptPlanCompliance(
            ran=plan is not None,
            error=plan.error if plan else None,
            compliant=plan.compliant if plan else True,
            confidence=plan.confidence if plan else None,
            summary=plan.summary if plan else None,
            gaps=len(plan.gaps) if plan else 0,
            blocking=bool(plan and plan.blocking),
            enforced=settings.quality_plan_compliance == "block",
        ),
    )

    # The refuter (Phase 3 — notes/workflow-roles-plan.md): a top-level field, not
    # nested under `quality`, since it's gated on `[roles]` and runs independently of
    # `[quality] enabled` entirely. Same `blocking AND enforced` split as
    # ReceiptPlanCompliance above, for the same round-8 reason.
    rv = run.review if run else None
    review = ReceiptReview(
        ran=rv is not None,
        error=rv.error if rv else None,
        verdict=rv.verdict if rv else "pass",
        summary=rv.summary if rv else None,
        must_fix=len(rv.must_fix) if rv else 0,
        blocking=bool(rv and rv.verdict == "fail"),
        enforced=settings.review_enforce == "block",
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

    return Receipt(
        workspace_id=workspace.id,
        branch=workspace.branch,
        base_ref=workspace.base_ref,
        verdict=verdict,
        gate_sha=gate_sha,
        digest=run.diff_fingerprint if run else None,
        sandbox_profile=run.sandbox_profile if run else None,
        degraded_reasons=list(getattr(run, "degraded_reasons", []) or []) if run else [],
        suite=suite,
        tamper=tamper,
        quality=quality,
        review=review,
        verified_hunks=verified_hunks,
        mutation=mutation,
        agent=ReceiptAgent(
            model=agent_run.model if agent_run else None,
            effort=agent_run.effort if agent_run else None,
            cost_usd=agent_run.cost_usd if agent_run else None,
        ),
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
        note = "tree changed since this score was measured — re-run mutation to refresh it"
    return ReceiptMutation(
        supported=cached.supported,
        ran=True,
        stale=stale,
        score=cached.score,
        survivors=cached.survivors,
        note=note,
    )


def render_markdown(receipt: Receipt) -> str:
    lines: list[str] = []
    verdict_label = {
        "green": "GREEN", "red": "RED", "degraded": "DEGRADED", "none": "NOT GATED",
    }[receipt.verdict]
    lines.append(f"# haro gate receipt — {verdict_label}")
    lines.append("")
    lines.append(f"- Branch: `{receipt.branch}` → `{receipt.base_ref}`")
    if receipt.gate_sha:
        lines.append(f"- Tree the gate measured: `{receipt.gate_sha[:12]}`")
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
        lines.append("## Degraded — a check this project asked for could not run")
        for reason in receipt.degraded_reasons:
            lines.append(f"- {reason}")

    lines.append("")
    lines.append("## Tests that can't be fooled")
    if receipt.tamper.measured:
        state = "clean" if receipt.tamper.clean else f"{receipt.tamper.findings_count} finding(s)"
        lines.append(f"- Tamper alarm: {state}" + (f" — {receipt.tamper.note}" if receipt.tamper.note else ""))
    else:
        lines.append("- Tamper alarm: not measured")
    if receipt.mutation.ran and receipt.mutation.supported and receipt.mutation.score is not None:
        stale = " (stale — tree changed since scored)" if receipt.mutation.stale else ""
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

    lines.append("")
    lines.append("## Policy")
    if receipt.quality.measured:
        state = f"{receipt.quality.findings_count} finding(s)" if receipt.quality.findings_count else "clean"
        # `blocked`/`blocking_count` are the deterministic scanners' OWN findings only
        # (mode-agnostic — see ReceiptQuality.blocked) — never conflated with a
        # plan-compliance block, which has its own line below with its own cause.
        blocked = f" ({receipt.quality.blocking_count} blocking)" if receipt.quality.blocked else ""
        lines.append(f"- Quality scan: {state}{blocked}" + (f" — {receipt.quality.note}" if receipt.quality.note else ""))
    else:
        lines.append("- Quality scan: not measured")
    pc = receipt.quality.plan_compliance
    if pc.ran:
        if pc.error:
            lines.append(f"- Plan compliance: could not run — {pc.error}")
        elif pc.blocking and pc.enforced:
            lines.append(f"- Plan compliance: BLOCKING — {pc.summary or 'diff does not implement the task'}")
        elif pc.blocking:
            # Meets the confidence bar but [quality] plan_compliance = "warn": flagged,
            # never enforced — must not read as "BLOCKING" on what may be a GREEN run.
            lines.append(f"- Plan compliance: flagged, not enforced ([quality] plan_compliance is \"warn\") — {pc.summary or 'diff does not implement the task'}")
        elif not pc.compliant:
            lines.append(f"- Plan compliance: possible gap ({pc.confidence} confidence, advisory) — {pc.summary or 'see gate for detail'}")
        else:
            lines.append("- Plan compliance: implements the task" + (f" — {pc.summary}" if pc.summary else ""))
    rv = receipt.review
    if rv.ran:
        if rv.error:
            lines.append(f"- Refuter: could not run — {rv.error}")
        elif rv.blocking and rv.enforced:
            lines.append(f"- Refuter: BLOCKING — {rv.must_fix} must-fix — {rv.summary or 'see gate for detail'}")
        elif rv.blocking:
            # Meets the bar but review_enforce = "warn": flagged, never enforced — must
            # not read as "BLOCKING" on what may be a GREEN run (same as plan compliance).
            lines.append(
                f"- Refuter: flagged, not enforced (review_enforce is \"warn\") — "
                f"{rv.must_fix} must-fix — {rv.summary or 'see gate for detail'}"
            )
        else:
            lines.append("- Refuter: no must-fix findings" + (f" — {rv.summary}" if rv.summary else ""))

    if receipt.agent.model:
        agent_bits = [receipt.agent.model]
        if receipt.agent.effort:
            agent_bits.append(receipt.agent.effort)
        agent_line = "/".join(agent_bits)
        if receipt.agent.cost_usd is not None:
            agent_line += f" — ${receipt.agent.cost_usd:.2f}"
        lines.append("")
        lines.append(f"_Agent: {agent_line}_")

    return "\n".join(lines) + "\n"
