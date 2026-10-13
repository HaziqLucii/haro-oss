"""Wikilinks, tags and backlinks between notes, read from the markdown on demand.

Nothing is stored: the links live in the notes themselves (``[[a note]]``, ``[[folder/a note]]``,
``[[a note#heading|shown text]]``, ``#a-tag``), in the same syntax Obsidian reads, so the folder
opens there unchanged. Code (fenced blocks and inline spans) is never scanned, so a ``[[x]]`` in
an example is not a link. What is derived, per open note: where each of its links points, which
notes link to it (backlinks) and which mention its title without linking (mentions).

A target resolves, in order, as a path (``folder/name`` with or without ``.md``), a file name
(``name``; the first by path when several notes share one, flagged ambiguous) and a title (the
note's first heading). Renaming a note rewrites the links that named it by path or file name, in
the other notes, keeping their ``#heading`` and ``|alias``; links by title still resolve and are
left alone.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from . import notes

MAX_SCANNED = 2000  # notes a scan will open
TODO_PREFIX = "todo:"  # `[[todo:ab12cd the item's text]]` links to a backlog item by its id
SNIPPET = 160

_WIKI = re.compile(r"\[\[([^\[\]\n|#]+?)(?:#([^\[\]\n|]*))?(?:\|([^\[\]\n]*))?\]\]")
# A tag starts with a letter (`#123` is an issue, `# Title` a heading) and is not part of a word,
# a URL fragment, a markdown anchor or a path. Unicode-aware, like the client's copy of this rule.
_TAG = re.compile(r"(?<![\w/&#\[(=])#([^\W\d_][\w/-]*)")


@dataclass(frozen=True)
class Link:
    target: str
    anchor: str | None
    alias: str | None
    start: int
    end: int


def _mask_inline(line: str) -> str:
    """The line with inline code spans blanked. A linear scan: a backtick run opens a span that
    the next run of the SAME length closes (a regex for this backtracks badly on long runs of
    backticks, and this runs on every note)."""
    out = list(line)
    i, n = 0, len(line)
    while i < n:
        if line[i] != "`":
            i += 1
            continue
        j = i
        while j < n and line[j] == "`":
            j += 1
        run = j - i
        k = j
        close = -1
        while True:
            k = line.find("`", k)
            if k == -1:
                break
            e = k
            while e < n and line[e] == "`":
                e += 1
            if e - k == run:
                close = e
                break
            k = e
        if close == -1:
            i = j
            continue
        for x in range(i, close):
            out[x] = " "
        i = close
    return "".join(out)


def _fence_open(line: str) -> tuple[str, int] | None:
    """(marker char, length) when the line opens a fenced block: up to three spaces of indent,
    then at least three backticks (with no backtick after them) or tildes."""
    stripped = line.lstrip(" ")
    if len(line) - len(stripped) > 3:
        return None
    for ch in ("`", "~"):
        if stripped.startswith(ch * 3):
            run = len(stripped) - len(stripped.lstrip(ch))
            if ch == "`" and "`" in stripped[run:]:
                return None
            return ch, run
    return None


def mask_code(text: str) -> str:
    """The text with fenced blocks and inline code replaced by spaces of the same length, so
    offsets into it are offsets into the original. Only ``\\n`` ends a line, matching the client."""
    out: list[str] = []
    fence: tuple[str, int] | None = None
    for line in text.split("\n"):
        if fence is not None:
            out.append(" " * len(line))
            body = line.strip(" ")
            if body and set(body) == {fence[0]} and len(body) >= fence[1] and len(line) - len(line.lstrip(" ")) <= 3:
                fence = None
            continue
        opening = _fence_open(line)
        if opening is not None:
            fence = opening
            out.append(" " * len(line))
        else:
            out.append(_mask_inline(line))
    return "\n".join(out)


def _parse_masked(masked: str) -> tuple[list[Link], list[str]]:
    links = [
        Link(m.group(1).strip(), m.group(2), m.group(3), m.start(), m.end())
        for m in _WIKI.finditer(masked)
        if m.group(1).strip()
    ]
    tags: list[str] = []
    for m in _TAG.finditer(masked):
        if m.group(1) not in tags:
            tags.append(m.group(1))
    return links, tags


def parse(text: str) -> tuple[list[Link], list[str]]:
    """The wikilinks and the tags (unique, in order) of one note, outside code."""
    return _parse_masked(mask_code(text))


class Index:
    """What a target can name, built from every note's path and title."""

    def __init__(self, entries: dict[str, str]):
        self.entries = entries  # path -> title
        self.by_path = {p[:-3].lower(): p for p in entries}
        self.by_stem: dict[str, list[str]] = {}
        self.by_title: dict[str, list[str]] = {}
        for p in sorted(entries):
            self.by_stem.setdefault(Path(p).stem.lower(), []).append(p)
            self.by_title.setdefault(entries[p].lower(), []).append(p)

    def resolve(self, target: str) -> tuple[str | None, str, bool]:
        """(path or None, how it matched: path|stem|title|none, ambiguous)."""
        t = target.strip().lower()
        if t.startswith(TODO_PREFIX):  # a link to a backlog item, not a note
            return None, "todo", False
        if t.endswith(".md"):
            t = t[:-3]
        if t in self.by_path:
            return self.by_path[t], "path", False
        if "/" in t:
            tails = sorted(p for k, p in self.by_path.items() if k.endswith("/" + t))
            if tails:
                return tails[0], "path", len(tails) > 1
        hits = self.by_stem.get(t)
        if hits:
            return hits[0], "stem", len(hits) > 1
        hits = self.by_title.get(t)
        if hits:
            return hits[0], "title", len(hits) > 1
        return None, "none", False


@dataclass
class _Note:
    path: str
    title: str
    text: str
    links: list[Link]
    tags: list[str]
    etag: str
    masked: str
    exact: bool  # decoded as UTF-8 without loss: safe to write back


def _scan(project_path: str) -> list[_Note]:
    root = notes.notes_root(project_path)
    found: list[_Note] = []
    for p in notes._files(project_path)[:MAX_SCANNED]:
        try:
            data = p.read_bytes()
        except OSError:
            continue
        if len(data) > notes.MAX_BYTES:
            continue
        try:
            text, exact = data.decode("utf-8"), True
        except UnicodeDecodeError:
            text, exact = data.decode("utf-8", errors="replace"), False
        rel = p.relative_to(root).as_posix()
        masked = mask_code(text)
        links, tags = _parse_masked(masked)
        found.append(
            _Note(rel, notes._title(text, p.stem.replace("-", " ").replace("_", " ")), text,
                  links, tags, notes.etag_of(data), masked, exact)
        )
    return found


def _line_at(text: str, pos: int) -> str:
    start = text.rfind("\n", 0, pos) + 1
    end = text.find("\n", pos)
    return text[start : end if end != -1 else len(text)].strip()[:SNIPPET]


def _file_of(project_path: str, target: str) -> str | None:
    """The path (relative to the notes folder) of the file a link names, when it names one."""
    from . import note_files

    base = target.split("#", 1)[0].strip()
    if note_files._ext(base) not in note_files.OPENABLE:
        return None
    try:
        return note_files.resolve(project_path, base).relative_to(notes.notes_root(project_path).resolve()).as_posix()
    except (notes.NoteError, ValueError):
        return None


def links_for(project_path: str, rel: str) -> dict:
    """Outgoing links, backlinks, unlinked mentions and tags of one note. Blocking."""
    rel = notes._safe_rel(rel)
    scanned = _scan(project_path)
    me = next((n for n in scanned if n.path == rel), None)
    if me is None:
        raise notes.NoteError(f"{rel} does not exist")
    index = Index({n.path: n.title for n in scanned})

    outgoing = []
    for link in me.links:
        path, how, ambiguous = index.resolve(link.target)
        row = {
            "target": link.target, "anchor": link.anchor, "alias": link.alias, "path": path,
            "title": index.entries.get(path) if path else None, "ambiguous": ambiguous,
        }
        tid = todo_id_of(link.target)
        if tid is not None:
            row["todo"] = todo_ref(project_path, tid)
        if path is None and tid is None:
            # `[[report.pdf]]` or `![[diagram.png]]`: a file beside the notes, not a note to create
            row["file"] = _file_of(project_path, link.target)
        outgoing.append(row)

    backlinks, linked_from = [], set()
    for n in scanned:
        if n.path == rel:
            continue
        for link in n.links:
            path, _how, _amb = index.resolve(link.target)
            if path == rel:
                backlinks.append({
                    "path": n.path, "title": n.title, "snippet": _line_at(n.text, link.start),
                })
                linked_from.add(n.path)
                break

    names = {me.title.lower(), Path(rel).stem.replace("-", " ").replace("_", " ").lower()}
    names = {n for n in names if len(n) >= 3}
    mentions = []
    if names:
        pattern = re.compile(
            r"(?<![\w])(?:" + "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
            + r")(?![\w])", re.I,
        )
        for n in scanned:
            if n.path == rel or n.path in linked_from:
                continue
            m = pattern.search(n.masked)
            if m:
                mentions.append({
                    "path": n.path, "title": n.title, "snippet": _line_at(n.text, m.start()),
                })
    return {"path": rel, "tags": me.tags, "outgoing": outgoing, "backlinks": backlinks,
            "mentions": mentions}


def plan_rename(project_path: str, old: str, new: str) -> list[tuple[str, str, str]]:
    """The edits a rename needs: ``(path, new text, etag it was read at)``. Computed against the
    notes as they are BEFORE the rename, with the index as it will be AFTER. A link is rewritten
    when it named ``old`` by path or file name (it now names the new name), and also when the
    rename would make it resolve to a different note than it did (a new `plan.md` beating an
    existing `sub/plan.md` for ``[[plan]]``): that one is pinned to its note's path. The renamed
    note's own links are included, under its new path. A note that did not decode as UTF-8 is
    never rewritten. A case-only rename changes nothing (links resolve case-insensitively).
    Blocking."""
    old, new = notes._safe_rel(old), notes._safe_rel(new)
    if old.lower() == new.lower():
        return []
    scanned = _scan(project_path)
    before = Index({n.path: n.title for n in scanned})
    after_entries = {p: t for p, t in before.entries.items() if p != old}
    after_entries[new] = before.entries.get(old, "")
    after = Index(after_entries)
    stem = Path(new).stem
    unique = len(after.by_stem.get(stem.lower(), [])) == 1
    renamed_to = stem if unique else new[:-3]
    plan: list[tuple[str, str, str]] = []
    for n in scanned:
        if not n.exact:
            continue
        edits = []
        for link in n.links:
            bp, how, _amb = before.resolve(link.target)
            if bp is None:
                continue
            ap, _how2, _amb2 = after.resolve(link.target)
            if bp == old:
                if how in ("path", "stem"):
                    target = renamed_to
                elif ap != new:
                    target = new[:-3]  # a title link another note's name now beats
                else:
                    continue
            elif ap != bp:
                target = bp[:-3]  # hijacked by the new name: pin it to the note it meant
            else:
                continue
            inner = target
            if link.anchor is not None:
                inner += "#" + link.anchor
            if link.alias is not None:
                inner += "|" + link.alias
            edits.append((link.start, link.end, "[[" + inner + "]]"))
        if edits:
            text = n.text
            for start, end, repl in sorted(edits, reverse=True):
                text = text[:start] + repl + text[end:]
            if text != n.text:
                plan.append((new if n.path == old else n.path, text, n.etag))
    return plan


def apply_plan(project_path: str, plan: list[tuple[str, str, str]]) -> tuple[list[str], list[str]]:
    """Write a rename plan: ``(written, skipped)``. A note that changed since it was planned is
    skipped and left as it is."""
    done, skipped = [], []
    for rel, text, etag in plan:
        try:
            notes.write_note(project_path, rel, text, etag)
            done.append(rel)
        except notes.NoteError:
            skipped.append(rel)
    return done, skipped


# ---- links to backlog items ---------------------------------------------------------------

_TODO_ID = re.compile(r"^todo:([a-z0-9]{4,12})(?:\s|$)", re.I)


def todo_id_of(target: str) -> str | None:
    """The item id in a ``[[todo:ab12cd text]]`` target, else None."""
    m = _TODO_ID.match(target.strip())
    return m.group(1).lower() if m else None


def todo_ref(project_path: str, item_id: str) -> dict | None:
    """The backlog item an id names now (its text, file and whether it is done), or None when no
    entry has the id or the item can no longer be found (lost). Blocking."""
    from . import backlog, backlog_meta

    entry = next((e for e in backlog_meta.load(project_path) if e.id == item_id), None)
    if entry is None:
        return None
    root = Path(project_path).resolve()
    target = (root / entry.path).resolve()
    if root not in target.parents:
        return None
    try:
        text = target.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    items = backlog.parse_todo(text)
    hit = next((it for it in items if it["text"] == entry.text), None) or next(
        (it for it in items if backlog_meta.norm(it["text"]) == backlog_meta.norm(entry.text)), None
    )
    if hit is None:
        return None
    return {"id": item_id, "text": hit["text"], "path": entry.path, "done": bool(hit["done"])}


def notes_linking_todo(project_path: str, item_id: str) -> list[dict]:
    """The notes that link to a backlog item, with the line each does it on. Blocking."""
    out = []
    for n in _scan(project_path):
        for link in n.links:
            if todo_id_of(link.target) == item_id:
                out.append({"path": n.path, "title": n.title, "snippet": _line_at(n.text, link.start)})
                break
    return out
