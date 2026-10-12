"""The endpoints behind `haro-app` (run info, open, list, declared tools) and their config.

Same pattern as test_project_config_routes.py: the async route handlers are driven directly
with ``asyncio.run`` against the module-level store and hub.
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from haro import config, lifecycle, main
from haro.config import load_project_settings, tools_instruction
from haro.models import OpenAppRequest, Project, Workspace


def run(coro):
    return asyncio.run(coro)


@pytest.fixture(autouse=True)
def _isolated(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    monkeypatch.setattr(config.settings, "run_log_root", str(tmp_path / "logs"))


def _project(tmp_path, toml: str, local: str = "") -> Project:
    proj = tmp_path / f"proj{len(list(tmp_path.glob('proj*')))}"
    (proj / ".haro").mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
    (proj / ".haro" / "settings.toml").write_text(toml)
    if local:
        (proj / ".haro" / "settings.local.toml").write_text(local)
    return Project(name="demo", path=str(proj), default_branch="main")


@pytest.fixture
def make(tmp_path):
    made: list[tuple[Project, Workspace]] = []

    def _make(toml: str, local: str = "") -> Workspace:
        proj = _project(tmp_path, toml, local)
        main.store.add_project(proj)
        ws = Workspace(
            project_id=proj.id, name="ws", branch="haro/ws",
            worktree_path=proj.path, base_ref="main", port=4311,
        )
        main.store.add_workspace(ws)
        made.append((proj, ws))
        return ws

    yield _make
    for proj, ws in made:
        for key in [k for k, p in main.store.run_procs.items() if k[0] == ws.id and isinstance(p, SimpleNamespace)]:
            main.store.run_procs.pop(key)
            main.store.run_started.pop(key, None)
        run(lifecycle.stop_run(store=main.store, workspace=ws))
        main.store.remove_workspace(ws.id)
        main.store.remove_project(proj.id)


def _body(resp) -> str:
    return resp.body.decode()


def _fake_running(ws: Workspace, run_id: str = "app", *, started_ago: float = 12.0) -> None:
    main.store.run_procs[(ws.id, run_id)] = SimpleNamespace(returncode=None)
    main.store.run_started[(ws.id, run_id)] = time.monotonic() - started_ago


# -- config -------------------------------------------------------------------


def test_tools_are_parsed_with_defaults_and_clamps(tmp_path):
    proj = _project(
        tmp_path,
        '[scripts.tools.lint]\ncommand = "npm run lint"\ndescription = "eslint"\n'
        '[scripts.tools.slow]\ncommand = "make slow"\ntimeout = 99999\n'
        '[scripts.tools.zero]\ncommand = "true"\ntimeout = 0\n'
        '[scripts.tools.nocommand]\ndescription = "nothing to run"\n'
        '[scripts.tools."bad name"]\ncommand = "true"\n'
        '[scripts.tools.junk]\ncommand = "true"\ntimeout = "soon"\n',
    )
    tools = {t.name: t for t in load_project_settings(proj.path).tools}
    assert list(tools) == ["lint", "slow", "zero", "junk"]
    assert (tools["lint"].command, tools["lint"].description, tools["lint"].timeout) == ("npm run lint", "eslint", 300)
    assert tools["slow"].timeout == 1800
    assert tools["zero"].timeout == 1
    assert tools["junk"].timeout == 300


def test_a_local_tools_table_replaces_the_committed_one(tmp_path):
    proj = _project(
        tmp_path,
        '[scripts.tools.a]\ncommand = "echo a"\n',
        '[scripts.tools.b]\ncommand = "echo b"\n',
    )
    assert [t.name for t in load_project_settings(proj.path).tools] == ["b"]


def test_the_user_layer_can_declare_tools_too(tmp_path, monkeypatch):
    user = tmp_path / "user.toml"
    user.write_text('[scripts.tools.fmt]\ncommand = "ruff format"\n')
    monkeypatch.setenv("HARO_USER_CONFIG", str(user))
    proj = _project(tmp_path, "")
    assert [t.name for t in load_project_settings(proj.path).tools] == ["fmt"]


def test_no_tools_by_default(tmp_path):
    proj = _project(tmp_path, '[scripts]\nrun = "npm start"\n')
    ps = load_project_settings(proj.path)
    assert ps.tools == [] and tools_instruction(ps.tools) == ""


def test_auto_open_app_defaults_off_and_is_read_from_agent(tmp_path):
    assert load_project_settings(_project(tmp_path, "").path).agent_auto_open_app is False
    other = tmp_path / "other"
    other.mkdir()
    proj = _project(other, "[agent]\nauto_open_app = true\n")
    assert load_project_settings(proj.path).agent_auto_open_app is True


def test_the_tools_line_lists_names_and_descriptions():
    line = tools_instruction([
        config.ToolScript("lint", "x", "eslint the app"),
        config.ToolScript("seed", "y"),
    ])
    assert line == "This project declares commands you can run with `haro-app do <name>`: lint (eslint the app), seed."


def test_the_standing_instructions_describe_every_verb():
    text = config.WORK_CONTRACT
    for verb in ("haro-app wait", "haro-app url", "haro-app logs", "haro-app open", "haro-app list", "haro-app do"):
        assert verb in text


# -- run/info -----------------------------------------------------------------


def test_info_of_a_stopped_run(make):
    ws = make('[scripts]\nrun = "x"\n')
    info = run(main.run_info(ws.id))
    assert info == {"name": "app", "running": False, "url": None, "port": 4311, "up_seconds": None}


def test_info_of_a_running_run_has_url_port_and_uptime(make):
    ws = make('[scripts]\nrun = "x"\n')
    _fake_running(ws, started_ago=12)
    info = run(main.run_info(ws.id))
    assert info["running"] is True and info["url"] == "http://localhost:4311" and info["port"] == 4311
    assert 12 <= info["up_seconds"] <= 14


def test_info_follows_the_configured_url(make):
    ws = make('[scripts.run.web]\ncommand = "x"\nurl = "https://dev.test:8443/app"\n')
    info = run(main.run_info(ws.id))
    assert info["url"] == "https://dev.test:8443/app" and info["port"] == 8443 and info["name"] == "web"


def test_info_text_is_key_value_lines_with_the_log_path(make, tmp_path):
    ws = make('[scripts.run.web]\ncommand = "x"\ndefault = true\n[scripts.run.worker]\ncommand = "y"\n')
    _fake_running(ws, "web", started_ago=3)
    text = _body(run(main.run_info(ws.id, format="text")))
    lines = dict(line.split("=", 1) for line in text.splitlines())
    assert lines["name"] == "web" and lines["running"] == "1" and lines["url"] == "http://localhost:4311"
    assert lines["log"] == str(tmp_path / "logs" / ws.id / "run.log")
    other = _body(run(main.run_info(ws.id, run_id="worker", format="text")))
    assert f"log={tmp_path}/logs/{ws.id}/run-worker.log" in other and "running=0" in other


def test_info_errors(make):
    ws = make('[scripts]\nrun = "x"\n')
    with pytest.raises(HTTPException) as e:
        run(main.run_info(ws.id, run_id="nope"))
    assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        run(main.run_info("missing"))
    assert e.value.status_code == 404
    bare = make("")
    with pytest.raises(HTTPException) as e:
        run(main.run_info(bare.id))
    assert e.value.status_code == 400 and "no `run` script" in e.value.detail


def test_info_of_a_real_dev_server_and_after_stop(make):
    ws = make(f'[scripts]\nrun = "{sys.executable} -m http.server $HARO_PORT --bind 127.0.0.1"\n')

    async def go():
        await main.run_app(ws.id)
        running = await main.run_info(ws.id)
        await main.stop_app(ws.id)
        return running, await main.run_info(ws.id)

    running, stopped = run(go())
    assert running["running"] is True and running["up_seconds"] == 0
    assert stopped["running"] is False and stopped["up_seconds"] is None


# -- run/open -----------------------------------------------------------------


def _open(ws, path, run_id=None):
    return run(main.run_open(ws.id, OpenAppRequest(path=path, run_id=run_id)))


@pytest.mark.parametrize(
    "path",
    ["//evil.com", "//evil.com/x", "http://x", "https://evil.com/a", "evil.com", "api", "/\\evil.com",
     "/a\\b", "/a\nb", "/a\x00b", "/a b", "/" + "x" * 500, "javascript:alert(1)"],
)
def test_open_refuses_anything_that_is_not_a_plain_path(make, path):
    ws = make('[scripts]\nrun = "x"\n')
    _fake_running(ws)
    with pytest.raises(HTTPException) as e:
        _open(ws, path)
    assert e.value.status_code == 400


def test_open_needs_the_app_running(make):
    ws = make('[scripts]\nrun = "x"\n')
    with pytest.raises(HTTPException) as e:
        _open(ws, "/x")
    assert e.value.status_code == 409
    assert e.value.detail == "the app is not running: start it with haro-app start"


def test_a_bad_path_is_refused_before_the_running_check(make):
    ws = make('[scripts]\nrun = "x"\n')
    with pytest.raises(HTTPException) as e:
        _open(ws, "//evil.com")
    assert e.value.status_code == 400


def test_open_builds_the_url_from_the_runs_own_origin(make):
    ws = make('[scripts]\nrun = "x"\n')
    _fake_running(ws)
    q = main.hub.subscribe(ws.id)
    try:
        res = _open(ws, "/api/slug?x=1#top")
        assert res["url"] == "http://localhost:4311/api/slug?x=1#top" and res["auto"] is False
        env = q.get_nowait()
    finally:
        main.hub.unsubscribe(ws.id, q)
    assert env["channel"] == "status" and env["workspace_id"] == ws.id
    s = env["suggest_open"]
    assert s["url"] == "http://localhost:4311/api/slug?x=1#top" and s["path"] == "/api/slug?x=1#top"
    assert s["run_id"] == "app" and s["auto"] is False and abs(s["at"] - time.time()) < 5


def test_open_uses_only_the_origin_of_a_configured_url(make):
    ws = make('[scripts.run.web]\ncommand = "x"\nurl = "https://dev.test:8443/base/"\n')
    _fake_running(ws, "web")
    assert _open(ws, "/health")["url"] == "https://dev.test:8443/health"
    assert _open(ws, "")["url"] == "https://dev.test:8443/base/"


def test_open_carries_the_auto_setting(make):
    ws = make('[scripts]\nrun = "x"\n[agent]\nauto_open_app = true\n')
    _fake_running(ws)
    q = main.hub.subscribe(ws.id)
    try:
        assert _open(ws, "/")["auto"] is True
        assert q.get_nowait()["suggest_open"]["auto"] is True
    finally:
        main.hub.unsubscribe(ws.id, q)


def test_open_reaches_the_global_feed(make):
    ws = make('[scripts]\nrun = "x"\n')
    _fake_running(ws)
    g = main.hub.subscribe_global()
    try:
        _open(ws, "/x")
        env = g.get_nowait()
    finally:
        main.hub.unsubscribe_global(g)
    assert env["workspace_id"] == ws.id and env["suggest_open"]["path"] == "/x"


def test_open_text_answers_the_url(make):
    ws = make('[scripts]\nrun = "x"\n')
    _fake_running(ws)
    res = run(main.run_open(ws.id, OpenAppRequest(path="/x"), format="text"))
    assert _body(res) == "url=http://localhost:4311/x\n"


# -- list and declared tools ----------------------------------------------------


TOOLS = (
    '[scripts.run.web]\ncommand = "x"\ndefault = true\n[scripts.run.worker]\ncommand = "y"\n'
    '[scripts.tools.lint]\ncommand = "echo linted"\ndescription = "eslint the app"\n'
    '[scripts.tools.seed]\ncommand = "echo seeded"\n'
)


def test_list_shows_runs_and_tools(make):
    ws = make(TOOLS)
    _fake_running(ws, "web")
    text = _body(run(main.run_list(ws.id, format="text")))
    assert text == (
        "run web (default): running at http://localhost:4311\n"
        "run worker: stopped\n"
        "tool lint: eslint the app\n"
        "tool seed\n"
    )
    data = run(main.run_list(ws.id))
    assert [r["name"] for r in data["runs"]] == ["web", "worker"] and data["runs"][0]["default"] is True
    assert [t["name"] for t in data["tools"]] == ["lint", "seed"]


def test_list_of_a_bare_project(make):
    ws = make("")
    assert _body(run(main.run_list(ws.id, format="text"))) == "no run scripts or tools declared\n"


# -- running a tool --------------------------------------------------------------


def _tool(ws, name, **kw):
    return run(main.run_declared_tool(ws.id, name, **kw))


def test_a_tool_runs_in_the_worktree_and_returns_its_tail(make):
    ws = make('[scripts.tools.t]\ncommand = "echo hello; echo port=$HARO_PORT; pwd"\n')
    out = _tool(ws, "t")
    assert out["exit"] == 0 and out["timed_out"] is False
    lines = out["tail"].splitlines()
    assert lines[0] == "hello" and lines[1] == "port=4311" and lines[2] == ws.worktree_path


def test_a_failing_tool_reports_its_exit_code(make):
    ws = make('[scripts.tools.t]\ncommand = "echo boom >&2; exit 3"\n')
    out = _tool(ws, "t")
    assert out["exit"] == 3 and out["tail"] == "boom"


def test_the_tail_is_the_last_40_lines_without_colour_or_redraws(make):
    cmd = "i=1; while [ $i -le 60 ]; do printf '\\033[31mline %d\\033[0m\\n' $i; i=$((i+1)); done; printf 'a\\rb\\rfinal\\n'"
    ws = make(f"[scripts.tools.t]\ncommand = '''{cmd}'''\n")
    lines = _tool(ws, "t")["tail"].splitlines()
    assert len(lines) == 40 and lines[-1] == "final" and lines[-2] == "line 60"
    assert "\x1b" not in "".join(lines)


def test_a_tool_that_outlives_its_timeout_is_killed_with_its_children(make, tmp_path):
    marker = tmp_path / "child-alive"
    cmd = f"(sleep 30; touch {marker}) & sleep 30"
    ws = make(f"[scripts.tools.slow]\ncommand = '''{cmd}'''\ntimeout = 1\n")
    started = time.monotonic()
    out = _tool(ws, "slow")
    assert out["timed_out"] is True and out["exit"] == 124
    assert time.monotonic() - started < 10
    assert not marker.exists()
    text = _body(_tool(ws, "slow", format="text"))
    assert "tool slow: timed out after 1s, killed\n" in text
    assert text.splitlines()[-1].startswith("tool slow: exit 124 in ")


def test_an_undeclared_tool_is_a_404(make):
    ws = make(TOOLS)
    with pytest.raises(HTTPException) as e:
        _tool(ws, "rm-rf")
    assert e.value.status_code == 404


def test_a_tool_waits_for_setup_to_finish(make):
    ws = make(TOOLS)

    async def go():
        task = asyncio.create_task(asyncio.sleep(5))
        main.store.set_active_task(ws.id, main.SETUP_SESSION, task)
        try:
            await main.run_declared_tool(ws.id, "lint")
        finally:
            task.cancel()
            main.store.pop_active_task(ws.id, main.SETUP_SESSION)

    with pytest.raises(HTTPException) as e:
        run(go())
    assert e.value.status_code == 409


def test_a_tool_may_run_while_an_agent_works(make):
    ws = make(TOOLS)

    async def go():
        task = asyncio.create_task(asyncio.sleep(5))
        main.store.set_active_task(ws.id, "main", task)
        try:
            return await main.run_declared_tool(ws.id, "lint")
        finally:
            task.cancel()
            main.store.pop_active_task(ws.id, "main")

    assert run(go())["exit"] == 0


def test_tool_output_streams_to_the_dev_log(make):
    ws = make('[scripts.tools.t]\ncommand = "echo one; echo two"\n')
    q = main.hub.subscribe(ws.id)
    try:
        _tool(ws, "t")
        lines = []
        while not q.empty():
            env = q.get_nowait()
            if env.get("channel") == "run":
                lines.append(env["line"])
    finally:
        main.hub.unsubscribe(ws.id, q)
    assert lines[0].startswith("◆ tool t: echo one") and "one" in lines and "two" in lines
    assert lines[-1] == "◆ tool t finished (exit 0)"


def test_tool_text_ends_with_the_exit_line(make):
    ws = make('[scripts.tools.t]\ncommand = "echo hi; exit 2"\n')
    text = _body(_tool(ws, "t", format="text"))
    assert text.startswith("hi\n") and text.rstrip().rsplit("\n", 1)[1].startswith("tool t: exit 2 in ")


# -- the agent is told about the tools only when it has the command --------------


def test_the_tools_line_reaches_the_run_instructions(make, tmp_path, monkeypatch):
    from haro import app_ctl
    from haro.adapters.base import AgentAdapter, NormalizedEvent
    from haro.hub import Hub
    from haro.models import AgentRun
    from haro.runner import run_agent
    from haro.store import Store

    monkeypatch.setattr(config.settings, "api_url", "http://127.0.0.1:41417")
    monkeypatch.setattr(config.settings, "bin_dir", str(tmp_path / "bin"))
    app_ctl._written.clear()

    class Adapter(AgentAdapter):
        name = "t"

        def __init__(self):
            self.kw = None

        async def run(self, *, task, cwd, instructions=None, plan=False, app_control=None, **_):
            self.kw = {"instructions": instructions, "app_control": app_control}
            yield NormalizedEvent("done", {"session_id": "s"})

    def go(project_path, plan=False):
        adapter, store, hub = Adapter(), Store(), Hub()
        ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/tmp/wt", base_ref="main")
        store.add_workspace(ws)
        r = AgentRun(workspace_id=ws.id, adapter="t", task="t", plan=plan)
        store.add_run(r)
        asyncio.run(run_agent(
            store=store, hub=hub, adapter=adapter, workspace=ws, run=r, test_adapter=None,
            project_path=project_path, auto_gate=False, instructions="base", plan=plan,
        ))
        return adapter.kw

    with_tools = _project(tmp_path, '[scripts]\nrun = "x"\n[scripts.tools.lint]\ncommand = "l"\ndescription = "eslint"\n')
    kw = go(with_tools.path)
    assert kw["instructions"].startswith("base\n\n") and "haro-app do <name>`: lint (eslint)" in kw["instructions"]
    assert kw["app_control"] is not None
    assert "haro-app do" not in go(with_tools.path, plan=True)["instructions"]

    other = tmp_path / "other"
    other.mkdir()
    no_tools = _project(other, '[scripts]\nrun = "x"\n')
    assert go(no_tools.path)["instructions"] == "base"

    only_tools = tmp_path / "only"
    only_tools.mkdir()
    p = _project(only_tools, '[scripts.tools.lint]\ncommand = "l"\n')
    kw = go(p.path)
    assert kw["app_control"] is not None and "lint" in kw["instructions"]


def test_an_open_suggestion_is_not_replayed_to_a_later_subscriber(make):
    ws = make('[scripts]\nrun = "x"\n')
    _fake_running(ws)
    _open(ws, "/dashboard")
    assert not [e for e in main.hub.history(ws.id) if "suggest_open" in e]


def test_a_run_has_a_probe_flag_only_with_an_address_of_its_own(make):
    ws = make(
        '[scripts.run.web]\ncommand = "w"\n\n[scripts.run.worker]\ncommand = "k"\n\n'
        '[scripts.run.api]\ncommand = "a"\nurl = "http://localhost:9000"\n'
    )
    info = lambda r: lifecycle.run_state(  # noqa: E731
        store=main.store, workspace=ws, psettings=load_project_settings(ws.worktree_path), run_id=r
    )
    assert info("web")["probe"] == 1
    assert info("worker")["probe"] == 0
    assert info("api")["probe"] == 1


def test_the_runbook_rewrite_keeps_declared_tools(tmp_path):
    proj = tmp_path / "p"
    (proj / ".haro").mkdir(parents=True)
    (proj / ".haro" / "settings.toml").write_text(
        '[scripts]\nrun = "old"\n\n[scripts.tools.migrate]\ncommand = "npm run migrate"\n'
        'description = "apply migrations"\ntimeout = 600\n\n[scripts.tools.seed]\ncommand = "node seed.js"\n'
    )
    config.write_project_scripts(
        str(proj), setup=None, run="npm start", archive=None, run_mode="concurrent",
        login_shell=False, port_range=(4500, 4599), target="shared",
    )
    ps = load_project_settings(str(proj))
    assert [(t.name, t.command, t.description, t.timeout) for t in ps.tools] == [
        ("migrate", "npm run migrate", "apply migrations", 600),
        ("seed", "node seed.js", "", 300),
    ]
    assert ps.run == "npm start"


def test_the_same_tool_cannot_run_twice_at_once(make):
    ws = make(TOOLS)
    main.store.tools_running.add((ws.id, "lint"))
    try:
        with pytest.raises(HTTPException) as e:
            run(main.run_declared_tool(ws.id, "lint"))
        assert e.value.status_code == 409 and "already running" in e.value.detail
    finally:
        main.store.tools_running.discard((ws.id, "lint"))
    assert run(main.run_declared_tool(ws.id, "lint"))["exit"] == 0
    assert (ws.id, "lint") not in main.store.tools_running


def test_a_tool_does_not_run_under_the_gate(make):
    from haro.models import WorkspaceStatus

    ws = make(TOOLS)
    ws.status = WorkspaceStatus.tests_running
    try:
        with pytest.raises(HTTPException) as e:
            run(main.run_declared_tool(ws.id, "lint"))
        assert e.value.status_code == 409 and "gate" in e.value.detail
    finally:
        ws.status = WorkspaceStatus.idle
