"""One search over a project's todos, notes and issues, with operators.

``stage:red tag:ui -is:done fix cart`` means: items in the red stage, tagged ui, not done, whose
title or text contain both ``fix`` and ``cart``. Words are AND-ed, case-insensitive substrings;
``-word`` and ``-key:value`` exclude; ``"two words"`` is one term. Operators:

* ``tag:`` a tag (``tag:perf`` also matches ``perf/db``)
* ``stage:`` ready, queued, running, red, green, shipped (todos and issues that have a workspace)
* ``in:`` todos, notes, issues, files (PDFs and other files beside the notes)
* ``path:`` (or ``file:``) part of the file path
* ``is:`` done, open, pinned, ready, blocked, snoozed, archived

Archived todos are left out unless ``is:archived`` is asked for. Candidates are plain dicts built
by the caller (see ``todo_candidates`` and friends); this module has no I/O of its own.
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass, field

_KEYS = {"tag", "stage", "in", "path", "file", "is"}
_KIND = {
    "todo": "todo", "todos": "todo", "note": "note", "notes": "note", "issue": "issue", "issues": "issue",
    "file": "file", "files": "file", "pdf": "file", "pdfs": "file",
}


@dataclass
class Query:
    terms: list[str] = field(default_factory=list)
    neg_terms: list[str] = field(default_factory=list)
    flt: list[tuple[str, str]] = field(default_factory=list)
    neg_flt: list[tuple[str, str]] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not (self.terms or self.neg_terms or self.flt or self.neg_flt)

    def wants(self, key: str, value: str) -> bool:
        return (key, value) in self.flt


def parse_query(q: str) -> Query:
    try:
        tokens = shlex.split(q)
    except ValueError:  # an unbalanced quote: fall back to plain words
        tokens = q.split()
    out = Query()
    for tok in tokens:
        neg = tok.startswith("-") and len(tok) > 1
        body = tok[1:] if neg else tok
        key, sep, value = body.partition(":")
        if sep and key.lower() in _KEYS and value:
            pair = (key.lower(), value.lower().lstrip("#"))
            (out.neg_flt if neg else out.flt).append(pair)
        elif body:
            (out.neg_terms if neg else out.terms).append(body.lower())
    return out


def _tag_match(tags: list[str], want: str) -> bool:
    return any(t == want or t.startswith(want + "/") for t in tags)


def _filter_ok(c: dict, key: str, value: str) -> bool:
    if key == "tag":
        return _tag_match(c.get("tags", []), value)
    if key == "stage":
        return c.get("stage") == value
    if key == "in":
        return c["kind"] == _KIND.get(value, value)
    if key in ("path", "file"):
        return value in c.get("path", "").lower()
    if key == "is":
        done = bool(c.get("done"))
        return {
            "done": done,
            "closed": done,
            "open": not done,
            "pinned": bool(c.get("pinned")),
            "blocked": bool(c.get("blocked")),
            "ready": c["kind"] == "todo" and not done and not c.get("blocked") and not c.get("snoozed")
            and not c.get("archived") and c.get("stage") in (None, "ready"),
            "snoozed": bool(c.get("snoozed")),
            "archived": bool(c.get("archived")),
        }.get(value, False)
    return True


def _haystack(c: dict) -> str:
    return f"{c.get('title', '')}\n{c.get('text', '')}\n{c.get('path', '')}\n{' '.join(c.get('tags', []))}".lower()


def matches(c: dict, q: Query) -> bool:
    if c.get("archived") and not q.wants("is", "archived"):
        return False
    if not all(_filter_ok(c, k, v) for k, v in q.flt):
        return False
    if any(_filter_ok(c, k, v) for k, v in q.neg_flt):
        return False
    hay = _haystack(c)
    return all(t in hay for t in q.terms) and not any(t in hay for t in q.neg_terms)


def _score(c: dict, q: Query) -> float:
    title = c.get("title", "").lower()
    score = 0.0
    for t in q.terms:
        if title.startswith(t):
            score += 3
        elif t in title:
            score += 2
        else:
            score += 1
    if c.get("pinned"):
        score += 1.5
    if c.get("done"):
        score -= 1
    score += {"todo": 0.3, "note": 0.2, "file": 0.15, "issue": 0.1}.get(c["kind"], 0)
    return score


def search(cands: list[dict], q: Query, limit: int = 40) -> list[dict]:
    """The candidates that match, best first. With no query at all: pinned todos, then the
    newest notes, then the rest (what a quick switcher shows before you type)."""
    hits = [c for c in cands if matches(c, q)]
    if q.empty:
        hits.sort(key=lambda c: (
            0 if c.get("pinned") else 1 if c["kind"] == "note" else 2,
            -c.get("mtime", 0.0),
        ))
    else:
        hits.sort(key=lambda c: (-_score(c, q), -c.get("mtime", 0.0)))
    return hits[:limit]


# ---- candidates -----------------------------------------------------------------------------

def todo_candidates(files: list[dict]) -> list[dict]:
    """Flatten ``GET /todo`` files into candidates."""
    out = []
    for f in files:
        for i, it in enumerate(f["items"]):
            out.append({
                "kind": "todo", "title": it["text"], "text": it.get("body", ""), "path": f["path"],
                "file": f["path"], "index": i, "id": it.get("id"), "tags": it.get("tags", []),
                "stage": it.get("stage"), "done": it["done"], "pinned": it.get("pinned", False),
                "blocked": it.get("blocked", False), "snoozed": it.get("snoozed", False),
                "archived": it.get("archived", False), "snippet": it.get("heading", ""),
                "mtime": 0.0,
            })
    return out


def note_candidates(notes: list[dict]) -> list[dict]:
    """Notes as candidates; each dict has path, title, text, tags, mtime."""
    return [{
        "kind": "note", "title": n["title"], "text": n["text"][:20000], "path": n["path"],
        "tags": n["tags"], "done": False, "mtime": n["mtime"], "snippet": "",
    } for n in notes]


def file_candidates(files: list[dict]) -> list[dict]:
    """Files beside the notes (``note_files.searchable``): found by name, and for a PDF or a text file
    by what is inside."""
    return [{
        "kind": "file", "title": f["name"], "text": f["text"], "path": f["path"], "tags": [],
        "done": False, "mtime": f["mtime"], "snippet": f["kind"], "file_kind": f["kind"],
    } for f in files]


def issue_candidates(issues: list[dict]) -> list[dict]:
    return [{
        "kind": "issue", "title": f"#{i['number']} {i['title']}", "text": "", "path": f"issue #{i['number']}",
        "number": i["number"], "tags": [str(x).lower() for x in i.get("labels", [])],
        "stage": i.get("stage") if i.get("seeded_workspace") else None,
        "done": str(i.get("state", "")).lower() == "closed", "mtime": 0.0, "snippet": i.get("state", ""),
    } for i in issues]


def result_row(c: dict, text_query: list[str]) -> dict:
    """What the client gets for one hit."""
    snippet = c.get("snippet", "")
    if c["kind"] in ("note", "file") and text_query:
        for line in c.get("text", "").splitlines():
            if any(t in line.lower() for t in text_query):
                snippet = re.sub(r"\s+", " ", line.strip())[:160]
                break
    return {
        "kind": c["kind"], "title": c["title"], "subtitle": c.get("path", ""), "snippet": snippet,
        "tags": c.get("tags", []), "stage": c.get("stage"), "done": bool(c.get("done")),
        "pinned": bool(c.get("pinned")), "id": c.get("id"), "path": c.get("path", ""),
        "file": c.get("file"), "index": c.get("index"), "number": c.get("number"),
        "file_kind": c.get("file_kind"),
    }
