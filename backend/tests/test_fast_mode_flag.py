"""Fast Mode is a per-run flag on the adapter, not a fork of the run path.

There is NO ``--fast`` CLI flag: fast mode is a persisted ``fastMode`` *setting*
(the REPL's ``/fast`` toggle). haro injects it per-run as an inline ``--settings``
source — ``--settings '{"fastMode":true}'`` — which layers on top of the user's
real settings without persisting them (verified against Claude Code v2.1.214: this
flips the session's ``fast_mode_state`` "off"→"on"). These tests pin that the
adapter emits that exact invocation only when ``fast`` is set, and that fast is
orthogonal to plan (it does NOT touch ``--permission-mode``).
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
    """See test_plan_mode_flag._FakeProc — ``returncode`` matters because the adapter's
    ``finally`` reads it to decide whether the process group still needs killing."""

    def __init__(self):
        self.stdout = _EmptyStdout()
        self.stderr = _EmptyStderr()
        self.returncode = None
        self.pid = -1

    async def wait(self):
        self.returncode = 0
        return 0


def _capture_cmd(**run_kwargs) -> list[str]:
    """Run the adapter with a stubbed subprocess and return the argv it built."""
    captured: dict[str, list[str]] = {}

    async def fake_exec(*cmd, **_kwargs):
        captured["cmd"] = list(cmd)
        return _FakeProc()

    async def scenario():
        import haro.adapters.claude_code as mod

        orig = mod.asyncio.create_subprocess_exec
        orig_which = mod.shutil.which
        mod.asyncio.create_subprocess_exec = fake_exec
        # CI runners don't have the real `claude` CLI on PATH — the adapter's
        # own shutil.which guard would otherwise short-circuit before ever
        # reaching create_subprocess_exec, leaving `captured` empty.
        mod.shutil.which = lambda name: "/usr/bin/" + name
        try:
            adapter = ClaudeCodeAdapter()
            async for _ in adapter.run(task="do a thing", cwd="/tmp/wt", **run_kwargs):
                pass
        finally:
            mod.asyncio.create_subprocess_exec = orig
            mod.shutil.which = orig_which
        return captured["cmd"]

    return asyncio.run(scenario())


def _settings_value(cmd: list[str]) -> str | None:
    return cmd[cmd.index("--settings") + 1] if "--settings" in cmd else None


def test_fast_run_injects_fastmode_settings():
    cmd = _capture_cmd(fast=True)
    assert _settings_value(cmd) == '{"fastMode":true}'


def test_default_run_has_no_settings_flag():
    # A run with no mode selected behaves exactly as it does today — no --settings.
    cmd = _capture_cmd(fast=False)
    assert "--settings" not in cmd


def test_fast_flag_defaults_off():
    # Omitting `fast` entirely is the same as fast=False (no --settings emitted).
    assert "--settings" not in _capture_cmd()


def test_fast_is_orthogonal_to_permission_mode():
    # Fast tweaks a *setting*, not the permission mode: a fast (non-plan) run still
    # runs in auto-edit (bypassPermissions), never plan mode.
    cmd = _capture_cmd(fast=True)
    assert cmd[cmd.index("--permission-mode") + 1] == "bypassPermissions"


def test_plan_run_does_not_inject_fastmode():
    # Plan and fast are mutually exclusive in the UI; a plan-only run must not
    # carry the fast setting.
    cmd = _capture_cmd(plan=True)
    assert "--settings" not in cmd
    assert cmd[cmd.index("--permission-mode") + 1] == "plan"
