"""Frozen entry point for the packaged haro desktop build.

PyInstaller bundles this module + the ``haro`` package into a single
self-contained binary — no virtualenv and no system Python required on the
target machine. The desktop app spawns it with
``--port <n>`` and waits for ``/health``.

We call ``uvicorn.run`` programmatically (not the ``uvicorn`` CLI) because the
frozen binary has no shell and no console-script on PATH. Passing the imported
``app`` object also skips uvicorn's import-string machinery.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time

from haro.frozen_env import restore_host_library_path

# Before haro.main is imported: modules there copy os.environ for the processes they start.
if getattr(sys, "frozen", False):
    restore_host_library_path(os.environ)

import uvicorn  # noqa: E402

from haro.config import settings  # noqa: E402
from haro.main import app  # noqa: E402


def _die_with_parent(parent_pid: int) -> None:
    """Exit when the app shell (pid ``parent_pid``) is gone — a clean quit,
    a crash, or SIGKILL — so no orphaned backend is ever left behind.

    We POLL the parent pid rather than watch stdin for EOF. The old stdin-EOF
    approach exited *instantly* whenever stdin wasn't a live pipe (e.g. a
    /dev/null inherited on some relaunch paths), which surfaced to the user as
    "backend didn't start". Polling a pid has no such dependency and still
    catches every exit path (unlike quit handlers, which a signal
    can skip)."""
    while True:
        try:
            os.kill(parent_pid, 0)  # signal 0 = liveness probe, delivers nothing
        except ProcessLookupError:
            os._exit(0)  # parent gone → take the backend down with it
        except OSError:
            pass  # transient (e.g. EPERM) → assume alive, retry
        time.sleep(1.5)


def api_url(host: str, port: int) -> str:
    """The address a local client uses for a server bound to [host]: a wildcard bind is reached
    on loopback, and an IPv6 address needs brackets in a URL."""
    if host in ("", "0.0.0.0", "::"):
        host = "127.0.0.1"
    if ":" in host:
        host = f"[{host}]"
    return f"http://{host}:{port}"


def main() -> None:
    parser = argparse.ArgumentParser(prog="haro-backend")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    parent = os.environ.get("HARO_PARENT_PID", "")
    if parent.isdigit():
        threading.Thread(target=_die_with_parent, args=(int(parent),), daemon=True).start()

    # Where agents reach this backend (`haro-app`, app_ctl.py): a setting, not the process
    # environment, so it is not handed to every terminal and script haro starts.
    settings.api_url = api_url(args.host, args.port)

    # Bind to loopback only: this backend is private to the local desktop app.
    # timeout_graceful_shutdown bounds SIGTERM → exit to 3s (matching run.sh's
    # dev launcher) so quitting the desktop app can't hang on a lingering
    # WebSocket — main.js's stopBackend() sends SIGTERM to the whole process
    # group and the app.on("before-quit") handler doesn't itself wait, but a
    # slow uvicorn shutdown still delays the OS actually reclaiming the port.
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning", timeout_graceful_shutdown=3)


if __name__ == "__main__":
    main()
