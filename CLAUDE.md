# haro

haro is a **local-first, Linux-first workbench for developers who stay the author of their code**.
Every task runs in its own **git worktree**. You write it yourself in **manual mode** (the agent is
hard-disabled and haro's assistant can only read), or hand it to an agent you can **fence** to the
files you name. Either way the **receipt** says who wrote what, and no work is mergeable until its
tests pass. It also runs several agents in parallel, but that is table stakes, not the point. It is
inspired by prior-art macOS-only orchestrators (Conductor and others) but is not a clone.

## North star
> You stay the author. haro lets you keep the agent inside what you handed it, and tells the truth
> about who wrote what.

**Strategic stance (reset 2026-10-07).** The test gate used to be the headline ("the gate is the
whole point"). The dogfooding and a five-source research pass (`notes/usp-research-2026-10.md`)
changed that: skill and craft loss is the loudest demand, review is the biggest pain, free
standards already cover AI-authorship labels, and nobody was found paying for any of it. So:
Conductor optimizes how many agents you run; haro optimizes whether you still understand what
ships and how much of it the agent was allowed to touch. The gate stays as a quiet automatic safety
net, not the pitch. `backlog/now.md` ("Direction") is the live statement of this.

**Keep every claim bounded.** The receipt describes what happened inside haro. It cannot see
another AI tool open beside it, so never write "no AI wrote this" or "proof": write "AI edits: 0
inside haro" or "the agent was fenced to X". The fence is opt-in (an empty Scope box means no
fence). A file edited by hand during an agent run counts as the agent's.

## What makes it distinctive
1. **Manual mode with the agent hard-disabled.** The agent endpoints answer 409; the assistant (Plan,
   Search, Docs) is read-only, and haro diffs the worktree before and after every answer, so "AI
   edits: 0" is checked, not asserted.
2. **The scope fence.** A per-run list of paths the agent may edit, enforced on the result (a
   worktree snapshot, then put back whatever fell outside), not on the agent's tools, because its
   shell bypasses tool rules. It covers follow-up runs and the test-first build run too.
3. **An honest receipt.** "Written by" credits the files you edited by hand, in any editor, and
   names its own limits.
4. **The gate as a safety net.** Local, automatic, pre-push: the tamper alarm, Verified Hunks and
   merge-blocked-unless-green. Vitest first, pytest and any command too.
5. **Local-first, minimal permissions.** Drives local git, optional `gh` with the user's own creds,
   no broad GitHub OAuth. **Linux-first** is true but no longer unique (Orca, Emdash, Paseo and T3
   Code ship on Linux), so it is a fact, not a headline.

Multi-agent support is **table stakes**, not a differentiator (the incumbents are already multi-agent).

## Tech stack
- **Backend:** Python + FastAPI + asyncio (subprocess supervision + WebSocket streaming)
- **Frontend:** the **Flutter desktop client in `app/`** (`app/CLAUDE.md` covers it). The React `frontend/` was deleted 2026-10-07; its last state is `git show 7158a68:frontend/<path>`. The old `desktop/` shell is gone too.
- **Packaging:** the Flutter desktop client in `app/` (macOS + Linux) with the frozen backend bundled inside (`scripts/build-macos.sh`, `scripts/build-linux.sh`); `./run.sh` is the dev path (backend + `flutter run`)
- **Git:** local git CLI + worktrees; optional `gh` CLI for PRs (no OAuth)
- **Aesthetic:** the **Kuro/ryoku brand theme** (trademark, single theme, **dark-only** — the
  light toggle was removed in the 2026-09-02 pivot) — warm monochrome bone ink
  (`rgb(205,196,186)`) on near-black (`#0b0a09`), Swiss grid + Japanese restraint, hairline rules
  and 2px corners, no shadows, film grain (`styles/dossier.css`); no Japanese characters in functional UI
  (decoration is for the landing page only). Green (`--accent`) is reserved for the
  test gate only — everywhere else (buttons, focus rings, meters) is bone/ink. Type: Fraunces
  (display/wordmark) + Space Grotesk (UI/prose) + Space Mono (mono/prompt/code default),
  self-hosted TTFs bundled in `app/assets/fonts`. All colors and type flow through the tokens in
  `app/lib/theme/tokens.dart`. `brand/dither.py` (Floyd-Steinberg or `--ordered` Bayer, reproducible) is
  available for a future image accent but isn't wired to anything shipped today. Motion: ink arrives,
  objects do not move (`notes/kuro-motion-plan.md`). See `notes/kuro-theme-plan.md`.

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
    cached; needs a green base).
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
  - ✅ **Task flow** — main column is a stepper `① agent › ② code › ③ review › ④ ship` (live state
    badges), not loose tabs. You work one step at a time: **only the current step is clickable**
    (the others are dimmed) and **Proceed to <next>** / **Back to <previous>** move you (2026-10-09,
    `state/workflow.dart`; step 3 is shown as "review", its key and route stay `verify`). Proceed never
    starts the gate: it is started from review. The workflow made visible; the gate is step ③ on the
    main stage, so the flow literally resolves on the green gate before ④ ship.
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
  path, not deleted. See `brand/` (`dither.py`) and `notes/kuro-theme-plan.md`.
- ~~**Winner-only fan-out**~~ (Bet 11, `backlog/winner-fanout.md`) **removed 2026-09-30**, backend included
  (`race.py`, `fanout.py`, `[race]`, the `/races` endpoints, the `races` table). An old `races` table in
  `~/.haro/haro.db` is ignored. History lives in the backlog file and CHANGELOG.
- **v3** — merge queue · spec-driven fan-out · cost/token metrics · round-2 trust-ladder
  bets (Bets 8–12 — see `notes/differentiation-bets-round2.md` + their `backlog/*.md` specs)

## Config convention
- `.haro/settings.toml` (committed) + `.haro/settings.local.toml` (gitignored)
- `[scripts]` lifecycle hooks: `setup` / `run` (multiple named `[scripts.run.<id>]`, each with an optional `url` where the app answers when it does not use `$HARO_PORT`, http or https only) / `archive` + `run_mode`
- `[files] include` — glob list of gitignored files copied into each new worktree (the
  "Files to copy" convention; default `[".env*"]`). Secrets live in `.haro/.env` (the Environment tab), seeded
  separately. See `config.copy_worktree_includes` / `seed_worktree_env`.
- `[gate] auto_run` (off by default since 2026-10-09): start the full gate by itself when an agent run
  finishes. Off, the gate is the step you start from review (a full gate after every stop is slow on a big
  project). `StartAgentRequest.run_gate_on_done` (optional) overrides it per run; a test-first build run
  always gates; auto-fix rounds and the auto-PR rung only happen with the automatic gate.
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
- `[gate] secrets_scan`: the **advisory secrets scan** (on by default; the `[quality]` Double
  Gate and plan compliance were cut 2026-09-29, the gate is fully deterministic and old
  `[quality]` keys are ignored). On a passing full-scope gate, gitleaks (`--redact`, diff-scoped)
  adds `secret_found` rows to "code to check". Never affects green/red, never degrades a run,
  never blocks a ship; a missing gitleaks is silently skipped. `secrets_scan.py`.
- **Project pull settings** (no config key; per-project, stored on the project row in SQLite, edited in the dashboard's Projects table): `Project.auto_pull` (default on) lets the background `project_sync` poll and the after-merge sync fast-forward the checkout; `Project.pull_branch` (empty = default branch) is the branch it keeps level with `origin`. `POST /projects/{id}/sync` ("Pull now") ignores `auto_pull`. `PUT /projects/{id}/pull-settings`. See `project_sync.py`, `app/lib/features/triage/projects_table.dart`.
- **Merge train**: no key of its own: with `[gate] merge_result` on, `POST /projects/{id}/merge-queue`
  gates each candidate on (base after earlier landings + candidate), full scope, and lands only green
  ones; a red one is blocked "red on merged base". `merge_queue.GateCheck` is injected. A dry run never gates.
- `[agent] max_parallel` — how many agent subprocesses may run **at once across the whole
  install** (default 4; `0` = unlimited). Over-cap runs wait as `AgentRunStatus.queued` and
  start as slots free up. A resource guard (the `max_budget_usd`/`cost_warn_usd` pair bounds
  *spend*; this bounds the machine). See `runner._spawn_slot` +
  `backlog/agent-session-lifecycle.md` §5.
- `[agent] auto_open_app` (off by default): when the agent runs `haro-app open /path`, the client opens that page in the
  browser at once instead of only offering it in the rail's APP row (`Agent suggests /path`, Open ↗, dismiss). The address is
  always the run's own origin plus the path. Only for a suggestion that arrives while the workspace is open. See
  `main.run_open`, `rail/workspace_rail.dart`.
- `[scripts.tools.<name>]`: a command the agent may run with `haro-app do <name>`: `command` (required), `description`,
  `timeout` seconds (default 300, max 1800). Runs in the worktree like the setup script, output streamed to the Dev log, the
  last 40 lines returned, the process tree killed on timeout. No arguments: the repo declares what the agent may run.
  Merged across the user, committed and local layers like `[scripts.run.<id>]` (a higher layer's `tools` table replaces the
  lower one's). The declared names go into the run's instructions when the agent has `haro-app`. See
  `config._parse_tools`, `lifecycle.run_tool`, `POST /workspaces/{id}/tools/{name}` (one at a time per tool, never under the gate).
- `[agent] ignore_user_claude_md` (off by default): add `claudeMdExcludes` for the developer's own
  `~/.claude/CLAUDE.md` (or `$CLAUDE_CONFIG_DIR/CLAUDE.md`) to the run's inline `--settings`, so what governs a run
  is the project's CLAUDE.md and haro's instructions, not personal rules for other projects. The project CLAUDE.md,
  skills and the login are untouched (`--setting-sources` does not do this; tested on CLI 2.1.296).
- `[agent] command_guard` (on by default): the agent's Bash and Read calls go through the same PreToolUse hook as the
  fence (`scope_fence.judge` -> `command_guard.refusal`) and a match on a short list is refused before it runs:
  `git reset --hard`, `git clean -f`, `git checkout .`, `git push --force`, `rm -r` on the worktree, `.git`, home or
  a path outside it, and reading `.env`/key files, `printenv`, `echo $TOKEN`. A text match and a speed bump, never a
  guarantee (the shell can reach the same files another way); labels land on `AgentRun.guard_refused`, the stream and
  `Receipt.guard`. The net under it is the **restore point**: every non-plan run pins its start snapshot as
  `refs/haro/start/<workspace>/<run>` (`restore_point.py`, newest 10 kept) and
  `POST /workspaces/{id}/runs/{run}/restore-start` puts the files back (the current state is kept under
  `refs/haro/before-restore/` first; files only, commits stay). Verified with the real CLI 2.1.296 that the hook
  fires for Bash and Read and a deny stops the call. `Receipt.new_dependencies` (`new_dependencies.py`) lists names a
  changed `package.json`/`requirements*.txt`/`pyproject.toml` has now and the base did not, no registry asked.
- `[agent] protect_tests`: `"off"` (default) | `"existing"`: deny the agent's Edit/Write/MultiEdit/NotebookEdit
  tools on every test file tracked at `base_ref` (new test files stay writable); per-run override on the
  start-agent request. A speed bump, NOT a guarantee (the agent's shell can still write a file, never call
  the tests "read-only"): the tamper alarm on the diff stays the actual check, and a protected run is
  labelled on the gate note and the receipt. See `protect_tests.py` + `backlog/protected-tests.md`.
- **Scope fence** (no config key; per-run composer field / `StartAgentRequest.scope`, off unless set): a list of
  paths or globs the agent may edit; reading stays free. Two layers. Early warning: the run's `--settings` carries
  a PreToolUse HTTP hook on Edit, Write, MultiEdit and NotebookEdit that posts to `POST /hooks/fence/{run id}`
  (`scope_fence.judge`, same matcher as the revert), so an out-of-fence edit is refused BEFORE the write with a
  reason the agent reads; refusals land on `AgentRun.fence_blocked` and `Receipt.scope.blocked` ("N blocked files").
  Needs `settings.api_url` (desktop app or `HARO_API`); without it, or if haro is unreachable, the hook is simply
  absent or fails open. The real check, because the agent's shell bypasses hooks and deny rules, is on the RESULT: `scope_fence.snapshot_tree` takes a git tree of the worktree (tracked + untracked, not
  ignored, via a throwaway copy of the index) before the agent starts, and in `runner._drive_agent`'s `finally`
  (done, error and a user stop alike) `scope_fence.enforce` diffs against it and puts back every path changed
  outside the fence: added files are deleted, modified or deleted ones restored from the START snapshot (so the
  dev's own uncommitted stubs survive; never HEAD). The run's end state is kept at `refs/haro/scope/<run id>`
  before anything is reverted. Fails closed: a fence that cannot be armed never starts the agent, and a check
  that fails says so (`AgentRun.scope_error`, receipt "could not check"). Plan runs and test-first drafts are
  not fenced; auto-fix rounds inherit the fence. A concurrent edit by the dev in a fenced-out file during the
  run is reverted too (the backup ref covers it). Receipt: `Receipt.scope`. See `scope_fence.py`,
  `tests/test_scope_fence*.py`, `backlog/now.md`.
- **Test-first tasks** (no config key; per-run composer option / `StartAgentRequest.test_first`, off unless
  chosen): the agent drafts only a failing acceptance test, haro proves it red, the dev approves it, the
  build runs with that file edit-denied, and the gate blocks the merge (whatever `tamper_alarm` says)
  unless every approved case is present and passing and each approved file's hash is unchanged. State on
  `Workspace.test_first`; `acceptance.py`, `POST /workspaces/{id}/test-first/approve`. See `backlog/test-first.md`.
- ~~`[editor] nvim`~~ **removed 2026-09-30** (with the `/ws/workspaces/{id}/editor` Neovim PTY and the bundled
  LazyVim). "Open in... Neovim" (`POST /workspaces/{id}/open`) types the user's own `nvim` into the Shell tab.
  An old `[editor]` table in a settings file is ignored.
- `[roles]` — **workflow roles** (off by default, `notes/workflow-roles-plan.md`): give each
  step of the plan→scout→build→review loop its own `"model:effort"` (`plan`/`build`/
  `review`/`scout`), so approving a plan can't silently build at the plan's (pricier) model —
  `start_agent` resolves explicit `req.model` > this run's role > `[agent] default_model` >
  `"sonnet"`. The composer shows a role strip instead of the model/effort pickers when on.
  Phase 1 (config + resolution + strip), Phase 2 (haro's own sub-agents injected via `--agents`: a read-only `scout` when `[roles] scout` is set and a `code-review`
  (reviews the diff, reruns tests, never edits) when `[roles] review` is set, delegation rows in the stream),
  and Phase 3 (the code reviewer) are done, but the code reviewer is now ON-DEMAND only: the `review`
  role is the model behind `POST /workspaces/{id}/review` ("Review with AI"); the gate never
  calls it and `review_enforce` is a no-op. See `backlog/workflow-roles.md`.
- Env vars for scripts: `HARO_PORT`, `HARO_WORKSPACE_PATH`, `HARO_ROOT_PATH`. Agent runs for a project with a
  `run` script also get `HARO_RUN_LOG` / `HARO_LOG_DIR` (the app's output, `~/.haro/logs/<workspace>/`, `run_logs.py`)
  and `haro-app start|stop|restart|status [run]` on the PATH (`app_ctl.py`, `~/.haro/bin`; needs the backend's own
  address: `settings.api_url`, set by `desktop_app.py`, `HARO_API` under `./run.sh`; not offered to a plan run).
  Background shells and monitors the agent starts end with its turn.

## Planning docs (read before making product decisions)
> ⚠ **The roadmap above is a lagging summary — it goes stale.** `CHANGELOG.md` is the record of what
> shipped, and `backlog/now.md` is the only open-work list (reset 2026-10-05: the old per-feature
> `backlog/*.md` specs were mostly shipped and are in git history, e.g. `git show 5c9cb49:backlog/gate.md`).
> Older comments, notes and skills that say "see `backlog/<name>.md`" point at those historical files.
> Before concluding a feature is unbuilt, grep `CHANGELOG.md` and the code, not the roadmap prose.
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
- `app/` — Flutter desktop client (see `app/CLAUDE.md`). Layout is a bento: sidebar · stream+composer · gate+diff.
  The old React UI is gone (`git show 7158a68:frontend/src/api.ts` for its API client).
- **WS envelope:** every message is `{channel: "agent"|"test"|"status", …}` — the UI routes by channel.
  The `test` channel carries `kind: "run_started"|"cell"|"snapshot"` (live grid cells + final result).
  The **`watch`** channel mirrors that shape for the Live Gate's advisory run — a *separate* channel
  on purpose, so an advisory verdict can never overwrite the authoritative grid's state.
- **Gate dep stopgap:** `gate.ensure_deps` symlinks the project's `node_modules` into the
  worktree before running Vitest (worktrees are gitignored-deps-free). v2's `[scripts] setup`
  hook replaces this.
- See `README.md` for run instructions. Test sandbox repo: any vitest project; point `HARO_VITEST_SANDBOX` at it to run the real-vitest tests.
- **Desktop launch:** `./run.sh` starts a fresh backend and runs `flutter run` on `app/`. Release builds
  bundle the backend inside the app (`scripts/build-linux.sh`).

## Conventions
- **Backend:** `from __future__ import annotations`; async everywhere (subprocess via
  `asyncio.create_subprocess_exec`); pydantic models in `models.py`; module-level
  docstrings explaining the *why*. Keep the two adapter seams clean — the UI only ever
  sees the 5 normalized event types (`token|tool_call|file_edit|done|error`).
- **Frontend:** Flutter in `app/`; tokens in `app/lib/theme/tokens.dart`; minimalist "coder vibe"
  (mono accents, one accent color).
- Prefer local, on-device operations; never introduce broad cloud permissions without asking.
