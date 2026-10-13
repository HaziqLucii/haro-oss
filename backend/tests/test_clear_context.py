"""Clearing a session's context drops its Claude resume id, keeps the transcript and leaves a
``context_cleared`` marker so the client stops counting the old window."""

import asyncio

import pytest
from fastapi import HTTPException

from haro import main
from haro.models import Workspace
from haro.store import DEFAULT_SESSION


def _ws() -> Workspace:
    ws = Workspace(id="ws_clr", project_id="p", name="n", branch="b", base_ref="main", worktree_path="/tmp/x")
    main.store.workspaces[ws.id] = ws
    return ws


def test_clear_context_drops_resume_ids_and_marks_the_transcript():
    ws = _ws()
    ws.last_session_id = "claude-1"
    ws.session_resume = {DEFAULT_SESSION: "claude-1", "review": "claude-2"}
    main.store.append_event(ws.id, {"run_id": "r", "workspace_id": ws.id, "ts": 1.0, "type": "done", "payload": {}})
    try:
        assert main.store.clear_context(ws.id) is True
        assert ws.last_session_id is None
        assert DEFAULT_SESSION not in ws.session_resume
        assert ws.session_resume["review"] == "claude-2"
        types = [e["type"] for e in main.store.events_for(ws.id)]
        assert types == ["done", "context_cleared"]
        assert main.store.clear_context(ws.id) is False
        assert [e["type"] for e in main.store.events_for(ws.id)] == types
    finally:
        main.store.workspaces.pop(ws.id, None)
        main.store.events.pop((ws.id, DEFAULT_SESSION), None)


def test_route_clears_and_404s_for_a_missing_workspace():
    ws = _ws()
    ws.last_session_id = "claude-1"
    try:
        with pytest.raises(HTTPException) as e:
            asyncio.run(main.clear_session_context("nope"))
        assert e.value.status_code == 404
        assert asyncio.run(main.clear_session_context(ws.id)) == {"cleared": True}
        assert ws.last_session_id is None
    finally:
        main.store.workspaces.pop(ws.id, None)
        main.store.events.pop((ws.id, DEFAULT_SESSION), None)
