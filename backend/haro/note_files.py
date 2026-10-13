"""Files that sit beside the notes: PDFs, spreadsheets, documents, images, drawings.

An Obsidian vault carries these next to its markdown (a client's PDF, an Excel sheet, a diagram),
and a note links to them (``[[report.pdf]]``, ``![[diagram.png]]``). They live in the same
``.haro/notes/`` folder, travel with git like the notes, and are never read or written by haro
except to list them, open one with the system's own app, serve an image to the note view, and read a
PDF's (or a plain text file's) words so the search can find them. Nothing is converted or copied.

Every path is relative to the notes folder, may not start any part with a dot, may not be a
symlink, and must stay inside the folder. Only a short list of document and image types is ever
opened: a script or an app bundle is never handed to the system's ``open``.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path, PurePosixPath

from . import notes

MAX_FILES = 500
MAX_TEXT_CHARS = 400_000
MAX_PDF_PAGES = 300
MAX_PDF_BYTES = 40_000_000
MAX_TEXT_BYTES = 2_000_000

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
PDF_EXT = {".pdf"}
SHEET_EXT = {".xlsx", ".xls", ".xlsm", ".csv", ".ods"}
DOC_EXT = {".docx", ".doc", ".odt", ".rtf", ".pptx", ".ppt"}
TEXT_EXT = {".txt", ".sql", ".json", ".log", ".csv", ".tsv", ".yaml", ".yml", ".toml"}
DRAWING_EXT = {".excalidraw"}
OPENABLE = IMAGE_EXT | PDF_EXT | SHEET_EXT | DOC_EXT | TEXT_EXT | DRAWING_EXT | {".svg"}
_EXCALIDRAW_MD = ".excalidraw.md"  # the Obsidian plugin's drawing: markdown wrapping compressed JSON


def is_drawing_note(name: str) -> bool:
    return name.lower().endswith(_EXCALIDRAW_MD)


def _ext(name: str) -> str:
    n = name.lower()
    if n.endswith(_EXCALIDRAW_MD):
        return ".excalidraw"
    return ("." + n.rsplit(".", 1)[1]) if "." in n else ""


def kind_of(name: str) -> str:
    e = _ext(name)
    if e in PDF_EXT:
        return "pdf"
    if e in SHEET_EXT:
        return "sheet"
    if e in DOC_EXT:
        return "doc"
    if e in IMAGE_EXT or e == ".svg":
        return "image"
    if e in DRAWING_EXT:
        return "drawing"
    if e in TEXT_EXT:
        return "text"
    return "other"


def _walk(project_path: str):
    """Every candidate file under the notes folder as ``(relative posix path, absolute path)``:
    no hidden parts, no symlinks, nothing resolving outside, not the pasted-images folder."""
    root = notes.notes_root(project_path)
    if not root.is_dir():
        return
    real = root.resolve()
    for p in root.rglob("*"):
        try:
            rel = p.relative_to(root)
            parts = rel.parts
            if any(part.startswith(".") for part in parts) or p.is_symlink() or not p.is_file():
                continue
            if parts[0] == "assets":
                continue
            if p.name.lower().endswith(".md") and not is_drawing_note(p.name):
                continue
            if _ext(p.name) not in OPENABLE:
                continue
            if real not in p.resolve().parents:
                continue
            yield rel.as_posix(), p
        except OSError:
            continue


def list_files(project_path: str) -> list[dict]:
    """The files beside the notes, newest first. Blocking."""
    out = []
    for rel, p in _walk(project_path):
        try:
            st = p.stat()
        except OSError:
            continue
        out.append({
            "path": rel, "name": p.name, "kind": kind_of(p.name), "size": st.st_size,
            "modified": st.st_mtime,
        })
    out.sort(key=lambda r: -r["modified"])
    return out[:MAX_FILES]


def resolve(project_path: str, target: str) -> Path:
    """The file a link or a path names. An exact path first; else (as Obsidian does) a file of that
    name anywhere in the folder, the shallowest one. Raises ``NoteError`` when there is none."""
    target = target.strip().replace("\\", "/")
    if not target or "\x00" in target or target.startswith("/") or ".." in PurePosixPath(target).parts:
        raise notes.NoteError(f"not a file of this project's notes: {target!r}")
    found = {rel.lower(): p for rel, p in _walk(project_path)}
    hit = found.get(target.lower())
    if hit is not None:
        return hit
    if target.lower().endswith(".excalidraw"):  # [[drawing.excalidraw]] names drawing.excalidraw.md
        target = target + ".md"
        hit = found.get(target.lower())
        if hit is not None:
            return hit
    name = PurePosixPath(target).name.lower()
    same = sorted(((rel, p) for rel, p in found.items() if PurePosixPath(rel).name == name), key=lambda t: t[0].count("/"))
    if not same:
        raise notes.NoteError(f"no file {target!r} beside the notes")
    return same[0][1]


def image_file(project_path: str, target: str) -> Path:
    """The picture behind a note's image: ``assets/x.png`` (a pasted one), a path in the folder, or a
    bare name as Obsidian writes it. A drawing (``X.excalidraw``) shows its exported ``X.excalidraw.png``
    when the plugin made one."""
    t = target.strip()
    if t.lower().startswith("assets/"):
        # pasted images are not listed (they are not "files" to open), but are served
        from . import notes_extras

        return notes_extras.asset_file(project_path, t)
    candidates = [t]
    low = t.lower()
    if low.endswith(".excalidraw"):
        candidates.insert(0, t + ".png")
    elif low.endswith(_EXCALIDRAW_MD):
        candidates.insert(0, t[: -len(".md")] + ".png")
    for c in candidates:
        try:
            p = resolve(project_path, c)
        except notes.NoteError:
            continue
        if p.suffix.lower() in IMAGE_EXT:
            return p
    raise notes.NoteError("no such image beside the notes")


def open_externally(project_path: str, target: str) -> str:
    """Open a file with the system's own app (``open`` on macOS, ``xdg-open`` elsewhere). Returns its
    path relative to the notes folder. Only the types in ``OPENABLE`` are opened."""
    p = resolve(project_path, target)
    if _ext(p.name) not in OPENABLE:
        raise notes.NoteError("that kind of file is not opened from here")
    cmd = ["open", str(p)] if sys.platform == "darwin" else ["xdg-open", str(p)]
    try:
        subprocess.Popen(  # noqa: S603 (fixed program, the path is one argument, never a shell)
            cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as e:
        raise notes.NoteError(f"could not open it: {e}") from e
    return p.relative_to(notes.notes_root(project_path).resolve()).as_posix()


# ---- the words inside a file, for the search ------------------------------------------------

_pdf_cache: dict[tuple[str, int, int], str] = {}


def pdf_text(p: Path) -> str:
    """A PDF's text (the first pages, capped). Empty for a scanned PDF or one that cannot be read.
    Cached by path, modification time and size. Blocking."""
    try:
        st = p.stat()
    except OSError:
        return ""
    if st.st_size > MAX_PDF_BYTES:
        return ""
    key = (str(p), st.st_mtime_ns, st.st_size)
    if key in _pdf_cache:
        return _pdf_cache[key]
    text = ""
    try:
        from pypdf import PdfReader

        reader = PdfReader(str(p))
        parts: list[str] = []
        total = 0
        for page in reader.pages[:MAX_PDF_PAGES]:
            t = page.extract_text() or ""
            parts.append(t)
            total += len(t)
            if total >= MAX_TEXT_CHARS:
                break
        text = "\n".join(parts)[:MAX_TEXT_CHARS]
    except Exception:  # noqa: BLE001 (a damaged or encrypted PDF is just not searchable)
        text = ""
    if len(_pdf_cache) > 64:
        _pdf_cache.clear()
    _pdf_cache[key] = text
    return text


def file_text(p: Path) -> str:
    if p.suffix.lower() in PDF_EXT:
        return pdf_text(p)
    if _ext(p.name) in TEXT_EXT:
        try:
            if p.stat().st_size > MAX_TEXT_BYTES:
                return ""
            return p.read_bytes().decode("utf-8", errors="replace")[:MAX_TEXT_CHARS]
        except OSError:
            return ""
    return ""


def searchable(project_path: str) -> list[dict]:
    """Every listed file with its text (PDFs and plain-text files; others have none), for the
    search. Blocking."""
    out = []
    for rel, p in _walk(project_path):
        try:
            mtime = p.stat().st_mtime
        except OSError:
            continue
        out.append({"path": rel, "name": p.name, "kind": kind_of(p.name), "text": file_text(p), "mtime": mtime})
        if len(out) >= MAX_FILES:
            break
    return out
