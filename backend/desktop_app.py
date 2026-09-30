"""Frozen entry point for the packaged haro desktop build.

PyInstaller bundles this module + the ``haro`` package into a single
self-contained binary — no virtualenv and no system Python required on the
target machine. The Electron shell (``desktop/main.js``) spawns it with
``--port <n>`` and waits for ``/health``.

We call ``uvicorn.run`` programmatically (not the ``uvicorn`` CLI) because the
frozen binary has no shell and no console-script on PATH. Passing the imported
``app`` object also skips uvicorn's import-string machinery.
"""

from __future__ import annotations

import argparse
import os
import threading
import time

import uvicorn

from haro.main import app


def _die_with_parent(parent_pid: int) -> None:
    """Exit when the Electron shell (pid ``parent_pid``) is gone — a clean quit,
    a crash, or SIGKILL — so no orphaned backend is ever left behind.

    We POLL the parent pid rather than watch stdin for EOF. The old stdin-EOF
    approach exited *instantly* whenever stdin wasn't a live pipe (e.g. a
    /dev/null inherited on some relaunch paths), which surfaced to the user as
    "backend didn't start". Polling a pid has no such dependency and still
    catches every exit path (unlike Electron's JS quit handlers, which a signal
    can skip)."""
    while True:
        try:
            os.kill(parent_pid, 0)  # signal 0 = liveness probe, delivers nothing
        except ProcessLookupError:
            os._exit(0)  # parent gone → take the backend down with it
        except OSError:
            pass  # transient (e.g. EPERM) → assume alive, retry
        time.sleep(1.5)


def main() -> None:
    parser = argparse.ArgumentParser(prog="haro-backend")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    parent = os.environ.get("HARO_PARENT_PID", "")
    if parent.isdigit():
        threading.Thread(target=_die_with_parent, args=(int(parent),), daemon=True).start()

    # Bind to loopback only: this backend is private to the local desktop app.
    # timeout_graceful_shutdown bounds SIGTERM → exit to 3s (matching run.sh's
    # dev launcher) so quitting the desktop app can't hang on a lingering
    # WebSocket — main.js's stopBackend() sends SIGTERM to the whole process
    # group and the app.on("before-quit") handler doesn't itself wait, but a
    # slow uvicorn shutdown still delays the OS actually reclaiming the port.
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning", timeout_graceful_shutdown=3)


if __name__ == "__main__":
    main()
