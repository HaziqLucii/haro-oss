"""In-app self-update for the packaged desktop build.

The installed app is a frozen snapshot (PyInstaller backend + prebuilt SPA). This
module lets it rebuild itself from the local source checkout when that source has
moved past the running build — but only once no agent/gate work is in flight (a
rebuild restarts the backend, which would kill running agents; that's the whole
reason haro dropped ``uvicorn --reload``).

Detection is commit-based: ``desktop/rebuild.sh`` stamps the git HEAD it built
from into ``assets/build_info.env`` (which rides inside the frozen binary). We
compare that stamped SHA to the source checkout's *current* HEAD — different →
an update is available. A run without a stamp (dev / ``run.sh``) reports
"unsupported" and never self-updates.

Preference (``manual`` vs ``auto``) persists next to the DB in ``~/.haro``.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path

from .models import WorkspaceStatus
from .store import Store

_STAMP = Path(__file__).parent / "assets" / "build_info.env"
_SETTINGS = (
    Path(os.environ.get("HARO_DB") or "~/.haro/haro.db").expanduser().parent / "update.json"
)
# rebuild.sh writes coarse build milestones here (PCT=/LABEL= lines, same format as
# the build stamp) so the still-alive old app can show real progress during the ~1-min
# rebuild. Pinned to ~/.haro to match the `.update-ready` sentinel the Electron shell
# watches — the whole self-update flow lives in that dir, independent of HARO_DB.
_PROGRESS = Path.home() / ".haro" / ".update-progress"

# A workspace in any of these is doing work a restart would interrupt.
_BUSY_STATUSES = {
    WorkspaceStatus.setting_up,
    WorkspaceStatus.agent_running,
    WorkspaceStatus.tests_running,
}

#: Set by POST /update/apply when the app is busy: apply as soon as it goes idle.
_pending: bool = False


def build_info() -> dict[str, str]:
    """``{'sha': ..., 'source_root': ...}`` from the build stamp, or ``{}`` if
    unstamped (a source/dev run that can't self-update)."""
    info: dict[str, str] = {}
    try:
        for line in _STAMP.read_text().splitlines():
            key, sep, val = line.partition("=")
            if sep:
                info[key.strip().lower()] = val.strip()
    except OSError:
        pass
    return info


async def _git_head(root: str) -> str | None:
    try:
        proc = await asyncio.create_subprocess_exec(
            "git", "-C", root, "rev-parse", "HEAD",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await proc.communicate()
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return out.decode().strip() or None


def busy_reason(store: Store) -> str | None:
    """Human note if a restart would interrupt work, else None (safe to update)."""
    n = sum(1 for w in store.workspaces.values() if w.status in _BUSY_STATUSES)
    if n:
        return f"{n} workspace{'s' if n != 1 else ''} still working (agent or tests running)"
    return None


def get_mode() -> str:
    """'manual' (default) or 'auto'."""
    try:
        return str(json.loads(_SETTINGS.read_text()).get("mode", "manual"))
    except (OSError, ValueError):
        return "manual"


def set_mode(mode: str) -> str:
    mode = "auto" if mode == "auto" else "manual"
    _SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    _SETTINGS.write_text(json.dumps({"mode": mode}))
    return mode


async def status(store: Store) -> dict:
    """Everything the UI needs: is an update available, are we busy, which mode."""
    info = build_info()
    sha, root = info.get("sha"), info.get("source_root")
    head = await _git_head(root) if root else None
    supported = bool(
        sha and root and sha != "unknown" and Path(root, "desktop", "rebuild.sh").exists()
    )
    available = bool(supported and head and sha != head)
    reason = busy_reason(store)
    return {
        "supported": supported,
        "available": available,
        "pending": _pending,
        "buildSha": (sha or "")[:8],
        "headSha": (head or "")[:8],
        "busy": reason is not None,
        "busyReason": reason,
        "mode": get_mode(),
    }


def set_pending(value: bool) -> None:
    global _pending
    _pending = value


def progress() -> dict | None:
    """The current rebuild milestone ``{"pct": 0-100, "label": str}`` written by
    rebuild.sh, or ``None`` when no rebuild is in flight / the file is absent. Coarse
    by nature — a handful of milestones (frontend build, backend freeze, package,
    install), not a continuous percent, since the underlying tools don't stream one."""
    try:
        raw = _PROGRESS.read_text()
    except OSError:
        return None
    fields: dict[str, str] = {}
    for line in raw.splitlines():
        key, sep, val = line.partition("=")
        if sep:
            fields[key.strip()] = val.strip()
    try:
        pct = int(fields.get("PCT", ""))
    except ValueError:
        return None
    return {"pct": max(0, min(100, pct)), "label": fields.get("LABEL", "")}


def _write_progress(pct: int, label: str) -> None:
    try:
        _PROGRESS.parent.mkdir(parents=True, exist_ok=True)
        _PROGRESS.write_text(f"PCT={pct}\nLABEL={label}\n")
    except OSError:
        pass


def clear_progress() -> None:
    """Drop any leftover progress file. Called on boot: a freshly relaunched build is,
    by definition, done updating, so a stale milestone (esp. the 100% written just
    before relaunch) must not make the new app look like it's still rebuilding."""
    try:
        _PROGRESS.unlink(missing_ok=True)
    except OSError:
        pass


async def apply() -> bool:
    """Spawn the detached rebuild+restart. Detached (start_new_session) so it
    survives the very restart it performs — it rebuilds, reinstalls, kills this
    app, and relaunches the new build. Returns False if the build isn't
    self-updatable (no stamp)."""
    info = build_info()
    root = info.get("source_root")
    if not root or not Path(root, "desktop", "rebuild.sh").exists():
        return False
    # Seed a 1% milestone up front so the UI shows a live bar the instant the click
    # lands — rebuild.sh takes a moment to spawn and write its own first milestone.
    _write_progress(1, "Starting")
    await asyncio.create_subprocess_exec(
        "bash", str(Path(root, "desktop", "rebuild.sh")), "--restart",
        cwd=root,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
        stdin=asyncio.subprocess.DEVNULL,
        start_new_session=True,
    )
    return True
