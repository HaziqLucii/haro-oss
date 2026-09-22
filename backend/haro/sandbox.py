"""Linux-first sandboxing (usp-critique-round3.md Move D): run haro's own
subprocesses under bubblewrap. Two independent profiles live here, because
they solve different problems and made different tradeoffs — don't conflate
them when editing.

**Step 1 — the test runner** (:func:`wrap_command`, ``[gate] sandbox``): deny
network only (``--unshare-net``), leave the filesystem exactly as it was
(``--dev-bind / /``). A green gate can then mean "green, AND offline" — no
test can silently depend on or exfiltrate to the network. Verified against a
real bubblewrap invocation on Linux on 2026-09-15: a sandboxed vitest run
stamps a profile hash and a test doing a live network fetch fails under the
sandbox, passes without it. See CHANGELOG.

**Step 2 — the agent itself** (:func:`wrap_agent_command`, ``[agent]
sandbox``): confine the ``claude`` CLI subprocess so bare
``--permission-mode bypassPermissions`` no longer means "the whole host is
writable." The opposite network posture from step 1: the agent MUST reach
``api.anthropic.com`` to function, so network stays shared — this profile
narrows the FILESYSTEM instead. Default-deny ``$HOME`` (a fresh, empty,
private tmpfs) with an explicit read-only allowlist for the agent's own
toolchain (node/nvm/volta/asdf/claude's install), a read-write bind for its
package cache, and read-write binds for exactly the worktree plus (when
writable) the project's real ``.git`` common dir — a haro worktree's
``.git`` is a FILE pointing at ``<project>/.git/worktrees/<name>``, so
binding only the worktree leaves git writes (`add`/`commit`/branch) hitting
a read-only root otherwise. The common dir's ``hooks/`` subdir is masked
(fresh tmpfs) so a compromised agent can't plant a hook that runs
unsandboxed the next time the host runs git there.

Both profiles are purely additive: :func:`bwrap_available` gates everything,
and a host without ``bwrap`` degrades — but the two steps degrade
differently ON PURPOSE. Step 1 degrades OPEN (runs unwrapped, and gate.py
flags the receipt as degraded): an unsandboxed green test run still carries
real information. Step 2 degrades CLOSED (the caller refuses to run at all,
emitting the normalized ``error`` event) — an unsandboxed ``claude`` run
under ``bypassPermissions`` is precisely the outcome the flag exists to
prevent, so silently continuing would be worse than refusing. See
``adapters/claude_code.py`` and ``review.py``.

**~/.claude is an allowlist, not a denylist** (see ``_CLAUDE_RW_ALLOW``'s
comment for the full history — five refuter rounds each found a new
exec-capable surface under ``.claude`` before this inversion). Only
specific, verified-pure-data paths are bound read-write; everything else
under ``.claude`` (including anything a future Claude Code release adds
that isn't in this list yet) simply does not exist inside the sandbox.
``~/.claude.json`` (the top-level FILE, distinct from the ``.claude/``
directory) is the one deliberate exception, bound read-write unconditionally
because the CLI reads its OAuth credentials from there and fails closed at
login without it — but it also carries ``mcpServers`` entries the CLI spawns
as commands, so a compromised run can still reach unconfined execution
through THAT one file. This is a real, unclosed gap, not a considered
acceptable residual — closing it would need JSON-level (not bind-mount-level)
access control. The same class of exposure exists, smaller, on
``~/.claude/.credentials.json`` itself: it is bound read-write (needed for
OAuth token refresh), so a compromised run can overwrite it — not code
execution, but account-level (a swapped token silently redirects subsequent
*unsandboxed* runs to an attacker's org, or at minimum forces a re-login).
Read-only would close that at the cost of breaking token refresh; left
read-write as a deliberate tradeoff, not an oversight. ``backups/`` (also
allowlisted, read-write) holds periodic ``.claude.json`` backups and is a
second, weaker path to the same ``mcpServers`` exposure ``.claude.json``
itself already has. A symlink planted INSIDE an allowlisted directory (e.g.
``sessions/evil -> ~/.claude/settings.json``) persists on the host, but a
write through it still lands on the real read-only-elsewhere target or
fails — no working exploit found, and no host-side process was found that
writes attacker-predictable filenames into an allowlisted directory, so
this is a documented watch-item, not a fix. The equivalent PROJECT-level
``<worktree>/.claude`` is re-bound READ-ONLY when it already exists (a
refuter pass caught a real bug in masking it unconditionally: a project MAY
commit ``.claude/settings.json``/``.claude/commands/`` — Anthropic's own
documented way to share tool-permission config with a team — and
``--tmpfs`` over an existing, git-tracked directory made it look DELETED to
git *inside* the sandbox; an agent's ordinary `git commit` then committed
that deletion for real, reaching the host branch on merge) and masked with
a fresh, empty, private ``--tmpfs`` only when the project has no
``.claude/`` at all yet (nothing tracked to lose there).

**Other honest residuals for step 2** (not solved here, don't oversell in a
receipt/pitch): network is fully open — there is no egress proxy/allowlist,
so a compromised agent can still exfiltrate anything it can read over the
open network. This is mount-namespace confinement only: no Landlock, no
seccomp (this host's glibc doesn't even wrap ``landlock_create_ruleset``,
there's no pip binding, and bwrap 0.12.0 has no native ``--landlock`` flag —
a kernel-level syscall/path policy is future work, not shipped). The
project's ``.git/config`` stays writable, so a ``core.hooksPath``
redirection elsewhere is unmitigated even with the default ``hooks/``
masked. Sandboxed ``npm``/``pip`` installs re-download every run (no
package-cache bind — see ``_HOME_ALLOW_RW``'s comment for why one was tried
and removed). The ``[agent] sandbox`` flag only wraps ``ClaudeCodeAdapter``
— the local-model adapter has no bwrap support at all, so a run refuses
outright rather than executing unconfined under the flag (see ``main.py``'s
adapter-selection code). :func:`bwrap_available` only checks that ``bwrap``
is on PATH, not that unprivileged user namespaces are actually usable (a
host with ``kernel.unprivileged_userns_clone=0`` or an AppArmor restriction
would fail at bwrap's own exec time instead of with haro's named "bwrap not
installed" reason). :func:`git_common_dir` assumes the worktree's
``gitdir:`` pointer is absolute; a repo configured with
``worktree.useRelativePaths`` (git ≥2.48) would produce a relative path that
reaches a non-``-try`` ``--bind`` and hard-fails the run instead of
degrading with a clear reason. On a legacy install that ever ran ``claude
migrate-installer`` (``~/.claude/local/claude`` + its own ``node_modules/``),
only the single resolved entry file gets ro-bound by the toolchain-closure
bind below — the rest of ``~/.claude/local/node_modules/`` would stay
unbound (invisible, same as everything else not in an allowlist), which is
safe but means that legacy layout may not actually run under this profile;
not reproducible on this host (native install), not verified elsewhere.
"""

from __future__ import annotations

import hashlib
import os
import shutil

#: Bumped whenever the actual bwrap invocation shape changes, so a cached
#: profile hash from an old shape never reads as equivalent to a new one.
_PROFILE_VERSION = "bwrap-v1"
_AGENT_PROFILE_VERSION = "bwrap-agent-v7"

#: Known, optional install locations for the agent's own toolchain, relative
#: to $HOME. Read-only, all "-try" so a host missing any of these just skips
#: it. Deliberately a fixed list rather than a dynamic filesystem walk —
#: the closure of "what the claude binary might need" is unbounded, but this
#: covers the common node/nvm/volta/asdf/bun/nix layouts; anything exotic
#: falls back to extra_ro (below) as a one-line per-project escape hatch (not
#: currently wired to any `.haro/settings.toml` key — a caller invoking
#: :func:`wrap_agent_command` directly can pass it, config plumbing is future
#: work if a project actually needs it).
_HOME_ALLOW_RO = (
    ".gitconfig", ".config/git", ".local/bin", ".local/share/claude",
    ".nvm", ".volta", ".asdf", ".bun", ".npm-global", ".nix-profile",
)
#: `~/.claude` policy: an ALLOWLIST, not a denylist — the inversion of this
#: profile's original approach, forced by five straight refuter rounds each
#: finding a NEW exec-capable surface under `.claude` faster than they could
#: be individually denied: `settings.json`/`settings.local.json` `hooks`,
#: `agents/`/`commands/`/`plugins/` (read into every future session's
#: prompt, or for a plugin its own `hooks`/`.mcp.json` server defs),
#: `CLAUDE.md` (persistent prompt injection), `daemon/` + `jobs/` (Claude
#: Code's BACKGROUND DAEMON — a real host process entirely outside this
#: sandbox — ingests `daemon/dispatch/` files and respawns workers straight
#: from `daemon/roster.json`, both carrying attacker-choosable
#: `launch.flagArgs`/`cwd`), and round 6 alone then found
#: `scheduled_tasks.json` (a durable, persisted task scheduler that survives
#: restarts and fires later, unconfined), `daemon.json`/`launch.json`/
#: `assistant-daemon-state.json` (daemon config siblings of the two already
#: masked), `hooks/`/`skills/` (a skill bundles executable scripts, not just
#: instructions), `workflows/`/`routines/`/`rules/`/`output-styles/` (the
#: same persistent-prompt-injection class as `CLAUDE.md`), `mailbox/`,
#: `agent-registry.json`, and `remote-settings.json` (an org-settings cache
#: whose payload can itself carry `hooks`/`sandboxSettings`). A denylist
#: has to enumerate all of that correctly and be re-verified on every
#: Claude Code release to stay complete; an allowlist instead fails SAFE
#: the moment Anthropic ships the next config surface — something merely
#: doesn't persist, instead of becoming a sixth (or eighth, or every future)
#: incident. Below are the specific, verified-as-pure-data paths (grounded
#: in this host's real `~/.claude` layout on CLI 2.1.272) bound read-write;
#: everything else under `.claude` simply doesn't exist inside the sandbox —
#: not locked, not masked, ABSENT, because it was never bound at all. This
#: is a documented best-effort list, not a closed one: a future Claude Code
#: release could add a new pure-data path here that this list doesn't know
#: about yet, in which case something merely fails to persist across a
#: sandboxed run (a functionality gap, caught by a real `claude -p`
#: regression, never a security one) rather than silently reopening an
#: exec channel.
_CLAUDE_RW_ALLOW = (
    ".credentials.json",
    "history.jsonl", "sessions", "projects", "file-history",
    "cache", "paste-cache", "image-cache", "session-env",
    "downloads", "backups", "plans", "daemon.log",
    ".last-cleanup", ".last-update-result.json",
    "mcp-needs-auth-cache.json",
    "policy-limits.json", "policy-limits.json.stamp.json",
)
#: Read-ONLY exception to the allowlist-of-absence above: haro installs its
#: own skills (`haro`/`haro-dev`, see `haro_skill.py`) into `~/.claude/skills`
#: on every boot, precisely so every sandboxed OR unsandboxed agent run
#: discovers them — without this, `[agent] sandbox = true` silently disables
#: that feature (a refuter pass caught this: the skill directory simply
#: isn't there under the plain RW allowlist above, no error, no warning).
#: Read-only, not added to `_CLAUDE_RW_ALLOW`, because a skill BUNDLES
#: EXECUTABLE SCRIPTS, not just instructions — read-write here would reopen
#: exactly the class of hole this whole allowlist inversion exists to close.
_CLAUDE_RO_ALLOW = ("skills",)
#: Read-write, optional. `.claude.json` (the top-level FILE, distinct from
#: the `.claude/` directory above) is NOT optional in practice — without it
#: the CLI can't read its OAuth credentials and every real run fails closed
#: at login instead of running unsandboxed (caught by an actual `claude -p`
#: invocation through the wrapper, not by the mocked tests, which only
#: exercised `claude --version`/`--help` — neither needs credentials). This
#: is a real, load-bearing residual, not a convenience: `.claude.json` also
#: carries `mcpServers` entries the CLI spawns as commands, so a compromised
#: run can still reach unconfined execution through THIS one file — closing
#: it would need JSON-level (not bind-mount-level) access control, and is
#: unclosed by design here, not overlooked (see the module docstring). A
#: prior revision also bound `.cache` (a different, ambient `~/.cache`, not
#: `~/.claude/cache` above) read-write on the theory it held the npm package
#: cache; that was simply wrong (npm's cache is `~/.npm`, confirmed via `npm
#: config get cache`) and `~/.cache` is exactly the kind of host-persistent
#: write hole this profile otherwise closes (pre-commit hook venvs, uv/pip
#: wheel caches) — removed rather than narrowed, so sandboxed npm/pip
#: installs simply re-download every run.
_HOME_ALLOW_RW = (".claude.json",)


def bwrap_available() -> bool:
    """Whether ``bwrap`` is on PATH at all — the single gate everything else
    in this module sits behind."""
    return shutil.which("bwrap") is not None


def profile_hash(*, network: bool) -> str:
    """A short identity for the sandbox profile actually used. NOT a security
    hash — the same "did this change" role ``receipt.diff_fingerprint`` plays
    for diffs, so a receipt/attestation can say *which* profile shape produced
    a green without the caller needing to know bwrap's own flag names."""
    text = f"{_PROFILE_VERSION}:network={network}"
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def agent_profile_hash() -> str:
    """Same identity role as :func:`profile_hash`, for the agent profile. No
    parameters (unlike the test profile) because this shape has exactly one
    posture today: network shared, filesystem confined.

    Not yet wired to anything — unlike the test profile's ``sandbox_profile``
    (stamped on `TestRun`/`Receipt`), no `AgentRun`/receipt field records
    whether a given agent run was actually sandboxed. Stamping that is future
    work, tracked as a gap, not assumed done by this function's existence.
    """
    return hashlib.sha256(_AGENT_PROFILE_VERSION.encode()).hexdigest()[:16]


def wrap_command(cmd: list[str]) -> list[str]:
    """Prepend the bwrap invocation that denies network while leaving
    everything else exactly as it was: the same filesystem, same devices, same
    ``/proc``, at the same paths (``--dev-bind / /``), plus ``--unshare-net``.

    Callers MUST check :func:`bwrap_available` first — this function does not,
    so it stays a pure, easily-tested command-list transform rather than
    something that silently no-ops when bwrap is missing.
    """
    return [
        "bwrap",
        "--dev-bind", "/", "/",
        "--unshare-net",
        "--die-with-parent",
        "--",
        *cmd,
    ]


def git_common_dir(worktree: str) -> str | None:
    """Resolve a linked worktree's real (common) git dir from its ``.git``
    file, e.g. ``gitdir: /project/.git/worktrees/<name>`` → ``/project/.git``.

    Returns None when ``<worktree>/.git`` is a plain directory (not a linked
    worktree — nothing extra to bind) or doesn't exist at all. Deliberately
    self-contained (parses the on-disk pointer rather than requiring callers
    to thread a separate project-root argument through the whole call chain):
    a haro worktree's own ``.git`` is exactly this shape by construction.
    """
    git_path = os.path.join(worktree, ".git")
    if not os.path.isfile(git_path):
        return None
    try:
        text = open(git_path, encoding="utf-8").read()
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("gitdir:"):
            gitdir = line.split(":", 1)[1].strip()
            # <project>/.git/worktrees/<name> -> <project>/.git
            worktrees_dir = os.path.dirname(gitdir)
            common = os.path.dirname(worktrees_dir)
            return common if os.path.basename(worktrees_dir) == "worktrees" else None
    return None


def wrap_agent_command(
    cmd: list[str],
    *,
    worktree: str,
    git_dir: str | None = None,
    writable: bool = True,
    home: str | None = None,
    extra_ro: tuple[str, ...] = (),
    extra_rw: tuple[str, ...] = (),
) -> list[str] | None:
    """Prepend the bwrap invocation that confines the AGENT: network shared
    (it must reach the API), filesystem default-deny under $HOME with an
    explicit allowlist, read-write only on the worktree (and, when
    ``writable``, the project's real git common dir with its ``hooks/``
    masked).

    Returns None when ``cmd[0]`` can't be resolved on PATH, so the caller can
    keep its existing "CLI not found" handling instead of getting bwrap's own
    opaque exit-1 (once argv[0] is ``bwrap``, ``create_subprocess_exec``
    always succeeds — bwrap itself fails at exec time, on stderr, with the
    same exit code a mount-setup error would produce).

    Deliberately does NOT set ``--new-session`` or unshare the PID namespace:
    haro's teardown (``procs.terminate_tree``) signals the whole process
    GROUP from the host (``killpg``). ``--new-session`` would move the
    sandboxed process into its own group, invisible to that killpg, breaking
    graceful SIGTERM (which ``claude --resume`` relies on to flush session
    state) in favour of an abrupt SIGKILL-on-parent-death. There is no
    controlling TTY here (stdout/stderr are pipes) so ``--new-session``'s
    actual purpose — blocking TIOCSTI injection — buys nothing anyway. A PID
    namespace has the same teardown problem (namespace death is SIGKILL,
    not graceful) for no isolation benefit worth it here.

    Callers MUST check :func:`bwrap_available` first (same contract as
    :func:`wrap_command`) — and, unlike the test profile, MUST fail closed
    rather than run unwrapped when it's False. See the module docstring.
    """
    resolved = shutil.which(cmd[0])
    if resolved is None:
        return None
    home = home or os.path.expanduser("~")

    argv = [
        "bwrap",
        "--unshare-user", "--unshare-ipc", "--unshare-uts",
        "--die-with-parent",
        "--ro-bind", "/", "/",
        "--proc", "/proc",
        "--dev", "/dev",
        "--tmpfs", "/tmp",
        # Default-deny $HOME: a fresh, empty, private tmpfs. Everything below
        # is an explicit exception layered on top of it. --setenv is required:
        # bwrap does NOT infer $HOME from the mount layout, so without it the
        # wrapped process inherits whatever $HOME the HOST process had, which
        # silently diverges from the path actually being masked/allowlisted
        # here the moment a caller passes a `home` different from the host's
        # real one (this is exactly the bug a real-bwrap test caught: the
        # allowlist appeared to work while actually confining the wrong path).
        "--tmpfs", home,
        "--setenv", "HOME", home,
    ]
    for rel in _HOME_ALLOW_RO:
        p = os.path.join(home, rel)
        if os.path.exists(p):
            argv += ["--ro-bind-try", p, p]
    for rel in _HOME_ALLOW_RW:
        p = os.path.join(home, rel)
        if os.path.exists(p):
            argv += ["--bind-try", p, p]
    # ~/.claude: allowlist, not denylist (see _CLAUDE_RW_ALLOW's comment for
    # why). Existence-gated like every other convenience allowance in this
    # function — unlike the old denylist approach this replaced, skipping an
    # absent path here is safe: there's nothing to allow, and everything NOT
    # in this list is simply never bound, so it doesn't exist inside the
    # sandbox at all (bwrap auto-creates the `.claude` directory itself, as
    # a plain empty dir in the tmpfs $HOME, to host whichever of these
    # subpaths actually get bound).
    for rel in _CLAUDE_RW_ALLOW:
        p = os.path.join(home, ".claude", rel)
        if os.path.exists(p):
            argv += ["--bind-try", p, p]
    for rel in _CLAUDE_RO_ALLOW:
        p = os.path.join(home, ".claude", rel)
        if os.path.exists(p):
            argv += ["--ro-bind-try", p, p]
    # The agent's own toolchain closure (wherever `which claude` actually
    # resolved to, following symlinks) — covers installs this fixed
    # allowlist doesn't anticipate.
    real_bin = os.path.realpath(resolved)
    argv += ["--ro-bind-try", real_bin, real_bin]
    for p in extra_ro:
        argv += ["--ro-bind-try", p, p]
    for p in extra_rw:
        argv += ["--bind-try", p, p]

    bind_flag = "--bind" if writable else "--ro-bind"
    argv += [bind_flag, worktree, worktree]
    if writable:
        # The PROJECT-level `.claude` (a normal part of the worktree the
        # whole-worktree bind above would otherwise expose read-write) is
        # the second surface a refuter pass found this profile hadn't
        # considered: Claude Code's own denylist masks this exact class of
        # file at BOTH the home root and the cwd root
        # (`.claude/settings.local.json`, `.claude/scheduled_tasks.json`,
        # etc.) — haro's own embedded terminal or a future unsandboxed run
        # in this same worktree would read whatever a compromised agent
        # planted here.
        #
        # NOT always `--tmpfs`, unlike every other mask in this function —
        # a refuter pass caught a real bug in that: a project MAY commit
        # `.claude/settings.json`/`.claude/commands/` (Anthropic's own
        # documented way to share tool-permission config with a team), and
        # `--tmpfs` over an EXISTING, git-tracked directory makes it look
        # DELETED to git *inside* the sandbox — an agent's ordinary `git add
        # -A && git commit` then commits that deletion for real, and it
        # reaches the host branch on merge. So: if the project already has
        # a `.claude/` (tracked or not), re-bind it READ-ONLY instead
        # (preserves it, git sees no change, but no write inside it —
        # existing or new file — can persist). Only mask with `--tmpfs`
        # when the project has no `.claude/` at all yet, where there is
        # nothing tracked to lose and the concern is purely "don't let a
        # compromised run create one."
        project_claude = os.path.join(worktree, ".claude")
        if os.path.exists(project_claude):
            argv += ["--ro-bind-try", project_claude, project_claude]
        else:
            argv += ["--tmpfs", project_claude]
    if writable and git_dir:
        argv += ["--bind", git_dir, git_dir]
        argv += ["--tmpfs", os.path.join(git_dir, "hooks")]

    argv += ["--chdir", worktree, "--", *cmd]
    return argv
