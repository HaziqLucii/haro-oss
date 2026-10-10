"""The app's runtime log on disk, so the agent can watch the app it is working on.

haro owns the dev server (the Run button starts the project's ``run`` script), so every line
it prints already passes through ``lifecycle.start_run``. Here the same lines are also kept in
``~/.haro/logs/<workspace>/run.log`` (``run-<name>.log`` for a secondary run script). The agent
is told the path in ``$HARO_RUN_LOG`` and attaches a Monitor to it, instead of starting a shell
of its own: a shell the agent starts dies when its turn ends (the CLI kills background tasks
when haro closes stdin), the app haro runs does not.

The file starts empty on every start of the run, and is capped: past ``CAP_BYTES`` it keeps the
newest half, so a chatty server cannot fill the disk. It is written with the owner's
permissions only, since a dev server's output can carry secrets.
"""

from __future__ import annotations

import contextlib
import os
import re
import shutil
from pathlib import Path

from .config import settings

CAP_BYTES = 5 * 1024 * 1024


def log_dir(workspace_id: str) -> Path:
    return Path(settings.run_log_root).expanduser() / workspace_id


def run_log_path(workspace_id: str, run_id: str, *, default: bool) -> Path:
    """``run.log`` for the default run script, ``run-<id>.log`` for any other. The id comes from
    the project's settings file, which the repo controls, so it is cut down to a plain name."""
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", run_id).strip("_") or "run"
    name = "run.log" if default else f"run-{safe}.log"
    return log_dir(workspace_id) / name


def remove_workspace_logs(workspace_id: str) -> None:
    shutil.rmtree(log_dir(workspace_id), ignore_errors=True)


class RunLog:
    """An append-only, capped log file for one run of one run script."""

    def __init__(self, path: Path, *, cap: int = CAP_BYTES) -> None:
        self.path = path
        self._cap = cap
        self._size = 0
        self._fh = None
        self._open(truncate=True)

    def _open(self, *, truncate: bool) -> None:
        flags = os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if truncate else os.O_APPEND)
        with contextlib.suppress(OSError):
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._fh = os.fdopen(os.open(self.path, flags, 0o600), "ab")

    def write(self, line: str) -> None:
        """Append one line (a newline is added). A disk error drops the line, never the run."""
        if self._fh is None:
            return
        data = (line.rstrip("\n") + "\n").encode(errors="replace")
        try:
            self._fh.write(data)
            self._fh.flush()
        except OSError:
            return
        self._size += len(data)
        if self._size > self._cap:
            self._compact()

    def _compact(self) -> None:
        """Keep the newest half, starting on a line boundary. The new file replaces the old one
        in a single rename, so a reader following the path never sees a half-written file."""
        keep = self._cap // 2
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            with open(self.path, "rb") as f:
                f.seek(-keep, os.SEEK_END)
                tail = f.read().split(b"\n", 1)[-1]
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as out:
                out.write(tail)
            self._fh.close()
            os.replace(tmp, self.path)
            self._size = len(tail)
        except OSError:
            self._size = 0  # do not retry on every line
            with contextlib.suppress(OSError):
                tmp.unlink()
        finally:
            self._open(truncate=False)

    def close(self) -> None:
        if self._fh is not None:
            with contextlib.suppress(OSError):
                self._fh.close()
            self._fh = None
