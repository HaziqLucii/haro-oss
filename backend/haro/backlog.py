"""Backlog markdown: parsing, and the write paths built on top of it.

The backlog has always been read-only files-in-git: an item flips to done only when
an agent merges the tick back. This module holds that whole lifecycle for markdown
backlogs — parsing a file into notes + `- [ ]` items (``parse_todo_doc``), creating
or editing one from the in-app editor (``write_todo``, the ``PUT /projects/{id}/todo``
endpoint), appending a gate-residue follow-up item (``append_item``, the
``POST /projects/{id}/todo/items`` endpoint), and flipping a single item's checkbox
once its seeded workspace ships (``tick_backlog_item``). ``tick_backlog_item`` is
called from exactly one place — ``integrate.py``, on the workspace's WORKTREE, right
before the merge commit — so the tick rides inside that commit the same way
``Closes #n`` rides inside the message, instead of a separate edit to the main
checkout after the fact (which would dirty it and refuse every subsequent local
merge, or race the gh path's next pull).

It's a thin, well-guarded seam kept out of ``main.py``/``integrate.py`` on purpose
(disjoint file ownership, single home for the path-safety rules and the parsing they
guard). The one rule that matters for writes: a write may only touch a
*backlog-eligible* path inside the project — a doc under the configured
``backlog_dir``, a todo-named doc, or a ``[backlog] files`` glob — so the endpoint
can never be coerced into scribbling an arbitrary file in the repo.
"""

from __future__ import annotations

import fnmatch
from pathlib import Path, PurePosixPath

# Doc-like extensions that mark a human backlog doc — mirrors
# ``main._discover_todo_files`` / ``watcher._TODO_DOC_EXT`` (a source file like
# ``todos.py`` must never count as a backlog doc, nor be writable through here).
_TODO_DOC_EXT = {".md", ".markdown", ".txt", ".rst", ""}


class BacklogError(ValueError):
    """A rejected write — unsafe path, wrong extension, or non-backlog target.
    Carried up to the route as an HTTP 400 (a client mistake, not a server fault)."""


def _ext(name: str) -> str:
    return ("." + name.rsplit(".", 1)[1].lower()) if "." in name else ""


def is_backlog_path(
    rel: str, backlog_dir: str = "backlog", extra_globs: tuple[str, ...] | list[str] = ()
) -> bool:
    """Is ``rel`` (a repo-relative POSIX path) a backlog doc? True when it has a
    doc extension AND either lives under ``backlog_dir`` (any name), its basename
    contains 'todo', or it matches one of ``extra_globs`` (the ``[backlog] files``
    config, e.g. ``"TODO.md"``/``"docs/backlog*"`` — additive, mirrors ``[files]
    include``'s shape). Mirrors discovery so the editor can only write what the
    backlog actually shows."""
    rel = rel.strip().strip("/")
    if not rel:
        return False
    base = rel.rsplit("/", 1)[-1]
    if _ext(base) not in _TODO_DOC_EXT:
        return False
    under_dir = bool(backlog_dir) and (
        rel == backlog_dir or rel.startswith(f"{backlog_dir}/")
    )
    if under_dir or "todo" in base.lower():
        return True
    return any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(base, g) for g in extra_globs)


def _safe_rel(rel: str) -> str:
    """Normalize a client-supplied path and refuse anything that could escape the
    project root: absolute paths and ``..`` traversal. ``.``/empty segments are
    normalized away by ``PurePosixPath``. Check absoluteness *before* stripping any
    leading slash, so ``/etc/x`` is rejected rather than silently reinterpreted as a
    project-relative path."""
    rel = rel.strip().replace("\\", "/")
    if not rel:
        raise BacklogError("path is required")
    p = PurePosixPath(rel)
    if p.is_absolute():
        raise BacklogError(f"path must be relative to the project: {rel!r}")
    if ".." in p.parts:
        raise BacklogError(f"unsafe path (traversal): {rel!r}")
    safe = p.as_posix()
    if not safe or safe == ".":
        raise BacklogError("path is required")
    return safe


def _resolve_target(
    project_path: str, rel: str, backlog_dir: str, extra_globs: tuple[str, ...] | list[str]
) -> tuple[str, Path]:
    """Shared guard for every backlog write: normalize + validate ``rel``, resolve
    it under ``project_path``, and confirm the resolved path really stays inside the
    project (defense in depth against a symlinked parent resolving out of the tree).
    Returns ``(safe_rel, absolute_target)`` or raises ``BacklogError``."""
    safe = _safe_rel(rel)
    if not is_backlog_path(safe, backlog_dir, extra_globs):
        raise BacklogError(
            f"{safe!r} is not a backlog file: put it under {backlog_dir}/, "
            "give it a name containing 'todo', or match a configured [backlog] files glob"
        )
    root = Path(project_path).resolve()
    target = (root / safe).resolve()
    if root != target and root not in target.parents:
        raise BacklogError(f"path escapes the project: {rel!r}")
    return safe, target


def write_todo(
    project_path: str,
    rel: str,
    content: str,
    *,
    backlog_dir: str = "backlog",
    extra_globs: tuple[str, ...] | list[str] = (),
) -> str:
    """Write ``content`` to the backlog file ``rel`` (repo-relative) under
    ``project_path``, creating it (and any parent folder like ``backlog/``) if new.
    Guarded: the path must stay inside the project and be backlog-eligible. Returns
    the normalized repo-relative path actually written.

    A trailing newline is ensured so the file is a well-formed text doc, and the
    parent directory is created so "new file in ``backlog/``" works on a repo that
    doesn't have the folder yet."""
    safe, target = _resolve_target(project_path, rel, backlog_dir, extra_globs)
    if not content.endswith("\n"):
        content += "\n"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    return safe


def append_item(
    project_path: str,
    rel: str,
    title: str,
    evidence: str = "",
    *,
    backlog_dir: str = "backlog",
    extra_globs: tuple[str, ...] | list[str] = (),
) -> str:
    """Append one follow-up item to a backlog file, creating it (with a heading) if
    it doesn't exist yet. The gate's own residue outlet (backlog-redesign-plan.md
    Move 3): a failing test you decide to defer, a mutation survivor, an untested
    hunk, a refuter finding, a review comment — each becomes one
    ``- [ ] <title> (<evidence>)`` line here instead of the only outlet today being
    "send to agent" (re-tasking the CURRENT agent, not queuing follow-up work).
    Same guards as ``write_todo``, so this can never write outside a backlog-eligible
    path. Returns the normalized repo-relative path written to."""
    safe, target = _resolve_target(project_path, rel, backlog_dir, extra_globs)
    title = " ".join(title.split())  # collapse embedded newlines/whitespace to one line
    evidence = " ".join(evidence.split())
    line = f"- [ ] {title}" + (f" ({evidence})" if evidence else "")
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        existing = target.read_text(encoding="utf-8")
        if existing and not existing.endswith("\n"):
            existing += "\n"
        new_text = existing + line + "\n"
    else:
        heading = safe.rsplit("/", 1)[-1].rsplit(".", 1)[0].replace("-", " ").replace("_", " ")
        new_text = f"# {heading.strip().title() or 'Follow-ups'}\n\n{line}\n"
    target.write_text(new_text, encoding="utf-8")
    return safe


def parse_todo_doc(text: str) -> list[dict]:
    """Parse a backlog markdown file into an ordered list of *blocks*, so the UI can
    render notes and tasks interleaved in document order. Two block kinds:

      ``{"kind": "note", "md": <raw markdown>}`` — headings, prose, links, any
        non-task context. Purely display; never seedable. This is the context the
        older items-only parser dropped: keeping it lets a backlog file double as a
        notes doc without forcing every line to be a checkbox.
      ``{"kind": "item", "heading", "text", "body", "done"}`` — a GitHub-style
        ``- [ ]`` / ``- [x]`` task, the seedable unit.

    A task-list item is a *block*, not a single line: markdown lets its text wrap
    onto indented continuation lines (CommonMark "lazy continuation"). We fold those
    back into the item so a wrapped item isn't truncated at its first line-break. A
    blank line, a heading, or a new list marker ends the item. Each item carries two
    views of its content:
      ``text`` — compact one-paragraph prose (continuation folded with spaces,
        fenced code stripped) for the checklist display + the short branch name.
      ``body`` — the full item verbatim (continuation + fenced ``` blocks, newlines
        preserved, dedented) — the brief handed to an agent when a todo is clicked,
        so a "see this example:" item keeps its example."""
    blocks: list[dict] = []
    heading: str | None = None
    current: dict | None = None  # the item currently accreting continuation lines
    note: list[str] = []  # consecutive non-item lines awaiting a flush into a note block
    in_fence = False  # inside a ``` fenced block → don't fold lines into text

    def flush_note() -> None:
        # Emit the buffered lines as one markdown note, trimming surrounding blanks
        # but keeping internal structure. A whitespace-only buffer emits nothing.
        while note and not note[0].strip():
            note.pop(0)
        while note and not note[-1].strip():
            note.pop()
        if note:
            blocks.append({"kind": "note", "md": "\n".join(note)})
        note.clear()

    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("```"):
            in_fence = not in_fence
            (current["_body"] if current is not None else note).append(raw)
            continue
        if in_fence:
            (current["_body"] if current is not None else note).append(raw)
            continue
        if line.startswith("#"):
            label = line.lstrip("#").strip()
            if label:
                heading = label
            current = None
            note.append(raw)  # headings render as note markdown
            continue
        marker = next((p for p in ("- ", "* ", "+ ") if line.startswith(p)), None)
        if marker is not None:
            rest = line[len(marker) :]
            if len(rest) >= 3 and rest[0] == "[" and rest[2] == "]":
                flush_note()  # notes preceding the item render before it
                current = {
                    "kind": "item",
                    "heading": heading,
                    "text": rest[3:].strip(),
                    "done": rest[1] in ("x", "X"),
                    "_body": [rest[3:].strip()],
                }
                blocks.append(current)
            else:
                current = None  # a plain (non-checkbox) bullet is prose/notes
                note.append(raw)
            continue
        # Not a marker line. An indented, non-blank line continues the current
        # item's text; a blank line (or unindented prose) closes it out into notes.
        if current is not None and line and raw[:1].isspace():
            current["text"] = (current["text"] + " " + line).strip()
            current["_body"].append(raw)
        else:
            current = None
            note.append(raw)
    flush_note()
    # Finalize each item's ``body``: dedent the continuation lines by their common
    # indent so code examples keep their relative shape, and drop the scratch key.
    for b in blocks:
        if b["kind"] == "item":
            b["body"] = dedent_block(b.pop("_body"))
    return blocks


def parse_todo(text: str) -> list[dict]:
    """The backlog's task items only (headings/prose dropped) — the shape the
    click-to-workspace flow depends on. See ``parse_todo_doc`` for the full ordered
    document (notes + items) the backlog UI now renders."""
    return [b for b in parse_todo_doc(text) if b["kind"] == "item"]


def dedent_block(lines: list[str]) -> str:
    """Join an item's raw lines into its ``body``. The first line (the item text)
    is already unindented; the rest share a hanging indent — strip their common
    leading whitespace so a fenced code example keeps its internal indentation
    without the markdown hanging-indent bleeding in."""
    if not lines:
        return ""
    head, *rest = lines
    indents = [len(l) - len(l.lstrip()) for l in rest if l.strip()]
    n = min(indents) if indents else 0
    body = [head] + [l[n:] if len(l) >= n else l.lstrip() for l in rest]
    return "\n".join(body).strip()


def _tick_item_text(text: str, target_text: str) -> tuple[str, bool]:
    """Flip the first not-yet-done ``- [ ]`` item whose folded ``text`` (see
    ``parse_todo_doc``) matches ``target_text`` to ``- [x]``, in place, preserving
    everything else byte-for-byte. Returns ``(new_text, ticked)``; ``ticked`` is
    False (and ``new_text is text``) when nothing matched — a renamed, already-done,
    or already-ticked item is a no-op, not an error."""
    items = [b for b in parse_todo_doc(text) if b["kind"] == "item"]
    match_idx = next(
        (i for i, b in enumerate(items) if not b["done"] and b["text"] == target_text), None
    )
    if match_idx is None:
        return text, False
    lines = text.splitlines(keepends=True)
    count = -1
    in_fence = False  # mirror parse_todo_doc: a ``` fence hides checkbox-looking
    # lines inside an example from counting as real items — without this, a
    # `- [ ]` shown as markdown *inside* a fenced code example (a real backlog file
    # can absolutely contain one, e.g. a doc explaining the checklist syntax) would
    # be counted as an item by this raw re-scan but NOT by parse_todo_doc, so the
    # two counters disagree and the wrong line gets ticked.
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        lstripped = raw.lstrip()
        marker = next((p for p in ("- ", "* ", "+ ") if lstripped.startswith(p)), None)
        if marker is None:
            continue
        rest = lstripped[len(marker):]
        if not (len(rest) >= 3 and rest[0] == "[" and rest[2] == "]"):
            continue
        count += 1
        if count == match_idx:
            box_pos = len(raw) - len(lstripped) + len(marker) + 1
            lines[i] = raw[:box_pos] + "x" + raw[box_pos + 1:]
            return "".join(lines), True
    return text, False  # parsed as a match but the raw re-scan didn't find it (shouldn't happen)


def tick_backlog_item(
    project_path: str,
    seed_key: str | None,
    backlog_dir: str = "backlog",
    extra_globs: tuple[str, ...] | list[str] = (),
) -> bool:
    """Best-effort write-back companion to ``Closes #n`` (integrate.py): once a
    todo-seeded workspace's work has merged, flip its source line's checkbox in the
    seed file itself, the same way a GitHub issue gets closed by the merge. Matches
    by the item's text (same rule ``BACKLOG_TICK`` gives the agent), so a since-
    edited item is left alone rather than ticking the wrong line. Never raises: a
    missing file, a renamed item, or a write failure must not undo an already-
    successful merge — ``BACKLOG_TICK`` remains the belt-and-braces fallback.

    Called from every merge path (the manual merge endpoint, the merge queue, and
    the autonomy ladder's auto-merge rung) so none of them can silently skip it."""
    if not seed_key or seed_key.startswith("issue:") or "::" not in seed_key:
        return False
    rel, _, target_text = seed_key.partition("::")
    if not is_backlog_path(rel, backlog_dir, extra_globs):
        return False
    path = Path(project_path) / rel
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    new_text, ticked = _tick_item_text(text, target_text)
    if not ticked:
        return False
    try:
        path.write_text(new_text, encoding="utf-8")
    except OSError:
        return False
    return True
