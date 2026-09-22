"""GitHub Issues as a live backlog source.

The committed ``todo-*.md`` files are one backlog input; a project's own GitHub
issues assigned to the current user are a second. This module reads them live via
the user's authenticated ``gh`` CLI (same local-first, no-OAuth stance as
git_panel.py) and never persists issue content: GitHub is the source of truth,
haro reads and links. The only durable state is the issue→workspace link, which
``seed_key = "issue:<number>"`` already stores at workspace-creation time.

``gh issue list`` runs in the repo's cwd, so it scopes to *this* project's
``origin`` for free. ``state``/``assignee``/``limit`` are caller-supplied
(``[backlog] issue_state``/``issue_assignee``/``issue_limit``, overridable
per-request by the UI's state tabs and mine/all toggle) rather than the old
hard-coded ``--assignee @me --state all --limit 50``: solo devs rarely
self-assign, so defaulting to ``@me`` made the tab empty for most repos, and
fetching every state under one shared limit let closed issues silently push
open ones out of a truncated result.

A short-lived in-process cache, keyed by the exact query (state/assignee/limit),
bounds how often we shell out to ``gh`` (the backlog refetches on every
status/gate event) and doubles as a *display* cache: if a later fetch fails
(offline, rate-limited) we serve the last good result for that same query
stamped ``fetched_at`` so the tab degrades to "as of HH:MM" rather than going
blank. The cache is a view convenience, never a source of truth.

Reads are unconditional; the one *write* this module makes is
``write_back_on_pickup`` — an opt-in, best-effort GitHub announcement (self-assign
+ ``in-progress`` label + a comment) fired when an issue seeds a workspace, gated
by ``[backlog] issue_writeback`` because writing to GitHub is a visible side effect.
"""

from __future__ import annotations

import asyncio
import json as _json
import time

from . import git_ops

_TTL = 20.0  # seconds a cached fetch is served without re-shelling to gh

# (project_path, state, assignee, limit) -> (fetched_epoch, issues) — last
# *successful* fetch for that exact query only. Keyed by the full query because
# switching state/assignee mid-session must not serve another query's cache.
_cache: dict[tuple[str, str, str, int], tuple[float, list[dict]]] = {}


async def _gh(*args: str, cwd: str) -> tuple[int, str, str]:
    """Run the user's ``gh`` CLI. Returns (code, stdout, stderr); 127 if absent."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "gh", *args, cwd=cwd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        return 127, "", "`gh` CLI not found"
    out, err = await proc.communicate()
    return proc.returncode or 0, out.decode().strip(), err.decode().strip()


def _normalize(raw: list[dict]) -> list[dict]:
    """Flatten ``gh``'s issue JSON to the shape the backlog UI consumes and sort
    open-first, each group most-recent (highest number) first."""
    issues: list[dict] = []
    for it in raw:
        issues.append({
            "number": it.get("number"),
            "title": (it.get("title") or "").strip(),
            "body": (it.get("body") or "").strip(),
            "state": (it.get("state") or "").lower(),  # "open" | "closed"
            "labels": [l.get("name", "") for l in (it.get("labels") or []) if l.get("name")],
            "url": it.get("url") or "",
        })
    issues.sort(key=lambda i: (i["state"] != "open", -(i["number"] or 0)))
    return issues


def _stamp(
    fetched_epoch: float, issues: list[dict], *, stale: bool, limit: int, reason: str | None = None
) -> dict:
    return {
        "available": True,
        "stale": stale,
        "fetched_at": _iso(fetched_epoch),
        "reason": reason,
        "issues": issues,
        # A same-size result at the configured limit likely isn't the full set —
        # surfaced instead of pretending the fetch is exhaustive (see module docstring).
        "truncated": len(issues) >= limit,
    }


def _iso(epoch: float) -> str:
    # UTC ISO-8601 with a trailing Z; the frontend renders the local HH:MM.
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


_PICKUP_LABEL = "in-progress"
_PICKUP_COMMENT = "Picked up in haro."


async def write_back_on_pickup(project_path: str, number: int) -> None:
    """Announce, on GitHub, that issue ``number`` was just picked up in haro.

    Best-effort courtesy so a teammate scanning the tracker doesn't grab the same
    issue: self-assign + add an ``in-progress`` label + drop a "Picked up in haro"
    comment. Every step is independent and failure-swallowing — the local pickup
    (the workspace) already succeeded, so a missing ``gh``, a repo without the label,
    or an offline machine must never surface as an error here. Only the caller's
    config gate (``[backlog] issue_writeback``) decides *whether* to run this; the
    method never persists anything, matching the read path's "GitHub is truth" stance.

    Invalidates the display cache so the next ``list_issues`` re-fetches and the row
    reflects the fresh label/assignee instead of a pre-pickup snapshot.
    """
    n = str(number)
    # `gh issue edit` applies the label + assignee in one call; a repo missing the
    # label makes gh exit non-zero, which we ignore (the comment still lands).
    await _gh(
        "issue", "edit", n, "--add-assignee", "@me", "--add-label", _PICKUP_LABEL,
        cwd=project_path,
    )
    await _gh("issue", "comment", n, "--body", _PICKUP_COMMENT, cwd=project_path)
    # Every cached query for this project is now potentially stale (the picked-up
    # issue's label/assignee changed regardless of which state/assignee it was
    # fetched under), so drop them all rather than guess which key it lived in.
    for key in [k for k in _cache if k[0] == project_path]:
        _cache.pop(key, None)


async def list_issues(
    project_path: str,
    *,
    force: bool = False,
    state: str = "open",
    assignee: str = "",
    limit: int = 100,
) -> dict:
    """Issues for the project at ``project_path``, matching ``state``/``assignee``.

    ``state`` is one of "open"/"closed"/"all"; ``assignee`` is a login, "@me", or
    "" for anyone. Returns one of:
      - ``{available: False, reason}`` — no remote / no ``gh`` (empty-state tab).
      - ``{available: True, stale, fetched_at, issues, truncated}`` — live or
        cached fetch; ``stale`` marks a display-cache fallback after a failed
        refresh, ``truncated`` marks a result that hit ``limit``.
    ``force`` bypasses the TTL (the ⟳ button) but still honors the display cache
    on failure."""
    now = time.time()
    cache_key = (project_path, state, assignee, limit)
    cached = _cache.get(cache_key)
    if not force and cached and now - cached[0] < _TTL:
        return _stamp(cached[0], cached[1], stale=False, limit=limit)

    if not await git_ops.has_remote(project_path):
        return {"available": False, "reason": "no-remote", "issues": []}

    args = ["issue", "list", "--state", state, "--limit", str(limit),
            "--json", "number,title,body,state,labels,url"]
    if assignee:
        args += ["--assignee", assignee]
    code, out, err = await _gh(*args, cwd=project_path)
    if code == 0:
        try:
            issues = _normalize(_json.loads(out or "[]"))
        except _json.JSONDecodeError:
            issues = []
        _cache[cache_key] = (now, issues)
        return _stamp(now, issues, stale=False, limit=limit)

    # gh missing → hard empty state, same as the PR chip's "install gh" degrade.
    if code == 127:
        return {"available": False, "reason": "no-gh", "issues": []}

    # Any other failure (offline, rate-limited, auth): serve the last good fetch as
    # a stamped display cache if we have one; otherwise report unavailable.
    if cached:
        return _stamp(cached[0], cached[1], stale=True, limit=limit, reason=(err or out) or None)
    return {"available": False, "reason": (err or out) or "fetch failed", "issues": []}
