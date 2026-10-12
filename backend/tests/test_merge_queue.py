"""Conflict-aware merge queue: the greedy ordering engine (pure, with injected IO)
+ the real ``git merge-tree`` conflict check, plus the endpoint's **admission** rule —
which on a project that armed ``[trust] auto_action`` inherits the autonomy ladder
(backlog/autonomy-ladder.md §3)."""

import asyncio
import subprocess
import textwrap
from pathlib import Path

from haro import git_ops
from haro import main as main_mod
from haro.merge_queue import Candidate, preview_merge_queue, run_merge_queue
from haro.models import Project, TestRun, Workspace, WorkspaceStatus
from haro.store import Store


def _cands(*names):
    return [Candidate(id=n, name=n, branch=f"feat/{n}", base_ref="main") for n in names]


def test_all_clean_merge_in_order():
    merged = []

    async def conflict_check(base, branch):
        return []

    async def merge_one(c):
        merged.append(c.id)

    out = asyncio.run(run_merge_queue(_cands("a", "b", "c"), conflict_check=conflict_check, merge_one=merge_one))
    assert merged == ["a", "b", "c"]
    assert [m["id"] for m in out.merged] == ["a", "b", "c"]
    assert out.blocked == []


def test_conflicting_candidate_is_blocked_with_files():
    async def conflict_check(base, branch):
        return ["x.ts"] if branch == "feat/b" else []

    async def merge_one(c):
        pass

    out = asyncio.run(run_merge_queue(_cands("a", "b", "c"), conflict_check=conflict_check, merge_one=merge_one))
    assert {m["id"] for m in out.merged} == {"a", "c"}
    assert len(out.blocked) == 1
    assert out.blocked[0]["id"] == "b"
    assert out.blocked[0]["conflicts"] == ["x.ts"]


def test_order_dependent_conflict_defers_the_loser():
    # b merges cleanly until a lands; once a is merged, b conflicts → blocked.
    merged = []

    async def conflict_check(base, branch):
        if branch == "feat/b" and "a" in merged:
            return ["shared.ts"]
        return []

    async def merge_one(c):
        merged.append(c.id)

    out = asyncio.run(run_merge_queue(_cands("a", "b"), conflict_check=conflict_check, merge_one=merge_one))
    # a lands first (both clean initially, a scanned first); then b is re-checked and blocked
    assert merged == ["a"]
    assert [m["id"] for m in out.merged] == ["a"]
    assert [b["id"] for b in out.blocked] == ["b"]


def test_merge_failure_blocks_only_that_one():
    async def conflict_check(base, branch):
        return []

    async def merge_one(c):
        if c.id == "b":
            raise RuntimeError("branch protection")

    out = asyncio.run(run_merge_queue(_cands("a", "b", "c"), conflict_check=conflict_check, merge_one=merge_one))
    assert {m["id"] for m in out.merged} == {"a", "c"}
    assert out.blocked[0]["id"] == "b" and "branch protection" in out.blocked[0]["reason"]


def test_preview_reports_readiness_without_merging():
    async def conflict_check(base, branch):
        return ["c.ts"] if branch == "feat/b" else []

    out = asyncio.run(preview_merge_queue(_cands("a", "b"), conflict_check=conflict_check))
    assert [m["id"] for m in out.merged] == ["a"]      # "would merge"
    assert [b["id"] for b in out.blocked] == ["b"]


# ---- real git: merge_tree_conflicts ----
def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def test_merge_tree_conflicts_real_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("a\nb\nc\n")
    (repo / "g.txt").write_text("keep\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    # clean branch: edits a different file
    _run("checkout", "-b", "clean", cwd=repo)
    (repo / "g.txt").write_text("changed\n")
    _run("commit", "-am", "clean edit", cwd=repo)

    # conflicting branch: edits the same line main will also change
    _run("checkout", "main", cwd=repo)
    _run("checkout", "-b", "conflict", cwd=repo)
    (repo / "f.txt").write_text("a\nCONFLICT\nc\n")
    _run("commit", "-am", "conflict edit", cwd=repo)
    _run("checkout", "main", cwd=repo)
    (repo / "f.txt").write_text("a\nMAIN\nc\n")
    _run("commit", "-am", "main edit", cwd=repo)

    assert asyncio.run(git_ops.merge_tree_conflicts(repo, "main", "clean")) == []
    assert asyncio.run(git_ops.merge_tree_conflicts(repo, "main", "conflict")) == ["f.txt"]


# --------------------------------------------------------------------------- #
# Admission: the queue inherits the autonomy ladder
# --------------------------------------------------------------------------- #
# Green + committed + idle is the queue's original ticket. Once a project arms
# `[trust] auto_action`, admission additionally demands the *same* rung-complete bar
# `rungs.maybe_fire` clears — otherwise "merge all green" is a hole straight through
# the ladder. The git + integrate IO is stubbed; what's under test is the admission
# decision and the attribution it writes.
_LADDER_TOML = """
[gate]
merge_result = true

[workflow]
coverage_guard = "block"
flaky_rerun = true
tamper_alarm = "warn"

[trust]
enabled = true
streak_required = 2
auto_action = "auto_pr"
"""


#: `plan_markdown` handed to each stubbed integrate() call, in order.
_PLANS: list = []


def _arm_ladder(project_path: Path, *, auto_action: str = "auto_pr") -> None:
    haro = project_path / ".haro"
    haro.mkdir(parents=True, exist_ok=True)
    toml = textwrap.dedent(_LADDER_TOML).replace('"auto_pr"', f'"{auto_action}"')
    (haro / "settings.toml").write_text(toml)


def _green_ws(store: Store, project: Project, name: str) -> Workspace:
    ws = Workspace(
        project_id=project.id, name=name, branch=f"feat/{name}",
        worktree_path=str(Path(project.path) / name), base_ref="main",
        status=WorkspaceStatus.gate_green,
    )
    store.workspaces[ws.id] = ws
    return ws


def _clean_green_run(ws: Workspace, **kw) -> TestRun:
    """A run that meets every ladder condition: full scope, passed, no coverage
    regression, no flaky, no tamper findings."""
    base = dict(workspace_id=ws.id, project_id=ws.project_id, runner="vitest",
                scope="all", status="passed", coverage_delta=0.0)
    base.update(kw)
    return TestRun(**base)


def _stub_queue_io(monkeypatch, merged: list[str]) -> None:
    """Everything the endpoint touches outside the store: no repo, no remote, nothing
    dirty, nothing conflicting — so only the admission rule can change the outcome."""
    async def _false(*a, **k):
        return False

    async def _true(*a, **k):
        return True

    async def _no_conflicts(*a, **k):
        return []

    _PLANS.clear()

    async def _integrate(*, workspace, project, message, plan_markdown=None):
        merged.append(message)
        _PLANS.append(plan_markdown)
        return {"detail": "merged"}

    monkeypatch.setattr(main_mod.git_ops, "has_remote", _false)
    monkeypatch.setattr(main_mod.git_ops, "is_clean", _true)
    monkeypatch.setattr(main_mod.git_ops, "worktree_valid", lambda p: True)
    monkeypatch.setattr(main_mod.git_ops, "merge_tree_conflicts", _no_conflicts)
    monkeypatch.setattr(main_mod, "integrate", _integrate)

    # `merge_result = true` (which the ladder requires) turns the merge train on, so a
    # queue run re-gates each candidate. These tests are about admission, so the re-gate
    # is a green stub; the train's own behaviour is covered further down.
    async def _green_gate(*, workspace, **_k):
        workspace.status = WorkspaceStatus.gate_green
        return TestRun(workspace_id=workspace.id, runner="vitest", scope="all", status="passed")

    monkeypatch.setattr(main_mod, "run_gate", _green_gate)

    async def _save(*a, **k):
        return None

    monkeypatch.setattr(main_mod.db, "save_snapshot", _save)


def _setup(tmp_path, monkeypatch, *, arm: str | None) -> tuple[Store, Project, list[str]]:
    store = Store()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    if arm:
        _arm_ladder(tmp_path, auto_action=arm)
    merged: list[str] = []
    _stub_queue_io(monkeypatch, merged)
    monkeypatch.setattr(main_mod, "store", store)
    return store, project, merged


def _item(result, ws):
    return next(i for i in result.items if i.workspace_id == ws.id)


def test_unarmed_project_keeps_green_is_enough(tmp_path, monkeypatch):
    # No [trust] policy: a green workspace with no trust history at all still merges.
    # The ladder must never gate a project that didn't ask for it.
    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    ws = _green_ws(store, project, "a")

    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert _item(result, ws).outcome == "merged"
    assert len(merged) == 1
    assert "trust conditions met" not in merged[0]  # no ladder ⇒ no ladder attribution


def test_a_saved_manual_plan_rides_along_into_the_queue_merge(tmp_path, monkeypatch):
    from haro.models import ManualPlan, PlanStep

    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    a = _green_ws(store, project, "a")
    b = _green_ws(store, project, "b")
    a.plans = [
        ManualPlan(title="Wire it", steps=[PlanStep(text="read the handler")], saved=True),
        ManualPlan(title="Draft", steps=[PlanStep(text="unsaved step")]),
    ]

    asyncio.run(main_mod.run_merge_queue(project.id))
    with_plan = [p for p in _PLANS if p]
    assert len(merged) == 2 and len(with_plan) == 1
    assert "## Plan" in with_plan[0] and "read the handler" in with_plan[0]
    assert "unsaved step" not in with_plan[0]
    assert b.plans == []


def test_armed_project_admits_only_rung_complete_workspaces(tmp_path, monkeypatch):
    # `a` is rung-complete (2 clean greens = the required streak); `b` is merely green,
    # with a coverage regression and no streak of its own to stand on.
    store, project, merged = _setup(tmp_path, monkeypatch, arm="auto_pr")
    a = _green_ws(store, project, "a")
    b = _green_ws(store, project, "b")
    store.add_test(_clean_green_run(a))
    store.add_test(_clean_green_run(a))
    store.add_test(_clean_green_run(b, coverage_delta=-2.0))

    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert _item(result, a).outcome == "merged"
    skipped = _item(result, b)
    assert skipped.outcome == "skipped"
    assert "coverage" in skipped.reason and "merge by hand" in skipped.reason
    assert len(merged) == 1  # b was never handed to integrate()


def test_ladder_admitted_merge_cites_its_trust_report(tmp_path, monkeypatch):
    # A queue merge the ladder authorized is attributable exactly like a rung's: the
    # commit body carries the conditions, so `git log` reads the same either way.
    store, project, merged = _setup(tmp_path, monkeypatch, arm="auto_pr")
    a = _green_ws(store, project, "a")
    store.add_test(_clean_green_run(a))
    store.add_test(_clean_green_run(a))

    asyncio.run(main_mod.run_merge_queue(project.id))
    assert len(merged) == 1
    body = merged[0]
    assert body.startswith("haro: a")
    assert "Merge-queued by the haro autonomy ladder" in body
    assert "streak 2/2" in body
    assert "✓ no_tamper" in body


def test_dry_run_previews_under_the_ladder(tmp_path, monkeypatch):
    # The preview has to admit on the same rule, or "ready" lies about what would land.
    store, project, merged = _setup(tmp_path, monkeypatch, arm="auto_pr")
    a = _green_ws(store, project, "a")
    b = _green_ws(store, project, "b")
    store.add_test(_clean_green_run(a))
    store.add_test(_clean_green_run(a))
    store.add_test(_clean_green_run(b, scope="impacted"))

    result = asyncio.run(main_mod.run_merge_queue(project.id, dry=True))
    assert result.dry is True
    assert _item(result, a).outcome == "ready"
    assert _item(result, b).outcome == "skipped"
    assert "full_scope" in _item(result, b).reason
    assert merged == []  # a dry run lands nothing


def test_hard_precondition_holds_the_queue_too(tmp_path, monkeypatch):
    # Anti-Goodhart: with the alarm off, auto_pr can't arm — and so the queue can't
    # batch-land either, even though the workspace is green with a full streak.
    store, project, merged = _setup(tmp_path, monkeypatch, arm="auto_pr")
    (tmp_path / ".haro" / "settings.toml").write_text(
        textwrap.dedent(_LADDER_TOML).replace('tamper_alarm = "warn"', 'tamper_alarm = "off"')
    )
    a = _green_ws(store, project, "a")
    store.add_test(_clean_green_run(a))
    store.add_test(_clean_green_run(a))

    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert _item(result, a).outcome == "skipped"
    assert "tamper" in _item(result, a).reason
    assert merged == []


# --------------------------------------------------------------------------- #
# Merge train: each candidate is gated on (advanced base + candidate) before landing
# --------------------------------------------------------------------------- #
from haro.merge_queue import GateVerdict  # noqa: E402


def test_train_gates_each_candidate_after_the_previous_landed():
    landed: list[str] = []
    seen_landed_at_gate: dict[str, list[str]] = {}

    async def conflict_check(base, branch):
        return []

    async def merge_one(c):
        landed.append(c.id)

    async def gate_check(c):
        seen_landed_at_gate[c.id] = list(landed)  # what the base held when c was gated
        return GateVerdict(green=True)

    out = asyncio.run(run_merge_queue(_cands("a", "b", "c"), conflict_check=conflict_check,
                                      merge_one=merge_one, gate_check=gate_check))
    assert landed == ["a", "b", "c"]
    assert seen_landed_at_gate == {"a": [], "b": ["a"], "c": ["a", "b"]}
    assert [m["gate"] for m in out.merged] == ["green", "green", "green"]


def test_train_red_on_merged_base_is_blocked_and_the_queue_continues():
    landed: list[str] = []

    async def conflict_check(base, branch):
        return []

    async def merge_one(c):
        landed.append(c.id)

    async def gate_check(c):
        return GateVerdict(green=False, detail="2 failing test(s)") if c.id == "b" else GateVerdict(green=True)

    out = asyncio.run(run_merge_queue(_cands("a", "b", "c"), conflict_check=conflict_check,
                                      merge_one=merge_one, gate_check=gate_check))
    assert landed == ["a", "c"]  # b never reached merge_one, c still landed
    (blocked,) = out.blocked
    assert blocked["id"] == "b" and blocked["gate"] == "red"
    assert blocked["reason"].startswith("red on merged base")
    assert "2 failing" in blocked["reason"]


def test_train_a_gate_that_cannot_run_blocks_rather_than_lands():
    landed: list[str] = []

    async def conflict_check(base, branch):
        return []

    async def merge_one(c):
        landed.append(c.id)

    async def gate_check(c):
        raise RuntimeError("runner exploded")

    out = asyncio.run(run_merge_queue(_cands("a"), conflict_check=conflict_check,
                                      merge_one=merge_one, gate_check=gate_check))
    assert landed == []
    assert out.blocked[0]["gate"] == "error" and "runner exploded" in out.blocked[0]["reason"]


def test_train_conflicting_candidate_is_never_gated():
    gated: list[str] = []

    async def conflict_check(base, branch):
        return ["x.ts"] if branch == "feat/b" else []

    async def merge_one(c):
        pass

    async def gate_check(c):
        gated.append(c.id)
        return GateVerdict(green=True)

    asyncio.run(run_merge_queue(_cands("a", "b"), conflict_check=conflict_check,
                                merge_one=merge_one, gate_check=gate_check))
    assert gated == ["a"]  # a full suite is not spent on a candidate that can't merge


def test_no_gate_check_keeps_the_original_shape():
    async def conflict_check(base, branch):
        return []

    async def merge_one(c):
        pass

    out = asyncio.run(run_merge_queue(_cands("a"), conflict_check=conflict_check, merge_one=merge_one))
    assert out.merged == [{"id": "a", "name": "a"}]  # no "gate" key: backward compatible


def test_train_with_real_repo_catches_two_branches_that_are_only_bad_together(tmp_path):
    """Each branch merges cleanly and is fine alone; together they violate a rule the
    'suite' checks (a.txt and b.txt must not coexist). Only the first one lands."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "base.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    for name in ("a", "b"):
        _run("checkout", "-b", f"feat/{name}", "main", cwd=repo)
        (repo / f"{name}.txt").write_text(name)
        _run("add", "-A", cwd=repo)
        _run("commit", "-m", name, cwd=repo)
    _run("checkout", "main", cwd=repo)

    async def conflict_check(base, branch):
        return await git_ops.merge_tree_conflicts(repo, base, branch)

    async def merge_one(c):
        _run("merge", "--no-ff", "-m", f"merge {c.id}", c.branch, cwd=repo)

    n = 0

    async def gate_check(c):
        nonlocal n
        n += 1
        dest = tmp_path / f"merged{n}"
        conflicts = await git_ops.create_merge_worktree(repo, "main", c.branch, dest)
        try:
            assert conflicts == []
            both = (dest / "a.txt").exists() and (dest / "b.txt").exists()
            return GateVerdict(green=not both, detail="a and b together")
        finally:
            await git_ops.remove_worktree(repo, dest)

    out = asyncio.run(run_merge_queue(_cands("a", "b"), conflict_check=conflict_check,
                                      merge_one=merge_one, gate_check=gate_check))
    assert [m["id"] for m in out.merged] == ["a"]
    assert out.blocked[0]["id"] == "b" and out.blocked[0]["reason"].startswith("red on merged base")
    tracked = subprocess.run(["git", "ls-files"], cwd=repo, capture_output=True, text=True).stdout.split()
    assert "a.txt" in tracked and "b.txt" not in tracked  # main never received the red one


def _fake_run_gate(calls):
    async def fake_run_gate(*, store, hub, adapter, workspace, project_path, trigger, settings, **_k):
        calls.append(workspace.name)
        red = workspace.name == "b"
        run = TestRun(workspace_id=workspace.id, project_id=workspace.project_id, runner="vitest",
                      scope="all", status="failed" if red else "passed", failed=1 if red else 0)
        workspace.status = WorkspaceStatus.gate_red if red else WorkspaceStatus.gate_green
        store.add_test(run)
        return run

    return fake_run_gate


def test_endpoint_runs_the_train_when_merge_result_is_on(tmp_path, monkeypatch):
    calls: list[str] = []
    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    (tmp_path / ".haro").mkdir(exist_ok=True)
    (tmp_path / ".haro" / "settings.toml").write_text("[gate]\nmerge_result = true\n")
    monkeypatch.setattr(main_mod, "run_gate", _fake_run_gate(calls))
    a, b = _green_ws(store, project, "a"), _green_ws(store, project, "b")

    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert result.train is True
    assert _item(result, a).outcome == "merged" and _item(result, a).gate == "green"
    blocked = _item(result, b)
    assert blocked.outcome == "blocked" and blocked.gate == "red"
    assert blocked.reason.startswith("red on merged base")
    assert len(merged) == 1


def test_endpoint_without_merge_result_has_no_train(tmp_path, monkeypatch):
    calls: list[str] = []
    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    monkeypatch.setattr(main_mod, "run_gate", _fake_run_gate(calls))
    _green_ws(store, project, "a")
    _green_ws(store, project, "b")

    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert result.train is False and calls == []
    assert all(i.gate is None for i in result.items) and len(merged) == 2


def test_train_gate_is_a_registered_task_and_a_busy_candidate_is_blocked(tmp_path, monkeypatch):
    seen: dict[str, str | None] = {}
    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    (tmp_path / ".haro").mkdir(exist_ok=True)
    (tmp_path / ".haro" / "settings.toml").write_text("[gate]\nmerge_result = true\n")
    a, b = _green_ws(store, project, "a"), _green_ws(store, project, "b")

    async def fake_run_gate(*, store, workspace, **_k):
        seen[workspace.name] = store.busy_reason(workspace.id)  # what a POST /tests would see
        workspace.status = WorkspaceStatus.gate_green
        store.gate_tasks.pop(workspace.id, None)
        return TestRun(workspace_id=workspace.id, runner="vitest", scope="all", status="passed")

    monkeypatch.setattr(main_mod, "run_gate", fake_run_gate)

    class _Live:  # another gate already in flight on b
        def done(self):
            return False

    store.gate_tasks[b.id] = _Live()
    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert seen["a"] == "the gate"
    assert "b" not in seen  # never started a second gate
    blocked = _item(result, b)
    # b was busy at admission, so it is skipped before the train even sees it
    assert blocked.outcome == "skipped"
    assert _item(result, a).outcome == "merged"


def test_train_blocks_a_candidate_that_became_busy_after_admission(tmp_path, monkeypatch):
    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    (tmp_path / ".haro").mkdir(exist_ok=True)
    (tmp_path / ".haro" / "settings.toml").write_text("[gate]\nmerge_result = true\n")
    a, b = _green_ws(store, project, "a"), _green_ws(store, project, "b")

    class _Live:
        def done(self):
            return False

    async def fake_run_gate(*, store, workspace, **_k):
        if workspace.name == "a":
            store.gate_tasks[b.id] = _Live()  # a POST /tests lands on b mid-queue
        workspace.status = WorkspaceStatus.gate_green
        return TestRun(workspace_id=workspace.id, runner="vitest", scope="all", status="passed")

    monkeypatch.setattr(main_mod, "run_gate", fake_run_gate)
    result = asyncio.run(main_mod.run_merge_queue(project.id))
    assert _item(result, a).outcome == "merged"
    blocked = _item(result, b)
    assert blocked.outcome == "blocked" and blocked.gate == "error"
    assert "gate already running" in blocked.reason


def test_train_blocks_when_the_remote_fetch_fails(tmp_path, monkeypatch):
    store, project, merged = _setup(tmp_path, monkeypatch, arm=None)
    (tmp_path / ".haro").mkdir(exist_ok=True)
    (tmp_path / ".haro" / "settings.toml").write_text("[gate]\nmerge_result = true\n[workflow]\nmerge_mode = 'merge'\n")

    async def has_remote(*a, **k):
        return True

    async def bad_fetch(*a, **k):
        raise git_ops.GitError(["fetch"], 1, "no network")

    async def boom_gate(**_k):
        raise AssertionError("must not gate against a stale base")

    monkeypatch.setattr(main_mod.git_ops, "has_remote", has_remote)
    monkeypatch.setattr(main_mod.git_ops, "fetch", bad_fetch)
    monkeypatch.setattr(main_mod, "run_gate", boom_gate)
    a = _green_ws(store, project, "a")
    result = asyncio.run(main_mod.run_merge_queue(project.id))
    item = _item(result, a)
    assert item.outcome == "blocked" and "stale" in item.reason and "fetch failed" in item.reason
    assert merged == []
