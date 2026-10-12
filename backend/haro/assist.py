"""Manual-rail assist runs: a read-only Claude Code job that plans or researches, never edits.

In manual mode the dev writes every line; the AI may only point. That promise is enforced
structurally, in three layers, so no prompt has to be trusted:

1. **Tool whitelist.** The CLI is started with ``--tools Read Grep Glob WebFetch WebSearch``
   (the built-in tool set is *replaced*, so Bash/Edit/Write/MultiEdit/NotebookEdit/Task do not
   exist for the run), the same tools pre-approved, the editing tools also listed under
   ``--disallowedTools``, and ``--permission-mode dontAsk`` so anything that would prompt is
   denied. Never ``bypassPermissions`` (the agent runner uses that; an assist run must not).
   MCP servers are off (``--strict-mcp-config``), so no third-party tool can write either.
2. **Event tripwire.** A ``file_edit`` event, or a tool call outside the whitelist, kills the
   run at once.
3. **Git guard.** ``git status`` plus HEAD (and a fingerprint of every dirty file) is
   snapshotted before and after; any difference fails the job loudly and is logged. Files the
   dev saved through haro during the run are excused, since the dev is allowed to keep coding
   while the assistant thinks. Edits made in a terminal or the git panel during a run can trip
   the guard, which is why the message says so. Gitignored paths are not covered (status does
   not list them); the tool whitelist is what covers those.

"Pointers, never code" is likewise deterministic: ``strip_code_fences`` replaces every fenced
block in the model's output with ``CODE_REMOVED`` before it is stored or shown. Inline code
spans (identifiers, paths) stay.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Awaitable, Callable

from . import files as filesvc
from . import git_ops
from . import research as research_svc
from . import runner
from . import sandbox as sandbox_mod
from .adapters.base import NormalizedEvent
from .adapters.claude_code import ClaudeCodeAdapter, _STREAM_LIMIT
from .models import ManualPlan, PlanStep, ResearchRow
from .procs import terminate_tree
from .review import _extract_json_object

log = logging.getLogger(__name__)

READ_ONLY_TOOLS = ("Read", "Grep", "Glob", "WebFetch", "WebSearch")
DENIED_TOOLS = ("Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task", "Agent", "PowerShell")
CODE_REMOVED = "(code removed: haro points, you write)"
VIOLATION = "the assistant changed files: this should be impossible"
JOB_TIMEOUT_S = 600
#: A source target longer than this is dropped, not cut: a truncated link points nowhere.
MAX_TARGET_LEN = 500
_HASH_CAP = 256 * 1024 * 1024

PLAN_SYSTEM = (
    "You are haro's planning assistant. The developer writes all the code by hand; you only "
    "plan. You may read the repository with your read-only tools. You cannot edit files.\n"
    "Reply in exactly this shape and nothing else:\n"
    "TITLE: <at most 8 words>\n"
    "1. <one concrete step, one sentence, naming the files or functions to look at>\n"
    "2. ...\n"
    "WHY THIS ORDER: <one short line>\n"
    "Rules: 3 to 10 steps. No code blocks, no snippets beyond an identifier or path in inline "
    "backticks. Ask no questions back. Never offer to write or change code."
)

ASK_SYSTEM = (
    "You are haro's research assistant. Point the developer to where to look; never write code "
    "for them. Use your read-only tools to search the repository, and the web only for outside "
    "libraries. You cannot edit files.\n"
    "Reply with a single JSON object and nothing else:\n"
    '{"answer": "<at most 2 short sentences>", "sources": [{"kind": "repo|git|doc|web|man", '
    '"title": "<short>", "target": "<path or path:line | commit sha | https url | man:page>", '
    '"why": "<one short line>"}]}\n'
    "Rules: 1 to 6 sources. repo targets must be real paths in this repository. A manual page "
    "is cited as man:<page>, for example man:ls(1), and only when it exists on this machine. "
    "No code blocks, no snippets beyond an identifier or path in inline backticks."
)


# ---------------------------------------------------------------------- output hygiene
_FENCE_OPEN = re.compile(r"^(?P<indent>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_RUN = re.compile(r"`{3,}")
_INDENTED = re.compile(r"^(?: {4,}|\t)\S")


def _scan_inline(line: str) -> tuple[str, str | None]:
    """Replace triple-backtick spans that open mid-line. A span that closes on the same line
    is swapped for the marker in place; one that does not swallows the rest of the line and
    is returned as the fence still open."""
    pos = 0
    out: list[str] = []
    while True:
        m = _RUN.search(line, pos)
        if m is None:
            out.append(line[pos:])
            return "".join(out), None
        n = len(m.group())
        close = next((c for c in _RUN.finditer(line, m.end()) if len(c.group()) >= n), None)
        out.append(line[pos : m.start()])
        out.append(CODE_REMOVED)
        if close is None:
            return "".join(out), m.group()
        pos = close.end()


def strip_code_fences(text: str) -> str:
    """Replace every fenced code block with ``CODE_REMOVED``. An unclosed fence swallows the
    rest of the text (a truncated reply must not leak its code). A fence opened mid-line
    ("1. Add ``` then code ```") is handled too: it closes at the next run of backticks
    anywhere, and only the code is dropped, so later steps survive. Deterministic: same
    input, same output, no model in the loop."""
    out: list[str] = []
    fence: str | None = None
    inline = False
    for line in text.splitlines():
        if fence is not None:
            if inline:
                close = next((c for c in _RUN.finditer(line) if len(c.group()) >= len(fence)), None)
                if close is None:
                    continue
                fence, inline = None, False
                line = line[close.end() :]
                if not line.strip():
                    continue
            else:
                stripped = line.strip()
                if stripped and set(stripped) == {fence[0]} and len(stripped) >= len(fence):
                    fence = None
                continue
        m = _FENCE_OPEN.match(line)
        if m and not (m["fence"][0] == "`" and "`" in m["info"]):
            out.append(f"{m['indent']}{CODE_REMOVED}")
            fence = m["fence"]
            continue
        replaced, opened = _scan_inline(line)
        out.append(replaced)
        if opened is not None:
            fence, inline = opened, True
    return "\n".join(out)


def strip_indented_code(text: str) -> str:
    """Replace 4-space and tab indented code blocks with ``CODE_REMOVED``.

    An indented line directly under a list item (no blank line between) is that item's
    prose: a hanging-indent continuation or a sub-bullet, and it stays for ``parse_plan`` to
    fold into the step. Only an indented block that a blank line separates from the item
    above it (or that follows no item at all) is code. Runs before plan parsing so step text
    never carries the code CommonMark would render as a block."""
    out: list[str] = []
    attached = False
    last_was_marker = False
    for line in text.splitlines():
        if not line.strip():
            attached = False
            out.append(line)
            continue
        indented = bool(_INDENTED.match(line))
        is_step = bool(_STEP.match(line))
        if indented and CODE_REMOVED not in line:
            if attached or is_step:
                out.append(line)
                last_was_marker = False
                continue
            if not last_was_marker:
                out.append(CODE_REMOVED)
            last_was_marker = True
            continue
        if is_step:
            attached = True
        elif not line.startswith(" "):
            attached = False
        last_was_marker = CODE_REMOVED in line
        out.append(line)
    return "\n".join(out)


def clean_field(text: str, cap: int = 200) -> str:
    """A model-written title or reason as one line of prose: fences and indented code out,
    line breaks collapsed."""
    plain = strip_indented_code(strip_code_fences(text))
    return _clip(re.sub(r"\s+", " ", plain).strip(), cap)


def _clip(text: str, cap: int) -> str:
    """Shorten to ``cap`` without cutting a word: end at the last full sentence when one ends
    in the back half, else at the last space with an ellipsis."""
    if len(text) <= cap:
        return text
    cut = text[:cap]
    end = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
    if end >= cap // 2:
        return cut[: end + 1]
    space = cut.rfind(" ")
    return (cut[:space] if space > 0 else cut).rstrip(",;:") + "…"


_STEP = re.compile(r"^\s*(?:\d+[.)]|[-*])\s+(?P<text>\S.*)$")
_TITLE = re.compile(r"^\s*(?:#+\s*|\*\*)?\s*title\s*:?\**\s*:?\s*(?P<t>.*?)\**\s*$", re.I)
_WHY = re.compile(r"^\s*(?:[*_#]+\s*)?why this order(?:[*_]*)\s*[:\-]?\s*(?:[*_]*)\s*(?P<t>.*)$", re.I)


def _clean_step(s: str) -> str:
    s = re.sub(r"^\[[ xX]\]\s*", "", s.strip())
    return re.sub(r"\s+", " ", s.replace("**", "")).strip()


def _indent(line: str) -> int:
    return len(line.expandtabs(4)) - len(line.expandtabs(4).lstrip(" "))


def parse_plan(text: str, prompt: str = "") -> tuple[str, list[str], str]:
    """``(title, steps, why)`` from the plan reply. Tolerant of bullets and bold; a missing
    title falls back to the prompt's first line. Zero steps is the caller's error to report.

    A step's text is its own line plus what is attached to it: indented prose directly below
    (any indent, so a hanging indent under "10." works) and sub-bullets, which fold in as
    "step: a; b" instead of becoming steps of their own. A blank line ends the attachment."""
    title = ""
    why = ""
    steps: list[str] = []
    in_why = False
    attached = False
    subs = 0
    base_indent: int | None = None
    for line in text.splitlines():
        if not line.strip():
            in_why = False
            attached = False
            continue
        w = _WHY.match(line)
        if w:
            why = w["t"].replace("**", "").strip()
            in_why = not why
            attached = False
            continue
        if in_why:
            why = line.replace("**", "").strip()
            in_why = False
            continue
        t = _TITLE.match(line)
        if t and not steps and not title and t["t"]:
            title = t["t"].strip()
            continue
        s = _STEP.match(line)
        if s:
            indent = _indent(line)
            if base_indent is None:
                base_indent = indent
            if steps and indent >= base_indent + 2:
                piece = _clean_step(s["text"])
                if piece:
                    steps[-1] += (" " if subs == 0 else "; ") + piece
                    subs += 1
                attached = True
                continue
            steps.append(_clean_step(s["text"]))
            subs = 0
            attached = True
            continue
        if steps and attached and not why and line[0] in " \t":
            steps[-1] = _clean_step(f"{steps[-1]} {line}")
            continue
        attached = False
    steps = [s for s in steps if s]
    if not title:
        first = next((ln.strip() for ln in prompt.splitlines() if ln.strip()), "Plan")
        title = first[:60].rstrip()
    return title[:80], steps, why


def parse_research(text: str) -> tuple[str, list[dict[str, str]]]:
    """``(answer, raw_sources)`` from the ``ask`` reply. Falls back to the plain text as the
    answer when the model ignored the JSON contract."""
    try:
        obj = json.loads(_extract_json_object(text, ("answer", "sources")))
    except (json.JSONDecodeError, ValueError):
        obj = None
    if not isinstance(obj, dict):
        return strip_code_fences(text).strip()[:400], []
    answer = clean_field(str(obj.get("answer") or ""), 400)
    raw = obj.get("sources")
    sources = [
        {
            "kind": str(v.get("kind") or "").strip(),
            "target": str(v.get("target") or "").strip(),
            "title": clean_field(str(v.get("title") or "")),
            "why": clean_field(str(v.get("why") or "")),
        }
        for v in (raw if isinstance(raw, list) else [])
        if isinstance(v, dict)
    ]
    return answer, sources


_TARGET_LINE = re.compile(r"^(?P<path>.+?)(?::(?P<line>\d+))?$")
_SHA = re.compile(r"^[0-9a-f]{7,40}$", re.I)


async def verify_sources(
    worktree: str,
    sources: list[dict[str, str]],
    kept_shas: set[str] | None = None,
) -> tuple[list[ResearchRow], int]:
    """Turn the model's claimed sources into rows, dropping any that point at nothing: a repo
    path that does not exist, a commit that is not in this repo, a link that is not http(s),
    a man page this machine does not have.
    A pointer that cannot be followed is worse than no pointer. ``kept_shas``, when given,
    collects the (hex) commit ids of the git sources that survived."""
    rows: list[ResearchRow] = []
    dropped = 0
    for src in sources[:6]:
        kind, title, target, why = src["kind"].lower(), src["title"], src["target"], src["why"]
        row: ResearchRow | None = None
        if len(target) > MAX_TARGET_LEN:
            dropped += 1
            continue
        if kind == "repo":
            m = _TARGET_LINE.match(target)
            if m and _is_file(worktree, m["path"]):
                row = ResearchRow(source="repo", title=title or target, target=target, why=why, action="jump")
        elif kind == "git":
            row = await _git_row(worktree, target, title, why)
            if row is not None and kept_shas is not None:
                kept_shas.add(target.strip().lower())
        elif kind == "man" or target.lower().startswith("man:"):
            page = re.sub(r"^man:\s*", "", target, flags=re.I).strip()
            if await research_svc.man_exists(page):
                row = ResearchRow(
                    source="man", title=title or page, target=page, why=why, action="read"
                )
        elif kind in ("doc", "web") and re.match(r"^https?://", target, re.I):
            row = ResearchRow(
                source="web" if kind == "web" else "doc", title=title or target,
                target=target, why=why, action="open",
            )
        if row is None:
            dropped += 1
        else:
            rows.append(row)
    return rows, dropped


def _is_file(worktree: str, rel: str) -> bool:
    try:
        return filesvc.safe_path(worktree, rel).is_file()
    except (ValueError, OSError):
        return False


async def _git_row(worktree: str, target: str, title: str, why: str) -> ResearchRow | None:
    sha = target.strip()
    if not _SHA.match(sha):
        return None
    try:
        out = await git_ops._git(
            "show", "--no-color", "--name-only", "--format=%h %s", sha, cwd=worktree
        )
    except git_ops.GitError:
        return None
    head, _, tail = out.partition("\n")
    path = next((n.strip() for n in tail.splitlines() if n.strip() and _is_file(worktree, n.strip())), None)
    if path is None:
        return None
    return ResearchRow(source="git", title=title or head, target=path, why=why or head, action="jump")


# ---------------------------------------------------------------------------- command
def build_command(
    *,
    prompt: str,
    system: str,
    model: str | None = None,
    effort: str | None = None,
    max_budget_usd: float | None = None,
) -> list[str]:
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "stream-json", "--verbose",
        "--tools", *READ_ONLY_TOOLS,
        "--allowedTools", *READ_ONLY_TOOLS,
        "--disallowedTools", *DENIED_TOOLS,
        "--permission-mode", "dontAsk",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--append-system-prompt", system,
    ]
    if model:
        cmd += ["--model", model]
    if effort:
        cmd += ["--effort", effort]
    if max_budget_usd and max_budget_usd > 0:
        cmd += ["--max-budget-usd", str(max_budget_usd)]
    return cmd


# ------------------------------------------------------------------------- git guard
@dataclass(frozen=True)
class Snapshot:
    head: str
    entries: dict[str, str] = field(default_factory=dict)


def _fingerprint(path: Path) -> str:
    """Size plus a content digest, never mtime: a tool that rewrites identical bytes (an
    editor save, a formatter) is not a change, and one that changes them always is."""
    try:
        if path.is_symlink():
            return "link:" + os.readlink(path)
        st = path.stat()
        if not path.is_file():
            return "dir"
        if st.st_size > _HASH_CAP:
            return f"{st.st_size}:big"
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return f"{st.st_size}:{h.hexdigest()}"
    except OSError:
        return "gone"


async def _run_git(cwd: str, *args: str) -> str:
    proc = await asyncio.create_subprocess_exec(
        "git", "--no-optional-locks", *args, cwd=cwd,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    if proc.returncode != 0:
        raise git_ops.GitError(list(args), proc.returncode or -1, err.decode(errors="replace"))
    return out.decode(errors="surrogateescape")


async def snapshot(cwd: str) -> Snapshot:
    """HEAD plus every dirty or untracked path with a content fingerprint. Status alone
    would miss a second edit to a file that was already modified."""
    try:
        head = (await _run_git(cwd, "rev-parse", "HEAD")).strip()
    except git_ops.GitError:
        head = "(no commits)"
    raw = await _run_git(cwd, "status", "--porcelain", "-z", "--untracked-files=all")
    tokens = raw.split("\0")
    entries: dict[str, str] = {}
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        i += 1
        if len(tok) < 4:
            continue
        xy, path = tok[:2], tok[3:]
        if xy[0] in "RC":
            i += 1
        entries[path] = f"{xy}|{_fingerprint(Path(cwd) / path)}"
    return Snapshot(head=head, entries=entries)


def changed_between(before: Snapshot, after: Snapshot, excused: set[str] | None = None) -> list[str]:
    prefixes = tuple(e.rstrip("/") + "/" for e in (excused or ()))
    exact = set(excused or ())
    changed = [
        p for p in sorted(set(before.entries) | set(after.entries))
        if before.entries.get(p) != after.entries.get(p)
        and p not in exact
        and not p.startswith(prefixes)
    ]
    if before.head != after.head:
        changed.insert(0, "HEAD")
    return changed


def violation_message(changed: list[str]) -> str:
    shown = ", ".join(changed[:5]) + (f" (+{len(changed) - 5} more)" if len(changed) > 5 else "")
    return (
        f"{VIOLATION} ({shown}). If you saved a file in another editor, edited in a terminal or committed while it ran, "
        "that is the likely cause."
    )


# ---------------------------------------------------------------------------- the run
@dataclass
class JobResult:
    text: str = ""
    cost_usd: float | None = None
    error: str | None = None
    #: A real change to the worktree was found by the git guard.
    violation: bool = False
    #: The run was stopped (its cancellation was absorbed after a best-effort guard check).
    stopped: bool = False
    #: Tools the run tried to call that it does not have (edits included). Never written.
    blocked_calls: list[str] = field(default_factory=list)
    #: Set when the guard saw a change but a haro-internal writer ran during the job, so it
    #: cannot tell whose it was. Not a failure, and not a clean bill either.
    inconclusive: str | None = None


EventSource = Callable[[list[str], str], AsyncIterator[NormalizedEvent]]
Emit = Callable[[str, dict[str, Any]], Awaitable[None]]


async def _claude_source(cmd: list[str], cwd: str, *, sandbox: bool = False) -> AsyncIterator[NormalizedEvent]:
    if shutil.which(cmd[0]) is None:
        yield NormalizedEvent("error", {"message": "`claude` CLI not found on PATH. Install Claude Code."})
        return
    if sandbox:
        if not sandbox_mod.bwrap_available():
            yield NormalizedEvent("error", {"message": "[agent] sandbox is on but bwrap is not installed"})
            return
        wrapped = sandbox_mod.wrap_agent_command(cmd, worktree=cwd, writable=False)
        if wrapped is None:
            yield NormalizedEvent("error", {"message": "`claude` CLI not found on PATH. Install Claude Code."})
            return
        cmd = wrapped
    proc = await asyncio.create_subprocess_exec(
        *cmd, cwd=cwd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        limit=_STREAM_LIMIT, start_new_session=True,
    )
    stream = ClaudeCodeAdapter()._stream(proc, cwd=cwd, resume=None, effort=None)
    try:
        async for ev in stream:
            yield ev
    finally:
        await stream.aclose()
        await terminate_tree(proc)


async def run_job(
    *,
    worktree: str,
    prompt: str,
    system: str,
    model: str | None,
    effort: str | None,
    max_budget_usd: float | None,
    max_parallel: int,
    emit: Emit,
    sandbox: bool = False,
    excused: Callable[[], set[str]] = lambda: set(),
    internal_writer: Callable[[], bool] = lambda: False,
    source: EventSource | None = None,
) -> JobResult:
    """Run one read-only job to completion. Never raises: a stop (``CancelledError``) comes
    back as ``JobResult.stopped`` after a best-effort guard check, every other failure in
    ``JobResult.error``.

    An attempted edit or a call to a tool outside the whitelist is NOT a violation: the CLI
    answers those with "No such tool available" and nothing is written, so they are logged
    and reported in ``blocked_calls``. Only a real change found by the git guard fails the
    job, unless a haro-internal writer (a gate run, a commit, ...) ran meanwhile
    (``internal_writer``), in which case the check is inconclusive and the job stands."""
    cmd = build_command(
        prompt=prompt, system=system, model=model, effort=effort, max_budget_usd=max_budget_usd
    )
    src = source or (lambda c, w: _claude_source(c, w, sandbox=sandbox))
    result = JobResult()
    sem = runner._slots(max_parallel)
    if sem is not None and sem.locked():
        await emit("queued", {"message": f"{max_parallel} runs already in flight (max_parallel)"})

    async with contextlib.AsyncExitStack() as stack:
        if sem is not None:
            await stack.enter_async_context(sem)
        try:
            before = await snapshot(worktree)
        except git_ops.GitError as exc:
            result.error = f"could not read git state: {exc.stderr.strip() or exc}"
            return result
        await emit("started", {})
        final_text = ""
        streamed: list[str] = []
        try:
            async with asyncio.timeout(JOB_TIMEOUT_S):
                agen = src(cmd, worktree)
                async with contextlib.aclosing(agen):
                    async for ev in agen:
                        if ev.payload.get("parent"):  # a sub-agent's own step: not this job's output
                            continue
                        if ev.type in ("file_edit", "tool_call"):
                            tool = str(ev.payload.get("tool") or "")
                            if ev.type == "file_edit" or tool not in READ_ONLY_TOOLS:
                                name = tool or "an unknown tool"
                                log.warning(
                                    "assist run in %s tried %s, which it does not have", worktree, name
                                )
                                if name not in result.blocked_calls:
                                    result.blocked_calls.append(name)
                                    await emit("blocked", {"tool": name})
                        elif ev.type == "token":
                            if ev.payload.get("system") or ev.payload.get("meta"):
                                continue
                            text = str(ev.payload.get("text") or "")
                            streamed.append(text)
                            await emit("token", {"text": strip_code_fences(text)})
                        elif ev.type == "done":
                            final_text = str(ev.payload.get("result") or "")
                            result.cost_usd = ev.payload.get("cost_usd")
                        elif ev.type == "error":
                            result.error = str(ev.payload.get("message") or "the assistant failed")
                            result.cost_usd = ev.payload.get("cost_usd")
                            break
        except TimeoutError:
            result.error = f"the assistant timed out after {JOB_TIMEOUT_S}s"
        except asyncio.CancelledError:
            result.stopped = True

        try:
            after = await snapshot(worktree)
        except (git_ops.GitError, OSError) as exc:
            if result.stopped:
                log.warning("assist guard could not re-read git state after a stop: %s", exc)
                return result
            result.violation = True
            result.error = f"{VIOLATION} (git state unreadable after the run: {getattr(exc, 'stderr', '') or exc})"
            return result
        changed = changed_between(before, after, excused())
        if changed:
            if internal_writer():
                result.inconclusive = (
                    "haro couldn't check the files during this run because a gate, dev server "
                    "or commit was writing to them ("
                    + ", ".join(changed[:5])
                    + "); the assistant had no edit tools."
                )
                log.warning("assist guard inconclusive in %s: %s", worktree, changed)
            else:
                result.violation = True
                result.error = violation_message(changed)
                log.error("assist guard tripped in %s: %s", worktree, changed)
                return result
        if result.stopped:
            return result
        if result.error is None:
            result.text = final_text or "".join(streamed)
    return result


# ----------------------------------------------------------------------- refs in a prompt
_AT = re.compile(r"(?<![\w/])@(?P<p>[\w./\-]+)")
_ISSUE = re.compile(r"(?<![\w&])#(?P<n>\d{1,6})\b")
IssueLookup = Callable[[str, int], Awaitable[dict]]


async def resolve_refs(
    worktree: str, project_path: str, prompt: str, view_issue: IssueLookup | None = None
) -> str:
    """The prompt plus a short list of what its ``@path`` and ``#issue`` mentions point at."""
    lines: list[str] = []
    for m in dict.fromkeys(x["p"].rstrip(".,;:") for x in _AT.finditer(prompt)):
        if _is_file(worktree, m):
            lines.append(f"- file: {m}")
    if view_issue is not None:
        for n in dict.fromkeys(int(x["n"]) for x in _ISSUE.finditer(prompt)):
            try:
                info = await asyncio.wait_for(view_issue(project_path, n), timeout=8)
            except Exception:  # noqa: BLE001 - gh missing/offline: the ref just stays unresolved
                continue
            if info.get("available") and info.get("title"):
                lines.append(f"- issue #{n}: {info['title']}")
    if not lines:
        return prompt
    return prompt + "\n\nThe developer pointed at:\n" + "\n".join(lines)


def make_plan(
    *, prompt: str, text: str, model: str | None, effort: str | None, cost_usd: float | None
) -> ManualPlan:
    """Parse the plan reply into a stored plan. Raises ``ValueError`` when it has no steps."""
    clean = strip_indented_code(strip_code_fences(text))
    title, steps, why = parse_plan(clean, prompt)
    if not steps:
        raise ValueError("the assistant's reply had no numbered steps: " + clean.strip()[:200])
    return ManualPlan(
        title=title, prompt=prompt, steps=[PlanStep(text=s) for s in steps], why=why,
        model=model, effort=effort, cost_usd=cost_usd,
    )


def plan_markdown(plans: list[ManualPlan]) -> str:
    """The saved plans as PR-body markdown. Empty when nothing was saved."""
    saved = [p for p in plans if p.saved]
    if not saved:
        return ""
    edits = "unverified" if any(p.guard_note for p in saved) else "0"
    out = ["## Plan", "", f"Plan by haro AI, code by hand · AI edits: {edits}", ""]
    for p in saved:
        if len(saved) > 1:
            out += [f"### {p.title}", ""]
        out += [f"- [{'x' if s.done else ' '}] {s.text}" for s in p.steps]
        if p.why:
            out += ["", f"Why this order: {p.why}"]
        out.append("")
    return "\n".join(out).rstrip() + "\n"


