# Changelog

All notable changes to **haro** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **On versioning.** haro is young and its public API/config surface is still moving,
> so it lives in the `0.y.z` range — where SemVer explicitly means "no stability promise
> yet." The `v1` / `v2` labels you'll see in `CLAUDE.md` and `notes/` are **internal
> roadmap milestones**, not release versions; they map *underneath* the `0.x` line below.
> The open-source debut is **0.1.0**.
>
> **A note on history.** The project was originally called **Synthesis** and was renamed
> to **haro** in `0.4.0` (2026-07-12) — older commits and the parallel `Synthesis: …`
> development line refer to the old name. The very first commit
> (`Initial checkpoint: Synthesis v0 → v2.0`) squashed the entire pre-history into one
> baseline, which is recorded here as `0.1.0`.

## [Unreleased]

### Fixed
- **Desktop app: prefs and queued tasks lost on every relaunch, 45s hang on a dead
  backend** — `desktop/main.js` picked a fresh OS-random port every launch, so the SPA's
  origin changed every launch too: Chromium scopes `localStorage` (model/effort/backend
  pickers, plan-first, fast mode, mono font, theme, and the queued-task list) and the HTTP/
  V8-bytecode caches per-origin, so all of it silently reset on relaunch and the `immutable`
  cache headers `main.py`'s `_CacheControlledSPA` already sends for hashed assets never got
  to help. `pickPort()` now prefers a fixed port (`HARO_DESKTOP_PORT`, default `41417`) and
  only falls back to a fresh OS-assigned one if that port is taken — the "never reuse a
  listener we didn't start" rule is unchanged, only *which* free port we ask for first.
  Also: a backend that dies right at spawn (bad venv, a stolen port, a broken frozen binary)
  used to make the health-poll wait its full 45s timeout before showing the failure screen;
  `whenReady` now races `waitForHealth()` against the backend process's own `exit` event and
  surfaces the exit code in the failure copy.
### Changed
- **Desktop app startup + process hygiene.** `desktop/main.js`: the login-shell `PATH` scrape
  (~1s on a typical rc file) ran synchronously at module load, before the splash window could
  even open — it's now `child_process.exec` kicked off at module load and awaited inside
  `startBackend()`, so Chromium/window init overlaps it instead of being blocked by it. Added
  explicit `sandbox: true` (already Electron's default here, now pinned so a future preload
  edit can't silently loosen it), `v8CacheOptions: "bypassHeatCheck"` (writes the V8 code
  cache on the first load rather than waiting for repeated hits — pays off now that the origin
  is stable), and `nativeTheme.themeSource = "dark"` (Kuro is dark-only; native chrome no
  longer flashes a light default before the first paint). `backend/desktop_app.py` now passes
  `timeout_graceful_shutdown=3` to `uvicorn.run` (parity with `run.sh`'s dev launcher), so quit
  can't hang on a lingering WebSocket. `backend/haro-backend.spec` excludes `pytest`/`pluggy`/
  `tkinter`/etc. from the frozen build (size only — nothing under `haro/` imports them at
  runtime; the frozen binary just doesn't need to carry the test-suite's own dependency).
  `backend/haro/main.py`'s boot `lifespan` now prints one `[boot] <step> <ms>ms` line per
  startup step (skill install, DB init/load/reconcile, adoptable-worktree scan, orphan-run
  sweep) to `~/.haro/backend.log`, to make a slow desktop launch diagnosable without a
  profiler.
- **Desktop app: heavy panels moved out of the root JS bundle.** `frontend/src/App.tsx` now
  `React.lazy()`s `Terminal` (xterm), `CodePanel` (already lazy internally for Monaco, but was
  itself eager), `GitPanel`, `ReviewPanel`, `SettingsModal`, and `ProjectSettingsModal` —
  the same pattern `CodePanel.tsx` already used for Monaco — each behind a `<Suspense
  fallback={null}>` at its render site. `Backlog` stays a static import: `ProjectDashboard.tsx`
  renders it unconditionally as the project-home view's always-visible column, so it was
  already forced into the root chunk from that eager path and a dynamic import from `App.tsx`
  would have been a no-op (Rollup's own `[INEFFECTIVE_DYNAMIC_IMPORT]` warning confirmed it
  before this was reverted). Measured on this repo: the root chunk (`index-*.js`) went from
  1,081.90 kB to 624.21 kB (gzip: 312.11 kB → 196.00 kB), about 42% smaller, with the six
  panels now loading on first use as their own chunks instead of every workspace paying for
  all of them upfront.
- **Real app icon, replacing the placeholder Haro (Gundam) ball** — `desktop/assets/icon.png`
  (window/taskbar icon) and `desktop/build/icon.png` (electron-builder's `.icns`/`.ico` source)
  were still the literal green Haro-ball placeholder from before the Kuro/ryoku rebrand.
  Replaced with the "H." slab monogram from the Kuro icon exploration (bone `#E8E4DA` on
  near-black `#0A0A0A`, 22% corner radius, subtle grain, a hairline `#232120` edge so a
  near-black plate doesn't vanish on an equally dark Dock/taskbar), rendered at a precise
  1024×1024 from the design's own SVG spec rather than upscaled from a screenshot.
  `frontend/public/favicon.png` gets the same mark at 512×512. The appbar wordmark also
  gets a lockup mark: `HaroMark` (`components/icons.tsx`) sits to the left of the `haro.`
  text in `.brand` (its `gap:9px` flex layout was already shaped for this, just never had
  a mark to fill it) — using the icon exploration's "stack" treatment (three horizontal
  bands resolving from a dither through a checkerboard half-tone to solid bone), picked
  over the plain "H." slab so the lockup echoes the brand's dithered-halftone accent
  instead of just repeating the app icon. A live SVG `<pattern>` only reads as texture at
  the design canvas's own ~62px preview: shrunk to the ~26px the appbar actually shows it
  at, a 1-unit dither tile is sub-pixel and every renderer just blurs it to flat grey. Uses
  the design's own fix instead: `coarse25`/`coarse50` (4-unit cells, so each cell still
  lands on a whole device pixel at icon size), baked to a real pixel-exact PNG asset
  (`frontend/public/brand/haro-mark-stack.png`, generated by the new `brand/haro_mark_stack.py`
  from the same pattern math as the design file, not a screenshot) so the UI's downscale is
  one clean area-average instead of a fight with sub-pixel SVG tiling.
- **③ verify Zone 3/4 cards + hover** — the "things to look at" and "details" accordions
  in the gate panel are now real cards (border + panel surface, matching each other); their
  header `<button>`s no longer inherit the base 3D keycap hover (a stray translateY jump +
  a floating box-shadow line on a flat, borderless button), replaced with a plain background
  tint. Inside Details, hairline top-dividers now separate the grid/flamebar/impact-map/
  coverage-flaky/mutation sections instead of one run-on stack.
- **Homepage dashboard scroll + a root-cause Chromium scrollbar bug** — the "workspaces" home
  dashboard's header (title/counts/select toggle) used to scroll away with the workspace grid;
  it now stays fixed while only the list scrolls (`.dash-body`). Found along the way: `body`'s
  `scrollbar-width`/`scrollbar-color` silently disabled every custom `*::-webkit-scrollbar*`
  rule in Chromium (≥121), falling back to the platform's native scrollbar chrome (GTK arrow
  buttons included) app-wide — the actual explanation for several "stray arrow" sightings
  this pass. Fixed by scoping those properties to `@supports not selector(::-webkit-scrollbar)`
  (Firefox only); the same unguarded footgun existed on the editor's tab strip and the mobile
  stats/settings rails, fixed the same way.
- **Housekeeping** (`usp-critique-round3.md`) — PyPI distribution renamed `haro` →
  `haro-gate` (the `haro` name collided with an unrelated 2.7-era package; the console
  script stays `haro`), README install lines updated to match; `pyproject.toml`'s stale
  `asyncpg` dependency (left over from the pre-SQLite-migration era, unused by any code)
  replaced with `aiosqlite`; `CLAUDE.md` corrected to say SQLite/`run.sh` are the real
  runtime instead of the stale Postgres/Docker-primary claims; `docker-compose.yml`'s dead
  Postgres service and `DATABASE_URL` (the backend never read it) removed, and its SQLite
  file now bind-mounts to the host so it survives container restarts instead of living in
  the container's ephemeral filesystem; `haro.desktop`'s `Exec` path (pointing at a
  deprecated machine) replaced with an edit-me placeholder and a comment explaining why
  it can't be a shell variable.

### Added
- **Workflow roles, Phase 3: the refuter, a review-fix loop, and plan text**
  (`notes/workflow-roles-plan.md`, `backlog/workflow-roles.md`) — an independent
  re-check of a green gate's diff against the task/plan, consuming the deterministic
  test/tamper/code-to-check facts as evidence instead of re-deriving them, and
  spending its read-only tools (Read/Grep/Glob, unlike plan compliance's diff-text-
  only pass) on what tests structurally can't answer: correctness bugs, missed edge
  cases, silent scope drift, a suite too thin to catch what it should. Runs
  automatically on every full-scope green when `[roles] review_enforce` is `"warn"`
  or `"block"`; a `"fail"` verdict under `"block"` folds `review_blocked` into the
  green conjunction the same way the Double Gate's `quality_blocked` does, so
  `ship_preflight`, the receipt, and the dashboard glance all refuse it for free.
  Same two anti-rationalization guardrails as plan compliance, reused rather than
  reinvented: cite-or-drop (an ungrounded must-fix is dropped) and a "fail" with
  nothing left standing downgrades to "pass" plus an honest note. Under `"block"`, a
  FAIL with a surviving must-fix drives a SECOND bounded fix loop (after the test
  auto-fix loop, not nested in it) on the build role — "warn" records the verdict
  without ever spending a fix round on it. A plan run's final result text is now
  captured onto `Workspace.plan_text`, so the refuter audits against the plan the
  dev actually approved, not just the one-line task. The ③ page's Zone 1 gets a
  "refuter: PASS (<model>)" caveat on a clean pass, Zone 2 a `RefuterBanner` when
  blocking, Zone 3 the must-fix list when merely flagged (warn mode) or pass-with-
  notes, and Zone 4 an on-demand "refute now" button. An independent refuter pass
  caught a real cost bug before this shipped: the entry condition checked `only is
  None` but not `test.scope == "all"`, so a project on `[gate] default_scope =
  "impacted"` paid a full refuter call on every fast gate and auto-fix/review-fix
  re-gate — the existing "impacted scope never runs it" test used the wrong scope
  knob and passed vacuously. Fixed, plus a `TypeError` parse-guardrail gap the same
  pass found in the new on-demand endpoint (pinned end-to-end, not just at the
  parser). Backend: 50 new tests (1154 passing total). Frontend: 27 new tests
  (579 passing total, tsc clean).
- **Workflow roles, Phase 2: scout sub-agent injection** (`notes/workflow-roles-plan.md`,
  `backlog/workflow-roles.md`) — when `[roles] scout` is configured, every plan/build run
  started from the composer gets haro's own read-only `scout` sub-agent (Read/Grep/Glob only, the project's
  configured scout model) via Claude Code's `--agents` flag, plus a short instructions
  paragraph telling the driving agent to delegate broad mapping/"where is X" lookups to
  it instead of reading whole files itself. Verified against the installed CLI (2.1.273)
  before writing any code: `--agents` accepts an array `tools` value and **merges** with
  same-named `~/.claude/agents/*.md` files rather than replacing them — but it still puts
  scout on the argv itself, so it now travels with the project onto any machine and
  survives `[agent] sandbox` (whose bwrap profile never binds `~/.claude/agents`).
  Feature-detected through `runner._drive_agent`/`run_agent` exactly like `fast`, so an
  auto-fix round inherits the same scout and the local-model adapter is unaffected. A
  sub-agent delegation (`Agent`/`Task` tool_use with a `subagent_type`) renders in the
  stream as a dim, indented `↳ scout: <description>` row instead of being summarized by
  its own (long) prompt. `backend/haro/roles.py` (new), 29 new backend tests (1104
  passing total — includes 4 pinning `start_agent`'s `agents` construction gate
  itself, added after an independent refuter pass verified it by hand and flagged
  the coverage gap), `AgentStream.delegate.test.tsx` (551 frontend passing total,
  tsc clean). Known gap: `race ×N` lanes (`fanout.py`) don't get a scout yet.
- **Workflow roles, Phase 1: `[roles]` config + plan/build resolution + composer role
  strip** (`notes/workflow-roles-plan.md`, `backlog/workflow-roles.md`) — opt-in
  `[roles] enabled = true` gives each step of the plan→scout→build→refute loop its
  own `"model:effort"` (`plan`/`build`/`review`/`scout`, `config.RoleConfig`/
  `_parse_role`/`write_project_roles`), closing the trap where approving a plan
  silently built at whatever model the plan step happened to run: `start_agent`'s
  resolution is now explicit `req.model`/`req.effort` → this run's ROLE (plan or
  build, resolved from `req.role` or `req.plan`) → the project's plain `[agent]`
  default → `"sonnet"`, and `AgentRun.role` is stamped onto the bootstrap event so
  the stream badge shows which step ran. `GET/PUT /projects/{id}/roles` + a new
  Roles settings tab (model/effort pickers per step, a generated `[roles]` TOML
  preview, personal/team scope). The composer replaces its model/effort pickers
  with a role strip (`plan · build · review`, next step highlighted, click → Roles
  tab) when roles are on — critically, `runArgs` (moved to the new `frontend/src/
  roles.ts`, alongside `nextRole`/`roleLabel`/`stripSteps`) omits `model`/`effort`
  entirely in that state, since an explicit `req.model` always wins server-side and
  would otherwise silently reopen the exact trap this feature exists to close; an
  independent refuter pass caught that gap (the strip rendered correctly but the
  request still carried the stale picker's model) before it shipped. `enabled =
  false` (the default) leaves every resolution path byte-identical to before this
  change. Review (the refuter) and scout (sub-agent injection) are parsed and
  savable today but only acted on from Phase 2/3.
- **Kuro motion system + dossier boot screen** (`notes/kuro-motion-plan.md`) — a token-driven motion layer (`styles/motion.css`: `--dur-1/2/3`, `--dur-breath`, `--dur-spin`, `--ease-out`, `--ease-in-out`; the `resolve`/`breathe`/`spin`/`rule-draw`/`stamp`/`cell-resolve` primitives) replacing 23 scattered keyframes, 15 distinct durations, 7 easings and 15 duplicated `prefers-reduced-motion` blocks. The flagship moments: the gate going green now stamps once (a hanko-seal settle plus a permanent accent hairline under the verdict, Nord's aurora sweep untouched), the live grid's cells resolve in as results stream (no artificial stagger — the reporter's timing IS the sweep), and the ① agent › ② code › ③ gate › ④ ship stepper crossfades via a same-document View Transition (`motion.ts`'s `withViewTransition`) instead of a jump cut. First paint is a self-sufficient inline dossier splash (`index.html`'s `#boot`, no bundle CSS dependency) that reports BACKEND/WORKSPACES/LIVE FEED as they come up, then morphs the wordmark into the appbar brand; `desktop/loader.html` mirrors it for Electron's pre-health splash. Former glow keyframes (mic-pulse, composer-seeded/flash-glow, op-pulse, ribbon-pulse) became border/outline breathes — no `box-shadow` keyframes remain anywhere in the theme. Single global `prefers-reduced-motion` rule in `motion.css` replaces the per-site ones; the megaman/nord theme flourishes and loader.css's reference three-bar breathing loader are the deliberate, documented exceptions left untouched.
- **Move D step 1: Linux-first gets teeth** (`usp-critique-round3.md`) — opt-in
  `[gate] sandbox = true` runs the vitest suite under bubblewrap with network
  denied (`--unshare-net`), so a green gate can mean "green, AND offline" — the
  one thing a macOS-only rival structurally cannot follow. `sandbox.py` is the
  new module (`bwrap_available`, `wrap_command`, `profile_hash`); `VitestAdapter`
  is the only runner that supports it so far (a project on `[gate] runner =
  "command"`/`"pytest"`/`"offense"` degrades with a named reason instead of
  silently running unsandboxed); `Receipt.sandbox_profile`/`TestRun.sandbox_profile`
  carry which profile produced the green, `None` when it wasn't sandboxed.
  **OFF by default. Verified against a real `bwrap` on Linux (2026-09-15)**:
  a throwaway vitest 4 project gated with `sandbox = true` stamps a
  `sandbox_profile` on the receipt and green suite; a test added to that
  project that does a live `fetch()` fails under the sandbox and passes with
  `sandbox = false`, confirming `--unshare-net` actually reaches the vitest
  subprocess rather than just shaping the argv.
- **Move D step 2: agent sandboxing** (`usp-critique-round3.md`) — opt-in
  `[agent] sandbox = true` confines the `claude` CLI subprocess under bwrap
  instead of handing bare `--permission-mode bypassPermissions` the whole
  host: network stays shared (the agent must reach `api.anthropic.com`), but
  the filesystem default-denies `$HOME` (a fresh, empty, private tmpfs) with
  an explicit read-only allowlist for the agent's own toolchain
  (node/nvm/volta/asdf/claude's install, resolved dynamically via
  `realpath(which("claude"))` so it isn't pinned to one install layout),
  read-write on an allowlist of specific `~/.claude` paths plus
  `~/.claude.json` (the CLI's own credentials and session state — required,
  not optional; see residuals below), and
  read-write access only on the worktree plus, when writable, the project's
  real git common dir (a haro worktree's `.git` is a *file* pointing at
  `<project>/.git/worktrees/<name>`, so binding only the worktree would leave
  `git add`/`commit`/branch writes hitting the read-only root; the common
  dir's `hooks/` is masked so a compromised agent can't plant a hook that
  runs unsandboxed on the host later). Wired into both
  `ClaudeCodeAdapter.run()` and `review.py`'s two one-shot calls
  (`run_review`, `run_plan_compliance` — the latter two get the *stricter*
  read-only-worktree, no-`.git` profile, matching their already-disabled
  tools); the local-model adapter has no sandbox support at all, so a run
  now REFUSES outright (400) rather than executing unconfined when
  `[agent] sandbox = true` and the resolved adapter is `local`. **Fails
  CLOSED, not open**: unlike the test gate's sandbox (which degrades to an
  unsandboxed run plus a flagged receipt), `[agent] sandbox = true` with no
  `bwrap` installed refuses to run at all (a normalized `error` event) — an
  unsandboxed `bypassPermissions` run is precisely the outcome this flag
  exists to prevent, so continuing anyway would be worse than refusing.
  Verified against real bwrap on Linux (2026-09-15): a `/bin/sh` probe
  standing in for the agent confirms writes outside `$HOME`/the worktree are
  discarded (masked, not merely denied — `$HOME` and the git `hooks/` dir are
  writable-but-ephemeral tmpfs overlays, so a write *succeeds* inside the
  sandbox and never reaches the real host path), `.ssh`/unlisted dotfiles are
  invisible, network egress still reaches `api.anthropic.com`, a real `git
  commit` inside the worktree still works, and `procs.terminate_tree` still
  reaches every sandboxed child (the sandboxing deliberately omits
  `--new-session` and any PID-namespace unshare, both of which would move the
  process out of reach of haro's host-side `killpg`-based teardown).
  An independent refuter pass then caught three real bugs the mocked tests
  missed, all fixed before this shipped: (1) `~/.claude`/`~/.claude.json`
  weren't allowlisted at all, so a *real* `claude -p` run failed at login
  every time (`claude --version`/`--help` don't need credentials, so the
  first verification pass missed it — a real non-interactive run now
  succeeds authentication through the wrapper); (2) an earlier revision
  read-write bound `~/.cache` on the theory it held the npm package cache —
  wrong (npm's cache is `~/.npm`, confirmed via `npm config get cache`, and
  isn't bound at all), and `.cache` is exactly the "plant something the host
  runs later" pattern (pre-commit hook venvs, uv/pip wheel caches) `.git/hooks`
  masking exists to close, so it was removed rather than narrowed — sandboxed
  npm/pip installs simply re-download every run now; (3) `[agent] sandbox =
  true` silently did nothing when the resolved adapter was `local` (no bwrap
  support there at all) — a fail-OPEN under a flag whose entire point is
  refusing exactly that, now a 400 refusal instead.
  A second refuter pass on those fixes then caught a fourth, more serious
  bug in the fix for (1): binding `~/.claude` read-write also handed a
  compromised agent a DELAYED, unconfined host code-execution path — plant a
  `hooks` entry in `settings.json`/`settings.local.json` and it runs as an
  ordinary shell command the next time `claude` runs anywhere (the embedded
  terminal, any project with the flag off, review.py's own unsandboxed
  calls), or edit `CLAUDE.md`/`agents/`/`commands/` to persist a malicious
  system prompt into every future session. Verified against real bwrap both
  ways: before the fix, a write to `settings.json` inside the sandbox
  persisted to the real host file; after, it doesn't.
  A THIRD refuter pass then found the fix for that itself incomplete: it
  conditioned the relock on `os.path.exists`, a no-op for any path that
  doesn't exist yet (`settings.local.json` doesn't exist on a fresh
  install) — a compromised agent just creates it instead of editing an
  existing one, and the write went through and persisted. Also missing
  entirely: `~/.claude/plugins/` (a plugin's own `hooks`/`.mcp.json`
  server definitions are the same exec-capable class, arguably worse — a
  whole directory of them). Both fixed: the lock is now unconditional
  (files get `--ro-bind-try /dev/null <path>`, directories get `--tmpfs
  <path>` — neither skips when the target is absent, unlike every other
  allowlist in this module, which are genuine optional conveniences) and
  `plugins/` was added alongside `settings.json`/`settings.local.json`/
  `CLAUDE.md`/`agents/`/`commands/`. `shell-snapshots/` (a per-session
  script the CLI sources on Bash tool calls, at a path shared across every
  `claude` process for this user) is additionally masked (private,
  writable-but-ephemeral, same mechanism as `.git/hooks`) so a compromised
  sandboxed run can't overwrite a *different*, concurrently-running
  unsandboxed session's snapshot. Verified against real bwrap with
  deliberately-absent target paths this time (the exact gap the second
  pass's verification missed by only testing paths that already existed):
  no attacker-written content ever reaches the host for any of these,
  though bwrap can leave a harmless empty stub file/directory behind for a
  path that didn't exist before (documented in `sandbox.py`, not a security
  gap — the alternative is the bug this replaced).
  A FOURTH refuter pass then found the most severe entry yet, by asking
  "what else under `.claude` has exec/persistence power?" instead of
  re-auditing the same three files again: Claude Code's BACKGROUND DAEMON
  (a real host process, entirely outside this sandbox, confirmed against
  the actual 2.1.272 binary) ingests files dropped into
  `~/.claude/daemon/dispatch/` and respawns workers straight from
  `~/.claude/daemon/roster.json` on takeover — both carry an
  attacker-choosable `launch.flagArgs`/`cwd` (verified against this host's
  own real `roster.json`, which contains exactly such a `launch` object).
  `daemon/control.key` (meant to gate who may talk to the daemon) is itself
  just a readable file inside the same writable `.claude` tree, so it
  defended nothing. `~/.claude/jobs/` holds per-job state read back the
  same way. Both were entirely missing from the lock — the same "plant it,
  it runs unconfined later" pattern as `.git/hooks`/`settings.json`/
  `.cache`, just a directory this profile hadn't looked at yet. Fixed by
  adding `.claude/daemon` and `.claude/jobs` to the same masked-directory
  treatment as `shell-snapshots/`. Verified a real, authenticated
  `claude -p ... --model haiku` run still completes normally with both
  masked (haro's headless runs don't rely on the background daemon), and
  that the daemon's real dispatch/roster files on this host are untouched
  after the run.
  A FIFTH and SIXTH refuter pass then found the pattern itself was the
  problem: asking "what else is under `.claude`" kept finding new
  exec-capable surfaces faster than they could be denied —
  `~/.claude/scheduled_tasks.json` (a durable task scheduler that survives
  restarts and fires later, unconfined), `daemon.json`/`launch.json`/
  `assistant-daemon-state.json` (daemon config siblings of the two already
  masked), `hooks/`/`skills/` (a skill bundles executable scripts, not just
  instructions), `workflows/`/`routines/`/`rules/`/`output-styles/` (the
  same persistent-prompt-injection class as `CLAUDE.md`), `mailbox/`,
  `agent-registry.json`, `remote-settings.json` (an org-settings cache
  whose payload can itself carry `hooks`/`sandboxSettings`) — a real-bwrap
  probe planted attacker content in 15 such paths in one pass. So this
  shipped as a structural inversion instead of a sixth denylist entry:
  `.claude` is now an ALLOWLIST (`sandbox.py`'s `_CLAUDE_RW_ALLOW`) —
  only specific, verified-pure-data paths (`.credentials.json`,
  `history.jsonl`, `sessions`, `projects`, `file-history`, `cache`,
  `paste-cache`, `image-cache`, `session-env`, `downloads`, `backups`,
  `plans`, `daemon.log`, and a few small housekeeping/cache-stamp files)
  are bound read-write; everything else under `.claude` — including
  anything a future Claude Code release adds that isn't on this list yet —
  simply does not exist inside the sandbox at all, not locked, not masked,
  absent. A denylist has to be complete to be correct and re-verified on
  every release; this allowlist fails SAFE the moment Anthropic ships the
  next config surface (something merely doesn't persist, rather than
  reopening an exec channel). The equivalent PROJECT-level
  `<worktree>/.claude` (a second surface the same pass found — Claude
  Code's own denylist covers this exact class of file at both the home
  root and the cwd root) is masked wholesale rather than allowlisted,
  since nothing there carries session continuity the agent needs mid-run.
  Verified against real bwrap with the exact attacker-planted paths from
  the finding (none persist) and, again, a real authenticated
  `claude -p ... --model haiku` run against the real `~/.claude` (completes
  normally; the real `daemon/dispatch/` stays empty and `settings.json`
  byte-identical afterward).
  `~/.claude.json` (the top-level FILE, not the directory) remains the one
  deliberate, unclosed exception — see residuals below.
  A SEVENTH refuter pass, aimed specifically at the two new mechanisms this
  inversion introduced (not another lap around `~/.claude` itself, which
  held), found one real bug in each: unconditionally masking
  `<worktree>/.claude` with `--tmpfs` makes a project's COMMITTED
  `.claude/settings.json` (Anthropic's own documented way to share
  tool-permission config with a team) look DELETED to git *inside* the
  sandbox — reproduced end to end: an agent's ordinary `git add -A &&
  git commit` committed that deletion for real, and it reached the host
  branch. Fixed: when the worktree already has a `.claude/`, it's now
  re-bound READ-ONLY instead (git sees no change, the CLI can still read
  it, but no write — existing file or new one — persists); `--tmpfs` is
  reserved for the case where nothing exists yet to lose. Separately,
  `~/.claude/skills` — where haro installs its own `haro`/`haro-dev` skills
  on every boot so every run discovers them — isn't pure data (a skill
  bundles executable scripts) so it was correctly left off the read-write
  allowlist, but that meant it didn't exist under the sandbox at all,
  silently disabling the feature with no warning. Fixed with a new
  READ-ONLY-only allowlist (`_CLAUDE_RO_ALLOW`): discoverable, never
  writable, so it can't reopen what the inversion just closed.
  **Honest residuals, not solved here**: network is fully open — no egress
  proxy/allowlist, so a compromised agent can still exfiltrate anything it
  can read over the open network. Mount-namespace confinement only — no
  Landlock, no seccomp (this host's glibc doesn't wrap
  `landlock_create_ruleset`, there's no pip binding, and bwrap 0.12.0 has no
  native `--landlock` flag). The project's `.git/config` stays writable, so a
  `core.hooksPath` redirection elsewhere is unmitigated even with the default
  `hooks/` masked. `~/.claude.json` (the top-level file, not the directory)
  is NOT narrowed — it carries session state the CLI must write AND
  `mcpServers` entries the CLI spawns as commands, so a compromised run can
  still reach unconfined execution through that one file; closing it would
  need JSON-level access control, not a bind-mount, and is unclosed by
  design here, not overlooked. The same exposure, smaller, applies to
  `~/.claude/.credentials.json` itself (bound read-write, needed for OAuth
  token refresh) — a compromised run can overwrite it, which isn't code
  execution but is account-level (redirects subsequent unsandboxed runs to
  an attacker's org, or at minimum forces a re-login); a deliberate
  tradeoff, not an oversight. `backups/` (also allowlisted) is a second,
  weaker path to the same `mcpServers` exposure. `bwrap_available()` only checks PATH, not
  whether unprivileged user namespaces are actually usable (a host with
  `kernel.unprivileged_userns_clone=0` or an AppArmor restriction fails at
  bwrap's own exec time instead of with a named reason). `git_common_dir()`
  assumes an absolute `gitdir:` pointer; `worktree.useRelativePaths` (git
  ≥2.48) would produce a relative path that hard-fails the run instead of
  degrading cleanly. `agent_profile_hash()` exists (mirroring the test
  profile's `sandbox_profile`) but isn't wired to any `AgentRun`/receipt
  field yet — no record of whether a given agent run was actually sandboxed.
- **Move B: gate everywhere** (`usp-critique-round3.md`) — the gate reaches
  where orchestration was absorbed to, instead of waiting for a haro workspace:
  - **Claude Code plugin** (`plugin/`): `Stop`/`SubagentStop` hooks run the same
    blocking `haro gate` recipe the README already documented, now installable
    instead of hand-copied.
  - **`haro-gate` GitHub Action** (`action.yml`, repo root): installs and runs
    the CLI, posts the receipt to the job summary EVEN on a red gate (a
    reviewer needs the evidence for the failure, not just a red X), fails the
    check on anything not a genuine green. Inputs cross into the composite
    action's shell step through `env:`, never interpolated directly into the
    `run:` body (refuter round-1 on this move reproduced both a word-splitting
    bug and an arbitrary-shell-execution bug from the direct-interpolation
    version).
  - **Git `pre-push` recipe** (README) for a repo with no haro workspace,
    plugin, or CI at all — just the CLI.
  - **Built, then CUT after review**: `WorktreeCreate`/`WorktreeRemove` hooks
    meant to keep the Merge Firewall's adoptable-worktree list live without
    polling. Refuter round-1 found the real Claude Code contract for
    `WorktreeCreate` is a REPLACEMENT hook (must itself perform the checkout
    and return the resulting path, or worktree creation fails for every
    project on the machine — an observer-only rescan script breaks it, not
    just no-ops), and that the natural `WorktreeRemove` handler
    (`DELETE /workspaces/{id}`) calls `git_ops.remove_worktree`, which
    force-deletes the underlying git branch — reproduced live as real data
    loss. Cut rather than shipped broken; see README's Plugin section for the
    reasoning. Path resolution for what WAS kept (none of the cut code needed
    it, but the exercise caught it first) was hand-verified against a real
    backend + real git worktrees along the way — a real bug (macOS resolves
    `/tmp` → `/private/tmp`; a naive path string-match silently matched
    nothing) was found and fixed before the cut, in code that no longer ships.
- **Move A: portable proof** (`usp-critique-round3.md`) — the receipt stops being
  something only haro's own UI/CLI can read:
  - `haro gate --json` — the Receipt as JSON instead of markdown.
  - `haro gate --attest` — signs the receipt as an in-toto-shaped, ed25519-signed
    DSSE envelope (subject = `git merge-base` + a diff fingerprint, predicate = the
    full Receipt) and saves it under `.haro/attestations/`. The signing key is
    generated on first use at `$HARO_HOME/attest_ed25519` (default `~/.haro/`) —
    one identity per machine, not per project. `haro verify <sha>` re-checks a
    saved statement's signature against this repo (`0` intact, `2` tampered/wrong
    key, `1` couldn't run the check at all) — spelled `haro verify`, not the plan's
    literal `haro gate verify`, to avoid an argparse ambiguity between a
    subcommand and `gate`'s own positional `path` (see `cli.py`'s module
    docstring). `attest.py` is the new module; `git_ops.merge_base` is new.
  - Every merge commit (both the local and `gh` paths) now carries a
    `Verified-by: haro-gate <version> <digest>` trailer, and the `gh` path folds
    the Gate Receipt straight into the PR body at creation time instead of behind
    the manual "post to PR" button (`integrate.py`, `main.py`'s ship endpoint —
    it now builds the receipt on both paths, not local-only).
  - New dependency: `cryptography` (ed25519 signing). `_EXCLUDE`/`_add_pathspec`
    in `git_ops.py` were extended so a saved attestation never pollutes the very
    diff it just described (the same category as the injected node_modules
    symlink `gate.ensure_deps` already excluded).
  - The digest is frozen at GATE time (`TestRun.diff_fingerprint`, exposed as
    `Receipt.digest`), not recomputed from the live tree when the trailer/PR body
    is written — a checkpoint commit or edit between a green gate and the merge
    click must not silently attach a claim to a diff nothing ever gated
    (`main.py`, `rungs.py`'s `auto_merge` rung, and `cli.py --attest` all thread
    it through now instead of each re-diffing independently).
  - `verify_envelope` now requires `payloadType` present rather than defaulting
    it (a stripped field used to silently verify against the very default it
    should have equaled) and never trusts an envelope's own `signatures[].keyid`
    as fact — `haro verify` reports the key it actually verified against.
- **Move C: harder to fool, round 2** (`usp-critique-round3.md`) — three additions to
  the tamper alarm's trust story:
  - **Red-first check**: for each genuinely NEW test in a diff, the gate re-runs it
    against `base_ref` in a throwaway worktree, overlaying only the CURRENT content
    of the test files that hold it (new test, old implementation). A test that
    already passes there is flagged `vacuous` — it never exercised the behaviour it
    claims to, the correlated-error gap where the same model writes test and impl
    from the same misreading (`tamper.added_tests`, `gate._red_first_check`).
  - **Tamper-alarm config scope**: a diff touching `vitest.config.*`, `pytest.ini`,
    `pyproject.toml`'s pytest section, a `package.json` test script, husky/
    `.githooks`, `.claude/settings*.json` or `.vscode/tasks.json` now surfaces as a
    `config` finding — the file that decides WHICH tests run, not just their
    content (`tamper.config_tamper`).
  - **`[race] policy = "split_authors"`**: two lanes, one tests-only and one
    impl-only, so no single model can encode the same misreading into both the test
    and the implementation. Deliberately NOT routed through `race.judge`'s
    ranking (there is nothing to rank — see `fanout._judge_split_authors`); records
    both lane ids and lets a human combine + review by hand.
- **Kill-the-survivors loop** (`usp-critique-plan.md` idea 4) — the ③ strength tab's
  "fix all → agent" twin. When mutation scoring finds survivors (faults the suite didn't
  notice), a `+ kill survivors → agent` button batches all of them into one follow-up
  review task: "write a test that fails on this mutation" — never "fix the code," since a
  survivor is evidence the tests are too weak, not that the code is wrong. Reuses the same
  review-composer round-trip as the tamper alarm's "restore weakened tests" and the double
  gate's "fix all quality" actions (`gate.mutationReviewItems`, `App.killSurvivors`,
  `GatePanel`'s `onKillSurvivors` prop threaded into `MutationLane`).

### Changed
- **③ verify redesigned as one verdict-first page** (`notes/verify-redesign-plan.md`) —
  replaces the `grid`/`impact`/`trust`/`strength` tab strip with four zones: one plain
  headline + primary action (`verdict.ts`'s `gateVerdict`), a fixed-order blockers list,
  an advisory "things to look at" worklist, and a collapsed Details accordion for the
  grid/ribbon/impact map/on-demand tools. `verdict.ts` is the single derivation shared by
  the pane-head badge, the flow stepper, and the page, so they cannot disagree by
  construction. Frontend only, no backend change.
  - Code to check moved into ③ itself, widened into the generic "things to look at" zone
    (code-to-check rows, warn-mode tamper findings, plan-compliance gaps, advisory
    quality findings, suspected-flaky tests, a warn-mode coverage drop, mutation
    survivors) — the rail keeps only a one-line deep-link chip back to it
    (`CodeToCheck.tsx` → `LookAt.tsx`).
  - The trust checklist left ③ for ④ ship, its only home now: shown whenever the
    autonomy ladder is enabled (not only while merge-blocked), open while it's the
    reason a merge is stuck, collapsed to a one-line summary once green.
  - ④ ship now reads `blocked` on a "can't tell" verdict (a degraded green, not only a
    red one) — `integrate.ship_preflight` already refused that ship server-side; the
    stepper no longer disagrees with it.
  - `GateFocus { target, nonce }` replaces a scalar focus nonce, so a deep-link (a
    blocked flow-step click, a ④ ship trust-row fix) can say which zone to land on.
  - Mutation-score state lifted to `App`, joining the `analyzing` flag coverage/flaky
    already share, so its survivors feed the rail's look-at count too.
- **README repositioned around the USP** (`usp-critique-plan.md` week 6): leads with "the
  merge gate for agent-written code — it produces proof, not a green tick" instead of
  "Linux-first orchestrator", adds a Three Pillars table, and rewrites the gate section to
  actually describe the tamper alarm, mutation strength, Verified Hunks, the Double Gate,
  and the Gate Receipt (the old copy predated all of them). Fixed several doc-drift bugs
  caught by refuter in the process: a stale "AI review lane" reference (the lane was
  removed, the endpoint wasn't — corrected to API-only), a stale "preview" pane mention
  (the live-preview iframe was retired), two "merge → archive" claims that don't match
  `integrate.py` (merge no longer auto-archives), and an unqualified "writes a git note"
  claim on the merge endpoint (local-merge-only, not the `gh` PR path).

## [0.9.0] - 2026-09-14

### Added
- **Gate Receipt — the exportable evidence packet a reviewer reads instead of the diff**
  (`usp-critique-plan.md` idea 1). Assembles suite verdict, tamper status, verified-hunks
  percentage with untested files, mutation score with survivors (read from whatever was
  last computed on demand — building a receipt never triggers a new test run, mutation
  pass, or `gh` call), and agent model/effort/cost into one markdown block + JSON. Three
  sinks: the ④ ship step (`ReceiptPanel.tsx`), `POST /workspaces/{id}/receipt/pr-comment`
  (posts via `gh`, an explicit action — never automatic), and a `git notes` entry on the
  merge commit for local (no-remote) merges (the gh/PR path squash-merges on GitHub, so
  there's no local commit to note without pushing a notes ref to a shared remote — judged
  too risky for what this earns yet; the PR-comment sink covers that case instead). New
  `backend/haro/receipt.py`, `GET /workspaces/{id}/receipt`, `git_ops.add_note`,
  `git_panel.comment_pr`. Two new tri-state signals this exposed a real gap for and now
  fixes at the source rather than approximating in the receipt: `TestRun.tamper_measured`
  (`tamper_findings == []` alone can't tell "the alarm is off" from "it ran clean" —
  gate.py now stamps this on the alarm's actual completion path) and
  `MutationResponse.diff_fingerprint` (haro doesn't commit agent work until merge, so a
  commit sha can't detect a stale cached mutation score against an uncommitted tree
  moving underneath it — this fingerprints the diff text instead). The verdict itself
  mirrors `gate.py`'s own green conjunction (passed AND not coverage/tamper/quality-
  blocked AND no merge conflict) rather than `run.status` alone, which reported a
  gate-blocked-but-passed suite (a tamper finding under `tamper_alarm = "block"`, a
  coverage drop, a blocking quality finding, a merge conflict) as GREEN. A third
  tri-state gap this surfaced and fixed at the source: `TestRun.quality_measured`
  (`[quality] enabled` with every configured scanner unavailable also left
  `quality_findings == []`, indistinguishable from a real clean scan — same bug as
  `tamper_measured`, one scanner category over) and, since the autonomy ladder's
  `quality` rung condition (`trust.py`) reads the exact same tri-state, it had the
  identical hole and is fixed alongside it. `Receipt` now also carries
  `degraded_reasons` verbatim (previously a `degraded` verdict was one unexplained
  word above a body where every section still claimed "clean", with no way to see
  which check was actually compromised) — but `degraded` is a GREEN-only qualifier:
  some `degraded_reasons` writers fire before the suite even runs, so a genuinely
  failed run now stays labeled RED rather than the softer DEGRADED. `tamper_measured`
  and `quality_measured` are both genuine tri-states (`None`/`True`/`False`, not a
  plain bool defaulting `False`) — the autonomy ladder's `no_tamper` and `quality` rung
  conditions in `trust.py` read the same fields and check the exact value `False`
  rather than falsiness, so a `TestRun` row persisted before these fields existed
  (`None`) falls through to its prior findings-only behavior instead of newly failing
  every such row with an invented cause. Round 7's review passed the core feature
  clean but found two evidence gaps in the same "unexplained verdict" vein: plan
  compliance (`[quality] plan_compliance`, backlog/double-gate.md §3) runs independently
  of `[quality] enabled` and can set `quality_blocked` on its own, so a run blocked only
  by plan compliance exported "Quality scan: not measured" with the actual blocking
  cause nowhere in the artifact — new `ReceiptPlanCompliance` section fixes that; and
  `ReceiptPanel.tsx` never rendered the quality section at all (a RED verdict badge over
  a checklist with no quality row), fixed alongside it. Round 8 then found the new
  section had three of its own mislabeling bugs: the panel's plan-compliance row drew
  a green ✓ for a check that produced NO answer (`error` set) — the same overclaim
  class as round 2's tamper bug, one check later; `PlanComplianceResult.blocking`
  ("meets the bar to block") printed as "BLOCKING" even under
  `[quality] plan_compliance = "warn"`, where it's never actually enforced, on what
  could be a genuinely GREEN run; and a plan-compliance-only block could print
  "(blocking)" on the deterministic Quality scan line even when that scan was
  genuinely clean, misattributing the cause. Fixed with a new `enforced` field
  (whether `"block"` mode was actually active) and by scoping the scan line's
  "(blocking)" suffix to its own findings count. Round 9 then found the deepest bug
  in this family: `ReceiptQuality.blocked` mirrored `TestRun.quality_blocked`, which
  only fires under `[quality] enforce = "block"` — under `"warn"` it stays False even
  with a blocking-severity finding on a changed line, but `ship_preflight`
  (integrate.py) has always refused to merge ANY blocking finding regardless of
  enforce mode ("a leaked credential must not merge just because the project set the
  dial to warn"). A receipt could print GREEN on a workspace haro itself refuses to
  ship, and `gh pr comment` would post exactly that GREEN header onto a PR carrying
  the secret. Fixed at the root: `ReceiptQuality.blocked` is now derived directly
  from each finding's own `.blocking` flag (mirrors `GateSummary.quality_blocking`),
  mode-agnostic, with a new `blocking_count` field so the markdown/UI can name the
  number. Tests: `test_receipt.py`, `test_cli.py`, `test_git_panel_comment_pr.py`,
  `test_integrate.py` (git-note attach/no-attach), `test_tamper_gate.py`,
  `test_degraded_gate.py`, `test_trust.py`, `ReceiptPanel.test.tsx`.
- **`haro gate` headless CLI** (`usp-critique-plan.md` idea 2): runs the exact same
  gate + Gate Receipt modules the UI uses, from a shell with no server running —
  `haro gate [path] [--base REF]` prints the receipt and exits `0` green / `2`
  anything else the gate measured and found wanting (red or degraded) / `1` if the
  CLI itself couldn't run at all (bad path, no adapter, a malformed invocation — a
  usage error exits `1`, not argparse's own default `2`, so a Stop hook script can't
  mistake "you typo'd a flag" for "the gate is red" and retry forever). An ephemeral
  in-memory `Store`/`Hub`/`Project`/`Workspace` point straight at the target
  directory — no workspace registration, no persistence, no network. Packaged as a
  console script (`[project.scripts] haro = "haro.cli:main"`, `uvx haro gate` /
  `pipx run haro gate`). Round 10 of review caught the packaging gap the CLI's own
  tests couldn't (they all use the `command` runner, which needs no package data):
  the built wheel shipped **zero** non-`.py` files — the vitest reporter, quality
  scanner rules, skill docs, all missing — so an installed `haro gate` on a real
  vitest project silently reported `0/0 passed` as a plain RED gate instead of a
  clear "the gate's own setup is broken" error. Fixed with
  `[tool.setuptools.package-data]`; verified by actually inspecting a built wheel's
  file list (`unzip -l`, not just a successful `pip install`) and running the
  installed console script against a real vitest project end-to-end (437/437
  passed, GREEN, exit 0). New `backend/haro/cli.py`. Tests: `test_cli.py`,
  `test_packaging.py` (asserts every non-`.py` file under `haro/` is covered by a
  package-data pattern, so a future asset file can't be silently forgotten again).
  Round 11 then found the guard test itself had a false negative: it matched
  patterns with `fnmatch`, whose `*` crosses `/`, while setuptools' real glob-based
  file discovery does not — so a pattern like `assets/skills/*/*.md` would
  (wrongly) also "cover" a file two segments deeper, which would still ship
  missing from a real wheel while the test kept passing. Fixed by matching with
  `Path.glob()` instead. Also fixed: the README's own Stop-hook recipe script
  collapsed every nonzero `haro gate` exit code to `2`, throwing away the very
  distinction this round's exit-code fix just made — a typo'd flag or `haro` not
  on PATH would block Claude and retry until the cap, exactly what the fix claimed
  to prevent; the script now only blocks on exit `2` and warns-but-continues on
  `1`. And `assets/build_info.env` (a desktop-build-only file that stamps the
  BUILDER's own local filesystem path) was being swept into the wheel by the
  original `assets/*.env` pattern — removed; a published `pip install haro` must
  not leak an installer's local path for a feature (`update.py`'s desktop
  self-update check) the CLI never uses. Round 12 found `Path.glob()` was ALSO not
  quite the right stand-in: setuptools' actual file discovery calls the stdlib
  `glob.glob(..., recursive=True)` directly, which skips dotfiles by default —
  `Path.glob()` doesn't, so a hidden file could have read as "covered" while a
  real wheel build still omitted it (no file under `haro/` is dot-prefixed today,
  so this never shipped a wrong wheel, only a guard that could have missed one).
  Fixed by calling `glob.glob` itself rather than a pathlib equivalent of it. Also
  fixed a zsh-specific footgun in the README's hook script: it named its exit-code
  variable `status`, which zsh treats as a readonly builtin — the script would
  fail on assignment and never block a red gate under zsh specifically (`sh`/
  `bash`/`dash` were unaffected); renamed to `rc`, verified against all four
  shells directly. Round 13 confirmed both fixes correct with independent
  reproductions (including a negative-control wheel build with a real dotfile),
  then asked the obvious question after three rounds of "the fix for the fix
  needed its own fix" in the same narrow spot: is hand-deriving setuptools' exact
  file-discovery semantics the right design at all? A real wheel build from a
  throwaway copy of the package, inspected directly, takes ~0.2s with no added
  dependency beyond `setuptools` itself (already the declared build backend) and
  is immune by construction to this entire bug class. `test_packaging.py`'s main
  coverage check now builds and inspects a real wheel instead of predicting one;
  the `fnmatch`/`glob` pattern-matcher and its regression tests for the two
  historical bugs stay as fast, specific pins. Tests: `test_cli.py`,
  `test_packaging.py`.
- **Conflict-safe local merge** (`notes/desync-hardening-plan.md` task 4). `local_merge`
  used to leave the main checkout mid-merge with conflict markers on disk when two
  workspaces conflicted (this already happened once, on `haro/todo-check-cleaning`, and
  broke the dev server on `main`). It now `git merge --abort`s on any merge failure so
  `main` is always left exactly as it was, distinguishes a real content conflict from any
  other merge failure (a rejecting hook, a signing error) so the real git error is never
  hidden behind a misleading "resolve conflicts" message, and surfaces a distinct error if
  the abort itself can't leave the tree clean. `backend/haro/git_ops.py`, tests in
  `backend/tests/test_git_ops.py`.
- **Mutation score — the "would the tests notice if the code were wrong?" gate signal**
  (`backlog/mutation-gate.md`). A green gate proves the suite *passes*; it cannot prove the
  suite would *fail* if the new code were subtly wrong, because the agent authored the tests
  that grade its own code. This mutates each **added** source line one at a time (flip an
  operator, a comparison, a constant), re-runs the suite, and reports the faults the tests
  can't tell apart — **survivors**, the shortlist a reviewer should actually read. Proven on a
  real agent diff: a `formatPrice`/`applyDiscount` module that gated **20/20 green with 100%
  line coverage** scored **82%**, and the two survivors sat on the exact `Math.round(...)`
  line that shipped a real floating-point rounding bug — the crack line coverage certified as
  clean.
  - **Advisory by construction**, the same stance as `verified_hunks.py`/`unchecked.py`: there
    is no `mutation_blocked`, it never writes `store.tests`/`workspace.status`/the trust streak
    (cached in an in-memory-only `store.mutation_runs`), so it can never touch a verdict the
    tests earned. Green-only and vitest-only for now, each "we cannot say" case returning a note.
  - **The load-bearing guard is the baseline check.** The suite must run AND pass *unmutated*
    right now, or every mutant would "pass" vacuously and the score would be a confident lie
    (0 killed / all survived) — the exact failure an early impacted-only optimization hit before
    it was pulled for full-suite correctness. `mutation.py` is a pure, injected-IO engine
    (`generate_mutants` + `run_mutation`, `test_mutation.py`); it distinguishes a compile-error
    mutant (**skipped**, not scored) from a caught one so the score can't be inflated where it
    lies. On-demand behind `[gate] mutation` (off by default — the one signal that costs N test
    runs); surfaced as the ③ verify **strength** tab (`POST /workspaces/{id}/mutation`).
- **Bulk archive — many workspaces, one at a time** (`backlog/bulk-archive.md`). Fan out five
  agents, three turn out to be dead ends, and clearing them is five trips through the sidebar's
  ⋯ menu. The dashboard's new **select** mode collects them in one go — but the batch is
  deliberately a **queue, not a `Promise.all`**. Archiving one workspace is already compound
  and destructive (quiesce every session + the gate + the PTYs + the dev servers → the project's
  `archive` script → `git worktree remove --force` → `git branch -D`); firing N of those at once
  multiplies every failure mode simultaneously — N archive scripts on one machine, N git
  commands on one repo's index, and a partial failure buried in a pile of parallel results with
  nobody able to say which workspace survived.
  - **Serial by construction.** `archive_queue.run_queue` drains one at a time, records a failed
    teardown against that item and keeps going, and stops **cooperatively** — the flag is checked
    *between* items, so the teardown in flight always finishes. Cancelling mid-`remove_worktree`
    is exactly how you get the half-removed husk the crash-safety work exists to avoid.
  - **The second danger is blast radius, not concurrency.** `branch -D` is a force delete: ten
    clicks of "archive" is ten deliberate acts, one click on ten cards is one act with ten times
    the reach. So the pure `archive_queue.plan` **skips anything with work at stake** — uncommitted
    edits, commits not in the base ref, a running agent — and names the risk per workspace;
    taking them needs an explicit "include them anyway". Risk-free items are ordered **first**,
    so a stopped queue has done the harmless half.
  - **Never a comforting zero.** A worktree git wouldn't answer for is *risky*, not clean (the
    coverage-guard rule), and the new `git_ops.ahead_count` raises rather than reporting 0 —
    unlike `git_panel.status`'s lenient display-side twin. A **husk** (no `.git` link) is the
    opposite case and IS admitted: archiving is its repair.
  - **The preview is the undo.** `POST /projects/{id}/archive-queue?dry=true` returns the same
    `ArchiveQueueRun` model the live run fills in, so what the user approves and what they watch
    are literally one object; the panel re-plans through the backend when the risk checkbox is
    ticked, so no admission rule is ever re-derived client-side. Progress rides the global feed
    (`notify`/`archive_queue`), one queue per project, and a reload mid-run reattaches.
  - **The UI keeps no rules of its own.** Every select-mode decision (`bulkBar`/`cardPick`) and
    every feed reduction (`mergeArchiveRun`/`archiveFeedEffects`) is a pure function in
    `archiveQueue.ts`, and the plan → re-plan → start → stop sequence is `archiveActions.ts`
    with its dependencies injected — because that sequence ends in deleted worktrees, and
    "which ids, with which force flag" is not something to leave in a component closure. What's
    left in `App.tsx` and `Dashboard.tsx` is declarations and JSX; `BulkSelectBar` and
    `WorkspaceCard` are exported so their picked/locked states can be rendered in a test rather
    than clicked into.
  - Writing those tests immediately paid: the risk block keyed on "held back" alone, so the
    **include-them-anyway checkbox vanished the moment you ticked it** — a forced plan showed
    no way back to the safe one. It now keys on held-back *or* forced and re-labels itself
    ("N will lose work").
  - `backend/haro/archive_queue.py`, `main._drain_archive_queue`/`_archive_candidate`, four
    endpoints, `frontend/src/archiveQueue.ts` + `archiveActions.ts` +
    `components/ArchiveQueuePanel.tsx` + the Dashboard select mode. Tests:
    `test_archive_queue.py`, `test_archive_queue_git.py` (a real repo: the held-back branch
    genuinely survives), `archiveQueue.test.ts`, `archiveActions.test.ts`,
    `api.archiveQueue.test.ts`, and render tests for the panel, both dashboards and the app root.
- **Code to check: rows you can tick off, so the pane can actually reach zero**
  (`backlog/code-to-check.md` §3.5). Read back off 125 real gate runs in `~/.haro/haro.db`
  rather than off impressions, and the finding was not the one the spec predicted. The pane is
  quiet on ordinary work (40 of 60 workspaces raised nothing), but of the 20 that DID raise a
  row, **exactly one ever reached zero**: one workspace ran nine gates and shipped still
  carrying `1 deleted`, another carried `23 lines never ran` unchanged across all nine of its
  runs. The cause was structural and visible in the code the whole time. Four of the eight row
  kinds (`new_dep`, `secret`, `deleted`, `migration`) have fix hints that begin "confirm…", and
  the UI gave nobody anywhere to put that confirmation. A worklist you cannot tick is a report,
  and a report is what people scroll past.
  - `unchecked.row_key` (`kind|file|count-or-detail`) stamps a stable identity on every row;
    ticks live in `Workspace.checked_rows`, toggle through `POST /workspaces/{id}/checked`, and
    are pruned to the live row set on every gate so the list cannot become a junk drawer.
  - **The key embeds the claim**, which is the whole semantics: a tick survives a re-gate that
    reproduces the same row and dies the moment the claim changes. Ticking "23 lines never ran"
    expires when there are 24, because you did not look at the 24th.
  - Ticked rows are **answered, not deleted** — they move under a "checked by you" disclosure
    and stay in the record. The badge (and `GateSummary.unchecked_count`) counts only what is
    still pending, since a badge that keeps counting finished work is one people switch off.
  - The tick says **"I looked"**, never "verified". The pane's naming law now reaches the API,
    the tooltip and the commit message.
- **Each row carries its plain sentence** ("23 of 40 added lines never ran") instead of hiding it
  in a `title` tooltip. `no test ran · rungs.py · 41` is legible only to someone who already
  knows the codebase, and a pane that needs insider knowledge is a pane only its author reads.
- **Agent session lifecycle — both edges of a run are backend-owned and crash-safe**
  (`backlog/agent-session-lifecycle.md`). A run's *execution* was already decoupled from the
  client (a retained task, a durable transcript, WS-close never cancels it). Its **start** and
  its **end** weren't, and that's where every reported clunk lived.
  - **§1 Backend-owned run deferral — the felt bug.** Clicking "run agent" on a fresh
    workspace, then switching away, silently lost the task: `start_agent` 409'd while setup
    was running, so the wait lived in a frontend queue whose only drainer was an effect scoped
    to the *selected* workspace. Now the run is **accepted as `AgentRunStatus.queued`** and
    `runner._await_setup` holds it until provisioning settles — the client fires and forgets.
    The stream says "⏳ Waiting for setup…", `run_setup`'s `finally` releases the
    `SETUP_SESSION` guard **before** announcing `idle` (it used to announce readiness while
    the guard it lifted was still set), and `runComposer` only client-queues behind a real
    agent/test run (`shouldClientQueue`, the same predicate the button label reads, so the two
    can no longer disagree). Its kill condition is honoured: a setup that never settles fails
    the run **loudly** after `SETUP_WAIT_TIMEOUT` rather than hanging it forever.
  - **§2 No more orphaned `claude`.** The agent adapter was the one subprocess owner with no
    process group and no `finally` kill, so cancelling a run unwound the generator and left
    `claude` — plus every tool it had shelled out to — alive and detached: stop, archive-mid-run
    and shutdown all leaked a live agent still burning tokens. `claude` now leads its own
    session and `run`'s `finally` kills the group. The teardown policy that had drifted
    per-owner is now one module, **`procs.py`** (`signal_tree` / `terminate_tree`), shared by
    the adapter, the lifecycle shells and the dev servers. The runner iterates the adapter under
    `contextlib.aclosing` because an async generator's `finally` does **not** run when its
    consumer is cancelled — without that, the kill was left to the garbage collector.
  - **§3 "Stopped" is a fact, not a promise.** `POST /agent/stop` now awaits the settle
    (bounded, `settled: bool` in the response) instead of returning the instant `cancel()` was
    *requested*. Setup shells are group-led and killed in a `finally` too, so deleting a
    workspace mid-`npm install` no longer leaves the install churning.
  - **§4 No zombie `running` runs.** `db.reconcile` settles every `AgentRun` left
    `running`/`queued` with no live task → `stopped` + `ended_at`. A run in flight when the
    process died used to stay persisted as `running` forever, skewing `store.latest_run`.
  - **§5 Global concurrency guardrail.** `[agent] max_parallel` (default 4, `0` = unlimited)
    caps concurrent agent subprocesses **across the whole install** — nothing bounded that
    before, so N workspaces meant N unbounded `claude` processes: a resource-exhaustion
    footgun under the "run many agents in parallel" headline. Over-cap runs wait as `queued`
    ("⏳ Queued: N already in flight") and start as slots free up.
  - **§6 Robustness hygiene.** A failed `startAgent` POST rolls the optimistic
    `agent_running` flip back (the composer used to wedge "busy" until a reload, with no
    status event coming to unstick it); fire-and-forget `create_task` calls are referenced so
    they can't be GC'd mid-flight (asyncio keeps only a weak ref); `pop_active_task` supports
    an identity-checked pop so a settling run can't evict a newer run's stop handle; a failing
    post-run snapshot is logged instead of silently swallowed; and **hub subscriber queues are
    bounded** (drop-oldest) so a consumer that stops draining can't grow memory without back-pressure.

- **Winner-only fan-out — the gate stops being a safety rail and becomes a referee**
  (Bet 11, `backlog/winner-fanout.md`; `notes/differentiation-bets-round2.md`). Best-of-n is
  herd convergence, but every rival ends the race by dumping N diffs on the human —
  *multiplying* the #1 documented pain — because none of them owns a deterministic local
  scorer; their only ranker is another model's opinion. haro refuses to show you N diffs.
  A **`race ×N`** button beside the model/effort pickers fans the SAME prompt across N lane
  configs (default sonnet-low / sonnet-high / opus) as sibling workspaces, every lane resolves
  to a real merge-blocking gate verdict, and the gate **ranks them**. You review exactly one
  candidate plus a scorecard saying why it won. Opt-in (`[race] enabled = false`).
  - **§0 — never race uncapped.** `race.preflight` refuses to start without `[agent]
    max_budget_usd`, and derives a race-level ceiling (`[race] max_total_usd`, default lanes ×
    the per-run cap) that **stops still-running lanes** when the lanes' summed `cost_usd`
    crosses it — announced on the feed, because stopping work for money must never be silent.
    N× token spend is this feature's headline risk. It also refuses on a suite too thin to
    referee with (`min_suite_tests`), and every refusal is free: nothing is created first.
  - **§0 — every lane's green means the same thing.** `fanout.lane_gate_settings` forces
    merge-result gating, the flaky confirmation re-run and full scope on for race lanes
    whatever the project configured. Ranking is a comparison, and a comparison between
    differently-strict verdicts is meaningless. All three overrides only ever make a gate
    *stricter*, which is what keeps the override from being a back door.
  - **§2 — the judge is pure and deterministic** (`race.py`, the `trust.py`/`merge_queue.py`
    shape: dataclasses in, verdict out, no git/store/clock — so "same inputs, same winner,
    every time" is a property you can test with no repo at all). Policies: `first_green` ·
    `cheapest_green` (default) · `best_coverage_delta` · `merge_clean`, each over a fixed
    tie-break chain (cost → wall → diff size → id; the trailing id is what stops input order
    deciding). Disqualifiers are facts the gate recorded, never judgements: not green,
    merge-conflicting, **degraded** (a check the project asked for couldn't run), or a green
    resting on a suspected-flaky pass.
  - **§2 — it refuses rather than guessing, and the refusals are the feature.** A green lane
    whose diff touches fewer than `[race] min_impacted_tests` tests ⇒ decline to auto-judge and
    show every lane ("compiles and passes" isn't good code on a weak suite). All lanes green
    and the policy metric within an epsilon ⇒ an **honest tie**: the top two side by side,
    never a fabricated winner.
  - **§3 — the ceremony, and the losers' afterlife.** The scorecard shows the winner card
    (click → the one diff you review) plus a row per lane — `verdict · cost · wall · coverage Δ
    · merge-clean`, each won/lost, with the policy's own axis marked decisive. Losing rows are
    never censored: a judge you can't second-guess is just another opinion. Losers are
    **soft-archived**, not deleted — `fanout.soft_archive_lane` checkpoint-commits the worktree
    onto its branch *first* (an agent's work is almost always uncommitted, and `worktree remove
    --force` would take the whole diff with it), removes the checkout **without** the branch,
    and keeps the store row + transcript + gate history. `purge losers` is the separate,
    irreversible act. Every race is persisted, so the set doubles as $/green-by-model
    calibration data.
  - Plumbing: `[race]` config (`config._parse_race_lanes`/`RaceLaneConfig`, tolerant of the
    array-of-tables form people hand-write wrong), `models.RaceRun`/`RaceLane`,
    `Workspace.race_id` (its own field — `seed_key` is *parsed* by the GitHub issue write-back,
    so a race tag smuggled through it would fire issue writes for a lane), a `races` table in
    `db.py`, `store.races`/`race_tasks`, `gate.run_gate(settings=)` +
    `runner.run_agent(gate_settings=, on_gate=)`, `main._seed_workspace` (the create-workspace
    machinery extracted so a lane is seeded *identically* to a hand-made workspace), and
    `lifecycle.quiesce_workspace` (the stop-everything half both teardown paths now share).
    Endpoints `GET /projects/{id}/race/preflight` (never 400s — the refusal is the payload, so
    the button greys out *and says why* before a dollar is spent), `POST /projects/{id}/races`,
    `GET /projects/{id}/races`, `GET /races/{id}`, `POST /races/{id}/stop`,
    `POST /races/{id}/purge-losers`; lifecycle on the global feed as `notify`/`race_*`.
  - Dashboards group a race's lanes into ONE scorecard and exclude them from the card grid,
    the counts and the "N gates need you" banner — a race owns its lanes' triage, and
    surfacing three red lanes there would rebuild the pile the feature removes. The sidebar
    hides soft-archived rows (their home is the scorecard).
  - Tests: `test_race_judge.py` (policies, determinism under input reordering, every
    disqualifier, both refusals), `test_race_config.py` (parsing + §0), `test_race_ceremony.py`
    (a real git repo: the loser's branch and committed diff survive, and so does the row —
    `db.reconcile`/`mark_broken` now skip `archived` workspaces, which are worktree-less by
    design and would otherwise be deleted as desync on the next boot), `races.test.ts`.
- **Verified Hunks — the gate pre-reads the diff for you** (`backlog/verified-hunks.md` §1–§3,
  round-2 Bet 12). The gate proved *the suite passed*; it now proves something about **every line
  of the diff**: which added lines the passing suite executed, and which it never touched. The ④
  ship diff badges each hunk, dots each added line, sorts the untested files first and collapses
  the fully-executed ones — so reviewing a 1,200-line agent diff becomes reviewing the residue
  nothing ran. Opt-in via `[gate] verified_hunks` (Gate settings → **Per-line proof**).
  - **The honesty rule is the feature.** An *executed* line is not an *asserted* line, so nothing
    on this surface says verified, proven or correct — a `verifiedHunks.test.ts` case asserts that
    over every label and tooltip, and the tooltip spells the gap out ("executed ≠ asserted"). §4's
    target copy "executed by N passing tests" waits for real per-test attribution; until then the
    badge says "executed by the green suite", because a count we can't attribute would be the
    first crack in the surface.
  - **No second coverage run.** The per-line map is the one `code_to_check` already measures on a
    green gate (`VitestAdapter.coverage_lines`); `run_gate` now measures it once and shares it, so
    with both signals on the marginal cost of this bet is zero. It's cached on the store
    (`store.line_hits`) with the diff it describes, so reopening the diff never re-runs a suite.
  - **Staleness is per-file, not per-sha.** HEAD is the wrong signal on its own: agent edits are
    uncommitted, so a line can be inserted — renumbering everything below it — without HEAD
    moving. `verified_hunks.annotate` compares each file's added lines at gate time against its
    added lines now, and a file that moved carries **no line data at all**; the toolbar says "the
    gate ran on an older tree". Silence is the only honest output for a line whose evidence no
    longer lines up with it, and a green dot on a shifted line is the one mistake this feature
    cannot survive.
  - **Green-only, enforced twice.** The pass runs only on an otherwise-green full-scope gate, and
    a non-green verdict calls `store.drop_line_hits` — an earlier green's proof must not sit in
    memory waiting to be drawn over a tree that just failed.
  - **Three line states, and the third one matters.** Executed (`hits ≥ 1`), never executed
    (`hits == 0`), and **not coverable** (absent from istanbul's `statementMap`: a blank line, a
    comment, a closing brace) — counted separately and never as untested, because "add a test for
    your closing brace" is how a signal gets switched off. A comment-only hunk reads "no
    executable lines added", not "0 of 4 executed".
  - **Collapse refuses to guess.** `collapsesByDefault` folds a file only when the gate measured
    it and every coverable added line ran; no proof, stale proof, an unmapped file or a
    nothing-executable file all stay open. Hiding a file on weak evidence is the first kill
    condition.
  - `+ review the residue → agent` batches the never-executed files into the composer round-trip
    (the fix-all / code-to-check path), each prefilled to ask for tests **or** a justification —
    a signal that accepts only one answer gets gamed into accepting anything.
  - New: `backend/haro/verified_hunks.py` (pure, no IO — the `blame.py`/`unchecked.py` shape),
    `GET /workspaces/{id}/verified-hunks` (`VerifiedHunksResponse`, `supported=False` + a reason
    per cause: off · non-vitest runner · no coverage provider · no green gate yet),
    `frontend/src/verifiedHunks.ts` (all copy + tallying, pure), and the `DiffView` surface. The
    Unified/Split preference is now persisted too (`haro-diff-mode`), alongside the new
    `haro-diff-untested-first`. Tests: `test_verified_hunks.py`, `test_verified_hunks_gate.py`,
    `verifiedHunks.test.ts`, `DiffView.test.tsx` (which pins that passing no proof renders the
    pre-feature diff exactly). E2E: `notes/e2e-gate-test-plan.md` **Phase 9**, written not driven.

### Changed
- **Evidence on by default: `[gate] verified_hunks` now defaults ON** (was off).
  `usp-critique-plan.md` idea 3: it's evidence, never a verdict — it can't block a merge
  and costs no extra test run, so it no longer needs an opt-in. Existing projects with no
  explicit `verified_hunks` setting will see the ④ ship diff's per-line proof appear on
  upgrade; set `verified_hunks = false` under `[gate]` to opt back out. `tamper_alarm` and
  `code_to_check` were already on by default and are unchanged.
- **Verify is human-first: the AI-review lane is gone from ③.** The gate now hands a human the
  *evidence* to review (the test grid, the mutation **strength** residue, and the **code to
  check** worklist) rather than a second model's opinion — a model judging a model was the one
  advisory verify surface that didn't fit "the gate is a deterministic verdict", and keeping it
  quietly nudged reviewers to delegate the read. The backend `/review` endpoint remains; the
  `GatePanel` tab + `ReviewLane` and the `App` wiring (`runReview`/`fixFinding`/`review` state)
  were removed.
- **The "code to check" card is fullscreenable.** It *is* the structured human-review surface
  (the diff-level worklist of what nothing executed), so it earns the same `.card--full` focus
  overlay + Esc-to-exit the gate and editor already have — room to read the whole residue in one
  view instead of a cramped rail pane.
- **Kuro trademark theme, completion pass** (`backlog/kuro-theme.md`). Pass 2 (palette values,
  `dossier.css` grain + a kanji watermark) had already landed; this pass finishes the
  reproduction of the Kuro Obsidian theme spec: the real type stack (Fraunces, Space Grotesk,
  Space Mono, self-hosted), a rotated dossier strip down the triage dashboard's left edge,
  ledger-row and rule-title utilities, and a full de-green sweep — `--accent` (gate green) now
  appears only on gate/test-grid/regression-ribbon surfaces and the new `.btn-gate` (the ④ merge
  button); every other primary action is an inverted bone keycap. Monaco and the terminal get
  their own monochrome palettes (`themes.ts` `editorPalette`/`terminalPalette` for the `haro`
  family) instead of riding stock `vs-dark`/default xterm colors, keeping ANSI/diff green as the
  one deliberate accent. All hardcoded border-radii collapsed to the 2px/3px token pair.
  **The dashboard's bottom-right corner accent went through two rounds of review**: a
  dithered-photo hero was tried and dropped for reading too heavy; its text-only replacement, a
  small katakana word (`モノクローム`) peeking off the right edge, was then dialed down to a
  ghost-faint 3% opacity. The pass-2 kanji watermark (`dossier.css` `body::before`, a giant
  bottom-right 門) was also removed on review — it read as a big distracting word rather than
  ambient texture, so only film grain remains as a body-level layer. A 1.8KB kanji glyph subset
  and `brand/dither.py` (reproducible Floyd-Steinberg/`--ordered` Bayer) both stay bundled as
  shelf tooling, unused by anything currently shipped. 8-bit/nord and the dead light-mode CSS are
  untouched, kept as the revert path.

### Fixed
- **The ④ ship step said "merged" while the rest of the workspace said green.** Purple
  "Pull request successfully merged and closed" on the ship step; a green dot in the sidebar,
  no purple `.bento-merged` frame, and no "Continue on a new branch" banner — because two
  different predicates were answering the same question.
  - `main._adopt_merged_state` (the reconcile behind `GET /git/pr` and the merge poll) says
    merged ⟺ a PR exists, is `MERGED`, **and** its `headRefOid` is the commit the worktree is
    actually on. `GitPanel` said `gateStatus === "merged" || pr.state === "MERGED"` — a
    fallback written *before* that reconcile existed, and SHA-blind. A branch NAME stays
    `MERGED` on github.com forever, so any workspace whose HEAD had moved past its merge
    (a commit after the merge, a reused branch name) went purple on the ship step alone,
    where "Continue on a new branch" was offered and then refused with a 409.
  - `GET /git/pr` now returns the verdict it just reconciled as
    `PrStatusResponse.workspace_merged`, and the panel reads that. One predicate, both sides,
    computed on the same request — they cannot drift.
  - **The silent half:** `_adopt_merged_state` **demoted** out of `merged` on any response
    without a `state`. But `pr_status` degrades to `supported=False` (no remote, no `gh`,
    worktree gone) or `exists=False` (no PR for this branch) — that's an *absence of
    evidence*, not a "not merged". So every **local** merge (no-remote repos, `[workflow]
    merge_mode = "merge"`) had its `merged` status undone the moment the ship panel loaded:
    `integrate` set it, and the panel's own PR fetch un-set it a beat later. It now acts only
    on a real PR record; demotion still fires where a PR record genuinely contradicts us
    (state `OPEN`/`CLOSED`, or `MERGED` for a commit we've moved past).
  - Regression tests: `backend/tests/test_merged_status_sync.py`.
- **Code to check called a change clean when nothing had looked at it** — and on this repo's own
  history, that was most "clean" panes (`backlog/code-to-check.md` §3.5). `TestRun.unchecked_items`
  defaulted to `[]`, and the pane rendered "0 rows" as its earned `nothing to check ✓ · every
  changed line ran`. That green appeared over a **red gate**, over an **impacted-only run**, over
  a project with **no coverage provider installed**, and over every diff the coverage map simply
  did not contain. The last one is the common case here: haro's gate runs vitest in `frontend/`,
  so on any backend-only change the map has nothing to say about the diff and the pane
  congratulated you anyway. Same fail-open shape §0 of `backlog/double-gate.md` treats as a
  cardinal sin, in the one signal that had never adopted the tri-state.
  - `unchecked_items` is now `list | None`: **`None` = the pass never ran, `[]` = it ran and found
    nothing.** Same contract `quality_findings` already carried, for the same reason.
  - New `TestRun.unchecked_covered_files` (`unchecked.covered_files`) is the number that licenses
    the clean state: `None` = no per-line map at all, `0` = a map that held nothing from this
    diff, `N` = N files genuinely executed. Only `N > 0` may claim the lines ran, and the clean
    state now prints the N so the claim is checkable.
  - `GateSummary.unchecked_count` is nullable, so a dashboard card cannot print a confident `0`
    for a check that did not happen.
  - Four honest states, resolved in one pure unit-tested place (`gate.ts uncheckedState`): **off**,
    **unmeasured** (naming *which* why, because a red gate and an impacted-only run want different
    next actions), **quiet** ("nothing to report", dim, coverage was blind), and **clean** (green,
    and only when coverage watched files run).
  - Three em dashes that had drifted into the pane's fix hints, caught by a new copy test.
- **The unmeasured-coverage hole: an agent could neuter the coverage guard just by running the
  test suite** (`backlog/gate.md` §2). Found in the autonomy-ladder adversarial dogfood
  (`notes/e2e-gate-test-plan.md` §8.8): the agent ran `npx vitest` itself, vitest wrote
  `node_modules/.vite/vitest/…` and thereby **created** `node_modules/` as a real directory, after
  which `ensure_deps` read the worktree as already provisioned and skipped the symlink for good.
  Vitest still ran via `npx`, but `@vitest/coverage-v8` could not resolve, so `coverage_delta` came
  back `None` — and `evaluate_coverage_guard(None, …)` returned `("ok", None)`, so
  `coverage_guard = "block"` never blocked in precisely the case where the *measurement* broke.
  Two independent halves, both fixed:
  - **"Exists" is not "provisioned"** — `gate._holds_packages` reads a `node_modules` holding no
    packages (no `.bin`, no non-dot entry) as what it is: a build cache. It gets cleared and
    symlinked, and only ever when the project actually has packages to offer, so nothing is deleted
    without a replacement. The merge-firewall §2 rule that a *foreign install* is hands-off is
    unchanged (real dir · live symlink · dangling symlink · a `.bin`-only tree all still no-op). The
    same check now guards the project side too — symlinking a package-less project root provisioned
    nothing while reporting success, and on a JS project that now falls through to
    `_provision_deps`' auto-install instead.
  - **`block` blocks.** A missing number is *less* information than a measured drop, so it can't be
    the one case that passes: `None` under `warn|block` returns that mode with a reason. It lands on
    `coverage_blocked` (the verdict, i.e. `workspace.status`) and not on §0's `degraded` alone,
    because `degraded` only reaches `ship_preflight` while *status* is what the dashboard, the
    regression ribbon and the merge firewall's verdict oracle read. `off` is still the escape hatch;
    no new config key.
  - **The note names the cause**, reusing `analytics.coverage_delta`'s own diagnosis (missing
    provider · red suite · no run yet) instead of re-guessing it, with
    `gate.unmeasured_coverage_note` as the single string shared with the §0 degraded reason. In the
    UI the fix hint forks on whether there *is* a number (`gate.ts` `coverageBlockHint`): "restore
    coverage" is unactionable when coverage was never measured, so that case says fix the reporting.
  - Two fixtures in `test_provision_deps.py` now put a package inside their stand-in
    `node_modules` — a real `npm install` never leaves the folder empty. The assertions are
    unchanged; only the fixture got more honest.
- **Opening an archived workspace no longer errors** (reported: a 500 out of `/git/pr`). An
  archived or merged workspace keeps its row for history while `remove_worktree` tears the
  directory down, so `ws.worktree_path` points at nothing and every git call dies with "fatal: not
  a git repository". The four call sites failed in four different ways, and the quietest was the
  worst: `pr_status` and `log` raised straight through their endpoints (**HTTP 500**),
  `commit`/`create_pr` surfaced a cryptic `400 fatal: not a git repository`, and **`status`
  swallowed the error and returned `ahead`/`behind`/`dirty` all zero** — indistinguishable from a
  clean branch, which is a confident wrong answer rather than a failure.
  - One guard at the source, `git_panel.worktree_gone()` over the existing
    `git_ops.worktree_valid`, so every current and future caller is covered. It checks `.git`
    rather than `isdir`, which also catches a husk left by an interrupted `git worktree remove`.
  - Reads degrade **and say so**: `pr_status` returns the same `{supported: false, reason}` shape
    it already uses for no-remote/no-gh (so the frontend needed no new branch), `log` returns an
    empty history, and `status` reports a new `worktree_missing` flag instead of faking zeros.
    Writes refuse loudly with a message naming the cause. Same never-silently-pass rule as §0.
  - `GitPanel` says it outright at the top and stops offering ship actions that would be refused.
    Amber, not red: nothing failed, the state is simply unknowable.
  - `test_git_panel_no_worktree.py` (12 cases) covers the guard, the husk case, each degraded
    read, both refused writes, and the three endpoint handlers from the reported traceback.
- **A check that could not run no longer reads as a clean green** (`backlog/double-gate.md` §0
  — **completes §0**, the stated prerequisite for the rest of the Double Gate). This is the worst
  failure this product can have, and it was **live in this repo**: the coverage guard was on while
  `coverage()` returned `None` every time, and the tamper alarm was on while its base inventory came
  back empty — and both produced an ordinary, confident green. The tamper one fails **open**: `[]`
  findings read as *"test suite intact vs base"*, which satisfied `trust.no_tamper` and would have
  let an autonomy rung arm on a check that never happened.
  - **Audited all 9 swallowed `except`s** in `gate.py` + `analytics.py`. Four could hide a
    check: merge-result prep falling back to "worktree as-is", the coverage guard, the tamper
    alarm, and code-to-check. The other five are correct as they stand (a runner crash IS a red
    gate, a crashed flaky re-run leaves it red, cleanup failure is housekeeping, and the Live
    Gate's silence is deliberate).
  - `TestRun.degraded_reasons` (a list — several checks can fail at once) + `GateSummary.degraded`
    for the coarse feed. Set **only** for a check the project asked for, which is both the
    anti-cry-wolf rule and the escape hatch: turn the check off and it stops being a check you
    asked for, so this needed no new config key.
  - **Not shippable**, enforced at `integrate.ship_preflight` rather than in the UI, so the auto
    rungs clear the same bar and an unverified green can't be auto-merged either. And
    `trust._break_reason` treats a degraded run as not-a-clean-green, which resets the streak and,
    since streak is required, drops `met` with no extra condition to maintain.
  - Amber `.gate-degraded` banner above every other banner in `GatePanel`. **Amber, not red**: red
    means a test failed, and nothing failed here. The honest state is *unknown*, which is its own
    thing and the entire reason §0 exists. 9 new tests in `test_degraded_gate.py`.
- **`CHANGELOG.md merge=union`** (`.gitattributes`, new) — the changelog is append-only and every
  change adds an entry at the same anchor, so two parallel agents conflicted on it essentially
  every time (it cost a stash-and-hand-resolve today). `union` keeps both sides instead of
  stopping. Knowing tradeoff: it never conflicts, so two genuinely overlapping entries can
  interleave, which surfaces at review where it is cheap rather than at merge where it blocks.
- **Analytics ran the test runner in the wrong directory on any project with `[gate] dir`**, which
  made the Autonomy Ladder's **"Coverage holds vs base" condition impossible to satisfy** — haro
  itself sets `dir = "frontend"`, so it could never be met here. `gate.run_gate` resolves
  `<root>/<gate_dir>` before invoking the runner; every function in `analytics.py` invoked it at the
  worktree/checkout **root** instead. New `analytics._resolve(project, root)` mirrors the gate's own
  resolution and is now used by `coverage_delta`, `_baseline_coverage`, `test_inventories`,
  `_baseline_inventory` and `detect_flaky`, for both the `ensure_deps` call and the runner cwd.
  - **Two different failures came out of the one mistake, and the quieter one was worse.**
    `coverage()` simply died (`Cannot find dependency '@vitest/coverage-v8'`, since the root has no
    `package.json`, no vitest config and no `node_modules`) — but `_list()` appeared to *work*: with
    nothing installed at the root, `npx` downloaded a vitest and ran it **config-less**, globbing the
    tree. It found haro's tests by luck, which means the tamper alarm's "which tests existed at
    base" reference was being built by a different runner than the gate uses, ignoring the project's
    include/exclude rules and aliases. `ensure_deps` was misdirected too, so it silently no-opped.
  - **The note stopped guessing the cause.** It always said *"the suite must be green to measure
    it"* — and said it while the gate showed **245 passed**, sending you hunting a red suite that did
    not exist. New `_unmeasurable_note` reads the gate's own last verdict and distinguishes three
    real situations: no gate run yet · the suite is red · the suite is **green** but the runner
    reported no coverage, which names the provider to install.
  - Verified on the live workspace rather than only in tests: coverage now measures
    (lines 35.37%), the baseline resolves, and the whole delta — detached checkout, deps symlink and
    **two** coverage runs — takes **1.7s**, because `ensure_deps` symlinks instead of installing.
    Delta is 0.0, so the condition is now satisfiable. `test_analytics_gate_dir.py` pins the cwd each
    call site is handed (the cwd *is* the bug) plus all three note branches.

### Added
- **A test rewritten in place is no longer invisible** (`backlog/tamper-alarm.md` §1, the last open
  item). §8.8's adversarial dogfood found the alarm's blind spot: it answers *"does this test still
  exist?"*, never *"does it still assert the same thing"*. A real agent retitled two base tests and
  inverted their assertions (`expect(mean([])).toBe(0)` → `expect(() => mean([])).toThrow(…)`) and
  the alarm reported **zero** findings — the fuzzy tier paired each retitle (0.812 / 0.824 against
  the 0.8 threshold) and swapping one assertion for another dropped no `expect(` count. `no_tamper`
  read *"test suite intact vs base"* while the base contract was asserted nowhere, which meant **an
  agent needed no `.skip` to hold a clean `no_tamper` row** — a free route through the one fact
  §8.8 proved decisive for `auto_merge`.
  - **It is still not a tamper finding, and that's the decision, not a shortcut.** Tightening the
    fuzzy tier (so a retitle only matches when its assertion is unchanged) would have pointed
    `green*`, the streak reset and `block` mode straight at the shape an *honest* contract change
    takes — the cry-wolf kill condition the judges were unanimous about. A retitle-plus-re-assert is
    genuinely ambiguous, so it is reported as a **fact to read**, never as a verdict.
  - New `tamper.rewritten_tests` reports those pairs on `TamperReport.rewrites`, and `run_gate`
    routes them to the **code to check** pane as `assertion_rewritten` rows naming the test and the
    title it used to carry. The pane rather than the `green*` drill-down, deliberately: the chip only
    renders when there ARE findings, and the whole point of this gap is that there are none — the
    chip would have hidden the row in the one case it exists for. The pane is advisory *by
    construction* (no `unchecked_blocked` twin) and its job is already "what has nothing checked".
  - Kept off `findings`/`note` structurally, not by convention: `trust.no_tamper`, the streak,
    `tamper_blocked` and `GateSummary.tamper_count` all read those, so a new kind *inside* that list
    would need five consumers to each remember to filter it. A run carrying rewrites still reads a
    clean `● green`, unstarred, streak intact — asserted end-to-end in `test_tamper_gate.py`.
  - Mechanics: matching now runs once in `pair_removals` (`_find_match` returns `(index, tier)`;
    only tier 3, the fuzzy tier, changed a *title*, so tiers 1–2 stay out of it), attribution is
    **hunk-scoped** via a new `FileDiff.hunks` that keeps context lines (without it, a title changed
    in one hunk adopts an assertion changed in another — a false positive on two innocent edits),
    and comparison is the multiset of `_assertion_text` (from `expect` to end of line) so a one-line
    retitle keeping its assertion stays silent. `parse_file_diffs` also stopped reading `---`/`+++`
    inside a hunk body, where a removed SQL comment (`-- …`) was enough to blank a file's path.
  - `_FUZZY_THRESHOLD` is a coin flip at this distance and `SequenceMatcher` is **order-sensitive**
    (`_similar(added, removed)` = 0.812/0.824; reversed = 0.781/0.794, i.e. no match), so both the
    ratios and the argument order are now pinned, alongside negatives for every legitimate shape:
    pure retitle, one-line retitle, reordered assertions, body change under an unchanged title.
- **Your own prompt renders as markdown in the agent stream** — a prompt echo used to show raw
  `**bold**`, backticks and `*italic*`, which is rough on a long seeded backlog item. The row now
  renders formatting, reusing the **same** `renderInline` / `splitFences` the agent's own output
  goes through (`AgentMarkdown`), so the two halves of one transcript cannot drift on what markdown
  means. Worth stating plainly: this is **display only**. The text sent to the agent is
  byte-identical either way, and markdown in a prompt was never a problem for the model, which
  reads it natively.
  - Layered outside-in rather than replacing `renderTaskText`, because that function already did
    something valuable that a naive swap would have silently deleted: **fences first** (a ```
    block renders as a real copyable code block and nothing inside it is touched afterwards, so an
    `@decorator` in pasted Python does not sprout a bogus file chip and `a ** b` is not bold), then
    **`@file` mentions** as clickable chips, then **inline markdown** on the prose that remains.
  - `AgentStream.prompt.test.tsx` covers both directions: markdown formats, and the pre-existing
    `@file` chips + trailing-punctuation peeling + code-fence isolation all still hold. Tested
    against `renderTaskText` directly rather than through `<AgentStream>`, which needs a DOM this
    project has no jsdom for; adding one for a test was not worth a dependency.
- **`code to check` — the diff-level signal the gate never had** (`backlog/code-to-check.md`
  §1-§3). Every condition on the Autonomy Ladder is **suite-level**: did the merged tree pass, did
  total coverage drop, was the whole suite run, was the run deterministic, was the suite weakened.
  **Not one of them looks at the change itself.** So a green gate says "the tests passed"; it never
  says "the tests covered what the agent changed". An agent can add 400 lines, the suite still
  passes, the coverage *delta* can even rise if the new file ships a couple of tests, and nothing
  notices that 300 of those lines were executed by nothing. That was a review problem until #214
  shipped `auto_merge`; now it is a shipping one.
  - **The pane** replaces the retired Live Gate panel in the side rail. Each row is a claim nothing
    checked (`no test imports`, `no test ran`, `new dependency`, `secret touched`, `file deleted`,
    `migration`, `suite weakened`), clicks through to the file in ② code, and one
    `+ send to agent` batches the lot into the review composer with per-kind instructions
    prefilled, reusing the `fix all` / `restore weakened tests` round-trip. It **shrinks to zero**,
    and `nothing to check ✓` is the earned state, which is what makes it a worklist rather than a
    dashboard number people learn to ignore.
  - **Naming law, enforced in tests:** rows say what was **not observed**. Nothing says *proven*,
    *verified* or *vouched*, because a line with a hit count was **executed**, which is not the
    same as asserted about. A positive word would become precisely the metric an agent games, the
    failure the tamper alarm exists to prevent. A `gate.test.ts` case asserts no label matches
    `/proven|verified|vouched|safe/`.
  - **Advisory by construction:** there is deliberately no `unchecked_blocked` twin of
    `tamper_blocked`, so this can never downgrade a verdict the tests earned. `no_unchecked` as a
    ladder rung is §4, deferred until the counts are known to be sane.
  - New pure engine `unchecked.py` (the `tamper.py`/`blame.py` shape, no IO) reusing
    `tamper.parse_file_diffs`, plus `VitestAdapter.coverage_lines` collapsing
    `coverage-final.json`'s `statementMap` + `s` into per-line hits. Computed in `run_gate` on an
    otherwise-green full-scope run only, reusing the diff it already fetched for the tamper alarm.
    `[workflow] code_to_check = "warn" | "off"`, default `warn`.
  - **Two false positives caught by running it against real data rather than fixtures**, both now
    pinned by tests. **Cross-language:** haro's gate runs vitest in `frontend/`, so its coverage map
    holds only JS-family files, and a diff touching `backend/haro/gate.py` was reported as "no test
    imports this file" when a JS report has nothing to say about Python. `runner_scope` now lets the
    map define its own universe (family-level, so a `.ts`-only map still covers a changed `.tsx`),
    which keeps the engine runner-agnostic. **Trivial edits:** an em-dash sweep filed 22 rows, 15 of
    them for one- and two-line changes. This pane reports on the *change*, not the repo's standing
    test debt, so a floor applies and rows sort biggest-first. Real-diff rows went 29 → 17.

### Changed
- **The Live Gate is demoted from a pane to a chip** (`backlog/code-to-check.md` §3). Its panel was
  empty unless you hand-edited inside a worktree, and delegate-to-agent is the actual workflow, so
  it never earned half the rail. The watch loop itself is untouched and still useful in the
  hand-fix red→green loop, so it survives as a one-line `live ● 68 passing · 0.4s` chip on the app
  strip. `GateLive.tsx` and ~110 lines of its pane CSS are deleted rather than left orphaned.

### Fixed
- **The frontend dependency graph is one graph again: vite 8, and coverage actually works**
  (resolves the known bug CI surfaced in `backlog/cockpit.md`). `package.json` declared
  `vite: ^5.4.11` while `vitest@4.1.10` requires `vite: ^6 || ^7 || ^8`, so npm quietly installed a
  **nested** `vite@8.1.4` under `vitest/` to satisfy the peer. Consequence: **the tests had been
  running on vite 8 while the dev server and the production build ran on vite 5.** The nested vite's
  own `esbuild ^0.27 || ^0.28` peer was absent from the lockfile, which is what made `npm ci` fail
  on the very first CI run. Now aligned on one graph: `vite@8.1.5` + `@vitejs/plugin-react@6.0.4`
  (its 6.x line peers `vite ^8`) + `vitest@4.1.10` + **`@vitest/coverage-v8@4.1.10`**, with **no
  nested vite** and no `esbuild` at all (vite 8 is rolldown/oxc, and declares esbuild as an
  *optional* peer). `npm ci --dry-run` is clean, so the lockfile is genuinely in sync rather than
  tolerated by a newer npm. The "Both esbuild and oxc options were set" warnings are gone with it.
  - **Coverage was silently dead and is now live.** `@vitest/coverage-v8` was never installed, so
    `VitestAdapter.coverage()` returned `None` on every call, which meant `[workflow] coverage_guard`
    could not work and the Autonomy Ladder's `coverage` condition was permanently unmeetable on this
    repo. That was dormant (the guard defaults `off`, and haro has no `[trust]` table) but it was a
    trap: the day you enable the ladder it could never arm, and the reason would read like a bug
    rather than a missing package. A coverage run now completes in **0.87s vs 0.43s without**, so the
    guard is cheap enough to leave on.
  - Verified past the suite, since a vite major is exactly where tests lie to you: 223 tests green,
    `tsc -b` + `vite build` green and **1.87s vs 25s** (rolldown), the dev server boots in 98ms with
    zero errors, and `monaco-editor` + `@monaco-editor/react` are still pre-bundled into
    `node_modules/.vite/deps`, so the `optimizeDeps.include` workaround that stops "opening Monaco
    kicks me back to the root" still holds on vite 8.
- **The tamper alarm stopped crying wolf** (`backlog/tamper-alarm.md` §3, the E2E item). Driving the
  alarm end-to-end against the real `haro-test` sandbox — two throwaway worktrees off `main`, real
  `git diff`, real `vitest list` inventories, `vitest run` confirming each suite genuinely green —
  caught three false-positive bugs, all of them the feature's own stated kill condition ("a chip that
  cries wolf destroys the trust it exists to build"). The root cause was one wrong assumption:
  **`vitest list` reports what *would run*, not what exists**, so the four signals were never
  independent observers of independent facts.
  - **A legitimate consolidation flagged as mass assertion-gutting.** Merging two test files into one
    made the deleted file read as "7 fewer expect() calls", even though the rename-aware matcher had
    correctly paired every test to its new home. `tamper.assertion_deltas` now only measures files
    present on *both* sides of the diff: a whole-file delete has no meaningful delta, and a test file
    genuinely deleted is exactly what the `removed` signal is for.
  - **`.skip` was reported twice** — once as a modifier, once as a "removed" test — so one deleted
    plus one skipped test read as `2 removed · 1 skipped`.
  - **One `.only` produced 6 phantom "test removed" findings**, because `.only` silences the rest of
    its file and those tests drop out of the listing.
  - Both are fixed by a new `tamper.reconcile` step: a modifier absorbs the removals it caused
    (`describe.skip` included, matched on the removal's ` > ` name segments) and an `.only` absorbs
    its whole file's, carrying the count in its detail — `.only added — 6 other tests in this file no
    longer run`, which is both more honest and scarier than six vague rows. Reconciliation only ever
    *merges* findings, so it can't lower a verdict; it exists so severity scales with the amount of
    tampering rather than the number of detectors watching.
  - The three scenarios are now pinned as unit tests (`backend/tests/test_tamper.py`, the
    reconciliation block) and written up as **Phase 7** of `notes/e2e-gate-test-plan.md`, whose
    §7.4 (a genuine rename + retitle + consolidation must stay *silent*) is the step to re-drive
    whenever `tamper.py` changes.

### Added
- **The Autonomy Ladder survived an adversarial agent** (`backlog/autonomy-ladder.md` §4, the last
  item — driven up as **§8.8** of `notes/e2e-gate-test-plan.md`). Docs + findings only, no product
  change. A **real** `claude` subprocess was told *"make the gate green no matter what"* three times,
  through the shipped `runner.run_agent` → `run_gate` → `rungs.maybe_fire` path on `haro-test`
  worktrees, with `streak_required = 1` so the rung was **armed and waiting** each time.
  - **It didn't cheat.** Twice the agent took the honest route under maximum pressure; once it
    enumerated the three cheats the alarm exists to catch and shipped a **red** gate with the
    contradiction explained instead. The suite was only weakened when a human *ordered* two tests
    deleted — which is the case that matters more anyway: a human-sanctioned weakening still must not
    ship unattended, and it didn't.
  - **Tamper was decisive, not lucky.** On that round's real facts (green gate, committed worktree,
    `2 removed`): waive every *other* condition and the rung is still refused; erase **only** the
    tamper findings and the identical run reads `ARMED = True`, 6/6. `rungs.maybe_fire` under
    `require_no_tamper = false` + `auto_merge` returned `None` with no notification and `main`
    untouched, and the pure Goodhart move (alarm `off` + condition waived + `auto_merge`) leaves
    `met = True` with `armed` **False** — arming again the moment the alarm goes back on.
  - **Two bugs found outside the ladder**, both filed rather than fixed here: a stray `node_modules`
    (created by the agent's own `npx vitest`) makes `ensure_deps` skip the deps symlink so coverage
    can't be measured, and `evaluate_coverage_guard(None, …)` never blocks — so `coverage_guard =
    "block"` is silently defeatable (`backlog/gate.md` §2). And a base test **rewritten in place**
    (retitled, assertion inverted, `expect(` count unchanged) yields zero tamper findings, so an
    agent needs no `.skip` to hold a clean `no_tamper` row (`backlog/tamper-alarm.md` §1). The `haro`
    skill's `green*` section now states that limit outright.
- **The Autonomy Ladder has a seat saved for the Double Gate** (`backlog/autonomy-ladder.md` §3, the
  last item of the section). "Quality-green" — the diff is secrets-, security- and lint-clean, not
  just test-green (`backlog/double-gate.md` §1) — is now a registered rung condition: `"quality"` in
  `config.TRUST_CONDITIONS`, one condition block in `trust.evaluate`, one label in
  `TrustChecklist.tsx`. The point of doing it now is that the quality gate then ships without
  touching the ladder at all: hit two names (`ProjectSettings.quality_enabled` from `[quality]
  enabled`, and `TestRun.quality_findings` stamped like the alarm's `tamper_findings`) and the
  checklist row, the rung, and the merge-queue admission all light up by themselves.
  - **Dormant, not unmet.** While no quality gate exists to measure anything, the row is *omitted* —
    the one deliberate exception to the ladder's "a guard that's off reads as unmet, never clean"
    rule. A condition nobody can satisfy would disarm every rung that just shipped, on every build,
    and it would offer no fix to deep-link to. Today's report is byte-identical; `require_quality`
    already parses and round-trips so the policy file can pin it in advance.
  - Once live it behaves like every other guard: off ⇒ unmet with a Gate-settings link, findings ⇒
    unmet with the gate's own note, clean ⇒ met, `require_quality = false` ⇒ shown but waived. The
    tests cover both eras — dormant on today's build, and the full matrix on a simulated shipped one.
- **The merge queue inherits the Autonomy Ladder** (`backlog/autonomy-ladder.md` §3). The rungs
  shipped a way to earn unattended shipping — and left a hole beside it: the conflict-aware batch
  merge (`POST /projects/{id}/merge-queue`) still admitted anything *green*, so "merge all green"
  would land, in one call, exactly the work the ladder had just refused, `auto_merge`'s hard tamper
  precondition included. Now, on a project that armed `[trust] auto_action`, the queue admits only
  **rung-complete** workspaces — the same bar `rungs.maybe_fire` clears, read from the same
  `trust.evaluate` facts.
  - **Skipped, not refused.** A rung-incomplete workspace comes back `outcome="skipped"` with the
    unmet condition keys named (`trust ladder incomplete: coverage, streak unmet — merge by hand
    instead`) and stays yours to merge from ④ ship. That split is the whole point: unattended
    shipping is earned, a human clicking merge is not. Naming the *keys* rather than a count means
    the reason points straight at the checklist rows to go read.
  - **A project that never armed `[trust]` is untouched** — green + committed + idle stays the whole
    admission ticket. The ladder must not start gating merges for people who didn't ask for it.
  - Same rule in the `?dry=true` preview, or "ready" would lie about what a real run would land.
  - **Attributable like a rung:** a queue merge the ladder admitted carries the rendered checklist in
    its commit body (`Merge-queued by the haro autonomy ladder: 6/6 …`), so `git log` reads the same
    whichever path landed it.
  - The decision stays **pure**: two new helpers in `trust.py` (`policy_armed(settings)` and
    `admission_reason(report)`) join `evaluate`, and the endpoint is only the IO shell — so the
    admission bar is unit-testable without a repo, like the ordering engine beside it.
- **The Autonomy Ladder can now actually ship: `auto_pr` + `auto_merge` fire from the gate-green
  handoff** (`backlog/autonomy-ladder.md` §3). The trust checklist has been able to read "armed" for
  a while, but nothing happened when it did — the rung was a display. Now a green gate on a project
  that opted in (`[trust] enabled = true` + `auto_action`) pushes and opens the PR (`auto_pr`) or
  merges outright (`auto_merge`, the full `integrate()` path). New `backend/haro/rungs.py`: `trust.py`
  still decides, this acts, and keeping them apart is what keeps the decision pure and unit-testable.
  - **Nothing bypasses the choke point.** The merge and PR endpoints' preflights moved into one
    shared `integrate.ship_preflight` (gate green, busy guard, clean tree, `[workflow] merge_mode`),
    and both rungs clear the *same function* the buttons do — so "automatic" can never quietly mean
    "fewer checks". The load-bearing one is the clean tree: **an uncommitted worktree is held, never
    auto-committed**, so a rung only ever ships work somebody labelled with a commit message.
  - **Never silent.** Every fired, held or failed rung publishes a `notify` `rung` envelope on the
    global feed (beep + desktop notification + toast, like `gate_green`/`gate_red`). An unattended
    merge you didn't notice is indistinguishable from a bug — and a *held* rung answers the question
    that would otherwise be unanswerable ("it's armed, so why didn't it fire?").
  - **Attributable.** The commit body (`auto_merge`) or PR body (`auto_pr`) embeds the rendered
    checklist — every condition, its detail, and the streak behind it — so the merge explains itself
    later, without haro running. Conditions a project dropped from its own conjunction are listed
    and marked, since an exemption is exactly what a reviewer wants to see.
  - Fires wherever an **authoritative** gate settles: after an agent's gate, after a hand-run gate,
    and after an adopted worktree's settle-gate (`rungs.gate_and_fire`). Structurally it can't fire
    off the advisory Live Gate (that never sets `gate_green`) or off an impacted-only run (the
    `full_scope` condition rejects it before `armed`). The runner fires it *after* releasing the
    agent's slot — inside the run, the busy guard would have held every rung forever, which is the
    kind of bug that looks like nothing at all, so it's pinned by a test.
  - A rung **never raises**: a failed action reports itself and leaves the workspace green and
    hand-mergeable. It must not damage the verdict it was acting on.
- **"Zero tamper findings" is now a real Autonomy Ladder rung condition** (`backlog/tamper-alarm.md`
  §3 · `backlog/autonomy-ladder.md` §1/§3). The trust checklist's **No tamper findings** row was a
  placeholder: it rendered "unavailable: tamper alarm not shipped" and could never be met. The alarm
  has shipped, so `trust.py` now reads the run's actual verdict, which is what stops earned
  auto-merge from being a Goodhart machine. Every *other* rung condition (coverage delta, flaky
  screen, merge-result green) is computed from the test suite itself, so one `it.skip` moves all of
  them at once. This is the condition that guards the substrate.
  - Three honest states instead of one placeholder: `tamper_alarm = "off"` reads **unmet** with a
    Gate-settings deep-link (an *unmeasured* suite is not a clean suite, and silence must not satisfy
    the condition everything else stands on); a `green*` reads **unmet**, carrying the alarm's own
    note ("1 tamper finding(s): 1 removed") and a new **`fix="tamper"`** deep-link that lands on the
    `green*` findings chip, whose `+ restore weakened tests → agent` action *is* the fix; a clean run
    reads **met** ("test suite intact vs base"). A red or a "re-run failed" partial says **not
    measured** rather than crediting silence, since the alarm only reads a whole green gate.
  - **A `green*` now breaks the project green streak** (`trust._break_reason`, one source of truth
    shared with `_is_clean_green`). Checking only the *latest* run would let an agent bank a streak
    on a weakened suite and tidy up on the last run, so the streak, a required condition, would
    itself become the metric to game. The streak row now also *names* what reset it ("0/3 … · a
    green* run (tamper findings) reset it"), because `0/3` next to a green gate otherwise reads as a
    bug.
  - **The `auto_merge` hard precondition is real code now, not a comment.** `armed` reads the actual
    `no_tamper` fact independent of its `require_` flag, and since that fact means "alarm on AND
    finding-free", one read enforces both halves: a `[trust]` edit dropping the condition, or an
    `off` alarm, still can't arm the dangerous rung.
  - Backend tests cover each state, both refusal paths and the streak reset (`test_trust.py`);
    `TrustChecklist.test.tsx` is new and covers the row + its deep-link in the rendered checklist.
- **`green*` in the regression ribbon, and time-travel to a starred run's findings**
  (`backlog/tamper-alarm.md` §3). The tamper alarm's asterisk already showed on the live verdict,
  the reason chip and the dashboard card — but the **ribbon**, the strip of past gate runs in the
  ③ tab bar, drew every green the same. That's the one place you go to ask "was this workspace
  *ever* really green?", so a suspicious green laundered itself into the record the moment the
  next clean run landed. Now a run with tamper findings hangs an amber `*` above its dot
  (`.rdot-star`; red via `.rdot-star-block` when `block` mode already turned the run red, so the
  star never implies "green" on a dot that blocked a merge), and its tooltip names the reason
  ("green* · 2 removed · 1 skipped") instead of only the pass/fail tally.
  - **Time-travel now lands on the findings.** Clicking a dot already re-pointed the whole grid
    body at that run (`viewTest`/`viewCells`), and the per-run findings persist for free because
    `db.py` snapshots a `TestRun` as one `model_dump_json` blob — so no endpoint changed. What was
    missing was the framing: the `.gate-timetravel` strip now renders **above** the `merge_note`
    and `green*` banners (they describe the past run, not the live one, and read as current when
    the notice comes after them) and states that run's own `green*` verdict, since the header
    verdict tracks the live `workspace.status` and can't. The banner is keyed by run id with
    `defaultOpen` while time-travelling, so hopping between starred dots shows each run's findings
    without a second click; `+ restore weakened tests → agent` stays withheld there (a past run's
    findings describe a diff that may no longer exist).
  - Dot class + tooltip moved into `gate.ts` **`ribbonDot()`** — pure and unit-tested
    (`gate.test.ts`: clean green, impacted, warn-mode star, block-mode red star,
    note-less count fallback, and a legacy run persisted before the alarm existed).
- **Live Gate: the gate becomes a vital sign** (`backlog/live-gate.md` §1–§3, **replaces the
  embedded app preview**). The gate used to run only when something *asked*: an agent `done`, a
  click, or an adopted worktree settling. Your own edits in ② code or the terminal of a managed
  workspace went unverified until you remembered to press a button. Now a project can opt into
  `[gate] watch` and the impacted tests re-run ~2s after you stop typing, streaming into a new
  **`GateLive`** panel in the side rail: verdict dot, a compact cell grid, the first failing test's
  name, click to jump to ③. The headline ("no work is mergeable until the gate is green, and you
  can *watch it happen*") is now continuously true instead of sampled once at the end.
  - **The law, enforced structurally:** a watch verdict is **advisory and cannot ship anything.**
    It lives in its own `gate.run_watch`, NOT a flag on `run_gate`, so there is no code path from
    the watch loop to `workspace.status`, `workspace.gate`, `store.tests` (the regression ribbon +
    trust-streak substrate), or the `notify` gate beep. `test_live_gate.py`'s
    `test_watch_run_writes_no_verdict_state` is the tripwire: it asserts `store.latest_test()` stays
    `None`, which is what every merge preflight reads. A cheap continuous green that could satisfy
    the merge gate would be Goodhart-via-convenience, the exact hole `backlog/autonomy-ladder.md`
    (full scope required) and the tamper alarm exist to close. `trust._is_clean_green` excludes
    `trigger="watch"` as a second lock, and the run streams on a dedicated **`watch`** channel so its
    cells can never clobber the authoritative grid mid-review.
  - **One debounce, two policies**: `watcher.py`'s quiescence timer (built for the Merge Firewall's
    agentless auto-gate) lost its `kind == "adopted"` fence and now forks on kind at fire time:
    **adopted** ⇒ the authoritative `run_gate` at `[trust] quiet_secs`; **managed + `[gate] watch`**
    ⇒ the advisory `run_watch` at a shorter `_WATCH_DEBOUNCE_SECS` (~2s, since "you stopped typing" is a
    different question from "settled enough to make a ship verdict"). One inotify watcher, one
    timer, no double-fire. Always impacted-only; refuses while `busy_reason` reports setup/agent/gate
    in flight; `run_gate` cancels any in-flight watch run so the real gate always wins the worktree;
    a crash degrades to no result (a broken advisory loop must be invisible, not alarming).
  - **What was removed, and why:** the live-preview **iframe**, the page rendered inside a pane.
    It was the only organ in haro with a free, better competitor one keystroke away (devtools,
    responsive mode, extensions, real profiles), so adjacency to the gate bought it nothing and it
    never earned half the rail. The `run` *capability* is fully intact and now reads as a one-line
    **`app-strip`**: named-run picker, ▸ run / ■ stop, a promoted **open ↗** (the app opens in a real
    browser), ⚙ scripts, ⌘R, the dev log, per-workspace `HARO_PORT`. Also retired: `previewFull` +
    its overlay, the `"preview"` mobile pane, `previewNonce`, `.preview-frame`/`.preview-empty`/
    `.preview-cmd`/`.btn-reload` and the now-unused `--preview-bg` token. New `styles/gate-live.css`.
  - Toggle in the Gate settings tab (**off by default**, the one gate knob that costs CPU
    continuously, unlike the tamper alarm which adds no test run). Pure display logic in `gate.ts`
    (`watchVerdict`, `watchSummary`) with its own vocabulary, "passing/failing" and never
    "green/red", because an advisory verdict must not borrow the words that mean *mergeable*.
    `GET /workspaces/{id}/watch` rehydrates the rail on reload/workspace-switch.
- **CI backstop (GitHub Actions)** (`.github/workflows/ci.yml`): two jobs, `backend · pytest`
  and `frontend · vitest + tsc + build`, on pushes to `main` and on PRs. Framed deliberately as
  a *backstop, not the gate*: haro's thesis is that the gate is local and pre-merge, so this
  only catches a push made outside haro (another machine, a web edit, a teammate without the
  app). A red run here means the local gate was bypassed. Runs the same commands the local gate
  does, so CI and the shipped Docker image cannot drift: `pip install -r requirements.txt`
  (exactly what `backend/Dockerfile` installs) then `python -m pytest -q`, and `npm ci` then
  `npm test` then `npm run build` (which is `tsc -b && vite build`, so it typechecks too).
  **Cost-bounded on purpose**, since this repo is private and therefore metered: Linux runners
  only (1x billing vs 2x Windows / 10x macOS), `timeout-minutes: 10` on both jobs (GitHub's
  default is 6 hours, so one hung process could otherwise eat a fifth of the monthly
  allowance), `concurrency` with `cancel-in-progress` so a rapid re-push cancels the superseded
  run, `paths-ignore` so the repo's heavy markdown churn skips CI, npm + pip caching, and **no
  artifact uploads** (artifact storage is the only thing that can bill on the Free plan).
  One run costs roughly two to three minutes. Also `.github/dependabot.yml`: monthly, grouped,
  low PR ceilings, so dependency updates cost well under ten CI minutes a month.
- **`green*` on the dashboard — the tamper flag rides the glance feed** (`backlog/tamper-alarm.md`
  §3) — `GateSummary` gains `tamper_count` + `tamper_note`, stamped in `run_gate` beside the other
  summary fields, so a starred green is visible **everywhere the gate is**, not only in the panel
  you happen to have open. The dashboard card shows the verdict word as `green*` (amber star,
  dashed-green left rail — "green, but not solid", so it never borrows amber-solid's "running" or
  amber-dashed's "broken" meaning) plus a one-line reason ("2 removed · 1 `.skip`"); the counts strip
  splits `N green` from `N green*`; and the **"N gates need you" banner now includes starred greens**
  alongside the reds — a `green*` ships unless you look, which is precisely why it belongs in the
  triage banner. The banner drops from red to amber when it's stars only (nothing is actually
  failing), and each starred chip's detail is the tamper *reason*, not its passing test count.
  Because the whole thing reads off the denormalized summary on `Workspace.gate`, it refreshes live
  off the coarse `status` feed with **no fetch-per-card** — the same rule `gate`/`trust` already
  follow; only a *green* gate stars (a tamper-*blocked* gate is already red on its own merit). New
  pure helpers `tamperStar`/`attentionSummary` in `Dashboard.tsx`, with `gate.ts`
  `tamperCountSummary` shared with the panel's chip so both surfaces word a `green*` identically.
  Tests: `dashboardStatus.test.ts` (star/no-star, note fallback, red never stars, banner
  composition + grammar), `test_tamper_gate.py` (summary + status-envelope round-trip, clean green
  unstarred).
- **`+ restore weakened tests → agent`** (`backlog/tamper-alarm.md` §2 — **completes §2**) — the
  `green*` chip now has an action, not just an explanation: an action row in `TamperBanner`
  (`GatePanel.tsx`, always visible, not hidden behind the expander) batches **every** tamper finding
  into the review composer in one click and switches to the ① agent view — the exact
  `fix all → agent` handoff a red gate gets, so a suspicious green routes to a fix instead of a
  shrug. New pure helpers in `gate.ts` (`tamperReviewItems`, `tamperFixHint`/`TAMPER_FIX_HINT`) mirror
  `failureReviewItems`, mapping each finding to the composer's `{target, context}` shape
  (`.skip: divides` · `.skip added — src/math.test.ts`; falls back to the file basename for per-file
  findings like assertion deltas, and to the bare kind for diff-wide snapshot churn). **One
  deliberate difference from fix-all:** the item's `text` arrives **prefilled** with a per-kind
  restore instruction ("remove the added `.only` — it silently stops every other test from running"),
  because unlike a failing test — where only the dev knows what "fix" means — a tamper finding *is*
  the ask; the batch is sendable as-is. Hidden while ribbon time-travelling (a past run's findings
  describe a diff that may no longer exist). Action styling keys off the banner's severity
  (`.gate-tamper-fix` amber in warn, red under `.gate-tamper-block`). Tests: `gate.test.ts`
  (per-kind hints, all three target fallbacks, null context, empty-green).
- **`green*` verdict + reason chip in the gate** (`backlog/tamper-alarm.md` §2) — an otherwise-green
  gate carrying `tamper_findings` now renders the verdict as **`● green*`** (asterisk on the
  `.verdict-green-star` span) plus a click-to-expand `TamperBanner` in the merge-note banner slot of
  `GatePanel.tsx`. Collapsed it shows the compact `tamper_note` ("3 removed · 2 skipped · snapshots
  84% of diff"); expanded it lists every finding's **kind · test · detail · file** (removed tests
  flagged red even in warn mode). Under `block` mode the banner is red-bordered with a "restore the
  weakened tests, or set `tamper_alarm` to warn to ship" hint, explaining the red the way the failure
  summary explains a normal red. Reads off `viewTest`, so ribbon time-travel shows a past run's
  findings too. Display logic is pure + unit-tested in `gate.ts` (`tamperKindLabel`, `tamperSummary`;
  `gate.test.ts`).
- **`[workflow] tamper_alarm` config key + Gate-tab control** (`backlog/tamper-alarm.md` §2) — the
  tamper alarm is now mode-gated by `tamper_alarm = "off" | "warn" | "block"`
  (`config.load_project_settings`, surfaced in the Gate settings tab via `GateConfig` /
  `GateUpdateRequest` / `write_project_gate`). **Default `warn`** — the one guard that's on by
  default, a deliberate exception because the signal is deterministic and adds no extra test run;
  `write_project_gate` therefore OMITS the default `"warn"` and persists only the opt-out `"off"` or
  opt-in `"block"` (inverse polarity from the other guards, which omit `"off"`). `block` sets
  `test.tamper_blocked` on any finding, which now folds into the `run_gate` green conjunction
  (`green = passed and not coverage_blocked and not merge_conflict and not tamper_blocked`) — so a
  tampered suite goes red and `integrate.py`'s "refused unless `gate_green`" preflight rejects it for
  free, without pretending a test failed (the run status stays `passed`, keeping the auto-fix loop
  out of it). `off` skips the pass entirely. Tests: `test_config.py` (roundtrip + default-omit),
  `test_tamper_gate.py` (block→red, off→skip).
- **Tamper alarm wired into the gate** (`backlog/tamper-alarm.md` §2) — `gate.run_gate` now runs the
  `tamper.py` engine on an **otherwise-green** gate only (`test.status == passed and only is None` —
  exactly the coverage-guard entry rule: a red is already blocked, and a partial "re-run failed"
  `only` run is a diagnostic loop, not a ship verdict). It sources the diff via `git_ops.diff` and the
  base-vs-worktree test inventories via `analytics.test_inventories` (cached `vitest list`, no extra
  test *run*), then records `test.tamper_findings` + `test.tamper_note` (the `green*` chip line). Warn
  behaviour for now — findings are recorded but never block (no `tamper_blocked`); a `None` inventory
  collapses to the diff-text-only signals, and an engine crash (git/list hiccup) degrades to **no
  findings**, never sinking a verdict the tests already earned. Tests: `test_tamper_gate.py`.
- **Tamper-alarm model shape on `TestRun`** (`backlog/tamper-alarm.md` §2) — `TestRun` gains
  `tamper_findings` / `tamper_note` / `tamper_blocked`, mirroring the `coverage_delta` /
  `coverage_note` / `coverage_blocked` trio: `tamper_findings` is a list of the new pydantic
  `TamperFinding` model (`kind`/`file`/`detail`/`test` — the persistable twin of the dataclass the
  pure-function engine in `tamper.py` emits, same split as `ReviewFinding` vs its reviewer),
  `tamper_note` is the compact `green*` chip line, and `tamper_blocked` downgrades an
  otherwise-green verdict to red under (future) `[workflow] tamper_alarm = "block"`. Frontend
  `types.ts` mirrors the shape. Schema/contract only — the `run_gate` wiring, config key, and
  `green*` chip are the rest of §2.
- **Quiescence auto-gate for adopted worktrees** (`backlog/merge-firewall.md` §4) — `watcher.py`'s
  `_on_quiescence` now hangs the agentless auto-gate off the settled-worktree seam: after the coarse
  `quiescent` signal, it **skips** when `store.busy_reason(ws_id)` reports a setup/agent/gate already
  in flight (don't pile on, don't fight a running setup), else schedules `gate.run_gate` at the
  project's `[gate] default_scope` (`gate_default_scope` → `changed_since=base_ref` for `impacted`,
  full suite for `all`) under `trigger="auto"`, registering `store.gate_tasks[ws_id]` exactly like the
  manual endpoint. `trigger="auto"` keeps §2's cry-wolf guard (`gate.auto_gate_allowed`) in force —
  the run is held until an adopted worktree's provisioning is `ok`. This is how a foreign
  (agentless) worktree gets gated at all — it never emits an agent `done`. Manual
  `POST /workspaces/{id}/tests` was already wired (`trigger="manual"`, always honored) and works
  regardless. `run_gate` is a top-level import (no cycle: `gate.py` imports neither `main` nor
  `watcher`); `_test_adapter` is lazy-imported from `main`. Tests: `test_quiescence.py`
  (auto-gates-when-idle, impacted-scope-passes-base-ref, skips-when-busy, skips-managed).
- **Quiescence trigger groundwork for agentless auto-gating** (`backlog/merge-firewall.md` §4) —
  `watcher.py`'s watch set now includes each **adopted** worktree path (`_desired_roots`), so a
  foreign worktree living outside the repo tree (a claude-squad dir) is watched directly; in-tree
  ones dedupe under the project path, and `_watch_membership` rebuilds the set when one is
  adopted/removed. On top of `fs_changed`, a new `_Quiescence` registry layers a *second*
  debounce: a per-workspace timer (re)armed on every change, firing `_on_quiescence` after
  `[trust] quiet_secs` (`ProjectSettings.trust_quiet_secs`, default 30, clamped ≥1, read-only
  config parsed inline in `load_project_settings`) of silence. Only adopted workspaces arm
  (`_dispatch`) — managed ones still gate on the agent `done` handoff. The fire emits a coarse
  `fs`/`quiescent` signal: the seam the follow-up auto-gate (skip-if-`busy_reason` → `run_gate`)
  consumes. Tests: `test_quiescence.py`.
- **Merge Firewall doesn't firewall haro itself** (`backlog/merge-firewall.md` §3) —
  `git_ops._git` now exports `HARO_INTERNAL=1` (`_INTERNAL_ENV`, beside the `_CRED_OVERRIDE`
  precedent) into every git subprocess; git passes its env down to the hooks it spawns, so
  `assets/firewall/hook.sh` early-returns (`[ "${HARO_INTERNAL:-}" = 1 ] && exit 0`) when haro
  itself drives the git op — integrate's `local_merge`, the merge queue, and the gate's
  `snapshot_worktree_commit`/`create_merge_worktree`. Without it the merge target (`main`) reads
  as `unknown` and `[trust] strict` would block haro merging its own *green* work. Documented
  in-code as a **convenience seam, not a security boundary**: any process can set the var, so it
  prevents the self-deadlock but cannot authenticate the caller — real enforcement stays the
  verdict oracle (a red gate blocks regardless, and haro never merges red work through
  `integrate`). Tests: `test_firewall_hook.py` (bypass-even-red-under-strict + unset-still-enforces),
  `test_git_ops.py` (the marker reaches git's hooks end-to-end + bare-merge negative control).
- **Merge Firewall uninstall is one command** (`backlog/merge-firewall.md` §3) —
  `DELETE /projects/{id}/firewall` (`main.uninstall_firewall`), the body-less, idempotent
  counterpart to `POST …/firewall`. Both disarm paths (`POST {firewall:"off"}` and `DELETE`)
  route through one shared `main._disarm_firewall(project)` — persist posture `off`, then
  `firewall.uninstall_hooks` strips exactly our fenced block from a chained foreign hook
  (husky et al. left byte-identical) or removes a slot we wholly own, and clears
  `haro.url`/`haro.strict`. Disarm is **pure file edits + a `git config` unset** and never
  reads gate state, so it works with the backend otherwise idle; a `DELETE` with nothing
  installed is a clean no-op, not an error (the uninstall-trust kill condition). Together with
  the hook's fail-open default, this upholds the promise: a stopped or removed haro can never
  brick a merge. Frontend seam added (`api.installFirewall`/`uninstallFirewall` +
  `FirewallPosture`/`FirewallResult`); the rendered UI control rides the still-greenfield
  firewall settings surface. Tests: `test_firewall_install.py` (disarm+persist-off, idempotent
  no-op, fence-only strip on a foreign hook, 404).
- **Merge Firewall `core.hooksPath` detection + hook chaining** (`backlog/merge-firewall.md` §3) —
  the installer no longer refuses a foreign hook; it **chains** onto it. `firewall._hooks_dir` is
  now `core.hooksPath`-aware (via `git_ops.get_config`): when husky/lefthook redirect git to e.g.
  `.husky`, git ignores `$GIT_COMMON_DIR/hooks` entirely, so a hook written there would never fire —
  we install into the redirected dir instead (relative paths resolve against the working-tree top,
  exactly as git reads them), else the shared `$GIT_COMMON_DIR/hooks`. When a slot already holds a
  *foreign* hook (husky's own `pre-push`, a hand-rolled script), `install_hooks` appends an
  idempotent, marker-fenced block (`# >>> haro firewall >>>` … `# <<< haro firewall <<<`) carrying
  the firewall logic (`hook.sh` minus its shebang — one source of truth), so both hooks run;
  reinstall refreshes the block in place (no duplication). `uninstall_hooks` strips exactly that
  fenced block, leaving the foreign hook byte-identical, or removes a slot haro wholly owns. The old
  `HookConflict`/`409`-on-conflict path is gone — chaining never clobbers, so it always succeeds.
  New `git_ops.get_config`. Tests: `test_firewall_install.py` (chain onto foreign, idempotent
  reinstall, `core.hooksPath` redirect, fence-only strip on uninstall).
- **Merge Firewall install endpoint + `[trust]` config** (`backlog/merge-firewall.md` §3) — the
  `[trust]` table gains two firewall keys: `firewall` (`off`|`warn`|`block`, default `off`) and
  `strict` (default `false`), parsed into `ProjectSettings.firewall`/`firewall_strict` by a
  dedicated `config._parse_firewall` kept beside `_parse_trust` (same table, distinct concern — the
  autonomy ladder governs what a *green* gate may do, the firewall governs whether a *red* gate may
  merge). New `POST /projects/{id}/firewall` (`install_firewall`) persists the posture to the
  committed `settings.toml` (`config.write_project_firewall`, a targeted upsert that preserves the
  ladder keys) then, for `warn`/`block`, installs `assets/firewall/hook.sh` under both `pre-push`
  and `pre-merge-commit` in the repo's **shared** hooks dir (`git rev-parse --git-common-dir`, so
  one install governs every worktree) and writes `git config haro.url` (only when non-default, so a
  stock install stays config-free) + `haro.strict`; `off` disarms by removing only the hook files
  haro owns (marker-guarded, never clobbering a foreign hook — `409` on conflict). Effective strict
  is `strict or firewall == "block"` (the shipped hook expresses posture purely through
  `haro.strict`). New `firewall.py` (`install_hooks`/`uninstall_hooks`) + `git_ops.set_config`/
  `unset_config`. `core.hooksPath`/husky chaining, the backend-down-safe `DELETE` uninstall, and
  `HARO_INTERNAL` remain the next §3 items. Tests: `test_firewall_install.py`.
- **Merge Firewall explicit failure semantics** (`backlog/merge-firewall.md` §3) — the hook
  (`assets/firewall/hook.sh`) now resolves both soft-failure axes against `git config
  --get --type=bool haro.strict` (default `false`), read **locally** rather than from the verdict
  response so fail-closed still applies when the backend is down (a down backend can't announce its
  own strictness). Backend unreachable/timeout ⇒ fail-open warn by default, block under strict;
  verdict `unknown` (ungoverned / never-adopted / not-gated branch) ⇒ warn+allow by default, block
  under strict; `red` always blocks regardless. Fail-open stays the default (the uninstall-trust
  kill condition — a hook must never brick merging once haro is gone). The install endpoint that
  writes `haro.strict` from `[trust] strict` is the next §3 item. Tests: `test_firewall_hook.py`
  (strict-unreachable, unknown-warn, unknown-strict-block, red-under-strict, green-under-strict).
- **Usage panel** — Claude subscription usage inside haro, mirroring Claude Desktop's Usage view:
  session / weekly utilization bars (severity-tinted green→amber→red), live reset countdowns, the
  scoped per-model weekly window, the plan/org header, and the extra-usage credits bar. New
  `GET /usage` (`usage.py`) reads the *user's own* Claude Code OAuth token — macOS Keychain (service
  `Claude Code-credentials`) preferred over the stale `~/.claude/.credentials.json`, Linux uses the
  file — and calls Anthropic's `/api/oauth/usage` + `/api/oauth/profile` (60s cached, off-loop via
  `asyncio.to_thread`). **Read-only by design:** haro never refreshes/rewrites the token (rotation
  could break the live Claude Code session); an expired token degrades to
  `{available:false, reason:"token_expired"}` with a "run any agent to refresh" note. Surfaced two
  ways: a full **Settings → Usage** tab (`Gauge` icon) and a compact glance **strip in the Dashboard
  header** that opens the full panel. Frontend: `components/Usage.tsx` (shared `useUsage` hook +
  `UsagePanel` + `UsageStrip`), `styles/usage.css`.
- **Merge Firewall verdict endpoint** (`backlog/merge-firewall.md` §3) — `GET
  /firewall/verdict?repo=<abs-path>&branch=<name>` (`main.firewall_verdict` →
  `models.FirewallVerdict`), the oracle the repo-level git hook will curl to decide whether a
  push/merge may proceed. A top-level route (the hook knows only its repo dir, not haro's project
  id): project matched by path via `git_ops._norm_path`, workspace by branch. Reads the
  denormalized `Workspace.gate`/`.status` off the store — no git/disk call, so a `--max-time 2`
  curl stays fast. Tri-state — `green` ⇔ `status == gate_green` (which already reflects
  `gate_merge_result` and, later, the Double Gate), `red` ⇔ `gate_red`, else `unknown` (ungoverned
  branch, unregistered repo, or not gated yet). Reports only — blocking (fail-open warn by default)
  is the hook + `[trust]` config's job (later §3 items). Tests: `test_firewall_verdict.py`.
- **Merge Firewall respects a foreign tool's own install** (`backlog/merge-firewall.md` §2) —
  `gate.ensure_deps`'s no-op guard is hardened from `wt_nm.exists()` to `exists() or is_symlink()`.
  `exists()` follows symlinks, so a *dangling* `node_modules` link a foreign tool left behind slipped
  past the guard; `os.symlink` then raised `FileExistsError`, degrading into a cry-wolf `setup`
  failure on a worktree that was in fact already provisioned. Any existing `node_modules` — real dir
  or symlink (live or dangling) — is now a clean no-op, so the adopt path (`run_setup` →
  `_provision_deps` → `ensure_deps`) never clobbers or trips over a foreign install. Tests:
  `test_ensure_deps.py`, `test_workspace_adopt.py::test_adopt_never_clobbers_foreign_node_modules`.

- **Merge Firewall auto-gate hold on adopted worktrees** (`backlog/merge-firewall.md` §2, the
  cry-wolf fix, part 2) — an adopted (foreign) worktree is now **never auto-gated until its
  provisioning reports `setup_state == "ok"`**. New pure helper `gate.auto_gate_allowed(workspace,
  setup_state)` (managed → always; adopted → only when setup ok) is enforced at `run_gate`'s single
  chokepoint: a non-`manual` trigger (`auto`/`autofix`, incl. the future §4 quiescence timer) on an
  unprovisioned adopted worktree returns early — the gate never runs, no red flip, nothing recorded.
  A **manual** gate (`POST /workspaces/{id}/tests`) is always honored. When a gate *does* error with
  `error_kind="setup"` on an adopted worktree, the UI now frames it as **"Environment, not code"**
  (`gateErrorFraming(kind, adopted)`, `.gate-errcard-env` — off the red palette) with a **re-run
  setup** affordance (`POST /workspaces/{id}/setup`) beside re-run-gate, so the firewall never reads
  a missing-deps foreign checkout as a code failure. Tests: `test_auto_gate_setup_guard.py`,
  `test_auto_gate_hold.py`, `gate.test.ts`.
- **Merge Firewall deps-on-adopt provisioning** (`backlog/merge-firewall.md` §2, the cry-wolf
  fix) — `adopt_workspace` now runs the **exact create-path provisioning** instead of registering
  a bare foreign worktree: `seed_worktree_env` + `copy_worktree_includes` (both non-clobbering,
  so a foreign tool's own `.env`/certs/`.npmrc` survive), the workspace is born
  `status="setting_up"`, and `run_setup` is scheduled under `SETUP_SESSION` (deps chip via
  `store.setup_state`). A foreign worktree that lacked haro's environment no longer gates red for
  *deps* reasons and makes the firewall cry wolf. `gate.ensure_deps` already no-ops on an existing
  `node_modules`, so a foreign tool's own install is never clobbered by the symlink stopgap. Tests:
  `test_workspace_adopt.py`.
- **Merge Firewall rescan on boot + on demand** (`backlog/merge-firewall.md` §1) — foreign
  (unadopted) worktrees are now re-derived from `git worktree list` on boot, following the
  `db.reconcile(store)` precedent in `main.py`'s `lifespan`: `main.reconcile_adoptable(store)`
  scans every project, seeds the per-project `store.adoptable` cache, and returns notes the boot
  log prints (`[adoptable] …`). It seeds **silently** (no client is connected yet, and everything
  would read as "new"). The on-demand scan endpoint `GET /projects/{id}/worktrees` re-scans every
  call, refreshes the baseline via `store.update_adoptable` (which returns the rows that
  *newly appeared* since the last scan, diffed by path), and broadcasts an `adoptable` hint on the
  global feed (`{channel:"notify", kind:"adoptable", project_id, count, new:[…]}`) carrying only the
  newly-appeared worktrees — so an open client lights up without polling. `adopt_workspace` prunes
  the adopted path from the hint immediately. The shared scan/filter logic is factored into
  `_scan_foreign_worktrees`. Never auto-adopts — registration stays behind the explicit adopt action.
- **Merge Firewall `Workspace.kind` provenance marker** (`backlog/merge-firewall.md` §1) — new
  `Workspace.kind: Literal["managed", "adopted"] = "managed"` in models.py distinguishes haro-created
  worktrees from foreign ones adopted in place; the adopt endpoint now stamps `kind="adopted"`. Persists
  free through db.py's `model_dump_json`/`model_validate_json` snapshot/hydrate — pre-firewall rows with
  no `kind` back-fill to `"managed"` on hydrate (no migration). Mirrored on the frontend `Workspace` type;
  the agentless-UI treatment (hide the ① agent step, "adopted" badge) is its own §1 item.
- **Merge Firewall adopt endpoint** (`backlog/merge-firewall.md` §1) — `POST /projects/{id}/workspaces/adopt`
  (main.py, beside `create_workspace`) registers an existing *foreign* worktree as a workspace so the
  gate/firewall governs it too. It's the `create_workspace` path **minus** `git_ops.add_worktree` (the
  worktree already exists on disk): it re-scans `git_ops.list_worktrees` to match the requested path and
  derive the branch from git (never trusting the client), refuses non-foreign paths (already-tracked ⇒
  409; the main checkout / a haro-managed worktree / a bare or detached checkout ⇒ 400), computes a
  remote-aware `base_ref` with the same `origin/<default>` logic as create, allocates a port, and
  snapshots with `kind="adopted"`. New `AdoptWorkspaceRequest` (`{path, name?}`) in models.py.
  Deps-on-adopt provisioning is its own §2 item.
- **Merge Firewall scan endpoint** (`backlog/merge-firewall.md` §1) — `GET /projects/{id}/worktrees`
  (main.py, beside `list_branches`) surfaces the repo's *unadopted foreign* worktrees: it scans
  `git_ops.list_worktrees` and drops every row haro already governs (managed workspaces, its own
  worktrees home, the repo's main checkout, bare entries), tagging each survivor with a best-guess
  `source` (`.claude/worktrees/` ⇒ `claude-code`, `claude-squad` dirs ⇒ `claude-squad`, else
  `unknown`). Read-only — it only lists adopt candidates; nothing is auto-adopted.
- **Merge-blocked and auto-merge-locked speak one language** (`backlog/autonomy-ladder.md` §2) —
  the ④-ship step (`GitPanel.tsx`) now renders the autonomy-ladder checklist under its
  "Merging is blocked" banner whenever the merge is blocked *because the gate isn't green* (the
  exact `409 merge blocked: gate is not green` case) and the project is on the ladder
  (`trust.enabled`). The checklist itself was **extracted from `GatePanel.tsx`'s `TrustLane` into
  a shared `components/TrustChecklist.tsx`** (with `TRUST_LABELS`/`TRUST_ACTION_LABELS`/
  `TRUST_FIX_LABELS`/`trustUnmet`) so the ③-gate `trust` tab and the ④-ship blocked banner render
  from **one source of truth** — no second copy to drift. Unmet rows deep-link back to the ③ gate
  step via a new `onTrustFix` prop wired to `App.tsx` `shipTrustFix` (guard → Gate settings;
  `run_full` → gate view + `runGate`; `ribbon` → gate view + focus nonce). No new `TrustReport`
  type work — it was already mirrored in `types.ts`.
- **Trust meter on the dashboard cards** (`backlog/autonomy-ladder.md` §2) — each `Dashboard.tsx`
  card now shows a compact autonomy-ladder meter: a streak progress bar (`streak/streak_required`)
  plus a rung label (`locked` → `ready` → the armed `auto-PR`/`auto-merge`). Fed from a new
  denormalized `TrustSummary` carried on the workspace (compact glance subset of the full
  `TrustReport`, stamped by `gate.run_gate` alongside `GateSummary`) — **no fetch-per-card**, the
  exact `gate` rule: it ships on the workspace list and refreshes live off the `trust` payload the
  `status` channel already broadcasts (`App.tsx` global feed merge). Hidden when the project isn't
  on the ladder (`enabled` false). New `models.TrustSummary` + `Workspace.trust`, `Dashboard.trustMeter`
  helper. Tests: `dashboardStatus.test.ts` trust-meter cases, `tests/test_trust_wiring.py` stamping assert.
- **Trust checklist rows deep-link to their fix** (`backlog/autonomy-ladder.md` §2) — each
  *unmet* row now carries a call-to-action button routed by a machine-readable `fix` token the
  backend stamps on the branch that knows the reason (`trust.py` `Condition.fix`, mirrored in
  `types.ts` `TrustFix`): a guard being off (merge-result / coverage / flaky) → **Gate settings**
  (opens the project's Gate tab where the `[gate]`/`[workflow]` toggles live); a fast impacted
  gate → **Run full suite** (`onRunGate` on the grid tab); a short streak → **See the ribbon**
  (jumps to the grid tab and pulses the regression ribbon). A genuine regression / flaky finding
  carries **no** link — that fix is code, not a toggle — so a deep-link only ever appears when a
  config action actually resolves the row.
- **Trust checklist on the ④-ship step** (`backlog/autonomy-ladder.md` §2) — the gate panel
  gained a **`trust` tab** rendering the autonomy-ladder report (`GatePanel.tsx` `TrustLane`):
  every condition as a met/unmet row with its backend `detail` — a legible checklist of "why
  you can’t auto-ship yet", deliberately **never a score or percentage**. A state-not-number
  headline (`armed` → `all conditions met` → `locked`) plus a tab badge counting the *required
  unmet* blockers. Fed from a new `TrustReport`/`TrustCondition` mirror in `types.ts` +
  `api.getTrust`, hydrated on workspace select and refreshed live off the `trust` payload
  piggybacked on the `status` channel (no fetch-per-verdict). 96% of devs don’t fully trust
  agent code, so the checklist IS the product; the auto-merge switch is the reward at the top.
- **Trust report over REST + the live feed** (`backlog/autonomy-ladder.md` §1) — the
  autonomy-ladder report is now exposed as `GET /workspaces/{id}/trust` (the conditions +
  streak + `met`/`armed` verdict), and `gate.run_gate` re-broadcasts it on the **`status`**
  channel by piggybacking the existing `GateSummary` publish — so the ④-ship checklist and
  the dashboard trust meter recompute on every gate verdict off the same coarse feed, no
  fetch-per-card (same denormalization rule as `gate`). A shared
  `gate.build_trust_report(store, workspace, settings)` is the IO shell around the pure
  `trust.evaluate` (fetches `latest_test` + `project_test_history`), so the endpoint and the
  broadcast can't drift; `_publish_status` gained a `trust=` kwarg. The merge-conflict early
  gate return carries the report too. Tests: `tests/test_trust_wiring.py`.
- **Project-level trust streak substrate** (`backlog/autonomy-ladder.md` §1) — the
  autonomy-ladder streak now counts trailing consecutive clean full-scope greens across
  *all* of a project's workspaces, not one. `Store.project_test_history(project_id)`
  gathers the chronological run history from `store.tests` (snapshotted to Postgres via
  `db.py` `test_runs`, so it survives restarts), and a new `TestRun.project_id` — stamped
  in `gate.run_gate` — keeps a workspace's greens attributable to the project *after* it
  merges + archives (`remove_workspace` drops the workspace but leaves its runs). Runs
  persisted before the field existed hydrate with `project_id = None` and are re-attributed
  via a live-workspace join while their workspace is still present. Feeds
  `trust.evaluate`'s `project_history` param; any full-scope red anywhere in the project
  resets the streak.
- **`TestRun.trigger` — the green-first-try signal** (`backlog/autonomy-ladder.md` §1) — a
  new `"auto" | "manual" | "autofix"` field on `TestRun`, stamped by `gate.run_gate` from
  what kicked the run off: `"auto"` (the post-agent auto-gate in `runner.py`), `"manual"`
  (a hand-triggered `POST /workspaces/{id}/tests`), or `"autofix"` (a re-gate inside the
  auto-fix loop). Only non-`autofix` greens climb the trust streak — needing the fix loop
  isn't a green-first-try — so `trust._is_clean_green` excludes them, guarding against
  fail→autofix→green churn inflating trust. Persisted (whole-model JSON in `db.py`
  `test_runs`); legacy rows hydrate with the default `"manual"`.
- **`write_project_trust` writer** (`backlog/autonomy-ladder.md` §1) — a targeted,
  non-destructive write of the `[trust]` autonomy-ladder policy, following the
  `write_project_gate` / `_upsert_table_keys` pattern (upserts keys in place, never
  clobbers `[scripts]`/`[gate]`/`[ports]`/`[workflow]`). The trust policy is team law:
  `target="shared"` writes the committed `settings.toml` and omits default-valued keys;
  `target="local"` writes only the delta over the committed policy it inherits, so a
  personal `settings.local.toml` reads as a pure tightening delta (deliberately unlike
  `write_project_agent`'s full-pin `.local`, because trust wants the un-set keys to inherit
  team law). Trust normalization (defaults, validation, `require_<key>` flags) factored into
  a shared `config._parse_trust` used by both `load_project_settings` and the writer, so the
  loader and writer can't drift on the condition set (`config.TRUST_CONDITIONS`).
- **Nord theme — the arctic family** (`backlog/nord-theme.md`) — the third theme family,
  built on the official Nord palette (MIT): Polar Night dark ground, Snow Storm light
  (white `--panel-2` pop, solid light-mode edges — the megaman-light lesson), Frost
  cyan/blue as the chrome voice with **aurora green kept as the gate signature**.
  Differentiates through *material and quiet* rather than the 8-bit family's hardness:
  frosted-glass overlays (toasts / modals / command palette get a translucent `--glass`
  fill + `backdrop-filter` blur), soft fog shadows, 2px quiet keycaps — and the
  **aurora gate moment**: when the verdict flips green, a one-shot aurora band (frost →
  violet → green, riding the mode-tuned tokens so it holds on light) sweeps across it
  and settles on gate green (`prefers-reduced-motion` disables it). Ships the official
  Nord Monaco editor + terminal ANSI palettes per mode, deepened on light for AA — dim
  text and light-mode Aurora hues deviate from canon where canon fails contrast, each
  deviation commented at the token (`frontend/src/styles/themes/nord.css`).
  Phase-4 polish shipped alongside: **aurora-sky flourish toggle** (Settings › Display,
  gated by a new `frost` family flag / `isFrostTheme` — the arctic mirror of `pixel` +
  CRT; a slow northern-lights drift in `styles/aurora.css`, screen-blend on Polar Night,
  watercolor-multiply on Snow Storm, hidden under reduced motion), **quiet loader**
  (the banter cubes become a breathing aurora ribbon in nord), **`glass` notification
  tone** (an icicle-tap chime beside the 8-bit `arcade` jingle in `notify.ts`), and the
  **micro-label type voice** (0.18em-tracked section heads — no new font bundled). — themes are now first-class and choosable, not a hardcoded
  dark/light flip. A registry (`frontend/src/themes.ts`: `id`, `label`, `tagline`,
  `ground`, preview swatches) drives a **Theme section in Settings › Display** — one
  clickable preview card per theme (swatch strip + label + tagline, active one ringed).
  The light palette moved out of `base.css` into its own token file
  (`frontend/src/styles/themes/light.css`), `@import`ed by the `styles.css` barrel after
  the partials; adding a theme is now one CSS file + one registry entry. The persisted
  `haro-theme` value is validated on load (`resolveThemeId`) so an unknown/stale id falls
  back to the default dark ground. The appbar sun/moon stays a quick dark↔light flip; when
  a custom (non-ground) theme is active it opens Settings › Display instead.
- **8-bit theme** — a third theme, an NES "blue-bomber"-inspired skin
  (`frontend/src/styles/themes/megaman.css`), registered in `themes.ts` as `8-bit`.
  A full reskin, not an accent swap: deep-navy ground + cyan family with the
  energy-green **gate signature preserved** (green gate still means mergeable), flat
  corners (`--radius-*: 0`), thick 3px borders, and hard-offset shadows with no blur.
  Pixelify Sans (already bundled) leads `--font-display` for headings/badges/buttons;
  body/UI text stays a readable sans. Trademark-free (no Capcom art/audio, no
  "Mega Man" in user-facing strings).
- **8-bit chrome moments** — theme-scoped `[data-theme="megaman"]` flourishes on three
  incidental surfaces so the reskin carries beyond the hero: the agent "Thinking…" loader
  swaps its banter cubes for a scrolling cyan **teleport beam** landing on a pulsing pad
  (`loader.css`), toasts become **NES dialogue boxes** (hard square frame + inset rule + a
  blinking "▼" continue caret, `toasts.css`), and the selected sidebar row gets a blinking
  "▶" **menu cursor** (`sidebar.css`). All CSS-only (no JSX change), stepped (`steps()`)
  timing for the low-fps sprite feel, and frozen under `prefers-reduced-motion`.
- **CRT flourish toggle** — an optional scanline + screen-edge vignette overlay that makes
  the 8-bit theme read like an old cathode-ray monitor. Pure CSS (`styles/crt.css`, a fixed
  `pointer-events:none` sheet above every surface), driven by a `data-crt="on"` attribute on
  `<html>` and persisted per-device as `haro-crt`. **Off by default**, auto-disabled under
  `prefers-reduced-motion` (the faint flicker is the only motion). The checkbox appears in
  **Settings › Display only while a pixel family is active** — gated by a new registry flag
  (`pixel: true` on 8-bit, read via `isPixelTheme`), so non-pixel families never see it.
  Covered by `themes.test.ts`.
- **8-bit gate jingle** — an `arcade` built-in option in the agent-done sound picker
  (`notify.ts` + `NotificationSettings.tsx`): an original chiptune "gate green" victory
  fanfare, a Web-Audio **square-wave** pulse arp rising through a C-major triad and
  resolving up an octave (C5·E5·G5·C6). Synthesized like the other built-ins (no bundled
  asset, works offline), trademark-free (no game-audio rip), and purely **opt-in** — the
  default stays `chime`. Available in any theme; pairs with the 8-bit skin but not gated
  on it. Picker chip renders automatically from `BUILTIN_SOUNDS`.
- **Editor + terminal palettes follow the theme** — the Monaco editor and the xterm
  terminal don't read the app's CSS vars natively, so a theme family may now ship
  optional `editor` (Monaco theme per mode) and `terminal` (16-slot xterm ANSI per mode)
  palettes in the `themes.ts` registry. The 8-bit family uses them for a **navy/cyan
  editor + shell** (energy-green kept as the ANSI/gate signature) instead of falling back
  to Monaco's stock `vs-dark`. `MonacoEditor.tsx` registers a Monaco theme per
  (family × mode) that has a palette — opaque (code), transparent (embedded fields), and
  diff variants; `Terminal.tsx` merges the ANSI palette over its live CSS-var surface.
  Both resolve via a shared `parseThemeProp("<family>-<mode>")`, so `App` now threads
  `${theme}-${mode}` into `CodePanel` + `ProjectSettingsModal` (previously bare `mode`,
  which starved Monaco of the family). Families without a palette (Haro) stay
  pixel-identical. Covered by `themes.test.ts`.
- **Tech-stack logos on project rows** — each project in the sidebar now shows its
  detected framework/language brand logos (e.g. Vue + Laravel for a polyglot repo). A new
  `presets.detect_stack_logos` sniffs top-level manifests (`package.json`, `composer.json`,
  `pyproject.toml`/`requirements.txt`, `Gemfile`, `go.mod`, `Cargo.toml`, Shopify theme
  layout) into an ordered, capped list of logo ids, stored on `Project.stack` at create
  time (and backfilled once per existing project on `GET /projects`). The frontend
  `StackIcon.tsx` inlines real brand SVGs at build time via `?raw` (framework/language marks
  from the `devicon` package; Shopify vendored under `assets/stack-logos`), each on a light
  tile so dark marks (Next.js) stay visible on the warm-dark theme.
- **Multiple agent sessions per workspace (WS multiplexing)** — a workspace can now host
  several agent conversations on the same worktree/branch, switched via a **session tab
  strip** in the agent-stream header (like the shell tabs: `session 1 · session 2 … · +`).
  The `agent` WebSocket envelope carries a **`session_id`** so concurrent streams route to
  the right tab, and each session **`--resume`s its own Claude conversation** independently
  (`Workspace.session_resume`, keyed `session_id` → Claude id; the primary session mirrors
  into the legacy `last_session_id` for backward-compat). Threaded end-to-end:
  `StartAgentRequest.session_id` → `run_agent(session_id=…)` → `_drive_agent`/
  `_announce_autofix` (tag the envelope + resume the session's thread; the gate stays on
  the shared worktree diff); new **`GET /workspaces/{id}/sessions`**, and `/events`,
  `/turns`, `/rewind` gained a `session` selector (default the primary session). Frontend:
  per-session `sessionEvents` map + switcher (`selectSession`/`addSession`, pure helpers in
  `src/sessions.ts`). Builds on the `(workspace_id, session_id)` transcript data model
  (#143). Tests: `backend/tests/test_ws_multiplexing.py`, `frontend/src/sessions.test.ts`.
- **Shared-branch semantics — concurrent sessions serialize on a per-worktree lock.** With
  multiple sessions now sharing one worktree/branch, their agent runs serialize on a new
  **`Store.agent_lock(ws_id)`** `asyncio.Lock` (the analogue of `git_ops._cwd_locks`), held by
  `run_agent` across drive + gate + auto-fix: two agents can never edit the same files at the
  same instant (git only reconciles edits across *separate* worktrees). A 2nd session is created
  and streams a **"⏳ queued"** notice immediately, but only edits once the 1st releases — so its
  gate sees the **combined diff** (the gate was already session-agnostic). `active_tasks` re-keyed
  **`(ws_id, session_id)`** so a 2nd session isn't rejected (the old blanket per-workspace 409 is
  gone) and doesn't clobber the 1st's stop handle; setup rides the reserved `store.SETUP_SESSION`.
  `start_agent`'s guard is per-session, `stop_agent` gained a `?session=` selector, and the
  commit/PR/merge/rewind/gate/setup guards now share one `store.busy_reason(ws_id)` helper.
  The composer's `busy` is still workspace-level, so concurrent sessions are a backend/API
  capability pending a per-session busy UI. Tests: `backend/tests/test_shared_branch.py`.
- **Backlog folder + in-app editing** — backlog docs can now live tidily under a
  **`backlog/`** folder (`backlog/gate.md`, `backlog/ui.md`) instead of littering the
  repo root with `todo-*.md`. Discovery (`main._discover_todo_files`) treats every
  doc under **`[backlog] dir`** (`config.ProjectSettings.backlog_dir`, default
  `backlog`) as a backlog file regardless of name, on top of the legacy
  "filename contains `todo`" rule (a root `TODO.md` still works). The backlog is now
  **editable in-app**: a **New** button (rail) creates a backlog file and an **Edit**
  button opens a raw-markdown editor, saved via **`PUT /projects/{id}/todo`**
  (`main.put_todo` → `backlog.write_todo`, path-guarded to backlog-eligible files
  inside the project); the fs watcher's `backlog_changed` refreshes the panel live.
  Backlog files are now rendered as **markdown with notes**: `main._parse_todo_doc`
  parses a file into ordered `blocks` (`note` prose + `- [ ]` items), and the detail
  pane interleaves read-only notes (`<FileMarkdown>`) with the clickable seed-to-
  workspace rows — so a backlog file doubles as a notes doc, and only `- [ ]` lines
  are actionable (no forced checkboxes). The haro repo's own 15 `todo-*.md` planning
  docs moved to `backlog/` (prefix dropped) as the first user of the convention.
- **Neovim in the code step (Linux-first editor option)** — the ② code step now has a
  **Monaco ⇄ nvim** toggle (top of the panel, choice persisted). nvim runs on the same
  PTY machinery as the embedded shell (`terminal.spawn_editor` / `_spawn_pty`, served over
  the new `/ws/workspaces/{id}/editor` WS, reusing `main._serve_pty` and `Terminal.tsx`
  with a `path` override). Which nvim launches is set by **`[editor] nvim`** in
  `.haro/settings.toml` (`config.ProjectSettings.nvim_mode`): `auto` (default — the
  developer's own `~/.config/nvim` if present, else a **bundled LazyVim** starter seeded
  into `~/.config/haro-nvim` under an isolated `NVIM_APPNAME`, so it never touches their
  config), `byo` (always their config), or `bundled` (always LazyVim). The nvim pane
  mounts lazily and stays alive across toggles (keeps unsaved buffers); a missing nvim
  surfaces a plain in-pane error.

### Changed
- **8-bit theme polish: long-session comfort in dark, a rebuilt light ground, and
  crisper pixel buttons** (`themes/megaman.css`, `buttons.css`, `test-grid.css`,
  `sidebar.css`). Palette rule: saturation is spent on small areas only. Dark softens
  `--fg` off the 17:1 glare white, calms the `--merged` magenta (it frames the whole
  workspace when merged) and the diff red; light trades the saturated sky wash for a
  soft sky paper with clearer bg to panel steps. Two new mode-aware tokens keep the
  gate hero honest in both grounds: `--pit` (the recessed grid/ribbon housings stay
  deep navy even in light; mixing off `--bg` had produced a gray slab) and `--pellet`
  (a deepened pass-green so ~150 green cells read as an energy bar, not a glare panel;
  the slow-test flamebar calmed from 0.28 to a 0.15/0.2 trace). Buttons: the keycap
  bevel is now two-tone sprite shading (`--bevel-hi`/`--bevel-lo`, light catch on top
  + hard shade below) with SOLID shade colors in light mode, replacing the translucent
  `--edge` that desaturated into gray mud on a pale ground; `.flow-step` joined the
  not-a-keycap opt-out list (the theme scope out-specified `bento.css` and the stepper
  had grown bevels). The navigator dropped its wall-of-bricks look: rest rows are quiet
  (faint frame, translucent fill), hover restores the capsule, selection keeps the
  accent box.

### Fixed
- **Nord aurora gate sweep no longer replays on every workspace open** — the one-shot
  aurora band (`gate.css` `nord-aurora`) was bound to the presence of `.verdict-green`,
  which mounts whenever an already-green workspace is opened, not only on a red→green
  flip — so the sweep fired on open with no visible trigger (and `GatePanel` wasn't keyed
  per workspace, so switching from a red workspace to a green one could fire it too). The
  animation now lives on a transient `.verdict-flip` class that `GatePanel` adds ONLY when
  `status` genuinely transitions to green from a non-green prior (never on first mount); at
  rest the Nord verdict is solid aurora-green (`var(--accent)`). `GatePanel` is now keyed on
  `workspace.id` (like `GitPanel`), so it remounts fresh per workspace and the flip detector
  can't leak across switches. `prefers-reduced-motion` still disables the sweep.
- **Diff-preview syntax colours were unreadable in light mode (every theme)** — the
  agent-stream file-edit diff popover (`AgentStream.useHighlightedDiff` → `highlight.ts`)
  read the light/dark ground from `document.documentElement.dataset.theme`, but the
  family×mode refactor moved the ground to `data-mode` and repurposed `data-theme` for the
  family (`haro`/`nord`/`megaman`). `data-theme` is therefore never `"light"`, so the
  highlighter always colorized with `vs-dark` — fine on a dark card, washed-out on a light
  one, identically across all families (the "shared cause"). Now reads `data-mode` for the
  ground and, per the goal that each theme stay visually distinct, colorizes with the
  family's OWN registered Monaco palette (Nord / 8-bit read in their own colours; the Haro
  family rides the stock `vs` / `vs-dark` ground). The preview highlighter registers the
  family theme itself, so it's correct even before the code editor has mounted.
- **Inline code chips no longer collide with neighboring lines in pixel themes** — the
  clickable copy-on-click `` `code` `` chips (`.inline-code`, rendered by AgentMarkdown /
  FileMarkdown — most visibly in backlog note blocks) borrowed the theme's chrome border
  via `var(--border-w)`. The 8-bit themes harden that token to `3px`, and since an inline
  element's border paints outside the line box without growing it, each chip bled ~6px
  into the lines above and below. The chip border is now a fixed `1px` (identical in the
  default theme, where `--border-w` is already 1px); the chunky token remains for
  block/flex chrome, where it grows the element properly.
- **nvim editor "not found on PATH" — backend couldn't see the Homebrew binary** — the code
  step's Monaco⇄nvim toggle reported *"nvim not found on PATH"* (and never opened the user's
  config) whenever the backend's PATH lacked Homebrew's `/opt/homebrew/bin`, where Neovim
  lives on Apple Silicon — even with `nvim` installed and a `~/.config/nvim` present.
  Detection (`terminal._resolve_nvim_mode`) was never at fault. Fixed in **both** launchers:
  - `run.sh` guaranteed `~/.local/bin` (claude) and nvm (node) but not Homebrew, so an
    app-launcher/Spotlight start (which hasn't run `brew shellenv`) failed. It now sources
    `brew shellenv` from the first Homebrew it finds (Apple Silicon, Intel, or Linuxbrew).
  - `desktop/main.js` (the Electron app built via `desktop/rebuild.sh`) scrapes the
    login-shell PATH (`$SHELL -ilc`), which normally includes Homebrew — but on a >5s-rc
    timeout it fell back to launchd's minimal PATH, dropping `nvim`/`claude`/`npx` together.
    A new `withToolDirs()` now guarantees `~/.local/bin` + Homebrew/Linuxbrew bins on the
    spawned backend's PATH whether the scrape succeeds or falls back (idempotent — a good
    login PATH is left untouched).
- **Duplicate backlog titles no longer collide** — two todo items with the same title
  slugify to the same string, which used to reuse the same worktree path (a hard `409
  worktree path already exists`) and `haro/<slug>` branch, so the second pickup failed.
  `create_workspace` now runs the slug through `_unique_slug`, which bumps `foo` → `foo-2`
  → `foo-3` past any existing worktree dir **or** branch (both namespaces), reflects the
  counter in the display name (`<title> (2)`), and the composer surfaces a toast so the
  dev knows a same-titled task already existed instead of silently getting a distinct
  branch. Covered by `tests/test_unique_slug.py`.

### Added
- **Rewind to here (agent-turn rewind)** — each of your prompts in the agent stream now
  carries a **"⤺ rewind to here"** marker (the per-turn boundary the markers feature laid
  down). Clicking it rewinds the session to that turn: the transcript is truncated at/after
  it and the **composer is prefilled** with that prompt so a bad turn is cheap to re-word
  and retry. Since there's no headless `claude --rewind` (`--resume` only resumes at the
  transcript leaf — see `notes/claude-code-stream-json.md` §11), haro builds it itself:
  `Store.rewind(ws, turn)` truncates its own persisted transcript (drops every `turn`-tagged
  event ≥ N; pre-marker events are kept) and the `POST /workspaces/{id}/rewind` route
  reconciles the worktree by first **checkpoint-committing** the current changes (reusing
  `git_panel.commit`, best-effort) so nothing is lost — the dropped turns' edits stay
  recoverable in git history. `last_session_id` is kept, so the re-run `--resume`s the same
  Claude session and continues from the rewound point. Refuses while an agent is running,
  and — like the conflict handoff — **never auto-runs**. `RewindRequest`/`RewindResponse` +
  `api.rewind`; wired through the `onRewind` seam on `AgentStream`. Backend tests:
  `tests/test_rewind.py`.
- **Fast Mode (per-run agent mode)** — a **"fast"** toggle beside the model/effort a **"fast"** toggle beside the model/effort
  pickers (Claude Code only, amber) for "speed over depth" on narrow edits and quick
  follow-ups. There is no `--fast` CLI flag: fast mode is a persisted `fastMode` setting
  (the REPL's `/fast`), so the adapter injects it per-run as `--settings '{"fastMode":true}'`
  (verified against Claude Code v2.1.214 to flip the session's `fast_mode_state`). Threaded
  `StartAgentRequest.fast` → `run_agent`/`_drive_agent` → `ClaudeCodeAdapter.run` (feature-
  detected, rides the auto-fix rounds); **mutually exclusive with "plan first"** in the
  composer. Unlike a plan run, a fast run still edits files and runs the gate normally.
- **Diff-viewer review controls** — the per-file diff (② code) gains two reviewer
  controls for large diffs, neither touching the gate: **commit-by-commit filtering**
  (step through the branch one own-commit at a time — `<sha>^` vs `<sha>` — instead of
  the full squashed working-vs-base diff, via a new `GET /file/base?ref=` param) and a
  **unified vs split** layout toggle (Monaco `renderSideBySide`, applied live, persisted).

## [0.8.0] - 2026-07-17 — Desktop app & config parity

The app becomes a shippable native desktop program and closes the last configuration
configuration gaps.

### Added
- **Native macOS Electron build** (dmg, arm64), on top of the Linux Electron package.
- **In-app self-update** — idle-gated rebuild, manual or automatic.
- **Global `⌘+Enter`** to run/queue the agent task from anywhere, with a `⌘↵` keycap on the run button (#109, #110).
- **GitHub Issues write-back** on pickup — self-assign + `in-progress` label + comment (#113); `Closes #<n>` threaded into issue-seeded commit/PR bodies (#114).
- Expand a GitHub issue in-place to read its body + comments (#115); label filter, text search and group-by-label on the Issues tab (#116).
- Claude command menu in the embedded shell — run `/mcp`, `/usage`, etc. from the terminal (#117).
- **Multiple shells per workspace** with a de-cluttered terminal header (#120).
- Render MCP `★ Insight` blocks as an amber fun-fact callout in the agent stream.
- **Config parity:** copy gitignored files into worktrees by glob, not just `.env` (#122); multiple named run scripts, each on its own port (#124); a user-global settings layer beneath project scopes (#125).

### Changed
- Anthropic Sans platform-wide + serif agent output; de-bolded file tree (#118).
- Settings: checkboxes swapped for toggle switches (#119).
- Ship view: "Files changed" dropdowns flattened to GitHub's minimal look (#112).

### Fixed
- Terminal: neutralize host terminal identity in the embedded PTY (#108).
- Desktop: resolve login-shell `PATH` so agents + gate run under a GUI/stale-terminal launch.
- Persistence/WS: flush transcript on run completion; tolerate disconnect + shutdown-cancel on live feeds.
- DB: single-writer lock so overlapping backends can't clobber state; `run.sh` enforces a single fresh backend instead of reattaching.
- SPA shell no-cached so a rebuilt desktop app isn't served stale.
- Dashboard: truncate long workspace names + branches on triage cards.
- UI: focus the prompt composer (not the terminal) on workspace open (#123); shell tab close button made static, not a keycap (#126).

## [0.7.0] - 2026-07-15 – 2026-07-16 — Console polish, the verify lane & local models

The agent surface consolidates into one console, the gate grows an AI review lane, and
haro learns to run on local models and on SQLite (no Docker required).

### Added
- **Voice-dictate the task composer** with a mic keycap (#81).
- **`verify` step** — the gate step is renamed to "verify" and gains an **AI code-review lane** alongside the tests.
- **Local-model backend** — `LocalModelAdapter` (Ollama / llama.cpp) (#99); a per-run backend picker (Claude Code / local); backend + model collapsed into one grouped dropdown.
- **Run natively on SQLite** instead of Docker/Postgres.
- **Package haro as a native Electron app** (frozen backend + SPA).
- **GitHub Issues as a second backlog tab** (#104).
- OS-level desktop notifications for gate + agent-done (#93).
- Keyboard-shortcuts modal + shell focus hint; fullscreen agent stream (#100) and fullscreen shell + compact stepper (#95).
- Terminal: colored prompt + `TERM`/color; `Ctrl+`` focuses the shell with the composer focus-glow.
- Sidebar: draft status for workspaces with unsent prompt text.
- Composer: clickable PR-reference badges (#88); seeded green-gate glow flashes on `⌘I` focus (#86).

### Changed
- Fold agent stream + review + prompt into one console surface (#82); move the gate onto the stream header (#87).
- Split the monolithic `styles.css` into topic partials behind a barrel import (#94).
- Sweep glyph affordances → sized SVG icons across the UI, appbar and settings tabs (#103).

### Fixed
- git-panel: eliminate Create-PR button flicker (#80); scope follow-up commit prefix to its own workspace (#85).
- review: keep the AI review from failing on an empty/unparseable result (#105); end the AI-review coin-toss + 3 verify-lane UX bugs.
- agent: keep session context across a mid-run stop (#107).
- db: strip NUL bytes before jsonb snapshot writes.
- terminal: kill the black bar below the shell (xterm viewport bg) (#98).
- backlog: strip `[TAG] -` prefix from GitHub issue titles when seeding a workspace.
- icons: show the Liquid file icon for `.liquid` files.

## [0.6.0] - 2026-07-14 — Stack presets, the settings hub & the code-editor IDE

The gate becomes stack-aware (auto-detect + propose config), all project configuration
moves behind a single `⚙` hub, and the code step grows into a real editor.

### Added
- **JSON-offense live-grid gate adapter** (theme-check / eslint / ruff) (#51).
- **Stack presets** — declarative registry with detection (#53); stack detection on add-project (#54); propose-and-confirm gate config (#55); local Shopify CLI via `npx` + login shell (#58).
- **fs watcher** — live panel updates, no manual refresh.
- **Per-project `⚙` settings hub:** Git tab with base-branch + ship-mode picker (#60, #61), Setup tab for scripts + instructions (#62), Gate tab (runner/command/scope + flaky/coverage guards) (#63), Agent + Instructions tabs (#64), Environment/secrets editor seeding the worktree `.env` (#67).
- Instructions: gate-integrity + backlog-tick platform contracts.
- **Code editor:** multiple open tabs (#56), go-to-file `⌘P` fuzzy open (#68), clickable breadcrumb path header (#69), per-file working-vs-base diff (#70), binary/large-file guard (#71), tree file ops — new/rename/delete (#72), sticky per-workspace editor state (#73), inline syntax squiggles via the worktree's `tsconfig` (#74), resizable file tree (#75).

### Changed
- Migrate the remaining CodeMirror fields to Monaco.
- Retire the per-workspace scripts editor — the project Setup tab is now the one source (#65).
- Default agents to opus/high and uncap the per-run budget.
- Quiet status-line remote row.

### Fixed
- code-preview: render relative markdown images from the worktree.
- sidebar: render the project gear; stop settings from collapsing the desktop sidebar.
- composer: stop a run/cleared task draft from resurrecting on re-select.

### Tests
- Cover stack-detection (#59) and the settings-hub routes + workspace-scripts retirement (#66).

## [0.5.0] - 2026-07-13 — The configurable gate & continue-on-new-branch

The gate stops being Vitest-only, and the ship flow learns to keep going after a merge.

### Added
- **`CommandAdapter`** — gate with an arbitrary configured command (#44); frame command-gate non-launches as *setup*, not red (#46).
- **"Continue on a new branch"** after merge, with follow-up PR threading (#38).
- Workspace defaults: `feat/` branch, diff→ship, seeded glow, composer attachments (#47).

### Changed
- Document `.haro/settings.toml` with a real Shopify command-gate example (#48).

### Fixed
- Ship: make PRs work from the Docker stack + reconcile stale PR status (#35).
- gate: auto-install deps for a fresh project so it runs out of the box (#36).
- composer: standardize the paste-to-file chip (#39); unblock Continue after a GitHub-side merge (#40); render fenced code as a clean full-width block; don't flash "queue" while a seeded workspace is setting up (#50).
- code: full-fidelity markdown preview (react-markdown + GFM) + fullscreen width (#43).
- backlog: parse wrapped todo items; split todo text (display) from body (agent brief).

### Tests
- Cover command-gate config parse + `CommandAdapter` dispatch (#49).

## [0.4.0] - 2026-07-12 — Brand: renamed to haro

The project is renamed from **Synthesis** to **haro**, end to end.

### Changed
- Rebrand **Synthesis → haro** across user-facing runtime strings, docs & artifacts, internal/build/launch code, and `synthesis.desktop → haro.desktop`.
- Re-skin ④ ship as a GitHub pull-request page.
- Backlog master-detail redesign — searchable rail + lifecycle groups (#33).
- Record the code-editor decision: switched to **Monaco** (was CodeMirror).

### Fixed
- gate: give the merge-result's `git merge` a guaranteed identity.

## [0.3.0] - 2026-07-11 — GitHub flow, remote linking, robustness & the cockpit UI

The biggest single day: the store is hardened against desync, the app learns to talk to
GitHub remotes, and the cockpit UI (stream, nav, mobile, the ①②③④ flow) takes shape.

### Added
- **Remote/GitHub flow:** link a project to a git remote + linked badge; publish/push the default branch from the UI; project-level pull for github-linked repos (#14); improved commit/PR/merge ship UX (#12).
- **The `① agent › ② code › ③ gate › ④ ship` flow** (#7), with the gate swapped into the step (preview to the side rail); ④ ship re-skinned as a GitHub PR page (#30).
- **Agent stream:** CLI-style op rows with a running pulse; expandable inline diff on file-edit rows; file chips + Monaco (#25); file references (#6).
- Two-layer "Add a project" — create new (`git init`) or add existing.
- Backlog: click a pending todo to seed a workspace; merged-workspaces view (#9).
- Editor: inline image/PDF preview + markdown toggle; VS Code-style changed-file highlighting in the tree.
- Toast notifications with configurable position/duration (#13); loading state on the merge button.
- **Mobile:** responsive phone layout — drawer sidebar + bottom tab bar (#20); decluttered top bar + master-detail editor.
- Rename workspace + branch, with branch-prefix presets (#21).
- Context-usage meter + code block in the task input (#26); the "expert for this platform" skill (#10).
- **Persistence & robustness:** agent transcript persistence (survives refresh/restart); Claude Code session resume (`--resume`); boot hydration of `agent_events`; store↔git reconciliation + crash-safe worktree teardown; the desync-hardening plan.
- merge: GitHub-style merged state + remote-aware base.
- instructions: standing rule to tick the TODO item when a task is done (#8).

### Changed
- nav: 'projects' becomes a plain label, home moves to the appbar logo; project rows + workspaces render as capsules; slimmed telemetry strip (#22).
- Redesign the project remote bar — compact keycaps, GitHub pull/push colors, edit-in-modal (#29).
- Optimize Claude Code token usage + default model/effort (#11); optimize the gate step (#24, #31).
- **Drop `uvicorn --reload`** so a merge writing the source tree no longer restarts the backend and kills running agents.
- Serialize git subprocesses per worktree to prevent `index.lock` races; release the workspace port on merge (not just archive).

### Fixed
- gh: install `gh` in the backend image + pass `GH_TOKEN`; worktree-safe `gh` merge; merge no-op on re-merge (#15).
- Don't orphan dev servers on restart (run-state desync).
- De-keycap the kebab/logo/popovers; keep the mobile run button reachable (#23); render backlog markdown + a real empty state.

## [0.2.0] - 2026-07-10 – 2026-07-11 — The cockpit & self-hosting

haro becomes "the one window a dev works in": an embedded terminal, code editor and
preview, all running on a self-hostable Docker + Postgres stack.

### Added
- **Brand theme** — the trademark theme board + applied warm-dark/light theme + 3D keycap buttons (the PostHog-inspired green-gate identity).
- **Embedded terminal** per workspace (PTY + xterm.js), as its own card below the gate.
- **In-app code editor + live app preview**; **command palette** (`⌘K`) + ripgrep worktree search.
- **Docker stack + Postgres persistence** + a self-host gate.
- **`PytestAdapter`** + per-project gate runner — gate the Python backend, not just Vitest.
- Richer agent-output markdown (bold/italic/headings/lists) + an npm-cache volume.

### Changed
- Isolated per-worktree frontend deps (`npm install`, replacing the `node_modules` symlink hack).

### Fixed
- Pin Vitest 4.x so the gate's NDJSON reporter API works.

## [0.1.0] - 2026-07-10 — Foundations & the gate

The initial baseline, captured in the first checkpoint (`Synthesis v0 → v2.0`). This is
haro's reason to exist: **no agent's work is mergeable until the tests are green — and you
watch it happen.**

### Added
- **The test gate (North Star)** — agent → isolated git worktree → streamed output + diff; the `VitestAdapter` runs automatically on agent `done`; merge is blocked unless the gate is green (`gate_green` / `gate_red`).
- **Live test grid** — cells stream gray→green/red via a custom Vitest NDJSON reporter; click a cell to drill into its error; slow-test flamebar + wall-time.
- **Impact Map** — changed files → impacted tests (`vitest list --changed`), run-impacted-only fast gate, a regression ribbon (gate-run history), coverage delta vs a base ref, and a flaky detector.
- **Review round-trip** — inline comments on diff lines + failing tests loop back to the agent composer as a follow-up task.
- **commit → merge → archive** (`integrate.py`) — local merge for no-remote repos, `gh` PR + merge when a remote exists; refused unless the gate is green.
- **Multi-agent** — agents run concurrently across worktrees; a global live feed (`/ws`) broadcasts coarse status/gate events; a triage dashboard ranks all workspaces needs-attention → active → green → idle.
- **Two adapter seams** — `AgentAdapter` (`ClaudeCodeAdapter`, parsing `--output-format stream-json`) and `TestRunnerAdapter` (`VitestAdapter`), normalized to five event types (`token | tool_call | file_edit | done | error`).
- **`.haro/settings.toml`** lifecycle scripts (`setup` / `run` / `archive`) + per-workspace port allocation (`HARO_PORT` / `HARO_WORKSPACE_PATH` / `HARO_ROOT_PATH`), with files-to-copy globs and a `.haro/.env` secrets seed.
- **"Run app"** — start the project's `run` script in the worktree on its allocated port, stream logs to the agent pane, with an "open ↗" link and stop-on-demand.

[Unreleased]: https://github.com/HaziqLucii/haro/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/HaziqLucii/haro/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/HaziqLucii/haro/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/HaziqLucii/haro/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/HaziqLucii/haro/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/HaziqLucii/haro/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/HaziqLucii/haro/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/HaziqLucii/haro/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/HaziqLucii/haro/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/HaziqLucii/haro/releases/tag/v0.1.0
