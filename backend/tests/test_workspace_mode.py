"""Workspace mode (agent | manual): who writes the code.

Manual is a promise that no agent edits the worktree, so the load-bearing tests are the
refusals: every path that can start an editing agent must 409 in a manual workspace, and the
read-only review must keep working. The mode also has to ride every status publish (the Flutter
client patches its workspace list from those) and survive a snapshot round trip.
"""

from __future__ import annotations

import asyncio
import subprocess
from datetime import datetime, timezone

import pytest
from fastapi import HTTPException

from haro import github_accounts, main, receipt as receipt_svc
from haro.config import load_project_settings
from haro.hub import Hub
from haro.models import (
    AgentRun,
    CreateWorkspaceRequest,
    ModeSwitch,
    Project,
    ReviewRequest,
    ReviewResult,
    SetModeRequest,
    StartAgentRequest,
    Workspace,
    status_payload,
)
from haro.models import TestFirstState as FirstState
from haro.store import DEFAULT_SESSION, SETUP_SESSION, Store


def _git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()


def _repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.com")
    _git(repo, "config", "user.name", "t")
    (repo / "f.txt").write_text("x\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "init")
    return repo


def _wire(monkeypatch, tmp_path, **ws_kw):
    repo = _repo(tmp_path)
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id="p", name="w", branch="main", worktree_path=str(repo), base_ref="main", **ws_kw
    )
    store.workspaces[ws.id] = ws
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "hub", hub)
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    return store, hub, ws, repo


def _run(coro):
    return asyncio.run(coro)


def _conflict(coro, fragment):
    with pytest.raises(HTTPException) as e:
        _run(coro)
    assert e.value.status_code == 409
    assert fragment in e.value.detail


# ---- create / hydrate ------------------------------------------------------------------


def _create(monkeypatch, tmp_path, req):
    repo = _repo(tmp_path)
    store = Store()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr("haro.store.settings.worktree_root", str(tmp_path / "wt"))

    async def spy(**_kw):
        return None

    monkeypatch.setattr(main, "run_setup", spy)

    async def go():
        ws = await main.create_workspace("p", req)
        task = store.active_task(ws.id, SETUP_SESSION)
        if task is not None:
            await task
        return ws

    return _run(go())


def test_create_defaults_to_agent(monkeypatch, tmp_path):
    ws = _create(monkeypatch, tmp_path, CreateWorkspaceRequest(name="alpha"))
    assert ws.mode == "agent" and ws.mode_switches == []


def test_create_with_manual_mode_is_stored(monkeypatch, tmp_path):
    ws = _create(monkeypatch, tmp_path, CreateWorkspaceRequest(name="beta", mode="manual"))
    assert ws.mode == "manual"


def test_old_snapshot_without_mode_hydrates_as_agent():
    legacy = Workspace(
        project_id="p", name="w", branch="b", worktree_path="/tmp/w", base_ref="main"
    ).model_dump()
    legacy.pop("mode")
    legacy.pop("mode_switches")
    ws = Workspace.model_validate(legacy)
    assert ws.mode == "agent" and ws.mode_switches == []


def test_mode_and_switches_survive_a_snapshot_round_trip():
    ws = Workspace(
        project_id="p", name="w", branch="b", worktree_path="/tmp/w", base_ref="main",
        mode="manual", mode_switches=[ModeSwitch(to="manual", sha="abc")],
    )
    back = Workspace.model_validate_json(ws.model_dump_json())
    assert back.mode == "manual"
    assert back.mode_switches[0].to == "manual" and back.mode_switches[0].sha == "abc"


# ---- the switch endpoint ---------------------------------------------------------------


def test_same_mode_is_a_noop(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    (repo / "f.txt").write_text("dirty\n")
    before = _git(repo, "rev-parse", "HEAD")
    out = _run(main.set_workspace_mode(ws.id, SetModeRequest(mode="agent")))
    assert out.mode == "agent" and out.mode_switches == []
    assert _git(repo, "rev-parse", "HEAD") == before
    assert hub.history(ws.id) == []


def test_switch_409_while_an_agent_is_running(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)

    async def go():
        t = asyncio.create_task(asyncio.sleep(30))
        store.set_active_task(ws.id, DEFAULT_SESSION, t)
        try:
            await main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        finally:
            t.cancel()

    _conflict(go(), "stop the agent first")
    assert ws.mode == "agent" and ws.mode_switches == []


def test_switch_409_while_the_gate_runs(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)

    async def go():
        t = asyncio.create_task(asyncio.sleep(30))
        store.gate_tasks[ws.id] = t
        try:
            await main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        finally:
            t.cancel()

    _conflict(go(), "gate run is in progress")
    assert ws.mode == "agent"


def test_switch_checkpoints_a_dirty_tree_and_records_the_sha(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    (repo / "f.txt").write_text("agent work\n")
    out = _run(main.set_workspace_mode(ws.id, SetModeRequest(mode="manual")))
    assert out.mode == "manual"
    assert _git(repo, "log", "-1", "--format=%s") == "checkpoint: switch to manual mode"
    assert _git(repo, "status", "--porcelain") == ""
    assert len(out.mode_switches) == 1
    sw = out.mode_switches[0]
    assert sw.to == "manual" and sw.sha == _git(repo, "rev-parse", "HEAD")


def test_switch_on_a_clean_tree_adds_no_commit(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    before = _git(repo, "rev-parse", "HEAD")
    out = _run(main.set_workspace_mode(ws.id, SetModeRequest(mode="agent")))
    assert out.mode == "agent"
    assert _git(repo, "rev-parse", "HEAD") == before
    assert out.mode_switches[0].sha == before


def test_switch_publishes_a_status_event_carrying_the_mode(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    _run(main.set_workspace_mode(ws.id, SetModeRequest(mode="manual")))
    events = [e for e in hub.history(ws.id) if e.get("channel") == "status"]
    assert events and events[-1]["mode"] == "manual"
    assert events[-1]["status"] == ws.status.value


def test_every_status_payload_carries_the_mode():
    ws = Workspace(
        project_id="p", name="w", branch="b", worktree_path="/tmp/w", base_ref="main", mode="manual"
    )
    assert status_payload(ws)["mode"] == "manual"


# ---- manual refuses every agent path ---------------------------------------------------


def _no_agent(monkeypatch):
    seen: list[dict] = []

    async def fake_run_agent(**kw):
        seen.append(kw)

    monkeypatch.setattr(main, "run_agent", fake_run_agent)
    return seen


@pytest.mark.parametrize(
    "req",
    [
        StartAgentRequest(task="do it"),
        StartAgentRequest(task="plan it", plan=True),
        StartAgentRequest(task="build the plan", role="build"),
        StartAgentRequest(task="a follow-up answer", session_id="side"),
        StartAgentRequest(task="draft", test_first=True),
    ],
)
def test_manual_refuses_start_agent(monkeypatch, tmp_path, req):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    seen = _no_agent(monkeypatch)
    _conflict(main.start_agent(ws.id, req), "manual mode")
    assert seen == [] and store.runs == {}


def test_manual_refuses_test_first_approve(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    ws.test_first = FirstState(phase="review", task="t")
    seen = _no_agent(monkeypatch)
    _conflict(main.approve_test_first(ws.id), "manual mode")
    assert seen == [] and ws.test_first.phase == "review"


def test_agent_mode_still_starts_an_agent(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    seen = _no_agent(monkeypatch)

    async def go():
        run = await main.start_agent(ws.id, StartAgentRequest(task="do it"))
        await asyncio.sleep(0)
        return run

    assert isinstance(_run(go()), AgentRun)
    assert len(seen) == 1


def test_review_with_ai_stays_allowed_in_manual(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    out = _run(main.run_review_endpoint(ws.id, ReviewRequest()))
    assert isinstance(out, ReviewResult)
    assert out.nothing_to_review is True and out.error is None


# ---- receipt: written by ---------------------------------------------------------------


def _receipt(monkeypatch, tmp_path, ws_kw, model=None, origin=None):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, **ws_kw)
    if origin:
        subprocess.run(["git", "remote", "add", "origin", origin], cwd=repo, check=True)
    if model:
        store.add_run(AgentRun(workspace_id=ws.id, adapter="claude-code", model=model))
    settings = load_project_settings(str(repo))
    rcpt = _run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))
    return rcpt, receipt_svc.render_markdown(rcpt)


def test_written_by_manual_never_switched(monkeypatch, tmp_path):
    rcpt, md = _receipt(monkeypatch, tmp_path, {"mode": "manual"})
    assert rcpt.written_by == "you"
    assert "- Written by: you" in md


GH = "https://github.com/HaziqLucii/shelf-demo.git"


def _resolves(monkeypatch, login, source):
    async def fake(slug, override=None):
        return github_accounts.Resolution(login, source)

    monkeypatch.setattr(github_accounts, "resolve", fake)


def test_written_by_manual_names_the_linked_github_account(monkeypatch, tmp_path):
    _resolves(monkeypatch, "HaziqLucii", "auto")
    rcpt, md = _receipt(monkeypatch, tmp_path, {"mode": "manual"}, origin=GH)
    assert rcpt.written_by == "HaziqLucii"
    assert "- Written by: HaziqLucii" in md


def test_written_by_does_not_name_a_bare_terminal_account(monkeypatch, tmp_path):
    _resolves(monkeypatch, "someone-else", "terminal")
    rcpt, _ = _receipt(monkeypatch, tmp_path, {"mode": "manual"}, origin=GH)
    assert rcpt.written_by == "you"


def test_written_by_survives_a_resolver_that_raises(monkeypatch, tmp_path):
    async def boom(slug, override=None):
        raise RuntimeError("gh is down")

    monkeypatch.setattr(github_accounts, "resolve", boom)
    rcpt, _ = _receipt(monkeypatch, tmp_path, {"mode": "manual"}, origin=GH)
    assert rcpt.written_by == "you"


def test_written_by_agent_never_switched_names_the_last_model(monkeypatch, tmp_path):
    rcpt, md = _receipt(monkeypatch, tmp_path, {}, model="sonnet")
    assert rcpt.written_by == "agent · sonnet"
    assert "- Written by: agent · sonnet" in md


def test_written_by_agent_without_a_run_is_just_agent(monkeypatch, tmp_path):
    rcpt, _md = _receipt(monkeypatch, tmp_path, {})
    assert rcpt.written_by == "agent"


def test_written_by_switched_lists_the_switches_in_order(monkeypatch, tmp_path):
    at = datetime(2026, 9, 29, 10, 32, tzinfo=timezone.utc)
    at2 = datetime(2026, 9, 29, 11, 5, tzinfo=timezone.utc)
    rcpt, md = _receipt(
        monkeypatch, tmp_path,
        {"mode": "agent", "mode_switches": [
            ModeSwitch(to="manual", at=at, sha="a"), ModeSwitch(to="agent", at=at2, sha="b"),
        ]},
    )
    hh = at.astimezone().strftime("%H:%M")
    hh2 = at2.astimezone().strftime("%H:%M")
    assert rcpt.written_by == (
        f"you and the agent (agent -> manual at {hh}, manual -> agent at {hh2})"
    )
    assert "—" not in md


def test_written_by_switched_names_the_account_too(monkeypatch, tmp_path):
    _resolves(monkeypatch, "HaziqLucii", "default")
    at = datetime(2026, 9, 29, 10, 32, tzinfo=timezone.utc)
    rcpt, _ = _receipt(
        monkeypatch, tmp_path,
        {"mode": "manual", "mode_switches": [ModeSwitch(to="manual", at=at, sha="a")]},
        origin=GH,
    )
    hh = at.astimezone().strftime("%H:%M")
    assert rcpt.written_by == f"HaziqLucii and the agent (agent -> manual at {hh})"


# ---- races between a mode switch and an agent start -------------------------------------


def test_start_agent_is_refused_while_a_switch_is_checkpointing(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    seen = _no_agent(monkeypatch)
    real_commit = main.git_panel.commit

    async def go():
        entered, release = asyncio.Event(), asyncio.Event()

        async def slow(*a, **k):
            entered.set()
            await release.wait()
            return await real_commit(*a, **k)

        monkeypatch.setattr(main.git_panel, "commit", slow)
        switch = asyncio.create_task(
            main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        )
        await entered.wait()
        assert ws.id in store.mode_switching
        with pytest.raises(HTTPException) as e:
            await main.start_agent(ws.id, StartAgentRequest(task="x"))
        assert e.value.status_code == 409 and "switching mode" in e.value.detail
        release.set()
        await switch

    _run(go())
    assert seen == [] and store.runs == {}
    assert ws.mode == "manual" and store.mode_switching == set()


def test_a_switch_is_refused_while_an_agent_start_is_in_flight(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    seen = _no_agent(monkeypatch)

    async def go():
        entered, release = asyncio.Event(), asyncio.Event()

        async def slow(*a, **k):
            entered.set()
            await release.wait()
            return []

        monkeypatch.setattr(main.git_ops, "changed_files", slow)
        start = asyncio.create_task(
            main.start_agent(ws.id, StartAgentRequest(task="x", test_first=True))
        )
        await entered.wait()
        assert store.agent_starting == {ws.id: 1}
        with pytest.raises(HTTPException) as e:
            await main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        assert e.value.status_code == 409 and "stop the agent first" in e.value.detail
        assert ws.mode == "agent" and store.mode_switching == set()
        release.set()
        await start
        await asyncio.sleep(0)

    _run(go())
    assert len(seen) == 1 and ws.mode == "agent"
    assert store.agent_starting == {}


def test_the_starting_mark_is_cleared_when_start_agent_raises(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    _no_agent(monkeypatch)

    async def go():
        t = asyncio.create_task(asyncio.sleep(30))
        store.set_active_task(ws.id, DEFAULT_SESSION, t)
        try:
            with pytest.raises(HTTPException):
                await main.start_agent(ws.id, StartAgentRequest(task="x"))
        finally:
            t.cancel()

    _run(go())
    assert store.agent_starting == {}


def test_start_agent_looks_again_right_before_spawning(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    seen = _no_agent(monkeypatch)

    async def flips_mode(*a, **k):
        ws.mode = "manual"
        return []

    monkeypatch.setattr(main.git_ops, "changed_files", flips_mode)
    _conflict(
        main.start_agent(ws.id, StartAgentRequest(task="x", test_first=True)),
        "manual mode",
    )
    assert seen == [] and store.agent_starting == {}
    assert store.runs == {}


def test_a_switch_refuses_if_an_agent_appears_during_the_checkpoint(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    tasks = []

    async def go():
        async def commit_and_start_agent(*a, **k):
            t = asyncio.create_task(asyncio.sleep(30))
            tasks.append(t)
            store.set_active_task(ws.id, DEFAULT_SESSION, t)
            return {}

        monkeypatch.setattr(main.git_panel, "commit", commit_and_start_agent)
        try:
            await main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        finally:
            for t in tasks:
                t.cancel()

    _conflict(go(), "stop the agent first")
    assert ws.mode == "agent" and ws.mode_switches == []
    assert store.mode_switching == set()


def test_switch_409_while_setup_runs(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)

    async def go():
        t = asyncio.create_task(asyncio.sleep(30))
        store.set_active_task(ws.id, SETUP_SESSION, t)
        try:
            await main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        finally:
            t.cancel()

    _conflict(go(), "setup is still running")
    assert ws.mode == "agent"


@pytest.mark.parametrize("status", ["archived", "merged"])
def test_switch_409_for_archived_and_merged_workspaces(monkeypatch, tmp_path, status):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, status=status)
    _conflict(main.set_workspace_mode(ws.id, SetModeRequest(mode="manual")), status)
    assert ws.mode == "agent" and ws.mode_switches == []


def test_written_by_asks_nothing_when_there_is_no_github_origin(monkeypatch, tmp_path):
    async def must_not_run(slug, override=None):
        raise AssertionError("resolve must not be called without a github.com origin")

    monkeypatch.setattr(github_accounts, "resolve", must_not_run)
    rcpt, _ = _receipt(monkeypatch, tmp_path, {"mode": "manual"})
    assert rcpt.written_by == "you"
