"""Test-first tasks (backlog/test-first.md): draft -> prove red -> approve -> build -> gate.

Everything runs against a real temp git repo and a trivial file-driven runner: a test file
holds lines ``case NAME expects TOKEN`` and a case passes when TOKEN appears in ``impl.txt``.
Writing TOKEN into ``impl.txt`` is therefore "building the feature". The agent is mocked;
no real claude run happens here.
"""

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import acceptance, analytics, main
from haro.adapters.test_runner.base import CaseResult, TestResult as RunResult, TestRunnerAdapter
from haro.config import ProjectSettings
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import (
    AgentRun,
    AgentRunStatus,
    ApproveTestFirstRequest,
    Project,
    StartAgentRequest,
    Workspace,
    WorkspaceStatus,
)
from haro.models import TestFirstState as FirstState
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


class FileRunner(TestRunnerAdapter):
    name = "vitest"

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        root = Path(cwd)
        wanted = {f for f, _ in only} if only else None
        impl = (root / "impl.txt").read_text() if (root / "impl.txt").exists() else ""
        cases = []
        for p in sorted(root.rglob("test_*.py")):
            rel = p.relative_to(root).as_posix()
            if wanted is not None and rel not in wanted:
                continue
            for line in p.read_text().splitlines():
                if line.startswith("case "):
                    name, _, token = line[5:].partition(" expects ")
                    ok = token.strip() in impl
                    cases.append(CaseResult(
                        file=rel, name=name.strip(), status="passed" if ok else "failed",
                        message=None if ok else f"expected {token.strip()} in impl",
                    ))
        if not cases:
            return RunResult(ok=False, error="no tests found")
        failed = sum(1 for c in cases if c.status == "failed")
        return RunResult(
            ok=failed == 0, total=len(cases), passed=len(cases) - failed, failed=failed, cases=cases
        )


def _git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def _repo(tmp_path):
    repo = tmp_path / "repo"
    (repo / "tests").mkdir(parents=True)
    (repo / "impl.txt").write_text("base\n")
    (repo / "tests" / "test_old.py").write_text("case old expects base\n")
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "init")
    return repo


def _world(tmp_path):
    repo = _repo(tmp_path)
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat", worktree_path=str(repo), base_ref="main"
    )
    ws.test_first = FirstState(phase="drafting", task="add a feature")
    store.workspaces[ws.id] = ws
    return store, hub, ws, repo


def _prove(hub, ws):
    asyncio.run(acceptance.finish_draft(hub=hub, workspace=ws, adapter=FileRunner()))
    return ws.test_first


def _draft(repo, body="case adds feature expects feature\n", name="test_acc.py"):
    (repo / "tests" / name).write_text(body)


def test_prove_red_accepts_a_test_that_fails_on_base(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo)
    tf = _prove(hub, ws)
    assert tf.phase == "review"
    assert [(c.name, c.message) for c in tf.cases] == [("adds feature", "expected feature in impl")]
    assert [f.path for f in tf.files] == ["tests/test_acc.py"]
    assert tf.files[0].sha256 == acceptance.sha256_of(repo, "tests/test_acc.py")
    assert ws.status == WorkspaceStatus.idle


def test_prove_red_rejects_a_test_that_already_passes(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo, "case trivially true expects base\ncase real expects feature\n")
    tf = _prove(hub, ws)
    assert tf.phase == "rejected"
    assert "already pass on base" in tf.reject_reason and "trivially true" in tf.reject_reason
    assert tf.files == [] and tf.cases == []


def test_prove_red_rejects_zero_collected_tests(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo, "# nothing here\n")
    tf = _prove(hub, ws)
    assert tf.phase == "rejected"
    assert "No test case was collected from tests/test_acc.py" in tf.reject_reason
    assert "move that import inside the test body" in tf.reject_reason


def test_prove_red_rejects_when_no_test_file_was_added(tmp_path):
    _store, hub, ws, _repo_ = _world(tmp_path)
    tf = _prove(hub, ws)
    assert tf.phase == "rejected" and "no test file" in tf.reject_reason


def test_phase_a_source_edit_is_rejected_after_the_run(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo)
    (repo / "impl.txt").write_text("base\nfeature\n")
    tf = _prove(hub, ws)
    assert tf.phase == "rejected"
    assert "impl.txt" in tf.reject_reason and "only add a test" in tf.reject_reason


def test_phase_a_editing_an_existing_test_file_is_rejected(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo)
    (repo / "tests" / "test_old.py").write_text("case old expects nothing\n")
    tf = _prove(hub, ws)
    assert tf.phase == "rejected" and "NEW file" in tf.reject_reason


def test_prove_engine_crash_is_a_rejection_never_a_pass(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo)

    class Boom(FileRunner):
        async def run(self, **kw):
            raise RuntimeError("runner exploded")

    asyncio.run(acceptance.finish_draft(hub=hub, workspace=ws, adapter=Boom()))
    assert ws.test_first.phase == "rejected" and "runner exploded" in ws.test_first.reject_reason


def test_draft_deny_rules_cover_tracked_non_test_files_only(tmp_path):
    rules = acceptance.draft_deny_patterns(["src/a.py", "tests/test_a.py", "web/x.test.ts", "README.md"])
    assert rules == ["/README.md", "/src/a.py"]
    assert acceptance.draft_deny_patterns([f"f{i}.py" for i in range(1001)]) == []


def test_status_event_carries_the_state(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo)
    _prove(hub, ws)
    payload = acceptance._publish_payload(ws)
    assert payload["status"] == "idle" and payload["test_first"]["phase"] == "review"


# ---- the gate ------------------------------------------------------------------------


def _approved(tmp_path, monkeypatch, tamper_alarm="off"):
    store, hub, ws, repo = _world(tmp_path)
    _draft(repo)
    tf = _prove(hub, ws)
    assert tf.phase == "review"
    tf.phase, tf.approved_at = "approved", 1_700_000_000.0

    async def inventories(*_a, **_k):
        return [], []

    monkeypatch.setattr(analytics, "test_inventories", inventories)
    settings = ProjectSettings()
    settings.tamper_alarm = tamper_alarm
    settings.gate_merge_result = False
    return store, hub, ws, repo, settings


def _gate(store, hub, ws, repo, settings):
    return asyncio.run(run_gate(
        store=store, hub=hub, adapter=FileRunner(), workspace=ws,
        project_path=str(repo), settings=settings,
    ))


def test_happy_path_is_green_with_the_receipt_line(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    (repo / "impl.txt").write_text("base\nfeature\n")
    test = _gate(store, hub, ws, repo, settings)
    assert test.status == RunStatus.passed and ws.status == WorkspaceStatus.gate_green
    assert test.acceptance.ok and (test.acceptance.passing, test.acceptance.total) == (1, 1)
    line = acceptance.receipt_line(test.acceptance)
    assert line.startswith("Acceptance test (approved ") and line.endswith("1/1 passing, unchanged.")
    assert test.acceptance_blocked is False


def test_gate_is_red_while_the_acceptance_test_still_fails(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    test = _gate(store, hub, ws, repo, settings)
    assert ws.status == WorkspaceStatus.gate_red
    assert test.acceptance.failing == ["adds feature"]


@pytest.mark.parametrize("alarm", ["off", "warn", "block"])
def test_changed_acceptance_file_blocks_whatever_the_tamper_mode(tmp_path, monkeypatch, alarm):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch, tamper_alarm=alarm)
    (repo / "impl.txt").write_text("base\nfeature\n")
    # Weakening the contract: the test now expects something already true, and still "passes".
    (repo / "tests" / "test_acc.py").write_text("case adds feature expects base\n")
    test = _gate(store, hub, ws, repo, settings)
    assert test.status == RunStatus.passed
    assert ws.status == WorkspaceStatus.gate_red
    assert test.acceptance_blocked is True
    assert test.acceptance.changed == ["tests/test_acc.py"]
    assert "acceptance_changed" in [f.kind for f in test.tamper_findings]
    assert "acceptance test changed after approval" in test.tamper_note


def test_missing_or_renamed_acceptance_test_blocks(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    (repo / "impl.txt").write_text("base\nfeature\n")
    (repo / "tests" / "test_acc.py").unlink()
    test = _gate(store, hub, ws, repo, settings)
    assert ws.status == WorkspaceStatus.gate_red and test.acceptance_blocked
    assert test.acceptance.missing == ["adds feature"]
    assert "acceptance_missing" in [f.kind for f in test.tamper_findings]


def test_a_flaky_excused_acceptance_failure_still_blocks(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    tf = ws.test_first
    cases = [CaseResult(file="tests/test_acc.py", name="adds feature", status="passed")]
    check = acceptance.check_acceptance(tf, str(repo), cases, excused={"adds feature"})
    assert check.failing == ["adds feature"] and not check.ok


def test_a_workspace_without_test_first_is_untouched(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    ws.test_first = None
    (repo / "impl.txt").write_text("base\nfeature\n")
    test = _gate(store, hub, ws, repo, settings)
    assert test.acceptance is None and ws.status == WorkspaceStatus.gate_green


# ---- start_agent / approve wiring -----------------------------------------------------


def _wire(tmp_path, monkeypatch):
    store, hub, ws, repo = _world(tmp_path)
    ws.test_first = None
    seen: list[dict] = []

    async def fake_run_agent(**kw):
        seen.append(kw)

    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "hub", hub)
    monkeypatch.setattr(main, "run_agent", fake_run_agent)
    return store, ws, repo, seen


def _start(ws, seen, **kw):
    async def go():
        run = await main.start_agent(ws.id, StartAgentRequest(**kw))
        await asyncio.sleep(0)
        return run

    return asyncio.run(go())


def test_start_test_first_sets_draft_mode_deny_rules_and_no_auto_gate(tmp_path, monkeypatch):
    _store, ws, _repo_, seen = _wire(tmp_path, monkeypatch)
    _start(ws, seen, task="add a feature", test_first=True)
    kw = seen[0]
    assert ws.test_first.phase == "drafting" and ws.test_first.task == "add a feature"
    assert kw["test_first_phase"] == "draft" and kw["auto_gate"] is False
    assert "/impl.txt" in kw["deny_edit_paths"] and "/tests/test_old.py" not in kw["deny_edit_paths"]
    assert "PHASE A" in kw["instructions"]


def test_test_first_refuses_a_workspace_that_already_has_changes(tmp_path, monkeypatch):
    from fastapi import HTTPException

    _store, ws, repo, seen = _wire(tmp_path, monkeypatch)
    (repo / "impl.txt").write_text("changed\n")
    with pytest.raises(HTTPException) as e:
        _start(ws, seen, task="t", test_first=True)
    assert e.value.status_code == 409


def test_build_run_is_refused_until_the_test_is_approved(tmp_path, monkeypatch):
    from fastapi import HTTPException

    _store, ws, _repo_, seen = _wire(tmp_path, monkeypatch)
    ws.test_first = FirstState(phase="review", task="t")
    with pytest.raises(HTTPException) as e:
        _start(ws, seen, task="just build it")
    assert e.value.status_code == 409 and "approve" in e.value.detail


def test_redraft_reuses_the_state_and_folds_feedback_into_the_prompt(tmp_path, monkeypatch):
    _store, ws, _repo_, seen = _wire(tmp_path, monkeypatch)
    ws.test_first = FirstState(phase="rejected", task="add a feature", reject_reason="x")
    run = _start(ws, seen, task="assert on the error message too", test_first=True)
    assert ws.test_first.phase == "drafting" and ws.test_first.rounds == 2
    assert ws.test_first.reject_reason is None
    assert "add a feature" in run.task and "assert on the error message too" in run.task


def test_approve_stores_state_and_starts_a_protected_build_run(tmp_path, monkeypatch):
    store, ws, repo, seen = _wire(tmp_path, monkeypatch)
    _draft(repo)
    ws.test_first = FirstState(phase="drafting", task="add a feature")
    asyncio.run(acceptance.finish_draft(hub=Hub(), workspace=ws, adapter=FileRunner()))
    assert ws.test_first.phase == "review"

    async def go():
        run = await main.approve_test_first(ws.id, ApproveTestFirstRequest(model="sonnet"))
        await asyncio.sleep(0)
        return run

    run = asyncio.run(go())
    assert ws.test_first.phase == "approved" and ws.test_first.approved_at
    kw = seen[0]
    assert kw["test_first_phase"] is None and kw["auto_gate"] is True
    assert "/tests/test_acc.py" in kw["deny_edit_paths"]
    assert "Do NOT modify these files: tests/test_acc.py" in kw["instructions"]
    assert run.model == "sonnet"


def test_approve_refuses_a_file_changed_after_the_proof(tmp_path, monkeypatch):
    from fastapi import HTTPException

    _store, ws, repo, _seen = _wire(tmp_path, monkeypatch)
    _draft(repo)
    ws.test_first = FirstState(phase="drafting", task="t")
    asyncio.run(acceptance.finish_draft(hub=Hub(), workspace=ws, adapter=FileRunner()))
    (repo / "tests" / "test_acc.py").write_text("case adds feature expects base\n")
    with pytest.raises(HTTPException) as e:
        asyncio.run(main.approve_test_first(ws.id))
    assert e.value.status_code == 409 and "changed after it was proven red" in e.value.detail
    assert ws.test_first.phase == "review"


def test_approve_refuses_when_nothing_is_waiting(tmp_path, monkeypatch):
    from fastapi import HTTPException

    _store, ws, _repo_, _seen = _wire(tmp_path, monkeypatch)
    ws.test_first = FirstState(phase="rejected", task="t")
    with pytest.raises(HTTPException):
        asyncio.run(main.approve_test_first(ws.id))


def test_vitest_only_args_accepts_whole_file_entries():
    from haro.adapters.test_runner.vitest import only_args

    assert only_args([("b.test.ts", ""), ("a.test.ts", "")]) == ["a.test.ts", "b.test.ts"]
    assert only_args([("a.test.ts", "adds")]) == ["a.test.ts", "-t", "^adds$"]


# ---- runner handoff -------------------------------------------------------------------


class _ScriptedAgent:
    name = "claude-code"

    def __init__(self, action):
        self.action = action

    async def run(self, *, task, cwd, **kw):
        from haro.models import AgentEvent  # noqa: F401
        from haro.adapters.base import NormalizedEvent

        self.action(Path(cwd))
        yield NormalizedEvent("done", {"result": "ok"})


def test_runner_proves_the_draft_instead_of_gating(tmp_path):
    from haro.runner import run_agent

    store, hub, ws, repo = _world(tmp_path)
    ws.test_first = FirstState(phase="drafting", task="t")
    run = AgentRun(workspace_id=ws.id, adapter="claude-code", task="t")
    store.add_run(run)

    def write(root):
        (root / "tests" / "test_acc.py").write_text("case adds feature expects feature\n")

    asyncio.run(run_agent(
        store=store, hub=hub, adapter=_ScriptedAgent(write), workspace=ws, run=run,
        test_adapter=FileRunner(), project_path=str(repo), auto_gate=False,
        test_first_phase="draft",
    ))
    assert run.status == AgentRunStatus.done
    assert ws.test_first.phase == "review"
    assert store.latest_test(ws.id) is None  # no gate ran on a draft


def test_a_failed_drafting_run_is_rejected_not_proven(tmp_path):
    from haro.runner import run_agent

    store, hub, ws, repo = _world(tmp_path)
    run = AgentRun(workspace_id=ws.id, adapter="claude-code", task="t")
    store.add_run(run)

    class Broken(_ScriptedAgent):
        async def run(self, **kw):
            from haro.adapters.base import NormalizedEvent

            yield NormalizedEvent("error", {"message": "boom"})

    asyncio.run(run_agent(
        store=store, hub=hub, adapter=Broken(None), workspace=ws, run=run,
        test_adapter=FileRunner(), project_path=str(repo), test_first_phase="draft",
    ))
    assert ws.test_first.phase == "rejected" and "error" in ws.test_first.reject_reason


def test_boot_reconcile_rejects_an_interrupted_draft(tmp_path):
    from haro import db

    store, _hub, ws, _repo_ = _world(tmp_path)
    ws.test_first.phase = "proving"
    db.reconcile(store)
    assert ws.test_first.phase == "rejected" and "restarted" in ws.test_first.reject_reason


def test_failed_scope_rerun_cannot_bypass_a_changed_acceptance_file(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch, tamper_alarm="block")
    first = _gate(store, hub, ws, repo, settings)
    assert ws.status == WorkspaceStatus.gate_red
    (repo / "tests" / "test_acc.py").write_text("case adds feature expects base\n")
    only = [(c.file, c.name) for c in first.cases if c.status == "failed"]
    second = asyncio.run(run_gate(
        store=store, hub=hub, adapter=FileRunner(), workspace=ws,
        project_path=str(repo), settings=settings, only=only,
    ))
    assert second.status == RunStatus.passed
    assert ws.status == WorkspaceStatus.gate_red and second.acceptance_blocked
    assert second.acceptance.changed == ["tests/test_acc.py"]


def test_partial_run_without_the_approved_cases_says_to_run_the_full_gate(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    (repo / "impl.txt").write_text("base\nfeature\n")
    test = asyncio.run(run_gate(
        store=store, hub=hub, adapter=FileRunner(), workspace=ws, project_path=str(repo),
        settings=settings, only=[("tests/test_old.py", "")],
    ))
    assert ws.status == WorkspaceStatus.gate_red and test.acceptance_blocked
    assert "run the full gate" in test.tamper_note
    assert test.tamper_findings == []


def test_partial_run_that_includes_the_intact_contract_can_be_green(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    (repo / "impl.txt").write_text("base\nfeature\n")
    test = asyncio.run(run_gate(
        store=store, hub=hub, adapter=FileRunner(), workspace=ws, project_path=str(repo),
        settings=settings, only=[("tests/test_acc.py", "")],
    ))
    assert test.acceptance.ok and ws.status == WorkspaceStatus.gate_green


def test_partial_run_cannot_wash_a_tamper_block(tmp_path, monkeypatch):
    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch, tamper_alarm="block")
    ws.test_first = None
    (repo / "impl.txt").write_text("base\nfeature\n")
    from haro.adapters.test_runner.base import TestRef as Ref

    async def inv(*_a, **_k):
        return [Ref(file="tests/test_old.py", name="old")], []

    monkeypatch.setattr(analytics, "test_inventories", inv)
    test = asyncio.run(run_gate(
        store=store, hub=hub, adapter=FileRunner(), workspace=ws, project_path=str(repo),
        settings=settings, only=[("tests/test_acc.py", "")],
    ))
    assert test.tamper_blocked and ws.status == WorkspaceStatus.gate_red


def test_missing_module_at_the_top_of_the_file_is_named_explicitly(tmp_path):
    from haro.adapters.test_runner.base import TestResult as RunResult

    reason = acceptance.judge_red(
        [("tests/test_acc.py", "tests/test_acc.py")],
        RunResult(ok=False, error="ModuleNotFoundError: No module named 'shipping'"),
    )[1]
    assert "move that import inside the test body" in reason
    assert "missing module" in reason and "shipping" in reason


# ---- concurrency, escape hatch, merge train ---------------------------------------------


def _live_task(store, ws, session):
    async def sleeper():
        await asyncio.sleep(5)

    async def go():
        t = asyncio.create_task(sleeper())
        store.set_active_task(ws.id, session, t)
        return t

    return go


def test_approve_and_redraft_refuse_while_any_session_is_active(tmp_path, monkeypatch):
    from fastapi import HTTPException

    store, ws, repo, seen = _wire(tmp_path, monkeypatch)
    _draft(repo)
    ws.test_first = FirstState(phase="drafting", task="t")
    asyncio.run(acceptance.finish_draft(hub=Hub(), workspace=ws, adapter=FileRunner()))

    async def go(fn):
        t = await _live_task(store, ws, "side")()
        try:
            await fn()
        finally:
            t.cancel()

    with pytest.raises(HTTPException) as e:
        asyncio.run(go(lambda: main.approve_test_first(ws.id)))
    assert e.value.status_code == 409 and ws.test_first.phase == "review"

    async def redraft():
        await main.start_agent(ws.id, StartAgentRequest(task="x", test_first=True))

    with pytest.raises(HTTPException) as e:
        asyncio.run(go(redraft))
    assert e.value.status_code == 409


def test_a_stale_draft_run_cannot_overwrite_an_approval(tmp_path):
    _store, hub, ws, repo = _world(tmp_path)
    _draft(repo)
    ws.test_first.gen = 1
    ws.test_first.phase = "approved"
    asyncio.run(acceptance.finish_draft(hub=hub, workspace=ws, adapter=FileRunner(), gen=1))
    assert ws.test_first.phase == "approved"
    ws.test_first.phase = "drafting"
    ws.test_first.gen = 2
    asyncio.run(acceptance.finish_draft(hub=hub, workspace=ws, adapter=FileRunner(), gen=1))
    assert ws.test_first.phase == "drafting"
    acceptance.interrupted(ws, "old run stopped", gen=1)
    assert ws.test_first.phase == "drafting"


def test_redraft_bumps_the_generation(tmp_path, monkeypatch):
    _store, ws, _repo_, seen = _wire(tmp_path, monkeypatch)
    _start(ws, seen, task="t", test_first=True)
    assert ws.test_first.gen == 1 and seen[0]["test_first_gen"] == 1
    ws.test_first.phase = "rejected"
    _start(ws, seen, task="again", test_first=True)
    assert ws.test_first.gen == 2 and seen[1]["test_first_gen"] == 2


def test_cancel_clears_a_draft_and_needs_confirm_after_approval(tmp_path, monkeypatch):
    from fastapi import HTTPException

    from haro.models import CancelTestFirstRequest

    _store, ws, _repo_, _seen = _wire(tmp_path, monkeypatch)
    ws.test_first = FirstState(phase="review", task="t")
    asyncio.run(main.cancel_test_first(ws.id))
    assert ws.test_first is None
    with pytest.raises(HTTPException):
        asyncio.run(main.cancel_test_first(ws.id))
    ws.test_first = FirstState(phase="approved", task="t")
    with pytest.raises(HTTPException) as e:
        asyncio.run(main.cancel_test_first(ws.id))
    assert e.value.status_code == 409 and ws.test_first is not None
    asyncio.run(main.cancel_test_first(ws.id, CancelTestFirstRequest(confirm=True)))
    assert ws.test_first is None


def test_after_cancel_the_receipt_stops_mentioning_acceptance(tmp_path, monkeypatch):
    from haro import receipt as receipt_svc

    store, hub, ws, repo, settings = _approved(tmp_path, monkeypatch)
    (repo / "impl.txt").write_text("base\nfeature\n")
    _gate(store, hub, ws, repo, settings)
    rc = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))
    assert rc.acceptance is not None
    ws.test_first = None
    rc = asyncio.run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))
    assert rc.acceptance is None
    assert "Acceptance test" not in receipt_svc.render_markdown(rc)


def test_merge_train_reason_names_the_acceptance_block():
    from haro.models import TestRun as Run

    run = Run(workspace_id="w", runner="x", status=RunStatus.passed, acceptance_blocked=True)
    assert main.gate_block_detail(run) == "acceptance test not intact"
    failed = Run(workspace_id="w", runner="x", status=RunStatus.failed, failed=2)
    assert main.gate_block_detail(failed) == "2 failing test(s)"
    assert main.gate_block_detail(Run(workspace_id="w", runner="x", status=RunStatus.passed)) == "gate is not green"
