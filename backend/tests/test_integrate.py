import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import git_ops, integrate
from haro.models import Project, Workspace, WorkspaceStatus


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def test_local_merge_git_note_carries_the_receipt(tmp_path):
    """The Gate Receipt's git-note sink (receipt.py, usp-critique-plan.md idea 1):
    a successful LOCAL merge attaches the receipt markdown to the merge commit, so
    the evidence travels with the commit even with no PR to comment on."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(
        project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main"
    )

    result = asyncio.run(
        integrate.integrate(
            workspace=ws, project=project, message="merge feat",
            receipt_markdown="# haro gate receipt — GREEN\n- Suite: 2/2 passed\n",
        )
    )
    assert result["method"] == "local"

    note = subprocess.run(
        ["git", "notes", "show", "HEAD"], cwd=repo, capture_output=True, text=True
    )
    assert note.returncode == 0
    assert "GREEN" in note.stdout
    assert "2/2 passed" in note.stdout


def test_local_merge_without_a_receipt_writes_no_note(tmp_path):
    """No receipt was built (e.g. it errored) — must not attach a stray empty note."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(
        project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main"
    )

    asyncio.run(integrate.integrate(workspace=ws, project=project, message="merge feat"))

    note = subprocess.run(
        ["git", "notes", "show", "HEAD"], cwd=repo, capture_output=True, text=True
    )
    assert note.returncode != 0


def test_local_merge_ticks_the_seed_backlog_item_and_leaves_main_clean(tmp_path):
    """The seed-file checkbox tick rides INSIDE the merge commit (on the worktree,
    before commit_all) rather than a separate edit to the main checkout afterward —
    a review caught that the old post-merge approach left `backlog/TODO.md` dirty
    in the main checkout, which made `git_ops.local_merge`'s `is_clean` guard refuse
    every SUBSEQUENT merge with "main checkout has uncommitted changes"."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "backlog").mkdir()
    (repo / "backlog" / "TODO.md").write_text("- [ ] ship it\n- [ ] something else\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(
        project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main",
        seed_key="backlog/TODO.md::ship it",
    )

    asyncio.run(integrate.integrate(workspace=ws, project=project, message="merge feat"))

    assert (repo / "backlog" / "TODO.md").read_text() == (
        "- [x] ship it\n- [ ] something else\n"
    )
    # The whole point: the main checkout must stay clean so a second merge can
    # follow immediately (reproduces the review's exact regression scenario).
    assert asyncio.run(git_ops.is_clean(str(repo))) is True


def test_local_merge_survives_a_seed_key_with_no_matching_item(tmp_path):
    """A renamed/removed item (or an issue-shaped seed_key) must not fail the merge
    — the tick is best-effort, BACKLOG_TICK is the fallback."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(
        project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main",
        seed_key="issue:42",
    )

    result = asyncio.run(integrate.integrate(workspace=ws, project=project, message="merge feat"))
    assert result["method"] == "local"


def _fake_gh(json_out):
    async def _gh(*args, cwd):
        return 0, json_out, ""

    return _gh


def test_pr_already_merged_true_when_sha_matches(monkeypatch):
    monkeypatch.setattr(
        integrate,
        "_gh",
        _fake_gh('{"state":"MERGED","headRefOid":"abc123"}'),
    )
    result = asyncio.run(integrate._pr_already_merged("feat", "/tmp", "abc123"))
    assert result is True


def test_pr_already_merged_false_when_new_commit_since_merge(monkeypatch):
    """A branch name stays MERGED on GitHub forever after its first PR lands. If
    the agent committed again since then, the new commit's sha won't match what
    was actually merged — this must NOT short-circuit, or the new work silently
    never gets pushed/merged (see the bug this test guards against)."""
    monkeypatch.setattr(
        integrate,
        "_gh",
        _fake_gh('{"state":"MERGED","headRefOid":"abc123"}'),
    )
    result = asyncio.run(integrate._pr_already_merged("feat", "/tmp", "def456"))
    assert result is False


def test_pr_already_merged_false_when_gh_call_fails(monkeypatch):
    async def _gh(*args, cwd):
        return 1, "", "no pull requests found"

    monkeypatch.setattr(integrate, "_gh", _gh)
    result = asyncio.run(integrate._pr_already_merged("feat", "/tmp", "abc123"))
    assert result is False


def test_merge_error_conflict_not_misreported_as_protection():
    """A `not mergeable` PR is a conflict, not branch protection — the message must
    point at resolving locally (`git merge origin/<base>`), never at a maintainer.
    Guards the exact gh output a user hit after a squash-merge kept diverging."""
    gh = (
        "Pull request HaziqLucii/haro#27 is not mergeable: the merge commit cannot "
        "be cleanly created."
    )
    msg = integrate._merge_error(gh, branch="feat/x", base_branch="main",
                                 pr_url="https://github.com/o/r/pull/27")
    assert "merge conflicts with main" in msg
    assert "git merge origin/main" in msg
    assert "branch protection" not in msg
    assert "maintainer" not in msg
    assert "raw gh:" in msg  # the real gh text is never fully hidden


def test_merge_error_real_branch_protection():
    msg = integrate._merge_error(
        "GraphQL: At least 1 approving review is required (protected branch)",
        branch="feat/x", base_branch="main", pr_url="https://github.com/o/r/pull/9",
    )
    assert "branch protection" in msg
    assert "pull/9" in msg


def test_merge_error_unknown_surfaces_raw():
    msg = integrate._merge_error("some brand new gh failure", branch="feat/x",
                                 base_branch="main", pr_url=None)
    assert msg == "gh pr merge failed: some brand new gh failure"


def test_issue_number_parses_issue_seed_key():
    assert integrate._issue_number("issue:42") == 42


def test_issue_number_none_for_non_issue_seeds():
    # todo-file seeds, ad-hoc workspaces (None), and malformed values all yield None
    # so no closing keyword is threaded for them.
    assert integrate._issue_number(None) is None
    assert integrate._issue_number("backlog/cockpit.md::do the thing") is None
    assert integrate._issue_number("issue:") is None
    assert integrate._issue_number("issue:abc") is None


def test_closes_prefix_for_issue_seed():
    assert integrate._closes_prefix("issue:42") == "Closes #42\n\n"


def test_closes_prefix_empty_for_non_issue_seed():
    assert integrate._closes_prefix(None) == ""
    assert integrate._closes_prefix("todo.md::x") == ""


def test_closes_prefix_idempotency_guard_matches_seeded_box():
    """The commit box the UI seeds already carries "Closes #42"; the backend guard is
    a case-insensitive substring check, so re-submitting must NOT double the keyword."""
    closes = integrate._closes_prefix("issue:42")
    message = "Follow-up to #3.\nCloses #42\n\nfix the thing"
    assert closes.strip().lower() in message.lower()  # guard would skip the prepend


# --- ship_preflight: the one choke point every ship path clears -------------- #
# Shared by POST /workspaces/{id}/merge, POST /workspaces/{id}/git/pr and both
# autonomy-ladder rungs (rungs.py), so these messages ARE the API's 409 bodies. The
# rung-side behaviour is covered in test_rungs.py; here we pin the refusals themselves.
def _pair(status=WorkspaceStatus.gate_green):
    project = Project(id="p", name="proj", path="/tmp/repo", default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="feat",
                   worktree_path="/tmp/wt", base_ref="main")
    ws.status = status
    return ws, project


def _refusal(monkeypatch, *, clean=True, merged=False, remote=False, **kw):
    """Run the preflight with git stubbed; return the refusal message, or None if it passed."""
    monkeypatch.setattr(integrate.git_ops, "is_clean", _async(clean))
    monkeypatch.setattr(integrate.git_ops, "branch_merged", _async(merged))
    monkeypatch.setattr(integrate.git_ops, "has_remote", _async(remote))
    ws, project = _pair(kw.pop("status", WorkspaceStatus.gate_green))
    try:
        asyncio.run(integrate.ship_preflight(
            workspace=ws, project=project,
            merge_mode=kw.pop("merge_mode", "both"), busy=kw.pop("busy", None),
            action=kw.pop("action", "merge"),
        ))
    except integrate.ShipRefused as exc:
        return str(exc)
    return None


def _async(value):
    async def _f(*_a, **_kw):
        return value

    return _f


def test_preflight_passes_a_clean_green_workspace(monkeypatch):
    assert _refusal(monkeypatch) is None


def test_preflight_requires_a_green_gate(monkeypatch):
    msg = _refusal(monkeypatch, status=WorkspaceStatus.gate_red)
    assert msg == "merge blocked: gate is not green (status: gate_red)"
    # The PR flavour names itself, and additionally accepts an already-merged workspace.
    assert "PR blocked" in _refusal(monkeypatch, status=WorkspaceStatus.gate_red, action="pr")
    assert _refusal(monkeypatch, status=WorkspaceStatus.merged, action="pr") is None


def test_preflight_refuses_while_busy(monkeypatch):
    assert _refusal(monkeypatch, busy="an agent") == "an agent is running: wait before merging"


def test_preflight_refuses_a_dirty_worktree(monkeypatch):
    """Commit-first: nothing ships unlabeled, and the ladder never commits *for* you."""
    assert _refusal(monkeypatch, clean=False) == "commit your changes first, then merge"
    assert "then open the PR" in _refusal(monkeypatch, clean=False, action="pr")


def test_preflight_honors_merge_mode(monkeypatch):
    assert "PR-only" in _refusal(monkeypatch, merge_mode="pr", remote=True)
    # No remote ⇒ no PR to open, so a PR-only policy can't block the local merge path.
    assert _refusal(monkeypatch, merge_mode="pr", remote=False) is None
    assert "merges directly" in _refusal(monkeypatch, merge_mode="merge", action="pr")


def test_preflight_refuses_a_pr_with_nothing_in_it(monkeypatch):
    """400, not 409 — "there is nothing here" isn't "not right now"."""
    ws, project = _pair()
    monkeypatch.setattr(integrate.git_ops, "is_clean", _async(True))
    monkeypatch.setattr(integrate.git_ops, "branch_merged", _async(True))
    with pytest.raises(integrate.ShipRefused) as exc:
        asyncio.run(integrate.ship_preflight(
            workspace=ws, project=project, merge_mode="both", busy=None, action="pr",
        ))
    assert exc.value.status == 400
    assert "no commits beyond main" in str(exc.value)


# --------------------------------------------------------------------------- #
# Verified-by trailer + PR-body receipt (usp-critique-round3.md Move A)
# --------------------------------------------------------------------------- #
def test_local_merge_commit_carries_the_verified_by_trailer(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main")

    asyncio.run(integrate.integrate(workspace=ws, project=project, message="merge feat"))

    log = subprocess.run(
        ["git", "log", "-1", "--format=%B"], cwd=repo, capture_output=True, text=True
    ).stdout
    assert "Verified-by: haro-gate" in log
    from haro import __version__
    assert __version__ in log


def test_verified_by_trailer_not_doubled_when_message_already_has_one(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main")

    asyncio.run(integrate.integrate(
        workspace=ws, project=project,
        message="merge feat\n\nVerified-by: haro-gate 9.9.9 alreadyhere",
    ))

    log = subprocess.run(
        ["git", "log", "-1", "--format=%B"], cwd=repo, capture_output=True, text=True
    ).stdout
    assert log.count("Verified-by: haro-gate") == 1
    assert "alreadyhere" in log  # the caller's own trailer wins, untouched


def test_gh_path_posts_the_receipt_into_the_pr_body(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    _run("remote", "add", "origin", "https://example.invalid/o/r.git", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main")

    calls: list[tuple] = []

    async def _fake_gh(*args, cwd):
        calls.append(args)
        if args[:2] == ("pr", "create"):
            return 0, "https://github.com/o/r/pull/1", ""
        if args[:2] == ("pr", "merge"):
            return 0, "", ""
        return 0, "", ""

    monkeypatch.setattr(integrate.git_ops, "push_branch", _noop)
    monkeypatch.setattr(integrate.git_ops, "delete_remote_branch", _noop)
    monkeypatch.setattr(integrate, "_gh", _fake_gh)

    result = asyncio.run(integrate.integrate(
        workspace=ws, project=project, message="add the login form\n\nsome body detail",
        receipt_markdown="# haro gate receipt — GREEN\n- Suite: 3/3 passed\n",
    ))

    assert result["method"] == "gh"
    create_call = next(c for c in calls if c[:2] == ("pr", "create"))
    assert create_call[2] == "--title"
    assert create_call[3] == "add the login form"
    assert create_call[4] == "--body"
    body = create_call[5]
    assert "some body detail" in body
    assert "GREEN" in body and "3/3 passed" in body
    # The trailer rides along for free: it's part of `message`, and `pr_body` is
    # sliced FROM `message` — refuter round-3 caught a vacuous version of this
    # assertion (`not in create_call` tests tuple membership, not substring-in-body,
    # so it was true unconditionally regardless of what actually shipped).
    assert "Verified-by: haro-gate" in body


async def _noop(*a, **k):
    return None


def test_trailer_uses_the_passed_digest_not_a_fresh_redift(tmp_path):
    # usp-critique-round3.md Move A, refuter round-3: the trailer must reflect
    # what the GATE measured, not whatever the worktree looks like at merge time.
    # Passing `digest` explicitly (as main.py/rungs.py now do, from the frozen
    # `Receipt.digest`) must win over any fresh re-diff — even one that would
    # compute to something completely different.
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "g.txt").write_text("new file — this would fingerprint to something else entirely\n")

    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main")

    asyncio.run(integrate.integrate(
        workspace=ws, project=project, message="merge feat",
        digest="gate-time-digest-frozen-before-any-drift",
    ))

    log = subprocess.run(
        ["git", "log", "-1", "--format=%B"], cwd=repo, capture_output=True, text=True
    ).stdout
    assert "Verified-by: haro-gate" in log
    assert "gate-time-digest-frozen-before-any-drift" in log
