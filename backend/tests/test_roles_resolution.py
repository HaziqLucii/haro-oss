"""`start_agent`'s model/effort/role resolution order (Phase 1 of
notes/workflow-roles-plan.md): explicit `req.model`/`req.effort` > this run's ROLE
(when `[roles] enabled`) > `[agent] default_model`/`default_effort` > "sonnet".

Same driving pattern as test_agent_session_lifecycle.py: call `main.start_agent`
directly and inspect the returned `AgentRun` before the (fire-and-forget) actual
agent subprocess ever gets a chance to run.
"""

from __future__ import annotations

import asyncio
import tempfile

from haro import main
from haro.config import write_project_agent, write_project_roles
from haro.hub import Hub
from haro.models import Project, StartAgentRequest, Workspace
from haro.store import Store


def _fixture(project_path: str):
    store, hub = Store(), Hub()
    proj = Project(name="p", path=project_path, default_branch="main")
    store.projects[proj.id] = proj
    ws = Workspace(project_id=proj.id, name="w", branch="haro/w",
                   worktree_path="/tmp/wt", base_ref="main")
    store.add_workspace(ws)
    main.store = store
    return store, hub, ws


def _configure_roles(project_path: str, **kwargs) -> None:
    defaults = dict(
        enabled=True, role_plan="fable:xhigh", role_build="sonnet:high",
        role_review="opus:high", role_scout="haiku",
    )
    defaults.update(kwargs)
    write_project_roles(project_path, **defaults)


def test_roles_off_leaves_todays_resolution_chain_untouched():
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    write_project_agent(
        project_path, default_model="opus", default_effort="high",
        max_budget_usd=5.0, cost_warn_usd=20.0,
    )
    _fixture(project_path)  # sets main.store

    async def go():
        return await main.start_agent(
            [w for w in main.store.workspaces.values()][0].id,
            StartAgentRequest(task="do it"),
        )

    run = asyncio.run(go())
    assert run.model == "opus"       # the project's [agent] default, roles never consulted
    assert run.effort == "high"
    assert run.role == ""            # roles off ⇒ no role stamped


def test_a_plan_submit_resolves_the_plan_role():
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)
    _fixture(project_path)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="plan it", plan=True))

    run = asyncio.run(go())
    assert run.role == "plan"
    assert run.model == "fable"
    assert run.effort == "xhigh"


def test_role_build_wins_even_when_plan_is_also_configured():
    """The approve-plan handoff sends `role="build"` explicitly — it must resolve to
    the BUILD role even though the just-finished plan turn ran under the plan role."""
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)
    _fixture(project_path)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(
            ws_id, StartAgentRequest(task="implement it now", role="build"),
        )

    run = asyncio.run(go())
    assert run.role == "build"
    assert run.model == "sonnet"
    assert run.effort == "high"


def test_an_ordinary_submit_with_no_plan_flag_resolves_build():
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)
    _fixture(project_path)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    run = asyncio.run(go())
    assert run.role == "build"
    assert run.model == "sonnet"
    assert run.effort == "high"


def test_an_explicit_per_run_model_wins_over_the_role():
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)
    _fixture(project_path)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(
            ws_id, StartAgentRequest(task="fix the bug", model="haiku", effort="low"),
        )

    run = asyncio.run(go())
    assert run.model == "haiku"
    assert run.effort == "low"
    assert run.role == "build"  # still stamped — the override is only for model/effort


def _capture_run_agent_kwargs(monkeypatch) -> dict:
    """Stub `main.run_agent` (bound via `from .runner import run_agent`) and return
    the dict its kwargs land in, so a test can inspect exactly what start_agent
    built for it — same technique test_agent_session_lifecycle.py already uses to
    drive `main.start_agent` without a real agent subprocess."""
    captured: dict = {}

    async def fake_run_agent(**kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(main, "run_agent", fake_run_agent)
    return captured


def test_scout_agents_payload_built_only_when_roles_and_scout_are_both_configured(monkeypatch):
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    asyncio.run(go())
    assert captured["agents"] is not None
    assert captured["agents"]["scout"]["model"] == "haiku"
    # The scout paragraph is appended, not silently dropped or replacing the project's own.
    assert "scout" in (captured["instructions"] or "").lower()


def test_no_agents_payload_when_scout_role_is_unconfigured(monkeypatch):
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path, role_scout="")
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    asyncio.run(go())
    assert captured["agents"] is None


def test_no_agents_payload_when_roles_are_off_even_with_a_scout_role_on_disk(monkeypatch):
    # A project that flips `[roles] enabled` off must not leak a leftover
    # `role_scout` into the request — same byte-identical-when-off contract as
    # model/effort resolution.
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path, enabled=False)
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    asyncio.run(go())
    assert captured["agents"] is None


def test_local_adapter_never_gets_an_agents_payload_or_scout_instructions(monkeypatch):
    # The local adapter's `run()` has no `agents` param — main.py must feature-detect
    # this the same way it does for `plan`/`fast`, never handing it a dict it can't
    # use, and must not advertise a sub-agent it has nothing to register.
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(
            ws_id, StartAgentRequest(task="fix the bug", adapter="local"),
        )

    asyncio.run(go())
    assert captured["agents"] is None
    assert "scout" not in (captured["instructions"] or "").lower()


def test_an_unconfigured_role_falls_back_to_the_agent_default():
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    write_project_agent(
        project_path, default_model="opus", default_effort="",
        max_budget_usd=5.0, cost_warn_usd=20.0,
    )
    # roles enabled, but no review role configured — review isn't used by start_agent
    # in Phase 1, but a role with no matching config (e.g. a typo) must still fall
    # back cleanly rather than erroring.
    _configure_roles(project_path, role_build="")
    _fixture(project_path)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    run = asyncio.run(go())
    assert run.role == "build"
    assert run.model == "opus"  # falls back to [agent] default_model, not "sonnet"


# --------------------------------------------------------------------------- #
# review_role / review_max_rounds construction (Phase 3 — notes/workflow-roles-plan.md).
# `review_enforce = "block"` was cut 2026-09-17 (an LLM verdict never blocks a merge
# on its own), so "warn" is now the only enforcement level — and, with it, the only
# signal that `review_role` — the runner's own gate for the review-fix loop — is
# truthy. An independent refuter pass asked specifically whether this construction
# (not just the runner-side gate) was pinned by a test.
# --------------------------------------------------------------------------- #
def test_review_role_is_armed_under_enforce_warn(monkeypatch):
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path, review_enforce="warn")
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    asyncio.run(go())
    assert captured["review_role"] is not None
    assert captured["review_role"].model == "opus"


def test_review_role_is_none_under_enforce_off_even_with_a_review_role_configured(monkeypatch):
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path)  # review_enforce defaults to "off"
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    asyncio.run(go())
    assert captured["review_role"] is None


def test_review_max_rounds_is_read_from_project_settings(monkeypatch):
    project_path = tempfile.mkdtemp(prefix="haro-proj-")
    _configure_roles(project_path, review_enforce="warn", review_max_rounds=5)
    _fixture(project_path)
    captured = _capture_run_agent_kwargs(monkeypatch)

    async def go():
        ws_id = [w for w in main.store.workspaces.values()][0].id
        return await main.start_agent(ws_id, StartAgentRequest(task="fix the bug"))

    asyncio.run(go())
    assert captured["review_max_rounds"] == 5
