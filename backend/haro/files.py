"""Worktree file access for the in-app editor (the "code" view).

Browse / read / write files inside a workspace's worktree so the developer can
tweak the agent's output without leaving haro. Paths are always resolved
*inside* the worktree — traversal outside it is refused.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import mimetypes
import os
import re
import shutil
import uuid
from pathlib import Path

from . import git_ops

_IGNORE = {".git", "node_modules", ".DS_Store"}
_MAX_BYTES = 1_500_000  # don't load huge files into the editor
_TSCONFIG_MAX_EXTENDS = 8  # cap `extends` chain depth (guard against cycles)


def safe_path(worktree: str, rel: str) -> Path:
    base = Path(worktree).resolve()
    target = (base / rel).resolve()
    if base != target and base not in target.parents:
        raise ValueError("path escapes the worktree")
    return target


class FileConflict(Exception):
    """The file's content on disk no longer matches the etag the writer last saw."""

    def __init__(self, current_etag: str) -> None:
        self.current_etag = current_etag
        super().__init__("file changed on disk")


class FileMissing(Exception):
    """The writer expected an existing file (it holds an etag) but it is gone."""


def etag_of(data: bytes) -> str:
    # A content hash, not an mtime: mtime has 1 s granularity on some filesystems and
    # flags a false conflict when an identical file is re-checked-out.
    return hashlib.sha1(data).hexdigest()[:16]


def _walk_tree(base: Path, rel: str = "") -> list[dict]:
    """Filesystem walk of the worktree (dirs first; ignores .git/node_modules). The
    fallback for :func:`build_tree` when the directory is not a git work tree."""
    out: list[dict] = []
    d = base / rel if rel else base
    try:
        entries = sorted(d.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))
    except OSError:
        return out
    for e in entries:
        if e.name in _IGNORE:
            continue
        rp = f"{rel}/{e.name}".lstrip("/")
        if e.is_dir() and not e.is_symlink():
            out.append({"name": e.name, "path": rp, "dir": True, "children": _walk_tree(base, rp)})
        elif e.is_file():
            out.append({"name": e.name, "path": rp, "dir": False})
    return out


def _nest(file_paths: list[str], dir_paths: list[str]) -> list[dict]:
    root: dict = {}
    for raw, is_dir in [(p, False) for p in file_paths] + [(p, True) for p in dir_paths]:
        parts = [c for c in raw.split("/") if c]
        if not parts or any(c in _IGNORE for c in parts):
            continue
        node = root
        for i, comp in enumerate(parts):
            last = i == len(parts) - 1
            if last and not is_dir:
                node.setdefault(comp, None)
            else:
                nxt = node.get(comp)
                if nxt is None:
                    nxt = node[comp] = {}
                node = nxt

    def emit(node: dict, rel: str) -> list[dict]:
        names = sorted(node, key=lambda n: (node[n] is None, n.lower()))
        out: list[dict] = []
        for name in names:
            rp = f"{rel}/{name}" if rel else name
            if node[name] is None:
                out.append({"name": name, "path": rp, "dir": False})
            else:
                out.append({"name": name, "path": rp, "dir": True, "children": emit(node[name], rp)})
        return out

    return emit(root, "")


def _graft_walk(tree: list[dict], base: Path, rel: str) -> None:
    """Replace the children of the folder at ``rel`` in ``tree`` with a filesystem walk."""
    level = tree
    node: dict | None = None
    for part in rel.split("/"):
        node = next((n for n in level if n["dir"] and n["name"] == part), None)
        if node is None:
            return
        level = node["children"]
    if node is not None:
        node["children"] = _walk_tree(base, rel)


async def build_tree(base: Path) -> list[dict]:
    """Nested tree of the worktree (dirs first, then files).

    Git-backed so ``.gitignore`` is respected and a 10k-file repo is one cheap call:
    tracked + untracked-not-ignored files, minus tracked files deleted from disk, plus
    untracked directories (so an empty folder made by the explorer still shows). Files
    under ``.context/`` (composer attachments, excluded via ``info/exclude``) therefore
    leave the tree; they stay reachable from the composer chip. A non-git directory, or
    any git failure, falls back to the filesystem walk. ``ls-files`` reports a submodule as
    one path and a nested repo as a bare folder, so anything it lists that is a directory
    on disk is shown as a folder filled by the filesystem walk instead."""
    if not (base / ".git").exists():
        return _walk_tree(base)
    try:
        listed = await git_ops._git(
            "ls-files", "-z", "--cached", "--others", "--exclude-standard", cwd=base
        )
        deleted = await git_ops._git("ls-files", "-z", "--deleted", cwd=base)
        dirs = await git_ops._git(
            "ls-files", "-z", "--others", "--directory", "--exclude-standard", cwd=base
        )
    except (git_ops.GitError, OSError, UnicodeDecodeError):
        return _walk_tree(base)
    gone = set(deleted.split("\0"))
    entries = [p for p in listed.split("\0") if p and p not in gone]
    nested = [
        p.rstrip("/")
        for p in entries
        if (base / p.rstrip("/")).is_dir() and not (base / p.rstrip("/")).is_symlink()
    ]
    nested_set = set(nested)
    file_paths = [p for p in entries if p.rstrip("/") not in nested_set]
    dir_paths = [p.rstrip("/") for p in dirs.split("\0") if p.endswith("/")] + nested
    tree = _nest(file_paths, dir_paths)
    for rel in nested:
        _graft_walk(tree, base, rel)
    return tree


def read_file(worktree: str, rel: str) -> dict:
    p = safe_path(worktree, rel)
    if not p.is_file():
        raise FileNotFoundError(rel)
    size = p.stat().st_size
    # Size cap: don't stream a huge blob into Monaco (freezes the editor / the tab).
    if size > _MAX_BYTES:
        return {"path": rel, "content": "", "error": "file too large to edit", "size": size}
    data = p.read_bytes()
    etag = etag_of(data)
    # Binary sniff: a NUL byte is the classic tell (text files never carry one), and
    # it also flags blobs that would happen to decode as UTF-8. Fall back to the
    # decode result for the rest.
    if b"\x00" in data:
        return {"path": rel, "content": "", "error": "binary file", "size": size, "etag": etag}
    try:
        return {"path": rel, "content": data.decode("utf-8"), "size": len(data), "etag": etag}
    except UnicodeDecodeError:
        return {"path": rel, "content": "", "error": "binary file", "size": size, "etag": etag}


def write_file(worktree: str, rel: str, content: str, expected_etag: str | None = None) -> str:
    """Write ``content`` atomically and return the new etag.

    With ``expected_etag`` the write is refused (``FileConflict`` / ``FileMissing``) when
    the file on disk no longer matches what the editor last read. Atomic (temp file in
    the same directory, fsync, ``os.replace``) so a crash or a concurrent reader never
    sees a half-written file. The check-then-replace window is not locked: it narrows the
    race to microseconds, it does not close it."""
    p = safe_path(worktree, rel)
    existing: bytes | None = None
    try:
        existing = p.read_bytes()
    except FileNotFoundError:
        pass
    except IsADirectoryError:
        raise ValueError("path is a directory") from None
    if expected_etag is not None:
        if existing is None:
            raise FileMissing(rel)
        current = etag_of(existing)
        if current != expected_etag:
            raise FileConflict(current)
    data = content.encode("utf-8")
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.haro-{uuid.uuid4().hex[:8]}.tmp")
    # os.open with 0o666 honours the umask, unlike mkstemp's fixed 0600, so a new file
    # gets the permissions a plain write would have given it.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if existing is not None:
            shutil.copymode(p, tmp)  # keep the exec bit
        os.replace(tmp, p)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return etag_of(data)


def write_bytes(worktree: str, rel: str, data: bytes) -> None:
    """Write raw bytes into the worktree (for binary attachments — images, PDFs,
    picked media). Same path-traversal guard as :func:`write_file`."""
    p = safe_path(worktree, rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def create_entry(worktree: str, rel: str, is_dir: bool) -> None:
    """Create a new file (empty) or folder inside the worktree for the tree's
    right-click ops. Parents are created as needed; refuses to clobber an existing
    path so a "new file" can't silently truncate a real one."""
    p = safe_path(worktree, rel)
    if p.exists():
        raise ValueError("path already exists")
    if is_dir:
        p.mkdir(parents=True)
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.touch()


def rename_entry(worktree: str, src: str, dst: str) -> None:
    """Rename / move a file or folder within the worktree. Both ends are traversal-
    guarded; refuses to overwrite an existing destination."""
    s = safe_path(worktree, src)
    d = safe_path(worktree, dst)
    if not s.exists():
        raise FileNotFoundError(src)
    if d.exists():
        raise ValueError("destination already exists")
    d.parent.mkdir(parents=True, exist_ok=True)
    s.rename(d)


def delete_entry(worktree: str, rel: str) -> None:
    """Delete a file or folder (recursively) within the worktree. Refuses to delete
    the worktree root itself."""
    p = safe_path(worktree, rel)
    if p.resolve() == Path(worktree).resolve():
        raise ValueError("cannot delete the worktree root")
    if not p.exists():
        raise FileNotFoundError(rel)
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    else:
        p.unlink()


def _strip_jsonc(text: str) -> str:
    """Strip `//` + `/* */` comments and trailing commas from JSONC so ``json.loads``
    can read a tsconfig (which is JSON-with-comments). String literals are respected
    so a `//` inside a value isn't mistaken for a comment."""
    out: list[str] = []
    i, n = 0, len(text)
    in_str = False
    quote = ""
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] not in "\r\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))  # drop trailing commas


def _load_jsonc(p: Path) -> dict:
    try:
        data = json.loads(_strip_jsonc(p.read_text("utf-8")))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, UnicodeDecodeError):
        return {}


def _resolve_extends(base: Path, spec: str, cfg_dir: Path) -> Path | None:
    """Resolve a tsconfig ``extends`` target to a file inside the worktree. Relative
    specs resolve against the extending config's dir; bare package names against
    ``node_modules``. Anything escaping the worktree is refused (returns None)."""
    if spec.startswith((".", "/")):
        cand = (cfg_dir / spec).resolve()
    else:
        cand = (base / "node_modules" / spec).resolve()
    if base != cand and base not in cand.parents:
        return None
    if cand.is_dir():
        cand = cand / "tsconfig.json"
    elif cand.suffix != ".json":
        cand = cand.with_name(cand.name + ".json")
    return cand if cand.is_file() else None


def resolve_tsconfig(worktree: str) -> dict | None:
    """Merged ``compilerOptions`` from the worktree's ``tsconfig.json`` (or
    ``jsconfig.json``), following the ``extends`` chain parent-first so the child
    overrides win. Returns None when there's no config at the worktree root; an empty
    dict when a config exists but sets no compiler options. Best-effort and tolerant:
    unreadable / malformed / out-of-worktree configs are skipped rather than raising —
    the code editor only needs a hint (jsx mode, target) to parse files the way the
    project does, not a faithful compile."""
    base = Path(worktree).resolve()
    root_cfg = next(
        (base / name for name in ("tsconfig.json", "jsconfig.json") if (base / name).is_file()),
        None,
    )
    if not root_cfg:
        return None
    merged: dict = {}
    seen: set[Path] = set()

    def load_chain(cfg: Path, depth: int) -> None:
        if depth > _TSCONFIG_MAX_EXTENDS or cfg in seen:
            return
        seen.add(cfg)
        data = _load_jsonc(cfg)
        ext = data.get("extends")
        specs = [ext] if isinstance(ext, str) else ext if isinstance(ext, list) else []
        for spec in specs:
            if isinstance(spec, str):
                target = _resolve_extends(base, spec, cfg.parent)
                if target:
                    load_chain(target, depth + 1)
        co = data.get("compilerOptions")
        if isinstance(co, dict):
            merged.update(co)

    load_chain(root_cfg, 0)
    return merged


def raw_file(worktree: str, rel: str) -> tuple[Path, str]:
    """Resolve a worktree file for RAW byte serving (images, PDFs, …) with a guessed
    media type — so the code view can preview non-text files inline instead of
    showing a "binary file" error. Path traversal is refused (via safe_path)."""
    p = safe_path(worktree, rel)
    if not p.is_file():
        raise FileNotFoundError(rel)
    media, _ = mimetypes.guess_type(str(p))
    return p, media or "application/octet-stream"


async def search_text(worktree: str, q: str, limit: int = 200) -> dict:
    """Find-in-files across the worktree (ripgrep, or grep fallback). Shared by
    ``GET /workspaces/{id}/search`` and the manual rail's ``repo`` research scope."""
    if not q.strip():
        return {"matches": [], "truncated": False}

    rg = shutil.which("rg")
    if rg:
        cmd = [rg, "--line-number", "--column", "--no-heading", "--color=never",
               "--smart-case", "--max-columns=240", "-e", q, "."]
    else:
        cmd = ["grep", "-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "-e", q, "."]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, cwd=worktree,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
    except (FileNotFoundError, asyncio.TimeoutError):
        return {"matches": [], "truncated": False, "error": "search unavailable"}

    matches: list[dict] = []
    truncated = False
    for raw in out.decode(errors="replace").splitlines():
        # rg: path:line:col:text   grep: path:line:text
        parts = raw.split(":", 3 if rg else 2)
        if len(parts) < (4 if rg else 3):
            continue
        path = parts[0][2:] if parts[0].startswith("./") else parts[0]
        try:
            line = int(parts[1])
            col = int(parts[2]) if rg else 1
        except ValueError:
            continue
        text = parts[3] if rg else parts[2]
        matches.append({"file": path, "line": line, "col": col, "text": text[:240]})
        if len(matches) >= limit:
            truncated = True
            break
    return {"matches": matches, "truncated": truncated}
