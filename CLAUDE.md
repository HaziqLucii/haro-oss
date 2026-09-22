# haro

haro is a **local-first, Linux-first AI coding-agent orchestrator** — a control plane
that runs multiple AI coding agents in parallel, each isolated in its own **git worktree**,
with an **automatic per-agent test gate**: no agent's work is mergeable until its tests pass,
and you watch it happen on a live visual map. It's inspired by prior-art macOS-only
orchestrators but is not a clone — see the differentiators below.

## North star
> No agent's work is mergeable until `vitest run` is green — and you can watch it happen.

**Strategic stance: "the gate is the whole point."** Make the single-workspace test-gate
experience genuinely excellent BEFORE building multi-agent breadth. Depth over breadth.

## What makes it distinctive
1. **Linux-first** (the comparable orchestrators are macOS-only).
2. **Vitest/test gate as the headline** — local, automatic, pre-push, visual. The macOS-only
   tools defer to GitHub CI (post-push). This is the flagship.
3. **Local-first / minimal-permissions** — drive local git + optional `gh` with the user's
   own creds; no broad GitHub OAuth (broad OAuth scopes have drawn criticism elsewhere).
4. Later moats: Impact Map (changed files → impacted tests), conflict-aware merge queue,
   spec-driven fan-out.

Multi-agent support is **table stakes**, not a differentiator (the incumbents are already multi-agent).

## Tech stack
- **Backend:** Python + FastAPI + asyncio (subprocess supervision + WebSocket streaming)
- **Frontend:** React + TypeScript + Vite
- **Packaging:** local web app first; optional Electron wrapper later
- **Git:** local git CLI + worktrees; optional `gh` CLI for PRs (no OAuth)
- **Aesthetic:** the **Kuro/ryoku brand theme** (trademark, single theme, **dark-only** — the
  light toggle was removed in the 2026-09-02 pivot) — warm monochrome bone ink
  (`rgb(205,196,186)`) on near-black (`#0b0a09`), Swiss grid + Japanese restraint, hairline rules
  and 2px corners, no shadows, film grain (`styles/dossier.css`), a small ghost-faint katakana
  word (`モノクローム`) peeking off the dashboard's right edge. Green (`--accent`) is reserved for the
  test gate only — everywhere else (buttons, focus rings, meters) is bone/ink. Type: Fraunces
  (display/wordmark) + Space Grotesk (UI/prose) + Space Mono (mono/prompt/code default),
  self-hosted, bundled in `frontend/public/fonts`; the older Anthropic Sans/Serif + IBM
  Plex/JetBrains Mono + Pixelify + Open Runde faces stay bundled as the offline fallback chain
  and because 8-bit/nord still reference them (kept in the registry, not deleted). All colors
  flow through CSS vars in `styles/base.css` `:root` (`styles.css` is a barrel that `@import`s
  the topic partials in `frontend/src/styles/`). `brand/dither.py` (Floyd-Steinberg or
  `--ordered` Bayer, reproducible) is available for a future image accent but isn't wired to
  anything shipped today. Motion: ink arrives, objects do not move; tokens in
  `styles/motion.css` (see `notes/kuro-motion-plan.md`). See `notes/kuro-theme-plan.md` and
  `backlog/kuro-theme.md`.

## Two adapter seams (design up front, one impl each for now)
- `AgentAdapter` — **Claude Code first** (`ClaudeCodeAdapter`, parses `--output-format
  stream-json`); Codex/Cursor/Gemini later. Normalize output to events:
  `token | tool_call | file_edit | done | error`.
- `TestRunnerAdapter` — **Vitest first** (`VitestAdapter`); pytest/jest/go-test later.

## Roadmap (current phase: v1 ✅ · v2 core + v2.3 config ✅ · cockpit largely ✅ · robustness-hardened via dogfooding — see CHANGELOG.md)
> **`CHANGELOG.md` is the live record of what's shipped** (versioned `0.1.0` → current; the
> `v1`/`v2` labels here are internal *milestones*, not releases — they map underneath the `0.x` line).
> The notes/ planning docs below are the *original plan* — read `CHANGELOG.md` for where we actually are.
- **v0** — agent → worktree → streamed output + diff (prove the pipe) ✅ **DONE**
- **v1** — THE GATE, deep, on ONE workspace: works → beautiful (live grid) → smart (Impact Map)
  - **v1.0** ✅ **DONE** — `VitestAdapter`, auto-gate on agent `done`, `gate_green`/`gate_red`,
    merge blocked unless green. Multiplexed WS channels (`agent`/`test`/`status`).
  - **v1.1** ✅ **DONE** — live test grid (cells stream gray→green/red via a custom Vitest
    reporter), click a cell → drill into its error, slow-test flamebar, wall-time.
  - **v1.2** ✅ **DONE** — **Impact Map** (changed files → impacted tests via
    `vitest list --changed <base_ref>`), **run-impacted-only** fast gate (`vitest --changed`),
    **regression ribbon** (gate-run history), **coverage delta** (worktree vs base_ref baseline,
    cached; needs a green base), **flaky detector** (re-run N× via `analytics.detect_flaky`).
  - **v1.3** ✅ **DONE** — inline review comments (diff lines + failing tests) round-trip to the
    agent composer as a follow-up task; **commit → merge → archive** via `integrate.py` (local
    merge for no-remote repos, `gh` PR+merge when a remote exists), refused unless `gate_green`.
- **UI** ✅ **bento redesign** — bento layout: LEFT sidebar (projects → workspaces
  navigator), MIDDLE agent stream + roomy prompt composer, RIGHT gate (hero) + diff, TOP
  telemetry tiles (gate/tests/coverage/impact). Still the minimalist dark + green-accent identity.
- **v2** (in progress) — multi-agent dashboard + feature parity
  - **v2.0** ✅ **DONE** — **parallel agents** (agents run concurrently across worktrees;
    verified overlapping), **global live feed** (`/ws` broadcasts coarse status/gate events
    for every workspace via `hub.subscribe_global`), **triage dashboard** (`Dashboard.tsx`:
    all workspaces as cards ranked needs-attention → active → green → idle).
  - **v2.1** ✅ **DONE** — `.haro/settings.toml` config (`config.load_project_settings`,
    committed + `.local` override), **setup script** run on workspace create (streamed, replaces
    the node_modules symlink hack — that's now the fallback), **archive script** on delete,
    **per-workspace port allocation** from a configured range (`HARO_PORT/WORKSPACE_PATH/ROOT_PATH`
    env). See `lifecycle.py`.
    - **Config parity** ✅ **DONE** (see `backlog/project-config.md` for the checkbox-tracked
      spec): **files-to-copy** globs (`[files] include`, default `[".env*"]` — `copy_worktree_includes`
      seeds gitignored files like `.npmrc`/certs into each worktree, on top of the `.haro/.env` secrets
      seed), **multiple named run scripts** each on its own port, **user-global settings** layer.
      ⚠ files-to-copy is already built here — do NOT re-scope it as a gap.
  - **v2.2** ✅ **DONE** — **`run` script** (dev-server "Run app" action + stop): starts the
    project's `run` script in the worktree on its allocated `HARO_PORT`, streams logs to the
    agent pane, exposes an "open ↗" link, stops on demand/archive (`lifecycle.start_run/stop_run`,
    `store.run_procs`).
  - **v2.3** ✅ **DONE** — **platform configuration**: custom instructions (Tier-1) — a standing
    prompt every run inherits via `--append-system-prompt`, from `.haro/instructions.md`
    (committed) + `.local` (personal), edited in the Runbook (`config.{read,write,combined}_instructions`,
    `GET/PUT /workspaces/{id}/instructions`); `[workflow]` toggles stubbed for Tier-2; **agent-done
    sound** (coarse `notify` on the global feed → client beep, `NotificationSettings.tsx`/`notify.ts`);
    **per-run model + reasoning-effort** pickers (`--model` / `--effort`); **delete workspace**
    (`DELETE /workspaces/{id}`) + **remove project** (`DELETE /projects/{id}`).
  - **Robustness / reconciliation** ✅ (hardened via heavy dogfooding) — the store is a cache
    reconciled to ground truth (SQLite / OS procs / git worktrees). **Dropped `uvicorn --reload`**
    (a merge no longer restarts the backend + kills running agents); transcript hydrated on boot +
    `_sync` wipe-guard; crash-safe idempotent `remove_worktree` + `.git`-validity reconcile +
    `integrate` preflight; `broken` workspace status; no orphaned dev servers (process groups +
    boot sweep); per-cwd git lock (index.lock races); **conflict-safe local merge** (task 4,
    2026-09-14 — `local_merge` aborts and leaves `main` clean on any merge failure instead of
    leaving conflict markers on disk). Pending: periodic reconcile, agent auto-resume — see
    **`notes/desync-hardening-plan.md`**.
  - **v2.x** (next) — Tier-2 workflow enforcement (changelog + confirm-before-commit); composer
    context (file mentions, `.context/` handoff folder); seed a workspace from a branch or GitHub issue.
- **Cockpit pivot** (the "one window, no alt-tab" strategy — see CHANGELOG.md + backlog/cockpit.md)
  - ✅ embedded **terminal** (PTY), in-app **code editor** + file tree (Monaco, with
    fullscreen focus mode), **command palette** (⌘K), worktree **search** (ripgrep).
    ⚠ The **live-preview iframe was shipped then retired** — a page rendered in a pane is the one
    surface a real browser beats outright, so the rail now carries a one-line **app strip** (run /
    stop / open ↗ / scripts, with the **Live Gate** as a small advisory chip) plus a one-line
    **look-at chip** (`LookAtChip.tsx`) deep-linking to ③ verify's "things to look at" zone — the
    diff-level signal (`backlog/code-to-check.md`), since every other gate guard is suite-level, now
    living inside ③ itself rather than as its own rail card (see the ③ verify redesign below). Do NOT
    re-scope an embedded preview as a gap (`backlog/live-gate.md`), and note `GateLive.tsx` is
    deleted: its pane was empty unless you hand-edited in a worktree.
  - ✅ **Task flow** — main column is a stepper `① agent › ② code › ③ gate › ④ ship` (freely
    clickable, live state badges), not loose tabs. The workflow made visible; the gate is step ③
    on the main stage (promoted out of the side column, which now holds preview + terminal), so the
    flow literally resolves on the green gate before ④ ship.
  - ✅ **Git & PR panel** (`git` main-column tab, `GitPanel.tsx` + `git_panel.py`): branch
    ahead/behind, checkpoint commit (no merge), dirty files, history (own commits marked),
    PR status + CI checks + review via `gh`. Endpoints `GET/POST /workspaces/{id}/git/*`.
  - ✅ **Runbook** — Dev folded into run-app/preview (▸ run / ■ stop / ⌘R), Setup surfaced as the
    `deps` gate chip, in-app CodeMirror scripts editor (save → `.local`, promote → committed) —
    NOT a generic tab clone. Plus: PostHog-style **changes accordion** (shared `Chevron.tsx`),
    **composer focus hotkey**.
- **Brand** ✅ — pivoted (2026-09-02) to **one trademark theme**, Kuro/ryoku: warm monochrome,
  dark-only (light toggle removed), Fraunces/Space Grotesk/Space Mono, bone/inverted-bone
  primary buttons, green reserved for the gate. `backlog/kuro-theme.md` tracks the completion
  pass (fonts bundled, dossier flourishes, de-green sweep, chrome parity, editor/terminal
  palettes). 8-bit/nord themes and the dead light-mode CSS stay in the registry as a revert
  path, not deleted. See `brand/` (`dither.py`, `fetch_fonts.sh`) and `notes/kuro-theme-plan.md`.
- **Winner-only fan-out** ✅ (Bet 11, `backlog/winner-fanout.md`) — `race ×N` fans ONE prompt
  across N lane configs (model×effort) as sibling workspaces; the merge-blocking gate **ranks**
  them and you review exactly one candidate plus a scorecard. `race.py` is the pure judge
  (policies + tie-break chain + the two honest refusals: a suite too thin to referee with, and
  an all-green tie it won't fake a winner out of); `fanout.py` is the shell (seed lanes, force
  the strict gate so every lane's green means the same thing, watch the race-level $ ceiling,
  soft-archive losers with their branches + transcripts intact). Opt-in `[race] enabled`.
- **v3** — merge queue · spec-driven fan-out · cost/token metrics · round-2 trust-ladder
  bets (Bets 8–12 — see `notes/differentiation-bets-round2.md` + their `backlog/*.md` specs)

## Config convention
- `.haro/settings.toml` (committed) + `.haro/settings.local.toml` (gitignored)
- `[scripts]` lifecycle hooks: `setup` / `run` (multiple named `[scripts.run.<id>]`) / `archive` + `run_mode`
- `[files] include` — glob list of gitignored files copied into each new worktree (the
  "Files to copy" convention; default `[".env*"]`). Secrets live in `.haro/.env` (the Environment tab), seeded
  separately. See `config.copy_worktree_includes` / `seed_worktree_env`.
- `[race]` — **winner-only fan-out** (off by default): `enabled`, `lanes` (model×effort grid),
  `policy` (`first_green`|`cheapest_green`|`best_coverage_delta`|`merge_clean`), `max_lanes`,
  `min_suite_tests` / `min_impacted_tests` (the two thin-suite refusals), `max_total_usd`
  (race-level $ ceiling; 0 ⇒ lanes × `[agent] max_budget_usd`). See `race.py` / `fanout.py`.
- `[gate] watch` — the **Live Gate** (off by default): re-run the impacted tests ~2s after the
  worktree goes quiet, streaming an **advisory** verdict into the side rail. Structurally cannot
  ship anything (`gate.run_watch`, its own `watch` WS channel — never `workspace.status`/
  `store.tests`); the full-scope ③ gate stays the only merge verdict. See `backlog/live-gate.md`.
- `[gate] verified_hunks` — **Verified Hunks** (on by default since 2026-09-14): annotate the ④ ship diff per
  line — "executed by the green suite" vs "never executed" — sort the untested files first and
  collapse the fully-executed ones, so a big agent diff shrinks to the residue nothing ran.
  Evidence, never a verdict: no label says "verified", and it cannot block a merge. Reuses the
  per-line coverage map `code_to_check` already measures, so it adds no test run
  (`verified_hunks.py`, `GET /workspaces/{id}/verified-hunks`). See `backlog/verified-hunks.md`.
- `[gate] mutation` — **Mutation score** (off by default): the "would the tests notice if the
  code were wrong?" signal. Mutate each **added** line, re-run the suite, list the faults nothing
  caught (**survivors**). Where coverage says "the line ran", this says "no test failed when it
  changed" — proven to point at a real float-rounding bug a 100%-coverage green gate certified as
  clean. Advisory (no `mutation_blocked`), on-demand (it re-runs the suite N times, so off the ~1s
  gate path), a Zone 4 Details tool ("how hard are the tests to fool") on the ③ verify page —
  see the ③ verify redesign below. **The baseline sanity check is load-bearing** (the
  unmutated suite must run AND pass, or every mutant "passes" vacuously). `mutation.py` +
  `POST /workspaces/{id}/mutation`. See `backlog/mutation-gate.md`.
- `[quality]` — **the Double Gate** (Bet 7, off by default): green means tests **AND**
  quality. `enabled`, `scanners` (`gitleaks`/`semgrep`/`lint`), `severity_threshold`,
  `enforce` (warn|block), `lint_cmd`, `semgrep_config`, plus `plan_compliance`
  (off|warn|block) for the LLM third. Deterministic scanners are diff-scoped and run on an
  otherwise-green gate; `quality_blocked` folds into the green conjunction so `integrate`,
  the merge queue and the ladder all refuse quality-red for free. **A scanner that isn't
  installed DEGRADES the run — it never reads as clean** (§0). Plan compliance blocks only
  on a high-confidence gap that cites a diff line; an ungrounded claim is treated as a
  guess. `quality.py` + `adapters/quality/`, `review.run_plan_compliance`. See
  `backlog/double-gate.md`.
- `[agent] max_parallel` — how many agent subprocesses may run **at once across the whole
  install** (default 4; `0` = unlimited). Over-cap runs wait as `AgentRunStatus.queued` and
  start as slots free up. A resource guard (the `max_budget_usd`/`cost_warn_usd` pair bounds
  *spend*; this bounds the machine). See `runner._spawn_slot` +
  `backlog/agent-session-lifecycle.md` §5.
- `[editor] nvim` — the code step's Neovim option: `auto` (default — the user's own
  `~/.config/nvim`, else bundled LazyVim), `byo`, or `bundled`. See `terminal.spawn_editor`.
- `[roles]` — **workflow roles** (off by default, `notes/workflow-roles-plan.md`): give each
  step of the plan→scout→build→refute loop its own `"model:effort"` (`plan`/`build`/
  `review`/`scout`), so approving a plan can't silently build at the plan's (pricier) model —
  `start_agent` resolves explicit `req.model` > this run's role > `[agent] default_model` >
  `"sonnet"`. The composer shows a role strip instead of the model/effort pickers when on.
  Phase 1 (config + resolution + strip), Phase 2 (a read-only `scout` sub-agent
  injected via `--agents` when `[roles] scout` is set, delegation rows in the stream),
  and Phase 3 (the refuter: an independent, read-only re-check of a green gate's diff
  against the task/plan, `review_enforce = "warn"|"block"`, a bounded review-fix loop
  under "block", `Workspace.plan_text`) are all done. See `backlog/workflow-roles.md`.
- Env vars for scripts: `HARO_PORT`, `HARO_WORKSPACE_PATH`, `HARO_ROOT_PATH`

## Planning docs (read before making product decisions)
> ⚠ **The roadmap above is a lagging summary — it goes stale.** Before concluding a feature is
> unbuilt (or scoping a "new" one), grep the `backlog/*.md` files (the project's backlog folder;
> these were the old root `todo-*.md` docs): they are the
> granular, **checkbox-tracked (`[x]`/`[ ]`) source of truth** per feature area, and they win over
> the roadmap prose when the two disagree. E.g. files-to-copy, multiple run scripts,
> and user-global settings all read as gaps in older prose but are `[x]` done in
> `backlog/project-config.md` (the "Config parity" section). Skim the relevant `backlog/*.md`
> first — grouped roughly as: gate (`backlog/gate.md`, `backlog/double-gate.md`, and the round-2
> trust-ladder specs: `backlog/tamper-alarm.md`, `backlog/autonomy-ladder.md`,
> `backlog/verified-hunks.md`, `backlog/winner-fanout.md`, `backlog/merge-firewall.md`), project/config
> (`backlog/project-config.md`), git/PR (`backlog/project-git-sync.md`, `backlog/team-pr-flow.md`,
> `backlog/github-issues-backlog.md`), cockpit/UI (`backlog/cockpit.md`, `backlog/code-editor.md`,
> `backlog/ui.md`, `backlog/mobile-view.md`, `backlog/bulk-archive.md`), and cross-cutting (`backlog/cost-guardrails.md`,
> `backlog/brand.md`, `backlog/linux-attraction.md`, `backlog/skill-maintenance.md`).
- `CHANGELOG.md` — ⭐ **current truth**: every shipped change, versioned `0.1.0` → current
  (Keep a Changelog format). Update its `[Unreleased]` section as we ship.
- `notes/desync-hardening-plan.md` — **active hardening backlog** (4 tasks): the reconciliation
  mechanism + remaining crash-safety work; written as hand-off specs for in-platform agents.
- `notes/product-spec.md` — **master doc**: positioning, stack, data model, API, roadmap
- `notes/conductor-baseline-spec.md` — verified table-stakes to match (from deep research)
- `notes/differentiation-bets.md` — the bets + post-research verdicts
- `notes/differentiation-bets-round2.md` — **2026-07-22 round-2 bets (Bets 8–12, the "trust
  ladder":** tamper alarm → autonomy ladder → verified hunks → winner-only fan-out → merge
  firewall), judge-ranked, plus benched ideas + anti-roadmap; raw market research (Conductor
  status, rival landscape, pain ranking, platform-absorption risk) in `notes/market-recon-2026-07.md`
- `notes/vitest-visualizer.md` — flagship feature concepts + build order
- `notes/claude-code-stream-json.md` — **build reference**: exact `claude --output-format
  stream-json` event schema, verified against v2.1.204. Read before writing `ClaudeCodeAdapter`.

## Layout
- `backend/` — Python + FastAPI. `haro/main.py` (REST + WS), `adapters/`
  (`AgentAdapter`+`ClaudeCodeAdapter`; `test_runner/` = `TestRunnerAdapter`+`VitestAdapter`
  + `vitest_reporter.mjs`, a custom Vitest reporter emitting NDJSON per test-case for the live grid),
  `git_ops.py`, `runner.py` (agent→gate handoff), `gate.py` (test gate + `ensure_deps`),
  `integrate.py` (commit→merge/`gh` PR→archive), `hub.py` (multiplexed pub/sub),
  `store.py` (in-memory), `models.py`, `config.py`.
  Deps in `requirements.txt`; run `.venv/bin/python -m uvicorn haro.main:app` with `PYTHONPATH=.`.
  **Primary (and only) runtime is `./run.sh`** on the host (boots both servers + opens the app
  window). Backend runs **WITHOUT `--reload`** (it supervises long-lived agent subprocesses — a
  reload would kill them; a merge writing the source tree used to trigger exactly that). Pick up
  code changes with an intentional restart.
  Persistence: `db.py` (aiosqlite) snapshots the store to a single SQLite file at `$HARO_DB`
  (default `~/.haro/haro.db`) + hydrates on boot; `_hydrated` guards against wiping un-loaded tables.
- `backend/haro/analytics.py` — on-demand "smart" insights (coverage delta + flaky),
  kept out of the merge-gate path.
- `backend/haro/terminal.py` + `Terminal.tsx` — embedded shell per workspace (PTY over
  `/ws/workspaces/{id}/terminal` ↔ xterm.js), a card below the gate. **Product vision: haro
  is the one window a dev works in — no alt-tabbing.** Fit the terminal after `fonts.ready` so the
  PTY winsize matches (else zsh leaks its reverse-`%` EOL mark).
- `frontend/` — React + TS + Vite. `src/App.tsx` orchestrates state + routes WS channels;
  `components/` (`Sidebar` = projects→workspaces navigator, `AgentStream`, `DiffView`,
  `GatePanel` = the ③ verify verdict-first page (`verdict.ts` is its derivation layer),
  `LookAt`/`LookAtChip` = the "things to look at" zone + rail deep-link, `ImpactMap`,
  `ReviewPanel` = comment round-trip); `api.ts`
  (REST + WS); Vite proxies API/WS to `:8000`. Layout is a bento: sidebar · stream+composer · gate+diff.
- **WS envelope:** every message is `{channel: "agent"|"test"|"status", …}` — the UI routes by channel.
  The `test` channel carries `kind: "run_started"|"cell"|"snapshot"` (live grid cells + final result).
  The **`watch`** channel mirrors that shape for the Live Gate's advisory run — a *separate* channel
  on purpose, so an advisory verdict can never overwrite the authoritative grid's state.
- **Gate dep stopgap:** `gate.ensure_deps` symlinks the project's `node_modules` into the
  worktree before running Vitest (worktrees are gitignored-deps-free). v2's `[scripts] setup`
  hook replaces this.
- See `README.md` for run instructions. Test sandbox repo: `/home/deprecated/Projects/synthesis-sandbox`.
- **Desktop launch:** `./run.sh` boots both servers + opens a chromeless Chrome `--app` window
  (feels native, zero packaging). `haro.desktop` pins it to the app launcher. **Decision:**
  stay on app-mode for now; wrap in **Electron** (not Tauri) only once we're satisfied to ship.

## Conventions
- **Backend:** `from __future__ import annotations`; async everywhere (subprocess via
  `asyncio.create_subprocess_exec`); pydantic models in `models.py`; module-level
  docstrings explaining the *why*. Keep the two adapter seams clean — the UI only ever
  sees the 5 normalized event types (`token|tool_call|file_edit|done|error`).
- **Frontend:** function components + hooks; mirror backend shapes in `types.ts`;
  minimalist "coder vibe" (mono accents, one accent color). CSS lives in topic
  partials under `frontend/src/styles/`, `@import`ed in cascade order by the
  `styles.css` barrel — edit the partial for a surface, not one giant sheet.
- Prefer local, on-device operations; never introduce broad cloud permissions without asking.
