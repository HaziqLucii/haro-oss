"""Manual-rail research that needs no AI: repo, git, man and web scopes.

The Search tab only sends ``ask`` now. The other scopes stay for the CLI and tests, and the
``git`` scope is also what an ``ask`` runs for the identifiers in the question (see
``merge_git_hits``): the assistant has no shell, so it cannot read history itself.

Every function returns pointers (``ResearchRow``), never prose or code: the dev reads the
source themselves. Nothing here fetches from the network (``web`` only builds search links the
client opens in the user's own browser) and nothing writes to the worktree. The AI-backed
``ask`` scope lives in ``assist.py``.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import re
import shutil
from urllib.parse import quote

from . import files as filesvc
from . import git_ops
from .models import ResearchRow

MAX_ROWS = 30
MAN_CAP = 300_000
_MAN_TIMEOUT = 10

_BLAME_TARGET = re.compile(r"^(?P<path>.+):(?P<line>\d+)$")
_MAN_LINE = re.compile(r"^(?P<names>.+?)\s*\((?P<sec>[^)]+)\)\s+-\s+(?P<desc>.*)$")
_MAN_PAGE = re.compile(r"^(?P<name>[A-Za-z0-9_.+:@-]+?)(?:\((?P<sec>[0-9][A-Za-z0-9]*)\))?$")
_OVERSTRIKE = re.compile(r".\x08")

#: Official-docs domains per detected stack id (``presets._LOGO_ORDER``). The search itself
#: is a plain ``site:`` query on a general engine: no per-site search URL to keep in sync.
DOCS_SITES: dict[str, str] = {
    "shopify": "shopify.dev",
    "nextjs": "nextjs.org/docs",
    "nuxtjs": "nuxt.com/docs",
    "react": "react.dev",
    "vuejs": "vuejs.org",
    "svelte": "svelte.dev",
    "angular": "angular.dev",
    "astro": "docs.astro.build",
    "laravel": "laravel.com/docs",
    "rails": "guides.rubyonrails.org",
    "django": "docs.djangoproject.com",
    "flask": "flask.palletsprojects.com",
    "fastapi": "fastapi.tiangolo.com",
    "nestjs": "docs.nestjs.com",
    "express": "expressjs.com",
    "go": "go.dev/doc",
    "rust": "doc.rust-lang.org",
    "php": "php.net/manual",
    "ruby": "ruby-doc.org",
    "python": "docs.python.org",
    "nodejs": "nodejs.org/docs",
}

_ENGINE = "https://duckduckgo.com/?q="


# ---------------------------------------------------------------------------- repo
async def research_repo(worktree: str, query: str) -> tuple[list[ResearchRow], str | None]:
    found = await filesvc.search_text(worktree, query, limit=MAX_ROWS)
    if found.get("error"):
        return [], "search is unavailable (neither ripgrep nor grep could run)"
    rows = [
        ResearchRow(
            source="repo",
            title=f"{m['file']}:{m['line']}",
            target=f"{m['file']}:{m['line']}",
            why=str(m["text"]).strip()[:160],
            action="jump",
        )
        for m in found["matches"]
    ]
    note = f"showing the first {MAX_ROWS}" if found.get("truncated") else None
    return rows, note


# ----------------------------------------------------------------------------- git
def _existing(worktree: str, rel: str) -> bool:
    try:
        return filesvc.safe_path(worktree, rel).is_file()
    except (ValueError, OSError):
        return False


def _parse_log(worktree: str, out: str) -> list[tuple[str, str, str, str, list[str]]]:
    """``(sha, short, subject, ago, existing_files)`` per commit of a ``--name-only`` log."""
    commits = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        head, _, tail = rec.partition("\n")
        parts = head.split("\x1f")
        if len(parts) < 4:
            continue
        names = [n.strip() for n in tail.splitlines() if n.strip()]
        commits.append((parts[0], parts[1], parts[2], parts[3], [n for n in names if _existing(worktree, n)]))
    return commits


#: Longest one git lookup (pickaxe, grep, blame) may run before it is killed.
GIT_CALL_TIMEOUT = 8


async def _log(worktree: str, *selector: str) -> list[tuple[str, str, str, str, list[str]]]:
    out = await git_ops._git(
        "log", "-n", "10", "--no-color", "--format=%x1e%H%x1f%h%x1f%s%x1f%ar", "--name-only",
        *selector, cwd=worktree, timeout=GIT_CALL_TIMEOUT,
    )
    return _parse_log(worktree, out)


async def _blame(worktree: str, rel: str, line: int) -> ResearchRow | None:
    out = await git_ops._git(
        "blame", "-L", f"{line},{line}", "--porcelain", "--", rel, cwd=worktree,
        timeout=GIT_CALL_TIMEOUT,
    )
    lines = out.splitlines()
    if not lines:
        return None
    sha = lines[0].split(" ", 1)[0]
    author = next((ln[7:] for ln in lines if ln.startswith("author ")), "")
    summary = next((ln[8:] for ln in lines if ln.startswith("summary ")), "")
    return ResearchRow(
        source="git",
        title=f"git blame {rel}:{line} · {sha[:7]}",
        target=f"{rel}:{line}",
        why=f"{summary} ({author})".strip(),
        action="jump",
    )


async def research_git(worktree: str, query: str) -> tuple[list[ResearchRow], str | None]:
    m = _BLAME_TARGET.match(query.strip())
    if m and _existing(worktree, m["path"]):
        try:
            row = await _blame(worktree, m["path"], int(m["line"]))
        except git_ops.GitError as exc:
            return [], f"git blame failed: {exc.stderr.strip() or exc}"
        except asyncio.TimeoutError:
            return [], "git blame timed out"
        return ([row] if row else []), None

    q = query.strip()
    if not q:
        return [], None
    try:
        picked = await _log(worktree, f"-S{q}")
        grepped = await _log(worktree, "-i", "-F", f"--grep={q}")
    except git_ops.GitError as exc:
        msg = exc.stderr.strip()
        if "does not have any commits" in msg:
            return [], "this repo has no commits yet"
        return [], f"git log failed: {msg or exc}"
    except asyncio.TimeoutError:
        return [], "git log timed out"

    rows: list[ResearchRow] = []
    seen: set[str] = set()
    skipped = 0
    for kind, commits in (("changed the text", picked), ("mentioned in message", grepped)):
        for sha, short, subject, ago, files in commits:
            if sha in seen:
                continue
            seen.add(sha)
            if not files:
                skipped += 1
                continue
            more = f" +{len(files) - 3}" if len(files) > 3 else ""
            rows.append(
                ResearchRow(
                    source="git",
                    title=f"{short} {subject}",
                    target=files[0],
                    why=f"{kind} · {ago} · {', '.join(files[:3])}{more}",
                    action="jump",
                )
            )
    note = f"{skipped} commit(s) only touched files that no longer exist" if skipped else None
    return rows[:MAX_ROWS], note


# ------------------------------------------------------------- git lookups for an ask
#: Total rows an ``ask`` may return: the model's own (at most 6) plus haro's git hits.
ASK_MAX_ROWS = 8
GIT_HIT_IDS = 3
GIT_LOOKUP_TIMEOUT = 20

_BACKTICKED = re.compile(r"`([^`\n]{3,80})`")
_QUOTED = re.compile(r"\"([^\"\n]{3,80})\"|(?<![\w])'([^'\n]{3,80})'(?![\w])")
_PATH_LINE = re.compile(r"(?<![\w./-])([\w./-]*[\w-]\.\w+:\d+)(?!\w)")
_CODE_NAME = re.compile(
    r"\b[a-z]+(?:[A-Z][a-z0-9]*)+\b"  # camelCase
    r"|\b(?:[A-Z][a-z0-9]+){2,}\b"  # PascalCase
    r"|\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\b"  # snake_case
    r"|\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+\b"  # dotted.name
)
_SHA_TOKEN = re.compile(r"^[0-9a-f]{7,40}$")


def extract_identifiers(query: str, limit: int = GIT_HIT_IDS) -> list[str]:
    """Likely code identifiers in a question, best first: ``path:line`` (blame), backticked
    words, quoted strings, then camelCase / PascalCase / snake_case / dotted names in the
    order they appear. Plain prose yields nothing, so an ordinary question costs no git
    call. At most ``limit``, deduplicated."""
    found: list[str] = []

    def add(cand: str) -> None:
        cand = cand.strip()
        if len(cand) >= 3 and cand not in found:
            found.append(cand)

    text = query
    for m in _PATH_LINE.finditer(text):
        add(m.group(1))
    text = _PATH_LINE.sub(" ", text)
    for m in _BACKTICKED.finditer(text):
        add(m.group(1))
    text = _BACKTICKED.sub(" ", text)
    for m in _QUOTED.finditer(text):
        add(m.group(1) or m.group(2))
    text = _QUOTED.sub(" ", text)
    for m in _CODE_NAME.finditer(text):
        if "." in m.group(0) and len(m.group(0)) < 4:
            continue  # "e.g", "i.e": abbreviations, not names
        add(m.group(0))
    return found[:limit]


def _row_sha(row: ResearchRow) -> str | None:
    """The commit a log row is about (its leading short sha). A blame row points at a line,
    not at a commit, so it has none and is only deduplicated by its target."""
    if row.source != "git" or row.title.startswith("git blame"):
        return None
    token = row.title.strip().split(" ", 1)[0].lower()
    return token if _SHA_TOKEN.match(token) else None


async def merge_git_hits(
    worktree: str,
    query: str,
    rows: list[ResearchRow],
    model_shas: set[str] | frozenset[str] = frozenset(),
    cap: int = ASK_MAX_ROWS,
) -> list[ResearchRow]:
    """``rows`` plus haro's own free git lookups for the identifiers in ``query``.

    Runs the ``git`` scope (pickaxe, message grep, blame for ``path:line``) for up to
    ``GIT_HIT_IDS`` identifiers and appends the hits as ``git`` rows, round-robin so one noisy
    identifier cannot crowd out the rest. A hit is skipped when its commit is already listed
    (by the model, via ``model_shas``, or by an earlier hit) and the total never exceeds
    ``cap``. Never raises and never waits past ``GIT_LOOKUP_TIMEOUT``: a slow or failing repo
    just yields no hits."""
    room = cap - len(rows)
    if room <= 0:
        return rows
    idents = extract_identifiers(query)
    if not idents:
        return rows

    async def one(ident: str) -> list[ResearchRow]:
        m = _BLAME_TARGET.match(ident)
        if m and not _existing(worktree, m["path"]):
            return []
        hits, _ = await research_git(worktree, ident)
        return hits

    try:
        per = await asyncio.wait_for(
            asyncio.gather(*(one(i) for i in idents), return_exceptions=True), GIT_LOOKUP_TIMEOUT
        )
    except asyncio.TimeoutError:
        return rows
    lists = [r for r in per if isinstance(r, list)]

    seen_shas = {s.lower() for s in model_shas if _SHA_TOKEN.match(s.lower())}
    seen_rows = {(r.source, r.target, r.title) for r in rows}
    out = list(rows)
    added = 0
    for i in range(max((len(r) for r in lists), default=0)):
        for hits in lists:
            if i >= len(hits) or added >= room:
                continue
            hit = hits[i]
            sha = _row_sha(hit)
            if sha and any(sha.startswith(s) or s.startswith(sha) for s in seen_shas):
                continue
            key = (hit.source, hit.target, hit.title)
            if key in seen_rows:
                continue
            if sha:
                seen_shas.add(sha)
            seen_rows.add(key)
            out.append(hit)
            added += 1
    return out


# ------------------------------------------------------------------------------ man
async def research_man(query: str) -> tuple[list[ResearchRow], str | None]:
    q = query.strip().lstrip("-").strip()
    if not q:
        return [], None
    if shutil.which("man") is None:
        return [], "man is not installed"
    try:
        proc = await asyncio.create_subprocess_exec(
            "man", "-k", q,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=_MAN_TIMEOUT)
    except (FileNotFoundError, asyncio.TimeoutError):
        return [], "man search is unavailable"
    rows: list[ResearchRow] = []
    for raw in out.decode(errors="replace").splitlines():
        m = _MAN_LINE.match(raw.strip())
        if not m:
            continue
        first = re.match(r"^(?P<n>[^(\s]+)\s*(?:\((?P<s>[^)]+)\))?", m["names"].split(",")[0].strip())
        if not first:
            continue
        name = first["n"]
        sec = (first["s"] or m["sec"]).strip()
        rows.append(
            ResearchRow(
                source="man", title=f"{name}({sec})", target=f"{name}({sec})",
                why=m["desc"].strip(), action="read",
            )
        )
        if len(rows) >= MAX_ROWS:
            break
    return rows, None


async def man_exists(page: str) -> bool:
    """Whether this machine has a manual page by that name (``ls`` or ``ls(1)``), via
    ``man -w``, which only locates the file. Never raises."""
    parsed = parse_man_page(page)
    if parsed is None or shutil.which("man") is None:
        return False
    name, sec = parsed
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            "man", "-w", *([sec] if sec else []), name,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=_MAN_TIMEOUT)
    except (OSError, asyncio.TimeoutError):
        if proc is not None and proc.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
        return False
    return proc.returncode == 0 and bool(out.strip())


def parse_man_page(page: str) -> tuple[str, str | None] | None:
    m = _MAN_PAGE.match(page.strip())
    if not m or m["name"].startswith("-"):
        return None
    return m["name"], m["sec"]


def strip_overstrikes(text: str) -> str:
    """``col -b`` without the dependency: man renders bold and underline as ``x\\bx`` / ``_\\bx``."""
    return _OVERSTRIKE.sub("", text)


async def read_man_page(page: str) -> tuple[str, bool] | None:
    """The rendered page as plain text, offline. ``None`` when there is no such page."""
    parsed = parse_man_page(page)
    if parsed is None or shutil.which("man") is None:
        return None
    name, sec = parsed
    cmd = ["man", "-P", "cat", *([sec] if sec else []), name]
    env = {**os.environ, "MANWIDTH": "80", "MANPAGER": "cat", "PAGER": "cat"}
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=_MAN_TIMEOUT)
    except (FileNotFoundError, asyncio.TimeoutError):
        return None
    if proc.returncode != 0 or not out.strip():
        return None
    text = strip_overstrikes(out.decode(errors="replace"))
    return text[:MAN_CAP], len(text) > MAN_CAP


# ------------------------------------------------------------------------------ web
def research_web(query: str, stack: list[str]) -> tuple[list[ResearchRow], str | None]:
    """Search links only: haro fetches nothing, the client opens them in the user's browser."""
    q = query.strip()
    if not q:
        return [], None
    rows: list[ResearchRow] = []
    for sid in stack:
        site = DOCS_SITES.get(sid)
        if site:
            rows.append(
                ResearchRow(
                    source="web",
                    title=f"{site.split('/')[0]} docs",
                    target=_ENGINE + quote(f"site:{site} {q}"),
                    why=f"official {sid} docs, searched for \"{q}\"",
                    action="open",
                )
            )
    rows.append(
        ResearchRow(
            source="web", title="Web search", target=_ENGINE + quote(q),
            why="opens in your browser", action="open",
        )
    )
    return rows, "haro does not fetch pages: these open in your browser"
