"""Route-level tests for the Merge Firewall verdict oracle,
``GET /firewall/verdict?repo=<abs-path>&branch=<name>`` (backlog/merge-firewall.md §3).

This is the substrate the repo-level git hook curls to decide whether a push/merge
may proceed. It's a pure read off the reconciled store — project matched by path,
workspace by branch — so these tests drive the async handler directly with
``asyncio.run`` against the module-level ``store`` singleton (the pattern the other
route tests use), no real git repo or HTTP client needed.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import main
from haro.models import GateSummary, Project, Workspace, WorkspaceStatus
from haro.models import TestRunStatus as _TestRunStatus  # aliased so pytest doesn't collect it


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def project(tmp_path):
    """A registered project rooted at a real on-disk path (so ``_norm_path`` resolves
    it the same way the endpoint does)."""
    path = tmp_path / "repo"
    path.mkdir()
    proj = Project(name="demo", path=str(path), default_branch="main")
    main.store.add_project(proj)
    yield proj
    main.store.remove_project(proj.id)


def _add_ws(project, *, branch, status, gate=None):
    ws = Workspace(
        project_id=project.id,
        name=branch,
        branch=branch,
        worktree_path=f"{project.path}-wt-{branch}",
        base_ref="main",
        status=status,
        gate=gate,
    )
    main.store.add_workspace(ws)
    return ws


def test_green_when_gate_green(project):
    gate = GateSummary(status=_TestRunStatus.passed, total=3, passed=3, failed=0)
    ws = _add_ws(project, branch="feat/x", status=WorkspaceStatus.gate_green, gate=gate)
    try:
        out = run(main.firewall_verdict(repo=project.path, branch="feat/x"))
        assert out.verdict == "green"
        assert out.workspace_id == ws.id
        assert out.gate is not None and out.gate.passed == 3
    finally:
        main.store.remove_workspace(ws.id)


def test_red_when_gate_red(project):
    gate = GateSummary(status=_TestRunStatus.failed, total=3, passed=2, failed=1)
    ws = _add_ws(project, branch="feat/y", status=WorkspaceStatus.gate_red, gate=gate)
    try:
        out = run(main.firewall_verdict(repo=project.path, branch="feat/y"))
        assert out.verdict == "red"
        assert out.workspace_id == ws.id
        assert out.gate is not None and out.gate.failed == 1
    finally:
        main.store.remove_workspace(ws.id)


def test_unknown_when_never_gated(project):
    """A governed workspace that hasn't gated yet reports ``unknown`` (not red) — the
    firewall enforces a *proven* red, and the hook fail-opens on unknown by default —
    but still names the workspace so the hook can say which one is unresolved."""
    ws = _add_ws(project, branch="feat/z", status=WorkspaceStatus.idle)
    try:
        out = run(main.firewall_verdict(repo=project.path, branch="feat/z"))
        assert out.verdict == "unknown"
        assert out.workspace_id == ws.id
        assert out.gate is None
    finally:
        main.store.remove_workspace(ws.id)


def test_unknown_when_branch_ungoverned(project):
    """A branch with no matching workspace → unknown, and no workspace attribution."""
    out = run(main.firewall_verdict(repo=project.path, branch="never-adopted"))
    assert out.verdict == "unknown"
    assert out.workspace_id is None
    assert out.gate is None


def test_unknown_when_repo_unregistered(tmp_path):
    """A repo path haro doesn't govern → unknown (the hook fail-opens / warns)."""
    out = run(main.firewall_verdict(repo=str(tmp_path / "nope"), branch="main"))
    assert out.verdict == "unknown"
    assert out.workspace_id is None


def test_branch_match_is_scoped_to_the_repo(tmp_path):
    """Two projects can share a branch name; the verdict matches the workspace in the
    project whose path was requested, never a same-named branch in another repo."""
    a = tmp_path / "a"
    b = tmp_path / "b"
    a.mkdir()
    b.mkdir()
    proj_a = Project(name="a", path=str(a), default_branch="main")
    proj_b = Project(name="b", path=str(b), default_branch="main")
    main.store.add_project(proj_a)
    main.store.add_project(proj_b)
    ws_a = _add_ws(proj_a, branch="shared", status=WorkspaceStatus.gate_red,
                   gate=GateSummary(status=_TestRunStatus.failed, failed=1))
    ws_b = _add_ws(proj_b, branch="shared", status=WorkspaceStatus.gate_green,
                   gate=GateSummary(status=_TestRunStatus.passed))
    try:
        out = run(main.firewall_verdict(repo=str(b), branch="shared"))
        assert out.verdict == "green"
        assert out.workspace_id == ws_b.id
    finally:
        main.store.remove_workspace(ws_a.id)
        main.store.remove_workspace(ws_b.id)
        main.store.remove_project(proj_a.id)
        main.store.remove_project(proj_b.id)
