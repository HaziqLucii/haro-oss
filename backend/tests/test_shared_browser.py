"""The shared browser (browser.py): a Playwright MCP server kept up between agent runs.

A tiny python listener stands in for ``npx @playwright/mcp`` (the command is the one seam), so the
tests cover haro's part: starting on a free port, waiting for it to answer, state, stopping it with
its process group and port, honest failure, and the run argv that hands it to the agent.
"""

from __future__ import annotations

import asyncio
import json
import sys

import pytest

from haro import browser
from haro.config import ProjectSettings
from haro.store import Store

from test_agents_flag import _capture_cmd

LISTENER = (
    "import socket,sys,time;"
    "s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);"
    "s.bind(('127.0.0.1',int(sys.argv[1])));s.listen();time.sleep(120)"
)


def _ps(lo: int = 47100, hi: int = 47199) -> ProjectSettings:
    ps = ProjectSettings()
    ps.port_range = (lo, hi)
    return ps


@pytest.fixture
def fake_server(monkeypatch, tmp_path):
    monkeypatch.setattr(browser.settings, "browser_root", str(tmp_path / "browsers"))
    monkeypatch.setattr(browser.run_logs.settings, "run_log_root", str(tmp_path / "logs"))
    monkeypatch.setattr(
        browser, "_command", lambda port, profile: [sys.executable, "-c", LISTENER, str(port)]
    )
    # The stand-in server does not speak MCP: the window is opened by its own test below.
    monkeypatch.setattr(browser, "_prime", lambda url: None)


def test_start_waits_for_the_server_then_stop_takes_it_and_its_port_away(fake_server):
    async def go():
        store = Store()
        assert browser.state(store, "w1") == {
            "running": False, "starting": False, "port": None, "url": None,
        }
        st = await browser.start(store, "w1", _ps())
        assert st["running"] and not st["starting"]
        assert st["url"] == f"http://localhost:{st['port']}/mcp"
        assert st["port"] in store.allocated_ports
        assert browser.live(store, "w1") == st
        proc = store.browsers["w1"].proc
        again = await browser.start(store, "w1", _ps())  # a second press changes nothing
        assert again["port"] == st["port"] and store.browsers["w1"].proc is proc

        await browser.stop(store, "w1")
        assert proc.returncode is not None
        assert browser.live(store, "w1") is None
        assert st["port"] not in store.allocated_ports
        await browser.stop(store, "w1")  # stopping again is fine

    asyncio.run(go())


def test_two_workspaces_get_two_servers_and_two_profiles(fake_server):
    async def go():
        store = Store()
        a = await browser.start(store, "a", _ps())
        b = await browser.start(store, "b", _ps())
        assert a["port"] != b["port"]
        assert store.browsers["a"].profile != store.browsers["b"].profile
        assert await browser.stop_all(store) == 2
        assert not store.browsers

    asyncio.run(go())


def test_a_server_that_dies_while_starting_is_an_error_and_leaves_nothing(monkeypatch, tmp_path):
    monkeypatch.setattr(browser.settings, "browser_root", str(tmp_path / "browsers"))
    monkeypatch.setattr(browser.run_logs.settings, "run_log_root", str(tmp_path / "logs"))
    monkeypatch.setattr(
        browser, "_command",
        lambda port, profile: [sys.executable, "-c", "print('boom: no browser installed');raise SystemExit(1)"],
    )

    async def go():
        store = Store()
        with pytest.raises(browser.BrowserError, match="boom: no browser installed"):
            await browser.start(store, "w1", _ps())
        assert browser.state(store, "w1")["running"] is False
        assert not store.allocated_ports

    asyncio.run(go())


def test_a_server_that_exits_later_is_forgotten(fake_server):
    async def go():
        store = Store()
        st = await browser.start(store, "w1", _ps())
        store.browsers["w1"].proc.kill()
        for _ in range(40):
            if "w1" not in store.browsers:
                break
            await asyncio.sleep(0.05)
        assert browser.live(store, "w1") is None
        assert st["port"] not in store.allocated_ports

    asyncio.run(go())


def test_a_port_something_else_holds_is_skipped(fake_server):
    async def go():
        import socket

        held = socket.socket()
        held.bind(("127.0.0.1", 47150))
        held.listen()
        try:
            store = Store()
            st = await browser.start(store, "w1", _ps(47150, 47160))
            assert st["port"] != 47150
            await browser.stop_all(store)
        finally:
            held.close()

    asyncio.run(go())


def test_the_mcp_config_names_the_server_and_its_url():
    cfg = json.loads(browser.mcp_config("http://localhost:4001/mcp"))
    assert cfg == {
        "mcpServers": {"haro_browser": {"type": "http", "url": "http://localhost:4001/mcp"}}
    }
    note = browser.instructions_note(cli=True)
    assert "mcp__haro_browser__browser_" in note and "browser_tabs" in note
    assert "haro-app browser status" in note
    assert "haro-app" not in browser.instructions_note(cli=False)


def test_a_run_with_the_browser_is_handed_its_url_and_the_plugin_is_denied_not_everything_else():
    cmd = _capture_cmd(browser_mcp={"url": "http://localhost:4001/mcp"})
    assert "--strict-mcp-config" not in cmd
    cfg = cmd[cmd.index("--mcp-config") + 1]
    assert json.loads(cfg)["mcpServers"]["haro_browser"]["url"] == "http://localhost:4001/mcp"
    denied = cmd[cmd.index("--disallowedTools") + 1 :]
    assert "mcp__plugin_playwright_playwright" in denied


def test_the_browser_deny_joins_protected_test_rules_in_one_flag():
    cmd = _capture_cmd(
        deny_edit_paths=["tests/a.py"],
        browser_mcp={"url": "http://localhost:4001/mcp"},
    )
    assert cmd.count("--disallowedTools") == 1
    denied = cmd[cmd.index("--disallowedTools") + 1 :]
    assert "Edit(tests/a.py)" in denied and "mcp__plugin_playwright_playwright" in denied


def test_a_run_without_the_browser_has_no_mcp_flags():
    cmd = _capture_cmd()
    assert "--mcp-config" not in cmd
    assert "--disallowedTools" not in cmd


# --------------------------------------------------------------------------- #
# What a run is handed (runner.py)
# --------------------------------------------------------------------------- #
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.hub import Hub
from haro.models import AgentRun, Workspace
from haro.runner import run_agent


class _BrowserAwareAdapter(AgentAdapter):
    name = "browser-aware"

    def __init__(self) -> None:
        self.browser_mcp = "unset"
        self.instructions = None

    async def run(self, *, task, cwd, model=None, effort=None, resume=None, instructions=None,
                  max_budget_usd=None, plan=False, browser_mcp=None):
        self.browser_mcp, self.instructions = browser_mcp, instructions
        yield NormalizedEvent("done", {"session_id": "s"})


class _BrowserBlindAdapter(AgentAdapter):
    name = "browser-blind"

    def __init__(self) -> None:
        self.instructions = None

    async def run(self, *, task, cwd, model=None, effort=None, resume=None, instructions=None,
                  max_budget_usd=None):
        self.instructions = instructions
        yield NormalizedEvent("done", {})


class _Alive:
    returncode = None


def _drive(adapter, *, browser_up=True, plan=False):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    if browser_up:
        store.browsers[ws.id] = browser.BrowserServer(
            proc=_Alive(), port=4123, profile="/x", ready=True
        )
    run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=run, test_adapter=object(),
        project_path="/tmp/proj", auto_gate=False, plan=plan, instructions="be careful",
    ))


def test_a_run_gets_the_browser_url_and_a_note_when_the_browser_is_up():
    a = _BrowserAwareAdapter()
    _drive(a)
    assert a.browser_mcp == {"url": "http://localhost:4123/mcp"}
    assert a.instructions.startswith("be careful\n\n")
    assert "mcp__haro_browser__browser_" in a.instructions


def test_no_browser_means_nothing_added():
    a = _BrowserAwareAdapter()
    _drive(a, browser_up=False)
    assert a.browser_mcp is None
    assert a.instructions == "be careful"


def test_a_plan_run_is_not_offered_the_browser():
    a = _BrowserAwareAdapter()
    _drive(a, plan=True)
    assert a.browser_mcp is None
    assert a.instructions == "be careful"


def test_an_adapter_that_cannot_take_it_is_not_told_about_it():
    a = _BrowserBlindAdapter()
    _drive(a)
    assert a.instructions == "be careful"


# --------------------------------------------------------------------------- #
# The routes and `haro-app browser`
# --------------------------------------------------------------------------- #
def _routes(tmp_path, monkeypatch, *, mode="agent"):
    from fastapi import HTTPException  # noqa: F401
    from haro import main
    from haro.models import Project

    store = Store()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path),
                   base_ref="main", mode=mode)
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    project.id = "p"
    store.add_project(project)
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "load_project_settings", lambda _p: _ps())
    return main, store, ws


def test_the_text_state_tells_the_agent_what_to_do(tmp_path, monkeypatch, fake_server):
    main, store, ws = _routes(tmp_path, monkeypatch)

    async def go():
        off = await main.browser_state(ws.id, format="text")
        assert "haro-app browser start" in off.body.decode()
        started = await main.browser_start(ws.id, format="text")
        assert "from your next run" in started.body.decode()
        again = await main.browser_start(ws.id, format="text")
        assert "running" in again.body.decode() and "next run" not in again.body.decode()
        stopped = await main.browser_stop(ws.id, format="text")
        assert "stopped" in stopped.body.decode()
        assert (await main.browser_state(ws.id))["running"] is False

    asyncio.run(go())


def test_a_manual_workspace_cannot_start_a_browser_for_an_agent_that_is_off(
    tmp_path, monkeypatch, fake_server
):
    from fastapi import HTTPException

    main, store, ws = _routes(tmp_path, monkeypatch, mode="manual")
    with pytest.raises(HTTPException) as err:
        asyncio.run(main.browser_start(ws.id))
    assert err.value.status_code == 409
    assert not store.browsers


def test_a_start_that_fails_answers_400_with_the_reason(tmp_path, monkeypatch):
    from fastapi import HTTPException

    main, store, ws = _routes(tmp_path, monkeypatch)
    monkeypatch.setattr(browser.settings, "browser_root", str(tmp_path / "browsers"))
    monkeypatch.setattr(browser.run_logs.settings, "run_log_root", str(tmp_path / "logs"))

    def no_npx(port, profile):
        raise browser.BrowserError("npx was not found on PATH: the shared browser needs Node.js")

    monkeypatch.setattr(browser, "_command", no_npx)
    with pytest.raises(HTTPException) as err:
        asyncio.run(main.browser_start(ws.id))
    assert err.value.status_code == 400 and "Node.js" in err.value.detail
    assert not store.allocated_ports


def test_haro_app_has_a_browser_verb():
    from haro import app_ctl

    assert "browser)" in app_ctl.SCRIPT
    assert "$base/browser/start?format=text" in app_ctl.SCRIPT


# --------------------------------------------------------------------------- #
# Races and what the kill scans may match (review fixes)
# --------------------------------------------------------------------------- #
def test_two_starts_at_once_make_one_server(fake_server):
    async def go():
        store = Store()
        a, b = await asyncio.gather(
            browser.start(store, "w1", _ps()), browser.start(store, "w1", _ps())
        )
        assert a["port"] == b["port"]
        assert len(store.allocated_ports) == 1
        await browser.stop(store, "w1")
        assert not store.allocated_ports

    asyncio.run(go())


def test_a_start_after_a_stop_gets_a_fresh_server_and_the_old_one_is_gone(fake_server):
    async def go():
        store = Store()
        await browser.start(store, "w1", _ps())
        first = store.browsers["w1"].proc
        await asyncio.gather(browser.stop(store, "w1"), browser.start(store, "w1", _ps()))
        assert first.returncode is not None
        assert browser.live(store, "w1") is not None
        await browser.stop(store, "w1")

    asyncio.run(go())


def test_a_path_matches_only_as_a_path_of_its_own():
    p = "/h/.haro/browsers/ws_1"
    assert browser._names(f"node mcp --user-data-dir {p}", p)
    assert browser._names(f"chrome --user-data-dir={p} --x", p)
    assert browser._names(f"chrome {p}/Default/Cache", p)
    assert not browser._names(f"node --user-data-dir {p}0", p)
    assert not browser._names(f"tail -f {p}.log", p)


def test_the_log_is_not_under_the_profile_root(fake_server, monkeypatch, tmp_path):
    monkeypatch.setattr(browser.run_logs.settings, "run_log_root", str(tmp_path / "logs"))
    log = browser._log_path("ws_1")
    assert str(browser.profile_dir("ws_1").parent) not in str(log)


def test_forgetting_a_workspace_removes_its_profile_and_log(fake_server, monkeypatch, tmp_path):
    monkeypatch.setattr(browser.run_logs.settings, "run_log_root", str(tmp_path / "logs"))

    async def go():
        store = Store()
        await browser.start(store, "w1", _ps())
        profile = browser.profile_dir("w1")
        assert profile.exists() and browser._log_path("w1").exists()
        await browser.stop(store, "w1")
        assert profile.exists()  # stopping keeps logins
        browser.forget("w1")
        assert not profile.exists() and not browser._log_path("w1").exists()

    asyncio.run(go())


def test_opening_the_window_speaks_mcp_in_order_and_ends_on_a_blank_page():
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    seen: list[tuple] = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            args = body.get("params", {}).get("arguments") if body["method"] == "tools/call" else None
            seen.append((body["method"], self.headers.get("mcp-session-id"), args))
            self.send_response(200)
            if "id" not in body:  # a notification: no reply
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            reply = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": {"ok": True}})
            payload = f"event: message\ndata: {reply}\n\n".encode()  # replies come as SSE
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("mcp-session-id", "sess-1")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_a):
            pass

    srv = HTTPServer(("localhost", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        browser._prime(f"http://localhost:{srv.server_address[1]}/mcp")
    finally:
        srv.shutdown()
    assert seen == [
        ("initialize", None, None),
        ("notifications/initialized", "sess-1", None),
        ("tools/call", "sess-1", {"url": "about:blank"}),
    ]


def test_a_window_that_cannot_open_does_not_fail_the_start(monkeypatch, tmp_path, fake_server):
    def boom(url):
        raise OSError("no display")

    monkeypatch.setattr(browser, "_prime", boom)

    async def go():
        store = Store()
        st = await browser.start(store, "w1", _ps())
        assert st["running"]
        await browser.stop(store, "w1")

    asyncio.run(go())
