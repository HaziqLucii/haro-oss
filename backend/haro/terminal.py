"""Interactive terminal — a real PTY per workspace, streamed over a WebSocket.

The whole point of haro is to be the one window a developer works in, so a
worktree isn't much use without a shell in it. We spawn the user's `$SHELL` on a
pseudo-terminal rooted at the worktree (with the workspace's HARO_* env),
pump its output to the browser (xterm.js), and write keystrokes back. Local,
single-user, full access — same trust model as the rest of the app.
"""

from __future__ import annotations

import asyncio
import fcntl
import os
import pwd
import shutil
import struct
import termios
from pathlib import Path

#: A small bash rc bundled with the backend that gives the embedded terminal a
#: colored prompt + color aliases + a sane TERM (the container has no user rc).
_TERMINAL_RC = Path(__file__).resolve().parent / "assets" / "terminal_rc.sh"

#: setsid(1) from util-linux. We front the shell with `setsid --ctty` to give it
#: a controlling terminal (see spawn_shell) — the reliable, event-loop-agnostic
#: way to do it, since uvloop (uvicorn's loop) silently ignores subprocess
#: preexec_fn. None on platforms without it (e.g. macOS) → preexec_fn fallback.
_SETSID = shutil.which("setsid")

def set_winsize(fd: int, rows: int, cols: int) -> None:
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def _with_identity(env: dict[str, str]) -> dict[str, str]:
    """Make sure the shell sees a coherent USER/LOGNAME/HOME.

    A bare ``bash -i`` (non-login) doesn't export USER/LOGNAME from passwd the way a
    login shell would, so fill them in from the OS's own passwd entry when the parent
    environment is missing them, so the prompt and any tool reading ``$USER``/``$HOME``
    behave.
    """
    try:
        pw = pwd.getpwuid(os.getuid())
        name, home = pw.pw_name, pw.pw_dir
    except KeyError:
        name, home = env.get("USER") or "haro", env.get("HOME") or ""
    if not env.get("USER"):
        env["USER"] = name
    if not env.get("LOGNAME"):
        env["LOGNAME"] = name
    if not env.get("HOME") and home:
        env["HOME"] = home
    return env


def _neutralize_host_terminal(env: dict[str, str]) -> dict[str, str]:
    """Present the embedded PTY as a plain xterm, not the host terminal.

    haro spawns the user's real ``$SHELL -i``, so it sources their rc — but the
    backend's env was inherited from whatever terminal launched ``./run.sh``
    (e.g. Ghostty, iTerm, Terminal.app). That leaks the host terminal's identity
    (``TERM=xterm-ghostty``, ``TERM_PROGRAM=ghostty``, ``GHOSTTY_*`` shell
    integration) into the PTY, so rc gates like
    ``[[ $TERM_PROGRAM == ghostty ]] && fastfetch`` fire in the tiny grid cell.
    xterm.js is a standard truecolor terminal, so advertise exactly that: force a
    portable ``TERM`` and drop the host emulator's markers. Colors still work
    (they key off ``TERM``/``COLORTERM``), the greeter noise does not.
    """
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "haro"
    env.pop("TERM_PROGRAM_VERSION", None)
    for key in [k for k in env if k.startswith("GHOSTTY_") or k.startswith("ITERM_")]:
        env.pop(key, None)
    return env


def _setup_controlling_tty() -> None:
    """Child-side setup (after fork, before exec): become a session leader AND
    adopt the PTY slave — our stdin, fd 0 — as the session's controlling terminal.

    ``setsid`` alone detaches from any controlling tty but does NOT attach a new
    one, so an interactive shell can't do job control: zsh warns "No TTY for
    interactive shell (tcgetpgrp failed)" and ``setpgid`` raises ENOTTY
    ("Inappropriate ioctl for device"). The ``TIOCSCTTY`` ioctl claims the pty."""
    os.setsid()
    try:
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    except OSError:
        pass  # already a controlling tty, or unsupported — shell still runs


async def _spawn_pty(cwd: str, env: dict[str, str], argv: list[str]):
    """Exec ``argv`` on a fresh PTY rooted at ``cwd``. Returns (proc, master_fd).

    Give the process a CONTROLLING terminal so job control / raw-mode input
    work, else fish warns "No TTY for interactive shell (tcgetpgrp failed)" +
    fails setpgid and zsh runs silently degraded. Prefer ``setsid --ctty`` over a preexec_fn because
    UVLOOP (uvicorn's event loop) SILENTLY IGNORES preexec_fn, so the fd/ioctl
    setup never ran in production. setsid(1) starts a new session and (--ctty)
    makes its stdin — our pty slave — the controlling terminal, then execs
    ``argv`` in-place (no fork here: our child isn't a process-group leader, so
    setsid() succeeds directly and ``proc`` stays the target program). Fall back
    to preexec_fn where setsid(1) is absent (macOS)."""
    env = _with_identity(env)
    env = _neutralize_host_terminal(env)
    master, slave = os.openpty()
    if _SETSID:
        cmd = [_SETSID, "--ctty", *argv]
        preexec = None
    else:
        cmd = list(argv)
        preexec = _setup_controlling_tty
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        cwd=cwd,
        env=env,
        preexec_fn=preexec,
    )
    os.close(slave)  # parent only needs the master end
    return proc, master


async def spawn_shell(cwd: str, env: dict[str, str]):
    """Start an interactive shell on a new PTY. Returns (proc, master_fd)."""
    shell = env.get("SHELL") or "/bin/bash"
    # For bash, load our rc (colored prompt + aliases) since the container has no
    # per-user config. Non-bash shells (or a missing rc) just get a plain `-i`.
    if "bash" in os.path.basename(shell) and _TERMINAL_RC.exists():
        argv = [shell, "--rcfile", str(_TERMINAL_RC), "-i"]
    else:
        argv = [shell, "-i"]
    return await _spawn_pty(cwd, env, argv)
