"""The weekly review: what to look at, computed from facts and never guessed.

Inputs are the backlog as ``GET /todo`` returns it, the notes (with their links), and when each
backlog file last changed in git. Nothing is scored by a model: a todo is stale when its file has
not been touched for ``STALE_DAYS`` and it is still open; a note is unlinked when no note links to
it and it links to none; one old note is resurfaced per day, chosen by the date so it does not
change on every open.
"""

from __future__ import annotations

import hashlib
from datetime import date

STALE_DAYS = 14
OLD_NOTE_DAYS = 30
LIMIT = 30


def stale_todos(files: list[dict], last_change: dict[str, float], now: float) -> list[dict]:
    out = []
    for f in files:
        ts = last_change.get(f["path"])
        if ts is None:
            continue
        days = int((now - ts) // 86400)
        if days < STALE_DAYS:
            continue
        for i, it in enumerate(f["items"]):
            if it["done"] or it.get("archived") or it.get("snoozed"):
                continue
            out.append({
                "file": f["path"], "index": i, "text": it["text"], "id": it.get("id"),
                "days": days, "stage": it.get("stage"),
            })
    out.sort(key=lambda r: -r["days"])
    return out[:LIMIT]


def without_workspace(files: list[dict]) -> list[dict]:
    """Open, startable items nobody has started: the stage is ``ready`` and nothing blocks them."""
    out = []
    for f in files:
        for i, it in enumerate(f["items"]):
            if it["done"] or it.get("archived") or it.get("snoozed") or it.get("blocked"):
                continue
            if it.get("stage") == "ready" and not it.get("seeded_workspace"):
                out.append({"file": f["path"], "index": i, "text": it["text"], "id": it.get("id")})
    return out[:LIMIT]


def unlinked_notes(notes: list[dict]) -> list[dict]:
    """Notes that link nowhere and that nothing links to. ``notes``: path, title, outgoing (list of
    resolved target paths) from the caller's scan."""
    linked_to = {p for n in notes for p in n["outgoing"]}
    out = [
        {"path": n["path"], "title": n["title"]}
        for n in notes
        if not n["outgoing"] and n["path"] not in linked_to
    ]
    return out[:LIMIT]


def resurface(notes: list[dict], now: float, today: date) -> dict | None:
    """One note untouched for ``OLD_NOTE_DAYS``, picked by the date: the same one all day."""
    old = sorted(
        (n for n in notes if (now - n["mtime"]) >= OLD_NOTE_DAYS * 86400), key=lambda n: n["path"]
    )
    if not old:
        return None
    pick = old[int(hashlib.sha1(today.isoformat().encode()).hexdigest(), 16) % len(old)]
    return {"path": pick["path"], "title": pick["title"], "days": int((now - pick["mtime"]) // 86400)}
