"""Static run-script check: a run command that names a package.json script that is not
there is flagged; everything else (found, not a plain package-manager run, unreadable)
stays unjudged. Route-level: the check surfaces on ``RunScriptInfo.problem`` for both the
project and the workspace scripts endpoints, and ``BaselineState.head_sha`` for First run.

Async route handlers are driven directly with ``asyncio.run`` against the module-level
``store``, like ``test_project_config_routes.py`` (no in-process HTTP client in the gate
env).
"""

import asyncio
import json
import subprocess

import pytest

from haro import main
from haro.models import Project, ScriptsUpdateRequest, Workspace
from haro.run_check import missing_script


def _pkg(root, scripts=None, sub=None):
    d = root / sub if sub else root
    d.mkdir(parents=True, exist_ok=True)
    body = {"name": "x"}
    if scripts is not None:
        body["scripts"] = scripts
    (d / "package.json").write_text(json.dumps(body))


def test_defined_script_is_not_flagged(tmp_path):
    _pkg(tmp_path, {"dev": "vite"})
    assert missing_script("npm run dev", tmp_path) is None
    assert missing_script("pnpm run dev", tmp_path) is None
    assert missing_script("yarn run dev", tmp_path) is None
    assert missing_script("npm run-script dev", tmp_path) is None


def test_missing_script_names_it(tmp_path):
    _pkg(tmp_path, {"build": "tsc"})
    assert missing_script("npm run dev", tmp_path) == "no `dev` script in package.json"
    assert missing_script("pnpm run dev", tmp_path) == "no `dev` script in package.json"
    assert missing_script("yarn run dev", tmp_path) == "no `dev` script in package.json"


def test_trailing_args_are_ignored(tmp_path):
    _pkg(tmp_path, {"dev": "vite"})
    cmd = "npm run dev -- --port $HARO_PORT --host 0.0.0.0"
    assert missing_script(cmd, tmp_path) is None
    _pkg(tmp_path, {})
    assert missing_script(cmd, tmp_path) == "no `dev` script in package.json"


def test_package_without_scripts_key_is_missing(tmp_path):
    _pkg(tmp_path, None)
    assert missing_script("npm run dev", tmp_path) == "no `dev` script in package.json"


def test_npm_start(tmp_path):
    _pkg(tmp_path, {"dev": "vite"})
    assert missing_script("npm start", tmp_path) == "no `start` script in package.json"
    _pkg(tmp_path, {"start": "node ."})
    assert missing_script("npm start", tmp_path) is None
    assert missing_script("pnpm start", tmp_path) is None


def test_npm_start_falls_back_to_server_js(tmp_path):
    _pkg(tmp_path, {})
    (tmp_path / "server.js").write_text("")
    assert missing_script("npm start", tmp_path) is None
    assert missing_script("pnpm start", tmp_path) == "no `start` script in package.json"


def test_prefix_reads_the_named_folder(tmp_path):
    _pkg(tmp_path, {}, sub=None)
    _pkg(tmp_path, {"dev": "vite"}, sub="frontend")
    assert missing_script("npm --prefix frontend run dev", tmp_path) is None
    assert missing_script("npm --prefix=frontend run dev", tmp_path) is None
    assert missing_script("pnpm -C frontend run dev", tmp_path) is None
    assert (
        missing_script("npm --prefix frontend run nope", tmp_path)
        == "no `nope` script in frontend/package.json"
    )


def test_no_package_json(tmp_path):
    assert (
        missing_script("npm run dev", tmp_path)
        == "no package.json to run `dev` from"
    )


@pytest.mark.parametrize(
    "command",
    [
        "",
        "   ",
        "make dev",
        "PORT=3000 npm run dev",
        "npm run build && npm run dev",
        "cd web; npm run dev",
        "npm run dev | tee log",
        "npm run --workspace web dev",
        "pnpm -r run dev",
        "pnpm --filter web run dev",
        "npm run dev --if-present",
        "npm install",
        "npm run",
        "yarn dev",
        "npx vite",
        "npm run serve --workspace=pkgs/web",
        "npm run serve -w pkgs/web",
        "npm run serve --prefix pkgs/web",
        "npm run serve --workspaces",
        "npm run serve -ws",
        "npm start --workspace=web",
        'npm run "$SCRIPT"',
        "npm run dev:$HARO_PORT",
        "npm run 'a b'",
    ],
)
def test_anything_else_is_left_unjudged(tmp_path, command):
    _pkg(tmp_path, {})
    assert missing_script(command, tmp_path) is None


def test_yarn_run_is_unjudged_when_a_binary_of_that_name_exists(tmp_path):
    _pkg(tmp_path, {})
    (tmp_path / "node_modules" / ".bin").mkdir(parents=True)
    (tmp_path / "node_modules" / ".bin" / "vite").write_text("")
    assert missing_script("yarn run vite", tmp_path) is None
    assert missing_script("yarn run nope", tmp_path) == "no `nope` script in package.json"
    assert missing_script("npm run vite", tmp_path) == "no `vite` script in package.json"


def test_args_after_the_double_dash_are_not_options_to_the_manager(tmp_path):
    _pkg(tmp_path, {})
    assert (
        missing_script("npm run dev -- --workspace x", tmp_path)
        == "no `dev` script in package.json"
    )


def test_none_command_and_unreadable_json(tmp_path):
    assert missing_script(None, tmp_path) is None
    (tmp_path / "package.json").write_text("{not json")
    assert missing_script("npm run dev", tmp_path) is None
    (tmp_path / "package.json").write_text("[]")
    assert missing_script("npm run dev", tmp_path) is None


def test_unbalanced_quote_is_unjudged(tmp_path):
    _pkg(tmp_path, {})
    assert missing_script("npm run 'dev", tmp_path) is None


# ── routes ───────────────────────────────────────────────────────────────────


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def project(tmp_path):
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    proj = Project(name="demo", path=str(tmp_path), default_branch="main")
    main.store.add_project(proj)
    yield proj
    main.store.remove_project(proj.id)


def _save_run(project, command):
    run(
        main.put_project_scripts(
            project.id, ScriptsUpdateRequest(run=command, target="shared")
        )
    )


def test_project_scripts_route_reports_the_problem(project, tmp_path):
    _pkg(tmp_path, {"build": "tsc"})
    _save_run(project, "npm run dev")
    cfg = run(main.get_project_scripts(project.id))
    assert [r.problem for r in cfg.runs] == ["no `dev` script in package.json"]

    _pkg(tmp_path, {"dev": "vite"})
    cfg = run(main.get_project_scripts(project.id))
    assert [r.problem for r in cfg.runs] == [None]


def test_saving_scripts_returns_the_problem_too(project, tmp_path):
    _pkg(tmp_path, {})
    saved = run(
        main.put_project_scripts(
            project.id, ScriptsUpdateRequest(run="npm run dev", target="shared")
        )
    )
    assert saved.runs[0].problem == "no `dev` script in package.json"


def test_workspace_scripts_route_checks_the_worktree(project, tmp_path):
    wt = tmp_path / "wt"
    _pkg(tmp_path, {"dev": "vite"})
    _pkg(wt, {})
    ws = Workspace(
        project_id=project.id,
        name="ws",
        branch="ws/demo",
        worktree_path=str(wt),
        base_ref="main",
    )
    main.store.add_workspace(ws)
    _save_run(project, "npm run dev")
    cfg = run(main.get_scripts(ws.id))
    assert cfg.runs[0].problem == "no `dev` script in package.json"


def test_no_run_script_no_problem(project):
    cfg = run(main.get_project_scripts(project.id))
    assert cfg.runs == []


# ── baseline head_sha ────────────────────────────────────────────────────────


def _repo_with_commit(path):
    def git(*args):
        subprocess.run(
            ["git", "-c", "user.email=a@b.c", "-c", "user.name=t", *args],
            cwd=path,
            check=True,
            capture_output=True,
        )

    git("init", "-q", "-b", "main")
    (path / "a.txt").write_text("a")
    git("add", ".")
    git("commit", "-q", "-m", "init")
    return subprocess.run(
        ["git", "rev-parse", "main"], cwd=path, check=True, capture_output=True, text=True
    ).stdout.strip()


def test_baseline_state_carries_the_default_branch_sha(tmp_path):
    sha = _repo_with_commit(tmp_path)
    proj = Project(name="b", path=str(tmp_path), default_branch="main")
    main.store.add_project(proj)
    try:
        state = run(main.get_baseline(proj.id))
        assert state.head_sha == sha
        assert state.result is None
    finally:
        main.store.remove_project(proj.id)


def test_baseline_state_head_sha_is_none_when_git_cannot_resolve(tmp_path):
    proj = Project(name="b", path=str(tmp_path), default_branch="main")
    main.store.add_project(proj)
    try:
        assert run(main.get_baseline(proj.id)).head_sha is None
    finally:
        main.store.remove_project(proj.id)


def test_verified_hunks_notes_carry_no_em_dash(project, tmp_path):
    ws = Workspace(
        project_id=project.id, name="ws", branch="ws/demo",
        worktree_path=str(tmp_path), base_ref="main",
    )
    main.store.add_workspace(ws)
    resp = run(main.get_verified_hunks(ws.id))
    assert resp.supported is False
    assert resp.note == "no green gate has measured this tree yet: run the full gate"
    assert "—" not in resp.note
