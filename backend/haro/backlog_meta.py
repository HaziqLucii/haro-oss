"""Metadata for backlog items, kept beside the project's files, never inside them.

The project's own backlog files (``backlog/*.md``, ``TODO.md``) stay exactly as the project writes
them: haro adds no markers to them. What haro knows about an item (a short id, tags, what it
depends on, pinned, snoozed, archived) lives in ``.haro/todos/meta.jsonl``, one JSON object per
line sorted by id (so two branches editing different items rarely conflict in git).

An entry is created lazily, the first time an item is tagged, pinned, linked from a note or
otherwise given something to remember. To find the item again after the file was edited (by hand,
by an agent, by the merge tick) an entry keeps the item's text, its neighbours' text and its file,
and is re-matched in this order: exact text in the same file, the same text normalised, the same
normalised text in another file (a move), then the same two neighbours. An item that matches none
of these is reported as ``lost`` instead of being guessed. Limit: rewording an item and moving it
in the same edit outside haro loses the match.
"""

from __future__ import annotations

import json
import os
import re
import secrets
from dataclasses import asdict, dataclass, field
from datetime import date
from pathlib import Path

META_DIR = ".haro/todos"
LEGACY_META_DIR = ".haro/backlog"  # where an earlier build kept it: read from there, then moved
META_FILE = "meta.jsonl"
VIEWS_FILE = "views.json"
_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
ID_LEN = 6
MAX_TAGS = 20
MAX_VIEWS = 50

_TAG = re.compile(r"^[^\W\d_][\w/-]*$")
_ID = re.compile(r"^[a-z0-9]{4,12}$")


class MetaError(ValueError):
    """A request about item metadata that cannot be honoured."""


@dataclass
class Entry:
    id: str
    path: str
    text: str
    prev: str = ""
    next: str = ""
    tags: list[str] = field(default_factory=list)
    depends: list[str] = field(default_factory=list)
    pinned: bool = False
    snooze: str = ""  # YYYY-MM-DD: hidden from ready lists until that day
    archived: bool = False
    seen: str = ""  # YYYY-MM-DD the entry was created


def norm(text: str) -> str:
    """Comparison form of an item's text: lower case, spaces folded, edge punctuation dropped."""
    return re.sub(r"\s+", " ", text.strip().lower()).strip(" .,:;!-")


def clean_tag(tag: str) -> str:
    t = tag.strip().lstrip("#").lower()
    if not _TAG.match(t) or len(t) > 40:
        raise MetaError(f"not a tag: {tag!r}")
    return t


def meta_dir(project_path: str) -> Path:
    return Path(project_path) / META_DIR


def _read(project_path: str, name: str) -> str | None:
    """A metadata file from ``.haro/todos/``, or from the folder an earlier version used."""
    for folder in (META_DIR, LEGACY_META_DIR):
        try:
            return (Path(project_path) / folder / name).read_text(encoding="utf-8")
        except OSError:
            continue
    return None


def _drop_legacy(project_path: str, name: str) -> None:
    old = Path(project_path) / LEGACY_META_DIR
    try:
        (old / name).unlink(missing_ok=True)
        old.rmdir()  # only when nothing else is in it
    except OSError:
        pass


def load(project_path: str) -> list[Entry]:
    raw = _read(project_path, META_FILE)
    if raw is None:
        return []
    out: list[Entry] = []
    seen: set[str] = set()
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            if not isinstance(d, dict) or not _ID.match(str(d.get("id", ""))) or d["id"] in seen:
                continue
            e = Entry(
                id=d["id"], path=str(d.get("path", "")), text=str(d.get("text", "")),
                prev=str(d.get("prev", "")), next=str(d.get("next", "")),
                tags=[str(t) for t in d.get("tags", []) if isinstance(t, str)][:MAX_TAGS],
                depends=[str(t) for t in d.get("depends", []) if isinstance(t, str)],
                pinned=bool(d.get("pinned", False)), snooze=str(d.get("snooze", "")),
                archived=bool(d.get("archived", False)), seen=str(d.get("seen", "")),
            )
        except (ValueError, TypeError):
            continue
        seen.add(e.id)
        out.append(e)
    return out


def save(project_path: str, entries: list[Entry]) -> None:
    folder = meta_dir(project_path)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / META_FILE
    body = "".join(
        json.dumps(asdict(e), sort_keys=True, ensure_ascii=False) + "\n"
        for e in sorted(entries, key=lambda e: e.id)
    )
    tmp = target.with_name(f".{META_FILE}.{secrets.token_hex(4)}.haro-tmp")
    try:
        tmp.write_text(body, encoding="utf-8")
        tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)
    _drop_legacy(project_path, META_FILE)


@dataclass
class Slot:
    path: str
    index: int
    text: str
    n: str
    prev: str
    next: str


@dataclass
class Snapshot:
    """The items of a project matched to their entries (built by ``snapshot``)."""

    entries: list[Entry]
    slots: list[Slot]
    matched: dict[tuple[str, int], Entry]
    lost: list[Entry]
    changed: bool

    def entry_for(self, path: str, index: int) -> Entry | None:
        return self.matched.get((path, index))


def snapshot(project_path: str, files: list[tuple[str, list[dict]]]) -> Snapshot:
    """Match the stored entries to the items of ``files`` (``(path, items)`` pairs, items as
    ``backlog.parse_todo_doc`` returns them). Refreshes the text, neighbours and file of every
    entry it matches, and reports whether anything changed (the caller may then ``persist``)."""
    entries = load(project_path)
    slots: list[Slot] = []
    for path, items in files:
        for i, it in enumerate(items):
            slots.append(Slot(
                path, i, it["text"], norm(it["text"]),
                norm(items[i - 1]["text"]) if i > 0 else "",
                norm(items[i + 1]["text"]) if i + 1 < len(items) else "",
            ))
    free = {(s.path, s.index): s for s in slots}
    matched: dict[tuple[str, int], Entry] = {}
    pending = list(entries)

    def claim(entry: Entry, slot: Slot) -> None:
        matched[(slot.path, slot.index)] = entry
        free.pop((slot.path, slot.index), None)
        pending.remove(entry)

    for entry in list(pending):  # 1: exact text, same file
        hit = next((s for s in free.values() if s.path == entry.path and s.text == entry.text), None)
        if hit:
            claim(entry, hit)
    for entry in list(pending):  # 2: normalised text, same file
        hit = next((s for s in free.values() if s.path == entry.path and s.n == norm(entry.text)), None)
        if hit:
            claim(entry, hit)
    for entry in list(pending):  # 3: normalised text, another file, when it is unambiguous
        hits = [s for s in free.values() if s.n == norm(entry.text)]
        if len(hits) == 1:
            claim(entry, hits[0])
    for entry in list(pending):  # 4: both neighbours, same file
        if not (entry.prev or entry.next):
            continue
        hits = [
            s for s in free.values()
            if s.path == entry.path and s.prev == entry.prev and s.next == entry.next
        ]
        if len(hits) == 1:
            claim(entry, hits[0])
    changed = False
    by_slot = {(s.path, s.index): s for s in slots}
    for (path, index), entry in matched.items():
        s = by_slot[(path, index)]
        fresh = (s.path, s.text, s.prev, s.next)
        if (entry.path, entry.text, entry.prev, entry.next) != fresh:
            entry.path, entry.text, entry.prev, entry.next = fresh
            changed = True
    return Snapshot(entries, slots, matched, list(pending), changed)


def forget(snap: Snapshot, path: str, index: int) -> None:
    """Drop the entry of an item haro itself deleted, so its tags, snooze and id cannot attach to
    the next item that happens to take its place."""
    entry = snap.entry_for(path, index)
    if entry is None:
        return
    snap.entries = [e for e in snap.entries if e.id != entry.id]
    for e in snap.entries:
        if entry.id in e.depends:
            e.depends = [d for d in e.depends if d != entry.id]
    snap.changed = True


def check_capture(project_path: str, tags: list[str], depends: list[str]) -> None:
    """Refuse a captured line whose tags or dependencies cannot be stored, before the line is
    written (the words are taken off the line, so a failure afterwards would lose them)."""
    for t in tags:
        clean_tag(t)
    if len(tags) > MAX_TAGS:
        raise MetaError(f"at most {MAX_TAGS} tags")
    if depends:
        known = {e.id for e in load(project_path)}
        for d in depends:
            if d not in known:
                raise MetaError(f"no item has the id {d!r}")


def persist(project_path: str, snap: Snapshot) -> None:
    save(project_path, snap.entries)
    snap.changed = False


def new_id(taken: set[str]) -> str:
    while True:
        i = "".join(secrets.choice(_ALPHABET) for _ in range(ID_LEN))
        if i not in taken:
            return i


def ensure(snap: Snapshot, path: str, index: int) -> Entry:
    """The entry of an item, created (with a fresh id) when it has none yet."""
    existing = snap.entry_for(path, index)
    if existing is not None:
        return existing
    slot = next((s for s in snap.slots if s.path == path and s.index == index), None)
    if slot is None:
        raise MetaError("no such item")
    entry = Entry(
        id=new_id({e.id for e in snap.entries}), path=path, text=slot.text, prev=slot.prev,
        next=slot.next, seen=date.today().isoformat(),
    )
    snap.entries.append(entry)
    snap.matched[(path, index)] = entry
    snap.changed = True
    return entry


def update(
    snap: Snapshot,
    entry: Entry,
    *,
    tags: list[str] | None = None,
    depends: list[str] | None = None,
    pinned: bool | None = None,
    snooze: str | None = None,
    archived: bool | None = None,
) -> Entry:
    if tags is not None:
        clean: list[str] = []
        for t in tags:
            c = clean_tag(t)
            if c not in clean:
                clean.append(c)
        if len(clean) > MAX_TAGS:
            raise MetaError(f"at most {MAX_TAGS} tags")
        entry.tags = clean
    if depends is not None:
        known = {e.id for e in snap.entries}
        for d in depends:
            if d == entry.id:
                raise MetaError("an item cannot depend on itself")
            if d not in known:
                raise MetaError(f"no item has the id {d!r}")
        by_id = {e.id: e for e in snap.entries}

        def reaches(start: str, goal: str, seen: set[str]) -> bool:
            if start == goal:
                return True
            if start in seen or start not in by_id:
                return False
            seen.add(start)
            return any(reaches(n, goal, seen) for n in by_id[start].depends)

        for d in depends:
            if reaches(d, entry.id, set()):
                raise MetaError("that would make a loop: it already depends on this item")
        entry.depends = list(dict.fromkeys(depends))
    if pinned is not None:
        entry.pinned = pinned
    if snooze is not None:
        if snooze:
            try:
                date.fromisoformat(snooze)
            except ValueError as e:
                raise MetaError("snooze is a date, YYYY-MM-DD, or empty") from e
        entry.snooze = snooze
    if archived is not None:
        entry.archived = archived
    snap.changed = True
    return entry


def decorate(snap: Snapshot, files: list[tuple[str, list[dict]]]) -> list[dict]:
    """Add the metadata to every item dict (in place): ``id`` (None until the item has an entry),
    ``tags``, ``depends``, ``pinned``, ``snooze``, ``snoozed``, ``archived``, and what follows from
    the dependencies: ``blocked`` and ``blocked_by`` (ids not done yet). Returns the entries that
    could not be matched to any item (``lost``), as plain dicts."""
    today = date.today().isoformat()
    by_id: dict[str, dict] = {}
    for path, items in files:
        for i, it in enumerate(items):
            e = snap.entry_for(path, i)
            it["id"] = e.id if e else None
            it["tags"] = list(e.tags) if e else []
            it["depends"] = list(e.depends) if e else []
            it["pinned"] = bool(e and e.pinned)
            it["snooze"] = e.snooze if e else ""
            it["snoozed"] = bool(e and e.snooze and e.snooze > today)
            it["archived"] = bool(e and e.archived)
            if e:
                by_id[e.id] = it
    for _path, items in files:
        for it in items:
            blockers = [
                d for d in it["depends"]
                if d in by_id and not by_id[d]["done"] and not by_id[d]["archived"]
            ]
            it["blocked_by"] = blockers
            it["blocked"] = bool(blockers)
    return [asdict(e) for e in snap.lost]


# ---- saved views --------------------------------------------------------------------------

def load_views(project_path: str) -> list[dict]:
    raw = _read(project_path, VIEWS_FILE)
    try:
        data = json.loads(raw) if raw is not None else []
    except ValueError:
        return []
    out = []
    for v in data if isinstance(data, list) else []:
        if isinstance(v, dict) and isinstance(v.get("name"), str) and isinstance(v.get("query"), str):
            out.append({
                "id": str(v.get("id") or ""), "name": v["name"][:60], "query": v["query"][:300],
                "layout": "board" if v.get("layout") == "board" else "list",
            })
    return out[:MAX_VIEWS]


def save_views(project_path: str, views: list[dict]) -> list[dict]:
    clean: list[dict] = []
    taken: set[str] = set()
    for v in views[:MAX_VIEWS]:
        name = str(v.get("name", "")).strip()[:60]
        if not name:
            raise MetaError("a view needs a name")
        vid = str(v.get("id") or "")
        if not _ID.match(vid) or vid in taken:
            vid = new_id(taken)
        taken.add(vid)
        clean.append({
            "id": vid, "name": name, "query": str(v.get("query", ""))[:300],
            "layout": "board" if v.get("layout") == "board" else "list",
        })
    folder = meta_dir(project_path)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / VIEWS_FILE
    tmp = target.with_name(f".{VIEWS_FILE}.{secrets.token_hex(4)}.haro-tmp")
    try:
        tmp.write_text(json.dumps(clean, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)
    _drop_legacy(project_path, VIEWS_FILE)
    return clean


# ---- capture: `fix cart bug #ui depends:ab12cd` ---------------------------------------------

_CAPTURE_TAG = re.compile(r"(?:^|(?<=\s))#([^\W\d_][\w/-]*)(?=\s|$)")
_CAPTURE_DEP = re.compile(r"(?:^|(?<=\s))depends:([a-z0-9]{4,12})(?=\s|$)")


def split_capture(title: str) -> tuple[str, list[str], list[str]]:
    """A captured line split into its text, its tags and the ids it depends on. Only whole
    words count: ``#ui`` is a tag, ``C#`` and an issue number (``#123``) are not."""
    tags = [m.group(1).lower() for m in _CAPTURE_TAG.finditer(title)]
    deps = [m.group(1) for m in _CAPTURE_DEP.finditer(title)]
    text = _CAPTURE_DEP.sub("", _CAPTURE_TAG.sub("", title))
    text = re.sub(r"\s{2,}", " ", text).strip()
    return text, list(dict.fromkeys(tags)), list(dict.fromkeys(deps))
