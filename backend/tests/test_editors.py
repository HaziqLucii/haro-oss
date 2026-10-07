""""Open in..." (``GET /editors``, ``POST /workspaces/{id}/open``).

Detection runs against a fake PATH / fake app dirs, and the spawner is always mocked:
no test launches a real editor. Handlers are called directly, like the rest of the suite.
"""

from __future__ import annotations

import asyncio
import os
import stat
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import editors
from haro import main as main_mod
from haro.models import OpenInRequest, Project, Workspace


def _exe(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def _detect(tmp_path, platform="linux", env=None, app_dirs=None, bins=(), extra=()):
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    for b in bins:
        _exe(bindir / b)
    e = {"PATH": str(bindir), **(env or {})}
    return editors.detect_editors(e, platform=platform, home=str(tmp_path / "home"),
                                  app_dirs=app_dirs if app_dirs is not None else [],
                                  extra_bin_dirs=list(extra))


# --- detection ---------------------------------------------------------------
def test_detects_path_binaries_and_classifies_kinds(tmp_path):
    det = _detect(tmp_path, bins=["code", "cursor", "nvim", "hx", "xdg-open"])
    assert det["vscode"].available and det["vscode"].prefix == (str(tmp_path / "bin" / "code"),)
    assert det["cursor"].available
    assert det["neovim"].available and det["neovim"].prefix == ("nvim",)
    assert det["helix"].available and det["helix"].prefix == ("hx",)
    assert not det["zed"].available and not det["vim"].available
    assert det["file_manager"].available and det["file_manager"].label == "File manager"
    kinds = {f.id: f.kind for f in det.values()}
    assert kinds["vscode"] == "gui" and kinds["neovim"] == "terminal"
    assert kinds["file_manager"] == "file_manager"


def test_macos_app_bundles_and_versioned_jetbrains(tmp_path):
    apps = tmp_path / "Applications"
    _exe(apps / "Zed.app/Contents/MacOS/cli")
    _exe(apps / "Visual Studio Code.app/Contents/Resources/app/bin/code")
    _exe(apps / "IntelliJ IDEA 2025.3.app/Contents/MacOS/idea")
    new_idea = _exe(apps / "IntelliJ IDEA 2026.1.app/Contents/MacOS/idea")
    _exe(apps / "Sublime Text.app/Contents/SharedSupport/bin/subl")
    det = _detect(tmp_path, platform="darwin", app_dirs=[str(apps)], bins=["open"])
    assert det["zed"].prefix == (str(apps / "Zed.app/Contents/MacOS/cli"),)
    assert det["vscode"].available and det["sublime"].available
    assert det["idea"].prefix == (str(new_idea),)
    assert not det["pycharm"].available and not det["cursor"].available
    assert det["file_manager"].label == "Finder" and det["file_manager"].available


def test_bundle_dirs_ignored_off_macos(tmp_path):
    apps = tmp_path / "Applications"
    _exe(apps / "Zed.app/Contents/MacOS/cli")
    assert not _detect(tmp_path, platform="linux", app_dirs=[str(apps)])["zed"].available


def test_linux_extra_dirs_and_flatpak_export(tmp_path):
    home = tmp_path / "home"
    _exe(home / ".local/bin/zed")
    _exe(home / ".local/share/flatpak/exports/bin/com.visualstudio.code")
    det = _detect(tmp_path, extra=["~/.local/bin", "~/.local/share/flatpak/exports/bin"])
    assert det["zed"].prefix == (str(home / ".local/bin/zed"),)
    assert det["vscode"].prefix == (str(home / ".local/share/flatpak/exports/bin/com.visualstudio.code"),)


def test_env_editor_classified_by_basename(tmp_path):
    det = _detect(tmp_path, bins=["nvim"], env={"EDITOR": "nvim"})
    e = det["env_editor"]
    assert (e.kind, e.available, e.label, e.prefix) == ("terminal", True, "$EDITOR (nvim)", ("nvim",))

    det = _detect(tmp_path, bins=["code"], env={"EDITOR": "vi", "VISUAL": "code --wait"})
    e = det["env_editor"]
    assert e.kind == "gui" and e.label == "$VISUAL (code)"
    assert e.prefix == (str(tmp_path / "bin" / "code"), "--wait")

    assert not _detect(tmp_path)["env_editor"].available
    assert not _detect(tmp_path, env={"EDITOR": "not-installed"})["env_editor"].available


def test_cache_and_refresh(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(editors, "_cache", None)
    monkeypatch.setattr(editors, "detect_editors", lambda env: calls.append(1) or {})
    editors.get_detection({})
    editors.get_detection({})
    assert len(calls) == 1
    editors.get_detection({}, refresh=True)
    assert len(calls) == 2


# --- argv / command construction --------------------------------------------
def _found(det, id_):
    return det[id_]


@pytest.fixture
def wt(tmp_path):
    root = tmp_path / "wt"
    (root / "src").mkdir(parents=True)
    (root / "src" / "a.py").write_text("x\n")
    return root.resolve()


def test_argv_per_gui_target(tmp_path, wt):
    det = _detect(tmp_path, bins=["code", "cursor", "zed", "idea", "subl", "xdg-open"])
    f = wt / "src" / "a.py"
    p = lambda i: det[i].prefix[0]  # noqa: E731
    w = str(wt)
    assert editors.build_argv(det["vscode"], w, f, 7) == [p("vscode"), w, "--goto", f"{f}:7"]
    assert editors.build_argv(det["cursor"], w, f, None) == [p("cursor"), w, "--goto", str(f)]
    assert editors.build_argv(det["zed"], w, f, 7) == [p("zed"), w, f"{f}:7"]
    assert editors.build_argv(det["idea"], w, f, 7) == [p("idea"), "--line", "7", str(f)]
    assert editors.build_argv(det["idea"], w, f, None) == [p("idea"), str(f)]
    assert editors.build_argv(det["sublime"], w, f, 7) == [p("sublime"), f"{f}:7"]
    for i in ("vscode", "zed", "idea", "sublime"):
        assert editors.build_argv(det[i], w, None, None) == [p(i), w]
    assert editors.build_argv(det["file_manager"], w, f, 3) == [det["file_manager"].prefix[0], w]


def test_shell_commands(tmp_path, wt):
    det = _detect(tmp_path, bins=["nvim", "vim", "hx"])
    f = wt / "src" / "a.py"
    w = str(wt)
    assert editors.build_shell_command(det["neovim"], w, f, 12) == "nvim +12 src/a.py"
    assert editors.build_shell_command(det["vim"], w, f, None) == "vim src/a.py"
    assert editors.build_shell_command(det["helix"], w, f, 12) == "hx src/a.py:12"
    assert editors.build_shell_command(det["neovim"], w, None, None) == "nvim ."


def test_shell_command_quotes_hostile_names(tmp_path, wt):
    det = _detect(tmp_path, bins=["nvim"])
    weird = wt / "a b; rm -rf ~.txt"
    weird.write_text("")
    cmd = editors.build_shell_command(det["neovim"], str(wt), weird, 3)
    assert cmd == "nvim +3 'a b; rm -rf ~.txt'"
    dash = wt / "-e.txt"
    dash.write_text("")
    assert editors.build_shell_command(det["neovim"], str(wt), dash, None) == "nvim ./-e.txt"


# --- endpoints ---------------------------------------------------------------
class Spawner:
    def __init__(self):
        self.calls = []

    async def __call__(self, argv, cwd, env):
        self.calls.append((argv, cwd, env))


@pytest.fixture
def api(tmp_path, wt, monkeypatch):
    det = _detect(tmp_path, bins=["code", "nvim", "xdg-open"])
    monkeypatch.setattr(editors, "_cache", det)
    spawner = Spawner()
    monkeypatch.setattr(editors, "spawn_detached", spawner)
    proj = Project(name="p", path=str(wt), default_branch="main")
    w = Workspace(project_id=proj.id, name="w", branch="feat", worktree_path=str(wt), base_ref="main", port=4321)
    main_mod.store.projects[proj.id] = proj
    main_mod.store.workspaces[w.id] = w
    yield w, spawner
    main_mod.store.workspaces.pop(w.id, None)
    main_mod.store.projects.pop(proj.id, None)


def _open(ws_id, **body):
    return asyncio.run(main_mod.open_in_editor(ws_id, OpenInRequest(**body)))


def _status(ws_id, **body) -> int:
    with pytest.raises(HTTPException) as exc:
        _open(ws_id, **body)
    return exc.value.status_code


def test_editors_route_lists_all_targets(api):
    out = asyncio.run(main_mod.list_editors())
    by_id = {e["id"]: e for e in out}
    assert by_id["vscode"] == {"id": "vscode", "label": "VS Code", "kind": "gui", "available": True}
    assert by_id["zed"]["available"] is False
    assert by_id["neovim"]["kind"] == "terminal"
    assert {"env_editor", "file_manager"} <= set(by_id)


def test_editors_refresh_reprobes(api, monkeypatch):
    seen = []
    monkeypatch.setattr(editors, "detect_editors", lambda env: seen.append(1) or {})
    asyncio.run(main_mod.list_editors(refresh=True))
    assert seen == [1]


def test_gui_open_file_line_spawns_in_worktree(api, wt):
    w, spawner = api
    out = _open(w.id, target="vscode", path="src/a.py", line=9)
    assert out.mode == "spawned" and out.command is None
    (argv, cwd, env), = spawner.calls
    assert argv[1:] == [str(wt), "--goto", f"{wt / 'src' / 'a.py'}:9"]
    assert cwd == str(wt)
    assert env["HARO_PORT"] == "4321"
    assert env["HARO_WORKSPACE_PATH"] == str(wt)


def test_gui_open_worktree_only_and_file_manager(api, wt):
    w, spawner = api
    _open(w.id, target="vscode")
    _open(w.id, target="file_manager")
    assert spawner.calls[0][0][1:] == [str(wt)]
    assert spawner.calls[1][0][1:] == [str(wt)]


def test_terminal_target_returns_command_and_never_spawns(api):
    w, spawner = api
    out = _open(w.id, target="neovim", path="src/a.py", line=4)
    assert out.mode == "shell" and out.command == "nvim +4 src/a.py"
    assert _open(w.id, target="neovim").command == "nvim ."
    assert spawner.calls == []


def test_path_escapes_rejected(api, wt, tmp_path):
    w, spawner = api
    outside = tmp_path / "secret.txt"
    outside.write_text("s")
    (wt / "link").symlink_to(outside)
    (wt / "dirlink").symlink_to(tmp_path)
    for bad in ("../secret.txt", "src/../../secret.txt", str(outside), "link", "dirlink/secret.txt", "a\0b"):
        assert _status(w.id, target="vscode", path=bad) == 400, bad
        assert _status(w.id, target="neovim", path=bad) == 400, bad
    assert spawner.calls == []


def test_absolute_path_inside_worktree_ok(api, wt):
    w, spawner = api
    assert _open(w.id, target="neovim", path=str(wt / "src" / "a.py")).command == "nvim src/a.py"


def test_missing_file_is_404(api):
    w, _ = api
    assert _status(w.id, target="vscode", path="nope.py") == 404


def test_line_validation(api):
    w, _ = api
    assert _status(w.id, target="vscode", path="src/a.py", line=0) == 400
    assert _status(w.id, target="vscode", path="src/a.py", line=-3) == 400
    assert _status(w.id, target="vscode", line=3) == 400


def test_unknown_and_unavailable_targets_are_400(api, monkeypatch):
    w, spawner = api
    assert _status(w.id, target="emacs-gui") == 400
    reprobed = []
    real = editors.detect_editors
    monkeypatch.setattr(editors, "detect_editors", lambda env: reprobed.append(1) or real({"PATH": ""}, app_dirs=[], extra_bin_dirs=[]))
    assert _status(w.id, target="zed") == 400
    assert reprobed == [1]  # re-probed once before refusing
    assert spawner.calls == []


def test_missing_workspace_is_404():
    assert _status("ws_nope", target="vscode") == 404


def test_missing_worktree_is_400(api, wt):
    w, spawner = api
    w.worktree_path = str(wt / "gone")
    assert _status(w.id, target="vscode") == 400
    assert spawner.calls == []


def test_spawn_failure_is_400(api, monkeypatch):
    w, _ = api

    async def boom(*_a):
        raise FileNotFoundError("no such file")

    monkeypatch.setattr(editors, "spawn_detached", boom)
    assert _status(w.id, target="vscode") == 400


# --- project-root files (settings, instructions, backlog docs) ------------------
def _open_project(project_id, **body):
    return asyncio.run(main_mod.open_project_file(project_id, OpenInRequest(**body)))


def _project_status(project_id, **body) -> int:
    with pytest.raises(HTTPException) as exc:
        _open_project(project_id, **body)
    return exc.value.status_code


def test_project_file_opens_in_gui_editor_at_project_root(api, wt):
    w, spawner = api
    (wt / ".haro").mkdir()
    (wt / ".haro" / "instructions.md").write_text("x")
    out = _open_project(w.project_id, target="vscode", path=".haro/instructions.md")
    assert out.mode == "spawned"
    (argv, cwd, _env), = spawner.calls
    assert argv[1:] == [str(wt), "--goto", str(wt / ".haro" / "instructions.md")]
    assert cwd == str(wt)


def test_project_file_that_does_not_exist_yet_is_allowed(api, wt):
    w, spawner = api
    _open_project(w.project_id, target="vscode", path=".haro/instructions.local.md")
    assert spawner.calls[0][0][-1] == str(wt / ".haro" / "instructions.local.md")


def test_project_file_rejects_escapes_folders_and_terminal_editors(api, wt, tmp_path):
    w, spawner = api
    pid = w.project_id
    for bad in ("../secret.txt", str(tmp_path / "secret.txt"), "a\0b"):
        assert _project_status(pid, target="vscode", path=bad) == 400, bad
    assert _project_status(pid, target="vscode", path="src") == 400
    assert _project_status(pid, target="vscode") == 400
    assert _project_status(pid, target="neovim", path="src/a.py") == 400
    assert _project_status("proj_nope", target="vscode", path="src/a.py") == 404
    assert spawner.calls == []


def test_routes_are_wired():
    paths = {(r.path, m) for r in main_mod.app.routes for m in getattr(r, "methods", ())}
    assert ("/editors", "GET") in paths
    assert ("/workspaces/{ws_id}/open", "POST") in paths
