"""Hot reload from haro: the run process has a stdin and ``send_run_key`` presses r / R in it
(``flutter run`` reads them there; verified with a plain pipe, no PTY needed)."""

from __future__ import annotations

import asyncio

import pytest

from haro import config, lifecycle
from haro.hub import Hub
from haro.models import Project, Workspace
from haro.store import Store

from test_run_logs import log_root  # noqa: F401


def _setup(tmp_path, command):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    psettings.runs = [config.RunScript(id="web", command=command, default=True)]
    return store, hub, ws, project, psettings


def test_a_key_reaches_the_running_process(log_root, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(lifecycle, "takes_reload_keys", lambda _c: True)
    store, hub, ws, project, ps = _setup(
        tmp_path,
        "echo 'Flutter run key commands.'; while true; do k=$(head -c 1) || exit; echo got:$k; done",
    )

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        for _ in range(100):
            if (ws.id, "web") not in store.run_starting:
                break
            await asyncio.sleep(0.1)
        run_id = await lifecycle.send_run_key(
            store=store, workspace=ws, psettings=ps, run_id=None, key="r"
        )
        await lifecycle.send_run_key(store=store, workspace=ws, psettings=ps, run_id="web", key="R")
        for _ in range(100):
            text = (log_root / ws.id / "run.log").read_text()
            if "got:r" in text and "got:R" in text:
                break
            await asyncio.sleep(0.1)
        await lifecycle.stop_run(store=store, workspace=ws)
        return run_id, text

    run_id, text = asyncio.run(go())
    assert run_id == "web"
    assert "got:r" in text and "got:R" in text


def test_only_r_and_capital_r_are_sent(log_root, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(lifecycle, "takes_reload_keys", lambda _c: True)
    store, hub, ws, project, ps = _setup(tmp_path, "sleep 30")

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        try:
            with pytest.raises(ValueError):
                await lifecycle.send_run_key(store=store, workspace=ws, psettings=ps, run_id=None, key="q")
            with pytest.raises(ValueError):
                await lifecycle.send_run_key(store=store, workspace=ws, psettings=ps, run_id=None, key="rr")
        finally:
            await lifecycle.stop_run(store=store, workspace=ws)

    asyncio.run(go())


def test_a_run_that_is_not_running_is_a_lookup_error(log_root, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(lifecycle, "takes_reload_keys", lambda _c: True)
    store, hub, ws, project, ps = _setup(tmp_path, "sleep 30")

    async def go():
        with pytest.raises(LookupError):
            await lifecycle.send_run_key(store=store, workspace=ws, psettings=ps, run_id=None, key="r")
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        await lifecycle.stop_run(store=store, workspace=ws)
        with pytest.raises(LookupError):
            await lifecycle.send_run_key(store=store, workspace=ws, psettings=ps, run_id=None, key="r")

    asyncio.run(go())


@pytest.mark.parametrize(
    "command,expected",
    [
        ("flutter run -d 192.168.1.5:5555", True),
        ("fvm flutter run", True),
        ("cd app && FOO=1 flutter run --release", True),
        ("npm run dev", False),
        ("echo flutter run is slow", False),
        ("flutter build apk", False),
    ],
)
def test_only_flutter_run_takes_reload_keys(command, expected):
    assert lifecycle.takes_reload_keys(command) is expected


def test_a_run_that_is_not_flutter_has_no_stdin_and_is_refused(log_root, tmp_path):  # noqa: F811
    store, hub, ws, project, ps = _setup(tmp_path, "sleep 30")

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        try:
            with pytest.raises(LookupError, match="not a flutter run"):
                await lifecycle.send_run_key(
                    store=store, workspace=ws, psettings=ps, run_id=None, key="r"
                )
        finally:
            await lifecycle.stop_run(store=store, workspace=ws)

    asyncio.run(go())


def test_the_route_maps_errors_to_400_404_and_409(log_root, tmp_path, monkeypatch):  # noqa: F811
    from fastapi.testclient import TestClient

    from haro import main

    store, hub, ws, project, ps = _setup(tmp_path, "sleep 30")
    store.add_project(project)
    ws.project_id = project.id
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "load_project_settings", lambda _p: ps)
    c = TestClient(main.app)
    assert c.post("/workspaces/nope/run/key?key=r").status_code == 404
    assert c.post(f"/workspaces/{ws.id}/run/key?key=q").status_code == 400
    assert c.post(f"/workspaces/{ws.id}/run/key?key=r&run_id=ghost").status_code == 400
    assert c.post(f"/workspaces/{ws.id}/run/key?key=r").status_code == 409


def _run_events(hub, ws):
    return [e for e in hub.history(ws.id) if e.get("channel") == "run" and "line" not in e]


def test_a_flutter_run_starts_as_starting_and_is_ready_at_the_key_commands_line(
    log_root, tmp_path, monkeypatch  # noqa: F811
):
    monkeypatch.setattr(lifecycle, "takes_reload_keys", lambda _c: True)
    store, hub, ws, project, ps = _setup(
        tmp_path, "echo 'Running Gradle task'; echo 'Flutter run key commands.'"
    )

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        await asyncio.wait_for(store.run_tasks[(ws.id, "web")], 10)

    asyncio.run(go())
    events = _run_events(hub, ws)
    assert events[0]["running"] is True and events[0]["starting"] is True
    assert events[1] == {"channel": "run", "run_id": "web", "ready": True}
    assert events[2]["running"] is False


def test_another_dev_server_is_never_starting(log_root, tmp_path):  # noqa: F811
    store, hub, ws, project, ps = _setup(tmp_path, "echo 'Flutter run key commands.'")

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        await asyncio.wait_for(store.run_tasks[(ws.id, "web")], 10)

    asyncio.run(go())
    events = _run_events(hub, ws)
    assert events[0]["starting"] is False
    assert not any(e.get("ready") for e in events)


def test_a_key_is_refused_while_the_run_is_starting_and_run_state_says_so(
    log_root, tmp_path, monkeypatch  # noqa: F811
):
    monkeypatch.setattr(lifecycle, "takes_reload_keys", lambda _c: True)
    store, hub, ws, project, ps = _setup(
        tmp_path, "echo building; sleep 0.5; echo 'Flutter run key commands.'; sleep 5"
    )

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=ps)
        try:
            assert lifecycle.run_state(store=store, workspace=ws, psettings=ps)["starting"] is True
            with pytest.raises(LookupError, match="still starting"):
                await lifecycle.send_run_key(
                    store=store, workspace=ws, psettings=ps, run_id=None, key="r"
                )
            for _ in range(100):
                if (ws.id, "web") not in store.run_starting:
                    break
                await asyncio.sleep(0.1)
            assert lifecycle.run_state(store=store, workspace=ws, psettings=ps)["starting"] is False
            await lifecycle.send_run_key(store=store, workspace=ws, psettings=ps, run_id=None, key="r")
        finally:
            await lifecycle.stop_run(store=store, workspace=ws)
        assert not store.run_starting

    asyncio.run(go())
