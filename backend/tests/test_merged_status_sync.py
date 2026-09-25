"""The reported bug: the ④ ship step read "merged" while everything keyed on
`workspace.status` — the sidebar dot, the bento purple border, "Continue on a new
branch" — read green.

Two predicates had drifted apart:

  * backend  `_adopt_merged_state`  — merged ⟺ a PR exists, is MERGED, and its
    `headRefOid` is the commit we're actually sitting on.
  * frontend `GitPanel`             — merged ⟺ `status == "merged" || pr.state == "MERGED"`

The frontend half was written before `GET /git/pr` learned to reconcile, and it is
SHA-blind: a branch name stays MERGED on github.com forever, so any workspace whose
HEAD had moved past its merge commit went purple on the ship step alone. The fix hands
the panel the reconciled verdict (`workspace_merged`) instead of letting it re-derive one.

Reconciling also has to know the difference between "not merged" and "no PR to ask".
`pr_status` degrades to `supported=False` (no remote, no `gh`, worktree gone) or
`exists=False` (no PR for this branch) — an ABSENCE of evidence. Treating that as
"not merged" demoted every LOCAL merge: `integrate` set `merged`, then the ship
panel's own PR fetch un-set it a moment later, on every no-remote repo and every
project running `[workflow] merge_mode = "merge"`.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import git_ops, main
from haro.models import Project, Workspace, WorkspaceStatus

HEAD = "c7ee9c92803f3b890ebf250e5f605a3eee205788"
OTHER = "1111111111111111111111111111111111111111"


@pytest.fixture
def ws(tmp_path):
    """A green workspace in the process-wide store, fully restored afterwards (a
    leaked row poisons every later test that walks the store)."""
    projects, workspaces = dict(main.store.projects), dict(main.store.workspaces)
    project = Project(id="p-merged-sync", name="proj", path=str(tmp_path), default_branch="main")
    main.store.projects[project.id] = project
    w = Workspace(
        project_id=project.id, name="ship it", branch="feat/ship",
        worktree_path=str(tmp_path), base_ref="main",
    )
    w.status = WorkspaceStatus.gate_green
    main.store.workspaces[w.id] = w
    try:
        yield w
    finally:
        main.store.projects.clear()
        main.store.projects.update(projects)
        main.store.workspaces.clear()
        main.store.workspaces.update(workspaces)


@pytest.fixture(autouse=True)
def _head(monkeypatch):
    """Pin the worktree's HEAD so the head_sha comparison is the thing under test."""
    async def head_sha(_path):
        return HEAD
    monkeypatch.setattr(git_ops, "head_sha", head_sha)


def adopt(w, data) -> bool:
    return asyncio.run(main._adopt_merged_state(w, data))


def merged_pr(**over) -> dict:
    return {"supported": True, "exists": True, "state": "MERGED",
            "head_sha": HEAD, "number": 227, **over}


# --- absence of a PR is not evidence of "not merged" ------------------------ #

@pytest.mark.parametrize("data, why", [
    ({"supported": False, "reason": "no git remote: local-only workspace"}, "no remote"),
    ({"supported": False, "reason": "`gh` CLI not found"}, "no gh CLI"),
    ({"supported": False, "reason": "no worktree on disk"}, "worktree gone"),
    ({"supported": True, "exists": False}, "no PR for this branch"),
])
def test_a_local_merge_survives_the_ship_panels_pr_fetch(ws, data, why):
    """THE silent half of the bug. `integrate` merges locally and sets `merged`; the
    ship panel then fetches `/git/pr`, which has nothing to report — and that used to
    demote the workspace straight back to gate_green."""
    ws.status = WorkspaceStatus.merged
    assert adopt(ws, data) is False, why
    assert ws.status == WorkspaceStatus.merged, why


def test_no_pr_does_not_promote_either(ws):
    """The guard cuts both ways — an absence can't invent a merge."""
    assert adopt(ws, {"supported": True, "exists": False}) is False
    assert ws.status == WorkspaceStatus.gate_green


# --- a real PR record still moves the status, both directions --------------- #

def test_a_pr_merged_on_github_promotes(ws):
    """The case the reconcile exists for: someone merged the PR on github.com, so
    nothing local ever fired. Its head is the commit we're on, so it's ours."""
    assert adopt(ws, merged_pr()) is True
    assert ws.status == WorkspaceStatus.merged
    assert ws.last_pr_number == 227


def test_a_merged_pr_for_a_different_commit_does_not_promote(ws):
    """A reused branch name, or new commits since the merge. This is the check the
    frontend's `pr.state === "MERGED"` shortcut skipped — the visible half of the bug."""
    assert adopt(ws, merged_pr(head_sha=OTHER)) is False
    assert ws.status == WorkspaceStatus.gate_green


def test_an_open_pr_unsticks_a_wrongly_merged_workspace(ws):
    """Demotion still works where there IS a PR record contradicting us. It lands on
    `idle` here rather than `gate_green` because this fixture carries no gate result —
    the demote only restores green when the last gate actually passed."""
    ws.status = WorkspaceStatus.merged
    assert adopt(ws, merged_pr(state="OPEN")) is True
    assert ws.status == WorkspaceStatus.idle


def test_a_stale_merged_pr_unsticks_once_head_moves(ws):
    """Same, via the head check: the PR reads MERGED but for a commit we left behind."""
    ws.status = WorkspaceStatus.merged
    assert adopt(ws, merged_pr(head_sha=OTHER)) is True
    assert ws.status == WorkspaceStatus.idle


# --- the panel gets ONE verdict, not a second opinion ----------------------- #

def test_the_endpoint_hands_the_panel_the_reconciled_verdict(ws, monkeypatch):
    """`workspace_merged` is what `GitPanel` now paints the ④ step purple on. It must
    agree with `workspace.status` on the very response that reconciled it — the two
    disagreeing IS the bug."""
    from haro import git_panel

    async def pr_status(_path, _branch):
        return merged_pr()
    monkeypatch.setattr(git_panel, "pr_status", pr_status)

    resp = asyncio.run(main.git_pr(ws.id))
    assert resp.state == "MERGED"
    assert resp.workspace_merged is True
    assert ws.status == WorkspaceStatus.merged


def test_a_stale_merged_pr_reads_not_merged_to_the_panel(ws, monkeypatch):
    """The reported symptom, at the seam that produced it: gh says MERGED, but for a
    commit we've moved past. The panel must NOT go purple while the sidebar stays green."""
    from haro import git_panel

    async def pr_status(_path, _branch):
        return merged_pr(head_sha=OTHER)
    monkeypatch.setattr(git_panel, "pr_status", pr_status)

    resp = asyncio.run(main.git_pr(ws.id))
    assert resp.state == "MERGED"          # what the old frontend keyed on
    assert resp.workspace_merged is False  # what it keys on now
    assert ws.status == WorkspaceStatus.gate_green
