"""Warm deps: the shared package-manager cache/store wired into script_env, so a
fresh worktree's setup install reuses prior downloads instead of a cold fetch."""

from haro.lifecycle import deps_cache_env, script_env
from haro.models import Project, Workspace


def _ws_proj():
    project = Project(id="p", name="proj", path="/tmp/proj", default_branch="main")
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path="/tmp/wt", base_ref="main", port=5200,
    )
    return ws, project


def test_deps_cache_env_roots_each_manager_under_the_cache_dir():
    env = deps_cache_env("/cache")
    assert env["npm_config_cache"] == "/cache/npm"
    assert env["npm_config_store_dir"] == "/cache/pnpm-store"  # pnpm's hardlink store
    assert env["YARN_CACHE_FOLDER"] == "/cache/yarn"
    assert env["BUN_INSTALL_CACHE_DIR"] == "/cache/bun"


def test_deps_cache_env_disabled_when_root_empty():
    assert deps_cache_env("") == {}


def test_script_env_injects_cache_and_haro_vars(monkeypatch):
    monkeypatch.setattr("haro.lifecycle.settings.deps_cache_root", "/cache")
    monkeypatch.delenv("npm_config_cache", raising=False)
    ws, project = _ws_proj()
    env = script_env(ws, project)
    assert env["npm_config_cache"] == "/cache/npm"
    assert env["HARO_WORKSPACE_PATH"] == "/tmp/wt"
    assert env["HARO_ROOT_PATH"] == "/tmp/proj"
    assert env["HARO_PORT"] == "5200"


def test_user_cache_env_wins_over_the_shared_default(monkeypatch):
    monkeypatch.setattr("haro.lifecycle.settings.deps_cache_root", "/cache")
    monkeypatch.setenv("npm_config_cache", "/my/own/cache")
    ws, project = _ws_proj()
    env = script_env(ws, project)
    assert env["npm_config_cache"] == "/my/own/cache"  # setdefault must not clobber it


def test_no_cache_vars_when_sharing_disabled(monkeypatch):
    monkeypatch.setattr("haro.lifecycle.settings.deps_cache_root", "")
    monkeypatch.delenv("npm_config_cache", raising=False)
    ws, project = _ws_proj()
    env = script_env(ws, project)
    assert "npm_config_cache" not in env
