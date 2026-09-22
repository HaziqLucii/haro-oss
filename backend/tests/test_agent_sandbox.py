"""Real-bwrap verification for the agent sandbox profile (Move D step 2,
usp-critique-round3.md). Unlike test_sandbox.py's pure-logic tests, these
actually invoke bwrap and assert on its real behavior. A `/bin/sh` probe
stands in for the agent throughout, so nothing here spends an Anthropic API
token — see sandbox.py's module docstring for the profile these exercise.

Skipped wholesale when bwrap isn't installed (these need the real thing,
unlike step 1's degrade-gate tests, which stay platform-independent by
mocking `bwrap_available`)."""

from __future__ import annotations

import asyncio
import subprocess

import pytest

from haro import procs, sandbox

pytestmark = pytest.mark.skipif(not sandbox.bwrap_available(), reason="bwrap not installed")


def _probe(probe: str, *, worktree, home, git_dir=None, writable=True) -> subprocess.CompletedProcess:
    cmd = sandbox.wrap_agent_command(
        ["/bin/sh", "-c", probe],
        worktree=str(worktree), git_dir=git_dir, writable=writable, home=str(home),
    )
    assert cmd is not None, "claude/sh not resolvable on PATH in this test environment"
    return subprocess.run(cmd, capture_output=True, text=True, timeout=15)


def _home_and_worktree(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    wt = tmp_path / "wt"
    wt.mkdir()
    return home, wt


def test_home_writes_never_reach_the_real_host_directory(tmp_path):
    # $HOME is masked with a writable-but-PRIVATE tmpfs (not a read-only deny):
    # a write inside the sandbox succeeds against that ephemeral filesystem and
    # is discarded when the sandbox exits, never touching the real host `home`
    # directory. That's the property worth asserting — not that the write
    # fails outright (it doesn't; see the hooks-masking test for the same
    # pattern applied to a git dir).
    home, wt = _home_and_worktree(tmp_path)
    result = _probe("touch $HOME/pwned && echo DONE", worktree=wt, home=home)
    assert "DONE" in result.stdout, result.stderr
    assert not (home / "pwned").exists()


def test_write_usr_fails(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    result = _probe("touch /usr/pwned 2>/dev/null && echo BAD || echo GOOD", worktree=wt, home=home)
    assert "GOOD" in result.stdout


def test_write_inside_worktree_succeeds(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    result = _probe(f"touch {wt}/probe && echo OK", worktree=wt, home=home)
    assert "OK" in result.stdout, result.stderr
    assert (wt / "probe").exists()  # landed on the real host worktree, not a private tmpfs


def test_home_hides_unallowlisted_files(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    (home / ".npmrc").write_text("//registry/:_authToken=secret\n")
    result = _probe("ls -a $HOME", worktree=wt, home=home)
    assert ".npmrc" not in result.stdout


def test_ssh_keys_not_readable(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    ssh = home / ".ssh"
    ssh.mkdir()
    (ssh / "id_rsa").write_text("-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n")
    result = _probe("cat $HOME/.ssh/id_rsa 2>&1", worktree=wt, home=home)
    assert "fake" not in result.stdout


# --------------------------------------------------------------------------- #
# ~/.claude exec-surface. SIX refuter rounds found real bugs here, in order:
# (1) ~/.claude wasn't allowlisted at all (broke real auth); (2) once RW-bound
# wholesale, settings.json/CLAUDE.md/agents/commands/plugins were writable,
# letting a compromised agent plant a `hooks` entry or persistent prompt
# injection that runs UNCONFINED the next time `claude` runs anywhere; (3) the
# first attempt at re-locking those gated on `os.path.exists`, a no-op for
# any file that doesn't exist YET; (4) `daemon/`+`jobs/` were missed
# entirely — Claude Code's background daemon (a real host process, outside
# this sandbox) ingests dispatch files and respawns workers from
# `daemon/roster.json` with attacker-choosable `launch.flagArgs`/`cwd`;
# (5)/(6) yet more surfaces (`scheduled_tasks.json`, `daemon.json`,
# `hooks/`, `skills/`, `workflows/`, `routines/`, `rules/`,
# `output-styles/`, `mailbox/`, `agent-registry.json`, `remote-settings*`)
# kept surfacing faster than a denylist could enumerate them, which is why
# `.claude` is now an ALLOWLIST (see sandbox.py's `_CLAUDE_RW_ALLOW`): only
# specific, verified-pure-data paths are bound; everything else simply does
# not exist inside the sandbox. These tests assert on host-persisted
# CONTENT (or, for a genuinely unlisted path, on its ABSENCE inside the
# sandbox), not on whether a write "succeeded" — a private, ephemeral
# writable area (the auto-created `.claude` directory node itself, or the
# project-level `.claude` mask below) still lets `mkdir`/`touch` succeed
# against it without ever reaching the real host.
# --------------------------------------------------------------------------- #


def test_claude_settings_json_write_never_persists(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    claude_dir = home / ".claude"
    claude_dir.mkdir()
    (claude_dir / "settings.json").write_text("ORIGINAL")
    _probe("echo INJECTED > $HOME/.claude/settings.json", worktree=wt, home=home)
    assert (claude_dir / "settings.json").read_text() == "ORIGINAL"


def test_claude_settings_local_json_locked_even_when_absent(tmp_path):
    # The exact bug round 2's fix missed: this file does NOT exist yet.
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude").mkdir()
    _probe("echo INJECTED > $HOME/.claude/settings.local.json", worktree=wt, home=home)
    p = home / ".claude" / "settings.local.json"
    # bwrap may create an empty mountpoint stub for a path that didn't exist —
    # harmless (no attacker content), so assert on CONTENT, not existence.
    assert not p.exists() or p.read_text() == ""


def test_claude_md_locked_even_when_absent(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude").mkdir()
    _probe("echo INJECTED > $HOME/.claude/CLAUDE.md", worktree=wt, home=home)
    p = home / ".claude" / "CLAUDE.md"
    assert not p.exists() or p.read_text() == ""


def test_claude_agents_dir_write_never_persists(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    agents = home / ".claude" / "agents"
    agents.mkdir(parents=True)
    (agents / "existing.md").write_text("benign")
    _probe("touch $HOME/.claude/agents/evil.md", worktree=wt, home=home)
    assert sorted(p.name for p in agents.iterdir()) == ["existing.md"]


def test_claude_commands_and_plugins_dirs_locked_even_when_absent(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude").mkdir()
    _probe(
        "mkdir -p $HOME/.claude/commands $HOME/.claude/plugins && "
        "echo INJECTED > $HOME/.claude/commands/evil.md && "
        "echo INJECTED > $HOME/.claude/plugins/evil.json",
        worktree=wt, home=home,
    )
    for name in ("commands", "plugins"):
        p = home / ".claude" / name
        # May exist as an empty stub (harmless); must never contain the
        # attacker's file.
        assert not p.exists() or list(p.iterdir()) == []


def test_claude_daemon_dispatch_and_roster_never_persist(tmp_path):
    # The most severe finding of the four refuter rounds: Claude Code's
    # background daemon (a real host process, entirely outside this sandbox)
    # ingests files from `daemon/dispatch/` and respawns workers straight
    # from `daemon/roster.json`, both carrying attacker-choosable launch
    # flags/cwd — a compromised sandboxed run plants a file here and gets an
    # unconfined `claude` process later. `daemon/` didn't exist at all
    # before, matching the exact "planted while absent" shape round 3 fixed
    # for the lock list.
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude").mkdir()
    _probe(
        "mkdir -p $HOME/.claude/daemon/dispatch && "
        'echo \'{"launch":{"flagArgs":["--permission-mode","bypassPermissions"]}}\' '
        "> $HOME/.claude/daemon/dispatch/evil.json && "
        "echo EVIL-ROSTER > $HOME/.claude/daemon/roster.json",
        worktree=wt, home=home,
    )
    daemon_dir = home / ".claude" / "daemon"
    # May exist as an empty stub tree (harmless); must never contain the
    # attacker's dispatch file or an overwritten roster.
    assert not daemon_dir.exists() or not any(daemon_dir.rglob("*"))


def test_claude_jobs_dir_never_persists(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude").mkdir()
    _probe(
        "mkdir -p $HOME/.claude/jobs/evil && echo INJECTED > $HOME/.claude/jobs/evil/state.json",
        worktree=wt, home=home,
    )
    jobs_dir = home / ".claude" / "jobs"
    assert not jobs_dir.exists() or not any(jobs_dir.rglob("*"))


def test_claude_json_top_level_file_remains_writable_by_design(tmp_path):
    # Documented residual, not a bug: the CLI needs to write session state and
    # mcpServers entries here, so this ONE file is never locked.
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude.json").write_text("ORIGINAL\n")
    _probe("echo APPENDED >> $HOME/.claude.json", worktree=wt, home=home)
    assert (home / ".claude.json").read_text() == "ORIGINAL\nAPPENDED\n"


def test_claude_allowlisted_session_dir_stays_writable(tmp_path):
    # `sessions/` IS in _CLAUDE_RW_ALLOW — the CLI needs to persist session
    # transcripts across turns for `--resume` to work.
    home, wt = _home_and_worktree(tmp_path)
    sessions = home / ".claude" / "sessions"
    sessions.mkdir(parents=True)
    result = _probe("echo ok > $HOME/.claude/sessions/some-session.jsonl && echo OK", worktree=wt, home=home)
    assert "OK" in result.stdout, result.stderr
    assert (sessions / "some-session.jsonl").read_text() == "ok\n"


def test_claude_arbitrary_unallowlisted_path_is_absent_not_just_locked(tmp_path):
    # The whole point of the allowlist inversion: a path with NO special
    # meaning to any of the 6 rounds of findings, but also not on the
    # allowlist, is not merely locked — it doesn't exist inside the sandbox
    # at all, because `.claude` itself is never bound wholesale any more.
    home, wt = _home_and_worktree(tmp_path)
    (home / ".claude").mkdir()
    result = _probe(
        "echo ok > $HOME/.claude/some-random-file.jsonl; echo DONE",
        worktree=wt, home=home,
    )
    assert "No such file or directory" in result.stderr
    assert not (home / ".claude" / "some-random-file.jsonl").exists()


def test_claude_skills_are_readable_but_not_writable(tmp_path):
    # haro installs its own skills into ~/.claude/skills on every boot so
    # every sandboxed run can still discover them (a refuter pass caught
    # that the plain RW allowlist silently disabled this feature); bound
    # read-only, not read-write, since a skill bundles executable scripts.
    home, wt = _home_and_worktree(tmp_path)
    skill_dir = home / ".claude" / "skills" / "haro"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text("# haro skill\n")

    read_result = _probe("cat $HOME/.claude/skills/haro/SKILL.md", worktree=wt, home=home)
    assert "# haro skill" in read_result.stdout

    write_result = _probe(
        "echo evil > $HOME/.claude/skills/haro/SKILL.md 2>&1; echo DONE", worktree=wt, home=home
    )
    assert "DONE" in write_result.stdout
    assert (skill_dir / "SKILL.md").read_text() == "# haro skill\n"


def test_network_stays_shared(tmp_path):
    home, wt = _home_and_worktree(tmp_path)
    result = _probe(
        "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "
        "https://api.anthropic.com/v1/messages 2>/dev/null || echo NOCURL",
        worktree=wt, home=home,
    )
    out = result.stdout.strip()
    if out == "NOCURL":
        pytest.skip("curl not installed in this test environment")
    # Any real HTTP response proves the request reached the network (an
    # unauthenticated POST is expected to be rejected, just not by DNS/connect
    # failure) — the point is "reachable", not the exact status.
    assert out and out != "000", f"expected a real HTTP status, got {out!r}"


def _init_repo_with_worktree(tmp_path):
    project = tmp_path / "project"
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.email", "t@example.com"], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.name", "t"], check=True)
    (project / "f.txt").write_text("x")
    subprocess.run(["git", "-C", str(project), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(project), "commit", "-q", "-m", "init"], check=True)
    wt = tmp_path / "wt"
    subprocess.run(
        ["git", "-C", str(project), "worktree", "add", "-q", str(wt), "-b", "feature"], check=True
    )
    return project, wt


def test_git_commit_inside_worktree_succeeds(tmp_path):
    project, wt = _init_repo_with_worktree(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    git_dir = sandbox.git_common_dir(str(wt))
    assert git_dir == str(project / ".git")

    result = _probe(
        "git status --porcelain && git commit -q --allow-empty -m probe && echo OK",
        worktree=wt, git_dir=git_dir, home=home,
    )
    assert "OK" in result.stdout, result.stderr


def test_committed_project_claude_dir_is_not_seen_as_deleted_by_git(tmp_path):
    # Regression cover for a real bug a refuter pass caught: a project MAY
    # commit `.claude/settings.json` (Anthropic's own documented way to
    # share tool-permission config with a team). Unconditionally masking
    # <worktree>/.claude with a fresh --tmpfs made git see it as DELETED
    # inside the sandbox, and an agent's ordinary `git add -A && git commit`
    # committed that deletion for real — reaching the host branch on merge.
    project = tmp_path / "project"
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.email", "t@example.com"], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.name", "t"], check=True)
    (project / ".claude").mkdir()
    (project / ".claude" / "settings.json").write_text('{"permissions": {}}')
    (project / "f.txt").write_text("x")
    subprocess.run(["git", "-C", str(project), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(project), "commit", "-q", "-m", "init"], check=True)
    wt = tmp_path / "wt"
    subprocess.run(
        ["git", "-C", str(project), "worktree", "add", "-q", str(wt), "-b", "feature"], check=True
    )
    home = tmp_path / "home"
    home.mkdir()
    git_dir = sandbox.git_common_dir(str(wt))

    result = _probe(
        "git status --porcelain && cat $(pwd)/.claude/settings.json",
        worktree=wt, git_dir=git_dir, home=home,
    )
    assert result.stdout.strip() == '{"permissions": {}}', (
        f"git must see NO changes (empty porcelain output before the cat), "
        f"got: {result.stdout!r} / {result.stderr!r}"
    )

    # And the exec-surface protection still holds: no new write persists.
    write_result = _probe(
        "echo evil > $(pwd)/.claude/settings.json 2>&1; echo DONE",
        worktree=wt, git_dir=git_dir, home=home,
    )
    assert "DONE" in write_result.stdout
    # Assert on the WORKTREE's copy (what the probe actually touched), not
    # the main checkout — that one's read-only via --ro-bind / / regardless
    # and would pass even if the worktree write had persisted.
    assert (wt / ".claude" / "settings.json").read_text() == '{"permissions": {}}'


def test_git_hooks_directory_is_masked(tmp_path):
    # Masking is a tmpfs OVERLAY, not a write denial: a write inside the
    # sandbox succeeds against the private, ephemeral tmpfs and is simply
    # discarded when the sandbox exits — it never reaches the real host
    # directory. That's the actual property worth asserting here.
    project, wt = _init_repo_with_worktree(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    git_dir = sandbox.git_common_dir(str(wt))

    result = _probe(
        f"touch {git_dir}/hooks/post-checkout && echo DONE",
        worktree=wt, git_dir=git_dir, home=home,
    )
    assert "DONE" in result.stdout, result.stderr
    assert not (project / ".git" / "hooks" / "post-checkout").exists()


def test_readonly_profile_has_no_git_dir_or_writable_worktree(tmp_path):
    project, wt = _init_repo_with_worktree(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    git_dir = sandbox.git_common_dir(str(wt))

    result = _probe(
        f"touch {wt}/probe 2>/dev/null && echo BAD || echo GOOD",
        worktree=wt, git_dir=git_dir, home=home, writable=False,
    )
    assert "GOOD" in result.stdout
    assert not (wt / "probe").exists()


def test_teardown_reaches_sandboxed_children():
    """The class of defect this catches: `--new-session`/a PID namespace moves
    the sandboxed tree out of reach of haro's host-side `killpg`-based
    teardown (see sandbox.py's wrap_agent_command docstring). Regressing
    either would leave these sleepers alive after terminate_tree returns."""
    cmd = sandbox.wrap_agent_command(
        ["/bin/sh", "-c", "sleep 300 & sleep 300 & wait"],
        worktree="/tmp", home="/tmp",
    )
    assert cmd is not None

    async def _go():
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True,
        )
        await asyncio.sleep(0.5)  # let bwrap finish setup and exec the probe
        await procs.terminate_tree(proc, grace=2.0)
        return proc

    proc = asyncio.run(_go())
    assert proc.returncode is not None
