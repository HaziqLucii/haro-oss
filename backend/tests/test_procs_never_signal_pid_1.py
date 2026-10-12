"""``signal_tree`` must never send a signal to pid -1, 0 or 1.

``os.kill(-1, sig)`` signals every process the user owns: it closed the whole desktop session
(a black screen, then every app gone). ``os.getpgid(-1)`` raises ProcessLookupError, which sent
a fake or stale pid of -1 into the single-process fallback. Both signal calls are replaced by
recorders here, so this test cannot signal anything itself.
"""

from __future__ import annotations

import asyncio
import signal

import pytest

from haro import procs


class _Proc:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None

    async def wait(self):
        self.returncode = 0
        return 0


@pytest.fixture
def sent(monkeypatch):
    calls: list[tuple[str, int, int]] = []
    monkeypatch.setattr(procs.os, "kill", lambda pid, sig: calls.append(("kill", pid, sig)))
    monkeypatch.setattr(procs.os, "killpg", lambda pg, sig: calls.append(("killpg", pg, sig)))
    return calls


@pytest.mark.parametrize("pid", [-1, 0, 1, -42, None, "7"])
def test_a_pid_that_is_not_a_real_child_is_never_signalled(sent, pid):
    procs.signal_tree(_Proc(pid), signal.SIGTERM)
    procs.signal_tree(_Proc(pid), signal.SIGKILL)
    assert sent == []


@pytest.mark.parametrize("pid", [-1, 0, 1])
def test_terminating_a_fake_process_signals_nothing(sent, pid):
    asyncio.run(procs.terminate_tree(_Proc(pid), grace=0.05))
    assert sent == []


def test_a_real_child_still_gets_its_group_signalled(sent, monkeypatch):
    monkeypatch.setattr(procs.os, "getpgid", lambda pid: 4242)
    procs.signal_tree(_Proc(4242), signal.SIGTERM)
    assert sent == [("killpg", 4242, signal.SIGTERM)]


def test_a_gone_group_falls_back_to_the_one_process(sent, monkeypatch):
    def gone(pid):
        raise ProcessLookupError

    monkeypatch.setattr(procs.os, "getpgid", gone)
    procs.signal_tree(_Proc(4242), signal.SIGTERM)
    assert sent == [("kill", 4242, signal.SIGTERM)]
