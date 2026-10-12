import asyncio
import subprocess
from pathlib import Path

from haro import git_ops
from haro.git_ops import GitError, slugify


def test_slugify_basic():
    assert slugify("Add Divide") == "add-divide"


def test_slugify_strips_punctuation_and_edges():
    assert slugify("  Fix Pagination!! ") == "fix-pagination"
    assert slugify("MCP/Server") == "mcp-server"


def test_slugify_collapses_runs():
    assert slugify("a___b   c") == "a-b-c"


def test_slugify_empty_falls_back():
    assert slugify("") == "task"
    assert slugify("!!!") == "task"


# --- list_worktrees: the Merge Firewall scanner (backlog/merge-firewall.md §1) --- #
def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    return repo


# --- "Don't firewall ourselves": _git exports HARO_INTERNAL=1 (backlog/merge-firewall.md §3) --- #
def _install_internal_gate_hook(repo: Path) -> None:
    """A pre-merge-commit hook that refuses unless HARO_INTERNAL=1 — a stand-in for the
    Merge Firewall hook. git passes its env down to hooks, so this proves `_git` propagates
    the marker end-to-end (not just that the constant exists)."""
    hook = repo / ".git" / "hooks" / "pre-merge-commit"
    hook.write_text('#!/bin/sh\n[ "${HARO_INTERNAL:-}" = 1 ] || exit 1\n')
    hook.chmod(0o755)


def test_git_marks_internal_so_haro_merges_pass_the_hook(tmp_path):
    repo = _repo(tmp_path)
    _run("checkout", "-b", "feat", cwd=repo)
    (repo / "f.txt").write_text("changed\n")
    _run("commit", "-am", "work", cwd=repo)
    _run("checkout", "main", cwd=repo)
    _install_internal_gate_hook(repo)

    # haro's own merge goes through _git (carrying HARO_INTERNAL=1) → the hook lets it through.
    asyncio.run(git_ops.local_merge(repo, "feat", "main", "merge feat"))
    log = subprocess.run(
        ["git", "log", "-1", "--pretty=%s"], cwd=repo, capture_output=True, text=True
    )
    assert "merge feat" in log.stdout


def test_bare_git_merge_without_marker_is_blocked_by_the_hook(tmp_path):
    # Negative control: the same hook DOES block a merge run without the marker, so the pass
    # above is the marker's doing, not a dead hook.
    repo = _repo(tmp_path)
    _run("checkout", "-b", "feat", cwd=repo)
    (repo / "f.txt").write_text("changed\n")
    _run("commit", "-am", "work", cwd=repo)
    _run("checkout", "main", cwd=repo)
    _install_internal_gate_hook(repo)

    blocked = subprocess.run(
        ["git", "merge", "--no-ff", "feat", "-m", "merge feat"],
        cwd=repo, capture_output=True, text=True,
    )
    assert blocked.returncode != 0


# --- local_merge aborts on conflict instead of leaving `main` half-merged (task 4,
# notes/desync-hardening-plan.md) --- #
def test_local_merge_conflict_aborts_and_leaves_repo_clean(tmp_path):
    repo = _repo(tmp_path)
    _run("checkout", "-b", "feat", cwd=repo)
    (repo / "f.txt").write_text("feat-change\n")
    _run("commit", "-am", "feat work", cwd=repo)
    _run("checkout", "main", cwd=repo)
    (repo / "f.txt").write_text("main-change\n")
    _run("commit", "-am", "main work", cwd=repo)

    try:
        asyncio.run(git_ops.local_merge(repo, "feat", "main", "merge feat"))
        assert False, "expected a conflicting merge to raise GitError"
    except GitError as exc:
        assert "feat" in str(exc) and "main" in str(exc)

    assert not (repo / ".git" / "MERGE_HEAD").exists()
    status = subprocess.run(
        ["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True
    )
    assert status.stdout == ""

    head = subprocess.run(
        ["git", "log", "-1", "--pretty=%s"], cwd=repo, capture_output=True, text=True
    )
    assert head.stdout.strip() == "main work"


def test_local_merge_non_conflicting_still_succeeds(tmp_path):
    repo = _repo(tmp_path)
    _run("checkout", "-b", "feat", cwd=repo)
    (repo / "g.txt").write_text("new file\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "feat work", cwd=repo)
    _run("checkout", "main", cwd=repo)

    asyncio.run(git_ops.local_merge(repo, "feat", "main", "merge feat"))

    log = subprocess.run(
        ["git", "log", "-1", "--pretty=%s"], cwd=repo, capture_output=True, text=True
    )
    assert "merge feat" in log.stdout


def test_local_merge_non_conflict_failure_keeps_real_stderr(tmp_path):
    """A merge can fail with no content conflict at all — a rejecting hook, a bad
    signing config. That must not get relabeled as 'conflicts with main': the real
    git error has to survive, or the actual cause is invisible to the user."""
    repo = _repo(tmp_path)
    _run("checkout", "-b", "feat", cwd=repo)
    (repo / "g.txt").write_text("new file\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "feat work", cwd=repo)
    _run("checkout", "main", cwd=repo)
    hook = repo / ".git" / "hooks" / "pre-merge-commit"
    hook.write_text('#!/bin/sh\necho "rejected: signature required" >&2\nexit 1\n')
    hook.chmod(0o755)

    try:
        asyncio.run(git_ops.local_merge(repo, "feat", "main", "merge feat"))
        assert False, "expected the rejecting hook to raise GitError"
    except GitError as exc:
        assert "conflicts with" not in str(exc)
        assert "signature required" in str(exc)

    assert not (repo / ".git" / "MERGE_HEAD").exists()
    status = subprocess.run(
        ["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True
    )
    assert status.stdout == ""


def test_list_worktrees_parses_and_classifies(tmp_path):
    repo = _repo(tmp_path)
    # haro's own worktrees root; a "managed" worktree sits under it.
    root = tmp_path / "worktrees"
    managed = root / "managed-ws"
    asyncio.run(git_ops.add_worktree(repo, managed, "haro/managed", "main"))
    # A foreign worktree elsewhere (a native/other-tool checkout).
    foreign = tmp_path / "elsewhere" / "foreign-ws"
    asyncio.run(git_ops.add_worktree(repo, foreign, "someones-branch", "main"))

    rows = asyncio.run(
        git_ops.list_worktrees(repo, tracked_paths=[str(managed)], worktree_root=str(root))
    )
    by_branch = {r["branch"]: r for r in rows}

    # Main checkout is present, on `main`, not detached, and (here) neither tracked
    # nor under haro's root — i.e. it reads as foreign, as the caller expects.
    assert by_branch["main"]["detached"] is False
    assert by_branch["main"]["head"]

    m = by_branch["haro/managed"]
    assert m["tracked"] is True
    assert m["under_worktree_root"] is True

    f = by_branch["someones-branch"]
    assert f["tracked"] is False
    assert f["under_worktree_root"] is False  # the adopt candidate


def test_list_worktrees_reports_detached(tmp_path):
    repo = _repo(tmp_path)
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    det = tmp_path / "det"
    asyncio.run(git_ops.add_detached_worktree(repo, det, sha))

    rows = asyncio.run(git_ops.list_worktrees(repo))
    detached = [r for r in rows if r["detached"]]
    assert len(detached) == 1
    assert detached[0]["branch"] is None
    assert detached[0]["head"] == sha
