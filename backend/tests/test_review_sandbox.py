"""review.py's sandbox wiring (Move D step 2, usp-critique-round3.md):
`_sandbox_wrap` must fail CLOSED when `[agent] sandbox` is on but bwrap
isn't available, for both one-shot `claude` calls it guards
(`run_review`, `run_plan_compliance`) — same contract as ClaudeCodeAdapter,
verified separately in test_agent_sandbox_wiring.py."""

from __future__ import annotations

import asyncio
import subprocess

from haro import review as review_mod
from haro import sandbox as sandbox_mod


def test_sandbox_wrap_passthrough_when_off():
    cmd = ["claude", "-p", "x"]
    wrapped, err = review_mod._sandbox_wrap(cmd, worktree="/tmp", sandbox=False)
    assert wrapped == cmd
    assert err is None


def test_sandbox_wrap_fails_closed_when_bwrap_missing(monkeypatch):
    monkeypatch.setattr(sandbox_mod, "bwrap_available", lambda: False)
    wrapped, err = review_mod._sandbox_wrap(["claude", "-p", "x"], worktree="/tmp", sandbox=True)
    assert wrapped is None
    assert "bwrap" in err


def test_sandbox_wrap_uses_readonly_no_git_profile(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox_mod, "bwrap_available", lambda: True)
    monkeypatch.setattr(sandbox_mod.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox_mod.os.path, "realpath", lambda p: p)

    wt = str(tmp_path / "wt")
    wrapped, err = review_mod._sandbox_wrap(["claude", "-p", "x"], worktree=wt, sandbox=True)

    assert err is None
    assert wrapped[0] == "bwrap"
    ro_pairs = [(wrapped[i + 1], wrapped[i + 2]) for i, t in enumerate(wrapped) if t == "--ro-bind"]
    bind_pairs = [(wrapped[i + 1], wrapped[i + 2]) for i, t in enumerate(wrapped) if t == "--bind"]
    assert (wt, wt) in ro_pairs  # read-only worktree
    assert (wt, wt) not in bind_pairs  # never writable
    # _sandbox_wrap never accepts a git_dir at all — structurally can't bind one.
    assert "worktrees" not in " ".join(wrapped)


def _repo_with_diff(tmp_path) -> str:
    project = tmp_path / "project"
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.email", "t@example.com"], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.name", "t"], check=True)
    (project / "f.txt").write_text("x\n")
    subprocess.run(["git", "-C", str(project), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(project), "commit", "-q", "-m", "init"], check=True)
    (project / "f.txt").write_text("y\n")
    return str(project)


def test_run_review_fails_closed_when_sandboxed_and_bwrap_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox_mod, "bwrap_available", lambda: False)
    project = _repo_with_diff(tmp_path)

    result = asyncio.run(
        review_mod.run_review(worktree_path=project, base_ref="HEAD", sandbox=True)
    )

    assert result.error is not None
    assert "bwrap" in result.error
    assert result.findings == []


def test_run_plan_compliance_fails_closed_when_sandboxed_and_bwrap_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox_mod, "bwrap_available", lambda: False)
    project = _repo_with_diff(tmp_path)

    result = asyncio.run(
        review_mod.run_plan_compliance(
            worktree_path=project, base_ref="HEAD", task="do a thing", sandbox=True
        )
    )

    assert result.error is not None
    assert "bwrap" in result.error
