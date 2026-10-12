"""Which GitHub account haro's ``gh`` calls run as, and how to add one.

Why: ``gh`` acts as whichever account is *active* in the user's terminal. With a personal and a
work account logged in, a work repo 404s ("Could not resolve to a Repository") while the
personal one is active, and the other way round. haro never runs ``gh auth switch`` to fix that
(it is global state shared with the user's terminal). Instead every ``gh`` call gets
``GH_TOKEN`` for the account resolved here, for that one call only (``git_ops.gh_env``).

Resolution order for a project: explicit per-project override, then automatic (the first account
whose token can read ``repos/{owner}/{repo}``), then haro's default account, then the terminal's
active account, then none. Override/auto/default inject a token; terminal/none leave ``gh``
alone (that is already what ``gh`` would do).

Tokens are secrets: they are held in memory only, passed to a child through its environment,
and never logged, returned by an endpoint or put in an error message.

The haro default lives in ``~/.haro/github.json`` rather than ``settings.toml``: the user-global
TOML is hand-edited and the stdlib cannot write TOML, so a read-modify-write would drop the
user's comments. A one-key JSON file survives restarts and is trivially atomic to replace.

Device login runs ``gh auth login -w`` as a child. Verified against gh 2.89 without a TTY: it
prints ``! First copy your one-time code: XXXX-XXXX`` and the device URL to stderr, does NOT wait
for Enter, and keeps polling GitHub until the browser step finishes (stdin can be /dev/null).
``gh`` rewrites ``~/.gitconfig`` on login (credential helper), and that file carries load-bearing
``includeIf`` identity rules, so the child gets a throwaway ``GIT_CONFIG_GLOBAL``. A successful
login also makes the new account active globally, so the previously active one is restored.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import shutil
import signal
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from pydantic import BaseModel

from . import git_ops
from . import store as store_mod

HOST = "github.com"
#: Seconds the account list is served without re-running ``gh auth status``.
ACCOUNTS_TTL = 30.0
#: Seconds a token read from ``gh auth token`` is kept in memory.
TOKEN_TTL = 300.0
#: Seconds an automatic resolution is cached: long when an account matched, short when none did
#: (a network blip must not pin "unresolved" for ten minutes).
RESOLVED_TTL = 600.0
UNRESOLVED_TTL = 30.0
PROBE_TIMEOUT = 4.0
#: Hard cap on what ``gh_env`` will wait for resolution before treating it as unresolved.
RESOLVE_BUDGET = 9.0
LOGIN_TTL = 600.0
CODE_WAIT = 15.0


class GhDefaultRequest(BaseModel):
    login: str


class GhAccountRequest(BaseModel):
    login: Optional[str] = None


@dataclass(frozen=True)
class Account:
    login: str
    active: bool


@dataclass(frozen=True)
class Resolution:
    login: Optional[str]
    source: str  # "override" | "auto" | "default" | "terminal" | "none"


def gh_available() -> bool:
    return shutil.which("gh") is not None


def _redact(text: str) -> str:
    return re.sub(r"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+", "***", text)


def _env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """The process env without any ambient token (an ambient ``GH_TOKEN`` would make ``gh``
    report that one identity instead of the stored accounts) and with prompts off."""
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env["GH_PROMPT_DISABLED"] = "1"
    if extra:
        env.update(extra)
    return env


async def _run_gh(
    *args: str, env: dict[str, str] | None = None, timeout: float = 10.0
) -> tuple[int, str, str]:
    """(code, stdout, stderr); 127 when ``gh`` is absent, 124 on timeout."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "gh", *args,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=env if env is not None else _env(),
        )
    except OSError:
        return 127, "", ""
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        await proc.wait()
        return 124, "", ""
    except asyncio.CancelledError:
        # A caller's time budget cancelling us must not leave the child running.
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        await proc.wait()
        raise
    return proc.returncode or 0, out.decode(errors="replace"), err.decode(errors="replace")


# --------------------------------------------------------------------------- accounts


_accounts_cache: tuple[float, list[Account]] | None = None
_tokens: dict[str, tuple[float, str]] = {}


def _parse_json_status(text: str) -> list[Account] | None:
    try:
        data = json.loads(text)
        entries = data["hosts"].get(HOST, [])
    except (ValueError, KeyError, AttributeError, TypeError):
        return None
    return [
        Account(str(e["login"]), bool(e.get("active")))
        for e in entries
        if isinstance(e, dict) and e.get("state") == "success" and e.get("login")
    ]


_LOGIN_LINE = re.compile(r"Logged in to github\.com\s+(?:account|as)\s+(\S+)")
_ACTIVE_LINE = re.compile(r"Active account:\s*(true|false)", re.I)


def _parse_text_status(text: str) -> list[Account]:
    """Older ``gh`` (no ``--json``): ``Logged in to github.com account X`` / ``as X`` blocks,
    with an ``Active account:`` line only on versions that support several accounts."""
    logins: list[str] = []
    active: dict[str, bool] = {}
    seen_active_line = False
    for line in text.splitlines():
        m = _LOGIN_LINE.search(line)
        if m:
            logins.append(m.group(1))
            continue
        m = _ACTIVE_LINE.search(line)
        if m and logins:
            seen_active_line = True
            active[logins[-1]] = m.group(1).lower() == "true"
    if not seen_active_line and logins:
        active[logins[0]] = True
    return [Account(login, active.get(login, False)) for login in logins]


async def list_accounts(*, force: bool = False) -> list[Account]:
    global _accounts_cache
    if not gh_available():
        return []
    now = time.monotonic()
    if not force and _accounts_cache and now - _accounts_cache[0] < ACCOUNTS_TTL:
        return list(_accounts_cache[1])
    code, out, err = await _run_gh("auth", "status", "--json", "hosts")
    accounts = _parse_json_status(out) if code == 0 or out.strip().startswith("{") else None
    if accounts is None:
        # gh exits non-zero when any stored account is unhealthy, and older versions print the
        # report to stderr, so read both streams.
        _code, out, err = await _run_gh("auth", "status", "--hostname", HOST)
        accounts = _parse_text_status(out + "\n" + err)
    previous = [a.login for a in _accounts_cache[1]] if _accounts_cache else None
    if previous is not None and previous != [a.login for a in accounts]:
        invalidate()
    _accounts_cache = (now, accounts)
    return list(accounts)


def _match(login: str | None, accounts: list[Account]) -> str | None:
    """Canonical login for a case-insensitive name, or None."""
    if not login:
        return None
    for a in accounts:
        if a.login.lower() == login.lower():
            return a.login
    return None


async def get_token(login: str) -> str | None:
    hit = _tokens.get(login)
    if hit and time.monotonic() - hit[0] < TOKEN_TTL:
        return hit[1]
    code, out, _err = await _run_gh("auth", "token", "-h", HOST, "-u", login)
    token = out.strip()
    if code != 0 or not token:
        _tokens.pop(login, None)
        return None
    _tokens[login] = (time.monotonic(), token)
    return token


# --------------------------------------------------------------------------- default


def _config_path() -> Path:
    return Path(os.environ.get("HARO_GITHUB_CONFIG", os.path.expanduser("~/.haro/github.json")))


def stored_default() -> str | None:
    try:
        value = json.loads(_config_path().read_text()).get("default")
    except (OSError, ValueError, AttributeError):
        return None
    return value if isinstance(value, str) and value else None


def set_default(login: str) -> None:
    path = _config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps({"default": login}))
    os.replace(tmp, path)
    invalidate()


# --------------------------------------------------------------------------- resolver


@dataclass
class _Cached:
    login: Optional[str]
    expires: float


_auto_cache: dict[str, _Cached] = {}
_auto_inflight: dict[str, asyncio.Task] = {}
_cwd_slug: dict[str, str] = {}
#: Bumped by every invalidate(): a probe round that started before it must not write its
#: (possibly stale) answer into the cache afterwards.
_generation = 0


def invalidate(slug: str | None = None) -> None:
    """Drop cached automatic resolutions (all, or one ``owner/repo``). A full invalidation also
    drops the account list and tokens, so the next read sees the live ``gh`` state."""
    global _accounts_cache, _generation
    _generation += 1
    if slug is None:
        _auto_cache.clear()
        _auto_inflight.clear()
        _tokens.clear()
        _accounts_cache = None
    else:
        _auto_cache.pop(slug.lower(), None)
        _auto_inflight.pop(slug.lower(), None)


async def _probe(slug: str, login: str) -> tuple[bool, bool]:
    """(can read, can push) for ``login`` on the repo. Reading is not enough to choose an
    account: every account can read a public repo, but a PR or comment is attributed forever
    to whoever sends it, so push access is what identifies the right account."""
    token = await get_token(login)
    if not token:
        return False, False
    code, out, _err = await _run_gh(
        "api", f"repos/{slug}", "--jq", ".permissions.push",
        env=_env({"GH_TOKEN": token}), timeout=PROBE_TIMEOUT,
    )
    return code == 0, code == 0 and out.strip() == "true"


async def _auto(slug: str, accounts: list[Account], default: str | None) -> str | None:
    """First account with push access (repo owner, then haro default, then the rest). With no
    pusher anywhere (a public repo you only read), prefer the terminal's active account, which
    is what ``gh`` would have used, then the default, then any account that can read."""
    owner = slug.split("/", 1)[0].lower()
    ordered = sorted(
        accounts,
        key=lambda a: (
            a.login.lower() != owner,
            default is None or a.login.lower() != default.lower(),
        ),
    )
    readers: list[Account] = []
    for account in ordered:
        can_read, can_push = await _probe(slug, account.login)
        if can_push:
            return account.login
        if can_read:
            readers.append(account)
    for account in readers:
        if account.active:
            return account.login
    for account in readers:
        if default and account.login.lower() == default.lower():
            return account.login
    return readers[0].login if readers else None


async def _auto_cached(slug: str, accounts: list[Account], default: str | None) -> str | None:
    key = slug.lower()
    hit = _auto_cache.get(key)
    if hit and hit.expires > time.monotonic():
        return hit.login
    task = _auto_inflight.get(key)
    if task is None:
        task = asyncio.ensure_future(_auto(slug, accounts, default))
        _auto_inflight[key] = task
        started = _generation

        def _done(t: asyncio.Task, key: str = key, started: int = started) -> None:
            if _auto_inflight.get(key) is t:
                _auto_inflight.pop(key, None)
            if t.cancelled() or t.exception() is not None or started != _generation:
                return
            login = t.result()
            ttl = RESOLVED_TTL if login else UNRESOLVED_TTL
            _auto_cache[key] = _Cached(login, time.monotonic() + ttl)

        task.add_done_callback(_done)
    return await asyncio.shield(task)


async def resolve(slug: str | None, override: str | None = None) -> Resolution:
    accounts = await list_accounts()
    if not accounts:
        return Resolution(None, "none")
    default = _match(stored_default(), accounts)
    chosen = _match(override, accounts)
    if chosen:
        return Resolution(chosen, "override")
    if slug:
        auto = await _auto_cached(slug, accounts, default)
        if auto:
            return Resolution(auto, "auto")
    if default:
        return Resolution(default, "default")
    active = next((a.login for a in accounts if a.active), None)
    if active:
        return Resolution(active, "terminal")
    return Resolution(None, "none")


def project_for_path(path: str | Path):
    """The Project owning ``path``: a workspace worktree, or the project root itself."""
    s = store_mod.store
    p = os.path.normpath(str(path))

    def inside(root: str) -> bool:
        root = os.path.normpath(root)
        return p == root or p.startswith(root + os.sep)

    for ws in s.workspaces.values():
        if inside(ws.worktree_path):
            return s.get_project(ws.project_id)
    for proj in s.projects.values():
        if inside(proj.path):
            return proj
    return None


async def token_for_repo(repo_path: str | Path, slug: str) -> str | None:
    """Token for the account that should run ``gh`` here, or None to leave ``gh`` alone."""
    if os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"):
        return None
    _cwd_slug[str(repo_path)] = slug
    project = project_for_path(repo_path)
    res = await resolve(slug, project.gh_account if project else None)
    if res.source in ("override", "auto", "default") and res.login:
        return await get_token(res.login)
    return None


async def env_token(repo_path: str | Path, slug: str) -> str | None:
    """``token_for_repo`` bounded in time and never raising: a resolution problem must not
    break the ``gh`` call it was meant to help."""
    try:
        return await asyncio.wait_for(token_for_repo(repo_path, slug), RESOLVE_BUDGET)
    except Exception:  # noqa: BLE001 (incl. TimeoutError)
        return None


_WRONG_ACCOUNT = (
    "Could not resolve to a Repository",
    "HTTP 404",
    "HTTP 403",
    "Resource not accessible",
    "must have push access",
    "must have admin rights",
    "Forbidden",
)


def note_gh_result(cwd: str | Path, code: int, stderr: str) -> None:
    """A later ``gh`` call that 404s or is refused on the repo means the cached account is wrong
    (access was granted or revoked): forget it so the next call re-probes."""
    if code == 0:
        return
    slug = _cwd_slug.get(str(cwd))
    if slug and any(marker in stderr for marker in _WRONG_ACCOUNT):
        invalidate(slug)


async def accounts_payload() -> dict[str, Any]:
    available = gh_available()
    accounts = await list_accounts() if available else []
    default = _match(stored_default(), accounts)
    return {
        "gh_available": available,
        "default": default,
        "accounts": [
            {
                "login": a.login,
                "avatar_url": f"https://github.com/{a.login}.png?size=64",
                "is_default": a.login == default,
                "terminal_active": a.active,
            }
            for a in accounts
        ],
    }


async def known_login(login: str) -> str | None:
    return _match(login, await list_accounts())


async def project_payload(project) -> dict[str, Any]:
    # Same input as git_ops.gh_env (the live origin), so the menu never disagrees with the calls.
    try:
        live = await git_ops.get_remote(project.path)
    except Exception:  # noqa: BLE001
        live = None
    slug = git_ops.github_slug(live or project.remote_url or "")
    res = await resolve(slug, project.gh_account)
    return {"override": project.gh_account, "resolved": res.login, "source": res.source}


# --------------------------------------------------------------------------- device login


class LoginError(Exception):
    """``reason`` is ``gh_missing``, ``login_in_progress`` or ``login_failed``."""

    def __init__(self, reason: str, message: str = "", session_id: str | None = None) -> None:
        super().__init__(message or reason)
        self.reason = reason
        self.message = message or reason
        #: For ``login_in_progress``: the pending session, so the client can cancel it.
        self.session_id = session_id


_CODE_AFTER_WORD = re.compile(r"code:?\s*([A-Z0-9]{4}-[A-Z0-9]{4})")
_CODE_ANY = re.compile(r"\b([A-Z0-9]{4}-[A-Z0-9]{4})\b")
_URL = re.compile(r"https?://[^\s\"'<>]+")
_DEFAULT_URL = "https://github.com/login/device"


@dataclass
class _Login:
    id: str
    proc: asyncio.subprocess.Process
    cfg_path: str
    before: list[str]
    previous_active: Optional[str]
    started: float = field(default_factory=time.monotonic)
    state: str = "pending"
    login: Optional[str] = None
    error: Optional[str] = None
    code: Optional[str] = None
    url: Optional[str] = None
    output: list[str] = field(default_factory=list)
    restored: bool = False
    pumps: list[asyncio.Task] = field(default_factory=list)
    watcher: Optional[asyncio.Task] = None


_sessions: dict[str, _Login] = {}
_starting = False


def _pending() -> _Login | None:
    return next((s for s in _sessions.values() if s.state == "pending"), None)


async def _pump(stream: asyncio.StreamReader, sess: _Login) -> None:
    async for raw in stream:
        line = _redact(raw.decode(errors="replace").rstrip())
        if not line.strip():
            continue
        if len(sess.output) < 200:
            sess.output.append(line)
        if sess.code is None:
            m = _CODE_AFTER_WORD.search(line) or _CODE_ANY.search(line)
            if m:
                sess.code = m.group(1)
        if sess.url is None:
            m = _URL.search(line)
            if m:
                sess.url = m.group(0).rstrip(".,)")


async def _kill(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is not None:
        return
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        await asyncio.wait_for(proc.wait(), 3)
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, signal.SIGKILL)
        await proc.wait()


def _tail_error(sess: _Login) -> str:
    return (sess.output[-1] if sess.output else "gh auth login failed")[:200]


async def _detect_login(sess: _Login) -> str | None:
    """The account the finished login produced: a new login, else (a re-login) the one gh made
    active."""
    after = await list_accounts(force=True)
    known = {b.lower() for b in sess.before}
    new = [a.login for a in after if a.login.lower() not in known]
    active = next((a.login for a in after if a.active), None)
    return new[0] if new else active


async def _restore_terminal(sess: _Login) -> None:
    """Put the terminal's active account back, whatever way the login ended. gh stores the token
    and makes the new account active before it exits, so a cancel, a late failure or the expiry
    kill can leave the terminal on the new account just like a success does. Runs once, after
    the child is dead; nothing to restore when there was no previous account."""
    if sess.restored or not sess.previous_active:
        return
    sess.restored = True
    after = await list_accounts(force=True)
    active = next((a.login for a in after if a.active), None)
    if active and active.lower() != sess.previous_active.lower() and _match(
        sess.previous_active, after
    ):
        code, _o, _e = await _run_gh("auth", "switch", "-h", HOST, "-u", sess.previous_active)
        if code != 0:
            print("[github] could not restore the terminal's active account after login")
    invalidate()


async def _watch(sess: _Login) -> None:
    outcome: tuple[str, Optional[str], Optional[str]] | None = None
    try:
        try:
            rc = await asyncio.wait_for(sess.proc.wait(), LOGIN_TTL)
        except asyncio.TimeoutError:
            outcome = ("failed", None, "login expired")
            return
        await asyncio.gather(*sess.pumps, return_exceptions=True)
        if sess.state != "pending":
            return
        if rc == 0:
            outcome = ("done", await _detect_login(sess), None)
        else:
            outcome = ("failed", None, _tail_error(sess))
    except Exception as exc:  # noqa: BLE001
        outcome = ("failed", None, _redact(f"login error: {type(exc).__name__}"))
    finally:
        await _kill(sess.proc)
        try:
            await _restore_terminal(sess)
        except Exception:  # noqa: BLE001
            pass
        with contextlib.suppress(OSError):
            os.unlink(sess.cfg_path)
        if outcome and sess.state == "pending":
            sess.state, sess.login, sess.error = outcome


async def start_login() -> dict[str, str]:
    global _starting
    if not gh_available():
        raise LoginError("gh_missing", "`gh` CLI not found")
    if _starting or _pending():
        pending = _pending()
        raise LoginError("login_in_progress", session_id=pending.id if pending else None)
    _starting = True
    try:
        horizon = time.monotonic() - 3600
        for sid in [k for k, s in _sessions.items() if s.state != "pending" and s.started < horizon]:
            _sessions.pop(sid)
        accounts = await list_accounts(force=True)
        before = [a.login for a in accounts]
        previous = next((a.login for a in accounts if a.active), None)
        fd, cfg = tempfile.mkstemp(prefix="haro-gitconfig-")
        os.close(fd)
        env = _env({
            "GIT_CONFIG_GLOBAL": cfg,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        })
        try:
            proc = await asyncio.create_subprocess_exec(
                "gh", "auth", "login", "-h", HOST, "-p", "https", "-w", "--skip-ssh-key",
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                env=env, start_new_session=True,
            )
        except OSError as exc:
            with contextlib.suppress(OSError):
                os.unlink(cfg)
            raise LoginError("gh_missing", "`gh` CLI not found") from exc
        sess = _Login(uuid.uuid4().hex, proc, cfg, before, previous)
        _sessions[sess.id] = sess
        sess.pumps = [
            asyncio.ensure_future(_pump(proc.stdout, sess)),
            asyncio.ensure_future(_pump(proc.stderr, sess)),
        ]
        sess.watcher = asyncio.ensure_future(_watch(sess))
    finally:
        _starting = False
    deadline = time.monotonic() + CODE_WAIT
    while sess.code is None and sess.state == "pending" and time.monotonic() < deadline:
        await asyncio.sleep(0.05)
    if sess.code is None:
        msg = _tail_error(sess) if sess.state != "pending" else "no one-time code from gh"
        await _abort(sess)
        raise LoginError("login_failed", msg)
    return {"id": sess.id, "code": sess.code, "url": sess.url or _DEFAULT_URL}


async def _abort(sess: _Login) -> None:
    if sess.state == "pending":
        sess.state = "cancelled"
    await _kill(sess.proc)
    if sess.watcher:
        with contextlib.suppress(Exception):
            await asyncio.wait_for(asyncio.shield(sess.watcher), 5)


def login_status(login_id: str) -> dict[str, Any] | None:
    sess = _sessions.get(login_id)
    if sess is None:
        return None
    return {"state": sess.state, "login": sess.login, "error": sess.error}


async def cancel_login(login_id: str) -> dict[str, Any] | None:
    sess = _sessions.get(login_id)
    if sess is None:
        return None
    if sess.state == "pending":
        await _abort(sess)
    return {"state": sess.state}


async def shutdown() -> None:
    """Kill any login child on backend exit so no ``gh`` outlives haro."""
    for sess in list(_sessions.values()):
        if sess.state == "pending":
            await _abort(sess)


def reset() -> None:
    """Forget every cache and session (tests, and a clean slate after loop changes)."""
    global _accounts_cache, _starting, _generation
    _accounts_cache = None
    _starting = False
    _generation = 0
    _tokens.clear()
    _auto_cache.clear()
    _auto_inflight.clear()
    _cwd_slug.clear()
    _sessions.clear()
