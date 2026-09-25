"""Linux-first sandboxing, step 1 (usp-critique-round3.md Move D). Pure-logic
tests only — the actual sandboxed subprocess behavior has NOT been verified
against a real `bwrap` on Linux (developed on macOS, where bwrap doesn't
exist at all; see sandbox.py's module docstring). What IS tested here: the
availability gate, the command-wrapping shape, the profile hash, and that
VitestAdapter only claims `sandboxed=True` when both requested AND available.
"""

from __future__ import annotations

import asyncio
import os

from haro import sandbox
from haro.adapters.test_runner import vitest as vitest_mod
from haro.adapters.test_runner.vitest import VitestAdapter


def test_bwrap_available_reflects_path(monkeypatch):
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/bwrap" if name == "bwrap" else None)
    assert sandbox.bwrap_available() is True
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: None)
    assert sandbox.bwrap_available() is False


def test_profile_hash_is_stable_and_distinguishes_network_setting():
    a = sandbox.profile_hash(network=False)
    b = sandbox.profile_hash(network=False)
    c = sandbox.profile_hash(network=True)
    assert a == b
    assert a != c
    assert len(a) == 16  # short identity, not a security hash — see docstring


def test_wrap_command_denies_network_and_preserves_the_original_command():
    wrapped = sandbox.wrap_command(["vitest", "run"])
    assert wrapped[0] == "bwrap"
    assert "--unshare-net" in wrapped
    assert wrapped[-2:] == ["vitest", "run"]  # the original command, untouched, at the end
    assert wrapped.count("--") >= 1  # bwrap's own args/command separator present


class _FakeStream:
    def __init__(self):
        self._sent = False

    async def readline(self):
        if self._sent:
            return b""
        self._sent = True
        return b""  # immediate EOF: nothing to parse, only the invoked argv matters here

    async def read(self):
        return b""


class _FakeProc:
    stdout = _FakeStream()
    stderr = _FakeStream()
    returncode = 0

    async def wait(self):
        return 0

    def kill(self):
        pass


def _capture_exec(monkeypatch):
    captured: dict = {}

    async def fake_exec(*cmd, **kwargs):
        captured["cmd"] = cmd
        return _FakeProc()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    return captured


def test_vitest_adapter_wraps_with_bwrap_when_requested_and_available(monkeypatch, tmp_path):
    captured = _capture_exec(monkeypatch)
    monkeypatch.setattr(vitest_mod.sandbox_mod, "bwrap_available", lambda: True)

    adapter = VitestAdapter(sandbox=True)
    asyncio.run(adapter.run(cwd=str(tmp_path)))

    assert captured["cmd"][0] == "bwrap"
    assert "--unshare-net" in captured["cmd"]


def test_vitest_adapter_does_not_wrap_when_bwrap_unavailable(monkeypatch, tmp_path):
    captured = _capture_exec(monkeypatch)
    monkeypatch.setattr(vitest_mod.sandbox_mod, "bwrap_available", lambda: False)

    adapter = VitestAdapter(sandbox=True)  # requested, but not available
    asyncio.run(adapter.run(cwd=str(tmp_path)))

    assert captured["cmd"][0] != "bwrap"


def test_vitest_adapter_does_not_wrap_when_not_requested(monkeypatch, tmp_path):
    captured = _capture_exec(monkeypatch)
    monkeypatch.setattr(vitest_mod.sandbox_mod, "bwrap_available", lambda: True)  # available, but not asked for

    adapter = VitestAdapter(sandbox=False)
    asyncio.run(adapter.run(cwd=str(tmp_path)))

    assert captured["cmd"][0] != "bwrap"


def test_result_sandboxed_flag_only_true_when_both_requested_and_available(monkeypatch, tmp_path):
    # Uses the `only`-scoped path (returns early with ok=True, total=0) so a
    # single fake EOF stream is enough — this test cares about TestResult's
    # flags, not the full NDJSON parse.
    _capture_exec(monkeypatch)
    monkeypatch.setattr(vitest_mod.sandbox_mod, "bwrap_available", lambda: True)

    adapter = VitestAdapter(sandbox=True)
    result = asyncio.run(adapter.run(cwd=str(tmp_path), only=[("a.test.ts", "x")]))
    assert result.sandboxed is True
    assert result.sandbox_profile == sandbox.profile_hash(network=False)

    monkeypatch.setattr(vitest_mod.sandbox_mod, "bwrap_available", lambda: False)
    adapter2 = VitestAdapter(sandbox=True)
    result2 = asyncio.run(adapter2.run(cwd=str(tmp_path), only=[("a.test.ts", "x")]))
    assert result2.sandboxed is False
    assert result2.sandbox_profile is None


# --------------------------------------------------------------------------- #
# Step 2 — the agent profile (usp-critique-round3.md Move D). Pure-logic tests
# only here too; real-bwrap behavior is exercised in test_agent_sandbox.py.
# --------------------------------------------------------------------------- #


def test_agent_profile_hash_is_stable_and_distinct_from_test_profile():
    a = sandbox.agent_profile_hash()
    b = sandbox.agent_profile_hash()
    assert a == b
    assert len(a) == 16
    assert a != sandbox.profile_hash(network=False)
    assert a != sandbox.profile_hash(network=True)


def test_git_common_dir_resolves_a_linked_worktree(tmp_path):
    project = tmp_path / "project"
    worktrees_dir = project / ".git" / "worktrees" / "feature"
    worktrees_dir.mkdir(parents=True)
    wt = tmp_path / "wt"
    wt.mkdir()
    (wt / ".git").write_text(f"gitdir: {worktrees_dir}\n")

    assert sandbox.git_common_dir(str(wt)) == str(project / ".git")


def test_git_common_dir_is_none_for_a_plain_git_directory(tmp_path):
    wt = tmp_path / "wt"
    (wt / ".git").mkdir(parents=True)  # a real (non-worktree) repo: .git is a dir

    assert sandbox.git_common_dir(str(wt)) is None


def test_git_common_dir_is_none_when_git_is_missing(tmp_path):
    assert sandbox.git_common_dir(str(tmp_path / "nope")) is None


def _pairs_after(argv: list[str], flag: str) -> list[tuple[str, str]]:
    """Every (SRC, DEST) pair following an occurrence of a two-arg bwrap flag —
    ``argv`` repeats a flag like ``--ro-bind`` for the root bind AND per-path
    binds, so tests need every occurrence, not just the first."""
    out = []
    for i, tok in enumerate(argv):
        if tok == flag:
            out.append((argv[i + 1], argv[i + 2]))
    return out


def test_wrap_agent_command_returns_none_when_binary_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: None)
    assert sandbox.wrap_agent_command(["claude"], worktree=str(tmp_path)) is None


def test_wrap_agent_command_shape(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)

    wrapped = sandbox.wrap_agent_command(
        ["claude", "-p", "hi"], worktree=str(tmp_path / "wt"), home=str(home)
    )

    assert wrapped[0] == "bwrap"
    # Network stays shared.
    assert "--unshare-net" not in wrapped
    # No --new-session, no PID/all namespace unshare: teardown-safety (see docstring).
    assert "--new-session" not in wrapped
    assert "--unshare-pid" not in wrapped
    assert "--unshare-all" not in wrapped
    # Default-deny $HOME (a bare --tmpfs <home>, distinct from /tmp's), and the
    # process's own $HOME env var must match what's actually mounted/allowlisted
    # — bwrap doesn't infer this, and a mismatch here is exactly the bug a real
    # bwrap run caught (see test_agent_sandbox.py's history / this module's
    # wrap_agent_command docstring).
    assert str(home) in wrapped
    assert ("HOME", str(home)) in _pairs_after(wrapped, "--setenv")
    assert wrapped.count("--tmpfs") >= 2  # /tmp and $HOME at least
    assert (str(tmp_path / "wt"), str(tmp_path / "wt")) in _pairs_after(wrapped, "--bind")
    assert wrapped[-3:] == ["claude", "-p", "hi"]
    assert wrapped[-4] == "--"


def test_wrap_agent_command_readonly_worktree_when_not_writable(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)
    wt = str(tmp_path / "wt")

    wrapped = sandbox.wrap_agent_command(
        ["claude"], worktree=wt, writable=False, home=str(tmp_path / "home")
    )

    assert (wt, wt) in _pairs_after(wrapped, "--ro-bind")
    assert (wt, wt) not in _pairs_after(wrapped, "--bind")


def test_wrap_agent_command_claude_dir_is_allowlist_not_denylist(monkeypatch, tmp_path):
    # Regression cover for the structural fix after FIVE refuter rounds each
    # found a new exec-capable surface under ~/.claude (settings.json hooks,
    # agents/commands/plugins, daemon dispatch+roster, scheduled_tasks.json,
    # hooks/skills/workflows/routines/rules/output-styles, mailbox,
    # agent-registry, remote-settings...): the profile no longer binds
    # `.claude` wholesale and re-locks the dangerous parts (a denylist that
    # has to be complete to be correct); it binds ONLY the specific
    # known-pure-data paths in _CLAUDE_RW_ALLOW. Anything else — including
    # paths this test deliberately creates to prove they're NOT bound —
    # simply never appears in argv at all.
    home = tmp_path / "home"
    claude_dir = home / ".claude"
    claude_dir.mkdir(parents=True)
    (claude_dir / "sessions").mkdir()  # allowlisted
    (claude_dir / ".credentials.json").write_text("{}")  # allowlisted
    (claude_dir / "settings.json").write_text("{}")  # NOT allowlisted
    (claude_dir / "agents").mkdir()  # NOT allowlisted
    (claude_dir / "daemon").mkdir()  # NOT allowlisted
    (claude_dir / "scheduled_tasks.json").write_text("{}")  # NOT allowlisted
    (home / ".claude.json").write_text("{}")
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)

    wrapped = sandbox.wrap_agent_command(["claude"], worktree=str(tmp_path / "wt"), home=str(home))

    for allowed in ("sessions", ".credentials.json"):
        p = str(claude_dir / allowed)
        assert (p, p) in _pairs_after(wrapped, "--bind-try")
    for not_allowed in ("settings.json", "agents", "daemon", "scheduled_tasks.json"):
        p = str(claude_dir / not_allowed)
        assert p not in wrapped, f"{not_allowed} must never appear in argv at all"
    # ~/.claude.json (the top-level FILE, not the directory) IS bound —
    # documented as a real, unclosed residual (mcpServers spawns commands).
    claude_json = str(home / ".claude.json")
    assert (claude_json, claude_json) in _pairs_after(wrapped, "--bind-try")


def test_wrap_agent_command_binds_claude_skills_readonly(monkeypatch, tmp_path):
    # haro installs its own `haro`/`haro-dev` skills into ~/.claude/skills on
    # every boot (haro_skill.py) so every agent run discovers them — a
    # refuter pass caught that the plain RW allowlist silently disabled this
    # under sandboxing (skills/ isn't pure data, so it's deliberately NOT in
    # _CLAUDE_RW_ALLOW). Bound read-only instead: discoverable, not writable
    # (a skill bundles executable scripts, so RW would reopen the exact
    # class of hole the allowlist inversion exists to close).
    home = tmp_path / "home"
    skills = home / ".claude" / "skills"
    skills.mkdir(parents=True)
    (skills / "haro" / "SKILL.md").parent.mkdir(parents=True)
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)

    wrapped = sandbox.wrap_agent_command(["claude"], worktree=str(tmp_path / "wt"), home=str(home))

    assert (str(skills), str(skills)) in _pairs_after(wrapped, "--ro-bind-try")
    assert (str(skills), str(skills)) not in _pairs_after(wrapped, "--bind-try")


def test_wrap_agent_command_masks_project_level_claude_dir(monkeypatch, tmp_path):
    # The SECOND surface a refuter pass found: <worktree>/.claude (a normal,
    # gitignored part of the repo) would otherwise be exposed read-write by
    # the whole-worktree bind, the same class of file Claude Code's own
    # denylist masks at both the home root and the cwd root.
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)
    wt = str(tmp_path / "wt")

    wrapped = sandbox.wrap_agent_command(["claude"], worktree=wt, home=str(tmp_path / "home"))

    wt_bind_idx = wrapped.index(wt)
    mask_path = os.path.join(wt, ".claude")
    mask_idx = wrapped.index(mask_path)
    assert mask_idx > wt_bind_idx, "the mask must come AFTER the worktree bind"
    assert wrapped[mask_idx - 1] == "--tmpfs"


def test_wrap_agent_command_preserves_existing_project_claude_readonly(monkeypatch, tmp_path):
    # Regression cover for a real bug a refuter pass caught with actual git:
    # a project MAY commit `.claude/settings.json` (Anthropic's own
    # documented way to share tool-permission config with a team) —
    # unconditionally `--tmpfs`-masking an EXISTING `.claude/` makes git see
    # it as deleted inside the sandbox, and an agent's ordinary `git commit`
    # then commits that deletion for real. When the worktree already has a
    # `.claude/`, it must be re-bound READ-ONLY (preserved, not masked) —
    # `--tmpfs` is reserved for the case where nothing exists yet to lose.
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)
    wt = tmp_path / "wt"
    project_claude = wt / ".claude"
    project_claude.mkdir(parents=True)
    (project_claude / "settings.json").write_text('{"permissions": {}}')

    wrapped = sandbox.wrap_agent_command(
        ["claude"], worktree=str(wt), home=str(tmp_path / "home")
    )

    assert (str(project_claude), str(project_claude)) in _pairs_after(wrapped, "--ro-bind-try")
    assert str(project_claude) not in [
        wrapped[i + 1] for i, t in enumerate(wrapped) if t == "--tmpfs"
    ]


def test_wrap_agent_command_does_not_mask_project_claude_when_readonly(monkeypatch, tmp_path):
    # writable=False (review.py's profile) already ro-binds the whole
    # worktree — masking .claude there would be redundant, not wrong, but
    # the implementation skips it, so pin that the extra --tmpfs isn't added.
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)
    wt = str(tmp_path / "wt")

    wrapped = sandbox.wrap_agent_command(
        ["claude"], worktree=wt, writable=False, home=str(tmp_path / "home")
    )

    assert os.path.join(wt, ".claude") not in wrapped


def test_wrap_agent_command_binds_git_common_dir_and_masks_hooks(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)
    git_dir = str(tmp_path / "project" / ".git")

    wrapped = sandbox.wrap_agent_command(
        ["claude"], worktree=str(tmp_path / "wt"), git_dir=git_dir, home=str(tmp_path / "home")
    )

    assert git_dir in wrapped
    assert f"{git_dir}/hooks" in wrapped


def test_wrap_agent_command_skips_git_dir_when_not_writable(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/claude")
    monkeypatch.setattr(sandbox.os.path, "realpath", lambda p: p)
    git_dir = str(tmp_path / "project" / ".git")

    wrapped = sandbox.wrap_agent_command(
        ["claude"], worktree=str(tmp_path / "wt"), git_dir=git_dir,
        writable=False, home=str(tmp_path / "home"),
    )

    assert git_dir not in wrapped
