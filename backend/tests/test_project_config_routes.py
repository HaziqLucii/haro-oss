"""Route-level tests for the project settings hub (backlog/project-config.md §3).

The config-layer writers are unit-tested in ``test_config.py``; this file covers
the HTTP seam on top of them: that the project-scoped scripts route round-trips,
that each settings tab (Git / Setup / Gate / Agent / Instructions) reads back what
it wrote through its endpoint, and — the retirement that made these the single
source of truth — that the workspace ``/scripts`` route is read-only (no PUT), so
scripts can only be edited project-level and never drift per-workspace.

No httpx/pytest-asyncio in the gate env, so we drive the async route handlers
directly with ``asyncio.run`` (the same pattern the adapter tests use) against the
module-level ``store`` singleton, rather than an in-process HTTP client.
"""

import asyncio
import subprocess

import pytest
from fastapi import HTTPException

from haro import main
from haro.models import (
    AgentUpdateRequest,
    DefaultBranchRequest,
    EnvUpdateRequest,
    GateUpdateRequest,
    InstructionsUpdateRequest,
    Project,
    RemoteUpdateRequest,
    ScriptsUpdateRequest,
    Workspace,
    WorkflowUpdateRequest,
)


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def project(tmp_path):
    """A registered project whose path is a real (empty) git repo — added to the
    store for the request's lifetime, then removed so tests don't bleed state."""
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    main.store.add_project(proj)
    yield proj
    main.store.remove_project(proj.id)


@pytest.fixture
def workspace(project):
    """A workspace under the fixture project — its worktree path is the project
    path (fine: the scripts route only reads the *project's* inherited config)."""
    ws = Workspace(
        project_id=project.id,
        name="ws",
        branch="ws/demo",
        worktree_path=project.path,
        base_ref="main",
    )
    main.store.add_workspace(ws)
    return ws


# ── Setup tab: project-scoped scripts route round-trips ──────────────────────


def test_project_scripts_route_roundtrips(project):
    saved = run(
        main.put_project_scripts(
            project.id,
            ScriptsUpdateRequest(
                setup="npm ci",
                run="npm run dev",
                archive="rm -rf tmp",
                run_mode="concurrent",
                login_shell=True,
                target="shared",
            ),
        )
    )
    # the PUT echoes the effective config back...
    assert saved.setup == "npm ci"
    assert saved.run == "npm run dev"
    assert saved.archive == "rm -rf tmp"
    assert saved.login_shell is True
    # ...and a fresh GET reads the same thing off disk.
    got = run(main.get_project_scripts(project.id))
    assert got == saved


def test_project_scripts_get_defaults_when_unset(project):
    got = run(main.get_project_scripts(project.id))
    assert got.setup is None and got.run is None and got.archive is None
    assert got.run_mode == "concurrent"
    assert got.login_shell is False


def test_project_scripts_unknown_project_404(project):
    with pytest.raises(HTTPException) as exc:
        run(main.get_project_scripts("proj_missing"))
    assert exc.value.status_code == 404


# ── Gate tab reads/writes ────────────────────────────────────────────────────


def test_gate_tab_roundtrips(project):
    saved = run(
        main.set_project_gate(
            project.id,
            GateUpdateRequest(
                runner="command",
                command="shopify theme check",
                gate_dir="theme",
                default_scope="impacted",
                merge_result=True,
                flaky_rerun=True,
                coverage_guard="block",
                coverage_tolerance=1.5,
                target="shared",
            ),
        )
    )
    assert saved.runner == "command"
    assert saved.command == "shopify theme check"
    got = run(main.get_project_gate(project.id))
    assert got == saved
    assert got.gate_dir == "theme"
    assert got.default_scope == "impacted"
    assert got.merge_result is True
    assert got.flaky_rerun is True
    assert got.coverage_guard == "block"
    assert got.coverage_tolerance == 1.5


def test_gate_tab_default_runner_is_vitest(project):
    # An unconfigured [gate] surfaces as the explicit "vitest" the UI shows, not the
    # internal empty-string default (which dispatch treats as vitest).
    got = run(main.get_project_gate(project.id))
    assert got.runner == "vitest"
    assert got.command == ""


# ── Agent tab reads/writes ───────────────────────────────────────────────────


def test_agent_tab_roundtrips(project):
    saved = run(
        main.set_project_agent(
            project.id,
            AgentUpdateRequest(
                default_model="opus",
                default_effort="high",
                max_budget_usd=12.0,
                cost_warn_usd=40.0,
                target="shared",
            ),
        )
    )
    assert saved.default_model == "opus"
    got = run(main.get_project_agent(project.id))
    assert got == saved
    assert got.default_effort == "high"
    assert got.max_budget_usd == 12.0
    assert got.cost_warn_usd == 40.0


def test_agent_tab_defaults_are_cost_conscious(project):
    got = run(main.get_project_agent(project.id))
    assert got.default_model == "sonnet"
    assert got.default_effort == ""
    assert got.max_budget_usd == 5.0
    assert got.cost_warn_usd == 20.0


# ── Environment tab reads/writes ─────────────────────────────────────────────


def test_env_tab_roundtrips(project):
    saved = run(main.set_project_env(project.id, EnvUpdateRequest(content="API_KEY=abc")))
    assert saved.content == "API_KEY=abc\n"
    assert run(main.get_project_env(project.id)).content == "API_KEY=abc\n"


def test_env_tab_defaults_empty(project):
    assert run(main.get_project_env(project.id)).content == ""


def test_env_tab_clearing_removes_seed(project):
    run(main.set_project_env(project.id, EnvUpdateRequest(content="A=1")))
    run(main.set_project_env(project.id, EnvUpdateRequest(content="")))
    assert run(main.get_project_env(project.id)).content == ""


# ── Git tab reads/writes (workflow merge-mode · base branch · remote) ─────────


def test_workflow_tab_roundtrips(project):
    saved = run(
        main.set_project_workflow(
            project.id, WorkflowUpdateRequest(merge_mode="pr", target="shared")
        )
    )
    assert saved.merge_mode == "pr"
    assert run(main.get_project_workflow(project.id)).merge_mode == "pr"


def test_default_branch_strips_origin_prefix(project):
    updated = run(
        main.set_default_branch(project.id, DefaultBranchRequest(branch="origin/develop"))
    )
    assert updated.default_branch == "develop"
    assert main.store.get_project(project.id).default_branch == "develop"


def test_default_branch_rejects_blank(project):
    with pytest.raises(HTTPException) as exc:
        run(main.set_default_branch(project.id, DefaultBranchRequest(branch="   ")))
    assert exc.value.status_code == 400


def test_remote_tab_roundtrips(project):
    saved = run(
        main.set_project_remote(
            project.id, RemoteUpdateRequest(url="https://github.com/acme/demo.git")
        )
    )
    assert saved.url == "https://github.com/acme/demo.git"
    got = run(main.get_project_remote(project.id))
    assert got.url == "https://github.com/acme/demo.git"
    # the cached badge field is kept in sync for the sidebar
    assert main.store.get_project(project.id).remote_url == "https://github.com/acme/demo.git"
    # unlinking clears it
    run(main.set_project_remote(project.id, RemoteUpdateRequest(url="")))
    assert run(main.get_project_remote(project.id)).url is None


# ── Instructions tab reads/writes ────────────────────────────────────────────


def test_instructions_tab_roundtrips(project):
    saved = run(
        main.put_project_instructions(
            project.id, InstructionsUpdateRequest(text="always add tests", target="shared")
        )
    )
    assert saved.shared == "always add tests"
    run(
        main.put_project_instructions(
            project.id, InstructionsUpdateRequest(text="my notes", target="local")
        )
    )
    got = run(main.get_project_instructions(project.id))
    assert got.shared == "always add tests"
    assert got.local == "my notes"


# ── Tabs write independently — no tab clobbers another ───────────────────────


def test_tabs_write_independently(project):
    run(main.put_project_scripts(project.id, ScriptsUpdateRequest(setup="npm ci", target="shared")))
    run(main.set_project_workflow(project.id, WorkflowUpdateRequest(merge_mode="merge", target="shared")))
    run(main.set_project_gate(project.id, GateUpdateRequest(runner="pytest", flaky_rerun=True, target="shared")))
    run(main.set_project_agent(project.id, AgentUpdateRequest(default_model="opus", target="shared")))

    assert run(main.get_project_scripts(project.id)).setup == "npm ci"
    assert run(main.get_project_workflow(project.id)).merge_mode == "merge"
    gate = run(main.get_project_gate(project.id))
    assert gate.runner == "pytest" and gate.flaky_rerun is True
    assert run(main.get_project_agent(project.id)).default_model == "opus"


# ── The retirement: workspace scripts are read-only (single source of truth) ──


def test_workspace_scripts_are_read_only_no_put_route():
    # The per-workspace scripts *write* was retired so project config can't drift
    # per-workspace: GET survives (shows inherited config), PUT must not exist.
    methods = {}
    for r in main.app.routes:
        if getattr(r, "path", "") == "/workspaces/{ws_id}/scripts":
            methods = {m for m in r.methods if m in {"GET", "PUT", "POST", "DELETE"}}
    assert methods == {"GET"}
    assert not hasattr(main, "put_scripts")
    assert not hasattr(main, "set_scripts")


def test_workspace_scripts_get_returns_inherited_project_config(project, workspace):
    # The workspace GET reads the *project's* effective config — edit it project-level,
    # the workspace sees it (inheritance, not a separate per-workspace store).
    run(main.put_project_scripts(project.id, ScriptsUpdateRequest(setup="npm ci", run="npm run dev", target="shared")))
    got = run(main.get_scripts(workspace.id))
    assert got.setup == "npm ci"
    assert got.run == "npm run dev"


def test_workspace_scripts_get_unknown_workspace_404():
    with pytest.raises(HTTPException) as exc:
        run(main.get_scripts("ws_missing"))
    assert exc.value.status_code == 404
