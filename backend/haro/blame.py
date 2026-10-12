"""Failure → blame — the reverse of the Impact Map.

The Impact Map answers "which tests does this diff touch?". Blame answers the
inverse for a *red* test: "which changed lines are most likely responsible?".

The mechanism is deliberately simple and honest: parse a failing test's stack
for source locations (``file:line`` frames) and intersect them with the lines
the diff actually changed vs ``base_ref``. A frame landing exactly on a changed
line is a strong, legible signal — "you changed foo.ts:42 and the failure runs
through it". When no frame hits a changed line but the stack still passes through
a changed file, we degrade to a file-level attribution rather than guess a line.

Pure functions only (no IO) so the matching logic is unit-testable — the endpoint
in ``main.py`` supplies the diff text and the failing cases.
"""

from __future__ import annotations

import re

# A source location in a stack: a path ending in an extension, then ``:line``.
# Matches ``src/math.ts:5``, ``/abs/wt/src/math.ts:5:19``, ``math.test.ts:5``.
# Won't match assertion prose ("expected 3 to be 4") — no ``.ext:number``.
_FRAME_RE = re.compile(r"([\w./\\-]+\.[a-zA-Z]+):(\d+)")

_MAX_HUNKS = 6  # keep the UI tidy — the first few implicated lines are what matter


def parse_frames(text: str | None) -> list[tuple[str, int]]:
    """Extract ``(path, line)`` frames from a failure stack, first-seen order, deduped."""
    if not text:
        return []
    out: list[tuple[str, int]] = []
    seen: set[tuple[str, int]] = set()
    for m in _FRAME_RE.finditer(text):
        frame = (m.group(1), int(m.group(2)))
        if frame not in seen:
            seen.add(frame)
            out.append(frame)
    return out


def changed_lines(diff_text: str) -> dict[str, dict[int, str]]:
    """Parse a unified diff into ``{path: {new_line_number: added_text}}``.

    Only *added* (new-side) lines are recorded, keyed by their line number in the
    post-change file — that's what a stack frame in the current worktree points at.
    """
    out: dict[str, dict[int, str]] = {}
    cur: dict[int, str] | None = None
    newno = 0
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            path = line[4:].strip()
            # git prints ``+++ b/<path>`` (or ``/dev/null`` for a deletion).
            if path.startswith("b/"):
                path = path[2:]
            cur = None if path == "/dev/null" else out.setdefault(path, {})
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)  # the new-side start line of the hunk
            newno = int(m.group(1)) if m else 0
        elif cur is None:
            continue
        elif line.startswith("+") and not line.startswith("+++"):
            cur[newno] = line[1:]
            newno += 1
        elif line.startswith("-") and not line.startswith("---"):
            pass  # a deletion consumes no new-side line number
        elif not line.startswith("\\"):  # context (incl. blank); "\ No newline" doesn't count
            newno += 1
    return out


def _match_changed_file(fpath: str, changed: dict[str, dict[int, str]]) -> str | None:
    """Find the changed file a stack frame's path refers to (longest suffix match).

    Frames carry absolute or worktree-relative paths; the diff keys are repo-relative.
    """
    p = fpath.replace("\\", "/")
    best: str | None = None
    best_len = -1
    for cp in changed:
        c = cp.replace("\\", "/")
        if (p == c or p.endswith("/" + c)) and len(c) > best_len:
            best, best_len = cp, len(c)
    return best


def blame_message(text: str | None, changed: dict[str, dict[int, str]]) -> list[dict]:
    """The changed lines a failure's stack implicates, most-specific first.

    Returns line-level hunks (``{file, line, code}``) when frames land on changed
    lines; otherwise a file-level fallback (``line``/``code`` None) for any changed
    file the stack passed through. Empty when the stack touches nothing changed.
    """
    frames = parse_frames(text)
    if not frames or not changed:
        return []
    hunks: list[dict] = []
    seen: set[tuple[str, int]] = set()
    files_hit: list[str] = []
    for fpath, line in frames:
        cf = _match_changed_file(fpath, changed)
        if cf is None:
            continue
        if cf not in files_hit:
            files_hit.append(cf)
        lines = changed[cf]
        if line in lines and (cf, line) not in seen:
            seen.add((cf, line))
            hunks.append({"file": cf, "line": line, "code": lines[line].strip() or None})
    if hunks:
        return hunks[:_MAX_HUNKS]
    return [{"file": cf, "line": None, "code": None} for cf in files_hit[:_MAX_HUNKS]]
