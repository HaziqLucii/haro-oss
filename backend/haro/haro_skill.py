"""haro_skill.py — ship haro's own platform knowledge as Claude Code skills.

Every agent haro spawns runs the ``claude`` CLI inside a git worktree of the
*user's* project. Claude Code auto-discovers skills from the user-level skills dir
(``~/.claude/skills``, honouring ``CLAUDE_CONFIG_DIR``), so installing skills there
teaches every agent — in every workspace, present and future — about haro.

Two skills, two audiences:
  - ``haro``     — subject-matter expert on *using* haro (the gate,
                   settings.toml, the task flow, merge/PR). Applies in any workspace.
  - ``haro-dev`` — contributor's map of haro's *own* codebase. Only relevant
                   when the worktree IS the haro repo itself (dogfooding); it
                   self-checks that before doing anything.

Why user-level and not per-worktree: writing ``.claude/skills`` into each worktree
would surface as untracked files in the *user's* project diff and could leak into
their gate. A single user-level install covers every workspace with zero pollution.

Skill sources are bundled in the repo (``assets/skills/<name>``) so they ship with
haro and are version-controlled; we refresh the installed copies on every boot
so they always match the running build (these skills are ours to own — we overwrite
them, but leave any *other* user skills untouched).
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

_SKILL_NAMES = ["haro", "haro-dev"]
_BUNDLED_ROOT = Path(__file__).parent / "assets" / "skills"


def _skills_dir() -> Path:
    """User-level Claude Code skills dir, honouring CLAUDE_CONFIG_DIR like the CLI."""
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(config_dir) / "skills"


def _install_one(name: str) -> str:
    bundled = _BUNDLED_ROOT / name
    src = bundled / "SKILL.md"
    if not src.is_file():
        return f"bundled skill missing at {src}: skipped"
    dest = _skills_dir() / name
    try:
        dest.mkdir(parents=True, exist_ok=True)
        # Copy the whole bundled dir (SKILL.md + any future reference files),
        # overwriting our own files while leaving unrelated user skills alone.
        for item in bundled.iterdir():
            target = dest / item.name
            if item.is_dir():
                shutil.copytree(item, target, dirs_exist_ok=True)
            else:
                shutil.copy2(item, target)
        return f"{name} skill installed → {dest}"
    except Exception as exc:  # noqa: BLE001 — install must never crash the app
        return f"{name} skill install failed: {exc}"


def install_haro_skill() -> list[str]:
    """Refresh the user-level haro skills from the bundled sources.

    Idempotent and best-effort: returns human-readable notes (mirroring the boot
    reconcile logs) and never raises — a skill-install hiccup must not stop the app
    from serving.
    """
    return [_install_one(name) for name in _SKILL_NAMES]
