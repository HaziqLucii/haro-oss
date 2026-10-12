"""GitHub account resolution, the gh_env token injection, the endpoints and device login.

A fake ``gh`` executable on PATH stands in for the real CLI: it keeps its accounts, per-account
repo access and a call log in ``FAKE_GH_DIR``. Real ``gh`` login completion needs a human in a
browser, so the completion paths here are only exercised against the fake; the non-TTY output
shape it prints was copied from a real ``gh 2.89`` run in a throwaway ``GH_CONFIG_DIR``.
"""

from __future__ import annotations

import asyncio
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import git_ops, github_accounts as ga
from haro import main as main_mod
from haro import store as store_mod
from haro.models import Project, Workspace
from haro.store import Store

_REAL_GH_AVAILABLE = ga.gh_available

FAKE_GH = r'''#!__PY__
import json, os, sys, time

d = os.environ["FAKE_GH_DIR"]
args = sys.argv[1:]


def load(name, default=None):
    try:
        return json.load(open(f"{d}/{name}"))
    except OSError:
        return default


def save(name, value):
    json.dump(value, open(f"{d}/{name}", "w"))


def tok(login):
    return f"tok_{login}_SECRETVALUE"


with open(f"{d}/calls.log", "a") as fh:
    fh.write(" ".join(args) + "\n")

accounts = load("accounts.json", [])

if args[:2] == ["auth", "status"]:
    if os.path.exists(f"{d}/slowstatus"):
        open(f"{d}/status.pid", "w").write(str(os.getpid()))
        time.sleep(30)
    if "--json" in args:
        if os.path.exists(f"{d}/nojson"):
            sys.stderr.write("unknown flag: --json\n")
            sys.exit(1)
        hosts = [
            {"state": "success", "active": a["active"], "host": "github.com", "login": a["login"]}
            for a in accounts
        ]
        print(json.dumps({"hosts": {"github.com": hosts} if hosts else {}}))
        sys.exit(0)
    for a in accounts:
        sys.stderr.write(f"github.com\n  ✓ Logged in to github.com account {a['login']} (keyring)\n")
        sys.stderr.write(f"  - Active account: {'true' if a['active'] else 'false'}\n")
    sys.exit(0 if accounts else 1)

if args[:2] == ["auth", "token"]:
    login = args[args.index("-u") + 1]
    if any(a["login"] == login for a in accounts):
        print(tok(login))
        sys.exit(0)
    sys.exit(1)

if args[:2] == ["auth", "switch"]:
    login = args[args.index("-u") + 1]
    for a in accounts:
        a["active"] = a["login"] == login
    save("accounts.json", accounts)
    sys.exit(0)

if args and args[0] == "api":
    repo = args[1].removeprefix("repos/")
    token = os.environ.get("GH_TOKEN", "")
    login = next((a["login"] for a in accounts if tok(a["login"]) == token), None)
    with open(f"{d}/calls.log", "a") as fh:
        fh.write(f"PROBE {repo} as {login}\n")
    if os.path.exists(f"{d}/slowprobe"):
        time.sleep(10)
    if os.path.exists(f"{d}/delayprobe"):
        time.sleep(0.6)
    entries = load("access.json", {}).get(login, []) if login else []
    if repo in entries or f"{repo}:read" in entries:
        print(("true" if repo in entries else "false") if "--jq" in args else "{}")
        sys.exit(0)
    sys.stderr.write("gh: Not Found (HTTP 404)\n")
    sys.exit(1)

if args[:2] == ["auth", "login"]:
    mode = open(f"{d}/mode").read().strip() if os.path.exists(f"{d}/mode") else "ok"
    open(f"{d}/login.pid", "w").write(str(os.getpid()))
    save("login.env", {
        "GIT_CONFIG_GLOBAL": os.environ.get("GIT_CONFIG_GLOBAL"),
        "GIT_TERMINAL_PROMPT": os.environ.get("GIT_TERMINAL_PROMPT"),
        "stdin_isatty": sys.stdin.isatty(),
    })
    cfg = os.environ.get("GIT_CONFIG_GLOBAL") or os.path.expanduser("~/.gitconfig")
    with open(cfg, "a") as fh:
        fh.write("[credential]\n\thelper = !gh auth git-credential\n")
    if mode == "nocode":
        sys.stderr.write("something unrelated\n")
        sys.exit(1)
    sys.stderr.write("\n! First copy your one-time code: AB12-CD34\n")
    sys.stderr.write("Open this URL to continue in your web browser: https://github.com/login/device\n")
    sys.stderr.flush()
    if mode in ("store_hang", "store_fail"):
        target = open(f"{d}/login.new").read().strip()
        if not any(a["login"] == target for a in accounts):
            accounts.append({"login": target, "active": False})
        for a in accounts:
            a["active"] = a["login"] == target
        save("accounts.json", accounts)
        if mode == "store_fail":
            time.sleep(0.2)
            sys.stderr.write("error: could not finish\n")
            sys.exit(1)
    if mode in ("hang", "store_hang"):
        time.sleep(60)
    if mode == "fail":
        time.sleep(0.2)
        sys.stderr.write("error: authentication failed\n")
        sys.exit(1)
    if mode == "leak":
        sys.stderr.write("error: bad token gho_abcdef123456SECRET\n")
        sys.exit(1)
    time.sleep(0.4)
    target = open(f"{d}/login.new").read().strip()
    if not any(a["login"] == target for a in accounts):
        accounts.append({"login": target, "active": False})
    for a in accounts:
        a["active"] = a["login"] == target
    save("accounts.json", accounts)
    sys.exit(0)

sys.exit(2)
'''


class Fake:
    def __init__(self, root: Path) -> None:
        self.dir = root / "state"
        self.dir.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        script = self.bin / "gh"
        script.write_text(FAKE_GH.replace("__PY__", sys.executable))
        script.chmod(script.stat().st_mode | stat.S_IEXEC)

    def accounts(self, *pairs: tuple[str, bool]) -> None:
        (self.dir / "accounts.json").write_text(
            json.dumps([{"login": l, "active": a} for l, a in pairs])
        )

    def access(self, **by_login: list[str]) -> None:
        (self.dir / "access.json").write_text(json.dumps(by_login))

    def flag(self, name: str, on: bool = True) -> None:
        (self.dir / name).unlink(missing_ok=True)
        if on:
            (self.dir / name).write_text("1")

    def mode(self, mode: str, new: str = "NewUser") -> None:
        (self.dir / "mode").write_text(mode)
        (self.dir / "login.new").write_text(new)

    def calls(self) -> list[str]:
        p = self.dir / "calls.log"
        return p.read_text().splitlines() if p.exists() else []

    def probes(self) -> list[str]:
        return [c for c in self.calls() if c.startswith("PROBE ")]

    def state(self) -> list[dict]:
        return json.loads((self.dir / "accounts.json").read_text())

    def login_env(self) -> dict:
        return json.loads((self.dir / "login.env").read_text())

    def pid(self) -> int:
        return int((self.dir / "login.pid").read_text())


SECRET = "SECRETVALUE"


@pytest.fixture
def fake(tmp_path, monkeypatch):
    f = Fake(tmp_path)
    monkeypatch.setenv("PATH", f"{f.bin}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_GH_DIR", str(f.dir))
    monkeypatch.setattr(ga, "gh_available", _REAL_GH_AVAILABLE)
    monkeypatch.setenv("HARO_GITHUB_CONFIG", str(tmp_path / "github.json"))
    for var in ("GH_TOKEN", "GITHUB_TOKEN", "GH_REPO"):
        monkeypatch.delenv(var, raising=False)
    ga.reset()
    # Some older tests assign main.store for good, so the two names can differ: point both at one.
    fresh = Store()
    monkeypatch.setattr(main_mod, "store", fresh)
    monkeypatch.setattr(store_mod, "store", fresh)

    async def _no_save(_store):
        return None

    monkeypatch.setattr(main_mod.db, "save_snapshot", _no_save)
    yield f
    ga.reset()


def run(coro):
    return asyncio.run(coro)


def _repo(path: Path, origin: str) -> str:
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "remote", "add", "origin", origin], check=True)
    return str(path)


# ------------------------------------------------------------------ parsing / listing


def test_parse_text_status_new_and_old_formats():
    new = (
        "github.com\n  ✓ Logged in to github.com account A (keyring)\n  - Active account: false\n"
        "  ✓ Logged in to github.com account B (keyring)\n  - Active account: true\n"
    )
    assert ga._parse_text_status(new) == [ga.Account("A", False), ga.Account("B", True)]
    old = "github.com\n  ✓ Logged in to github.com as Solo (oauth_token)\n"
    assert ga._parse_text_status(old) == [ga.Account("Solo", True)]
    assert ga._parse_text_status("You are not logged into any GitHub hosts.") == []


def test_parse_json_status_skips_failed_entries_and_other_hosts():
    raw = json.dumps({"hosts": {
        "github.com": [
            {"state": "success", "active": True, "login": "A"},
            {"state": "error", "active": False, "login": "Broken"},
        ],
        "ghe.example": [{"state": "success", "active": True, "login": "Z"}],
    }})
    assert ga._parse_json_status(raw) == [ga.Account("A", True)]
    assert ga._parse_json_status("not json") is None


def test_list_accounts_json_then_text_fallback(fake):
    fake.accounts(("HaziqLucii", True), ("work-account", False))
    got = run(ga.list_accounts())
    assert got == [ga.Account("HaziqLucii", True), ga.Account("work-account", False)]
    ga.reset()
    fake.flag("nojson")
    assert run(ga.list_accounts()) == got


def test_no_gh_on_path(fake, monkeypatch, tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    monkeypatch.setenv("PATH", str(empty))
    assert run(ga.list_accounts()) == []
    payload = run(ga.accounts_payload())
    assert payload == {"gh_available": False, "default": None, "accounts": []}
    with pytest.raises(ga.LoginError) as exc:
        run(ga.start_login())
    assert exc.value.reason == "gh_missing"


# ------------------------------------------------------------------ resolver


def test_override_wins_and_matches_case_insensitively(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])
    res = run(ga.resolve("org/repo", "a"))
    assert res == ga.Resolution("A", "override")
    assert fake.probes() == []


def test_auto_picks_the_account_that_can_read_the_repo(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])
    assert run(ga.resolve("org/repo")) == ga.Resolution("B", "auto")


def test_auto_probe_order_owner_then_default_among_accounts_with_push(fake):
    fake.accounts(("A", True), ("B", False), ("C", False))
    fake.access(A=["x/pub"], B=["x/pub", "B/own"], C=["x/pub"])
    assert run(ga.resolve("B/own")) == ga.Resolution("B", "auto")
    assert fake.probes()[0] == "PROBE B/own as B"
    ga.set_default("C")
    assert run(ga.resolve("x/pub")) == ga.Resolution("C", "auto")
    assert fake.probes()[-1] == "PROBE x/pub as C"


def test_falls_back_to_default_then_terminal_then_none(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access()
    assert run(ga.resolve("org/private")) == ga.Resolution("A", "terminal")
    ga.set_default("B")
    assert run(ga.resolve("org/private")) == ga.Resolution("B", "default")
    assert run(ga.resolve(None)) == ga.Resolution("B", "default")
    fake.accounts()
    ga.reset()
    assert run(ga.resolve("org/private")) == ga.Resolution(None, "none")


def test_stale_default_is_ignored(fake):
    fake.accounts(("A", True))
    fake.access()
    ga.set_default("Gone")
    assert run(ga.resolve("o/r")) == ga.Resolution("A", "terminal")
    assert run(ga.accounts_payload())["default"] is None


def test_auto_result_is_cached_until_invalidated(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])
    run(ga.resolve("org/repo"))
    n = len(fake.probes())
    assert n >= 1
    run(ga.resolve("org/repo"))
    run(ga.resolve("ORG/repo"))
    assert len(fake.probes()) == n

    ga.invalidate("org/repo")
    run(ga.resolve("org/repo"))
    assert len(fake.probes()) > n


def test_cache_dropped_on_default_change_account_change_and_404(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])
    run(ga.resolve("org/repo"))
    count = len(fake.probes())

    ga.set_default("A")
    run(ga.resolve("org/repo"))
    assert len(fake.probes()) > count
    count = len(fake.probes())

    fake.accounts(("A", True), ("B", False), ("C", False))
    run(ga.list_accounts(force=True))
    run(ga.resolve("org/repo"))
    assert len(fake.probes()) > count
    count = len(fake.probes())

    ga._cwd_slug["/some/cwd"] = "org/repo"
    ga.note_gh_result("/some/cwd", 1, "GraphQL: Could not resolve to a Repository with the name")
    run(ga.resolve("org/repo"))
    assert len(fake.probes()) > count
    count = len(fake.probes())

    ga.note_gh_result("/some/cwd", 1, "no pull requests found")
    ga.note_gh_result("/some/cwd", 0, "HTTP 404")
    run(ga.resolve("org/repo"))
    assert len(fake.probes()) == count


def test_unresolved_is_cached_briefly(fake, monkeypatch):
    fake.accounts(("A", True))
    fake.access()
    run(ga.resolve("o/r"))
    n = len(fake.probes())
    run(ga.resolve("o/r"))
    assert len(fake.probes()) == n
    monkeypatch.setattr(ga, "UNRESOLVED_TTL", -1.0)
    ga.invalidate()
    run(ga.resolve("o/r"))
    ga._auto_cache["o/r"].expires = 0
    run(ga.resolve("o/r"))
    assert len(fake.probes()) > n


def test_probe_timeout_counts_as_unresolved(fake, monkeypatch):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])
    fake.flag("slowprobe")
    monkeypatch.setattr(ga, "PROBE_TIMEOUT", 0.3)
    ga.set_default("B")
    started = time.monotonic()
    assert run(ga.resolve("org/repo")) == ga.Resolution("B", "default")
    assert time.monotonic() - started < 5


def test_concurrent_resolves_share_one_probe_round(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])

    async def go():
        return await asyncio.gather(*[ga.resolve("org/repo") for _ in range(5)])

    results = run(go())
    assert all(r == ga.Resolution("B", "auto") for r in results)
    assert len(fake.probes()) == 2


# ------------------------------------------------------------------ gh_env


def _project(tmp_path, origin, **kw) -> tuple[Project, str]:
    repo = _repo(tmp_path / "repo", origin)
    p = Project(id="p1", name="repo", path=repo, default_branch="main", remote_url=origin, **kw)
    main_mod.store.projects[p.id] = p
    return p, repo


def test_gh_env_adds_token_and_keeps_pinned_repo(fake, tmp_path):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["acme/widgets"])
    _p, repo = _project(tmp_path, "https://github.com/acme/widgets.git")
    env = run(git_ops.gh_env(repo))
    assert env["GH_REPO"] == "acme/widgets"
    assert env["GH_TOKEN"] == "tok_B_SECRETVALUE"
    assert not any("auth switch" in c for c in fake.calls())


def test_gh_env_override_applies_for_a_workspace_worktree(fake, tmp_path):
    fake.accounts(("A", True), ("B", False))
    fake.access(A=["o/r"], B=["o/r"])
    p, _repo_path = _project(tmp_path, "https://github.com/o/r.git", gh_account="B")
    wt = tmp_path / "worktrees" / "ws1"
    subprocess.run(["git", "init", "-q", str(wt)], check=True)
    subprocess.run(["git", "-C", str(wt), "remote", "add", "origin", p.remote_url], check=True)
    main_mod.store.workspaces["ws1"] = Workspace(
        id="ws1", project_id=p.id, name="w", branch="b", worktree_path=str(wt), base_ref="main"
    )
    env = run(git_ops.gh_env(str(wt)))
    assert env["GH_TOKEN"] == "tok_B_SECRETVALUE"
    assert fake.probes() == []


def test_gh_env_without_a_resolved_account_matches_the_old_behaviour(fake, tmp_path):
    repo = _repo(tmp_path / "a", "https://github.com/o/r.git")
    fake.accounts()
    env = run(git_ops.gh_env(repo))
    assert env["GH_REPO"] == "o/r" and "GH_TOKEN" not in env
    fake.accounts(("A", True))
    fake.access()
    ga.reset()
    env = run(git_ops.gh_env(repo))
    assert env["GH_REPO"] == "o/r" and "GH_TOKEN" not in env  # terminal fallback: gh decides


def test_gh_env_user_set_repo_is_never_overridden(fake, tmp_path, monkeypatch):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["o/r"])
    repo = _repo(tmp_path / "a", "https://github.com/o/r.git")
    monkeypatch.setenv("GH_REPO", "mine/chosen")
    env = run(git_ops.gh_env(repo))
    assert env["GH_REPO"] == "mine/chosen" and env["GH_TOKEN"] == "tok_B_SECRETVALUE"
    fake.accounts()
    ga.reset()
    assert run(git_ops.gh_env(repo)) is None


def test_gh_env_leaves_a_user_set_token_alone(fake, tmp_path, monkeypatch):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["o/r"])
    repo = _repo(tmp_path / "a", "https://github.com/o/r.git")
    monkeypatch.setenv("GH_TOKEN", "user-own-token")
    env = run(git_ops.gh_env(repo))
    assert env["GH_TOKEN"] == "user-own-token"
    assert fake.probes() == []


def test_gh_env_non_github_or_missing_origin_is_none(fake, tmp_path):
    fake.accounts(("A", True))
    assert run(git_ops.gh_env(_repo(tmp_path / "a", "https://gitlab.com/o/r.git"))) is None
    assert run(git_ops.gh_env(str(tmp_path / "missing"))) is None


def test_gh_env_survives_a_resolver_failure(fake, tmp_path, monkeypatch):
    repo = _repo(tmp_path / "a", "https://github.com/o/r.git")

    async def boom(*_a, **_k):
        raise RuntimeError("keyring exploded")

    monkeypatch.setattr(ga, "token_for_repo", boom)
    env = run(git_ops.gh_env(repo))
    assert env["GH_REPO"] == "o/r" and "GH_TOKEN" not in env


# ------------------------------------------------------------------ endpoints


def test_accounts_endpoint_shape(fake):
    fake.accounts(("HaziqLucii", True), ("work-account", False))
    res = run(main_mod.list_github_accounts())
    assert res == {
        "gh_available": True,
        "default": None,
        "accounts": [
            {"login": "HaziqLucii", "avatar_url": "https://github.com/HaziqLucii.png?size=64",
             "is_default": False, "terminal_active": True},
            {"login": "work-account", "avatar_url": "https://github.com/work-account.png?size=64",
             "is_default": False, "terminal_active": False},
        ],
    }


def test_default_endpoint_persists_and_404s(fake, tmp_path):
    fake.accounts(("A", True), ("B", False))
    out = run(main_mod.set_github_default(ga.GhDefaultRequest(login="b")))
    assert out == {"default": "B"}
    assert json.loads((tmp_path / "github.json").read_text()) == {"default": "B"}
    res = run(main_mod.list_github_accounts())
    assert res["default"] == "B"
    assert [a["is_default"] for a in res["accounts"]] == [False, True]
    with pytest.raises(HTTPException) as exc:
        run(main_mod.set_github_default(ga.GhDefaultRequest(login="nobody")))
    assert exc.value.status_code == 404


def test_project_gh_account_endpoints(fake, tmp_path):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["o/r"])
    p, _repo_path = _project(tmp_path, "https://github.com/o/r.git")
    assert run(main_mod.get_project_gh_account(p.id)) == {
        "override": None, "resolved": "B", "source": "auto"}
    out = run(main_mod.set_project_gh_account(p.id, ga.GhAccountRequest(login="a")))
    assert out == {"override": "A", "resolved": "A", "source": "override"}
    assert p.gh_account == "A"
    out = run(main_mod.set_project_gh_account(p.id, ga.GhAccountRequest(login=None)))
    assert out == {"override": None, "resolved": "B", "source": "auto"}
    for call in (
        lambda: main_mod.get_project_gh_account("nope"),
        lambda: main_mod.set_project_gh_account("nope", ga.GhAccountRequest(login=None)),
        lambda: main_mod.set_project_gh_account(p.id, ga.GhAccountRequest(login="ghost")),
    ):
        with pytest.raises(HTTPException) as exc:
            run(call())
        assert exc.value.status_code == 404


def test_project_json_carries_gh_account(fake, tmp_path):
    p, _r = _project(tmp_path, "https://github.com/o/r.git", gh_account="B")
    assert json.loads(p.model_dump_json())["gh_account"] == "B"
    assert Project(name="n", path="/p", default_branch="main").gh_account is None


def test_no_token_in_any_response_log_or_output(fake, tmp_path, caplog, capsys):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["o/r"])
    fake.mode("ok")
    p, repo = _project(tmp_path, "https://github.com/o/r.git")
    responses = [
        run(main_mod.list_github_accounts()),
        run(main_mod.get_project_gh_account(p.id)),
        run(main_mod.set_project_gh_account(p.id, ga.GhAccountRequest(login="B"))),
        run(main_mod.set_github_default(ga.GhDefaultRequest(login="B"))),
    ]
    run(git_ops.gh_env(repo))

    async def login():
        started = await ga.start_login()
        responses.append(started)
        await _wait_state(started["id"], "done")
        responses.append(ga.login_status(started["id"]))

    run(login())
    blob = json.dumps(responses) + caplog.text + capsys.readouterr().out + "\n".join(fake.calls())
    assert SECRET not in blob and "tok_" not in blob


# ------------------------------------------------------------------ device login


async def _wait_state(login_id: str, state: str, timeout: float = 8.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = ga.login_status(login_id)
        if status["state"] == state:
            return status
        await asyncio.sleep(0.05)
    raise AssertionError(f"login never reached {state}: {ga.login_status(login_id)}")


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_login_success_restores_terminal_account_and_isolates_gitconfig(fake, tmp_path, monkeypatch):
    fake.accounts(("A", True))
    fake.mode("ok", new="NewUser")
    real_home = tmp_path / "home"
    real_home.mkdir()
    real_cfg = real_home / ".gitconfig"
    real_cfg.write_text("[includeIf \"gitdir:~/x/\"]\n\tpath = ~/.gitconfig-personal\n")
    before = (real_cfg.read_text(), real_cfg.stat().st_mtime_ns)
    machine_cfg = Path.home() / ".gitconfig"
    machine_before = machine_cfg.stat().st_mtime_ns if machine_cfg.exists() else None
    monkeypatch.setenv("HOME", str(real_home))
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)

    async def go():
        started = await ga.start_login()
        assert started["code"] == "AB12-CD34"
        assert started["url"] == "https://github.com/login/device"
        assert ga.login_status(started["id"]) == {"state": "pending", "login": None, "error": None}
        env = fake.login_env()
        cfg = env["GIT_CONFIG_GLOBAL"]
        assert cfg and Path(cfg) != real_cfg and env["GIT_TERMINAL_PROMPT"] == "0"
        assert env["stdin_isatty"] is False
        done = await _wait_state(started["id"], "done")
        payload = await ga.accounts_payload()
        assert [a["login"] for a in payload["accounts"] if a["terminal_active"]] == ["A"]
        return cfg, done

    cfg, done = run(go())
    assert done == {"state": "done", "login": "NewUser", "error": None}
    assert (real_cfg.read_text(), real_cfg.stat().st_mtime_ns) == before
    assert (machine_cfg.stat().st_mtime_ns if machine_cfg.exists() else None) == machine_before
    assert not Path(cfg).exists()
    assert "auth switch -h github.com -u A" in fake.calls()
    assert [a["login"] for a in fake.state() if a["active"]] == ["A"]


def test_login_of_an_existing_account_reports_it_and_restores_previous(fake):
    fake.accounts(("A", True), ("B", False))
    fake.mode("ok", new="B")

    async def go():
        started = await ga.start_login()
        return await _wait_state(started["id"], "done")

    assert run(go())["login"] == "B"
    assert [a["login"] for a in fake.state() if a["active"]] == ["A"]


def test_login_from_zero_accounts_has_nothing_to_restore(fake):
    fake.accounts()
    fake.mode("ok", new="First")

    async def go():
        started = await ga.start_login()
        return await _wait_state(started["id"], "done")

    assert run(go())["login"] == "First"
    assert not any(c.startswith("auth switch") for c in fake.calls())


def test_second_login_is_refused_while_one_is_pending(fake):
    fake.accounts(("A", True))
    fake.mode("hang")

    async def go():
        started = await ga.start_login()
        refused = await main_mod.start_github_login()
        await ga.cancel_login(started["id"])
        return refused

    refused = run(go())
    assert refused.status_code == 409
    assert json.loads(refused.body)["reason"] == "login_in_progress"


def test_failed_login_reports_a_redacted_error(fake):
    fake.accounts(("A", True))

    async def go(mode):
        fake.mode(mode)
        started = await ga.start_login()
        return await _wait_state(started["id"], "failed")

    failed = run(go("fail"))
    assert failed["login"] is None and failed["error"] == "error: authentication failed"
    ga.reset()
    leaked = run(go("leak"))
    assert "SECRET" not in leaked["error"] and "gho_" not in leaked["error"]


def test_no_code_from_gh_is_a_login_failed_error_and_frees_the_slot(fake):
    fake.accounts(("A", True))
    fake.mode("nocode")

    async def go():
        res = await main_mod.start_github_login()
        fake.mode("ok", new="B")
        again = await ga.start_login()
        await _wait_state(again["id"], "done")
        return res

    res = run(go())
    assert res.status_code == 502 and json.loads(res.body)["reason"] == "login_failed"


def test_cancel_kills_the_child_and_removes_the_temp_config(fake):
    fake.accounts(("A", True))
    fake.mode("hang")

    async def go():
        started = await ga.start_login()
        cfg = fake.login_env()["GIT_CONFIG_GLOBAL"]
        pid = fake.pid()
        assert _alive(pid)
        out = await main_mod.cancel_github_login(started["id"])
        return started["id"], cfg, pid, out

    login_id, cfg, pid, out = run(go())
    assert out == {"state": "cancelled"}
    assert ga.login_status(login_id)["state"] == "cancelled"
    assert not _alive(pid) and not Path(cfg).exists()
    assert not any(c.startswith("auth switch") for c in fake.calls())


def test_unknown_login_id_is_404(fake):
    with pytest.raises(HTTPException) as exc:
        run(main_mod.get_github_login("nope"))
    assert exc.value.status_code == 404
    with pytest.raises(HTTPException) as exc:
        run(main_mod.cancel_github_login("nope"))
    assert exc.value.status_code == 404


def test_login_session_expires(fake, monkeypatch):
    fake.accounts(("A", True))
    fake.mode("hang")
    monkeypatch.setattr(ga, "LOGIN_TTL", 0.5)

    async def go():
        started = await ga.start_login()
        cfg = fake.login_env()["GIT_CONFIG_GLOBAL"]
        pid = fake.pid()
        status = await _wait_state(started["id"], "failed")
        await asyncio.sleep(0.1)
        return status, cfg, pid

    status, cfg, pid = run(go())
    assert status["error"] == "login expired"
    assert not _alive(pid) and not Path(cfg).exists()


def test_shutdown_leaves_no_login_child(fake):
    fake.accounts(("A", True))
    fake.mode("hang")

    async def go():
        await ga.start_login()
        cfg = fake.login_env()["GIT_CONFIG_GLOBAL"]
        pid = fake.pid()
        await ga.shutdown()
        return cfg, pid

    cfg, pid = run(go())
    assert not _alive(pid) and not Path(cfg).exists()


# ------------------------------------------------------------------ push-aware auto resolution


def test_public_org_repo_goes_to_the_account_with_push_not_the_default(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(A=["acme/x:read"], B=["acme/x"])
    ga.set_default("A")
    assert run(ga.resolve("acme/x")) == ga.Resolution("B", "auto")


def test_nobody_has_push_prefers_the_terminal_account_then_default_then_any_reader(fake):
    fake.accounts(("A", True), ("B", False), ("C", False))
    fake.access(A=["o/pub:read"], B=["o/pub:read"], C=["o/pub:read"])
    ga.set_default("B")
    assert run(ga.resolve("o/pub")) == ga.Resolution("A", "auto")

    ga.reset()
    fake.access(B=["o/pub:read"], C=["o/pub:read"])
    assert run(ga.resolve("o/pub")) == ga.Resolution("B", "auto")

    ga.reset()
    fake.access(C=["o/pub:read"])
    assert run(ga.resolve("o/pub")) == ga.Resolution("C", "auto")


def test_probe_asks_for_the_push_permission_and_never_trusts_a_missing_one(fake):
    fake.accounts(("A", True))
    fake.access(A=["o/pub:read"])
    run(ga.resolve("o/pub"))
    assert any(c.startswith("api repos/o/pub --jq .permissions.push") for c in fake.calls())


def test_permission_errors_also_drop_the_cached_account(fake):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["org/repo"])
    run(ga.resolve("org/repo"))
    ga._cwd_slug["/cwd"] = "org/repo"
    for text in (
        "HTTP 403: Resource not accessible by integration",
        "GraphQL: user must have push access",
        "gh: Forbidden (HTTP 403)",
    ):
        count = len(fake.probes())
        ga.note_gh_result("/cwd", 1, text)
        run(ga.resolve("org/repo"))
        assert len(fake.probes()) > count, text


def test_a_probe_round_overtaken_by_an_invalidate_does_not_write_the_cache(fake):
    fake.accounts(("A", True))
    fake.access(A=["o/r"])
    fake.flag("delayprobe")

    async def go():
        task = asyncio.ensure_future(ga.resolve("o/r"))
        await asyncio.sleep(0.25)
        ga.invalidate()
        res = await task
        await asyncio.sleep(0.1)
        return res

    assert run(go()) == ga.Resolution("A", "auto")
    assert "o/r" not in ga._auto_cache


def test_cancelling_a_gh_call_kills_the_child(fake):
    fake.accounts(("A", True))
    fake.flag("slowstatus")

    async def go():
        task = asyncio.ensure_future(ga.list_accounts())
        for _ in range(100):
            if (fake.dir / "status.pid").exists():
                break
            await asyncio.sleep(0.05)
        pid = int((fake.dir / "status.pid").read_text())
        assert _alive(pid)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        return pid

    assert not _alive(run(go()))


def test_project_payload_reads_the_live_origin_like_gh_env(fake, tmp_path):
    fake.accounts(("A", True), ("B", False))
    fake.access(B=["o/r"])
    repo = _repo(tmp_path / "repo", "https://github.com/o/r.git")
    p = Project(id="p1", name="repo", path=repo, default_branch="main",
                remote_url="https://github.com/stale/old.git")
    main_mod.store.projects[p.id] = p
    assert run(main_mod.get_project_gh_account(p.id)) == {
        "override": None, "resolved": "B", "source": "auto"}
    assert run(git_ops.gh_env(repo))["GH_TOKEN"] == "tok_B_SECRETVALUE"


# ------------------------------------------------------------------ terminal restore on every path


def _active(fake: Fake) -> list[str]:
    return [a["login"] for a in fake.state() if a["active"]]


def _switches(fake: Fake) -> list[str]:
    return [c for c in fake.calls() if c.startswith("auth switch")]


async def _wait_active(fake: Fake, login: str, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _active(fake) == [login]:
            return
        await asyncio.sleep(0.05)
    raise AssertionError(f"{login} never became active")


def test_cancel_after_the_token_was_stored_restores_the_terminal_account(fake):
    fake.accounts(("A", True))
    fake.mode("store_hang", new="NewUser")

    async def go():
        started = await ga.start_login()
        await _wait_active(fake, "NewUser")
        out = await ga.cancel_login(started["id"])
        return out, await ga.accounts_payload()

    out, payload = run(go())
    assert out == {"state": "cancelled"}
    assert _active(fake) == ["A"]
    assert [a["login"] for a in payload["accounts"] if a["terminal_active"]] == ["A"]


def test_nonzero_exit_after_storing_restores_the_terminal_account(fake):
    fake.accounts(("A", True))
    fake.mode("store_fail", new="NewUser")

    async def go():
        started = await ga.start_login()
        return await _wait_state(started["id"], "failed")

    failed = run(go())
    assert failed["error"] == "error: could not finish"
    assert _active(fake) == ["A"]


def test_expiry_restores_the_terminal_account(fake, monkeypatch):
    fake.accounts(("A", True))
    fake.mode("store_hang", new="NewUser")
    monkeypatch.setattr(ga, "LOGIN_TTL", 0.8)

    async def go():
        started = await ga.start_login()
        await _wait_active(fake, "NewUser")
        return await _wait_state(started["id"], "failed")

    assert run(go())["error"] == "login expired"
    assert _active(fake) == ["A"]


def test_shutdown_restores_the_terminal_account(fake):
    fake.accounts(("A", True))
    fake.mode("store_hang", new="NewUser")

    async def go():
        await ga.start_login()
        await _wait_active(fake, "NewUser")
        await ga.shutdown()

    run(go())
    assert _active(fake) == ["A"]


def test_no_switch_when_the_previous_account_is_the_one_logged_in(fake):
    fake.accounts(("A", True), ("B", False))
    fake.mode("store_fail", new="A")

    async def go():
        started = await ga.start_login()
        return await _wait_state(started["id"], "failed")

    run(go())
    assert _switches(fake) == [] and _active(fake) == ["A"]


def test_no_previous_account_means_nothing_to_restore(fake):
    fake.accounts()
    fake.mode("store_hang", new="First")

    async def go():
        started = await ga.start_login()
        await _wait_active(fake, "First")
        await ga.cancel_login(started["id"])

    run(go())
    assert _switches(fake) == [] and _active(fake) == ["First"]


def test_restore_is_skipped_when_the_previous_account_was_removed_meanwhile(fake):
    fake.accounts(("A", True))
    fake.mode("store_hang", new="NewUser")

    async def go():
        started = await ga.start_login()
        await _wait_active(fake, "NewUser")
        fake.accounts(("NewUser", True))
        await ga.cancel_login(started["id"])

    run(go())
    assert _switches(fake) == []


def test_login_in_progress_response_carries_the_pending_session_id(fake):
    fake.accounts(("A", True))
    fake.mode("hang")

    async def go():
        started = await ga.start_login()
        refused = await main_mod.start_github_login()
        await ga.cancel_login(started["id"])
        return started["id"], refused

    login_id, refused = run(go())
    assert refused.status_code == 409
    assert json.loads(refused.body) == {
        "detail": "login_in_progress", "reason": "login_in_progress", "id": login_id}


# ------------------------------------------------------------------ the gitconfig guard can fail


def test_login_without_the_throwaway_gitconfig_would_hit_the_real_one(fake, tmp_path, monkeypatch):
    """Proves the assertion in the success test has teeth: strip GIT_CONFIG_GLOBAL and the fake
    gh (like the real one) writes to the HOME-based config."""
    fake.accounts(("A", True))
    fake.mode("ok", new="B")
    home = tmp_path / "home"
    home.mkdir()
    real_cfg = home / ".gitconfig"
    real_cfg.write_text("[user]\n\tname = x\n")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)
    original = ga._env
    monkeypatch.setattr(
        ga, "_env",
        lambda extra=None: original({k: v for k, v in (extra or {}).items() if k != "GIT_CONFIG_GLOBAL"}),
    )

    async def go():
        started = await ga.start_login()
        await _wait_state(started["id"], "done")

    run(go())
    assert "credential" in real_cfg.read_text()


def test_haro_always_sets_a_throwaway_gitconfig_and_the_real_one_is_untouched(fake, tmp_path, monkeypatch):
    fake.accounts(("A", True))
    fake.mode("ok", new="B")
    home = tmp_path / "home"
    home.mkdir()
    real_cfg = home / ".gitconfig"
    real_cfg.write_text("[user]\n\tname = x\n")
    before = (real_cfg.read_text(), real_cfg.stat().st_mtime_ns)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)

    async def go():
        started = await ga.start_login()
        cfg = fake.login_env()["GIT_CONFIG_GLOBAL"]
        await _wait_state(started["id"], "done")
        return cfg

    cfg = run(go())
    assert cfg and Path(cfg) != real_cfg and not Path(cfg).exists()
    assert (real_cfg.read_text(), real_cfg.stat().st_mtime_ns) == before
