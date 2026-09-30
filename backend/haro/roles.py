"""Pure helpers for the workflow-roles loop's scout step (Phase 2 of
notes/workflow-roles-plan.md): haro injects its OWN scout sub-agent via Claude
Code's ``--agents`` flag, rather than relying on the caller's machine having
``~/.claude/agents/scout.md`` on disk. That file is real (Haziq's own daily-driver
config) but invisible in two situations this module exists to fix: it never
travels with the project (a teammate or CI box starting from scratch has no
scout at all), and it vanishes outright under ``[agent] sandbox`` — the bwrap
profile deliberately never binds ``~/.claude/agents`` (see ``sandbox.py``'s
default-deny ``$HOME``). ``--agents`` puts the same agent on the argv instead,
which survives both.

Nothing here touches I/O or the adapter; ``claude_code.py`` wires
``scout_agent_json`` onto the CLI invocation and ``main.py`` decides *when* (only
when `[roles] enabled` and a scout role is configured).
"""

from __future__ import annotations

from .config import RoleConfig

#: Adapted from Haziq's own ``~/.claude/agents/scout.md`` (the daily-driver
#: original this project's CLAUDE.md already points every session at for "where
#: is X" lookups) — the prompt body only, no frontmatter, since ``--agents``
#: carries `description`/`tools`/`model` as separate JSON keys.
SCOUT_PROMPT = """\
You are Scout: a read-only mapper and locator. You work in two modes.

1. LOOKUP ("where is X"): report each hit as `path:line` plus a one-line note
   on what it is.
2. MAP / SURVEY ("map the pages", "inventory the components", "where does the
   config live"): return a compact structured inventory grouped by area (folder
   or feature), each entry a path plus a one-line role. A shallow tree of
   locations, not a deep read.

Rules for both modes:
- Report locations and structure only. Never paste file contents or large
  excerpts back.
- When something has many hits, report the most relevant and state the total
  count.
- State explicitly what you did NOT find or could not reach, so the caller
  knows the gaps.
- Stay compact: a lookup is a handful of lines; a full map is a tight outline,
  not a wall of text. If a map would be huge, summarize its shape and point to
  the densest areas rather than listing everything.
"""

#: Tools scout may use — read-only, mirroring the frontmatter original. Passed as a
#: JSON array (verified against the installed CLI, 2.1.273: an array `tools` value
#: is accepted and the sub-agent is registered read-only; see backlog/workflow-roles.md).
SCOUT_TOOLS = ["Read", "Grep", "Glob"]

SCOUT_DESCRIPTION = (
    'Read-only codebase mapper and locator. Use it for ANY broad survey or '
    'fan-out sweep across many files (map the pages, inventory the components, '
    'list every call site of X, audit where routes or config live) as well as '
    'pinpoint "where is X" lookups. Runs on a cheap model and returns a compact '
    'map of path:line locations with one-line notes, never file bodies, so the '
    'driver session stays lean.'
)


def scout_agent_json(role: RoleConfig) -> dict:
    """The ``--agents`` JSON haro injects for its own scout sub-agent, keyed by
    the CLI's per-agent frontmatter contract (``description``/``prompt``/``tools``/
    ``model``). ``role.model`` is the project's configured ``[roles] scout``
    model (Haiku by default) — never the caller's own model, so a Sonnet/Opus
    build run doesn't accidentally pay Sonnet/Opus rates for mapping sweeps."""
    return {
        "scout": {
            "description": SCOUT_DESCRIPTION,
            "prompt": SCOUT_PROMPT,
            "tools": SCOUT_TOOLS,
            "model": role.model,
        }
    }


def scout_instructions() -> str:
    """One paragraph appended to the Tier-1 custom instructions (alongside the
    project's own ``.haro/instructions.md``) telling the agent a `scout`
    sub-agent exists and when to reach for it — the ``--agents`` JSON only
    REGISTERS the sub-agent; it doesn't tell the driving agent to prefer it over
    reading files itself."""
    return (
        "You have a `scout` sub-agent available (read-only: Read/Grep/Glob). "
        "Delegate every broad mapping or \"where is X\" lookup to it — locating "
        "a symbol, surveying many files, inventorying components or routes — "
        "instead of reading whole files yourself to find or map something. "
        "Reserve your own reads for files you already know you need to edit."
    )
