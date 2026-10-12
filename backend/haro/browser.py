"""A browser that outlives the agent's runs: one Playwright MCP server per workspace.

The Playwright plugin is a stdio MCP server, so Claude Code starts it with a run and kills it
when the run ends, and the browser it launched goes with it: every follow-up prompt reopened and
re-closed the window and lost the page. Here haro owns the server instead. ``POST
/workspaces/{id}/browser/start`` runs ``@playwright/mcp`` as its own HTTP process on a port from
the project's range, with ``--shared-browser-context`` (without it each new client gets a fresh
page: verified on CLI 2.1.296) and a profile folder of the workspace's own, so two workspaces never
share a page or a login. Each agent run in that workspace is then handed the server's URL
(``--mcp-config``) and the plugin's own Playwright tools are denied for that run, so the agent has
exactly one browser. Everything else the run loads (other MCP servers, skills) is untouched: the
config is added to, never made strict.

The browser window opens when the agent first navigates, not when the server starts. A run's MCP
list is fixed when it starts, so the browser has to be enabled before the run that should use it.

Stopped with the workspace (``lifecycle.quiesce_workspace``), at shutdown (``main.lifespan``), and a
server left by a hard kill is swept at boot (``sweep_orphans``): its argv carries the profile path.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import procs, run_logs
from .config import ProjectSettings, settings
from .store import Store

log = logging.getLogger(__name__)

#: The server's name in the run's MCP config, so its tools are ``mcp__haro_browser__browser_*``.
SERVER_NAME = "haro_browser"
TOOL_PREFIX = f"mcp__{SERVER_NAME}"
#: The user-level Playwright plugin's tools (server ``plugin:playwright:playwright``). Denied for a
#: run that has the shared browser, so the agent cannot pick the browser that closes with the run.
PLUGIN_DENY = "mcp__plugin_playwright_playwright"
#: First start downloads the package and, if missing, the browser: allow for it.
STARTUP_SECS = 120.0


class BrowserError(RuntimeError):
    """The shared browser could not start; the message is shown to the developer."""


@dataclass
class BrowserServer:
    proc: Any
    port: int
    profile: str
    started: float = field(default_factory=time.monotonic)
    ready: bool = False
    watcher: asyncio.Task | None = None


def profile_dir(workspace_id: str) -> Path:
    return Path(settings.browser_root).expanduser() / workspace_id


def _command(port: int, profile: str) -> list[str]:
    npx = shutil.which("npx")
    if npx is None:
        raise BrowserError("npx was not found on PATH: the shared browser needs Node.js")
    return [
        npx, "-y", "@playwright/mcp@latest",
        "--port", str(port),
        "--shared-browser-context",
        "--user-data-dir", profile,
    ]


def url_for(port: int) -> str:
    # `localhost`, not 127.0.0.1: the server binds whichever address `localhost` resolves to first
    # (IPv6 `::1` on a Mac) and answers 403 to any other Host header (checked on @playwright/mcp).
    return f"http://localhost:{port}/mcp"


def state(store: Store, workspace_id: str) -> dict:
    srv = store.browsers.get(workspace_id)
    alive = srv is not None and srv.proc.returncode is None
    return {
        "running": bool(alive and srv.ready),
        "starting": bool(alive and not srv.ready),
        "port": srv.port if alive else None,
        "url": url_for(srv.port) if alive and srv.ready else None,
    }


def live(store: Store, workspace_id: str) -> dict | None:
    """The state of a browser that is up and answering, else None (what a run is handed)."""
    s = state(store, workspace_id)
    return s if s["running"] else None


def mcp_config(url: str) -> str:
    return json.dumps({"mcpServers": {SERVER_NAME: {"type": "http", "url": url}}})


def instructions_note(*, cli: bool) -> str:
    note = (
        "A shared browser is open for this workspace. Use its tools (names start with "
        f"`{TOOL_PREFIX}__browser_`) for anything that needs a browser; the Playwright plugin's own "
        "tools are disabled for this run. The browser stays open between your runs, so call "
        "`browser_tabs` before you assume which page it is on."
    )
    if cli:
        note += (
            " `browser_close` cannot close it (it is shared across runs). When the developer asks "
            "you to stop or close the browser, run `haro-app browser stop`; otherwise leave it "
            "open, they may be using the window. `haro-app browser status` says whether it is up."
        )
    else:
        note += " Leave it open: the developer closes it from haro."
    return note


async def _port_open(port: int) -> bool:
    try:
        _r, w = await asyncio.wait_for(asyncio.open_connection("localhost", port), 1.0)
    except (OSError, asyncio.TimeoutError):
        return False
    w.close()
    return True


def _tail(path: Path, n: int = 6) -> str:
    try:
        lines = path.read_text(errors="replace").strip().splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-n:])


async def _watch(store: Store, workspace_id: str, srv: BrowserServer) -> None:
    """Forget the server when it exits on its own, so the rail never shows a dead browser as on."""
    await srv.proc.wait()
    if store.browsers.get(workspace_id) is srv:
        store.browsers.pop(workspace_id, None)
        store.release_port(srv.port)


async def _free_port(store: Store, psettings: ProjectSettings) -> int:
    """A port from the project's range that nothing answers on. The range is shared with the dev
    servers, and a port haro has not handed out can still be taken by another program."""
    skipped: list[int] = []
    try:
        for _ in range(25):
            port = store.allocate_port(*psettings.port_range)
            if port is None:
                break
            if not await _port_open(port):
                return port
            skipped.append(port)  # held until we are done, so the next pick differs
        raise BrowserError("no free port in this project's port range for the shared browser")
    finally:
        for p in skipped:
            store.release_port(p)


def _lock(store: Store, workspace_id: str) -> asyncio.Lock:
    return store.browser_locks.setdefault(workspace_id, asyncio.Lock())


async def start(store: Store, workspace_id: str, psettings: ProjectSettings) -> dict:
    """Start the workspace's browser server (a no-op when it is up) and wait until it answers.
    A second call while the first is still starting waits for it, then finds it up."""
    async with _lock(store, workspace_id):
        return await _start_locked(store, workspace_id, psettings)


def _log_path(workspace_id: str) -> Path:
    # Outside the profile root on purpose: the kill scans match that path in any command line.
    return run_logs.log_dir(workspace_id) / "browser.log"


async def _start_locked(store: Store, workspace_id: str, psettings: ProjectSettings) -> dict:
    existing = store.browsers.get(workspace_id)
    if existing is not None and existing.proc.returncode is None:
        return await _await_ready(store, workspace_id, existing)
    profile = profile_dir(workspace_id)
    profile.mkdir(parents=True, exist_ok=True)
    port = await _free_port(store, psettings)
    try:
        cmd = _command(port, str(profile))
    except BrowserError:
        store.release_port(port)
        raise
    log_path = _log_path(workspace_id)
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "wb") as out:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=out, stderr=asyncio.subprocess.STDOUT,
                stdin=asyncio.subprocess.DEVNULL, start_new_session=True,
            )
    except OSError as exc:
        store.release_port(port)
        raise BrowserError(f"could not start the shared browser: {exc}") from exc
    srv = BrowserServer(proc=proc, port=port, profile=str(profile))
    store.browsers[workspace_id] = srv
    srv.watcher = asyncio.create_task(_watch(store, workspace_id, srv))
    return await _await_ready(store, workspace_id, srv, log_path)


def _rpc(url: str, body: dict, session: str | None, timeout: float) -> tuple[dict | None, str | None]:
    """One JSON-RPC POST to the MCP server over HTTP; returns (the reply for this id, the session
    id the server assigned). The reply may come as plain JSON or as one server-sent event."""
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session:
        headers["mcp-session-id"] = session
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (localhost)
        sid = resp.headers.get("mcp-session-id") or session
        raw = resp.read().decode(errors="replace")
    if "id" not in body:  # a notification has no reply
        return None, sid
    for chunk in raw.splitlines():
        text = chunk[5:].strip() if chunk.startswith("data:") else chunk.strip()
        if text.startswith("{"):
            try:
                msg = json.loads(text)
            except ValueError:
                continue
            if msg.get("id") == body["id"]:
                return msg, sid
    return None, sid


def _prime(url: str) -> None:
    """Open the browser window now. Playwright launches it on the first tool call, so without this
    pressing Open shows nothing until the agent first navigates. Goes through the same MCP door the
    agent uses (initialize, then `browser_navigate` to a blank page) and leaves: with a shared
    context the window outlives this session (the same property runs rely on)."""
    init = {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "haro", "version": "1"},
        },
    }
    _reply, sid = _rpc(url, init, None, 30)
    _rpc(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid, 30)
    _rpc(
        url,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "browser_navigate", "arguments": {"url": "about:blank"}}},
        sid, 90,
    )


async def _open_window(port: int) -> None:
    """Best effort: a window that does not open (no display, no browser installed) must not turn a
    running server into a failed start, so the reason is logged and the card stays on."""
    try:
        await asyncio.to_thread(_prime, url_for(port))
    except Exception as exc:  # noqa: BLE001
        log.warning("shared browser: could not open its window: %s", exc)


async def _await_ready(
    store: Store, workspace_id: str, srv: BrowserServer, log_path: Path | None = None
) -> dict:
    deadline = time.monotonic() + STARTUP_SECS
    while time.monotonic() < deadline:
        if srv.proc.returncode is not None:
            detail = _tail(log_path) if log_path else ""
            raise BrowserError(
                "the shared browser server exited while starting" + (f": {detail}" if detail else "")
            )
        if await _port_open(srv.port):
            await _open_window(srv.port)
            srv.ready = True
            return state(store, workspace_id)
        await asyncio.sleep(0.25)
    await _stop_locked(store, workspace_id)
    raise BrowserError(f"the shared browser server did not answer within {int(STARTUP_SECS)}s")


def _names(cmd: str, path: str) -> bool:
    """True when ``path`` appears in the command line as a path of its own (followed by the end, a
    space or a separator), so `ws_1` does not match `ws_10` and a file merely named after it is not
    mistaken for the profile."""
    return re.search(re.escape(path) + r"(?=$|[\s/])", cmd) is not None


def _profile_pids(profile: str) -> list[int]:
    """Processes whose argv names this profile folder (the server and the browser it launched)."""
    try:
        out = subprocess.run(
            ["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(.*)", line)
        if m and _names(m.group(2), profile) and int(m.group(1)) not in (0, 1, os.getpid()):
            pids.append(int(m.group(1)))
    return pids


async def stop(store: Store, workspace_id: str) -> None:
    async with _lock(store, workspace_id):
        await _stop_locked(store, workspace_id)


def forget(workspace_id: str) -> None:
    """A workspace is gone: drop its browser profile (logins, cache) and log. Stopping alone keeps
    them, so a browser turned off and on again is still logged in."""
    shutil.rmtree(profile_dir(workspace_id), ignore_errors=True)
    try:
        _log_path(workspace_id).unlink()
    except OSError:
        pass


async def _stop_locked(store: Store, workspace_id: str) -> None:
    srv = store.browsers.pop(workspace_id, None)
    if srv is None:
        return
    await procs.terminate_tree(srv.proc)
    # A browser that left the server's process group would survive it: find it by its profile.
    for pid in await asyncio.to_thread(_profile_pids, srv.profile):
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    store.release_port(srv.port)


async def stop_all(store: Store) -> int:
    ids = list(store.browsers)
    for ws_id in ids:
        await stop(store, ws_id)
    return len(ids)


def sweep_orphans() -> list[str]:
    """Boot: kill servers and browsers a hard-killed backend left running, found by the profile
    root in their argv. ``store.browsers`` is empty at boot, so every match is an orphan."""
    root = str(Path(settings.browser_root).expanduser())
    notes = []
    for pid in _profile_pids(root + os.sep):
        try:
            os.kill(pid, signal.SIGKILL)
            notes.append(f"killed orphan browser pid {pid}")
        except (ProcessLookupError, PermissionError):
            pass
    return notes
