"""`haro-app`: the agent runs, checks and looks at the app haro runs for its workspace.

The script is checked against a tiny local server standing in for the backend, so what it sends
(method, path, body) and what it prints are pinned without starting a real dev server.
"""

from __future__ import annotations

import asyncio
import json
import os
import stat
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from haro import app_ctl, config
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.models import AgentRun, Workspace
from haro.runner import run_agent
from haro.store import Store
from haro.hub import Hub

from test_run_logs import _project_with_run, log_root  # noqa: F401
from test_stop_subagent import _drive, _result, run, scripted  # noqa: F401


@pytest.fixture
def bin_dir(log_root, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(config.settings, "bin_dir", str(tmp_path / "bin"))
    app_ctl._written.clear()
    return app_ctl.ensure_script()


class _Backend:
    """Records each request and answers canned bodies. `routes` maps (method, path without the
    query) to (status, body); anything else gets a small JSON ok, and an unknown workspace a 404."""

    def __init__(self):
        self.requests: list[tuple[str, str]] = []
        self.bodies: list[str] = []
        self.routes: dict[tuple[str, str], tuple[int, str]] = {}
        outer = self

        class H(BaseHTTPRequestHandler):
            def _answer(self, method):
                n = int(self.headers.get("Content-Length") or 0)
                outer.bodies.append(self.rfile.read(n).decode() if n else "")
                outer.requests.append((method, self.path))
                if "/workspaces/nope/" in self.path:
                    body, code = '{"detail":"workspace not found"}', 404
                elif (method, self.path.split("?")[0]) in outer.routes:
                    code, body = outer.routes[(method, self.path.split("?")[0])]
                else:
                    body, code = json.dumps({"ok": True, "path": self.path}), 200
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body.encode())

            def do_GET(self):
                self._answer("GET")

            def do_POST(self):
                self._answer("POST")

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def info(self, *, running=True, url=None, up=12, log="", probe=1):
        text = (
            f"name=app\nrunning={int(running)}\nurl={url or ''}\nport=\n"
            f"up_seconds={up if running else ''}\nprobe={probe}\nlog={log}\n"
        )
        self.routes[("GET", "/workspaces/w1/run/info")] = (200, text)

    def close(self):
        self.server.shutdown()


@pytest.fixture
def backend():
    b = _Backend()
    yield b
    b.close()


@pytest.fixture
def app_server():
    """The 'app': answers every request with a 404, which still counts as answering."""

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(404)
            self.end_headers()

        def log_message(self, *a):
            pass

    server = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def haro_app(bin_dir, *args, api=None, ws="w1", env=None):
    full = {k: v for k, v in os.environ.items() if not k.startswith("HARO_")}
    if api:
        full["HARO_API"] = api
        full["HARO_WORKSPACE_ID"] = ws
    full.update(env or {})
    return subprocess.run(
        ["sh", str(bin_dir / "haro-app"), *args], env=full, capture_output=True, text=True, timeout=60
    )


def test_the_script_is_written_executable_and_left_alone_when_current(bin_dir):
    path = bin_dir / "haro-app"
    assert path.read_text() == app_ctl.SCRIPT
    assert path.stat().st_mode & stat.S_IXUSR
    before = path.stat().st_mtime_ns
    app_ctl.ensure_script()
    assert path.stat().st_mtime_ns == before


def test_an_out_of_date_script_is_replaced(bin_dir):
    path = bin_dir / "haro-app"
    path.write_text("#!/bin/sh\necho old\n")
    app_ctl._written.clear()  # a new process: the content is checked again
    app_ctl.ensure_script()
    assert path.read_text() == app_ctl.SCRIPT
    assert path.stat().st_mode & stat.S_IXUSR


def test_the_script_is_valid_posix_sh(bin_dir):
    r = subprocess.run(["sh", "-n", str(bin_dir / "haro-app")], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_start_posts_then_waits_until_the_app_answers(bin_dir, backend, app_server):
    backend.info(url=app_server)
    r = haro_app(bin_dir, "start", api=backend.url)
    assert r.returncode == 0, r.stdout + r.stderr
    assert r.stdout.startswith(f"app: running at {app_server} (ready in ") and r.stdout.endswith("s)\n")
    assert backend.requests[0] == ("POST", "/workspaces/w1/run")
    assert backend.requests[1][1].startswith("/workspaces/w1/run/info?format=text")


def test_restart_posts_the_same_endpoint(bin_dir, backend, app_server):
    backend.info(url=app_server)
    assert haro_app(bin_dir, "restart", api=backend.url).returncode == 0
    assert backend.requests[0] == ("POST", "/workspaces/w1/run")


def test_no_wait_returns_without_probing_the_app(bin_dir, backend):
    backend.info(url="http://127.0.0.1:9")
    r = haro_app(bin_dir, "start", "--no-wait", api=backend.url)
    assert r.returncode == 0 and "started at http://127.0.0.1:9" in r.stdout


def test_an_app_that_never_answers_fails_with_a_pointer_to_the_log(bin_dir, backend):
    backend.info(url="http://127.0.0.1:9")
    r = haro_app(bin_dir, "start", "--timeout", "1", api=backend.url)
    assert r.returncode == 1
    assert r.stdout == "app: started but not answering after 1s, read the log with: haro-app logs\n"


def test_an_app_that_exits_while_starting_fails_early(bin_dir, backend):
    backend.info(running=False)
    r = haro_app(bin_dir, "start", "worker", api=backend.url)
    assert r.returncode == 1
    assert r.stdout == "app: exited before answering, read the log with: haro-app logs worker\n"


def test_wait_blocks_until_it_answers_and_refuses_a_stopped_app(bin_dir, backend, app_server):
    backend.info(url=app_server)
    r = haro_app(bin_dir, "wait", "--timeout", "5", api=backend.url)
    assert r.returncode == 0 and "app: running at" in r.stdout
    assert all(m == "GET" for m, _ in backend.requests)
    backend.info(running=False)
    r = haro_app(bin_dir, "wait", api=backend.url)
    assert r.returncode == 1 and r.stdout == "app: not running, start it with: haro-app start\n"


def test_stop_posts_to_the_stop_endpoint(bin_dir, backend):
    r = haro_app(bin_dir, "stop", api=backend.url)
    assert r.returncode == 0 and r.stdout == "app: stopped\n"
    assert backend.requests == [("POST", "/workspaces/w1/run/stop")]


def test_status_is_one_line(bin_dir, backend):
    backend.info(url="http://localhost:4002", up=12)
    r = haro_app(bin_dir, "status", api=backend.url)
    assert r.stdout == "app: running at http://localhost:4002 (up 12s)\n"
    backend.info(running=False)
    assert haro_app(bin_dir, "status", api=backend.url).stdout == "app: stopped\n"


def test_status_adds_the_last_error_line_from_the_log(bin_dir, backend, tmp_path):
    log = tmp_path / "run.log"
    log.write_text(
        "ready\n\x1b[31mError: listen EADDRINUSE :::4002\x1b[0m\n"
        + "  at " + "x" * 300 + " failed\n"
        + "plain output\n"
    )
    backend.info(running=False)
    r = haro_app(bin_dir, "status", api=backend.url, env={"HARO_RUN_LOG": str(log)})
    line = r.stdout.rstrip("\n")
    assert line.startswith("app: stopped | last error: Error: listen EADDRINUSE")
    assert len(line.split("last error: ")[1]) <= 120
    log.write_text("fine\nall good\n")
    r = haro_app(bin_dir, "status", api=backend.url, env={"HARO_RUN_LOG": str(log)})
    assert r.stdout == "app: stopped\n"
    log.write_text("one\nError: EADDRINUSE\n" + "pad\n" * 60)
    r = haro_app(bin_dir, "status", api=backend.url, env={"HARO_RUN_LOG": str(log)})
    assert "last error" not in r.stdout, "only the last 50 lines count"


def test_status_strips_colour_codes_from_the_error(bin_dir, backend, tmp_path):
    log = tmp_path / "run.log"
    log.write_text("\x1b[31mError: boom\x1b[0m\n")
    backend.info(running=False)
    r = haro_app(bin_dir, "status", api=backend.url, env={"HARO_RUN_LOG": str(log)})
    assert r.stdout == "app: stopped | last error: Error: boom\n"


def test_url_prints_the_origin_plus_the_path(bin_dir, backend):
    backend.info(url="http://localhost:4002/app/")
    assert haro_app(bin_dir, "url", api=backend.url).stdout == "http://localhost:4002/app/\n"
    r = haro_app(bin_dir, "url", "/api/slug?x=1", api=backend.url)
    assert r.stdout == "http://localhost:4002/api/slug?x=1\n"
    r = haro_app(bin_dir, "url", "worker", "/health", api=backend.url)
    assert r.stdout == "http://localhost:4002/health\n"
    assert backend.requests[-1][1].endswith("&run_id=worker")


def test_url_of_a_stopped_app_fails(bin_dir, backend):
    backend.info(running=False)
    r = haro_app(bin_dir, "url", "/x", api=backend.url)
    assert r.returncode == 1 and "not running, start it with: haro-app start" in r.stdout


def test_logs_tail_the_run_log(bin_dir, backend, tmp_path):
    log = tmp_path / "run.log"
    log.write_text("".join(f"line {i}\n" for i in range(100)))
    env = {"HARO_RUN_LOG": str(log)}
    r = haro_app(bin_dir, "logs", api=backend.url, env=env)
    assert r.stdout.splitlines() == [f"line {i}" for i in range(40, 100)]
    r = haro_app(bin_dir, "logs", "-n", "3", api=backend.url, env=env)
    assert r.stdout.splitlines() == ["line 97", "line 98", "line 99"]
    assert backend.requests == [], "the default run's log needs no backend call"


def test_logs_of_a_named_run_come_from_the_backend(bin_dir, backend, tmp_path):
    log = tmp_path / "run-worker.log"
    log.write_text("worker up\n")
    backend.info(log=str(log))
    r = haro_app(bin_dir, "logs", "worker", api=backend.url, env={"HARO_RUN_LOG": "/nope"})
    assert r.stdout == "worker up\n"


def test_logs_before_the_first_start(bin_dir, backend, tmp_path):
    r = haro_app(bin_dir, "logs", api=backend.url, env={"HARO_RUN_LOG": str(tmp_path / "none.log")})
    assert r.returncode == 0 and "no log yet" in r.stdout


def test_open_posts_the_path_as_json(bin_dir, backend):
    backend.routes[("POST", "/workspaces/w1/run/open")] = (200, "url=http://localhost:4002/api/slug\n")
    r = haro_app(bin_dir, "open", "/api/slug", api=backend.url)
    assert r.returncode == 0
    assert r.stdout == "app: offered http://localhost:4002/api/slug to the developer\n"
    assert json.loads(backend.bodies[0]) == {"path": "/api/slug"}
    haro_app(bin_dir, "open", "worker", api=backend.url)
    assert json.loads(backend.bodies[1]) == {"path": "", "run_id": "worker"}


def test_open_escapes_what_it_sends(bin_dir, backend):
    haro_app(bin_dir, "open", '/a"b\\c', api=backend.url)
    assert json.loads(backend.bodies[0]) == {"path": '/a"b\\c'}


def test_open_shows_the_backends_refusal(bin_dir, backend):
    backend.routes[("POST", "/workspaces/w1/run/open")] = (
        409, '{"detail":"the app is not running: start it with haro-app start"}'
    )
    r = haro_app(bin_dir, "open", "/x", api=backend.url)
    assert r.returncode == 1
    assert r.stdout == "haro-app: the app is not running: start it with haro-app start\n"


def test_list_prints_what_the_backend_says(bin_dir, backend):
    backend.routes[("GET", "/workspaces/w1/run/list")] = (200, "run app (default): stopped\ntool lint: eslint\n")
    r = haro_app(bin_dir, "list", api=backend.url)
    assert r.stdout == "run app (default): stopped\ntool lint: eslint\n"


def test_do_prints_the_tail_and_follows_the_exit_code(bin_dir, backend):
    backend.routes[("POST", "/workspaces/w1/tools/lint")] = (200, "all good\ntool lint: exit 0 in 0.1s\n")
    r = haro_app(bin_dir, "do", "lint", api=backend.url)
    assert r.returncode == 0 and r.stdout.endswith("tool lint: exit 0 in 0.1s\n")
    backend.routes[("POST", "/workspaces/w1/tools/lint")] = (200, "boom\ntool lint: exit 3 in 0.1s\n")
    r = haro_app(bin_dir, "do", "lint", api=backend.url)
    assert r.returncode == 1 and "boom" in r.stdout
    assert backend.requests[0] == ("POST", "/workspaces/w1/tools/lint?format=text")


def test_do_of_an_unknown_tool_fails_with_the_detail(bin_dir, backend):
    backend.routes[("POST", "/workspaces/w1/tools/nope")] = (404, '{"detail":"no tool named \'nope\'"}')
    r = haro_app(bin_dir, "do", "nope", api=backend.url)
    assert r.returncode == 1 and "no tool named" in r.stdout
    assert haro_app(bin_dir, "do", api=backend.url).returncode == 2


def test_a_run_name_picks_which_script(bin_dir, backend):
    assert haro_app(bin_dir, "stop", "worker", api=backend.url).returncode == 0
    assert backend.requests == [("POST", "/workspaces/w1/run/stop?run_id=worker")]
    backend.info(url="http://127.0.0.1:9")
    assert haro_app(bin_dir, "restart", "worker", "--no-wait", api=backend.url).returncode == 0
    assert ("POST", "/workspaces/w1/run?run_id=worker") in backend.requests


def test_an_error_from_the_backend_is_shown_and_fails(bin_dir, backend):
    r = haro_app(bin_dir, "start", api=backend.url, ws="nope")
    assert r.returncode == 1
    assert "workspace not found" in r.stdout


def test_a_wrong_command_and_a_missing_environment_both_fail(bin_dir, backend):
    r = haro_app(bin_dir, "explode", api=backend.url)
    assert r.returncode == 2 and "usage" in r.stderr
    r = haro_app(bin_dir, "status")
    assert r.returncode != 0 and "HARO_API" in r.stderr
    assert haro_app(bin_dir, "wait", "--timeout", "soon", api=backend.url).returncode == 2
    assert haro_app(bin_dir, "stop", "a/b", api=backend.url).returncode == 2


class _AppAwareAdapter(AgentAdapter):
    name = "app-aware"

    def __init__(self) -> None:
        self.seen = "unset"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False, app_control=None):
        self.seen = app_control
        yield NormalizedEvent("done", {"session_id": "s"})


def _run_with(adapter, project_path):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    agent_run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(agent_run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=agent_run,
        test_adapter=None, project_path=project_path, auto_gate=False,
    ))
    return ws


def test_the_runner_hands_the_agent_the_backend_address(log_root, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(config.settings, "api_url", "http://127.0.0.1:41417")
    monkeypatch.setattr(config.settings, "bin_dir", str(tmp_path / "bin"))
    app_ctl._written.clear()
    adapter = _AppAwareAdapter()
    ws = _run_with(adapter, _project_with_run(tmp_path, "npm start"))
    assert adapter.seen["api"] == "http://127.0.0.1:41417"
    assert adapter.seen["workspace_id"] == ws.id
    assert adapter.seen["bin_dir"] == str(tmp_path / "bin")
    assert (app_ctl.bin_dir() / "haro-app").exists()


def test_no_command_without_a_run_script_or_a_backend_address(log_root, tmp_path, monkeypatch):  # noqa: F811
    for d in ("a", "b"):
        (tmp_path / d).mkdir()
    monkeypatch.setattr(config.settings, "bin_dir", str(tmp_path / "bin"))
    app_ctl._written.clear()
    monkeypatch.setattr(config.settings, "api_url", "http://127.0.0.1:41417")
    adapter = _AppAwareAdapter()
    _run_with(adapter, _project_with_run(tmp_path / "a", None))
    assert adapter.seen is None, "no run script, no command"
    monkeypatch.setattr(config.settings, "api_url", "")
    adapter = _AppAwareAdapter()
    _run_with(adapter, _project_with_run(tmp_path / "b", "npm start"))
    assert adapter.seen is None, "no backend address, no command"


def test_a_plan_run_is_not_offered_the_command(log_root, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(config.settings, "api_url", "http://127.0.0.1:41417")
    monkeypatch.setattr(config.settings, "bin_dir", str(tmp_path / "bin"))
    app_ctl._written.clear()
    adapter = _AppAwareAdapter()
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    agent_run = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t", plan=True)
    store.add_run(agent_run)
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=adapter, workspace=ws, run=agent_run,
        test_adapter=None, project_path=_project_with_run(tmp_path, "npm start"),
        auto_gate=False, plan=True,
    ))
    assert adapter.seen is None, "a plan run edits nothing and must not run the project's scripts"


def test_a_script_that_cannot_be_written_means_no_command(log_root, tmp_path, monkeypatch):  # noqa: F811
    blocker = tmp_path / "file"
    blocker.write_text("not a directory")
    monkeypatch.setattr(config.settings, "bin_dir", str(blocker / "bin"))
    app_ctl._written.clear()
    assert app_ctl.ensure_script() is None
    monkeypatch.setattr(config.settings, "api_url", "http://127.0.0.1:41417")
    adapter = _AppAwareAdapter()
    _run_with(adapter, _project_with_run(tmp_path, "npm start"))
    assert adapter.seen is None


def test_the_command_folder_does_not_depend_on_the_log_folder(bin_dir, tmp_path, monkeypatch):
    monkeypatch.setattr(config.settings, "run_log_root", str(tmp_path / "elsewhere" / "logs"))
    assert app_ctl.bin_dir() == tmp_path / "bin"


def test_the_agent_process_gets_the_address_and_the_command_on_its_path(scripted, log_root, monkeypatch):  # noqa: F811
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_result())
        p.stdout.eof()

    async def go():
        async def consume():
            async for _ in adapter.run(
                task="t", cwd="/tmp/wt",
                app_control={"api": "http://127.0.0.1:1", "workspace_id": "w9", "bin_dir": "/x/bin"},
            ):
                pass
        t = asyncio.create_task(consume())
        await asyncio.sleep(0.05)
        await script(proc)
        await asyncio.wait_for(t, 5)

    run(go())
    env = proc.kwargs["env"]
    assert env["HARO_API"] == "http://127.0.0.1:1" and env["HARO_WORKSPACE_ID"] == "w9"
    assert env["PATH"].startswith("/x/bin" + os.pathsep)


def test_a_sandboxed_agent_can_read_the_command(monkeypatch, log_root):  # noqa: F811
    from haro.adapters import claude_code as cc

    seen = {}

    def fake_wrap(cmd, **kw):
        seen.update(kw)
        return ["bwrap", *cmd]

    monkeypatch.setattr(cc.sandbox_mod, "bwrap_available", lambda: True)
    monkeypatch.setattr(cc.sandbox_mod, "wrap_agent_command", fake_wrap)
    monkeypatch.setattr(cc.sandbox_mod, "git_common_dir", lambda cwd: None)
    monkeypatch.setattr(cc.shutil, "which", lambda name: "/usr/bin/" + name)

    async def fake_exec(*cmd, **kwargs):
        raise FileNotFoundError

    monkeypatch.setattr(cc.asyncio, "create_subprocess_exec", fake_exec)

    async def go():
        a = cc.ClaudeCodeAdapter(sandbox=True)
        return [e async for e in a.run(
            task="t", cwd="/tmp/wt",
            app_control={"api": "http://x", "workspace_id": "w", "bin_dir": "/x/bin"},
        )]

    run(go())
    assert "/x/bin" in seen["extra_ro"]


def test_the_desktop_entrypoint_publishes_its_own_address(monkeypatch):
    import desktop_app

    monkeypatch.setattr(config.settings, "api_url", "")
    monkeypatch.delenv("HARO_PARENT_PID", raising=False)
    monkeypatch.delenv("HARO_API", raising=False)
    monkeypatch.setattr(sys, "argv", ["haro-backend", "--port", "41999"])
    monkeypatch.setattr(desktop_app.uvicorn, "run", lambda *a, **k: None)
    desktop_app.main()
    assert config.settings.api_url == "http://127.0.0.1:41999"
    assert "HARO_API" not in os.environ, "not handed to every process haro starts"


@pytest.mark.parametrize(
    "host,expected",
    [
        ("127.0.0.1", "http://127.0.0.1:8000"),
        ("0.0.0.0", "http://127.0.0.1:8000"),
        ("::", "http://127.0.0.1:8000"),
        ("::1", "http://[::1]:8000"),
        ("localhost", "http://localhost:8000"),
    ],
)
def test_the_published_address_works_for_any_bind_host(host, expected):
    import desktop_app

    assert desktop_app.api_url(host, 8000) == expected


def test_the_standing_instructions_name_the_command():
    text = config.WORK_CONTRACT
    assert "haro-app restart" in text and "haro-app status" in text
    assert "Without `haro-app`" in text and "press Run" in text


def test_status_ignores_lines_that_only_mention_zero_errors(bin_dir, backend, tmp_path):
    log = tmp_path / "run.log"
    log.write_text("compiled with 0 errors\nGET /api/error-page 200\n0 failed\n")
    backend.info(url="http://localhost:4002")
    r = haro_app(bin_dir, "status", api=backend.url, env={"HARO_RUN_LOG": str(log)})
    assert r.stdout == "app: running at http://localhost:4002 (up 12s)\n"


def test_a_run_with_no_address_to_probe_is_not_waited_for(bin_dir, backend):
    backend.routes[("POST", "/workspaces/w1/run")] = (200, "{}")
    backend.info(url="http://localhost:4002", probe=0)
    r = haro_app(bin_dir, "start", "worker", "--timeout", "5", api=backend.url)
    assert r.returncode == 0, r.stdout
    assert "no address to check" in r.stdout
    assert not any(p.startswith("/workspaces/w1/run/info") and False for _, p in backend.requests)


def test_a_server_that_answers_502_is_not_ready_yet(bin_dir, backend):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(502)
            self.end_headers()

        def log_message(self, *a):
            pass

    server = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        backend.routes[("POST", "/workspaces/w1/run")] = (200, "{}")
        backend.info(url=f"http://127.0.0.1:{server.server_port}")
        r = haro_app(bin_dir, "start", "--timeout", "2", api=backend.url)
        assert r.returncode == 1 and "not answering after 2s" in r.stdout
    finally:
        server.shutdown()


def test_an_error_detail_with_quotes_is_printed_whole(bin_dir, backend):
    backend.routes[("POST", "/workspaces/w1/run/open")] = (
        400,
        '{"detail":"path must not contain a \\"quote\\" or \\u0027it\\u0027"}',
    )
    r = haro_app(bin_dir, "open", "/x", api=backend.url)
    assert r.returncode == 1
    assert r.stdout == "haro-app: path must not contain a \"quote\" or 'it'\n"


def test_an_app_that_answers_500_is_up_but_says_so(bin_dir, backend):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(500)
            self.end_headers()

        def log_message(self, *a):
            pass

    server = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        backend.routes[("POST", "/workspaces/w1/run")] = (200, "{}")
        backend.info(url=f"http://127.0.0.1:{server.server_port}")
        r = haro_app(bin_dir, "start", api=backend.url)
        assert r.returncode == 0
        assert "but it answers HTTP 500" in r.stdout
    finally:
        server.shutdown()
