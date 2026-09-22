"""Worktree file access for the in-app editor (the "code" view).

Browse / read / write files inside a workspace's worktree so the developer can
tweak the agent's output without leaving haro. Paths are always resolved
*inside* the worktree — traversal outside it is refused.
"""

from __future__ import annotations

import json
import mimetypes
import re
import shutil
from pathlib import Path

_IGNORE = {".git", "node_modules", ".DS_Store"}
_MAX_BYTES = 1_500_000  # don't load huge files into the editor
_TSCONFIG_MAX_EXTENDS = 8  # cap `extends` chain depth (guard against cycles)


def safe_path(worktree: str, rel: str) -> Path:
    base = Path(worktree).resolve()
    target = (base / rel).resolve()
    if base != target and base not in target.parents:
        raise ValueError("path escapes the worktree")
    return target


def build_tree(base: Path, rel: str = "") -> list[dict]:
    """Nested tree of the worktree (dirs first, then files; ignores .git/node_modules)."""
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
            out.append({"name": e.name, "path": rp, "dir": True, "children": build_tree(base, rp)})
        elif e.is_file():
            out.append({"name": e.name, "path": rp, "dir": False})
    return out


def read_file(worktree: str, rel: str) -> dict:
    p = safe_path(worktree, rel)
    if not p.is_file():
        raise FileNotFoundError(rel)
    size = p.stat().st_size
    # Size cap: don't stream a huge blob into Monaco (freezes the editor / the tab).
    if size > _MAX_BYTES:
        return {"path": rel, "content": "", "error": "file too large to edit", "size": size}
    data = p.read_bytes()
    # Binary sniff: a NUL byte is the classic tell (text files never carry one), and
    # it also flags blobs that would happen to decode as UTF-8. Fall back to the
    # decode result for the rest.
    if b"\x00" in data:
        return {"path": rel, "content": "", "error": "binary file", "size": size}
    try:
        return {"path": rel, "content": data.decode("utf-8")}
    except UnicodeDecodeError:
        return {"path": rel, "content": "", "error": "binary file", "size": size}


def write_file(worktree: str, rel: str, content: str) -> None:
    p = safe_path(worktree, rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)


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
