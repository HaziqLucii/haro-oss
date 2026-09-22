#!/bin/sh
# Shared by the Stop and SubagentStop hooks — both share the same "exit 2 blocks,
# keep working" contract, so one script covers a plain agent and a Task subagent.
# Blocks Claude from stopping until `haro gate` is green. `haro gate`'s own exit
# codes distinguish a red gate (2 — block, keep working) from the CLI itself
# failing to run (1 — a setup problem, e.g. a typo'd path or `haro` not on PATH,
# that retrying won't fix: warn but let Claude stop rather than looping forever).
#
# Deliberately does NOT check stop_hook_active to bail early on a red gate — the
# whole point is to keep blocking across retries as the agent fixes what's red.
# Claude Code's own Stop-hook cap (8 consecutive blocks by default; raise it with
# CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) is the safety net against a genuine deadlock,
# not this script.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1
output=$(haro gate 2>&1)
rc=$?   # NOT `status` — zsh treats that name as a readonly builtin and errors on assignment
if [ "$rc" -eq 2 ]; then
  echo "$output" >&2   # fed back to Claude as the reason to keep working
  exit 2
elif [ "$rc" -ne 0 ]; then
  echo "haro gate could not run (exit $rc), not blocking on it:" >&2
  echo "$output" >&2
fi
exit 0
