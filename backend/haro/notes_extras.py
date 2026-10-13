"""What goes around the notes: open tasks, templates, the daily note, and git history.

Everything is derived from the files in ``.haro/notes/`` and the project's git, and lives there:
templates are ordinary files in ``.haro/templates/``, the daily note is a normal note at
``daily/YYYY-MM-DD.md``, and history is ``git log`` on the note's file. Nothing here keeps state
of its own.
"""

from __future__ import annotations

import re
import subprocess
from datetime import date, datetime
from pathlib import Path

from . import notes, notes_links
from .note_templates import BUILT_IN

TEMPLATES_DIR = ".haro/templates"
MAX_TASKS = 500

_TASK = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[ \]\s+(.*\S)\s*$")


def open_tasks(project_path: str) -> list[dict]:
    """Unchecked ``- [ ]`` lines across the notes (outside code), newest note first. Read only:
    these are listed, never copied into the backlog."""
    root = notes.notes_root(project_path)
    out: list[dict] = []
    for p in notes._files(project_path):
        try:
            data = p.read_bytes()
        except OSError:
            continue
        if len(data) > notes.MAX_BYTES:
            continue
        text = data.decode("utf-8", errors="replace")
        masked = notes_links.mask_code(text).split("\n")
        raw = text.split("\n")
        rel = p.relative_to(root).as_posix()
        title = notes._title(text, p.stem.replace("-", " ").replace("_", " "))
        for n, line in enumerate(masked, start=1):
            m = _TASK.match(line)
            if m:
                out.append({"path": rel, "title": title, "line": n, "text": raw[n - 1].strip()[:200].split("] ", 1)[-1]})
                if len(out) >= MAX_TASKS:
                    return out
    return out


def templates(project_path: str) -> list[dict]:
    """The built-in templates plus any ``.haro/templates/*.md`` (a project file of the same id
    replaces the built-in)."""
    found: dict[str, dict] = {
        k: {"id": k, "name": name, "content": body, "source": "built-in"} for k, (name, body) in BUILT_IN.items()
    }
    folder = Path(project_path) / TEMPLATES_DIR
    if folder.is_dir() and not folder.is_symlink() and not (Path(project_path) / ".haro").is_symlink():
        for p in sorted(folder.glob("*.md")):
            if p.is_symlink() or not p.is_file() or p.name.startswith("."):
                continue
            try:
                data = p.read_bytes()
            except OSError:
                continue
            if len(data) > 50_000:
                continue
            tid = p.stem.lower().replace(" ", "-")
            found[tid] = {
                "id": tid, "name": p.stem.replace("-", " ").replace("_", " ").title(),
                "content": data.decode("utf-8", errors="replace"), "source": "project",
            }
    return list(found.values())


def fill(content: str, title: str, today: date | None = None) -> str:
    today = today or date.today()
    return content.replace("{{title}}", title).replace("{{date}}", today.isoformat())


def daily_path(today: date | None = None) -> str:
    return f"daily/{(today or date.today()).isoformat()}.md"


def daily_text(today: date, facts: dict) -> str:
    """A day's note, pre-filled with what haro knows (``facts``: landed, started, red, tasks)
    and room to write. Facts are lists of short lines; empty ones are left out."""
    out = [f"# {today.isoformat()}", ""]
    sections = (
        ("Landed on the default branch today", facts.get("landed", [])),
        ("Workspaces started today", facts.get("started", [])),
        ("Red gates right now", facts.get("red", [])),
        ("Open tasks in your notes", facts.get("tasks", [])),
    )
    for title, lines in sections:
        if lines:
            out += [f"## {title}", ""] + [f"- {l}" for l in lines] + [""]
    out += ["## Today", "", "- [ ] ", "", "## Notes", "", ""]
    return "\n".join(out)


# ---- git history ----------------------------------------------------------------------------

def _git(project_path: str, *args: str, timeout: int = 20) -> str:
    r = subprocess.run(
        ["git", *args], cwd=project_path, capture_output=True, text=True, timeout=timeout, check=False,
    )
    if r.returncode != 0:
        raise notes.NoteError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "git failed")
    return r.stdout


def _repo_rel(rel: str) -> str:
    return f"{notes.NOTES_DIR}/{notes._safe_rel(rel)}"


def history(project_path: str, rel: str, limit: int = 30) -> list[dict]:
    """The commits that changed a note under its current name, newest first. Empty when the note
    is not tracked yet. A rename starts a new history (``--follow`` would list commits whose
    version of the note cannot be opened by the current path). Blocking."""
    path = _repo_rel(rel)
    try:
        out = _git(project_path, "log", f"-n{limit}", "--format=%H%x1f%ct%x1f%an%x1f%s", "--", path)
    except (notes.NoteError, OSError, subprocess.SubprocessError):
        return []
    rows = []
    for line in out.splitlines():
        sha, _, rest = line.partition("\x1f")
        ts, _, rest = rest.partition("\x1f")
        author, _, subject = rest.partition("\x1f")
        if re.fullmatch(r"[0-9a-f]{40}", sha):
            rows.append({"sha": sha, "date": int(ts or 0), "author": author, "subject": subject})
    return rows


def _check_sha(sha: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        raise notes.NoteError("not a commit")
    return sha


def revision(project_path: str, rel: str, sha: str) -> str:
    """A note's text as of a commit. Blocking."""
    return _git(project_path, "show", f"{_check_sha(sha)}:{_repo_rel(rel)}")


def diff_to_current(project_path: str, rel: str, sha: str) -> str:
    """The unified diff from a commit's version of a note to what is on disk now. Blocking."""
    return _git(project_path, "diff", _check_sha(sha), "--", _repo_rel(rel))


# ---- pasted images --------------------------------------------------------------------------

ASSETS_DIR = "assets"
MAX_ASSET_BYTES = 8_000_000
_IMAGE_TYPES = {
    b"\x89PNG\r\n\x1a\n": "png",
    b"\xff\xd8\xff": "jpg",
    b"GIF87a": "gif",
    b"GIF89a": "gif",
}


def _image_ext(data: bytes) -> str | None:
    for magic, ext in _IMAGE_TYPES.items():
        if data.startswith(magic):
            return ext
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def save_asset(project_path: str, data: bytes, today: datetime | None = None) -> str:
    """Store a pasted image under ``.haro/notes/assets/`` and return its path relative to the
    notes folder (what the note's ``![](assets/...)`` says). The type is taken from the bytes, not
    from a name the caller gives; anything that is not a PNG, JPEG, GIF or WebP is refused."""
    if len(data) > MAX_ASSET_BYTES:
        raise notes.NoteError("an image is limited to 8 MB")
    ext = _image_ext(data)
    if ext is None:
        raise notes.NoteError("only PNG, JPEG, GIF and WebP images")
    root = notes.notes_root(project_path)
    folder = root / ASSETS_DIR
    folder.mkdir(parents=True, exist_ok=True)
    project_root = Path(project_path).resolve()
    if project_root not in folder.resolve().parents:
        raise notes.NoteError("the assets folder points outside the project")
    stamp = (today or datetime.now()).strftime("%Y%m%d-%H%M%S")
    n = 0
    while True:
        name = f"{stamp}{'' if n == 0 else f'-{n}'}.{ext}"
        target = folder / name
        try:
            with open(target, "xb") as f:
                f.write(data)
            return f"{ASSETS_DIR}/{name}"
        except FileExistsError:
            n += 1


def asset_file(project_path: str, rel: str) -> Path:
    """The image file behind ``assets/<name>``: a plain name under the assets folder, an image
    extension, and not a link out of it."""
    if not re.fullmatch(rf"{ASSETS_DIR}/[\w.-]+\.(png|jpg|gif|webp)", rel):
        raise notes.NoteError("not an image of this project's notes")
    root = notes.notes_root(project_path).resolve()
    target = (root / rel).resolve()
    if root not in target.parents or not target.is_file():
        raise notes.NoteError("no such image")
    return target
