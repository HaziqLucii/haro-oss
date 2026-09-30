"""The no-setup-script provisioning path: symlink existing deps, or auto-install
them for a fresh JS project so the Vitest gate works out of the box.

Regression: opening a project that never had `npm install` (no node_modules to
symlink) used to leave the gate unable to find vitest while the deps chip still
read green. Now it installs, and reports honest ok/failed state.
"""

import asyncio
from pathlib import Path

from haro.hub import Hub
from haro.lifecycle import _provision_deps, detect_install_cmd
from haro.models import Project, Workspace
from haro.store import Store


def _ws_proj(tmp_path):
    proj_dir = tmp_path / "proj"
    wt_dir = tmp_path / "wt"
    proj_dir.mkdir()
    wt_dir.mkdir()
    project = Project(id="p", name="proj", path=str(proj_dir), default_branch="main")
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(wt_dir), base_ref="main", port=5200,
    )
    return ws, project, proj_dir, wt_dir


def _provision(ws, project):
    from haro.config import ProjectSettings
    return asyncio.run(
        _provision_deps(
            store=Store(), hub=Hub(), workspace=ws, project=project,
            psettings=ProjectSettings(),
        )
    )


# --- detect_install_cmd: lockfile → package manager ------------------------

def test_detect_none_without_package_json(tmp_path):
    assert detect_install_cmd(tmp_path) is None


def test_detect_defaults_to_npm(tmp_path):
    (tmp_path / "package.json").write_text("{}")
    assert detect_install_cmd(tmp_path) == "npm install"


def test_detect_picks_manager_from_lockfile(tmp_path):
    (tmp_path / "package.json").write_text("{}")
    (tmp_path / "pnpm-lock.yaml").write_text("")
    assert detect_install_cmd(tmp_path) == "pnpm install"
    (tmp_path / "pnpm-lock.yaml").unlink()
    (tmp_path / "yarn.lock").write_text("")
    assert detect_install_cmd(tmp_path) == "yarn install"
    (tmp_path / "yarn.lock").unlink()
    (tmp_path / "bun.lockb").write_text("")
    assert detect_install_cmd(tmp_path) == "bun install"


# --- _provision_deps -------------------------------------------------------

def test_existing_project_deps_are_symlinked(tmp_path):
    ws, project, proj_dir, wt_dir = _ws_proj(tmp_path)
    # An installed package, not just the directory: `ensure_deps` now reads a *package-less*
    # node_modules as a build cache rather than an install (backlog/gate.md), and a real
    # `npm install` never leaves the folder empty.
    (proj_dir / "node_modules" / "vitest").mkdir(parents=True)
    state = _provision(ws, project)
    assert state["status"] == "ok"
    assert (wt_dir / "node_modules").is_symlink()


def test_fresh_js_project_triggers_install_then_symlink(tmp_path, monkeypatch):
    ws, project, proj_dir, wt_dir = _ws_proj(tmp_path)
    (proj_dir / "package.json").write_text("{}")  # JS project, but no node_modules yet

    ran = {}

    async def fake_run_shell(cmd, *, cwd, env, on_line, login_shell=False):
        ran["cmd"] = cmd
        ran["cwd"] = cwd
        Path(cwd, "node_modules", "vitest").mkdir(parents=True)  # a real install lands packages
        return 0

    monkeypatch.setattr("haro.lifecycle._run_shell", fake_run_shell)
    state = _provision(ws, project)

    assert ran["cmd"] == "npm install"
    assert ran["cwd"] == str(proj_dir)
    assert state["status"] == "ok" and state["exit"] == 0
    assert (wt_dir / "node_modules").is_symlink()  # symlinked into the worktree for the gate


def test_failed_install_reports_failed_state(tmp_path, monkeypatch):
    ws, project, proj_dir, wt_dir = _ws_proj(tmp_path)
    (proj_dir / "package.json").write_text("{}")

    async def fake_run_shell(cmd, *, cwd, env, on_line, login_shell=False):
        return 1  # install failed; node_modules NOT created

    monkeypatch.setattr("haro.lifecycle._run_shell", fake_run_shell)
    state = _provision(ws, project)

    assert state["status"] == "failed" and state["exit"] == 1
    assert not (wt_dir / "node_modules").exists()


def test_non_js_project_without_deps_reports_failed_not_green(tmp_path):
    # No package.json and nothing to symlink: the deps chip must NOT read green.
    ws, project, proj_dir, wt_dir = _ws_proj(tmp_path)
    state = _provision(ws, project)
    assert state["status"] == "failed"
