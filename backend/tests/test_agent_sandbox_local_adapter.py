"""`[agent] sandbox = true` must refuse a run on the local-model adapter
rather than execute it unconfined (Move D step 2, usp-critique-round3.md):
`sandbox.wrap_agent_command`/bwrap only wraps `ClaudeCodeAdapter`'s `claude`
subprocess — LocalModelAdapter has no sandbox support at all, so silently
proceeding would be exactly the "ran unsandboxed under the flag meant to
prevent that" failure this feature otherwise refuses. Same pattern as
test_agent_session_lifecycle.py: drive the handler directly with asyncio.run,
no TestClient, no pytest-asyncio."""

from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import main
from haro.hub import Hub
from haro.models import Project, StartAgentRequest, Workspace
from haro.store import Store


def _fixture_with_settings(toml: str):
    store, hub = Store(), Hub()
    proj_path = tempfile.mkdtemp(prefix="haro-proj-")
    (Path(proj_path) / ".haro").mkdir()
    (Path(proj_path) / ".haro" / "settings.toml").write_text(toml)
    project = Project(name="p", path=proj_path, default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="haro/w",
        worktree_path=tempfile.mkdtemp(prefix="haro-wt-"), base_ref="main",
    )
    store.add_workspace(ws)
    return store, hub, ws


def test_local_adapter_refuses_to_run_when_sandbox_is_on():
    async def go():
        store, hub, ws = _fixture_with_settings(
            '[agent]\nadapter = "local"\nsandbox = true\n'
        )
        main.store = store
        with pytest.raises(HTTPException) as exc_info:
            await main.start_agent(ws.id, StartAgentRequest(task="do it"))
        assert exc_info.value.status_code == 400
        assert "sandbox" in exc_info.value.detail
        assert "local" in exc_info.value.detail

    asyncio.run(go())


def test_local_adapter_runs_fine_when_sandbox_is_off():
    async def go():
        store, hub, ws = _fixture_with_settings('[agent]\nadapter = "local"\n')
        main.store = store
        # Should not raise for the sandbox reason (it may fail later trying to
        # actually reach a local model server, which is not what's under test —
        # only that it gets PAST the sandbox refusal).
        try:
            await main.start_agent(ws.id, StartAgentRequest(task="do it"))
        except HTTPException as exc:
            assert "sandbox" not in (exc.detail or "")
        for task in store.workspace_tasks(ws.id):
            task.cancel()
        await asyncio.gather(*store.workspace_tasks(ws.id), return_exceptions=True)

    asyncio.run(go())
