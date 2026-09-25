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

# The Double Gate joined the conjunction (backlog/double-gate.md §1), so a fixture whose
# point is "every prerequisite is ON" has to arm it here too — otherwise every workspace
# is skipped for an unmet `quality` row and the admission rule under test never runs.
[quality]
enabled = true

[trust]
enabled = true
streak_required = 2
auto_action = "auto_pr"
"""


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
    regression, no flaky, no tamper findings, quality-clean."""
    base = dict(workspace_id=ws.id, project_id=ws.project_id, runner="vitest",
                scope="all", status="passed", coverage_delta=0.0,
                # [] = measured clean. The default None reads as "nobody looked" and
                # leaves the Double Gate's rung unmet (backlog/double-gate.md §1).
                # quality_measured=True pairs with it: `findings == []` alone is also
                # what every-scanner-unavailable produces (trust.py's `quality_measured`
                # check), so a genuinely clean measured run has to say so on both fields.
                quality_findings=[], quality_measured=True)
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

    async def _integrate(*, workspace, project, message):
        merged.append(message)
        return {"detail": "merged"}

    monkeypatch.setattr(main_mod.git_ops, "has_remote", _false)
    monkeypatch.setattr(main_mod.git_ops, "is_clean", _true)
    monkeypatch.setattr(main_mod.git_ops, "worktree_valid", lambda p: True)
    monkeypatch.setattr(main_mod.git_ops, "merge_tree_conflicts", _no_conflicts)
    monkeypatch.setattr(main_mod, "integrate", _integrate)

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
