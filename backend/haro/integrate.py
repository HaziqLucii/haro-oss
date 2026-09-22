"""v1.3 integration: turn a green workspace into a merged change.

Two paths, chosen automatically:
  - **local** (no git remote): commit the worktree, then merge the branch into
    base_ref in the main checkout. Fully offline.
  - **gh** (remote exists): commit, push, `gh pr create`, and `gh pr merge`.

Either way the caller enforces the gate is green first — the discipline. On
success the workspace's worktree is archived.
"""

from __future__ import annotations

import asyncio
import json
import traceback

from . import __version__, git_ops
from . import backlog as backlog_svc
from .config import load_project_settings
from .models import Project, Workspace, WorkspaceStatus
from .receipt import diff_fingerprint


class ShipRefused(RuntimeError):
    """A ship preflight said no. The message is user-facing; ``status`` is the HTTP
    code an API path should answer with (409 "not now" by default, 400 for "there is
    nothing here to ship")."""

    def __init__(self, message: str, status: int = 409) -> None:
        super().__init__(message)
        self.status = status


async def ship_preflight(
    *,
    workspace: Workspace,
    project: Project,
    merge_mode: str,
    busy: str | None,
    action: str = "merge",
) -> None:
    """The ship choke point: everything that must hold before a green workspace turns
    into a merge (``action="merge"``) or a PR (``action="pr"``).

    Lifted out of the ``POST /workspaces/{id}/merge`` + ``POST /workspaces/{id}/git/pr``
    handlers so the autonomy ladder's auto rungs (``rungs.py``,
    backlog/autonomy-ladder.md §3) clear *literally the same* checks — gate green, busy
    guard, clean tree, ``[workflow] merge_mode`` — instead of a parallel copy free to
    drift. An automatic action is then exactly a manual one nobody had to click, which
    is the only version of it worth trusting.

    The clean-tree check is the load-bearing one for the ladder: an uncommitted
    worktree is *refused*, never auto-committed, so nothing lands unlabeled just
    because a rung was armed.

    Raises ``ShipRefused``; API paths turn that into a 4xx, the rung into a
    held-with-reason notification.
    """
    allowed = (
        # A PR is also offered after a merge (a merged workspace can still want its PR
        # link), which is why "pr" accepts the wider set.
        (WorkspaceStatus.gate_green, WorkspaceStatus.merged)
        if action == "pr"
        else (WorkspaceStatus.gate_green,)
    )
    if workspace.status not in allowed:
        label = "PR" if action == "pr" else "merge"
        raise ShipRefused(
            f"{label} blocked: gate is not green (status: {workspace.status.value})"
        )
    # A DEGRADED gate is not shippable (backlog/double-gate.md §0). "Degraded" means a check
    # this project asked for could not run, so the green covers less than it appears to. It
    # belongs at this choke point rather than in the UI, for the same reason every other
    # refusal does: the auto rungs clear this exact function, so an unverified green cannot
    # be auto-merged either.
    #
    # Only gated on an actual ship (status gate_green) — fetching the PR link for an
    # already-merged workspace reads a historical summary and must not be blocked by it.
    # The escape hatch needs no new config: turn the offending check off and it stops being
    # a check you asked for.
    if workspace.status == WorkspaceStatus.gate_green and (workspace.gate and workspace.gate.degraded):
        raise ShipRefused(
            "gate degraded: treat this green as unverified. A check this project asked for "
            "could not run, so re-run the gate (or turn that check off) before shipping"
        )
    # THE DOUBLE GATE (backlog/double-gate.md §1): green means tests AND quality.
    #
    # Under `[quality] enforce = "block"` a blocking finding already folds into the gate's
    # green conjunction, so the status check above catches it and this never fires. This is
    # here for the case that does NOT: `enforce = "warn"`, where the run stays green while
    # carrying blocking-severity findings. A leaked credential must not merge just because
    # the project set the enforcement dial to "warn" — warn governs whether the *verdict*
    # goes red, not whether haro will hand you the merge button for a secret.
    if workspace.status == WorkspaceStatus.gate_green and workspace.gate:
        blocking = workspace.gate.quality_blocking
        if blocking:
            note = workspace.gate.quality_note or f"{blocking} finding(s)"
            raise ShipRefused(
                f"quality gate: {note}. Fix the findings (or lower "
                "[quality] severity_threshold if they aren't worth blocking) before "
                f"{'opening a PR' if action == 'pr' else 'merging'}"
            )
    # THE REFUTER (Phase 3 — notes/workflow-roles-plan.md): the same "green means tests
    # AND review" promise as the quality check above, folded the same way — `test.
    # review_blocked` (the source of `workspace.gate.review_blocking`) is structurally
    # always False since 2026-09-17 (`review_enforce = "block"`, the only thing that
    # ever set it, was cut), so today this can never coexist with `gate_green` (the
    # status check above already caught it). Kept anyway as the same verified-list
    # contract every `quality_blocked` reader gets, so a future change to that
    # construction can't silently skip the ship choke point.
    if workspace.status == WorkspaceStatus.gate_green and workspace.gate and workspace.gate.review_blocking:
        n = workspace.gate.review_must_fix
        raise ShipRefused(
            f"refuter: {n} must-fix. Fix the findings before "
            f"{'opening a PR' if action == 'pr' else 'merging'}"
        )
    if busy:
        raise ShipRefused(
            f"{busy} is running: wait before "
            f"{'opening a PR' if action == 'pr' else 'merging'}"
        )
    # Commit-first: shipping never auto-commits the worktree. The developer (or the
    # agent) must commit with a real message before anything can land.
    if not await git_ops.is_clean(workspace.worktree_path):
        raise ShipRefused(
            f"commit your changes first, then {'open the PR' if action == 'pr' else 'merge'}"
        )
    if action == "pr":
        if merge_mode == "merge":
            raise ShipRefused(
                "this project merges directly ([workflow] merge_mode = \"merge\"): use “Merge”"
            )
        if await git_ops.branch_merged(project.path, workspace.branch, workspace.base_ref):
            raise ShipRefused(
                f"nothing to open a PR for: no commits beyond {workspace.base_ref}", 400
            )
    # Honor [workflow] merge_mode. "pr" means this project ships via review only —
    # block direct merge (but only when a remote exists; a no-remote repo has no PR
    # to open, so it always falls back to a local merge regardless of mode).
    elif merge_mode == "pr" and await git_ops.has_remote(project.path):
        raise ShipRefused(
            "this project is PR-only ([workflow] merge_mode = \"pr\"): use “Create PR” "
            "and have a maintainer merge it"
        )


async def _gh(*args: str, cwd: str) -> tuple[int, str, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            "gh", *args, cwd=cwd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        return 127, "", "`gh` CLI not found: install it or use a local (no-remote) repo"
    out, err = await proc.communicate()
    return proc.returncode or 0, out.decode().strip(), err.decode().strip()


async def _pr_already_merged(branch: str, cwd: str, current_sha: str) -> bool:
    """True if the PR for ``branch`` already merged *this exact commit* on the remote.

    Makes the gh path idempotent: a prior attempt can merge the PR remotely and
    still fail on local cleanup (the old ``--delete-branch`` worktree bug), leaving
    the workspace un-archived. On retry we detect the merged PR and skip straight
    to archiving instead of trying to re-push/re-merge an already-merged branch.

    Compares against ``current_sha`` (not just the PR's state) because a branch
    name stays "MERGED" on GitHub forever once its first PR lands — if the agent
    made a *new* commit since then, this must NOT short-circuit, or the new work
    silently never gets pushed/merged (it would look like a no-op success)."""
    code, out, _ = await _gh(
        "pr", "view", branch, "--json", "state,headRefOid", cwd=cwd
    )
    if code != 0:
        return False
    try:
        data = json.loads(out)
    except ValueError:
        return False
    return data.get("state") == "MERGED" and data.get("headRefOid") == current_sha


def _merge_error(gh_msg: str, *, branch: str, base_branch: str, pr_url: str | None) -> str:
    """Turn a failed ``gh pr merge`` into a friendly, *accurate* message.

    Three cases, distinguished so we never send the user down the wrong path:
      • **conflict** — the PR is dirty and GitHub can't create the merge commit
        cleanly (base moved, or a squash-merged branch kept getting commits). The
        fix is to resolve locally, NOT to ask a maintainer.
      • **blocked** — genuine branch-protection / permission signals: only a
        maintainer (or a passing review / required check) can merge.
      • otherwise — surface gh's raw error verbatim.
    We always append the raw gh text so the true cause is never fully hidden (the
    old classifier swallowed conflicts under a bogus "branch protection" message)."""
    msg = (gh_msg or "").strip()
    low = msg.lower()
    raw = f" (raw gh: {msg})" if msg else ""
    if any(s in low for s in ("not mergeable", "cannot be cleanly created", "conflict", "dirty")):
        where = f" (PR: {pr_url})" if pr_url else ""
        return (
            f"{branch} has merge conflicts with {base_branch}{where}: GitHub can't "
            f"create the merge commit cleanly. Resolve them in the worktree, then merge "
            f"again: `git fetch origin {base_branch} && git merge origin/{base_branch}` "
            f"→ fix conflicts → commit → let the gate re-run." + raw
        )
    if any(s in low for s in (
        "protected branch", "not authorized", "not allowed", "permission",
        "review is required", "review required", "approving review",
        "required status", "changes must be made through a pull request",
        "resource not accessible",
    )):
        where = f" Your PR is open: {pr_url}." if pr_url else ""
        return (
            "This repo won't let you merge directly: it likely requires a review or "
            "restricts who can merge (branch protection / permissions)." + where +
            " Use “Create PR” and ask a maintainer to review & merge." + raw
        )
    return f"gh pr merge failed: {msg}"


def _pr_number(url: str | None) -> int | None:
    """Trailing ``/pull/<n>`` of a gh PR URL → its integer, else None."""
    if not url:
        return None
    tail = url.rstrip("/").rsplit("/", 1)[-1]
    return int(tail) if tail.isdigit() else None


def _followup_prefix(prior_prs: list[int]) -> str:
    """"Follow-up to #106 / #107.\\n\\n" for a continued workspace, else ""."""
    if not prior_prs:
        return ""
    refs = " / ".join(f"#{n}" for n in prior_prs)
    return f"Follow-up to {refs}.\n\n"


def _issue_number(seed_key: str | None) -> int | None:
    """The ``<n>`` of an ``issue:<n>`` seed_key → its integer, else None.

    A workspace seeded from the GitHub Issues backlog carries ``seed_key =
    "issue:<n>"``; every other seed (a todo file, or an ad-hoc workspace) returns
    None so no closing keyword is threaded."""
    if not seed_key or not seed_key.startswith("issue:"):
        return None
    tail = seed_key[len("issue:"):]
    return int(tail) if tail.isdigit() else None


def _closes_prefix(seed_key: str | None) -> str:
    """"Closes #42\\n\\n" for an issue-seeded workspace, else "".

    Merging a PR whose body contains ``Closes #<n>`` auto-closes that issue on
    GitHub (default-branch merges), so the next backlog poll flips the issue row
    to ✔ without a manual close. An ``issue:<n>`` seed implies a GitHub remote
    exists (the Issues tab is populated from ``gh issue list``), so this only ever
    rides the gh PR path."""
    n = _issue_number(seed_key)
    return f"Closes #{n}\n\n" if n else ""


async def integrate(
    *,
    workspace: Workspace,
    project: Project,
    message: str,
    receipt_markdown: str | None = None,
    digest: str | None = None,
) -> dict:
    """Commit + merge (local or gh) + archive. Returns a summary dict.

    Raises git_ops.GitError / RuntimeError with a user-facing message on failure;
    callers surface these as 4xx without archiving.

    ``receipt_markdown``, when given, becomes the evidence on BOTH merge paths
    (usp-critique-round3.md Move A — previously local-only): on the **local** path
    it's attached as a ``git notes`` entry on the merge commit; on the **gh** path
    it's folded straight into the PR body at creation (``--title``/``--body``
    instead of ``--fill``), not left behind a manual button. The
    ``POST .../receipt/pr-comment`` endpoint still exists for re-posting after the
    fact (a re-gate, or a PR opened before this wired itself in).

    Every merge commit — local or gh — also gets a ``Verified-by: haro-gate
    <version> <digest>`` trailer appended to ``message``. ``digest`` should be the
    GATE-TIME ``Receipt.digest``/``TestRun.diff_fingerprint`` the caller already
    has (refuter round-3: this function used to recompute a FRESH diff here,
    which could describe a tree that drifted after the gate ran — a checkpoint
    commit or an edit between a green gate and the merge click). Only falls back
    to a fresh diff read when the caller passes none, for a caller that hasn't
    threaded a receipt through yet; best-effort either way, since a digest read
    failure must not block a merge the gate already earned. Cross-references an
    ``haro gate --attest`` statement's subject without needing a signature check
    to do it — the trailer is a content identifier, not a proof by itself; the
    proof is the (optional) signed statement.
    """
    # A workspace continued onto a fresh branch references the PRs it follows, so the
    # merge commit (and thus the PR body built from `message` below) reads "Follow-up
    # to #N." — threading a continued task's PRs together.
    prefix = _followup_prefix(workspace.prior_prs)
    if prefix and not message.lstrip().lower().startswith("follow-up to"):
        message = prefix + message
    # A workspace seeded from a GitHub issue threads "Closes #<n>" into the body so
    # merging the PR auto-closes the issue on GitHub → the next backlog poll flips the
    # row to ✔. Mirrors the follow-up threading above; prepended (so it heads the body)
    # and guarded by substring so a retry — or a commit box the UI already seeded —
    # doesn't double it.
    closes = _closes_prefix(workspace.seed_key)
    if closes and closes.strip().lower() not in message.lower():
        message = closes + message
    # Preflight: the worktree may have been removed/broken out-of-band (e.g. an
    # archive interrupted mid-delete). Don't run git in a husk — heal instead.
    if not git_ops.worktree_valid(workspace.worktree_path):
        if await git_ops.branch_merged(project.path, workspace.branch, workspace.base_ref):
            # Work is already safely in base_ref — finalize the teardown and report
            # success so the caller archives the stale workspace cleanly.
            await git_ops.remove_worktree(project.path, workspace.worktree_path, workspace.branch)
            return {"method": "noop", "pr_url": None, "committed": None,
                    "detail": f"{workspace.branch} was already merged into "
                              f"{workspace.base_ref}; cleaned up the stale workspace"}
        raise RuntimeError(
            "this workspace's worktree is missing or broken (no .git) and its branch "
            "isn't merged: archive it and recreate the workspace"
        )

    # `Verified-by:` trailer (usp-critique-round3.md Move A) — computed from the
    # SAME worktree-vs-base_ref diff the gate itself measured, before commit_all
    # touches anything, so the digest matches what actually earned the green.
    # Best-effort: a digest read failing must never block a merge the gate already
    # earned, so it just omits the trailer rather than raising.
    if "Verified-by: haro-gate" not in message:
        try:
            if digest is None:
                # Fallback only — a caller that hasn't threaded a receipt through.
                # Not gate-time, so this can describe a drifted tree; see the
                # docstring above and prefer passing `digest` whenever possible.
                diff_text, _ = await git_ops.diff(workspace.worktree_path, workspace.base_ref)
                digest = diff_fingerprint(diff_text)
            message = f"{message}\n\nVerified-by: haro-gate {__version__} {digest}"
        except Exception:  # noqa: BLE001 — evidence, not the verdict
            traceback.print_exc()

    # Companion to Closes #n (above): for a todo-seeded workspace, flip the source
    # line's checkbox in the WORKTREE's own copy of the seed file, before the
    # commit, so the tick rides inside this same merge commit — never a separate
    # edit to the main checkout after the fact (that would dirty it and refuse
    # every subsequent local merge via git_ops.is_clean, or race the gh path's
    # next pull against the very line BACKLOG_TICK already ticked on the branch).
    # Best-effort: a missing/renamed item or a write failure must not block a
    # merge the gate already earned — BACKLOG_TICK remains the fallback.
    try:
        settings = load_project_settings(project.path)
        backlog_svc.tick_backlog_item(
            workspace.worktree_path, workspace.seed_key, settings.backlog_dir, settings.backlog_files
        )
    except Exception:  # noqa: BLE001
        traceback.print_exc()

    sha = await git_ops.commit_all(workspace.worktree_path, message)
    # commit_all returns None when there was nothing to stage (already committed
    # by a prior attempt) — still need the current tip for the idempotency check.
    current_sha = sha or await git_ops.rev_parse("HEAD", workspace.worktree_path)

    # Nothing to merge — the branch has no commits beyond its base (the agent made
    # no changes, or the work is already merged elsewhere). Fail with a plain-English
    # message *before* touching gh, which otherwise emits the cryptic "could not find
    # any commits between <base> and <branch>".
    if await git_ops.branch_merged(project.path, workspace.branch, workspace.base_ref):
        raise RuntimeError(
            f"Nothing to merge: this workspace has no changes beyond {workspace.base_ref}. "
            "The agent didn't make any changes, or the work is already merged."
        )

    remote = await git_ops.has_remote(project.path)
    result: dict

    if not remote:
        # -- local merge path --
        await git_ops.local_merge(project.path, workspace.branch, workspace.base_ref, message)
        result = {"method": "local", "pr_url": None,
                  "detail": f"merged {workspace.branch} → {workspace.base_ref} locally"}
        if receipt_markdown:
            try:
                merge_sha = await git_ops.rev_parse("HEAD", project.path)
                await git_ops.add_note(project.path, merge_sha, receipt_markdown)
            except git_ops.GitError:
                # The merge already succeeded — a note is evidence, not the verdict,
                # so a `git notes` hiccup must not turn a real merge into a failure.
                traceback.print_exc()
    elif await _pr_already_merged(workspace.branch, workspace.worktree_path, current_sha):
        # A prior merge landed the PR remotely but failed on local cleanup — just
        # finalize the teardown so the retry succeeds instead of erroring.
        result = {"method": "gh", "pr_url": None,
                  "detail": f"PR for {workspace.branch} was already merged; "
                            f"cleaned up the workspace"}
    else:
        # -- gh PR path --
        # base_ref may be a remote-tracking ref ("origin/main", from Option A) but
        # `gh pr create --base` wants the bare remote branch NAME ("main"), so strip
        # the "origin/" prefix. (Diff/impact keep using the full ref — it's a valid
        # rev there; only gh needs the branch name.)
        base_branch = workspace.base_ref
        if base_branch.startswith("origin/"):
            base_branch = base_branch[len("origin/"):]
        await git_ops.push_branch(workspace.worktree_path, workspace.branch)
        # `--title`/`--body` instead of `--fill` (usp-critique-round3.md Move A):
        # `--fill` autofills both from the branch's commit, which is exactly what
        # we want for the title, but gives the receipt nowhere to go except a
        # follow-up comment. Splitting `message` ourselves keeps the same title
        # `--fill` would have picked (its first line) while making room to fold the
        # Gate Receipt straight into the body at creation time — not behind a
        # manual "post to PR" button.
        pr_title, _, pr_rest = message.partition("\n")
        # `--fill` could never hand `gh` a blank title (a commit always has SOME
        # subject line); `--title` can, if `message` starts with a blank line, and
        # `gh pr create --title ""` doesn't fail client-side — it reaches the
        # GraphQL API and fails there instead (refuter round-3, checked against a
        # real `gh`). Cheap to just not send a blank one.
        pr_title = pr_title.strip() or f"haro: {workspace.branch}"
        pr_body = pr_rest.strip()
        if receipt_markdown:
            pr_body = f"{pr_body}\n\n---\n\n{receipt_markdown}" if pr_body else receipt_markdown
        code, out, err = await _gh(
            "pr", "create", "--title", pr_title, "--body", pr_body,
            "--head", workspace.branch, "--base", base_branch,
            cwd=workspace.worktree_path,
        )
        # `pr create` prints the PR URL on success; if a PR already exists gh says so.
        pr_url = out if out.startswith("http") else None
        if code != 0 and "already exists" not in err.lower():
            raise RuntimeError(f"gh pr create failed: {err or out}")
        # Recover the URL when the PR already existed (create printed no link) so a
        # blocked-merge message below can still point the user at their open PR.
        if not pr_url:
            vcode, vout, _ = await _gh(
                "pr", "view", workspace.branch, "--json", "url", "-q", ".url",
                cwd=workspace.worktree_path,
            )
            if vcode == 0 and vout.startswith("http"):
                pr_url = vout
        # NB: no `--delete-branch` — that flag makes gh switch the local checkout
        # off the merged branch (`git checkout <base>`), which is fatal under
        # worktrees since <base> is already checked out in the main tree. The PR
        # merges fine; we delete the remote branch ourselves (below) and drop the
        # local worktree + branch via remove_worktree.
        mcode, mout, merr = await _gh(
            "pr", "merge", workspace.branch, "--squash",
            cwd=workspace.worktree_path,
        )
        if mcode != 0:
            raise RuntimeError(
                _merge_error(merr or mout, branch=workspace.branch,
                             base_branch=base_branch, pr_url=pr_url)
            )
        await git_ops.delete_remote_branch(workspace.worktree_path, workspace.branch)
        result = {"method": "gh", "pr_url": pr_url, "pr_number": _pr_number(pr_url),
                  "detail": f"opened & merged PR for {workspace.branch}"}

    # NB: we intentionally do NOT archive the worktree here anymore. Merge marks the
    # workspace `merged` (GitHub-style) and leaves the worktree in place; the user
    # decides when to archive (DELETE /workspaces/{id} → remove_worktree). Decoupling
    # merge from teardown lets a merged workspace stay visible + inspectable.
    result["committed"] = sha
    return result
