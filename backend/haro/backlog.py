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
    Move 3): a failing test you decide to defer, an untested
    hunk, a code reviewer finding, a review comment — each becomes one
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


def _subtree_ends(items: list[dict], lines: list[str]) -> list[int]:
    """For each item, the index of the last item in its subtree: the items after it that are
    indented deeper, as long as only blank lines sit between one member and the next (a
    heading or prose ends the family). An item with no sub-items ends at itself."""
    last = list(range(len(items)))
    for i, me in enumerate(items):
        end = me["end"]
        for j in range(i + 1, len(items)):
            it = items[j]
            if it["indent"] <= me["indent"] or any(l.strip() for l in lines[end : it["line"]]):
                break
            end = it["end"]
            last[i] = j
    return last


def _parents(last: list[int]) -> list[int | None]:
    """Each item's parent: the nearest earlier item whose family contains it, else None."""
    out: list[int | None] = []
    for i in range(len(last)):
        out.append(next((k for k in range(i - 1, -1, -1) if last[k] >= i), None))
    return out


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

    for n, raw in enumerate(text.splitlines()):
        line = raw.strip()
        if line.startswith("```"):
            in_fence = not in_fence
            if current is not None:
                current["_body"].append(raw)
                current["end"] = n + 1
            else:
                note.append(raw)
            continue
        if in_fence:
            if current is not None:
                current["_body"].append(raw)
                current["end"] = n + 1
            else:
                note.append(raw)
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
                    "line": n,  # [line, end) in the file's own lines, for item-level edits
                    "end": n + 1,
                    "indent": len(raw[: len(raw) - len(raw.lstrip())].expandtabs(4)),  # columns
                    "lead": len(raw) - len(raw.lstrip()),  # characters, for slicing the line
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
            current["end"] = n + 1
        else:
            current = None
            note.append(raw)
    flush_note()
    # Finalize each item's ``body``: dedent the continuation lines by their common
    # indent so code examples keep their relative shape, and drop the scratch key.
    for b in blocks:
        if b["kind"] == "item":
            b["body"] = dedent_block(b.pop("_body"))
    its = [b for b in blocks if b["kind"] == "item"]
    last = _subtree_ends(its, text.splitlines())
    for i, b in enumerate(its):
        b["children"] = last[i] - i
        b["depth"] = sum(1 for k in range(i) if i <= last[k])
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


# ---------------------------------------------------------------------------------------
# Item-level edits (the Backlog page): check, edit, delete, reorder, move to another file.
#
# An item is addressed by its position among the file's items plus the ``text`` the caller
# saw. Agents and the merge tick write these same files, so a position alone could land on a
# different item after they add or remove one; a text that no longer matches raises
# ``StaleItem`` (the route answers 409 and the client reloads) instead of editing the wrong
# line. Every function takes and returns text, so the file I/O stays in ``apply_item_op``.
# ---------------------------------------------------------------------------------------


class StaleItem(BacklogError):
    """The item at that position is no longer the one the caller saw."""


def _items(text: str) -> list[dict]:
    return [b for b in parse_todo_doc(text) if b["kind"] == "item"]


def _find(text: str, index: int, expect: str) -> tuple[list[str], dict]:
    items = _items(text)
    if not (0 <= index < len(items)) or items[index]["text"] != expect:
        raise StaleItem("the backlog changed since it was loaded; reloaded")
    return text.splitlines(keepends=True), items[index]


def _nl(lines: list[str]) -> list[str]:
    """Every line ends in a newline, so a block moved off the end of a file cannot glue onto
    the next line."""
    return [l if l.endswith("\n") else l + "\n" for l in lines]


def _format_item(done: bool, body: str, indent: str = "", marker: str = "- ") -> list[str]:
    """An item as file lines: the first line of ``body`` after the checkbox, the rest as
    hanging continuation lines. Blank lines survive only inside a ``` fence, since a blank
    line anywhere else would end the item."""
    rows = body.strip().splitlines()
    if not rows or not rows[0].strip():
        raise BacklogError("an item needs some text")
    out = [f"{indent}{marker}[{'x' if done else ' '}] {rows[0].strip()}\n"]
    in_fence = False
    for r in rows[1:]:
        if r.strip().startswith("```"):
            in_fence = not in_fence
        if not r.strip() and not in_fence:
            continue
        out.append(f"{indent}  {r}\n" if r.strip() else "\n")
    if in_fence:  # an open fence would swallow every item after this one
        out.append(f"{indent}  ```\n")
    return out


def set_done(text: str, index: int, expect: str, done: bool) -> str:
    lines, item = _find(text, index, expect)
    raw = lines[item["line"]]
    lstripped = raw.lstrip()
    marker = next(p for p in ("- ", "* ", "+ ") if lstripped.startswith(p))
    pos = len(raw) - len(lstripped) + len(marker) + 1
    lines[item["line"]] = raw[:pos] + ("x" if done else " ") + raw[pos + 1 :]
    return "".join(lines)


def edit_item(text: str, index: int, expect: str, body: str) -> str:
    lines, item = _find(text, index, expect)
    raw = lines[item["line"]]
    lstripped = raw.lstrip()
    marker = next(p for p in ("- ", "* ", "+ ") if lstripped.startswith(p))
    indent = raw[: len(raw) - len(lstripped)]
    new = _format_item(item["done"], body, indent, marker)
    lines[item["line"] : item["end"]] = new
    return "".join(lines)


def delete_item(text: str, index: int, expect: str) -> str:
    """Delete an item and its sub-items (leaving them would re-parent them to the item above)."""
    lines, item = _find(text, index, expect)
    last = _subtree_ends(_items(text), [l.rstrip("\r\n") for l in lines])[index]
    end = _items(text)[last]["end"]
    del lines[item["line"] : end]
    return "".join(lines)


def move_item(text: str, index: int, expect: str, delta: int) -> str:
    """Move an item with its sub-items one place up (``delta`` -1) or down (+1) among its
    siblings (same indent, same parent). Next to a neighbour with only blank lines between,
    the two swap. With a heading or prose between, the item crosses to the end of the previous
    section (up) or the start of the next (down) without taking the heading with it. With no
    sibling in that direction nothing changes."""
    lines, item = _find(text, index, expect)
    items = _items(text)
    last = _subtree_ends(items, [l.rstrip("\r\n") for l in lines])
    me_end = items[last[index]]["end"]
    parent = _parents(last)
    me_parent = parent[index]

    def sibling(j: int) -> bool:
        return parent[j] == me_parent and items[j]["indent"] == item["indent"]

    if delta < 0:
        j = next((k for k in range(index - 1, -1, -1) if sibling(k)), None)
        if j is None:
            return text
        o_start, o_end = items[j]["line"], items[last[j]]["end"]
        between = lines[o_end : item["line"]]
        at = o_start if not any(l.strip() for l in between) else o_end
    else:
        j = next((k for k in range(last[index] + 1, len(items)) if sibling(k)), None)
        if j is None:
            return text
        o_start, o_end = items[j]["line"], items[last[j]]["end"]
        between = lines[me_end : o_start]
        at = o_end if not any(l.strip() for l in between) else o_start
    block = _nl(lines[item["line"] : me_end])
    rest = _nl(lines[: item["line"]] + lines[me_end :])  # no glued lines at a bare end of file
    if at > item["line"]:
        at -= me_end - item["line"]
    rest[at:at] = block
    return "".join(rest)


def take_item(text: str, index: int, expect: str) -> list[str]:
    """An item with its sub-items as file lines, dedented so the item sits at the top level
    (for appending to another file)."""
    lines, item = _find(text, index, expect)
    last = _subtree_ends(_items(text), [l.rstrip("\r\n") for l in lines])[index]
    end = _items(text)[last]["end"]
    pad = item["lead"]
    rows = [l.rstrip("\r\n") for l in lines[item["line"] : end]]  # LF in the destination file
    return _nl([l[pad:] if l[:pad].strip() == "" else l.lstrip() for l in rows])


def _append_lines(project_path: str, rel: str, rows: list[str], backlog_dir: str, extra_globs) -> str:
    safe, target = _resolve_target(project_path, rel, backlog_dir, extra_globs)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        try:
            existing = target.read_text(encoding="utf-8")
        except UnicodeDecodeError as e:
            raise BacklogError(f"could not read {safe}: {e}") from e
        if existing and not existing.endswith("\n"):
            existing += "\n"
        new_text = existing + "".join(rows)
    else:
        heading = safe.rsplit("/", 1)[-1].rsplit(".", 1)[0].replace("-", " ").replace("_", " ")
        new_text = f"# {heading.strip().title() or 'Backlog'}\n\n" + "".join(rows)
    target.write_text(new_text, encoding="utf-8")
    return safe


def apply_item_op(
    project_path: str,
    rel: str,
    op: str,
    index: int,
    expect: str,
    *,
    body: str | None = None,
    to_rel: str | None = None,
    backlog_dir: str = "backlog",
    extra_globs: tuple[str, ...] | list[str] = (),
) -> dict:
    """Read the file, apply one item operation, write it back. Same path guards as
    ``write_todo``. Returns ``{"path", "text", "to"}``: ``text`` is the item's text after an
    edit (for re-pointing a seeded workspace), ``to`` the destination of a ``move``."""
    safe, target = _resolve_target(project_path, rel, backlog_dir, extra_globs)
    try:
        text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise BacklogError(f"could not read {rel}: {e}") from e
    result: dict = {"path": safe, "text": expect, "to": None}
    if op in ("check", "uncheck"):
        new = set_done(text, index, expect, op == "check")
    elif op == "edit":
        new = edit_item(text, index, expect, body or "")
        result["text"] = _items(new)[index]["text"]
    elif op == "delete":
        new = delete_item(text, index, expect)
    elif op in ("up", "down"):
        new = move_item(text, index, expect, -1 if op == "up" else 1)
    elif op == "move":
        if not to_rel:
            raise BacklogError("choose a file to move it to")
        dest, dest_target = _resolve_target(project_path, to_rel, backlog_dir, extra_globs)
        if dest == safe or (dest_target.exists() and target.samefile(dest_target)):
            return result  # the same file under another spelling (case-insensitive disk, symlink)
        rows = take_item(text, index, expect)
        # Written to the destination first: a failure leaves the item in both files, never in none.
        _append_lines(project_path, dest, rows, backlog_dir, extra_globs)
        new = delete_item(text, index, expect)
        result["to"] = dest
    else:
        raise BacklogError(f"unknown operation {op!r}")
    target.write_text(new, encoding="utf-8")
    return result


def rename_todo(
    project_path: str,
    rel: str,
    new_rel: str,
    *,
    backlog_dir: str = "backlog",
    extra_globs: tuple[str, ...] | list[str] = (),
) -> tuple[str, str]:
    """Rename a backlog file; the new name must also be backlog-eligible and free."""
    old, src = _resolve_target(project_path, rel, backlog_dir, extra_globs)
    new, dst = _resolve_target(project_path, new_rel, backlog_dir, extra_globs)
    if not src.is_file():
        raise BacklogError(f"{rel} does not exist")
    if old == new:
        return old, new
    if dst.exists():
        raise BacklogError(f"{new} already exists")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)
    return old, new
