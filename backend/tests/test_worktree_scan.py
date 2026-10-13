"""Route-level tests for the Merge Firewall scan endpoint,
``GET /projects/{project_id}/worktrees`` (backlog/merge-firewall.md §1).

``git_ops.list_worktrees`` is unit-tested in ``test_git_ops.py``; this covers the
HTTP seam on top of it: that the endpoint drops the rows haro already governs (the
managed workspace, the repo's own main checkout) and surfaces only genuinely foreign
worktrees, each tagged with a best-guess ``source``.

No httpx/pytest-asyncio in the gate env, so we drive the async handler directly with
``asyncio.run`` against the module-level ``store`` singleton (the pattern the other
route tests use), rather than an in-process HTTP client.
"""

from __future__ import annotations

import asyncio
import subprocess

import pytest
from fastapi import HTTPException

from haro import git_ops, main
from haro.config import settings
from haro.main import _guess_worktree_source
from haro.models import AdoptWorkspaceRequest, Project, Workspace


def run(coro):
    return asyncio.run(coro)


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path):
    """A real git repo with one initial commit, registered as a project."""
    path = tmp_path / "repo"
    path.mkdir()
    _run("init", "-b", "main", cwd=path)
    _run("config", "user.email", "t@t", cwd=path)
    _run("config", "user.name", "t", cwd=path)
    (path / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=path)
    _run("commit", "-m", "init", cwd=path)
    proj = Project(name="demo", path=str(path), default_branch="main")
    main.store.add_project(proj)
    yield proj
    main.store.remove_project(proj.id)


def test_scan_surfaces_foreign_drops_governed(tmp_path, repo):
    # A managed workspace haro created (tracked in the store).
    managed = tmp_path / "worktrees" / "managed"
    run(git_ops.add_worktree(repo.path, managed, "haro/managed", "main"))
    ws = Workspace(
        project_id=repo.id,
        name="managed",
        branch="haro/managed",
        worktree_path=str(managed),
        base_ref="main",
    )
    main.store.add_workspace(ws)
    # A foreign worktree some other tool created (never registered).
    foreign = tmp_path / "elsewhere" / "foreign"
    run(git_ops.add_worktree(repo.path, foreign, "someones-branch", "main"))

    out = run(main.list_foreign_worktrees(repo.id))
    branches = {w["branch"] for w in out["worktrees"]}

    # Only the foreign worktree survives — not the managed one, not the main checkout.
    assert branches == {"someones-branch"}
    assert out["worktrees"][0]["source"] == "unknown"


def test_scan_surfaces_orphaned_haro_worktree(tmp_path, repo, monkeypatch):
    """A worktree that lives under haro's OWN worktree root but has no store row
    (the store lost track of it — e.g. a create that never made it into a
    persisted snapshot before the app quit) must still surface, tagged
    ``orphaned``, rather than being silently dropped as "already governed".
    Without this, a lost workspace's worktree + branch could never be reclaimed
    or freed for reuse from the UI (the bug behind a "name already exists" 409
    on a workspace that no longer appears anywhere)."""
    root = tmp_path / "worktree-root"
    monkeypatch.setattr(settings, "worktree_root", str(root))

    orphan = root / repo.name / "orphaned-one"
    run(git_ops.add_worktree(repo.path, orphan, "haro/orphaned-one", "main"))
    # No `main.store.add_workspace(...)` — this worktree has no store row at all.

    out = run(main.list_foreign_worktrees(repo.id))

    assert {w["branch"] for w in out["worktrees"]} == {"haro/orphaned-one"}
    assert out["worktrees"][0]["source"] == "orphaned"


def test_adopt_orphaned_haro_worktree(tmp_path, repo, monkeypatch):
    """The orphan case is also adoptable, not just listed — recovering the lost
    workspace in place rather than requiring manual `git worktree remove` +
    `git branch -D` to free the name."""
    root = tmp_path / "worktree-root"
    monkeypatch.setattr(settings, "worktree_root", str(root))

    orphan = root / repo.name / "orphaned-two"
    run(git_ops.add_worktree(repo.path, orphan, "haro/orphaned-two", "main"))

    ws = run(main.adopt_workspace(repo.id, AdoptWorkspaceRequest(path=str(orphan))))
    try:
        assert ws.kind == "adopted"
        assert ws.branch == "haro/orphaned-two"
        assert ws.source == "orphaned"
    finally:
        main.store.remove_workspace(ws.id)


def test_scan_404_on_unknown_project():
    with pytest.raises(HTTPException) as exc:
        run(main.list_foreign_worktrees("does-not-exist"))
    assert exc.value.status_code == 404


def test_guess_source():
    assert _guess_worktree_source("/home/x/.claude/worktrees/feat-y") == "claude-code"
    assert _guess_worktree_source("/home/x/claude-squad/session-3") == "claude-squad"
    assert _guess_worktree_source("/tmp/some-random-checkout") == "unknown"


def test_reconcile_adoptable_seeds_baseline(tmp_path, repo):
    """Boot rescan (the db.reconcile precedent): seeds store.adoptable + returns a
    note, and stays silent (no broadcast) so a later scan can detect the delta."""
    foreign = tmp_path / "elsewhere" / "foreign"
    run(git_ops.add_worktree(repo.path, foreign, "someones-branch", "main"))

    async def scenario():
        q = main.hub.subscribe_global()
        try:
            notes = await main.reconcile_adoptable(main.store)
            return notes, q.empty()
        finally:
            main.hub.unsubscribe_global(q)

    notes, silent = run(scenario())

    assert any("adoptable worktree" in n for n in notes)
    assert {r["branch"] for r in main.store.adoptable[repo.id]} == {"someones-branch"}
    assert silent, "boot reconcile must not broadcast (no client yet, all reads as new)"


def test_on_demand_scan_broadcasts_only_newly_appeared(tmp_path, repo):
    """The on-demand scan endpoint diffs against the seeded baseline and broadcasts
    an `adoptable` hint carrying ONLY the worktree that newly appeared."""
    first = tmp_path / "elsewhere" / "first"
    run(git_ops.add_worktree(repo.path, first, "branch-one", "main"))

    async def scenario():
        # Seed the baseline with the first foreign worktree (boot).
        await main.reconcile_adoptable(main.store)
        # A second foreign worktree appears after boot.
        await git_ops.add_worktree(repo.path, tmp_path / "elsewhere" / "second", "branch-two", "main")
        q = main.hub.subscribe_global()
        try:
            out = await main.list_foreign_worktrees(repo.id)
            envelope = q.get_nowait() if not q.empty() else None
            return out, envelope
        finally:
            main.hub.unsubscribe_global(q)

    out, envelope = run(scenario())

    # Both foreign worktrees are listed…
    assert {w["branch"] for w in out["worktrees"]} == {"branch-one", "branch-two"}
    # …but only the newly-appeared one is announced as a hint.
    assert envelope is not None
    assert envelope["channel"] == "notify" and envelope["kind"] == "adoptable"
    assert envelope["count"] == 2
    assert {n["branch"] for n in envelope["new"]} == {"branch-two"}


def test_adopt_prunes_from_hint(tmp_path, repo):
    """Adopting a foreign worktree drops it from store.adoptable immediately, so the
    hint count is honest without waiting for the next scan."""
    foreign = tmp_path / "elsewhere" / "adopt-me"
    run(git_ops.add_worktree(repo.path, foreign, "adopt-branch", "main"))

    async def scenario():
        await main.reconcile_adoptable(main.store)
        ws = await main.adopt_workspace(repo.id, AdoptWorkspaceRequest(path=str(foreign)))
        return ws

    ws = run(scenario())
    try:
        assert ws.kind == "adopted"
        assert ws.branch == "adopt-branch"
        assert main.store.adoptable[repo.id] == []
    finally:
        main.store.remove_workspace(ws.id)
