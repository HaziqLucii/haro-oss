"""On-demand detail for a single GitHub issue: body + comments + labels.

The issues backlog tab (issues.py) lists a project's assigned issues shallowly —
enough to seed a workspace. This module fetches the *full* detail for ONE issue
on demand, so a dev can expand a row and read the body + discussion without
leaving haro (or opening the browser).

Kept as its own module — not folded into issues.py — deliberately: the two
concerns have disjoint file ownership so the "issue detail" and "write-back on
pickup" follow-ups can land as parallel worktrees without colliding at merge
(there's no conflict-aware merge yet — roadmap v3).

Same discipline as issues.py / git_panel.py: read live via the user's
authenticated ``gh`` CLI (local-first, no OAuth), and never persist the content.
GitHub is the source of truth; haro reads and links. Unlike the list, the detail
isn't cached — it's fetched only when a row is expanded, so a fresh ``gh issue
view`` per expand keeps the body/comments live without a poller.
"""

from __future__ import annotations

import asyncio
import json as _json

from . import git_ops


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


def _normalize(raw: dict) -> dict:
    """Flatten ``gh issue view``'s JSON to the shape the detail panel consumes."""
    return {
        "available": True,
        "number": raw.get("number"),
        "title": (raw.get("title") or "").strip(),
        "body": (raw.get("body") or "").strip(),
        "state": (raw.get("state") or "").lower(),  # "open" | "closed"
        "url": raw.get("url") or "",
        "labels": [l.get("name", "") for l in (raw.get("labels") or []) if l.get("name")],
        "comments": [
            {
                # gh nests the author under an object; flatten to the login handle.
                "author": (c.get("author") or {}).get("login", ""),
                "body": (c.get("body") or "").strip(),
                "created_at": c.get("createdAt") or "",
            }
            for c in (raw.get("comments") or [])
        ],
    }


async def view_issue(project_path: str, number: int) -> dict:
    """Full detail for issue ``number`` in the repo at ``project_path``.

    Returns one of:
      - ``{available: False, reason}`` — no remote / no ``gh`` / fetch failed
        (the panel shows the reason inline, same tone as the list's empty state).
      - ``{available: True, number, title, body, state, url, labels, comments}``.
    Read-only and never persisted — GitHub stays the source of truth."""
    if not await git_ops.has_remote(project_path):
        return {"available": False, "reason": "no-remote"}

    code, out, err = await _gh(
        "issue", "view", str(number),
        "--json", "number,title,body,state,labels,comments,url",
        cwd=project_path,
    )
    if code == 127:
        return {"available": False, "reason": "no-gh"}
    if code != 0:
        return {"available": False, "reason": (err or out) or "fetch failed"}
    try:
        raw = _json.loads(out or "{}")
    except _json.JSONDecodeError:
        return {"available": False, "reason": "malformed response from gh"}
    return _normalize(raw)
