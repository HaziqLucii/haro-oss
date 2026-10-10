"""Merge Firewall hook installer (backlog/merge-firewall.md §3).

Installs the repo-level git hook (``assets/firewall/hook.sh``) under both
``pre-push`` and ``pre-merge-commit``, so a single install governs every worktree
— foreign ones (native Claude Code, claude-squad, a bare terminal) included. Also
writes the two ``git config`` keys the hook reads:

  * ``haro.url``    — the backend the hook curls for a verdict. Written only when
    it differs from the default (``http://127.0.0.1:8000``), so a stock install
    stays config-free; unset back to that default otherwise.
  * ``haro.strict`` — the fail-closed toggle. The hook reads this *locally* (not
    from the verdict response) so fail-closed still resolves when the backend is
    down — a down backend can't announce its own strictness.

**Where the hook goes — `core.hooksPath` (husky et al.).** git runs hooks from
*exactly one* directory. Tools like husky/lefthook set ``core.hooksPath`` (e.g.
``.husky``), which makes git ignore ``$GIT_COMMON_DIR/hooks`` entirely — so a hook
written there would never fire. ``_hooks_dir`` follows that redirect: when
``core.hooksPath`` is set we install into it, else the shared ``$GIT_COMMON_DIR/hooks``.

**Chain, never clobber.** When the target slot already holds a *foreign* hook
(husky's own ``pre-push``, a hand-rolled script), we don't overwrite it — we append
an idempotent, marker-fenced block (``# >>> haro firewall >>>`` … ``# <<< haro
firewall <<<``) carrying the firewall logic, so both the foreign hook and ours run.
Uninstall strips exactly that fenced block, leaving the foreign hook byte-identical.
Only a slot we *wholly* own (a standalone haro hook) is written/removed as a whole
file. The fenced block is ``hook.sh`` minus its shebang, so the standalone hook and
the chained block share one source and can never drift.
"""

from __future__ import annotations

import stat
from pathlib import Path

from . import git_ops

#: Hook names the one script is installed under (it branches on ``basename $0``).
#: ``reference-transaction`` is what closes the fast-forward hole: git does NOT run
#: ``pre-merge-commit`` for a fast-forward, so without it `git merge <red-branch>` lands
#: red work with exit 0 and no output — and a branch cut from current base fast-forwards
#: by default. It fires on the ref update itself, so it also covers `reset --hard
#: <branch>`. See backlog/merge-firewall.md §5.
HOOK_NAMES = ("pre-push", "pre-merge-commit", "reference-transaction")
#: The default the hook falls back to when ``haro.url`` is unset — kept in sync
#: with ``hook.sh``. A backend on this URL needs no ``haro.url`` config at all.
DEFAULT_BACKEND_URL = "http://127.0.0.1:8000"
#: Substring proving a hook file (or fenced block) is ours, present in ``hook.sh``'s
#: header comment. Used to recognise a standalone haro hook we may rewrite/remove whole.
_HOOK_MARKER = "haro merge firewall"
#: Idempotent fence delimiting the block we append onto a *foreign* hook. Everything
#: between (inclusive) is ours to refresh or strip; the foreign hook around it is not.
_FENCE_START = "# >>> haro firewall >>>"
_FENCE_END = "# <<< haro firewall <<<"
_HOOK_SRC = Path(__file__).parent / "assets" / "firewall" / "hook.sh"


async def _hooks_dir(repo_path: str | Path) -> Path:
    """The directory git actually runs hooks from for this repo.

    Follows ``core.hooksPath`` when set (husky/lefthook redirect git there and stop
    reading the default dir); a relative value resolves against the working tree's
    top level, exactly as git interprets it. Otherwise the repo's *shared* hooks dir
    (``$GIT_COMMON_DIR/hooks``) — which resolves to the main checkout even from inside
    a linked worktree, so one install governs every worktree."""
    custom = await git_ops.get_config(repo_path, "core.hooksPath")
    if custom:
        p = Path(custom)
        if not p.is_absolute():
            top = (await git_ops._git("rev-parse", "--show-toplevel", cwd=repo_path)).strip()
            p = Path(top) / p
        return p.resolve()
    out = await git_ops._git("rev-parse", "--git-common-dir", cwd=repo_path)
    common = Path(out.strip())
    if not common.is_absolute():
        common = Path(repo_path) / common
    return common.resolve() / "hooks"


def _standalone_body() -> str:
    """The full standalone hook (with shebang) — written when we own the whole slot."""
    return _HOOK_SRC.read_text()


def _fence_block() -> str:
    """The firewall logic wrapped in the idempotent fence, for appending onto a foreign
    hook. Shares ``hook.sh`` as the single source of truth — just drops its shebang (the
    host hook already has one)."""
    lines = _standalone_body().splitlines()
    if lines and lines[0].startswith("#!"):
        lines = lines[1:]
    logic = "\n".join(lines).strip("\n")
    return f"{_FENCE_START}\n{logic}\n{_FENCE_END}\n"


def _strip_fence(text: str) -> str:
    """Return ``text`` with exactly our fenced block removed (inclusive). Idempotent;
    a no-op when no fence is present. Tolerates a lost end marker (strips to EOF)."""
    start = text.find(_FENCE_START)
    if start < 0:
        return text
    end = text.find(_FENCE_END, start)
    head = text[:start]
    tail = "" if end < 0 else text[end + len(_FENCE_END):]
    joined = head.rstrip("\n") + ("\n" + tail.lstrip("\n") if tail.strip() else "")
    return joined.rstrip("\n") + "\n" if joined.strip() else ""


def _ensure_exec(path: Path) -> None:
    """Make a (possibly foreign) hook executable without disturbing its other bits."""
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _install_one(dst: Path) -> None:
    """Arm a single hook slot, chaining rather than clobbering a foreign hook.

    * absent slot                → write the standalone hook (we own it)
    * already chained (has fence) → refresh our block in place
    * our standalone hook         → rewrite it (idempotent)
    * a foreign hook              → append the fenced block; the foreign hook stays
    """
    if not dst.exists():
        dst.write_text(_standalone_body())
        dst.chmod(0o755)
        return
    text = dst.read_text()
    if _FENCE_START in text:
        base = _strip_fence(text)
        dst.write_text(base.rstrip("\n") + "\n" + _fence_block() if base.strip() else _fence_block())
        _ensure_exec(dst)
        return
    if _HOOK_MARKER in text:  # our own standalone hook, no foreign content
        dst.write_text(_standalone_body())
        dst.chmod(0o755)
        return
    dst.write_text(text.rstrip("\n") + "\n\n" + _fence_block())
    _ensure_exec(dst)


async def install_hooks(
    repo_path: str | Path,
    *,
    backend_url: str = DEFAULT_BACKEND_URL,
    strict: bool = False,
) -> list[str]:
    """Arm the firewall in the repo's active hooks dir (``core.hooksPath``-aware) under
    both hook names + set the ``haro.url``/``haro.strict`` git config. Returns the hook
    paths touched.

    Never clobbers a foreign hook: an existing husky/lefthook/hand-rolled hook is chained
    onto via a marker-fenced block, not overwritten."""
    hooks = await _hooks_dir(repo_path)
    hooks.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for name in HOOK_NAMES:
        dst = hooks / name
        _install_one(dst)
        written.append(str(dst))

    backend_url = (backend_url or "").strip() or DEFAULT_BACKEND_URL
    if backend_url != DEFAULT_BACKEND_URL:
        await git_ops.set_config(repo_path, "haro.url", backend_url)
    else:
        await git_ops.unset_config(repo_path, "haro.url")
    await git_ops.set_config(repo_path, "haro.strict", "true" if strict else "false")
    return written


async def uninstall_hooks(repo_path: str | Path) -> list[str]:
    """Disarm the firewall: strip exactly our fenced block from a chained foreign hook
    (leaving theirs intact), or remove a hook file we wholly own, and clear
    ``haro.url``/``haro.strict``. Returns the paths touched. Pure file edits + a config
    unset, so it works with the backend stopped."""
    hooks = await _hooks_dir(repo_path)
    touched: list[str] = []
    for name in HOOK_NAMES:
        dst = hooks / name
        if not dst.exists():
            continue
        text = dst.read_text()
        if _FENCE_START in text:  # chained onto a foreign hook — strip only our block
            base = _strip_fence(text)
            if base.strip():
                dst.write_text(base)
            else:  # nothing left but our block (we'd created the slot) — remove it
                dst.unlink()
            touched.append(str(dst))
        elif _HOOK_MARKER in text:  # our standalone hook — remove the whole file
            dst.unlink()
            touched.append(str(dst))
        # else: a purely foreign hook we never touched — leave it be
    await git_ops.unset_config(repo_path, "haro.url")
    await git_ops.unset_config(repo_path, "haro.strict")
    return touched
