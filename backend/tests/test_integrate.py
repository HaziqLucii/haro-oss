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


def _refusal(monkeypatch, *, clean=True, merged=False, remote=False, gh=None, **kw):
    """Run the preflight with git stubbed; return the refusal message, or None if it passed."""
    monkeypatch.setattr(integrate.git_ops, "is_clean", _async(clean))
    monkeypatch.setattr(integrate.git_ops, "branch_merged", _async(merged))
    monkeypatch.setattr(integrate.git_ops, "has_remote", _async(remote))
    monkeypatch.setattr(integrate.git_ops, "gh_remote", _async(remote if gh is None else gh))
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
    _run("remote", "add", "origin", "https://github.com/o/r.git", cwd=repo)

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
    # sliced FROM `message` — code review round-3 caught a vacuous version of this
    # assertion (`not in create_call` tests tuple membership, not substring-in-body,
    # so it was true unconditionally regardless of what actually shipped).
    assert "Verified-by: haro-gate" in body


async def _noop(*a, **k):
    return None


def test_trailer_uses_the_passed_digest_not_a_fresh_redift(tmp_path):
    # usp-critique-round3.md Move A, code review round-3: the trailer must reflect
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


# ---- a remote gh cannot use: local merge plus a plain push ----


@pytest.mark.parametrize(
    "url,host",
    [
        ("https://github.com/o/r.git", "github.com"),
        ("https://user:tok@gitlab.example.com/o/r.git", "gitlab.example.com"),
        ("git@github.com:o/r.git", "github.com"),
        ("git@git.corp.example:team/r.git", "git.corp.example"),
        ("ssh://git@Gitea.Local:2222/o/r.git", "gitea.local"),
        ("/srv/git/r.git", None),
        ("../origin.git", None),
        ("file:///srv/git/r.git", None),
        ("C:\\repos\\origin.git", None),
        ("c:/repos/origin.git", None),
        ("", None),
        (None, None),
    ],
)
def test_remote_host_parses_every_url_shape(url, host):
    assert git_ops.remote_host(url) == host


def _repo_with_origin(tmp_path, url=None):
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    (repo / "f.txt").write_text("base\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    _run("remote", "add", "origin", str(origin), cwd=repo)
    _run("push", "-q", "origin", "main", cwd=repo)
    if url:
        _run("remote", "set-url", "origin", url, cwd=repo)
    return repo, origin


def test_gh_remote_is_false_for_a_local_path_and_a_gitlab_host(tmp_path, monkeypatch):
    repo, _ = _repo_with_origin(tmp_path)
    assert asyncio.run(git_ops.gh_remote(repo)) is False
    _run("remote", "set-url", "origin", "git@gitlab.com:o/r.git", cwd=repo)

    async def no(host, cwd):
        return False

    monkeypatch.setattr(git_ops, "_gh_knows_host", no)
    assert asyncio.run(git_ops.gh_remote(repo)) is False


def test_gh_remote_is_true_for_github_and_for_a_host_gh_is_signed_in_to(tmp_path, monkeypatch):
    repo, _ = _repo_with_origin(tmp_path, "https://github.com/o/r.git")
    assert asyncio.run(git_ops.gh_remote(repo)) is True
    _run("remote", "set-url", "origin", "https://ghe.corp.example/o/r.git", cwd=repo)
    seen = []

    async def yes(host, cwd):
        seen.append(host)
        return True

    monkeypatch.setattr(git_ops, "_gh_knows_host", yes)
    assert asyncio.run(git_ops.gh_remote(repo)) is True
    assert seen == ["ghe.corp.example"]


def test_only_origin_counts_for_gh(tmp_path):
    repo, _ = _repo_with_origin(tmp_path, "https://github.com/o/r.git")
    assert asyncio.run(git_ops.gh_remote(repo)) is True
    _run("remote", "rename", "origin", "upstream", cwd=repo)
    assert asyncio.run(git_ops.gh_remote(repo)) is False


def _ws_from_origin(repo, tmp_path):
    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "origin/main"))
    (wt / "g.txt").write_text("new file\n")
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(
        project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="origin/main"
    )
    return project, ws


def test_a_non_github_remote_merges_locally_and_pushes_the_base(tmp_path, monkeypatch):
    repo, origin = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)

    async def boom(*a, **k):
        raise AssertionError("gh must not be used for a remote it cannot reach")

    monkeypatch.setattr(integrate, "_gh", boom)
    result = asyncio.run(
        integrate.integrate(workspace=ws, project=project, message="add g\n\nbody")
    )
    assert result["method"] == "local"
    assert result["pushed"] is True
    assert "pushed main to origin" in result["detail"]
    local = subprocess.run(["git", "rev-parse", "main"], cwd=repo, capture_output=True, text=True).stdout
    remote = subprocess.run(["git", "rev-parse", "main"], cwd=origin, capture_output=True, text=True).stdout
    assert local == remote
    assert (repo / "g.txt").read_text() == "new file\n"
    assert subprocess.run(["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True).stdout == ""


def test_a_failed_push_is_reported_and_does_not_undo_the_merge(tmp_path):
    repo, origin = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    # Someone else moves origin/main on, so a plain push of our merge is rejected.
    other = tmp_path / "other"
    subprocess.run(["git", "clone", "-q", str(origin), str(other)], check=True, capture_output=True)
    _run("config", "user.email", "o@o", cwd=other)
    _run("config", "user.name", "o", cwd=other)
    (other / "x.txt").write_text("theirs\n")
    _run("add", "-A", cwd=other)
    _run("commit", "-m", "theirs", cwd=other)
    _run("push", "-q", "origin", "main", cwd=other)

    result = asyncio.run(integrate.integrate(workspace=ws, project=project, message="add g"))
    assert result["method"] == "local"
    assert result["pushed"] is False
    assert "push it yourself" in result["detail"]
    assert (repo / "g.txt").exists()
    merged = subprocess.run(["git", "log", "--oneline", "-1"], cwd=repo, capture_output=True, text=True).stdout
    assert "add g" in merged


def test_a_no_remote_project_still_merges_without_a_push_field(tmp_path):
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
    (wt / "g.txt").write_text("x\n")
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(wt), base_ref="main")
    result = asyncio.run(integrate.integrate(workspace=ws, project=project, message="m"))
    assert result["method"] == "local"
    assert "pushed" not in result
    assert result["detail"] == "merged feat → main locally"


def test_pr_only_does_not_block_a_merge_when_the_remote_cannot_open_prs(monkeypatch):
    assert _refusal(monkeypatch, remote=True, gh=False, merge_mode="pr") is None


def test_pr_only_still_blocks_a_merge_when_prs_can_be_opened(monkeypatch):
    assert "PR-only" in _refusal(monkeypatch, remote=True, gh=True, merge_mode="pr")


def test_a_repo_whose_only_remote_is_not_origin_merges_locally_without_a_push(tmp_path):
    repo, _ = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    _run("remote", "rename", "origin", "upstream", cwd=repo)
    ws.base_ref = "main"
    result = asyncio.run(integrate.integrate(workspace=ws, project=project, message="add g"))
    assert result["method"] == "local"
    assert "pushed" not in result


def test_a_local_base_with_unpushed_commits_is_refused_before_anything_is_published(tmp_path):
    repo, origin = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    (repo / "wip.txt").write_text("never gated\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "wip", cwd=repo)
    with pytest.raises(RuntimeError, match="not on origin/main"):
        asyncio.run(integrate.integrate(workspace=ws, project=project, message="add g"))
    pushed = subprocess.run(["git", "log", "--oneline", "main"], cwd=origin, capture_output=True, text=True).stdout
    assert "wip" not in pushed
    assert not (repo / "g.txt").exists()


# ---- credentials: the gh helper only replaces the user's own on GitHub hosts ----


def _creds(repo, args=("push", "origin", "main")):
    return asyncio.run(git_ops._pinned_credentials(args, repo))


def test_the_users_credential_helper_is_kept_for_a_non_github_remote(tmp_path, monkeypatch):
    async def no(host, cwd):
        return False

    monkeypatch.setattr(git_ops, "_gh_knows_host", no)
    repo, _ = _repo_with_origin(tmp_path, "https://gitlab.example.com/o/r.git")
    assert _creds(repo) is True
    assert _creds(repo, ("fetch", "origin")) is True
    assert _creds(repo, ("status",)) is False


def test_the_gh_helper_still_applies_on_github_a_local_path_and_a_gh_host(tmp_path, monkeypatch):
    repo, _ = _repo_with_origin(tmp_path, "https://github.com/o/r.git")
    assert _creds(repo) is False
    local, _ = _repo_with_origin(tmp_path / "b")
    assert _creds(local) is False

    async def yes(host, cwd):
        return True

    monkeypatch.setattr(git_ops, "_gh_knows_host", yes)
    ghe, _ = _repo_with_origin(tmp_path / "c", "https://ghe.corp.example/o/r.git")
    assert _creds(ghe) is False


# ---- asking gh whether it is signed in to a host ----


def _gh_on_path(tmp_path, monkeypatch, known_host):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    gh = bin_dir / "gh"
    gh.write_text(
        "#!/bin/sh\n"
        '[ "$1 $2 $3" = "auth token --hostname" ] && [ "$4" = "%s" ] && exit 0\n'
        "exit 1\n" % known_host
    )
    gh.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}:/usr/bin:/bin")


def test_gh_knows_a_host_it_has_a_token_for_and_not_another(tmp_path, monkeypatch):
    _gh_on_path(tmp_path, monkeypatch, "ghe.signedin.example")
    assert asyncio.run(git_ops._gh_knows_host("ghe.signedin.example", tmp_path)) is True
    assert asyncio.run(git_ops._gh_knows_host("gitlab.other.example", tmp_path)) is False


def test_gh_not_installed_means_not_a_gh_host(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert asyncio.run(git_ops._gh_knows_host("ghe.nogh.example", tmp_path)) is False


# ---- a workspace whose origin/* base disappeared (the remote was unlinked) ----


def test_a_workspace_based_on_a_removed_origin_ref_merges_onto_the_local_branch(tmp_path):
    repo, _ = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    _run("remote", "remove", "origin", cwd=repo)
    assert ws.base_ref == "origin/main"
    result = asyncio.run(integrate.integrate(workspace=ws, project=project, message="add g"))
    assert result["method"] == "local"
    assert ws.base_ref == "main"
    assert (repo / "g.txt").exists()


def test_a_missing_base_with_no_local_branch_says_so_instead_of_nothing_to_merge(tmp_path):
    repo, _ = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    ws.base_ref = "origin/gone"
    with pytest.raises(RuntimeError, match="no longer exists"):
        asyncio.run(integrate.integrate(workspace=ws, project=project, message="add g"))


def test_a_base_that_does_not_resolve_is_never_reported_as_merged(tmp_path):
    repo, _ = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    (tmp_path / "wt" / "g.txt").write_text("x\n")
    _run("add", "-A", cwd=tmp_path / "wt")
    _run("commit", "-m", "work", cwd=tmp_path / "wt")
    # base present: unmerged work is not merged, as before
    assert asyncio.run(git_ops.branch_merged(repo, "feat", "origin/main")) is False
    # base gone with the branch still there: unknown, so NOT merged (callers delete on True)
    _run("remote", "remove", "origin", cwd=repo)
    assert asyncio.run(git_ops.branch_merged(repo, "feat", "origin/main")) is False
    # branch gone too: nothing left to merge
    assert asyncio.run(git_ops.branch_merged(repo, "no-such-branch", "origin/main")) is True


def test_local_fallback_ref(tmp_path):
    repo, _ = _repo_with_origin(tmp_path)
    assert asyncio.run(git_ops.local_fallback_ref(repo, "origin/main")) is None  # still resolves
    _run("remote", "remove", "origin", cwd=repo)
    assert asyncio.run(git_ops.local_fallback_ref(repo, "origin/main")) == "main"
    assert asyncio.run(git_ops.local_fallback_ref(repo, "origin/release")) is None  # no local twin
    assert asyncio.run(git_ops.local_fallback_ref(repo, "main")) is None


def test_a_broken_worktree_with_a_missing_base_does_not_delete_the_unmerged_branch(tmp_path):
    repo, _ = _repo_with_origin(tmp_path)
    project, ws = _ws_from_origin(repo, tmp_path)
    (tmp_path / "wt" / "g.txt").write_text("x\n")
    _run("add", "-A", cwd=tmp_path / "wt")
    _run("commit", "-m", "unmerged work", cwd=tmp_path / "wt")
    ws.base_ref = "origin/gone"  # a base with no local twin
    (tmp_path / "wt" / ".git").unlink()  # the husk: a worktree whose .git is gone
    with pytest.raises(RuntimeError, match="no longer exists"):
        asyncio.run(integrate.integrate(workspace=ws, project=project, message="m"))
    branches = subprocess.run(["git", "branch", "--list", "feat"], cwd=repo, capture_output=True, text=True).stdout
    assert "feat" in branches
