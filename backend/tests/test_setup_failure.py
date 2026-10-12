"""A failed setup script says why (its last lines and exit code travel with `setup_state`),
and a re-run starts from a real node_modules, not a link into the project checkout."""

import asyncio

from haro.config import ProjectSettings
from haro.hub import Hub
from haro.lifecycle import run_setup
from haro.models import Project, Workspace
from haro.store import SETUP_SESSION, Store


def _rig(tmp_path):
    proj_dir = tmp_path / "proj"
    wt_dir = tmp_path / "wt"
    proj_dir.mkdir()
    wt_dir.mkdir()
    project = Project(id="p", name="proj", path=str(proj_dir), default_branch="main")
    ws = Workspace(
        project_id="p", name="w", branch="feat",
        worktree_path=str(wt_dir), base_ref="main", port=5200,
    )
    return ws, project, proj_dir, wt_dir


def _setup(ws, project, script, monkeypatch, calls=None):
    async def no_tree(_ws):
        return None

    monkeypatch.setattr("haro.lifecycle._record_setup_tree", no_tree)
    store = Store()
    asyncio.run(
        run_setup(
            store=store, hub=Hub(), workspace=ws, project=project,
            psettings=ProjectSettings(setup=script),
        )
    )
    return store.setup_state[ws.id]


def test_failed_script_keeps_exit_code_and_last_lines(tmp_path, monkeypatch):
    ws, project, _, _ = _rig(tmp_path)
    state = _setup(
        ws, project, "echo 'installing'; echo 'bun: command not found' >&2; exit 127", monkeypatch
    )
    assert state["status"] == "failed" and state["exit"] == 127
    assert "bun: command not found" in state["tail"]
    assert "installing" in state["tail"]


def test_tail_keeps_only_the_last_lines_and_drops_color_codes(tmp_path, monkeypatch):
    ws, project, _, _ = _rig(tmp_path)
    state = _setup(
        ws, project, "for i in $(seq 1 40); do printf '\\033[31mline %s\\033[0m\\n' $i; done; exit 1", monkeypatch
    )
    lines = state["tail"].splitlines()
    assert lines[-1] == "line 40" and len(lines) == 15
    assert "\x1b" not in state["tail"]


def test_a_passing_script_has_no_tail(tmp_path, monkeypatch):
    ws, project, _, _ = _rig(tmp_path)
    state = _setup(ws, project, "echo fine", monkeypatch)
    assert state["status"] == "ok" and state["tail"] == ""


def test_setup_removes_the_node_modules_link_to_the_checkout(tmp_path, monkeypatch):
    ws, project, proj_dir, wt_dir = _rig(tmp_path)
    (proj_dir / "node_modules").mkdir()
    (wt_dir / "node_modules").symlink_to(proj_dir / "node_modules")
    state = _setup(ws, project, "mkdir -p node_modules && touch node_modules/marker", monkeypatch)
    assert state["status"] == "ok"
    assert not (wt_dir / "node_modules").is_symlink()
    assert (wt_dir / "node_modules" / "marker").exists()
    assert not (proj_dir / "node_modules" / "marker").exists()


def test_a_link_to_somewhere_else_is_left_alone(tmp_path, monkeypatch):
    ws, project, proj_dir, wt_dir = _rig(tmp_path)
    shared = tmp_path / "shared-store"
    shared.mkdir()
    (wt_dir / "node_modules").symlink_to(shared)
    _setup(ws, project, "true", monkeypatch)
    assert (wt_dir / "node_modules").is_symlink()
    assert (wt_dir / "node_modules").resolve() == shared.resolve()


def test_a_failed_setup_puts_the_checkout_link_back(tmp_path, monkeypatch):
    ws, project, proj_dir, wt_dir = _rig(tmp_path)
    (proj_dir / "node_modules").mkdir()
    (wt_dir / "node_modules").symlink_to(proj_dir / "node_modules")
    state = _setup(ws, project, "exit 3", monkeypatch)
    assert state["status"] == "failed"
    assert (wt_dir / "node_modules").is_symlink()


def test_progress_frames_keep_only_the_last_one(tmp_path, monkeypatch):
    ws, project, _, _ = _rig(tmp_path)
    state = _setup(
        ws, project, "printf 'step 1\\rstep 2\\rerror: nope\\n'; exit 1", monkeypatch
    )
    assert state["tail"] == "error: nope"
