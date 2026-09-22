"""Sanity checks for the Claude Code plugin (usp-critique-round3.md Move B,
plugin/). Not an end-to-end test of the hooks actually firing inside Claude
Code (untestable here) — this only catches "obviously broken": invalid JSON,
a shell syntax error, a missing shebang/exec bit.

Scope note: `WorktreeCreate`/`WorktreeRemove` hooks were built, hand-tested
against a live backend, and then CUT after an independent review (refuter)
found the real Claude Code contract for these two events is dangerous to what
was shipped: `WorktreeCreate` is a REPLACEMENT hook (it must itself perform
the checkout and return the resulting path, or worktree creation fails
outright for every project on the machine — an observer-only rescan script
breaks it) and the `WorktreeRemove` handler called an endpoint that
force-deletes the user's git branch (`git_ops.remove_worktree` → `git branch
-D`), reproduced live in two orderings. Only `Stop`/`SubagentStop` — verified
safe and matching the documented contract — ship. See CHANGELOG."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin"


def test_plugin_manifest_is_valid_json():
    manifest = json.loads((PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text())
    assert manifest["name"] == "haro-gate"


def test_hooks_json_wires_only_stop_and_subagent_stop():
    hooks = json.loads((PLUGIN_ROOT / "hooks" / "hooks.json").read_text())["hooks"]
    assert set(hooks) == {"Stop", "SubagentStop"}
    for event, entries in hooks.items():
        commands = [h["command"] for e in entries for h in e["hooks"]]
        assert commands, event
        for cmd in commands:
            assert "${CLAUDE_PLUGIN_ROOT}" in cmd and "scripts/haro-gate.sh" in cmd, (event, cmd)


def test_stop_and_subagent_stop_share_the_same_script():
    hooks = json.loads((PLUGIN_ROOT / "hooks" / "hooks.json").read_text())["hooks"]
    stop_cmd = hooks["Stop"][0]["hooks"][0]["command"]
    subagent_cmd = hooks["SubagentStop"][0]["hooks"][0]["command"]
    assert stop_cmd == subagent_cmd  # same blocking contract, see haro-gate.sh's comment


def test_haro_gate_script_exists_executable_and_shell_syntax_is_valid():
    path = PLUGIN_ROOT / "scripts" / "haro-gate.sh"
    assert path.exists(), path
    assert path.read_text().startswith("#!/bin/sh")
    assert path.stat().st_mode & 0o111, "haro-gate.sh is not executable"
    sh = shutil.which("sh")
    result = subprocess.run([sh, "-n", str(path)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_no_worktree_hooks_or_scripts_shipped():
    # The cut described in this file's module docstring — pinned as a test so
    # a future re-add doesn't silently reintroduce the same two bugs without
    # someone deliberately deciding to.
    hooks = json.loads((PLUGIN_ROOT / "hooks" / "hooks.json").read_text())["hooks"]
    assert "WorktreeCreate" not in hooks
    assert "WorktreeRemove" not in hooks
    assert not (PLUGIN_ROOT / "scripts" / "worktree-rescan.sh").exists()
    assert not (PLUGIN_ROOT / "scripts" / "worktree-remove.sh").exists()
