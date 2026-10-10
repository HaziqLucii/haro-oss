"""Project notes: free-form markdown pages in ``<project>/.haro/notes/``.

The Backlog is for work you will do; this is where the thinking that comes before it goes
(a brainstorm, a design sketch, what you tried). Plain markdown files in the repo, so they
travel with ``git pull``, open in any editor, and cannot be locked in. They are written by the
developer in the app: nothing here is called by an agent, and an agent run only sees them as
ordinary files.

Every path is relative to the notes folder and guarded the way ``backlog`` guards its own: a
``.md`` name that stays inside the folder. A save carries the ``etag`` (a hash of the bytes)
the editor last read; if the file changed since, ``NoteConflict`` stops the write instead of
overwriting someone else's edit (an editor in another window, a ``git pull``). The check and
the write are two steps, so a change by another process in between can still be overwritten;
inside haro saves are serialized, and for a local tool that window is accepted. Creating a note
is exact: ``create_only`` refuses to replace a file that exists.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath

NOTES_DIR = ".haro/notes"
MAX_BYTES = 1_000_000
MAX_NOTES = 500
MAX_SEARCHED = 2000  # files a search will open
HEAD_BYTES = 4096  # what the list reads of a note: enough for its title
SEARCH_BYTES = 256_000  # how much of one note a search reads
MAX_NAME = 200  # bytes in one path part, so the scratch name still fits


class NoteError(ValueError):
    """The request is not a valid note operation (bad name, missing, too big)."""


class NoteConflict(NoteError):
    """The file changed since the editor read it."""

    def __init__(self, etag: str):
        super().__init__("the note changed on disk since it was opened")
        self.etag = etag


def notes_root(project_path: str) -> Path:
    return Path(project_path) / NOTES_DIR


def _safe_rel(rel: str) -> str:
    rel = rel.strip()
    p = PurePosixPath(rel)
    if (
        not rel or "\x00" in rel or "\\" in rel or rel.endswith("/") or p.is_absolute()
        or ".." in p.parts or any(part.startswith(".") for part in p.parts)
        or any(len(part.encode("utf-8", "replace")) > MAX_NAME for part in p.parts)
    ):
        raise NoteError(f"not a note path: {rel!r}")
    if p.suffix.lower() != ".md":
        raise NoteError("a note is a .md file")
    return p.as_posix()


def _resolve(project_path: str, rel: str) -> tuple[str, Path]:
    safe = _safe_rel(rel)
    root = notes_root(project_path).resolve()
    target = (root / safe).resolve()
    if root != target and root not in target.parents:
        raise NoteError(f"path escapes the notes folder: {rel!r}")
    return safe, target


def etag_of(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def _title(text: str, fallback: str) -> str:
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#"):
            t = s.lstrip("#").strip()
            if t:
                return t
        elif s:
            break
    return fallback


def _files(project_path: str) -> list[Path]:
    """Every note, newest first. Symlinks are skipped: a committed link must not be able to
    show another file's text in the list or in search snippets."""
    root = notes_root(project_path)
    if not root.is_dir():
        return []
    real = root.resolve()
    found: list[tuple[float, Path]] = []
    for p in root.rglob("*.md"):
        try:
            rel = p.relative_to(root)
            if p.is_symlink() or not p.is_file() or any(part.startswith(".") for part in rel.parts):
                continue
            if real not in p.resolve().parents:
                continue
            found.append((p.stat().st_mtime, p))
        except OSError:
            continue
    found.sort(key=lambda t: t[0], reverse=True)
    return [p for _, p in found]


def _head(p: Path, limit: int) -> str:
    with p.open("rb") as f:
        return f.read(limit).decode("utf-8", errors="replace")


def list_notes(project_path: str, q: str = "") -> list[dict]:
    """Newest first. Without ``q`` at most ``MAX_NOTES``, each read only as far as its title.
    With ``q``, the notes whose title or (the first ``SEARCH_BYTES`` of the) text contain it,
    case-insensitive, each with up to three matching lines; at most ``MAX_SEARCHED`` files are
    opened. Blocking: call it from a thread."""
    root = notes_root(project_path)
    needle = q.strip().lower()
    out: list[dict] = []
    files = _files(project_path)
    for p in files[: MAX_SEARCHED if needle else MAX_NOTES]:
        try:
            text = _head(p, SEARCH_BYTES if needle else HEAD_BYTES)
            st = p.stat()
        except OSError:
            continue
        rel = p.relative_to(root).as_posix()
        title = _title(text, p.stem.replace("-", " ").replace("_", " "))
        snippets: list[str] = []
        if needle:
            if needle not in text.lower() and needle not in title.lower():
                continue
            snippets = [l.strip()[:160] for l in text.splitlines() if needle in l.lower()][:3]
        out.append({
            "path": rel, "title": title, "modified": st.st_mtime, "size": st.st_size,
            "snippets": snippets,
        })
        if len(out) >= MAX_NOTES:
            break
    return out


def read_note(project_path: str, rel: str) -> dict:
    safe, target = _resolve(project_path, rel)
    try:
        data = target.read_bytes()
    except OSError as e:
        raise NoteError(f"could not read {safe}: {e}") from e
    return {"path": safe, "content": data.decode("utf-8", errors="replace"), "etag": etag_of(data)}


def write_note(
    project_path: str,
    rel: str,
    content: str,
    etag: str | None = None,
    *,
    create_only: bool = False,
) -> dict:
    """Create or replace a note. With ``etag`` the write goes through only if the file still
    has those bytes (a new file with an etag, or a deleted one, conflicts the same way). With
    ``create_only`` it refuses to replace anything. With neither, it overwrites on purpose."""
    safe, target = _resolve(project_path, rel)
    data = content.encode("utf-8")
    if len(data) > MAX_BYTES:
        raise NoteError("a note is limited to 1 MB")
    if target.is_dir():
        raise NoteError(f"{safe} is a folder")
    if etag is not None and not create_only:
        current = etag_of(target.read_bytes()) if target.is_file() else ""
        if current != etag:
            raise NoteConflict(current)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.haro-tmp")
    try:
        tmp.write_bytes(data)
        if create_only:
            try:
                os.link(tmp, target)  # fails if the name is taken, even by another case
            except FileExistsError:
                raise NoteError(f"{safe} already exists") from None
        else:
            tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)
    return {"path": safe, "etag": etag_of(data)}


def delete_note(project_path: str, rel: str) -> str:
    safe, target = _resolve(project_path, rel)
    if not target.is_file():
        raise NoteError(f"{safe} does not exist")
    target.unlink()
    return safe


def rename_note(project_path: str, rel: str, new_rel: str) -> tuple[str, str]:
    old, src = _resolve(project_path, rel)
    new, dst = _resolve(project_path, new_rel)
    if not src.is_file():
        raise NoteError(f"{old} does not exist")
    if old == new:
        return old, new
    if dst.exists() and not src.samefile(dst):  # same file: only the case changes
        raise NoteError(f"{new} already exists")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)
    return old, new
