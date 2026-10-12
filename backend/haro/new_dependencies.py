"""Dependency names a change adds to a manifest, read from the files alone.

For each changed ``package.json``, ``requirements*.txt`` and ``pyproject.toml``, the names present
now and absent from the same file at the base ref. No registry is asked and nothing is said about
what a package is: a name the developer did not expect is a reason to look, and that is all this is.
A version bump is not new, and a lockfile-only change is not covered.
"""

from __future__ import annotations

import json
import os
import re
import tomllib
from pathlib import Path

from . import git_ops
from .models import ReceiptNewDependency

_MAX_FILES = 12
_MAX_NAMES = 30
_JS_SECTIONS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")
_PEP508 = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)")
#: A package name as a registry allows it. A manifest key is the agent's text, and a name with a
#: backtick or a newline in it would reach the receipt markdown, so anything else is left out.
_NAME = re.compile(r"^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+$")


def _norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def _requirement(spec: object) -> str | None:
    m = _PEP508.match(spec) if isinstance(spec, str) else None
    return _norm(m.group(1)) if m else None


def _package_json(text: str) -> set[str]:
    data = json.loads(text)
    return {
        name
        for section in _JS_SECTIONS
        if isinstance(data.get(section), dict)
        for name in data[section]
        if isinstance(name, str) and len(name) <= 214 and _NAME.match(name)
    }


def _requirements(text: str) -> set[str]:
    names: set[str] = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line and not line.startswith(("-", "git+", "http")):
            if (n := _requirement(line)):
                names.add(n)
    return names


def _pyproject(text: str) -> set[str]:
    data = tomllib.loads(text)
    names: set[str] = set()
    project = data.get("project") or {}
    groups = [project.get("dependencies") or []]
    groups += list((project.get("optional-dependencies") or {}).values())
    groups += list((data.get("dependency-groups") or {}).values())
    for group in groups:
        names |= {n for spec in group if (n := _requirement(spec))}
    poetry = (data.get("tool") or {}).get("poetry") or {}
    tables = [poetry.get("dependencies") or {}]
    tables += [g.get("dependencies") or {} for g in (poetry.get("group") or {}).values() if isinstance(g, dict)]
    for table in tables:
        names |= {_norm(k) for k in table if k.lower() != "python" and _NAME.match(k)}
    return names


def _parser(path: str):
    base = os.path.basename(path)
    if base == "package.json":
        return _package_json
    if base == "pyproject.toml":
        return _pyproject
    if re.fullmatch(r"requirements.*\.txt", base):
        return _requirements
    return None


async def _base_text(worktree: str, base_ref: str, path: str) -> str:
    try:
        return await git_ops._git("show", f"{base_ref}:{path}", cwd=worktree)
    except git_ops.GitError:
        return ""


async def new_dependencies(worktree: str, base_ref: str, changed: list[str]) -> list[ReceiptNewDependency]:
    out: list[ReceiptNewDependency] = []
    for path in [p for p in changed if _parser(p)][:_MAX_FILES]:
        parse = _parser(path)
        try:
            now = Path(worktree, path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        try:
            before = await _base_text(worktree, base_ref, path)
            added = parse(now) - (parse(before) if before.strip() else set())
        except (ValueError, TypeError, AttributeError):
            continue
        if added:
            out.append(ReceiptNewDependency(path=path, names=sorted(added)[:_MAX_NAMES]))
    return out
