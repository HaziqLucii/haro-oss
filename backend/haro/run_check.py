"""Static check of a run script against the project's ``package.json``.

It answers one narrow question, "is the script this command names defined?", so the Run
button can say "no `dev` script in package.json" instead of starting a process that dies
on ``Missing script``. It never claims the command works: a found script only means
nothing was missing, and anything that is not a plain ``npm|pnpm|yarn run <x>`` (or
``start``) is left unjudged rather than guessed at. Reads one small file, runs nothing.
"""

from __future__ import annotations

import json
import re
import shlex
from pathlib import Path

#: Options that take the directory the package manager should run in.
_DIR_FLAGS = {"--prefix", "-C", "--dir", "--cwd"}
_NAME = re.compile(r"[A-Za-z0-9:_.@/-]+")
_CHAIN = ("&&", "||", ";", "|", "`", "$(")
#: Options that do not change which script runs. Any other option (workspaces, filters,
#: recursion, --if-present) makes "missing" not ours to judge.
_SKIP_FLAGS = {"--silent", "-s", "--no-color", "-q", "--quiet"}


def _parse(command: str) -> tuple[str, str, str | None] | None:
    """``(manager, script, dir)`` for a plain run command, else None."""
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if any(op in tok for tok in tokens for op in _CHAIN):
        # A chain: the link that fails may not be the one named first.
        return None
    if not tokens or tokens[0] not in ("npm", "pnpm", "yarn"):
        return None
    manager = tokens[0]
    folder: str | None = None
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok in _DIR_FLAGS:
            if i + 1 >= len(tokens):
                return None
            folder = tokens[i + 1]
            i += 2
        elif tok.split("=", 1)[0] in _DIR_FLAGS and "=" in tok:
            folder = tok.split("=", 1)[1]
            i += 1
        elif tok in _SKIP_FLAGS:
            i += 1
        elif tok.startswith("-"):
            return None
        else:
            break
    if i >= len(tokens):
        return None
    word = tokens[i]
    if word == "start":
        rest = tokens[i + 1 :]
        if any(t.startswith("-") for t in (rest[: rest.index("--")] if "--" in rest else rest)):
            return None
        return manager, "start", folder
    if word in ("run", "run-script") and i + 1 < len(tokens):
        name = tokens[i + 1]
        if name.startswith("-") or name == "--":
            return None
        if not _NAME.fullmatch(name):
            return None
        own = tokens[i + 2 :]
        if any(t.startswith("-") for t in (own[: own.index("--")] if "--" in own else own)):
            return None
        return manager, name, folder
    return None


def missing_script(command: str | None, root: str | Path) -> str | None:
    """The reason the run ``command`` names a script ``root`` does not define, or None
    when it is defined, is not a plain package-manager run, or cannot be read."""
    if not command or not command.strip():
        return None
    parsed = _parse(command.strip())
    if parsed is None:
        return None
    manager, name, folder = parsed
    base = Path(root) / folder if folder else Path(root)
    pkg = base / "package.json"
    where = f"{folder}/package.json" if folder else "package.json"
    if not pkg.is_file():
        return f"no {where} to run `{name}` from"
    try:
        data = json.loads(pkg.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    scripts = data.get("scripts")
    if isinstance(scripts, dict) and name in scripts:
        return None
    if manager == "yarn" and (base / "node_modules" / ".bin" / name).exists():
        return None  # yarn run also runs a binary of that name
    if name == "start" and manager == "npm" and (base / "server.js").is_file():
        return None
    return f"no `{name}` script in {where}"
