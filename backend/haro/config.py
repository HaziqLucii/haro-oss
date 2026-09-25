"""Runtime settings + per-project config.

Two layers:
  - ``Settings`` — process-wide, env-driven (where worktrees live, CORS origin).
  - ``ProjectSettings`` — the lifecycle config (setup/run/archive scripts, port
    range, gate + agent + workflow tables), merged from three TOML sources in
    ascending precedence: the **user-global** ``~/.haro/settings.toml``
    (cross-project defaults, lowest), then a project's committed
    ``.haro/settings.toml``, then its gitignored ``.haro/settings.local.toml``
    (personal, highest). Mirrors the user-global ``~/.haro`` + committed +
    ``.local`` model.
"""

from __future__ import annotations

import os
import shutil
import tomllib
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

# ``race`` is a leaf module (pure dataclasses + ranking, no haro imports), so this
# is import-cycle-free — the lane defaults and the policy vocabulary live beside the
# judge that reads them rather than being duplicated here.
from .race import DEFAULT_LANES, POLICIES as RACE_POLICIES


@dataclass
class Settings:
    #: Root under which all workspace worktrees are created.
    worktree_root: str = os.environ.get(
        "HARO_WORKTREE_ROOT", os.path.expanduser("~/.haro/worktrees")
    )
    #: CORS origin for the Vite dev server.
    frontend_origin: str = os.environ.get("HARO_FRONTEND_ORIGIN", "http://localhost:5173")
    #: Root the "add project" folder browser is confined to (your repos live here).
    browse_root: str = os.environ.get("HARO_BROWSE_ROOT", os.path.expanduser("~"))
    #: Persistent, shared package-manager cache/store root. Lives under the same
    #: ``~/.haro`` home as the worktrees (so it rides the same persistent volume
    #: in the Docker stack) — a fresh worktree's ``setup`` install reuses prior
    #: downloads instead of paying a cold fetch. Empty string disables the sharing.
    deps_cache_root: str = os.environ.get(
        "HARO_DEPS_CACHE", os.path.expanduser("~/.haro/cache")
    )


settings = Settings()


def user_settings_path() -> Path:
    """The user-global ``settings.toml`` — cross-project defaults (default model,
    reasoning effort, gate/workflow prefs) that a project's own committed and
    personal configs both override. Sits at the *lowest* precedence in
    ``load_project_settings``. Lives in the same ``~/.haro`` home as the worktrees
    and deps cache (so it rides the same persistent volume in the Docker stack).
    ``HARO_USER_CONFIG`` overrides the path (read at call time so tests can point
    it at a scratch dir)."""
    return Path(
        os.environ.get("HARO_USER_CONFIG", os.path.expanduser("~/.haro/settings.toml"))
    )


@dataclass
class RunScript:
    """One named run command (a ``[scripts.run.<id>]`` table).

    A project can define several — ``web``/``worker``/``test`` — each shown in the
    Run menu and started on its own port. ``default`` marks the one bound to the
    workspace's primary port (``workspace.port``) and shown in the preview iframe;
    the rest allocate a fresh port from ``[ports] range`` when started. ``icon`` is
    an optional glyph the menu shows beside the id.
    """

    id: str
    command: str
    default: bool = False
    icon: str | None = None


def _parse_run_scripts(run_raw: object) -> list[RunScript]:
    """Normalize the ``[scripts]`` ``run`` value into an ordered ``RunScript`` list.

    Two shapes, distinguished by TOML's own type system (they can't coexist in one
    file): a bare ``run = "cmd"`` string is the legacy single run (id ``app``); a
    ``[scripts.run.<id>]`` table set becomes one ``RunScript`` per sub-table. Each
    sub-value may itself be a command string (``[scripts.run] web = "cmd"``) or a
    table with ``command`` (+ optional ``default``/``icon``). Insertion order is
    preserved (tomllib keeps table order). If none is flagged ``default``, the first
    becomes the default so the workspace port + preview always bind to something.
    """
    runs: list[RunScript] = []
    if isinstance(run_raw, str):
        cmd = run_raw.strip()
        if cmd:
            runs.append(RunScript(id="app", command=cmd, default=True))
    elif isinstance(run_raw, dict):
        for rid, val in run_raw.items():
            rid = str(rid).strip()
            if not rid:
                continue
            if isinstance(val, str):
                cmd, default, icon = val.strip(), False, None
            elif isinstance(val, dict):
                cmd = str(val.get("command", "")).strip()
                default = bool(val.get("default", False))
                icon = str(val.get("icon")).strip() if val.get("icon") else None
            else:
                continue
            if cmd:
                runs.append(RunScript(id=rid, command=cmd, default=default, icon=icon))
    if runs and not any(r.default for r in runs):
        runs[0].default = True
    return runs


@dataclass
class RaceLaneConfig:
    """One lane in a winner-only fan-out (a ``[[race.lanes]]`` entry).

    A lane is just an agent config the SAME prompt is raced under — model plus
    reasoning effort — so the race measures whether the extra spend bought anything,
    not sampling noise between clones. See ``race.py`` / backlog/winner-fanout.md.
    """

    model: str
    effort: str = ""
    #: "" (an ordinary ranked lane) | "tests_only" | "impl_only" — stamped by
    #: ``fanout.resolve_lanes`` when ``[race] policy = "split_authors"``; never set
    #: from TOML directly (a hand-written ``[[race.lanes]]`` grid is ignored for that
    #: policy, see ``resolve_lanes``).
    role: str = ""

    @property
    def label(self) -> str:
        base = f"{self.model}-{self.effort}" if self.effort else self.model
        # A split_authors race forces both lanes to the SAME model/effort (see
        # resolve_lanes), so without this the two lanes' workspace names/branches
        # are identical apart from an auto-appended "(2)" — nothing tells a human
        # which one holds the tests. Refuter round-3 caught this.
        return f"{base}-{self.role}" if self.role else base


@dataclass
class RoleConfig:
    """One `[roles]` entry: the model + reasoning effort a step of the
    plan→scout→build→refute loop runs with (see notes/workflow-roles-plan.md).
    Mirrors ``RaceLaneConfig``'s shape (a race lane and a role are both just
    "an agent config"), but kept as its own type since a role has no lane label."""

    model: str
    effort: str = ""


def _parse_role(raw: object) -> RoleConfig | None:
    """Normalize one `[roles]` entry (a ``"model:effort"`` string or a
    ``{model, effort}`` table) into a ``RoleConfig``. Junk (empty/unknown shape,
    no model) returns ``None`` rather than raising — a malformed role must fall
    back to `[agent] default_model`/`default_effort` for that step, not take the
    whole project's config down (same philosophy as ``_parse_race_lanes``)."""
    if isinstance(raw, str):
        model, _sep, effort = raw.strip().partition(":")
    elif isinstance(raw, dict):
        model = str(raw.get("model", "")).strip()
        effort = str(raw.get("effort", "")).strip()
    else:
        return None
    model = model.strip().lower()
    effort = effort.strip().lower()
    if not model:
        return None
    return RoleConfig(model=model, effort=effort)


def _parse_race_lanes(raw: object) -> list[RaceLaneConfig]:
    """Normalize ``[race] lanes`` into an ordered ``RaceLaneConfig`` list.

    Accepts the natural TOML shapes — an array of tables
    (``[[race.lanes]] model = "opus"``), an array of plain model strings
    (``lanes = ["sonnet", "opus"]``), or ``"model:effort"`` strings — because this is a
    knob a human hand-edits and the array-of-tables form is the one people get wrong.
    Junk entries are dropped rather than raising: a malformed lane must not take the
    whole project's config down with it. An empty/invalid list falls back to the
    default grid so ``[race] enabled = true`` alone is a working config.
    """
    lanes: list[RaceLaneConfig] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                model, _sep, effort = item.strip().partition(":")
            elif isinstance(item, dict):
                model = str(item.get("model", "")).strip()
                effort = str(item.get("effort", "")).strip()
            else:
                continue
            model = model.strip().lower()
            effort = effort.strip().lower()
            if model:
                lanes.append(RaceLaneConfig(model=model, effort=effort))
    if not lanes:
        lanes = [RaceLaneConfig(model=d["model"], effort=d["effort"]) for d in DEFAULT_LANES]
    return lanes


#: The rung conditions the autonomy ladder ANDs together (Bet 9 —
#: ``backlog/autonomy-ladder.md``). Each is individually required-by-default and
#: individually togglable via a ``require_<key>`` flag under ``[trust]``. Kept as one
#: constant so the parser here, the ``trust.py`` evaluator, and a future
#: ``write_project_trust`` writer never drift on the condition set.
#:   * merge_result — the gate ran against the merge result and stayed green
#:   * coverage     — coverage delta vs base_ref ≥ 0
#:   * full_scope   — the gate ran the full suite (an "impacted" fast-gate never climbs)
#:   * no_flaky     — zero suspected-flaky tests in the run
#:   * no_tamper    — the tamper alarm is on and found nothing on the run (a `green*`
#:                    never climbs; `tamper_alarm = "off"` reads as unmet, not clean)
#:   * quality      — the Double Gate's other half: the diff is secrets/security/lint
#:                    clean (backlog/double-gate.md §1). Registered here so the policy
#:                    key (`require_quality`) parses and round-trips today; the condition
#:                    itself stays dormant until the quality gate ships a fact to read
#:                    (see the comment in `trust.evaluate`) — it must not disarm a rung
#:                    on a build that has no quality gate at all.
TRUST_CONDITIONS = (
    "merge_result", "coverage", "full_scope", "no_flaky", "no_tamper", "quality",
)


@dataclass
class ProjectSettings:
    """Parsed ``.haro/settings.toml`` for one project."""

    setup: str | None = None       # runs after worktree creation (install deps, etc.)
    run: str | None = None         # the DEFAULT run command (back-compat; see `runs`)
    #: All named run commands. Legacy single-string `run` collapses to one entry
    #: (id "app"); `[scripts.run.<id>]` tables become one entry each.
    runs: list[RunScript] = field(default_factory=list)
    archive: str | None = None     # cleanup before archiving
    run_mode: str = "concurrent"   # "concurrent" | "nonconcurrent"
    login_shell: bool = False      # run setup/run via `$SHELL -lc` so nvm/asdf/pyenv resolve
    gate_dir: str = ""             # subdir to run the test gate in (monorepo, e.g. "frontend")
    gate_runner: str = ""          # "" (default → vitest) | "vitest" | "pytest" | "command" | "offense"
    gate_command: str = ""         # runner="command"/"offense": the shell command to gate with
    gate_format: str = ""          # runner="offense": JSON offense format ("theme-check" | "eslint" | "ruff")
    # Scope the *auto*-gate (the run that fires when an agent finishes) uses:
    #   "all"      (default) — the full suite, always trustworthy but slower.
    #   "impacted"           — only the tests the diff vs base_ref provably affects
    #                          (the Impact Map fast gate). Cuts the feedback loop on
    #                          big suites; the UI then nudges "run full before ship",
    #                          and the ④ ship step still wants a full green.
    # Manual "run all" / "impacted" buttons are unaffected — this is only the default
    # scope the agent→gate handoff picks.
    gate_default_scope: str = "all"
    # Gate the thing that actually *ships*: when on, the gate runs against the MERGE
    # RESULT (the worktree merged onto the latest base_ref) instead of the worktree
    # alone — so a green gate survives a base change that landed after this workspace
    # branched, and a base⇄worktree merge conflict surfaces as a red gate. Off by
    # default (the extra merge/worktree cost only pays off once bases move under you).
    gate_merge_result: bool = False
    # Live Gate (backlog/live-gate.md): keep an ADVISORY impacted-only test loop running
    # off the filesystem watcher, so the rail shows a live verdict while you edit instead
    # of only after something asks for a gate. Deliberately OFF by default — unlike the
    # tamper alarm (deterministic, zero extra runs) this spends CPU on every save, so it
    # has to be chosen. A watch run can never ship anything: it runs in ``gate.run_watch``,
    # which has no path to the verdict writes ``run_gate`` performs.
    gate_watch: bool = False
    # Verified Hunks (backlog/verified-hunks.md): annotate the ④ ship diff per line —
    # "executed by the green suite" vs "never executed" — so a big agent diff collapses
    # to the residue the suite didn't exercise. It's evidence, not a verdict (never blocks
    # a merge), so it stays on by default rather than gated behind an opt-in.
    # Cheap once on: it reuses the per-line coverage map the code-to-check pass already
    # measures on a green gate, so turning it on adds no extra test run — it only makes
    # the gate cache that map for the diff view (see gate.run_gate / store.set_line_hits).
    # ON by default (2026-09-14, usp-critique-plan.md idea 3): it's the "proof per line"
    # pillar of the merge-gate USP and costs nothing extra to show.
    verified_hunks: bool = True
    # Mutation score (backlog/mutation-gate.md): on-demand, advisory — mutate each added
    # line, re-run the suite, report the faults the tests can't tell apart. OFF by default:
    # it is the one signal that costs N test runs, so it stays off the ~1s merge-gate path.
    mutation: bool = False
    # Linux-first sandboxing, step 1 (usp-critique-round3.md Move D): run the
    # gate's suite under bubblewrap with network denied, so green means "green,
    # offline". OFF by default — vitest-only so far (see gate.py's degradation
    # when a project asks for this on a non-vitest runner), and the actual
    # sandboxed subprocess behavior has NOT been verified against a real bwrap
    # on Linux as of this writing (see sandbox.py's module docstring); flip
    # this default only after that verification.
    gate_sandbox: bool = False
    port_range: tuple[int, int] = (4000, 4999)
    # --- Agent cost/token guardrails (the `[agent]` table) -------------------
    # Token spend is the platform's biggest operational cost, so these are the
    # knobs that keep a fleet of parallel agents from overspending.
    #  * default_model — the model a run gets when it doesn't pick one. Sonnet,
    #    NOT the CLI's pricier Opus default (~5× the per-token cost). An explicit
    #    per-run pick (opus/haiku/…) still wins.
    default_model: str = "sonnet"
    #  * default_effort — reasoning-effort budget when a run doesn't pick one.
    #    "" ⇒ the CLI default (~medium); kept modest on purpose, since high/
    #    xhigh/max burn far more thinking tokens for routine work.
    default_effort: str = ""
    #  * max_budget_usd — HARD per-run dollar ceiling (`claude --max-budget-usd`).
    #    A single run is stopped once its API spend crosses this — the runaway
    #    guard. 0 ⇒ uncapped.
    max_budget_usd: float = 5.0
    #  * cost_warn_usd — SOFT heads-up when a workspace's *cumulative* agent
    #    spend crosses this (a beep/banner, not a stop). 0 ⇒ off.
    cost_warn_usd: float = 20.0
    #  * max_parallel — how many agent subprocesses may run AT ONCE across the whole
    #    install (not per project, not per worktree). Runs over the cap wait as
    #    `queued` and start as slots free up. This is a resource guard, not a cost
    #    guard: N workspaces × an unbounded `claude` each is what makes "run many
    #    agents in parallel" exhaust a laptop. 0 ⇒ unlimited (the old behaviour).
    max_parallel: int = 4
    #  * sandbox (usp-critique-round3.md Move D step 2) — confine the `claude`
    #    subprocess under bwrap instead of handing bare `bypassPermissions` the
    #    whole host: default-deny $HOME, read-write only on the worktree (+ the
    #    project's real git dir), network left open (the agent needs the API).
    #    OFF by default. See sandbox.py's module docstring for the full threat
    #    model and honest residuals (network stays open; no Landlock/seccomp).
    agent_sandbox: bool = False
    #  * adapter — which agent backend a run uses. "claude-code" (default) shells the
    #    Claude Code CLI (cloud); "local" runs LocalModelAdapter against a local model
    #    server (Ollama / llama.cpp) — the "no cloud" path. When "local", the Claude
    #    model/effort/budget knobs above don't apply; local_base_url + local_model do.
    agent_adapter: str = "claude-code"
    #  * local_base_url — OpenAI-compatible endpoint for the local model. Ollama:
    #    http://localhost:11434/v1 ; llama.cpp llama-server: http://localhost:8080/v1.
    local_base_url: str = "http://localhost:11434/v1"
    #  * local_model — the local model tag to run (e.g. "qwen2.5-coder", "llama3.1").
    local_model: str = "qwen2.5-coder"
    # Tier-1 custom instructions: haro's own standing prompt for every agent
    # run in this project, appended to Claude Code via `--append-system-prompt`.
    # The committed `.haro/instructions.md` base, with a personal
    # `.haro/instructions.local.md` concatenated after it (both apply).
    instructions: str = ""
    # Tier-2 workflow rules — deterministic checkpoints the control plane enforces
    # (parsed here now; enforcement in the ship flow is the next step). NOT prompt
    # text: these gate what the platform does, so they can't be skipped by the agent.
    confirm_before_commit: bool = False
    changelog_on_commit: bool = False
    # Auto-fix loop: when the auto-gate comes back red with real *test failures*,
    # feed them straight back to the agent and re-gate — up to N rounds or until
    # green. Opt-in (off by default) with a hard round cap; the ⏹ stop button is the
    # kill-switch (it cancels the whole loop). Setup/crash reds don't loop — the
    # agent can't fix missing deps by editing code.
    auto_fix: bool = False
    auto_fix_max_rounds: int = 3
    # Flaky-aware green: on a red gate, silently re-run once; a test that failed then
    # passes is "suspected-flaky" and — when it's the only kind of failure — doesn't
    # block green. Opt-in: it trades one extra run on red for not letting nondeterminism
    # erode trust in the gate. Off by default (a red gate stays red).
    flaky_rerun: bool = False
    # Coverage guard: when a gate is otherwise green, compare line coverage to the
    # base_ref baseline. "off" (default) ignores it; "warn" attaches a note but stays
    # green; "block" turns the gate red so a coverage regression can't merge. A drop is
    # only tripped when it exceeds coverage_tolerance (percentage points). Off by default
    # because measuring coverage adds a run to the (otherwise lean) green path.
    coverage_guard: str = "off"
    coverage_tolerance: float = 0.0
    # Tamper alarm: on an otherwise-green gate, run the deterministic test-integrity
    # signal (tamper.analyze — removed/skipped tests, gutted assertions, snapshot churn)
    # and record the ``green*`` findings. "warn" (the DEFAULT) attaches findings + a note
    # but stays green; "block" folds ``tamper_blocked`` into the green conjunction so a
    # tampered suite can't merge; "off" skips the check. Unlike the other guards this
    # defaults ON — a deliberate exception, because the signal is deterministic and adds
    # NO extra test run (a dry ``vitest list`` diff + the diff text), so it's cheap trust.
    tamper_alarm: str = "warn"
    # Code to check ([workflow] code_to_check): the DIFF-level signal (unchecked.py).
    # Every other guard is suite-level, so none of them notices that the lines just
    # added were executed by nothing. "warn" (default) records rows; "off" skips the
    # pass. There is deliberately no "block": refusing a merge because a dependency
    # changed is a policy call to make after reading real counts, not before.
    # See backlog/code-to-check.md.
    code_to_check: str = "warn"
    # ---- THE DOUBLE GATE: `[quality]` (backlog/double-gate.md §1) --------------------
    #  * quality_enabled — the master switch, OFF by default like every other v2.x
    #    opt-in. Its *presence* is also the contract the autonomy ladder waits on: the
    #    `quality` rung condition stays dormant until a build has a quality gate at all,
    #    so flipping this on is what makes that checklist row appear (see trust.py).
    quality_enabled: bool = False
    #  * quality_scanners — which adapters run, in order. gitleaks leads because a leaked
    #    credential is the highest-value thing this tier catches and the cheapest to check.
    quality_scanners: list[str] = field(default_factory=lambda: ["gitleaks", "semgrep"])
    #  * quality_severity_threshold — the weakest severity that BLOCKS. Findings below it
    #    are still recorded and shown, just advisory. Secrets are always emitted `high`.
    quality_severity_threshold: str = "medium"
    #  * quality_enforce — "block" (default when enabled) folds `quality_blocked` into the
    #    green conjunction; "warn" records findings and stays green. Same warn/block shape
    #    as the tamper alarm and the coverage guard, so there is one mental model.
    quality_enforce: str = "block"
    #  * quality_lint_cmd / quality_lint_severity — the project's own linter for the
    #    `lint` adapter. No default command: haro has no business guessing a project's
    #    linter, and `lint` in `scanners` without a command reports as unavailable
    #    (⇒ degraded) rather than silently passing.
    quality_lint_cmd: str = ""
    quality_lint_severity: str = "medium"
    #  * quality_semgrep_config — override the bundled offline ruleset with a registry
    #    pack ("p/security-audit") or your own YAML. Empty ⇒ haro's bundled rules, which
    #    need no network (local-first: a gate that needs the internet isn't a gate).
    quality_semgrep_config: str = ""
    #  * quality_plan_compliance — the Double Gate's LLM third (§3): "off" (default) or
    #    "warn" — an LLM verdict never blocks a merge on its own (2026-09-17). Off by
    #    default and separately from `enabled` because this one costs a model call per
    #    green gate, so opting into secret scanning must not silently opt you into
    #    paying for an LLM audit too.
    quality_plan_compliance: str = "off"
    # Which ship actions the ④ ship step offers. NOT "local vs remote" — that's
    # auto-detected from whether the repo has a git remote (see integrate.py); this
    # is purely which buttons a project wants:
    #   "both"  (default) — Create/Open PR + Merge (trust branch protection)
    #   "pr"              — PR only (juniors can't merge directly; hide Merge)
    #   "merge"           — Merge only (solo repo; skip the PR ceremony)
    # A no-remote repo has no PR to open, so it always falls back to Merge.
    merge_mode: str = "both"
    # --- GitHub Issues backlog write-back (the `[backlog]` table) -------------
    # When an issue seeds a workspace, optionally write that pickup back to GitHub:
    # comment "Picked up in haro", add an `in-progress` label, and self-assign — so
    # a teammate scanning the tracker doesn't grab the same issue. OFF by default:
    # writing to GitHub is a visible side effect a team must opt into. Reads stay
    # live + unconditional; only this write is gated. See issues.write_back_on_pickup.
    issue_writeback: bool = False
    # --- Backlog folder (the `[backlog] dir` key) -----------------------------
    # Directory whose markdown/doc files are ALL treated as backlog docs regardless
    # of filename, so a project can keep its backlog tidy in `backlog/gate.md`,
    # `backlog/ui.md` instead of littering the repo root with `todo-*.md`. Purely
    # additive: the legacy "filename contains 'todo'" rule still applies everywhere
    # else (a root `TODO.md` is always found). Default `backlog` — the convention
    # haro itself adopts — so the folder Just Works with no config. See
    # `main._discover_todo_files` and `backlog.is_backlog_path`.
    backlog_dir: str = "backlog"
    # --- Backlog issue query (the `[backlog]` table) --------------------------
    # Replaces the old hard-coded `gh issue list --assignee @me`. Default is
    # unassigned-inclusive ("" = anyone) because solo devs rarely self-assign and
    # team members want to pick up unassigned work; `@me` is opt-in, not the
    # default. See issues.list_issues.
    issue_state: str = "open"
    issue_assignee: str = ""
    issue_limit: int = 100
    # --- Backlog file discovery (the `[backlog] files` key) -------------------
    # Additive globs on top of `backlog_dir` + the legacy "filename contains
    # 'todo'" heuristic, mirroring `[files] include`'s shape. Lets a project keep
    # backlog items in `TODO.md` / `ROADMAP.md` / `docs/backlog*` without renaming
    # anything. See backlog.is_backlog_path.
    backlog_files: list[str] = field(default_factory=list)
    # --- Worktree file seeding (the `[files]` table) --------------------------
    # Gitignored files a fresh worktree needs but a clean checkout never carries:
    # `.env` secrets, an `.npmrc` with a private-registry token (a common reason a
    # fresh `setup` fails), local TLS certs, service-account JSON. POSIX globs
    # relative to the project root, copied into the worktree at the same relative
    # path on create (see `copy_worktree_includes`). Defaults to `.env*` so the
    # historical `.env` seed keeps working; add more globs to opt into the
    # broader copy set.
    include_files: list[str] = field(default_factory=lambda: [".env*"])
    # --- In-app editor (the `[editor]` table) ---------------------------------
    # The "code" step can open the worktree in Neovim (a PTY editor) instead of
    # Monaco — for the Linux crowd who live in nvim. This picks WHICH nvim:
    #   "auto" (default) — the developer's own ~/.config/nvim if they have one,
    #                      else haro's bundled LazyVim (fully-stacked, zero setup).
    #   "byo"            — always the user's own nvim config.
    #   "bundled"        — always haro's LazyVim, seeded under an isolated
    #                      NVIM_APPNAME so it never touches ~/.config/nvim.
    # The Monaco⇄nvim toggle itself is a per-client UI choice; this only decides
    # which config the backend launches nvim with. See terminal.spawn_editor.
    nvim_mode: str = "auto"
    # --- Autonomy ladder / earned auto-merge (the `[trust]` table) ------------
    # Bet 9 (`backlog/autonomy-ladder.md`): accumulated green-gate facts graduate
    # into a merge policy. Parsed here as pure config; the rung evaluator
    # (`trust.py`) and UI are separate items. The policy is team law — it lives in
    # the committed `settings.toml`, and a `.local` override may only *tighten* it.
    #  * trust_enabled — master switch. Off by default (the ladder is opt-in; the
    #    gate stays a plain merge-blocker until a project arms it).
    trust_enabled: bool = False
    #  * trust_streak_required — trailing consecutive green full-scope gate runs the
    #    project must hold before the top rung unlocks. Any red resets the streak to 0.
    trust_streak_required: int = 3
    #  * trust_auto_action — what a fully-met rung is allowed to DO:
    #    "off" (default) — evaluate + display only, never act; "auto_pr" — push + open
    #    a PR without merging. Auto-merging a green verdict onto the user's own `main`
    #    was cut (2026-09-17): a local verdict is not something a stranger's `main`
    #    should be trusted to act on unattended.
    trust_auto_action: str = "off"
    #  * trust_require — per-condition require flags (`require_<key>` under `[trust]`),
    #    one per TRUST_CONDITIONS entry, ALL default true (absent ⇒ the condition counts).
    #    Setting one false drops that condition from the conjunction so a project can
    #    climb without, say, the coverage guard it doesn't run.
    trust_require: dict[str, bool] = field(
        default_factory=lambda: {c: True for c in TRUST_CONDITIONS}
    )
    # --- Merge Firewall (also under `[trust]`; backlog/merge-firewall.md §3) ---
    # The gate's *jurisdiction* over the whole repo. Separate from the autonomy
    # ladder above (that decides what a green gate is allowed to DO; this decides
    # whether a RED gate can be pushed/merged at all — from any tool, even a bare
    # terminal). Enforced by a repo-level git hook the `POST /projects/{id}/firewall`
    # install endpoint writes; the hook curls `/firewall/verdict` and reads its
    # posture from `git config haro.strict`.
    #  * firewall — the enforcement posture: "off" (default, no hook), "warn"
    #    (hook installed, fail-OPEN: a red gate blocks but an unknown/unreachable
    #    verdict only warns), "block" (fail-CLOSED: unknown/unreachable also blocks).
    firewall: str = "off"
    #  * firewall_strict — the raw `strict` toggle written to `git config haro.strict`
    #    (the hook's fail-closed switch). "block" implies strict regardless; this lets
    #    a "warn" posture opt into fail-closed independently. The install endpoint
    #    derives the effective strict as `firewall_strict or firewall == "block"`.
    firewall_strict: bool = False
    #  * quiet_secs — the quiescence debounce for auto-gating an *adopted* (agentless)
    #    worktree (backlog/merge-firewall.md §4). Adopted worktrees never emit an agent
    #    `done`, so the fs watcher waits this many seconds of no working-tree change
    #    before treating the worktree as settled and eligible for an auto-gate. Clamped
    #    ≥ 1 (0 would fire on every keystroke's inter-event gap). Read-only config: the
    #    firewall install endpoint never writes it, so it needs no writer round-trip.
    trust_quiet_secs: int = 30
    # --- Winner-only fan-out (the `[race]` table; backlog/winner-fanout.md) ----
    # Bet 11: fan the SAME prompt to N lane configs as sibling workspaces and let the
    # merge-blocking gate rank the winner, so the human reviews ONE diff plus a
    # scorecard. The judge is `race.py` (pure); the shell is `fanout.py`.
    #  * race_enabled — master switch, OFF by default. This is the one feature that
    #    multiplies token spend by the lane count, so it can never be a default.
    race_enabled: bool = False
    #  * race_max_lanes — hard cap on lanes per race, whatever the lane list says.
    #    Clamped ≥ 2 (a 1-lane "race" is just a run).
    race_max_lanes: int = 3
    #  * race_lanes — the lane grid: the same task at different model/effort points.
    race_lanes: list[RaceLaneConfig] = field(default_factory=lambda: _parse_race_lanes(None))
    #  * race_policy — which single metric crowns the winner (see race.POLICIES).
    #    Defaults to cheapest_green: cost is the pain this feature is most likely to
    #    cause, so the default policy is the one that argues against itself.
    race_policy: str = "cheapest_green"
    #  * race_min_suite_tests — pre-flight floor. Below this many tests at base_ref we
    #    REFUSE to auto-judge at all: "compiles and passes" isn't "good code" on a weak
    #    suite, and a degenerate winner is worse than no winner.
    race_min_suite_tests: int = 10
    #  * race_min_impacted_tests — the same idea at judge time, per lane: a green whose
    #    diff touches fewer than this many tests didn't really get looked at.
    race_min_impacted_tests: int = 3
    #  * race_max_total_usd — race-level dollar ceiling; still-running lanes are stopped
    #    once the lanes' summed `AgentRun.cost_usd` crosses it. 0 ⇒ derive it as
    #    lanes × `[agent] max_budget_usd` (so a ceiling always exists).
    race_max_total_usd: float = 0.0
    # --- Workflow roles (`[roles]`; notes/workflow-roles-plan.md) ---------------
    # Give each step of the plan→scout→build→refute loop its own model/effort so
    # approving a plan can't silently build at the (pricier) plan model — the
    # "forgot to flip two dropdowns" trap the plan doc identifies. OFF by default:
    # `roles_enabled=False` keeps model/effort resolution byte-identical to today
    # (explicit per-run pick → `[agent] default_model/default_effort` → "sonnet").
    roles_enabled: bool = False
    role_plan: RoleConfig | None = None
    role_build: RoleConfig | None = None
    role_review: RoleConfig | None = None
    role_scout: RoleConfig | None = None
    #  * review_enforce — "off" (default, the refuter never runs) | "warn" (verdict
    #    recorded, never blocks). An LLM verdict never blocks a merge on its own
    #    (2026-09-17: the deterministic gate is the only merge authority); Phase 3's
    #    review-fix loop still runs under "warn", it just can't refuse to ship.
    #    Independent of the plan/build resolution above — those work with review off.
    review_enforce: str = "off"
    #  * review_max_rounds — cap on the review-fix loop (Phase 3): bounded rounds
    #    of build-role fixes in response to refuter must-fix findings.
    review_max_rounds: int = 2
    raw: dict = field(default_factory=dict)

    @property
    def has_config(self) -> bool:
        return bool(self.raw)


def _read_toml(path: Path) -> dict:
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def _read_text(path: Path) -> str:
    try:
        return path.read_text()
    except OSError:
        return ""


def _as_float(value: object, default: float) -> float:
    """Coerce a TOML value to float, falling back to ``default`` on junk."""
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _as_int(value: object, default: int, *, minimum: int = 0) -> int:
    """Coerce a TOML value to a non-negative int, falling back to ``default`` on junk.
    Clamped at ``minimum`` so a negative in the file can't invert a cap's meaning."""
    try:
        return max(minimum, int(value))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _parse_trust(trust: dict) -> tuple[bool, int, str, dict[str, bool]]:
    """Normalize a raw ``[trust]`` table into
    ``(enabled, streak_required, auto_action, require)``.

    Single source of truth for the trust policy's defaults + validation, so
    ``load_project_settings`` and ``write_project_trust`` can't drift (same reason
    ``TRUST_CONDITIONS`` is one constant): an unknown ``auto_action`` falls back to
    the safe ``"off"``, ``streak_required`` is clamped ≥ 1 (0 would auto-unlock the
    ladder instantly), and every condition is required unless an explicit
    ``require_<key> = false`` drops it from the conjunction.
    """
    auto_action = str(trust.get("auto_action", "off")).strip().lower()
    if auto_action not in ("off", "auto_pr"):
        auto_action = "off"
    streak_required = max(1, int(_as_float(trust.get("streak_required", 3), 3)))
    require = {c: bool(trust.get(f"require_{c}", True)) for c in TRUST_CONDITIONS}
    return bool(trust.get("enabled", False)), streak_required, auto_action, require


def _parse_firewall(trust: dict) -> tuple[str, bool]:
    """Normalize the Merge Firewall keys of the ``[trust]`` table into
    ``(firewall, strict)`` (backlog/merge-firewall.md §3). Kept beside
    ``_parse_trust`` (they share the ``[trust]`` table) but deliberately separate:
    the firewall governs the gate's *jurisdiction* over the whole repo, the ladder
    governs auto-merge — different concerns, different writers, so they never drift.

    ``firewall`` is the posture the install endpoint arms (unknown → the safe
    ``off``); ``strict`` is the raw ``git config haro.strict`` toggle. The endpoint
    derives the *effective* strict (``strict or firewall == "block"``); this parse
    stays literal so the on-disk value round-trips unchanged."""
    firewall = str(trust.get("firewall", "off")).strip().lower()
    if firewall not in ("off", "warn", "block"):
        firewall = "off"
    return firewall, bool(trust.get("strict", False))


# Personal, per-machine config that must never be committed. We keep a
# committed ``.haro/.gitignore`` listing these, so the whole team inherits
# the ignore rule the moment any config is saved from the app.
_LOCAL_ONLY_FILES = ("settings.local.toml", "instructions.local.md")
_GITIGNORE_HEADER = "# haro: personal overrides: never commit these."


def _ensure_local_gitignore(base: Path, extra: tuple[str, ...] = ()) -> None:
    """Idempotently ensure ``.haro/.gitignore`` ignores the ``.local`` files
    (plus any ``extra`` patterns, e.g. ``.env`` when the secrets editor is used).

    Preserves any hand-added lines; only appends patterns that are missing."""
    path = base / ".gitignore"
    existing = _read_text(path)
    present = {ln.strip() for ln in existing.splitlines()}
    missing = [p for p in (*_LOCAL_ONLY_FILES, *extra) if p not in present]
    if not missing:
        return
    chunk: list[str] = []
    if not existing.strip():
        chunk.append(_GITIGNORE_HEADER)
    elif _GITIGNORE_HEADER not in existing:
        chunk += ["", _GITIGNORE_HEADER]
    chunk += missing
    prefix = existing.rstrip("\n")
    out = (prefix + "\n" if prefix else "") + "\n".join(chunk) + "\n"
    path.write_text(out)


def read_instructions(project_path: str) -> tuple[str, str]:
    """Return the raw (shared, local) instruction texts for the in-app editor.

    ``shared`` is ``.haro/instructions.md`` (committed → the whole team
    inherits it); ``local`` is ``.haro/instructions.local.md`` (gitignored,
    personal). Missing files read as empty strings.
    """
    base = Path(project_path) / ".haro"
    return _read_text(base / "instructions.md"), _read_text(base / "instructions.local.md")


# A haro-owned standing rule injected into *every* agent run, ahead of any
# per-project instructions. It teaches the agent the one TODO shape the backlog
# UI parses (`main._parse_todo`) and the click-to-workspace flow relies on, so
# agents *emit* the canonical format instead of ad-hoc markdown we'd forever be
# patching the parser to accept ("be strict in what you emit"). It also enforces
# how work is decomposed: each item must be independently runnable, because every
# item becomes a parallel workspace (own worktree + branch) and dependent items
# would collide. It's additive and scoped to TODO-named files; because it's
# prepended, a project's own instructions come after and can override it if a
# repo really needs to.
TODO_CONTRACT = """\
# haro backlog format (required when you create or edit backlog files)

A backlog file is any markdown/doc file under the project's `backlog/` folder
(e.g. `backlog/gate.md`) **or** any file whose name contains "todo" (e.g.
`TODO.md`, `todo-*.md`) anywhere in the repo. Both are parsed as the project
backlog and shown in haro's clickable backlog UI. Clicking a `- [ ]` item seeds a
new workspace: the item's **title becomes the git branch + workspace name**, and
its full text becomes the agent's task.

A backlog file is plain markdown: only `- [ ]` / `- [x]` lines become clickable
items; **all other prose (headings, notes, context) is kept and rendered as
notes** — so a backlog file doubles as a notes doc, and a file with no checklist
lines is a valid notes-only doc. Write items to this shape:

- Make each item **independently runnable in parallel.** haro launches backlog
  items as concurrent workspaces, each in its own git worktree + branch — running
  many at once is the point, so **default to splitting** into the smallest items
  that each stand alone. Combine two into one item only when there is a true
  **dependency**: one cannot be finished or pass its gate until the other is
  merged (it needs the other's code, or builds on files the other creates or
  rewrites). Do **not** combine merely because two items edit the same file —
  independent edits that happen to touch shared code are reconciled at merge time,
  not serialized. When unsure, split.
- Group items under `##` / `###` headings — the heading labels the group.
- One task per line as a GitHub task-list item: `- [ ] ...` (pending) or
  `- [x] ...` (done). Only these lines become clickable backlog items; other prose
  is rendered as notes/context around them (not actionable) — use it freely for
  headings, background, and links.
- Start each item with a short imperative **title**, then ` — ` (space, em dash,
  space), then the detail: `- [ ] Wire the dispatch — extend the runner to …`.
  Everything before the ` — ` becomes the branch/workspace name, so keep that
  lead phrase short (≈ a few words) and slug-friendly.
- Wrap long detail onto **indented continuation lines** (align under the item
  text); they are folded back into the one item — do not start them with `-`.
- Put code/config examples in fenced ``` blocks; they stay out of the compact
  checklist line but are included in the brief when the item is sent to an agent.
- Do not invent a "tests passed" or fake-gate item to look done. Tick `- [x]`
  only when the work is genuinely complete."""


# Gate integrity — the north star as a standing rule. haro's whole premise is that
# a green gate is a trustworthy merge signal; the failure mode we actually hit while
# dogfooding was an agent *fabricating a passing test* to turn the gate green (a
# gamed gate is worse than no gate). Universal to every project, so it's platform-level.
GATE_CONTRACT = """\
# the test gate is not yours to game

When you finish a task, haro automatically runs this project's test gate; a green
gate is the merge signal the developer trusts. Keep it honest:

- Never fabricate a passing test, stub a fake gate command, weaken or comment out
  an assertion, or skip/delete a failing test just to turn the gate green. A gamed
  gate is worse than no gate.
- If tests genuinely fail, fix the underlying code, or report the failure plainly —
  do not paper over it.
- If there are no tests, or the gate runner can't launch, say so (that reads as a
  setup problem, not a pass). Add a real test only when the change genuinely warrants
  one; never add an empty or trivially-true test purely to satisfy the gate."""


# Backlog lifecycle — the companion to TODO_CONTRACT (which governs the *format*).
# This governs the *close-out*: tick the item you finished. Phrased ship-agnostic on
# purpose (who commits/merges is project/personal config, not a platform default).
BACKLOG_TICK = """\
# close out the backlog item you finished

If your task came from a backlog item (a `- [ ]` line in a TODO file), then once
the work is complete and the gate is green, edit that file and flip the matching
`- [ ]` to `- [x]` — match by the item's text, and tick only that one item. Whether
to commit or merge that change is up to the project's own workflow, not this rule.

If you notice follow-up work while doing this task that you are not going to do
yourself (a related bug, a missing test, a cleanup you deliberately deferred),
append it as a new `- [ ]` line under a `## Follow-ups` heading in the same seed
file, instead of doing it now or leaving it unwritten. One line, same format as
the rest of the file. Do not invent follow-ups that aren't real."""


# Platform-level standing blocks, prepended to every agent run (order = priority).
_PLATFORM_CONTRACTS = (TODO_CONTRACT, GATE_CONTRACT, BACKLOG_TICK)


def combined_instructions(project_path: str) -> str:
    """The full standing instruction block for an agent run: haro's platform-level
    contracts first (backlog format, gate integrity, backlog close-out — so every
    agent on every project inherits them), then the team base and personal override
    concatenated after (both apply; later text can override earlier). Never empty —
    the contracts always ship — so the adapter always passes ``--append-system-prompt``."""
    shared, local = read_instructions(project_path)
    return "\n\n".join(
        p for p in (*_PLATFORM_CONTRACTS, shared.strip(), local.strip()) if p
    )


def write_instructions(project_path: str, text: str, *, target: str = "local") -> str:
    """Save the custom-instructions markdown to ``instructions.local.md``
    (personal, gitignored) or ``instructions.md`` (committed, team). An empty
    ``text`` removes the file so the section reads as truly unset. Returns the
    path written (or removed)."""
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "instructions.md" if target == "shared" else "instructions.local.md"
    path = base / fname
    if text.strip():
        path.write_text(text)
    elif path.exists():
        path.unlink()
    return str(path)


def read_env(project_path: str) -> str:
    """The project's ``.haro/.env`` seed — the dotenv block new worktrees are
    seeded with. Missing file reads as empty. Always gitignored (secrets), so there's
    no team/personal split: one personal, machine-local file per project."""
    return _read_text(Path(project_path) / ".haro" / ".env")


def write_env(project_path: str, text: str) -> str:
    """Save the worktree ``.env`` seed to ``.haro/.env`` and guarantee it's
    gitignored (it holds secrets — never committed). An empty ``text`` removes the
    file. Returns the path written (or removed)."""
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base, extra=(".env",))
    path = base / ".env"
    if text.strip():
        path.write_text(text if text.endswith("\n") else text + "\n")
    elif path.exists():
        path.unlink()
    return str(path)


def seed_worktree_env(project_path: str, worktree_path: str) -> bool:
    """Copy the project's ``.haro/.env`` seed into a fresh worktree's ``.env``.

    A worktree is a clean git checkout, so a gitignored ``.env`` from the main
    checkout never lands in it — setup/run/tests that need secrets then break on
    every new workspace. Seeding fixes that. No-op when there's no seed, or the
    worktree already has a ``.env`` (a committed one, or a re-provision) — never
    clobber an existing file."""
    src = Path(project_path) / ".haro" / ".env"
    dst = Path(worktree_path) / ".env"
    if not src.exists() or dst.exists():
        return False
    try:
        dst.write_text(src.read_text())
        return True
    except OSError:
        return False


def copy_worktree_includes(
    project_path: str, worktree_path: str, patterns: Sequence[str]
) -> list[str]:
    """Copy gitignored files matching ``patterns`` from the project checkout into a
    fresh worktree, at the same relative path (the ``files`` glob seed).

    A worktree is a clean checkout, so gitignored files the app/setup/tests rely on
    (``.env`` secrets, an ``.npmrc`` with a private-registry token, local TLS certs,
    service-account JSON) never land in it — and a fresh ``setup`` then fails on the
    missing auth. ``patterns`` are POSIX globs relative to the project root
    (``.env*``, ``.npmrc``, ``certs/*.pem``); ``**`` recurses.

    Only *missing* files are copied — a match whose destination already exists is
    left untouched. That single rule does three jobs: it skips tracked files (they're
    already checked out in the worktree, so copying is pointless), it leaves the
    dedicated ``.haro/.env`` seed (see ``seed_worktree_env``, which runs first)
    untouched when a root ``.env`` also matches, and it makes a re-provision idempotent.
    Absolute / parent-escaping patterns and symlinks resolving outside the repo are
    refused so a pattern can't read or write outside the two trees. Returns the
    worktree-relative paths actually copied.
    """
    root = Path(project_path).resolve()
    wt = Path(worktree_path).resolve()
    copied: list[str] = []
    seen: set[Path] = set()
    for pattern in patterns:
        pattern = (pattern or "").strip()
        # Refuse absolute globs and any `..` segment — a pattern must stay inside the repo.
        if not pattern or pattern.startswith("/") or ".." in pattern.split("/"):
            continue
        try:
            matches = root.glob(pattern)
        except (ValueError, OSError):
            continue
        for src in sorted(matches):
            if src in seen or not src.is_file():
                continue
            seen.add(src)
            try:
                rel = src.resolve().relative_to(root)  # also rejects out-of-repo symlinks
            except ValueError:
                continue
            dst = wt / rel
            if dst.exists():
                continue
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
            except OSError:
                continue
            copied.append(rel.as_posix())
    return copied


def load_project_settings(project_path: str) -> ProjectSettings:
    """Load the merged project config from three sources, ascending precedence:
    the user-global ``~/.haro/settings.toml`` (cross-project defaults), the
    project's committed ``.haro/settings.toml``, then its gitignored
    ``.haro/settings.local.toml`` (personal).

    Missing/invalid files yield defaults, so a project without any config still
    works (the gate falls back to symlinking node_modules — see gate.ensure_deps).
    """
    base = Path(project_path) / ".haro"
    merged: dict = {}
    # Lowest → highest precedence: user-global defaults, committed team config,
    # personal local override. A later source's keys win over an earlier one's.
    sources = (user_settings_path(), base / "settings.toml", base / "settings.local.toml")
    for path in sources:
        data = _read_toml(path)
        # shallow-merge tables (a higher-precedence source overrides a lower one)
        for key, val in data.items():
            if isinstance(val, dict) and isinstance(merged.get(key), dict):
                merged[key] = {**merged[key], **val}
            else:
                merged[key] = val

    scripts = merged.get("scripts", {}) if isinstance(merged.get("scripts"), dict) else {}
    ports = merged.get("ports", {}) if isinstance(merged.get("ports"), dict) else {}
    gate = merged.get("gate", {}) if isinstance(merged.get("gate"), dict) else {}
    workflow = merged.get("workflow", {}) if isinstance(merged.get("workflow"), dict) else {}
    agent = merged.get("agent", {}) if isinstance(merged.get("agent"), dict) else {}
    backlog = merged.get("backlog", {}) if isinstance(merged.get("backlog"), dict) else {}
    files = merged.get("files", {}) if isinstance(merged.get("files"), dict) else {}
    editor = merged.get("editor", {}) if isinstance(merged.get("editor"), dict) else {}
    trust = merged.get("trust", {}) if isinstance(merged.get("trust"), dict) else {}
    race = merged.get("race", {}) if isinstance(merged.get("race"), dict) else {}
    quality = merged.get("quality", {}) if isinstance(merged.get("quality"), dict) else {}
    roles = merged.get("roles", {}) if isinstance(merged.get("roles"), dict) else {}
    nvim_mode = str(editor.get("nvim", "auto")).strip().lower()
    if nvim_mode not in ("auto", "byo", "bundled"):
        nvim_mode = "auto"
    raw_include = files.get("include", [".env*"])
    include_files = (
        [p for p in (str(x).strip() for x in raw_include) if p]
        if isinstance(raw_include, list)
        else [".env*"]
    )
    rng = ports.get("range", [4000, 4999])
    try:
        lo, hi = int(rng[0]), int(rng[1])
    except (TypeError, ValueError, IndexError):
        lo, hi = 4000, 4999

    # `[quality]` (backlog/double-gate.md §1). An unknown scanner name is kept rather than
    # dropped: `quality.analyze` reports it as unavailable, which degrades the run. Silently
    # ignoring a typo'd scanner would mean a project believes it is scanning for secrets
    # when nothing is — the exact silent pass §0 exists to prevent.
    raw_scanners = quality.get("scanners")
    quality_scanners = (
        [s for s in (str(x).strip().lower() for x in raw_scanners) if s]
        if isinstance(raw_scanners, list)
        else ["gitleaks", "semgrep"]
    )
    quality_threshold = str(quality.get("severity_threshold", "medium")).strip().lower()
    if quality_threshold not in ("high", "medium", "low", "info"):
        quality_threshold = "medium"
    quality_enforce = str(quality.get("enforce", "block")).strip().lower()
    if quality_enforce not in ("warn", "block"):
        quality_enforce = "block"
    quality_plan = str(quality.get("plan_compliance", "off")).strip().lower()
    if quality_plan not in ("off", "warn"):
        quality_plan = "off"
    quality_lint_severity = str(quality.get("lint_severity", "medium")).strip().lower()
    if quality_lint_severity not in ("high", "medium", "low", "info"):
        quality_lint_severity = "medium"

    # Normalized via the shared parser so the loader and `write_project_trust`
    # never disagree on defaults/validation (unknown auto_action → "off", streak
    # clamped ≥ 1, each condition required unless `require_<key> = false`).
    trust_enabled, trust_streak_required, trust_auto_action, trust_require = _parse_trust(trust)
    firewall, firewall_strict = _parse_firewall(trust)

    runs = _parse_run_scripts(scripts.get("run"))
    run = next((r.command for r in runs if r.default), runs[0].command if runs else None)

    return ProjectSettings(
        setup=scripts.get("setup"),
        run=run,
        runs=runs,
        archive=scripts.get("archive"),
        run_mode=str(scripts.get("run_mode", "concurrent")),
        login_shell=bool(scripts.get("login_shell", False)),
        gate_dir=str(gate.get("dir", "")).strip("/"),
        gate_runner=str(gate.get("runner", "")).strip().lower(),
        gate_command=str(gate.get("command", "")).strip(),
        gate_format=str(gate.get("format", "")).strip().lower(),
        gate_default_scope=(
            "impacted" if str(gate.get("default_scope", "all")).strip().lower() == "impacted" else "all"
        ),
        gate_merge_result=bool(gate.get("merge_result", False)),
        gate_watch=bool(gate.get("watch", False)),
        verified_hunks=bool(gate.get("verified_hunks", True)),
        mutation=bool(gate.get("mutation", False)),
        gate_sandbox=bool(gate.get("sandbox", False)),
        port_range=(lo, hi),
        default_model=str(agent.get("default_model", "sonnet")).strip() or "sonnet",
        default_effort=str(agent.get("default_effort", "")).strip(),
        max_budget_usd=_as_float(agent.get("max_budget_usd", 5.0), 5.0),
        cost_warn_usd=_as_float(agent.get("cost_warn_usd", 20.0), 20.0),
        max_parallel=_as_int(agent.get("max_parallel", 4), 4),
        agent_sandbox=bool(agent.get("sandbox", False)),
        agent_adapter=(
            "local" if str(agent.get("adapter", "claude-code")).strip().lower() == "local"
            else "claude-code"
        ),
        local_base_url=str(agent.get("local_base_url", "http://localhost:11434/v1")).strip()
        or "http://localhost:11434/v1",
        local_model=str(agent.get("local_model", "qwen2.5-coder")).strip() or "qwen2.5-coder",
        instructions=combined_instructions(project_path),
        confirm_before_commit=bool(workflow.get("confirm_before_commit", False)),
        changelog_on_commit=bool(workflow.get("changelog_on_commit", False)),
        auto_fix=bool(workflow.get("auto_fix", False)),
        # Clamp to a sane 1..10 so a typo can't unleash a runaway (or disable) loop.
        auto_fix_max_rounds=max(1, min(10, int(_as_float(workflow.get("auto_fix_max_rounds", 3), 3)))),
        flaky_rerun=bool(workflow.get("flaky_rerun", False)),
        coverage_guard=(
            str(workflow.get("coverage_guard", "off")).strip().lower()
            if str(workflow.get("coverage_guard", "off")).strip().lower() in ("off", "warn", "block")
            else "off"
        ),
        coverage_tolerance=abs(_as_float(workflow.get("coverage_tolerance", 0.0), 0.0)),
        # Defaults ON to "warn" (see the dataclass note); an unknown value falls back to
        # that default rather than silently disabling the alarm.
        code_to_check=(
            str(workflow.get("code_to_check", "warn")).strip().lower()
            if str(workflow.get("code_to_check", "warn")).strip().lower() in ("off", "warn")
            else "warn"
        ),
        tamper_alarm=(
            str(workflow.get("tamper_alarm", "warn")).strip().lower()
            if str(workflow.get("tamper_alarm", "warn")).strip().lower() in ("off", "warn", "block")
            else "warn"
        ),
        # The Double Gate (backlog/double-gate.md §1). `quality_enabled` doubles as the
        # autonomy ladder's shipped-ness signal for its dormant `quality` rung.
        quality_enabled=bool(quality.get("enabled", False)),
        quality_scanners=quality_scanners,
        quality_severity_threshold=quality_threshold,
        quality_enforce=quality_enforce,
        quality_lint_cmd=str(quality.get("lint_cmd", "") or "").strip(),
        quality_lint_severity=quality_lint_severity,
        quality_semgrep_config=str(quality.get("semgrep_config", "") or "").strip(),
        quality_plan_compliance=quality_plan,
        # Unknown values fall back to the permissive default rather than erroring.
        merge_mode=(
            str(workflow.get("merge_mode", "both")).strip().lower()
            if str(workflow.get("merge_mode", "both")).strip().lower() in ("both", "pr", "merge")
            else "both"
        ),
        issue_writeback=bool(backlog.get("issue_writeback", False)),
        backlog_dir=str(backlog.get("dir", "backlog")).strip().strip("/") or "backlog",
        issue_state=(
            str(backlog.get("issue_state", "open")).strip().lower()
            if str(backlog.get("issue_state", "open")).strip().lower() in ("open", "closed", "all")
            else "open"
        ),
        issue_assignee=str(backlog.get("issue_assignee", "") or "").strip(),
        issue_limit=_as_int(backlog.get("issue_limit", 100), 100, minimum=1),
        backlog_files=(
            [p for p in (str(x).strip() for x in backlog.get("files", [])) if p]
            if isinstance(backlog.get("files", []), list)
            else []
        ),
        include_files=include_files,
        nvim_mode=nvim_mode,
        trust_enabled=trust_enabled,
        trust_streak_required=trust_streak_required,
        trust_auto_action=trust_auto_action,
        trust_require=trust_require,
        firewall=firewall,
        firewall_strict=firewall_strict,
        trust_quiet_secs=max(1, int(_as_float(trust.get("quiet_secs", 30), 30))),
        race_enabled=bool(race.get("enabled", False)),
        # Clamped ≥ 2: a one-lane race is a plain run wearing a scorecard, and the
        # honest-tie logic assumes there is something to compare against.
        race_max_lanes=max(2, int(_as_float(race.get("max_lanes", 3), 3))),
        race_lanes=_parse_race_lanes(race.get("lanes")),
        race_policy=(
            str(race.get("policy", "cheapest_green")).strip().lower()
            if str(race.get("policy", "cheapest_green")).strip().lower() in RACE_POLICIES
            else "cheapest_green"
        ),
        # Clamped ≥ 1 rather than ≥ 0: `min_suite_tests = 0` would disable the one
        # pre-flight check standing between a 3-test repo and a meaningless race.
        race_min_suite_tests=max(1, int(_as_float(race.get("min_suite_tests", 10), 10))),
        race_min_impacted_tests=max(1, int(_as_float(race.get("min_impacted_tests", 3), 3))),
        race_max_total_usd=max(0.0, _as_float(race.get("max_total_usd", 0.0), 0.0)),
        roles_enabled=bool(roles.get("enabled", False)),
        role_plan=_parse_role(roles.get("plan")),
        role_build=_parse_role(roles.get("build")),
        role_review=_parse_role(roles.get("review")),
        role_scout=_parse_role(roles.get("scout")),
        review_enforce=(
            str(roles.get("review_enforce", "off")).strip().lower()
            if str(roles.get("review_enforce", "off")).strip().lower() in ("off", "warn")
            else "off"
        ),
        review_max_rounds=max(0, min(10, int(_as_float(roles.get("review_max_rounds", 2), 2)))),
        raw=merged,
    )


def write_project_merge_mode(
    project_path: str, merge_mode: str, *, target: str = "shared"
) -> str:
    """Targeted, non-destructive write of ``[workflow] merge_mode``.

    Unlike ``write_project_scripts`` (which regenerates the scripts/gate/ports tables
    wholesale), this touches only the single ``merge_mode`` line inside ``[workflow]``,
    preserving every other table and any hand-added keys — so setting the ship-mode
    policy from the Git settings tab can never clobber a project's scripts or gate
    config. ``target="shared"`` writes the committed ``settings.toml`` (merge_mode is a
    team policy); ``"local"`` writes the personal ``settings.local.toml``. Returns the
    path written.
    """
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname
    new_line = f"merge_mode = {_toml_str(merge_mode)}"
    lines = _read_text(path).splitlines()

    section_start = next(
        (i for i, ln in enumerate(lines) if ln.strip() == "[workflow]"), None
    )
    if section_start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines += ["[workflow]", new_line]
    else:
        # Scan the table body (until the next table header / EOF) for merge_mode.
        end = next(
            (
                j
                for j in range(section_start + 1, len(lines))
                if lines[j].lstrip().startswith("[")
            ),
            len(lines),
        )
        for j in range(section_start + 1, end):
            if lines[j].split("=", 1)[0].strip() == "merge_mode":
                lines[j] = new_line
                break
        else:
            lines.insert(section_start + 1, new_line)

    path.write_text("\n".join(lines) + "\n")
    return str(path)


def _upsert_table_keys(
    lines: list[str], table: str, entries: list[tuple[str, str | None]]
) -> list[str]:
    """Upsert (or, when the serialized value is ``None``, remove) keys inside a
    ``[table]`` block, preserving every other line in the file.

    ``entries`` are ``(key, toml_value)`` pairs where ``toml_value`` is already
    serialized (e.g. via ``_toml_str``); a ``None`` value deletes the key so the
    file stays clean and ``load_project_settings`` falls back to its default. The
    table is created (with only the set keys) when absent. Returns the new lines.
    """
    header = f"[{table}]"
    start = next((i for i, ln in enumerate(lines) if ln.strip() == header), None)
    if start is None:
        set_entries = [(k, v) for k, v in entries if v is not None]
        if not set_entries:
            return lines
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(header)
        lines += [f"{k} = {v}" for k, v in set_entries]
        return lines

    # Body runs from just after the header to the next table header / EOF.
    end = next(
        (j for j in range(start + 1, len(lines)) if lines[j].lstrip().startswith("[")),
        len(lines),
    )
    for key, val in entries:
        idx = next(
            (j for j in range(start + 1, end) if lines[j].split("=", 1)[0].strip() == key),
            None,
        )
        if idx is not None:
            if val is None:
                del lines[idx]
                end -= 1
            else:
                lines[idx] = f"{key} = {val}"
        elif val is not None:
            lines.insert(end, f"{key} = {val}")
            end += 1
    return lines


def write_project_gate(
    project_path: str,
    *,
    runner: str,
    command: str,
    gate_format: str,
    gate_dir: str,
    default_scope: str,
    merge_result: bool,
    flaky_rerun: bool,
    coverage_guard: str,
    coverage_tolerance: float,
    tamper_alarm: str = "warn",
    code_to_check: str = "warn",
    watch: bool = False,
    verified_hunks: bool = True,
    mutation: bool = False,
    target: str = "shared",
) -> str:
    """Targeted, non-destructive write of the gate config from the Gate settings tab.

    Writes the ``[gate]`` block (runner/command/format/dir/default_scope/merge_result)
    plus the flaky/coverage guard keys that live under ``[workflow]``, upserting each
    key in place so it can never clobber ``[scripts]``, the port range, or the Git
    tab's ``[workflow] merge_mode`` (same reasoning as ``write_project_merge_mode``).
    Values left at their default are omitted, so the on-disk block stays minimal and
    matches what a stack preset would emit. ``target="shared"`` writes the committed
    ``settings.toml``; ``"local"`` the personal ``settings.local.toml``. Returns the
    path written.
    """
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname
    lines = _read_text(path).splitlines()

    runner = (runner or "").strip().lower()
    command = command.strip()
    gate_format = gate_format.strip().lower()
    gate_dir = gate_dir.strip("/")
    # runner="" and "vitest" are equivalent defaults — omit the key for both.
    gate_entries: list[tuple[str, str | None]] = [
        ("runner", _toml_str(runner) if runner and runner != "vitest" else None),
        ("command", _toml_str(command) if command and runner in ("command", "offense") else None),
        ("format", _toml_str(gate_format) if gate_format and runner == "offense" else None),
        ("dir", _toml_str(gate_dir) if gate_dir else None),
        ("default_scope", '"impacted"' if default_scope == "impacted" else None),
        ("merge_result", "true" if merge_result else None),
        ("watch", "true" if watch else None),
        # Inverse polarity, like tamper_alarm/code_to_check below: verified_hunks
        # defaults ON, so the value we OMIT is `true` — only the opt-out is written.
        ("verified_hunks", "false" if not verified_hunks else None),
        ("mutation", "true" if mutation else None),
    ]
    lines = _upsert_table_keys(lines, "gate", gate_entries)

    guard = str(coverage_guard).strip().lower()
    guard = guard if guard in ("warn", "block") else "off"
    tol = abs(_as_float(coverage_tolerance, 0.0))
    # Inverse polarity from the other guards: "warn" is the default, so it's the value
    # we OMIT — only the opt-out ("off") or opt-in-to-blocking ("block") get written.
    tamper = str(tamper_alarm).strip().lower()
    _ctc = str(code_to_check).strip().lower()
    _ctc = _ctc if _ctc == "off" else "warn"
    tamper = tamper if tamper in ("off", "block") else "warn"
    workflow_entries: list[tuple[str, str | None]] = [
        ("flaky_rerun", "true" if flaky_rerun else None),
        ("coverage_guard", _toml_str(guard) if guard != "off" else None),
        ("coverage_tolerance", repr(tol) if guard != "off" and tol else None),
        ("tamper_alarm", _toml_str(tamper) if tamper != "warn" else None),
        # Same inverse polarity as tamper_alarm: "warn" is the default, so the only
        # value worth writing is the opt-out.
        ("code_to_check", _toml_str(_ctc) if _ctc != "warn" else None),
    ]
    lines = _upsert_table_keys(lines, "workflow", workflow_entries)

    text = "\n".join(lines).strip("\n")
    path.write_text(text + "\n" if text else "")
    return str(path)


def write_project_agent(
    project_path: str,
    *,
    default_model: str,
    default_effort: str,
    max_budget_usd: float,
    cost_warn_usd: float,
    max_parallel: int = 4,
    agent_adapter: str = "claude-code",
    local_base_url: str = "http://localhost:11434/v1",
    local_model: str = "qwen2.5-coder",
    target: str = "shared",
) -> str:
    """Targeted, non-destructive write of the `[agent]` cost/model guardrails from the
    Agent settings tab.

    Upserts each key inside `[agent]` in place, preserving `[scripts]`, `[gate]`,
    `[ports]`, and the Git/Gate tabs' `[workflow]` keys (same reasoning as
    ``write_project_merge_mode``/``write_project_gate``). ``target="shared"`` writes the
    committed ``settings.toml`` and omits default-valued keys to keep the block minimal;
    ``"local"`` writes the personal ``settings.local.toml`` and pins EVERY key explicitly
    — a personal override sits above the committed file, so an omitted key would inherit
    the team value rather than the default. Returns the path written.
    """
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname
    lines = _read_text(path).splitlines()

    model = (default_model or "sonnet").strip().lower()
    effort = (default_effort or "").strip().lower()
    max_budget = abs(_as_float(max_budget_usd, 5.0))
    cost_warn = abs(_as_float(cost_warn_usd, 20.0))
    parallel = _as_int(max_parallel, 4)
    adapter = "local" if (agent_adapter or "").strip().lower() == "local" else "claude-code"
    base_url = (local_base_url or "").strip()
    lmodel = (local_model or "").strip()
    # A personal (`.local`) write is an OVERRIDE layer sitting ABOVE the committed
    # settings.toml. Omitting a key there does NOT fall back to the hardcoded default —
    # it falls back to whatever the team file set, so omitting a default-valued key would
    # leak the team value straight back (the "personal save doesn't stick" bug). So a
    # `.local` write pins every key explicitly; only the shared file keeps the minimal
    # "omit defaults" form, because nothing but the real defaults sits below it.
    explicit = target != "shared"
    entries: list[tuple[str, str | None]] = [
        # claude-code is the default — omit it (shared) so the block stays minimal. `adapter`
        # is the *default* backend; a run can override it per-run, so both backends' knobs
        # below are persisted independently of which one is the default.
        ("adapter", _toml_str(adapter) if explicit or adapter != "claude-code" else None),
        # Local-model knobs persist whenever they differ from the default (regardless of the
        # default backend) so a project can configure Local without switching its default to it.
        # (An empty value is never a real override, so it's still dropped even when explicit.)
        ("local_base_url",
         _toml_str(base_url) if base_url and (explicit or base_url != "http://localhost:11434/v1") else None),
        ("local_model",
         _toml_str(lmodel) if lmodel and (explicit or lmodel != "qwen2.5-coder") else None),
        # sonnet is the default — omit it (shared) so the block stays minimal.
        ("default_model", _toml_str(model) if model and (explicit or model != "sonnet") else None),
        ("default_effort", _toml_str(effort) if explicit or effort else None),
        # 5.0 / 20.0 are the ProjectSettings defaults — omit (shared) when unchanged.
        ("max_budget_usd", repr(max_budget) if explicit or max_budget != 5.0 else None),
        ("cost_warn_usd", repr(cost_warn) if explicit or cost_warn != 20.0 else None),
        # 4 is the ProjectSettings default — omit (shared) when unchanged. `0` is a real
        # value (unlimited), so it must be written explicitly, never treated as "unset".
        ("max_parallel", str(parallel) if explicit or parallel != 4 else None),
    ]
    lines = _upsert_table_keys(lines, "agent", entries)

    text = "\n".join(lines).strip("\n")
    path.write_text(text + "\n" if text else "")
    return str(path)


def write_project_roles(
    project_path: str,
    *,
    enabled: bool,
    role_plan: str = "",
    role_build: str = "",
    role_review: str = "",
    role_scout: str = "",
    review_enforce: str = "off",
    review_max_rounds: int = 2,
    target: str = "shared",
) -> str:
    """Targeted, non-destructive write of the `[roles]` workflow-loop config
    (notes/workflow-roles-plan.md) from the Roles settings tab.

    Each role is written as its ``"model:effort"`` shorthand (empty ⇒ the key is
    omitted, so that step falls back to `[agent] default_model`/`default_effort`).
    Upserts inside `[roles]` in place, preserving `[scripts]`, `[gate]`, `[agent]`,
    and every other table (same reasoning as ``write_project_agent``). Like the
    trust policy, roles are workflow law: `target="shared"` writes the committed
    ``settings.toml``; `"local"` the personal ``settings.local.toml``. Returns the
    path written.
    """
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname
    lines = _read_text(path).splitlines()

    def _shorthand(raw: str) -> str:
        return (raw or "").strip().lower()

    plan_s = _shorthand(role_plan)
    build_s = _shorthand(role_build)
    review_s = _shorthand(role_review)
    scout_s = _shorthand(role_scout)
    enforce = str(review_enforce or "off").strip().lower()
    enforce = enforce if enforce in ("off", "warn") else "off"
    rounds = max(0, min(10, _as_int(review_max_rounds, 2)))

    entries: list[tuple[str, str | None]] = [
        ("enabled", "true" if enabled else None),
        ("plan", _toml_str(plan_s) if plan_s else None),
        ("build", _toml_str(build_s) if build_s else None),
        ("review", _toml_str(review_s) if review_s else None),
        ("scout", _toml_str(scout_s) if scout_s else None),
        ("review_enforce", _toml_str(enforce) if enforce != "off" else None),
        ("review_max_rounds", str(rounds) if rounds != 2 else None),
    ]
    lines = _upsert_table_keys(lines, "roles", entries)

    text = "\n".join(lines).strip("\n")
    path.write_text(text + "\n" if text else "")
    return str(path)


def write_project_trust(
    project_path: str,
    *,
    enabled: bool,
    streak_required: int,
    auto_action: str,
    require: dict[str, bool],
    target: str = "shared",
) -> str:
    """Targeted, non-destructive write of the `[trust]` autonomy-ladder policy
    (Bet 9 — `backlog/autonomy-ladder.md`).

    Upserts each key inside `[trust]` in place, preserving `[scripts]`, `[gate]`,
    `[ports]`, and the `[workflow]` keys the Git/Gate tabs own (same reasoning as
    ``write_project_merge_mode``/``write_project_gate``). The trust policy is **team
    law**: the committed ``settings.toml`` is authoritative and a personal
    ``settings.local.toml`` layers on top of it key-by-key (it may only *tighten* —
    turn the ladder off, re-require a dropped condition, raise the streak — never
    loosen). That difference drives what each target omits:

      * ``target="shared"`` writes the committed file and omits keys left at their
        hardcoded default, keeping the block minimal (like ``write_project_gate``).
      * ``target="local"`` writes only the keys that differ from the *committed*
        policy it inherits, so a personal file reads as a pure tightening delta over
        team law rather than a full copy. This is the deliberate opposite of
        ``write_project_agent`` (whose ``.local`` pins every key): there an omitted
        key would leak the team value in place of the default, whereas here
        inheriting the team value is exactly what a partial trust override wants.

    Values are normalized through the loader's own parser first, so a value the UI
    sends lands where a hand-edited file would. Returns the path written.
    """
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname

    enabled, streak_required, auto_action, require = _parse_trust(
        {
            "enabled": bool(enabled),
            "streak_required": streak_required,
            "auto_action": auto_action,
            **{f"require_{c}": require.get(c, True) for c in TRUST_CONDITIONS},
        }
    )

    # Omit a key when it equals what the file inherits: a shared write inherits the
    # hardcoded defaults; a `.local` write inherits the committed team policy below it.
    if target == "shared":
        b_enabled, b_streak, b_action, b_require = _parse_trust({})
    else:
        committed = _read_toml(base / "settings.toml").get("trust", {})
        b_enabled, b_streak, b_action, b_require = _parse_trust(
            committed if isinstance(committed, dict) else {}
        )

    entries: list[tuple[str, str | None]] = [
        ("enabled", ("true" if enabled else "false") if enabled != b_enabled else None),
        ("streak_required", str(streak_required) if streak_required != b_streak else None),
        ("auto_action", _toml_str(auto_action) if auto_action != b_action else None),
    ]
    for c in TRUST_CONDITIONS:
        val = require[c]
        entries.append(
            (f"require_{c}", ("true" if val else "false") if val != b_require[c] else None)
        )

    lines = _upsert_table_keys(_read_text(path).splitlines(), "trust", entries)
    text = "\n".join(lines).strip("\n")
    path.write_text(text + "\n" if text else "")
    return str(path)


def write_project_firewall(
    project_path: str,
    *,
    firewall: str,
    strict: bool,
    target: str = "shared",
) -> str:
    """Targeted, non-destructive write of the Merge Firewall posture into the
    ``[trust]`` table (backlog/merge-firewall.md §3).

    Upserts only ``firewall``/``strict`` in place, so it can't clobber the autonomy
    ladder's own ``[trust]`` keys (``enabled``/``streak_required``/…) or any other
    table — same discipline as ``write_project_trust``/``write_project_gate``. The
    firewall is repo policy, so it defaults to the committed ``settings.toml``
    (``target="shared"``); a value at its default is omitted to keep the block
    minimal. Returns the path written."""
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname

    firewall, strict = _parse_firewall({"firewall": firewall, "strict": strict})
    entries: list[tuple[str, str | None]] = [
        ("firewall", _toml_str(firewall) if firewall != "off" else None),
        ("strict", "true" if strict else None),
    ]
    lines = _upsert_table_keys(_read_text(path).splitlines(), "trust", entries)
    text = "\n".join(lines).strip("\n")
    path.write_text(text + "\n" if text else "")
    return str(path)


def _toml_str(s: str) -> str:
    """Serialize a Python string as a TOML string value (basic or multi-line)."""
    if "\n" in s:
        body = s.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
        return f'"""\n{body}\n"""'
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_project_scripts(
    project_path: str,
    *,
    setup: str | None,
    run: str | None,
    archive: str | None,
    run_mode: str,
    login_shell: bool,
    port_range: tuple[int, int],
    gate: dict[str, str] | None = None,
    target: str = "local",
) -> str:
    """Write the `[scripts]` (+ `[gate]` + `[ports]`) config from the in-app editor.

    ``target="local"`` writes ``settings.local.toml`` (personal, gitignored);
    ``target="shared"`` writes ``settings.toml`` (committed → the whole team
    inherits it). The file is regenerated cleanly with a header comment; only the
    documented `scripts`/`gate`/`ports` tables are managed (hand-added custom keys
    aren't preserved — that's a known v1 limitation, and it includes multi-run
    `[scripts.run.<id>]` tables: saving here collapses them to the single default
    `run` string, so hand-authored multi-run configs are edited in TOML directly).
    ``gate`` (from a stack preset)
    writes a `[gate]` table when non-empty; passing ``None``/empty omits it (default
    → vitest). Returns the path written.
    """
    base = Path(project_path) / ".haro"
    base.mkdir(parents=True, exist_ok=True)
    _ensure_local_gitignore(base)
    fname = "settings.toml" if target == "shared" else "settings.local.toml"
    path = base / fname

    lines = [
        "# haro project config: managed by the in-app scripts editor.",
        "# settings.toml is committed (shared with the team); settings.local.toml is personal (gitignored).",
        "",
        "[scripts]",
    ]
    if setup:
        lines.append(f"setup = {_toml_str(setup)}")
    if run:
        lines.append(f"run = {_toml_str(run)}")
    if archive:
        lines.append(f"archive = {_toml_str(archive)}")
    lines.append(f'run_mode = "{run_mode or "concurrent"}"')
    if login_shell:
        lines.append("login_shell = true")
    if gate:
        lines += ["", "[gate]"]
        # Stable, readable key order: runner leads, then its command/format; any
        # other keys follow. Mirrors presets.to_toml_fragment.
        for key in ("runner", "command", "format"):
            if key in gate:
                lines.append(f"{key} = {_toml_str(str(gate[key]))}")
        for key, val in gate.items():
            if key not in ("runner", "command", "format"):
                lines.append(f"{key} = {_toml_str(str(val))}")
    lines += ["", "[ports]", f"range = [{int(port_range[0])}, {int(port_range[1])}]", ""]

    path.write_text("\n".join(lines))
    return str(path)
