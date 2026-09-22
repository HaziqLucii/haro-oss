"""Plan Mode is a per-run flag on the adapter, not a fork of the run path.

haro drives Claude Code with ``--permission-mode bypassPermissions`` (full
auto-edit in a throwaway worktree). Plan Mode swaps *that one value* for
``--permission-mode plan`` so the agent produces a plan and edits nothing until
the dev approves — the review surface *before* the first file edit. These tests
pin that the adapter emits the right ``--permission-mode`` value per run and
changes nothing else.
"""

import asyncio

from haro.adapters.claude_code import ClaudeCodeAdapter


class _EmptyStdout:
    """An already-drained stdout: ``async for`` yields nothing, so the run loop
    falls through to synthesizing a terminal event."""

    def __aiter__(self):
        return self

    async def __anext__(self):
        raise StopAsyncIteration


class _EmptyStderr:
    async def read(self):
        return b""


class _FakeProc:
    """A faithful-enough stand-in for ``asyncio.subprocess.Process``: it tracks
    ``returncode`` (None until it exits), which the adapter's process-group teardown
    reads to decide whether there is anything left to kill."""

    def __init__(self):
        self.stdout = _EmptyStdout()
        self.stderr = _EmptyStderr()
        self.returncode = None
        self.pid = -1

    async def wait(self):
        self.returncode = 0
        return 0


def _capture_cmd(plan: bool) -> list[str]:
    """Run the adapter with a stubbed subprocess and return the argv it built."""
    captured: dict[str, list[str]] = {}

    async def fake_exec(*cmd, **_kwargs):
        captured["cmd"] = list(cmd)
        return _FakeProc()

    async def scenario():
        import haro.adapters.claude_code as mod

        orig = mod.asyncio.create_subprocess_exec
        mod.asyncio.create_subprocess_exec = fake_exec
        try:
            adapter = ClaudeCodeAdapter()
            async for _ in adapter.run(task="do a thing", cwd="/tmp/wt", plan=plan):
                pass
        finally:
            mod.asyncio.create_subprocess_exec = orig
        return captured["cmd"]

    return asyncio.run(scenario())


def _permission_mode(cmd: list[str]) -> str | None:
    return cmd[cmd.index("--permission-mode") + 1] if "--permission-mode" in cmd else None


def test_plan_run_uses_permission_mode_plan():
    cmd = _capture_cmd(plan=True)
    assert _permission_mode(cmd) == "plan"
    # Plan replaces auto-edit — it must never emit both.
    assert "bypassPermissions" not in cmd


def test_default_run_stays_bypass_permissions():
    cmd = _capture_cmd(plan=False)
    assert _permission_mode(cmd) == "bypassPermissions"


def test_plan_flag_defaults_off():
    # A run with no mode selected behaves exactly as it does today.
    assert _permission_mode(_capture_cmd(plan=False)) == "bypassPermissions"
