"""A client that reconnects must learn which runs are going from the live process table, not from
the hub's replay buffer (1000 envelopes per workspace, one per dev-server log line): a stack
that logs steadily pushed the "run started" envelope out, and the app showed as stopped while
it ran."""

from __future__ import annotations

import asyncio

import pytest

from haro import config, main as main_mod
from haro.hub import Hub
from haro.models import Project, Workspace
from haro.store import Store


class _Proc:
    def __init__(self, returncode=None):
        self.returncode = returncode


@pytest.fixture
def wired(monkeypatch, tmp_path):
    store, hub = Store(), Hub()
    monkeypatch.setattr(main_mod, "store", store)
    monkeypatch.setattr(main_mod, "hub", hub)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    store.add_project(project)
    ws = Workspace(project_id=project.id, name="w", branch="b", worktree_path=str(tmp_path), base_ref="main", port=4000)
    store.add_workspace(ws)
    ps = config.ProjectSettings()
    ps.runs = [
        config.RunScript(id="web", command="x", default=True),
        config.RunScript(id="worker", command="y", default=False),
    ]
    monkeypatch.setattr(main_mod, "load_project_settings", lambda _path: ps)
    return store, hub, ws


def test_a_running_run_is_listed_with_its_address_and_a_stopped_one_is_not(wired):
    store, _hub, ws = wired
    store.run_procs[(ws.id, "web")] = _Proc()
    store.run_procs[(ws.id, "worker")] = _Proc(returncode=0)  # exited
    assert main_mod._run_snapshot(ws.id) == [
        {"channel": "run", "run_id": "web", "running": True, "starting": False, "url": "http://localhost:4000"},
    ]


def test_a_run_that_is_still_starting_says_so(wired):
    store, _hub, ws = wired
    store.run_procs[(ws.id, "web")] = _Proc()
    store.run_starting.add((ws.id, "web"))
    assert main_mod._run_snapshot(ws.id)[0]["starting"] is True


def test_nothing_running_or_an_unknown_workspace_gives_nothing(wired):
    _store, _hub, ws = wired
    assert main_mod._run_snapshot(ws.id) == []
    assert main_mod._run_snapshot("ws_nope") == []


def test_a_broken_settings_file_does_not_break_the_socket(wired, monkeypatch):
    _store, _hub, ws = wired

    def boom(_path):
        raise ValueError("bad toml")

    monkeypatch.setattr(main_mod, "load_project_settings", boom)
    assert main_mod._run_snapshot(ws.id) == []


class _Socket:
    def __init__(self):
        self.sent: list[dict] = []

    async def accept(self):
        return None

    async def send_json(self, envelope):
        self.sent.append(envelope)


def test_a_reconnect_learns_the_run_is_going_although_the_buffer_holds_only_log_lines(wired):
    store, hub, ws = wired
    store.run_procs[(ws.id, "web")] = _Proc()

    async def go():
        # 2500 log lines, no "started" envelope: it was pushed out of the 1000-envelope buffer.
        for i in range(2500):
            await hub.publish(ws.id, {"channel": "run", "run_id": "web", "line": f"api poll {i}"})
        sock = _Socket()
        task = asyncio.ensure_future(main_mod.workspace_ws(sock, ws.id))
        for _ in range(200):
            if len(sock.sent) >= 1001:
                break
            await asyncio.sleep(0.01)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        return sock.sent

    sent = asyncio.run(go())
    # The live state comes FIRST (a running envelope clears the Dev log), then the replay.
    assert sent[0] == {"channel": "run", "run_id": "web", "running": True, "starting": False, "url": "http://localhost:4000"}
    assert all(e.get("line") for e in sent[1:]) and len(sent) == 1001
    assert sent[-1]["line"] == "api poll 2499"


def test_a_stopped_run_adds_no_running_envelope_on_reconnect(wired):
    store, hub, ws = wired
    store.run_procs[(ws.id, "web")] = _Proc(returncode=1)

    async def go():
        await hub.publish(ws.id, {"channel": "run", "run_id": "web", "running": False, "exit": 1})
        sock = _Socket()
        task = asyncio.ensure_future(main_mod.workspace_ws(sock, ws.id))
        for _ in range(100):
            if sock.sent:
                break
            await asyncio.sleep(0.01)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        return sock.sent

    sent = asyncio.run(go())
    assert sent == [{"channel": "run", "run_id": "web", "running": False, "exit": 1}]
