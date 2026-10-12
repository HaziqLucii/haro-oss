"""Contract tests for the shipped Merge Firewall git hook (backlog/merge-firewall.md §3).

The hook (``haro/assets/firewall/hook.sh``) is a POSIX-sh script installed into a repo's
shared hooks dir as both ``pre-push`` and ``pre-merge-commit``. Nothing else in the suite
exercises shell assets, so this pins its contract: it must parse as POSIX sh, and — driven
against a stub verdict endpoint in a throwaway git repo — a *red* verdict must exit 1 and
name the workspace, a *green* verdict must exit 0, and an *unreachable* backend must
fail open (exit 0 with a warning). The end-to-end firewall flow is a separate §3 item.
"""

from __future__ import annotations

import http.server
import shutil
import subprocess
import threading
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parents[1] / "haro" / "assets" / "firewall" / "hook.sh"

_BODIES = {
    "red": b'{"verdict":"red","workspace_id":"ws_abc123","gate":{"status":"failed"}}',
    "green": b'{"verdict":"green","workspace_id":"ws_abc123"}',
    "unknown": b'{"verdict":"unknown"}',
}


def _need(tool: str) -> None:
    if shutil.which(tool) is None:
        pytest.skip(f"{tool} not available")


def test_hook_parses_as_posix_sh():
    _need("sh")
    assert HOOK.exists(), "firewall hook asset is missing"
    # `sh -n` parses without executing — a syntax regression fails here regardless of runtime.
    proc = subprocess.run(["sh", "-n", str(HOOK)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


class _StubServer:
    """Serves a fixed verdict JSON body on 127.0.0.1 for one test."""

    def __init__(self, verdict: str):
        body = _BODIES[verdict]

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 (http.server API)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):  # silence per-request stderr noise
                pass

        self._srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self._srv.server_address[1]}"

    def __enter__(self):
        self._t = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._t.start()
        return self

    def __exit__(self, *exc):
        self._srv.shutdown()
        self._srv.server_close()


@pytest.fixture
def repo(tmp_path):
    """A real git repo on branch feat/x with the hook copied under both invocation names."""
    for tool in ("git", "curl", "sh"):
        _need(tool)
    root = tmp_path / "repo"
    root.mkdir()

    def git(*args):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)

    git("init", "-q")
    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    git("commit", "-q", "--allow-empty", "-m", "init")
    git("branch", "-M", "feat/x")
    for name in ("pre-push", "pre-merge-commit"):
        dst = root / name
        shutil.copy(HOOK, dst)
        dst.chmod(0o755)
    return root


def _set_url(repo: Path, url: str) -> None:
    subprocess.run(["git", "config", "haro.url", url], cwd=repo, check=True)


def _set_strict(repo: Path, on: bool) -> None:
    subprocess.run(
        ["git", "config", "haro.strict", "true" if on else "false"], cwd=repo, check=True
    )


_ZERO = "0" * 40
_SHA = "1" * 40
_PUSH_LINE = f"refs/heads/feat/x {_SHA} refs/heads/feat/x {_ZERO}\n"


def _run_hook(repo: Path, name: str, stdin: str = "", env: dict | None = None):
    import os

    return subprocess.run(
        [str(repo / name), "origin", "http://example"],
        cwd=repo, input=stdin, capture_output=True, text=True,
        env={**os.environ, **env} if env else None,
    )


def test_red_verdict_blocks_pre_push(repo):
    with _StubServer("red") as srv:
        _set_url(repo, srv.url)
        proc = _run_hook(repo, "pre-push", _PUSH_LINE)
    assert proc.returncode == 1
    assert "feat/x" in proc.stderr
    assert "ws_abc123" in proc.stderr  # names the workspace


def test_red_verdict_blocks_pre_merge_commit(repo):
    with _StubServer("red") as srv:
        _set_url(repo, srv.url)
        proc = _run_hook(repo, "pre-merge-commit")
    assert proc.returncode == 1
    assert "ws_abc123" in proc.stderr


def test_green_verdict_allows(repo):
    with _StubServer("green") as srv:
        _set_url(repo, srv.url)
        proc = _run_hook(repo, "pre-push", _PUSH_LINE)
    assert proc.returncode == 0, proc.stderr


def test_branch_deletion_skipped(repo):
    # A delete push has a zero local sha and nothing to gate — never blocks, even on red.
    with _StubServer("red") as srv:
        _set_url(repo, srv.url)
        proc = _run_hook(repo, "pre-push", f":refs/heads/feat/x {_ZERO} refs/heads/feat/x {_SHA}\n")
    assert proc.returncode == 0, proc.stderr


def test_backend_unreachable_fails_open(repo):
    _set_url(repo, "http://127.0.0.1:1")  # nothing listening
    proc = _run_hook(repo, "pre-merge-commit")
    assert proc.returncode == 0
    assert "fail-open" in proc.stderr


def test_backend_unreachable_strict_fails_closed(repo):
    # [trust] strict flips the unreachable path from fail-open to fail-closed.
    _set_url(repo, "http://127.0.0.1:1")  # nothing listening
    _set_strict(repo, True)
    proc = _run_hook(repo, "pre-merge-commit")
    assert proc.returncode == 1
    assert "strict" in proc.stderr
    assert "unreachable" in proc.stderr


def test_unknown_verdict_warns_and_allows_by_default(repo):
    # A branch haro doesn't govern (never adopted / not gated) — warn, but don't block.
    with _StubServer("unknown") as srv:
        _set_url(repo, srv.url)
        proc = _run_hook(repo, "pre-push", _PUSH_LINE)
    assert proc.returncode == 0, proc.stderr
    assert "unknown to haro" in proc.stderr


def test_unknown_verdict_blocks_under_strict(repo):
    with _StubServer("unknown") as srv:
        _set_url(repo, srv.url)
        _set_strict(repo, True)
        proc = _run_hook(repo, "pre-push", _PUSH_LINE)
    assert proc.returncode == 1
    assert "feat/x" in proc.stderr


def test_red_verdict_blocks_even_under_strict(repo):
    # Strict never loosens the red block — a red gate stays blocked with or without it.
    with _StubServer("red") as srv:
        _set_url(repo, srv.url)
        _set_strict(repo, True)
        proc = _run_hook(repo, "pre-push", _PUSH_LINE)
    assert proc.returncode == 1
    assert "ws_abc123" in proc.stderr


def test_green_verdict_allows_under_strict(repo):
    # Strict blocks the ungoverned; a proven-green branch still merges.
    with _StubServer("green") as srv:
        _set_url(repo, srv.url)
        _set_strict(repo, True)
        proc = _run_hook(repo, "pre-push", _PUSH_LINE)
    assert proc.returncode == 0, proc.stderr


def test_haro_internal_bypasses_even_red_under_strict(repo):
    # "Don't firewall ourselves": HARO_INTERNAL=1 (exported by git_ops._git) short-circuits
    # the hook so haro's own integrate/merge-queue/gate merges are never blocked — even a red
    # verdict under strict must be let through, and the backend must not even be consulted.
    with _StubServer("red") as srv:
        _set_url(repo, srv.url)
        _set_strict(repo, True)
        proc = _run_hook(repo, "pre-merge-commit", env={"HARO_INTERNAL": "1"})
    assert proc.returncode == 0, proc.stderr
    assert proc.stderr == ""  # bypassed before any verdict/log output


def test_haro_internal_unset_still_enforces(repo):
    # The bypass is opt-in: without the marker a red verdict still blocks (regression guard so
    # the `set -u` default doesn't accidentally read as "internal").
    with _StubServer("red") as srv:
        _set_url(repo, srv.url)
        proc = _run_hook(repo, "pre-merge-commit")
    assert proc.returncode == 1


# --------------------------------------------------------------------------- #
# The fast-forward hole (backlog/merge-firewall.md §5)
# --------------------------------------------------------------------------- #
@pytest.fixture
def ff_repo(tmp_path):
    """A repo with `main` and a mergeable `feature`, hooks installed where git runs them.

    Unlike `repo` above (which invokes hook files directly), this drives REAL git commands,
    because the whole point of the bug was that git never invoked the hook at all.
    """
    for tool in ("git", "curl", "sh"):
        _need(tool)
    root = tmp_path / "ffrepo"
    root.mkdir()

    def git(*args):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)

    git("init", "-q", "-b", "main")
    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    (root / "f.txt").write_text("1\n")
    git("add", "-A")
    git("commit", "-qm", "init")
    git("checkout", "-q", "-b", "feature")
    (root / "f.txt").write_text("1\n2\n")
    git("commit", "-qam", "feature work")
    git("checkout", "-q", "main")

    hooks = root / ".git" / "hooks"
    hooks.mkdir(parents=True, exist_ok=True)
    for name in ("pre-push", "pre-merge-commit", "reference-transaction"):
        dst = hooks / name
        shutil.copy(HOOK, dst)
        dst.chmod(0o755)
    return root


def _head(repo: Path, ref: str = "main") -> str:
    return subprocess.run(
        ["git", "rev-parse", ref], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()


def test_fast_forward_merge_of_a_red_branch_is_blocked(ff_repo):
    """THE regression guard. git does not run pre-merge-commit for a fast-forward, so this
    merge used to land red work with exit 0 and no hook output at all — and a branch cut
    from current main fast-forwards by default, so it was the common case, not a corner."""
    before = _head(ff_repo)
    with _StubServer("red") as srv:
        _set_url(ff_repo, srv.url)
        proc = subprocess.run(
            ["git", "merge", "--ff-only", "feature"],
            cwd=ff_repo, capture_output=True, text=True,
        )
    assert proc.returncode != 0, "a fast-forward merge of a red branch must not succeed"
    assert "ws_abc123" in proc.stderr, "the refusal must name the offending workspace"
    assert _head(ff_repo) == before, "main must not have moved"


def test_fast_forward_merge_of_a_green_branch_still_works(ff_repo):
    """The firewall must not become a brick: a proven-green branch fast-forwards normally."""
    before = _head(ff_repo)
    with _StubServer("green") as srv:
        _set_url(ff_repo, srv.url)
        proc = subprocess.run(
            ["git", "merge", "--ff-only", "feature"],
            cwd=ff_repo, capture_output=True, text=True,
        )
    assert proc.returncode == 0, proc.stderr
    assert _head(ff_repo) != before, "the green branch should have landed"


def test_reset_hard_onto_a_red_branch_tip_is_blocked(ff_repo):
    """Same ref-update path as a fast-forward, so it must be covered by the same hook."""
    before = _head(ff_repo)
    with _StubServer("red") as srv:
        _set_url(ff_repo, srv.url)
        subprocess.run(
            ["git", "reset", "--hard", "feature"], cwd=ff_repo, capture_output=True, text=True
        )
    assert _head(ff_repo) == before, "main must not have been moved onto a red tip"


def test_an_ordinary_commit_is_not_firewalled_and_costs_no_backend_call(ff_repo):
    """Noise budget. reference-transaction fires many times per git operation, so the hook
    must resolve "is a governed branch arriving?" LOCALLY. A fresh commit is nobody's branch
    tip, so there are no candidates and the backend is never consulted — which is also why a
    red stub cannot block routine work."""
    # No stub server at all: an unreachable backend would still warn on stderr if consulted.
    _set_url(ff_repo, "http://127.0.0.1:1")  # nothing listening
    (ff_repo / "g.txt").write_text("x\n")
    subprocess.run(["git", "add", "-A"], cwd=ff_repo, check=True, capture_output=True)
    proc = subprocess.run(
        ["git", "commit", "-qm", "ordinary work"], cwd=ff_repo, capture_output=True, text=True
    )
    assert proc.returncode == 0, proc.stderr
    assert "haro firewall" not in proc.stderr, (
        "an ordinary commit must not consult the backend at all"
    )


def test_pre_merge_commit_judges_the_incoming_branch_not_the_target(ff_repo):
    """The merge path used to call check() with `git symbolic-ref HEAD` — the branch being
    merged INTO. On main (which no workspace owns) that asked the wrong question entirely and
    only ever blocked because `strict` refuses ungoverned branches. It must name the SOURCE."""
    # Force a real merge commit so pre-merge-commit actually runs.
    (ff_repo / "other.txt").write_text("main side\n")
    subprocess.run(["git", "add", "-A"], cwd=ff_repo, check=True, capture_output=True)
    subprocess.run(
        ["git", "commit", "-qm", "main diverges"], cwd=ff_repo, check=True, capture_output=True
    )
    with _StubServer("red") as srv:
        _set_url(ff_repo, srv.url)
        proc = subprocess.run(
            ["git", "merge", "--no-ff", "--no-edit", "feature"],
            cwd=ff_repo, capture_output=True, text=True,
        )
    assert proc.returncode != 0
    assert "feature" in proc.stderr, f"should name the incoming branch, got: {proc.stderr}"
    assert "BLOCKED 'main'" not in proc.stderr, "must not judge the target branch"
