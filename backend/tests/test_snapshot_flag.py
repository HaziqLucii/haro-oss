"""A resumed claude session replays the system prompt it recorded, so haro turns the snapshot
off on resume (only when the installed CLI knows the flag)."""

import asyncio

from haro.adapters import claude_code


def test_off_when_the_cli_lists_the_flag(monkeypatch):
    monkeypatch.setattr(claude_code, "_SNAPSHOT_FLAG", True)
    assert asyncio.run(claude_code._snapshot_off_args()) == ["--system-prompt-snapshot", "off"]


def test_nothing_when_the_cli_does_not_know_it(monkeypatch):
    monkeypatch.setattr(claude_code, "_SNAPSHOT_FLAG", False)
    assert asyncio.run(claude_code._snapshot_off_args()) == []


def test_probe_reads_help_once(monkeypatch):
    monkeypatch.setattr(claude_code, "_SNAPSHOT_FLAG", None)
    calls = []

    class _Proc:
        async def communicate(self):
            return b"Options:\n  --system-prompt-snapshot <on|off>  ...", None

    async def fake_exec(*argv, **kw):
        calls.append(argv)
        return _Proc()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)

    async def twice():
        return await claude_code._snapshot_off_args(), await claude_code._snapshot_off_args()

    a, b = asyncio.run(twice())
    assert a == b == ["--system-prompt-snapshot", "off"]
    assert len(calls) == 1 and calls[0][:2] == ("claude", "--help")


def test_a_failed_probe_means_no_flag(monkeypatch):
    monkeypatch.setattr(claude_code, "_SNAPSHOT_FLAG", None)

    async def boom(*argv, **kw):
        raise FileNotFoundError("claude")

    monkeypatch.setattr(asyncio, "create_subprocess_exec", boom)
    assert asyncio.run(claude_code._snapshot_off_args()) == []
