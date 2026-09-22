"""Process-group teardown — ONE policy for every subprocess haro owns.

haro supervises three kinds of child process: agents (`claude`), lifecycle shells
(setup / dev servers) and test runners. Each of them spawns its own tree —
``sh → npm → vite → esbuild``, ``claude → git → node`` — and killing only the
process we hold a handle to leaves the grandchildren (the ones actually holding
the port, or still burning tokens) running detached.

So every long-lived child is spawned with ``start_new_session=True`` (it leads its
own process *group*) and torn down through :func:`terminate_tree`: SIGTERM the
group, a short grace, then SIGKILL whatever is left. This module exists because
that policy was implemented once per owner and drifted — the dev-server path had
it, the agent adapter didn't, so every stop/archive/shutdown orphaned a live
`claude`. One helper, imported by both, can't drift.

Import-light on purpose (stdlib only): the agent adapters live under
``adapters/`` and must not pull the service layer in behind them.
"""

from __future__ import annotations

import asyncio
import os
import signal

#: How long a tree gets to exit on SIGTERM before we SIGKILL it. Long enough for a
#: CLI to flush its output, short enough that a stop feels immediate.
GRACE_SECS = 3.0


def signal_tree(proc, sig: int) -> None:
    """Send ``sig`` to a process's whole group (it was spawned with
    ``start_new_session=True``). Falls back to signalling just the process when the
    group is already gone, and no-ops on an exited/absent process."""
    if proc is None or proc.returncode is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), sig)
    except (ProcessLookupError, PermissionError):
        try:
            os.kill(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass


async def terminate_tree(proc, *, grace: float = GRACE_SECS) -> None:
    """SIGTERM a process tree, wait up to ``grace``, then SIGKILL survivors.

    A no-op when the process already exited, so it's safe to call unconditionally
    from a ``finally`` — normal completion costs nothing, and a cancelled or
    crashed owner still takes its children with it.

    A cancellation arriving *during* teardown escalates straight to SIGKILL and
    re-raises: whoever cancelled us wants this gone now, and swallowing the
    cancellation would hide a stop from the caller."""
    if proc is None or proc.returncode is not None:
        return
    signal_tree(proc, signal.SIGTERM)
    try:
        await asyncio.wait_for(proc.wait(), timeout=grace)
    except asyncio.TimeoutError:
        signal_tree(proc, signal.SIGKILL)
    except asyncio.CancelledError:
        signal_tree(proc, signal.SIGKILL)
        raise
