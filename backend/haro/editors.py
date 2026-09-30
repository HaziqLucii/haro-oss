"""External editors for "Open in...": detection, argv construction, detached spawn.

GUI editors and the file manager are launched by the backend so they inherit the
worktree's shell env (login-shell PATH, HARO_PORT, nvm...). Terminal editors are never
launched here: the client pastes the returned command into the Shell tab, which already
runs a PTY in the worktree with that same env.

The backend's own ``PATH`` is already the user's login-shell PATH (the desktop launcher
resolves it before spawning the backend), so detection probes ``env["PATH"]`` first and
only then the well-known install dirs below.
"""

from __future__ import annotations

import asyncio
import glob
import os
import shlex
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Sequence

from .files import safe_path


@dataclass(frozen=True)
class Target:
    id: str
    label: str
    kind: str  # "gui" | "terminal" | "file_manager"
    style: str  # how argv / the shell command is shaped, see build_*
    names: tuple[str, ...] = ()  # executable names probed on PATH (and flatpak exports)
    mac_bins: tuple[str, ...] = ()  # globs under an Applications dir, macOS only


TARGETS: tuple[Target, ...] = (
    Target("vscode", "VS Code", "gui", "vscode",
           ("code", "com.visualstudio.code"),
           ("Visual Studio Code.app/Contents/Resources/app/bin/code",)),
    Target("vscode-insiders", "VS Code Insiders", "gui", "vscode",
           ("code-insiders",),
           ("Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",)),
    Target("cursor", "Cursor", "gui", "vscode",
           ("cursor",),
           ("Cursor.app/Contents/Resources/app/bin/cursor",)),
    Target("zed", "Zed", "gui", "zed",
           ("zed", "zeditor", "dev.zed.Zed"),
           ("Zed.app/Contents/MacOS/cli",)),
    Target("idea", "IntelliJ IDEA", "gui", "jetbrains",
           ("idea", "idea.sh", "intellij-idea-ultimate", "intellij-idea-community",
            "com.jetbrains.IntelliJ-IDEA-Community", "com.jetbrains.IntelliJ-IDEA-Ultimate"),
           ("IntelliJ IDEA*.app/Contents/MacOS/idea",)),
    Target("pycharm", "PyCharm", "gui", "jetbrains",
           ("pycharm", "pycharm.sh", "pycharm-community", "pycharm-professional",
            "com.jetbrains.PyCharm-Community", "com.jetbrains.PyCharm-Professional"),
           ("PyCharm*.app/Contents/MacOS/pycharm",)),
    Target("webstorm", "WebStorm", "gui", "jetbrains",
           ("webstorm", "webstorm.sh", "com.jetbrains.WebStorm"),
           ("WebStorm*.app/Contents/MacOS/webstorm",)),
    Target("sublime", "Sublime Text", "gui", "sublime",
           ("subl", "sublime_text", "com.sublimetext.three"),
           ("Sublime Text*.app/Contents/SharedSupport/bin/subl",)),
    Target("neovim", "Neovim", "terminal", "plusline", ("nvim",)),
    Target("vim", "Vim", "terminal", "plusline", ("vim",)),
    Target("helix", "Helix", "terminal", "helix", ("hx", "helix")),
)

ENV_EDITOR_ID = "env_editor"
FILE_MANAGER_ID = "file_manager"

# $VISUAL / $EDITOR basenames known to open a window. Anything else is treated as a
# terminal editor: typing it into the Shell tab works for GUI programs too.
_GUI_BASENAMES = {
    "code": "vscode", "code-insiders": "vscode", "cursor": "vscode",
    "zed": "zed", "zeditor": "zed",
    "subl": "sublime", "sublime_text": "sublime",
    "idea": "jetbrains", "pycharm": "jetbrains", "webstorm": "jetbrains",
    "mate": "plain", "gedit": "plain", "kate": "plain", "atom": "plain",
    "xed": "plain", "gnome-text-editor": "plain", "bbedit": "plain",
}
_PLUSLINE_BASENAMES = {"nvim", "vim", "vi", "nano", "emacs", "kak", "view"}
_HELIX_BASENAMES = {"hx", "helix"}

_MAC_APP_DIRS = ("/Applications", "~/Applications")
_MAC_BIN_DIRS = (
    "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin",
    "~/Library/Application Support/JetBrains/Toolbox/scripts",
)
_LINUX_BIN_DIRS = (
    "/usr/local/bin", "/usr/bin", "/snap/bin", "~/.local/bin",
    "~/.local/share/flatpak/exports/bin", "/var/lib/flatpak/exports/bin",
    "~/.local/share/JetBrains/Toolbox/scripts",
)


@dataclass(frozen=True)
class Found:
    id: str
    label: str
    kind: str
    style: str
    # GUI / file manager: absolute executable (plus any flags) to launch.
    # Terminal: bare command words to type into the Shell tab.
    prefix: tuple[str, ...] = ()

    @property
    def available(self) -> bool:
        return bool(self.prefix)


Detection = dict[str, Found]


def _is_exec(p: str) -> bool:
    return os.path.isfile(p) and os.access(p, os.X_OK)


def _which(name: str, search_path: str) -> Optional[str]:
    found = shutil.which(name, path=search_path)
    return os.path.abspath(found) if found else None


def _search_path(
    env: Mapping[str, str], platform: str, home: str, extra: Optional[Sequence[str]] = None
) -> str:
    dirs = [d for d in env.get("PATH", "").split(os.pathsep) if d]
    if extra is None:
        extra = _MAC_BIN_DIRS if platform == "darwin" else _LINUX_BIN_DIRS
    for d in extra:
        d = d.replace("~", home, 1) if d.startswith("~") else d
        if d not in dirs:
            dirs.append(d)
    return os.pathsep.join(dirs)


def _mac_bin(target: Target, app_dirs: list[str]) -> Optional[str]:
    for app_dir in app_dirs:
        for pattern in target.mac_bins:
            # Newest first: "IntelliJ IDEA 2026.1.app" sorts after "...2025.3.app".
            for cand in sorted(glob.glob(os.path.join(app_dir, pattern)), reverse=True):
                if _is_exec(cand):
                    return cand
    return None


def _classify_env_editor(value: str, var: str, search_path: str) -> Found:
    try:
        parts = shlex.split(value)
    except ValueError:
        parts = []
    if not parts:
        return Found(ENV_EDITOR_ID, "$EDITOR", "terminal", "plain")
    base = os.path.basename(parts[0])
    label = f"${var} ({base})"
    if base in _GUI_BASENAMES:
        exe = parts[0] if os.path.isabs(parts[0]) and _is_exec(parts[0]) else _which(parts[0], search_path)
        prefix = (exe, *parts[1:]) if exe else ()
        return Found(ENV_EDITOR_ID, label, "gui", _GUI_BASENAMES[base], prefix)
    style = "plusline" if base in _PLUSLINE_BASENAMES else "helix" if base in _HELIX_BASENAMES else "plain"
    present = _is_exec(parts[0]) if os.path.isabs(parts[0]) else _which(parts[0], search_path)
    return Found(ENV_EDITOR_ID, label, "terminal", style, tuple(parts) if present else ())


def detect_editors(
    env: Mapping[str, str],
    platform: str = sys.platform,
    home: Optional[str] = None,
    app_dirs: Optional[list[str]] = None,
    extra_bin_dirs: Optional[Sequence[str]] = None,
) -> Detection:
    """Probe every target. ``env``/``platform``/``home``/``app_dirs``/``extra_bin_dirs``
    are parameters so tests can point detection at a fake PATH and fake install dirs."""
    home = home or os.path.expanduser("~")
    is_mac = platform == "darwin"
    search = _search_path(env, platform, home, extra_bin_dirs)
    if app_dirs is None:
        app_dirs = [d.replace("~", home, 1) if d.startswith("~") else d for d in _MAC_APP_DIRS]

    out: Detection = {}
    for t in TARGETS:
        exe = None
        for name in t.names:
            exe = _which(name, search)
            if exe:
                break
        if not exe and is_mac and t.mac_bins:
            exe = _mac_bin(t, app_dirs)
        if not exe:
            prefix: tuple[str, ...] = ()
        elif t.kind == "terminal":
            prefix = (os.path.basename(exe),)
        else:
            prefix = (exe,)
        out[t.id] = Found(t.id, t.label, t.kind, t.style, prefix)

    var = "VISUAL" if env.get("VISUAL") else "EDITOR"
    out[ENV_EDITOR_ID] = _classify_env_editor(env.get(var, ""), var, search)

    opener = "open" if is_mac else "xdg-open"
    exe = _which(opener, search)
    out[FILE_MANAGER_ID] = Found(
        FILE_MANAGER_ID, "Finder" if is_mac else "File manager", "file_manager", "plain",
        (exe,) if exe else (),
    )
    return out


_cache: Optional[Detection] = None


def get_detection(env: Mapping[str, str], refresh: bool = False) -> Detection:
    global _cache
    if _cache is None or refresh:
        _cache = detect_editors(env)
    return _cache


def reset_cache() -> None:
    global _cache
    _cache = None


def list_editors(det: Detection) -> list[dict]:
    return [
        {"id": f.id, "label": f.label, "kind": f.kind, "available": f.available}
        for f in det.values()
    ]


def resolve_target_path(worktree: str, path: Optional[str]) -> Optional[Path]:
    """Resolve ``path`` inside the worktree. ValueError if it escapes (``..``, an
    absolute path elsewhere, or a symlink pointing out), FileNotFoundError if absent."""
    if path is None or path == "":
        return None
    target = safe_path(worktree, path)
    if not target.exists():
        raise FileNotFoundError(path)
    return target


def build_argv(found: Found, worktree: str, file: Optional[Path], line: Optional[int]) -> list[str]:
    """argv for a GUI editor / file manager. Lists only, never a shell string."""
    argv = list(found.prefix)
    if found.kind == "file_manager" or file is None:
        return [*argv, worktree]
    f = str(file)
    at = f"{f}:{line}" if line else f
    if found.style == "vscode":
        # The worktree first, so the file opens inside that folder's window rather than
        # whichever window was last active.
        return [*argv, worktree, "--goto", at]
    if found.style == "zed":
        return [*argv, worktree, at]
    if found.style == "sublime":
        return [*argv, at]
    if found.style == "jetbrains":
        return [*argv, "--line", str(line), f] if line else [*argv, f]
    return [*argv, f]


def build_shell_command(found: Found, worktree: str, file: Optional[Path], line: Optional[int]) -> str:
    """Command for the client to type into the Shell tab (cwd = the worktree)."""
    words = list(found.prefix)
    if file is None:
        return shlex.join([*words, "."])
    rel = os.path.relpath(file, Path(worktree).resolve())
    if rel.startswith("-"):
        rel = f"./{rel}"
    if found.style == "plusline":
        return shlex.join([*words, *([f"+{line}"] if line else []), rel])
    if found.style == "helix":
        return shlex.join([*words, f"{rel}:{line}" if line else rel])
    return shlex.join([*words, rel])


_bg_tasks: set[asyncio.Task] = set()


def _log_fd():
    try:
        return sys.stderr.fileno()
    except (AttributeError, OSError, ValueError):
        return asyncio.subprocess.DEVNULL


async def spawn_detached(argv: list[str], cwd: str, env: Mapping[str, str]) -> None:
    """Start ``argv`` in its own session and return at once.

    ``start_new_session`` keeps the editor alive if the backend is killed by process
    group; stdin is closed and stdout/stderr go to the backend's log so the child never
    holds the request's sockets. A background ``wait`` reaps it so quick launcher shims
    (``code``, ``zed``) don't linger as zombies."""
    log = _log_fd()
    proc = await asyncio.create_subprocess_exec(
        *argv,
        cwd=cwd,
        env=dict(env),
        stdin=asyncio.subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    task = asyncio.create_task(proc.wait())
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)
