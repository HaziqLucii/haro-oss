"""Gate Receipt (usp-critique-plan.md idea 1): the evidence packet a reviewer reads
instead of the diff. Reuses the same fixtures as test_verified_hunks_gate.py so a
receipt is built from a real gate run rather than a hand-constructed TestRun."""

from __future__ import annotations

import asyncio

import pytest

from haro import main, receipt as receipt_svc
from haro.config import load_project_settings
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import MutationResponse, MutationSurvivor, Project, Workspace
from haro.store import Store

from tests.test_verified_hunks_gate import DIFF, _Adapter


def _setup(tmp_path, monkeypatch, *, verified="true", tamper_alarm="off"):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main",
    )
    store.workspaces[ws.id] = ws

    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir(exist_ok=True)
    body = "[gate]\n"
    if verified:
        body += f"verified_hunks = {verified}\n"
    body += f"[workflow]\ntamper_alarm = '{tamper_alarm}'\n"
    (haro_dir / "settings.toml").write_text(body)

    async def fake_diff(*_a, **_k):
        return DIFF, None

    async def fake_head(*_a, **_k):
        return "abc1234"

    async def fake_inventories(*_a, **_k):
        # Defined-but-empty inventories: a genuinely SUCCESSFUL tamper measurement (as
        # opposed to `base_inv is None`, the degraded case test_tamper_gate.py covers
        # directly) — this bare tmp_path has no real vitest/node_modules, so the real
        # `analytics.test_inventories` would otherwise return None here regardless of
        # what this fixture is trying to test.
        return [], []

    monkeypatch.setattr("haro.git_ops.diff", fake_diff)
    monkeypatch.setattr("haro.git_ops.head_sha", fake_head)
    monkeypatch.setattr("haro.analytics.test_inventories", fake_inventories)
    return store, hub, ws, project


def _gate(store, hub, ws, project, adapter=None):
    asyncio.run(
        run_gate(store=store, hub=hub, adapter=adapter or _Adapter(), workspace=ws,
                 project_path=project.path)
    )


def test_no_gate_run_yet_reads_as_none(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    settings_ = load_project_settings(project.path)
    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verdict == "none"
    assert rcpt.suite.total == 0
    assert rcpt.mutation.ran is False
    md = receipt_svc.render_markdown(rcpt)
    assert "NOT GATED" in md


def test_green_gate_assembles_suite_and_verified_hunks(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verdict == "green"
    assert rcpt.suite.total == 2 and rcpt.suite.passed == 2
    assert rcpt.verified_hunks.supported is True
    assert rcpt.verified_hunks.percentage is not None
    assert rcpt.mutation.ran is False  # nobody has run mutation on this tree

    md = receipt_svc.render_markdown(rcpt)
    assert "GREEN" in md
    assert "2/2 passed" in md
    assert "executed by the suite" in md


def test_tamper_reads_as_unmeasured_when_the_alarm_is_off(tmp_path, monkeypatch):
    # The regression this fix exists for: `TestRun.tamper_findings` is always `[]` when
    # the alarm never ran, same as when it ran clean — so "measured" must come from the
    # project's own setting, not from the run's (always-empty) findings list. An
    # unmeasured tamper alarm rendering as "clean" would be a fabricated evidence line
    # in an artifact that gets posted to a shared PR.
    store, hub, ws, project = _setup(tmp_path, monkeypatch, tamper_alarm="off")
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.tamper.measured is False

    md = receipt_svc.render_markdown(rcpt)
    assert "Tamper alarm: not measured" in md
    assert "Tamper alarm: clean" not in md


def test_tamper_reads_as_measured_when_the_alarm_is_on(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch, tamper_alarm="warn")
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.tamper.measured is True
    assert rcpt.tamper.clean is True

    md = receipt_svc.render_markdown(rcpt)
    assert "Tamper alarm: clean" in md


def test_verified_hunks_excludes_stale_files_from_the_percentage(tmp_path, monkeypatch):
    # The regression this fix exists for: a file edited after the gate ran carries no
    # real line data (verified_hunks.py calls it "stale"), so counting its added lines
    # in the denominator used to render a flat, fabricated "0.0% executed" instead of
    # the honest "no evidence for this file" the live /verified-hunks endpoint gives.
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    edited = DIFF.replace(
        "+export const add = (a, b) => a + b\n",
        "+export const add = (a, b) => a + b\n+export const sneaky = () => 1\n",
    )

    async def fake_diff(*_a, **_k):
        return edited, None

    monkeypatch.setattr("haro.git_ops.diff", fake_diff)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verified_hunks.supported is True
    assert rcpt.verified_hunks.percentage is None
    assert rcpt.verified_hunks.untested_files == []
    assert "changed since the gate ran" in (rcpt.verified_hunks.note or "")

    md = receipt_svc.render_markdown(rcpt)
    assert "0.0% of added lines executed" not in md


def test_mutation_score_is_read_from_cache_not_recomputed(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    store.mutation_runs[ws.id] = MutationResponse(
        base_ref="main", diff_fingerprint=receipt_svc.diff_fingerprint(DIFF),
        supported=True, score=82, killed=9, survived=2, total_mutants=11,
        survivors=[MutationSurvivor(path="src/math.ts", line=2, operator="round → floor")],
    )

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.mutation.ran is True
    assert rcpt.mutation.stale is False
    assert rcpt.mutation.score == 82
    assert len(rcpt.mutation.survivors) == 1

    md = receipt_svc.render_markdown(rcpt)
    assert "82%" in md
    assert "src/math.ts:2" in md


def test_mutation_score_flags_stale_when_uncommitted_edits_move_the_tree(tmp_path, monkeypatch):
    # The regression round 3 of review found: haro doesn't commit agent work until
    # merge, so HEAD (and a sha-keyed staleness check) can sit still for a workspace's
    # entire lifetime while the tree keeps changing underneath it. No new commit, no new
    # gate run here — just the diff moving — and the fingerprint still has to catch it.
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    store.mutation_runs[ws.id] = MutationResponse(
        base_ref="main", diff_fingerprint=receipt_svc.diff_fingerprint(DIFF),
        supported=True, score=82, killed=9, survived=2, total_mutants=11,
    )

    edited = DIFF.replace(
        "+export const add = (a, b) => a + b\n",
        "+export const add = (a, b) => a + b\n+export const sneaky = () => 1\n",
    )

    async def fake_diff(*_a, **_k):
        return edited, None

    monkeypatch.setattr("haro.git_ops.diff", fake_diff)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.mutation.ran is True
    assert rcpt.mutation.stale is True
    assert rcpt.mutation.score == 82  # still shown, just flagged

    md = receipt_svc.render_markdown(rcpt)
    assert "82% (stale" in md


def test_mutation_score_with_no_fingerprint_degrades_to_not_stale(tmp_path, monkeypatch):
    # An older cached score predating this field (or one from a project where the diff
    # read failed) has nothing to compare against — "can't say" must not read as a false
    # positive.
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    store.mutation_runs[ws.id] = MutationResponse(
        base_ref="main", supported=True, score=70, killed=7, survived=3, total_mutants=10,
    )

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.mutation.ran is True
    assert rcpt.mutation.stale is False
    assert rcpt.mutation.score == 70


def test_verdict_is_red_when_the_gate_blocked_a_passed_suite(tmp_path, monkeypatch):
    # The regression round 4 of review found: a passed suite can still be BLOCKED (a
    # tamper finding under tamper_alarm="block", a coverage drop, a quality finding, a
    # merge conflict) — gate.py folds that into `workspace.status`/red without ever
    # touching `run.degraded_reasons` (degraded is a DIFFERENT concept: an unmeasured
    # check, not a measured-and-failing one). Deriving the verdict from `run.status`
    # alone reported this exact case as GREEN — the fabricated-evidence failure this
    # whole feature exists to prevent, on the artifact that gets posted to a shared PR.
    from tests.test_tamper_gate import _Adapter as TamperAdapter
    from tests.test_tamper_gate import Ref, RunResult, _patch_inventories
    from tests.test_tamper_gate import _setup as tamper_setup
    from tests.test_tamper_gate import _write_tamper_mode
    from haro.gate import run_gate

    store, hub, ws, project = tamper_setup(tmp_path, RunResult(ok=True, total=1, passed=1, failed=0, cases=[]))
    _write_tamper_mode(tmp_path, "block")
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )
    asyncio.run(
        run_gate(
            store=store, hub=hub, adapter=TamperAdapter(RunResult(ok=True, total=1, passed=1, failed=0, cases=[])),
            workspace=ws, project_path=project.path,
        )
    )
    assert ws.status.value == "gate_red"  # sanity: the gate really did block this
    run = store.latest_test(ws.id)
    assert run.status.value == "passed" and run.tamper_blocked is True  # the trap

    settings_ = load_project_settings(project.path)
    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verdict == "red"

    md = receipt_svc.render_markdown(rcpt)
    assert "GREEN" not in md
    assert "# haro gate receipt — RED" in md


def test_verdict_is_red_not_degraded_for_a_failed_run_with_degraded_reasons(tmp_path, monkeypatch):
    # The regression round 6 of review found: `degraded` is a GREEN-only qualifier
    # (some degraded_reasons writers, like the merge-result prep in gate.py, fire
    # BEFORE the suite even runs — so a genuinely failed run can carry them too). The
    # round-4 fix resolved "passed but blocked" correctly but still let a non-empty
    # `degraded_reasons` win over a failed run, mislabeling RED as DEGRADED — a worse
    # mischaracterization than the one round 4 fixed, since a failing suite is the one
    # thing this artifact must never soften.
    from haro.models import TestRun, TestRunStatus

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    store.add_test(TestRun(
        workspace_id=ws.id, runner="vitest", scope="all", status=TestRunStatus.failed,
        total=3, passed=1, failed=2,
        degraded_reasons=[
            "merge-result gating was requested but main could not be merged for the "
            "run: this green covers the worktree alone"
        ],
    ))
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verdict == "red"
    assert rcpt.degraded_reasons  # the context is still surfaced, just not the headline

    md = receipt_svc.render_markdown(rcpt)
    assert "# haro gate receipt — RED" in md
    assert "DEGRADED" not in md.split("\n")[0]
    assert "merge-result gating was requested" in md  # still visible in the body


def test_tamper_reads_as_unmeasured_when_base_inventory_is_missing(tmp_path, monkeypatch):
    # The regression review round 5 found: `base_inv is None` degrades to
    # `tamper_findings == []`, which alone reads as clean — gate.py's own comment on
    # this exact branch says "unmeasured is not clean". Reproduced end-to-end through
    # a real gate run and the receipt built from it, since this is the concrete
    # scenario the review reproduced against `build_receipt`.
    store, hub, ws, project = _setup(tmp_path, monkeypatch, tamper_alarm="warn")

    async def fake_inventories_none(*_a, **_k):
        return None, []

    monkeypatch.setattr("haro.analytics.test_inventories", fake_inventories_none)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.tamper.measured is False
    assert rcpt.verdict == "degraded"
    assert any("base test inventory" in r for r in rcpt.degraded_reasons)

    md = receipt_svc.render_markdown(rcpt)
    assert "Tamper alarm: clean" not in md
    assert "Tamper alarm: not measured" in md
    assert "base test inventory was unavailable" in md


def test_quality_reads_as_unmeasured_when_every_scanner_is_unavailable(tmp_path, monkeypatch):
    # The regression review round 5 found, quality's turn: `quality.analyze` leaves
    # `findings == []` — the tri-state's own "measured clean" value — even when every
    # configured scanner was unavailable (recorded only in `degraded_reasons`). Reading
    # `quality_findings is not None` alone reported that as a clean quality scan.
    from haro.quality import QualityReport

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    haro_dir = tmp_path / ".haro"
    (haro_dir / "settings.toml").write_text(
        "[quality]\nenabled = true\n[workflow]\ntamper_alarm = 'off'\n[gate]\nverified_hunks = false\n"
    )
    (tmp_path / "changed.py").write_text("x = 1\n")

    async def fake_changed_files(*_a, **_k):
        return [{"path": "changed.py"}]

    async def all_unavailable(**_kw):
        return QualityReport(degraded=["[quality] gitleaks could not run: not installed"])

    monkeypatch.setattr("haro.git_ops.changed_files", fake_changed_files)
    monkeypatch.setattr("haro.quality.analyze", all_unavailable)
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.quality.measured is False
    assert rcpt.verdict == "degraded"
    assert any("could not run" in r for r in rcpt.degraded_reasons)

    md = receipt_svc.render_markdown(rcpt)
    assert "Quality scan: clean" not in md
    assert "Quality scan: not measured" in md
    assert "gitleaks could not run" in md


def test_plan_compliance_flagged_under_warn_mode_never_says_blocking(tmp_path, monkeypatch):
    # The round-8 regression: `PlanComplianceResult.blocking` means "meets the bar to
    # block", not "blocked". Under `[quality] plan_compliance = "warn"` the gate never
    # enforces it, so a genuinely GREEN run must not export "BLOCKING" — that
    # contradicts the receipt's own header.
    import time as _time
    from haro.models import PlanComplianceResult, PlanGap, TestRun, TestRunStatus

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    (tmp_path / ".haro" / "settings.toml").write_text(
        "[quality]\nplan_compliance = 'warn'\n"
    )
    store.add_test(TestRun(
        workspace_id=ws.id, runner="vitest", scope="all", status=TestRunStatus.passed,
        total=3, passed=3, quality_blocked=False,  # warn mode never sets this
        plan_compliance=PlanComplianceResult(
            ran_at=_time.time(), compliant=False, confidence="high",
            summary="added a cache layer the task never asked for",
            gaps=[PlanGap(item="cache layer not in the task", why="not requested", cited="src/cache.ts:1")],
        ),
    ))
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verdict == "green"
    assert rcpt.quality.plan_compliance.blocking is True
    assert rcpt.quality.plan_compliance.enforced is False

    md = receipt_svc.render_markdown(rcpt)
    assert "GREEN" in md
    assert "BLOCKING" not in md
    assert "not enforced" in md


def test_verdict_is_red_for_a_blocking_finding_under_warn_mode(tmp_path, monkeypatch):
    # The regression review round 9 found: `TestRun.quality_blocked` only fires under
    # `[quality] enforce = "block"` — under "warn" it stays False even with a
    # blocking-severity finding on a changed line, but `ship_preflight` (integrate.py)
    # still refuses to merge ANY blocking finding regardless of enforce mode ("a leaked
    # credential must not merge just because the project set the dial to warn"). Reading
    # only `quality_blocked` reported this exact case as GREEN.
    from haro.models import QualityFindingRow, TestRun, TestRunStatus

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    (tmp_path / ".haro" / "settings.toml").write_text(
        "[quality]\nenabled = true\nenforce = 'warn'\n"
    )
    store.add_test(TestRun(
        workspace_id=ws.id, runner="vitest", scope="all", status=TestRunStatus.passed,
        total=3, passed=3, quality_measured=True, quality_blocked=False,  # warn never sets this
        quality_findings=[QualityFindingRow(tool="gitleaks", severity="high", blocking=True)],
        quality_note="1 gitleaks",
    ))
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verdict == "red"
    assert rcpt.quality.blocked is True
    assert rcpt.quality.blocking_count == 1

    md = receipt_svc.render_markdown(rcpt)
    assert "GREEN" not in md
    assert "Quality scan: 1 finding(s) (1 blocking)" in md


def test_verified_hunks_off_reports_not_available(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch, verified="false")
    _gate(store, hub, ws, project)
    settings_ = load_project_settings(project.path)

    rcpt = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings_))
    assert rcpt.verified_hunks.supported is False
    assert "off" in (rcpt.verified_hunks.note or "")


def test_receipt_endpoint_round_trips(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    monkeypatch.setattr(main, "store", store)

    resp = asyncio.run(main.get_receipt(ws.id))
    assert resp.receipt.verdict == "green"
    assert "GREEN" in resp.markdown


def test_pr_comment_endpoint_surfaces_git_panel_errors_as_400(tmp_path, monkeypatch):
    from fastapi import HTTPException

    from haro import git_panel

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    monkeypatch.setattr(main, "store", store)

    async def fake_comment_pr(*_a, **_k):
        from haro.git_ops import GitError
        raise GitError(["pr", "comment"], 1, "no open PR for 'feat' yet")

    monkeypatch.setattr(git_panel, "comment_pr", fake_comment_pr)

    with pytest.raises(HTTPException) as e:
        asyncio.run(main.post_receipt_pr_comment(ws.id))
    assert e.value.status_code == 400
    assert "no open PR" in e.value.detail


def test_pr_comment_endpoint_happy_path(tmp_path, monkeypatch):
    from haro import git_panel

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    monkeypatch.setattr(main, "store", store)

    seen = {}

    async def fake_comment_pr(worktree_path, branch, body):
        seen["body"] = body
        return {"posted": True, "url": "https://github.com/o/r/pull/1#issuecomment-1"}

    monkeypatch.setattr(git_panel, "comment_pr", fake_comment_pr)

    result = asyncio.run(main.post_receipt_pr_comment(ws.id))
    assert result == {"posted": True, "url": "https://github.com/o/r/pull/1#issuecomment-1"}
    assert "GREEN" in seen["body"]
