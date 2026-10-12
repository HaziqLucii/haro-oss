"""The running app's output on disk, for the agent to watch (run_logs.py).

haro runs the dev server, so its lines are kept in ``<log root>/<workspace>/run.log`` and the
agent is told the path in ``$HARO_RUN_LOG`` instead of starting a background shell of its own
(which the CLI kills when the turn ends).
"""

from __future__ import annotations

import asyncio
import os
import stat

import pytest

from haro import config, lifecycle, run_logs
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.models import AgentRun, Project, Workspace
from haro.runner import run_agent
from haro.store import Store
from haro.hub import Hub

from test_stop_subagent import _drive, _result, run, scripted  # noqa: F401


@pytest.fixture(autouse=True)
def log_root(tmp_path, monkeypatch):
    monkeypatch.setattr(config.settings, "run_log_root", str(tmp_path / "logs"))
    return tmp_path / "logs"


def test_the_default_run_is_run_log_and_a_named_one_has_its_name(log_root):
    assert run_logs.run_log_path("w1", "web", default=True) == log_root / "w1" / "run.log"
    assert run_logs.run_log_path("w1", "worker", default=False) == log_root / "w1" / "run-worker.log"


def test_lines_are_appended_and_a_new_start_empties_the_file(log_root):
    path = run_logs.run_log_path("w1", "web", default=True)
    log = run_logs.RunLog(path)
    log.write("listening on :4000")
    log.write("GET /health 200\n")
    log.close()
    assert path.read_text() == "listening on :4000\nGET /health 200\n"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600

    again = run_logs.RunLog(path)
    again.close()
    assert path.read_text() == ""


def test_the_file_is_capped_and_keeps_the_newest_whole_lines(log_root):
    path = run_logs.run_log_path("w1", "web", default=True)
    log = run_logs.RunLog(path, cap=1000)
    for i in range(200):
        log.write(f"line {i:04d} " + "x" * 20)
    log.close()
    text = path.read_text()
    assert len(text.encode()) <= 1000
    lines = text.splitlines()
    assert lines[-1].startswith("line 0199")
    assert all(line.startswith("line ") for line in lines), "starts on a line boundary"


def test_a_disk_error_never_breaks_the_run(tmp_path, monkeypatch):
    blocker = tmp_path / "file"
    blocker.write_text("not a directory")
    log = run_logs.RunLog(blocker / "sub" / "run.log")
    log.write("still fine")
    log.close()


def test_the_run_script_output_is_kept_while_it_streams(log_root, tmp_path):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    psettings.runs = [config.RunScript(id="web", command="printf 'hello\\nworld\\n'", default=True)]

    async def go():
        await lifecycle.start_run(
            store=store, hub=hub, workspace=ws, project=project, psettings=psettings
        )
        task = store.run_tasks[(ws.id, "web")]
        await asyncio.wait_for(task, 10)

    asyncio.run(go())
    text = (log_root / ws.id / "run.log").read_text()
    assert "$ printf" in text and "hello\nworld\n" in text and "run exited (0)" in text


def test_tearing_a_workspace_down_removes_its_logs(log_root):
    path = run_logs.run_log_path("w1", "web", default=True)
    run_logs.RunLog(path).close()
    assert path.exists()
    run_logs.remove_workspace_logs("w1")
    assert not (log_root / "w1").exists()


class _LogAwareAdapter(AgentAdapter):
    name = "log-aware"

    def __init__(self) -> None:
        self.seen = "unset"

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, run_log_dir=None):
        self.seen = run_log_dir
        yield NormalizedEvent("done", {"session_id": "s"})


def _project_with_run(tmp_path, run_line: str | None):
    proj = tmp_path / "proj"
    (proj / ".haro").mkdir(parents=True)
    if run_line:
        (proj / ".haro" / "settings.toml").write_text(f"[scripts]\nrun = {run_line!r}\n".replace("'", '"'))
    return str(proj)


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


def test_the_runner_hands_the_log_directory_to_an_adapter_that_takes_it(log_root, tmp_path):
    adapter = _LogAwareAdapter()
    ws = _run_with(adapter, _project_with_run(tmp_path, "npm start"))
    assert adapter.seen == str(log_root / ws.id)
    assert (log_root / ws.id).is_dir(), "created, so a sandbox can bind it before the first Run"


def test_a_project_without_a_run_script_gets_no_log_variables(log_root, tmp_path):
    adapter = _LogAwareAdapter()
    _run_with(adapter, _project_with_run(tmp_path, None))
    assert adapter.seen is None
    assert not log_root.exists()


def test_the_agent_process_gets_the_log_path_in_its_environment(scripted, log_root):  # noqa: F811
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_result())
        p.stdout.eof()

    async def go():
        events = []
        async def consume():
            async for ev in adapter.run(task="t", cwd="/tmp/wt", run_log_dir=str(log_root / "w1")):
                events.append(ev)
        t = asyncio.create_task(consume())
        await asyncio.sleep(0.05)
        await script(proc)
        await asyncio.wait_for(t, 5)

    run(go())
    env = proc.kwargs["env"]
    assert env["HARO_RUN_LOG"] == str(log_root / "w1" / "run.log")
    assert env["HARO_LOG_DIR"] == str(log_root / "w1")
    assert env["PATH"] == os.environ["PATH"]


def test_without_a_log_directory_the_environment_is_untouched(scripted):  # noqa: F811
    adapter, proc = scripted

    async def script(p):
        p.stdout.feed(_result())
        p.stdout.eof()

    run(_drive(adapter, proc, script))
    assert proc.kwargs["env"] is None


def test_the_standing_instructions_tell_the_agent_where_the_app_log_is():
    text = config.WORK_CONTRACT
    assert "$HARO_RUN_LOG" in text
    assert "Monitor" in text
    assert "haro-app restart" in text


def test_a_sandboxed_agent_can_read_the_log_directory(monkeypatch, log_root):
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
        adapter = cc.ClaudeCodeAdapter(sandbox=True)
        return [e async for e in adapter.run(task="t", cwd="/tmp/wt", run_log_dir=str(log_root / "w1"))]

    run(go())
    assert seen["extra_ro"] == (str(log_root / "w1"),)


def test_a_run_name_from_the_settings_file_cannot_leave_the_log_folder(log_root):
    path = run_logs.run_log_path("w1", "../../evil/x", default=False)
    assert path.parent == log_root / "w1"
    assert path.name == "run-evil_x.log"


def test_the_only_run_script_is_run_log_even_when_not_marked_default(log_root, tmp_path):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    psettings.runs = [config.RunScript(id="web", command="printf 'x\\n'", default=False)]

    async def go():
        await lifecycle.start_run(
            store=store, hub=hub, workspace=ws, project=project, psettings=psettings
        )
        await asyncio.wait_for(store.run_tasks[(ws.id, "web")], 10)

    asyncio.run(go())
    assert (log_root / ws.id / "run.log").exists()


def test_a_failed_compaction_does_not_retry_on_every_line(log_root, monkeypatch):
    path = run_logs.run_log_path("w1", "web", default=True)
    log = run_logs.RunLog(path, cap=200)
    calls = []
    real = os.replace

    def boom(*a, **k):
        calls.append(1)
        raise OSError("disk")

    monkeypatch.setattr(os, "replace", boom)
    for i in range(60):
        log.write(f"line {i} " + "x" * 20)
    monkeypatch.setattr(os, "replace", real)
    log.close()
    assert len(calls) < 10, "one failure resets the count instead of failing on every write"
    assert path.read_text().endswith("line 59 " + "x" * 20 + "\n")


def test_a_configured_url_replaces_the_reserved_port_in_the_run_event(log_root, tmp_path):
    store = Store()
    published = []

    class Spy(Hub):
        async def publish(self, workspace_id, envelope):
            published.append(envelope)

    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main", port=4000)
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    psettings.runs = [
        config.RunScript(id="web", command="true", default=True, url="http://localhost:4200")
    ]

    async def go():
        url = await lifecycle.start_run(
            store=store, hub=Spy(), workspace=ws, project=project, psettings=psettings
        )
        await asyncio.wait_for(store.run_tasks[(ws.id, "web")], 10)
        return url

    assert asyncio.run(go()) == "http://localhost:4200"
    urls = {e.get("url") for e in published if e.get("running") is not None}
    assert urls == {"http://localhost:4200"}
    assert "→ http://localhost:4200" in (log_root / ws.id / "run.log").read_text()


def test_the_run_menu_shows_the_configured_url_even_when_stopped():
    from haro import main

    ps = config.ProjectSettings()
    ps.runs = [
        config.RunScript(id="web", command="npm start", default=True, url="http://localhost:4200"),
        config.RunScript(id="worker", command="npm run worker"),
    ]
    web, worker = main._run_infos(ps)
    assert web.url == "http://localhost:4200" and worker.url is None


def test_a_second_run_script_with_a_fixed_url_holds_no_port(log_root, tmp_path):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main", port=4000)
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    psettings.runs = [
        config.RunScript(id="web", command="true", default=True),
        config.RunScript(id="api", command="true", url="http://localhost:3000"),
    ]

    async def go():
        await lifecycle.start_run(
            store=store, hub=hub, workspace=ws, project=project, psettings=psettings, run_id="api"
        )
        await asyncio.wait_for(store.run_tasks[(ws.id, "api")], 10)

    asyncio.run(go())
    assert store.allocated_ports == set()
