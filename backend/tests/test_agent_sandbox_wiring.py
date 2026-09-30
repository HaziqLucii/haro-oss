"""ClaudeCodeAdapter's sandbox wiring (Move D step 2, usp-critique-round3.md):
`sandbox=True` wraps the command in bwrap; `bwrap` missing must FAIL CLOSED
(an error event, no subprocess spawned) rather than silently running
unsandboxed — the opposite of the test gate's sandbox, which degrades open.
See sandbox.py's module docstring for why. Pure-logic/mocked only, mirroring
test_plan_mode_flag.py's fixtures; real-bwrap behavior lives in
test_agent_sandbox.py."""

from __future__ import annotations

import asyncio

from haro.adapters.claude_code import ClaudeCodeAdapter


class _EmptyStdout:
    def __aiter__(self):
        return self

    async def __anext__(self):
        raise StopAsyncIteration


class _EmptyStderr:
    async def read(self):
        return b""


class _FakeProc:
    def __init__(self):
        self.stdout = _EmptyStdout()
        self.stderr = _EmptyStderr()
        self.returncode = None
        self.pid = -1

    async def wait(self):
        self.returncode = 0
        return 0


def _run(monkeypatch, *, sandbox: bool, bwrap_available: bool, which=None):
    """Drive ClaudeCodeAdapter.run() with subprocess exec stubbed out and
    sandbox availability mocked. Returns (events, captured_cmd_or_None)."""
    import haro.adapters.claude_code as mod

    captured: dict[str, list[str]] = {}

    async def fake_exec(*cmd, **_kwargs):
        captured["cmd"] = list(cmd)
        return _FakeProc()

    def fake_which(name):
        if which is not None:
            return which(name)
        return "/usr/bin/claude" if name == "claude" else None

    monkeypatch.setattr(mod.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(mod.shutil, "which", fake_which)
    monkeypatch.setattr(mod.sandbox_mod, "bwrap_available", lambda: bwrap_available)
    if bwrap_available:
        # wrap_agent_command itself also calls shutil.which(cmd[0]) internally
        # (sandbox_mod.shutil, a separate import) — keep both in sync.
        import haro.sandbox as sandbox_module
        monkeypatch.setattr(sandbox_module.shutil, "which", fake_which)

    async def scenario():
        adapter = ClaudeCodeAdapter(sandbox=sandbox)
        events = []
        async for ev in adapter.run(task="do a thing", cwd="/tmp/wt"):
            events.append(ev)
        return events

    events = asyncio.run(scenario())
    return events, captured.get("cmd")


def test_sandbox_off_runs_unwrapped(monkeypatch):
    events, cmd = _run(monkeypatch, sandbox=False, bwrap_available=True)
    assert cmd is not None
    assert cmd[0] == "claude"
    assert not any(ev.type == "error" for ev in events)


def test_sandbox_on_and_available_wraps_with_bwrap(monkeypatch):
    events, cmd = _run(monkeypatch, sandbox=True, bwrap_available=True)
    assert cmd is not None
    assert cmd[0] == "bwrap"
    assert "claude" in cmd
    assert not any(ev.type == "error" for ev in events)


def test_sandbox_on_but_bwrap_missing_fails_closed(monkeypatch):
    events, cmd = _run(monkeypatch, sandbox=True, bwrap_available=False)
    # Must NOT spawn a subprocess at all — an unsandboxed bypassPermissions
    # run is exactly the outcome this flag exists to prevent.
    assert cmd is None
    assert len(events) == 1
    assert events[0].type == "error"
    assert "sandbox" in events[0].payload["message"]
    assert "bwrap" in events[0].payload["message"]


def test_claude_missing_from_path_errors_before_spawn_even_when_sandboxed(monkeypatch):
    events, cmd = _run(
        monkeypatch, sandbox=True, bwrap_available=True, which=lambda name: None
    )
    assert cmd is None
    assert len(events) == 1
    assert events[0].type == "error"
    assert "claude" in events[0].payload["message"].lower()


def test_claude_missing_from_path_errors_when_not_sandboxed(monkeypatch):
    events, cmd = _run(
        monkeypatch, sandbox=False, bwrap_available=False, which=lambda name: None
    )
    assert cmd is None
    assert len(events) == 1
    assert events[0].type == "error"
