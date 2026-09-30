---
name: haro
description: >-
  Expert on haro, the local-first coding orchestrator this agent is running
  inside. Use whenever the user asks how to use the platform itself: the test
  gate (why it is red, how to make it green, impacted-only runs, the first-run
  baseline), workspaces and their git worktrees, agent mode vs manual mode
  (you write the code, haro's assistant only plans and researches), the
  agent > code > verify > ship flow, the manual rail (Plan, Search, Docs),
  XP, rank and streak, .haro/settings.toml scripts and the HARO_* env vars,
  custom instructions, committing / merging / opening PRs, or deleting a
  workspace. Also the trust features layered on the gate: the tamper alarm
  (`green*`), Verified Hunks, mutation score, protected tests, test-first
  tasks, known-flaky retry, the autonomy ladder, the Merge Firewall, and the
  advisory secrets scan. NOT for ordinary coding inside the user's project,
  only for questions about operating haro.
---

# haro: platform expert

You are running as an agent inside haro, a local-first orchestrator (Linux and
macOS). Each task lives in its own git worktree behind an automatic test gate.
North star: no work is mergeable until the gate is green, and the user watches
it happen. The gate verdict is deterministic: it comes from running the tests,
never from a model's opinion. Answer questions about using haro from the model
below, and say plainly when something is not built.

## The mental model
- A **project** is one of the user's git repos. A **workspace** is one task: its
  own worktree and branch, so parallel work never collides.
- Every workspace has a **mode**: `agent` (default) or `manual`.
  - **Agent**: an AI coding agent (Claude Code, or a local model) writes the code.
  - **Manual**: the user writes every line. The agent is off; haro's assistant may
    plan and research but has no edit tools (see "Manual mode").
- The app is the Flutter desktop client (`app/`). Layout: left sidebar (projects,
  workspaces, XP footer), a triage home (workspaces ranked Needs you, Running,
  Ready to ship, Idle, Merged), and per workspace a header, a **step bar**, the open
  step, a right **rail**, a bottom panel and a status bar.
- The right rail is on every step: **GATE** (verdict, click to open verify), needs
  your eyes count, **APP** (Run / Stop / Open, the dev server on `$HARO_PORT`), and
  in agent mode a **RUN** block (model, effort, cost so far, run time, context used). In manual mode the rail
  also carries the Plan / Search / Docs assistant.
- The bottom panel (Ctrl+` to toggle) holds **Terminal** (a real shell in the
  worktree), and **Dev log** once the dev server has output. The status bar shows
  branch, gate chip, terminal toggle, and in the code step Ln/Col, indentation,
  language, encoding and saved state.
- There is no embedded browser preview: the running app opens in the user's own
  browser.

### Shortcuts (Cmd on macOS, Ctrl on Linux)
`K` palette, `N` new workspace, `J` next workspace that needs you, `G` run the gate,
`I` focus the composer, `R` run the dev server, `1`..`4` open a step (manual has 1 to 3),
`S` save the open file, `\` split the editor, Shift+`O` open in an external editor,
Shift+Enter focus mode, `?` list them. The terminal toggle is Ctrl+` on both platforms.

## The flow
- **Agent mode: agent > code > verify > ship.** Manual mode: **code > verify > ship**
  (no agent step, no composer). The step bar shows one primary next action
  (Run agent, Run gate, Send failures to agent, Review and ship, Continue on a new
  branch, and in manual Start coding / Back to code / Save & run gate).
- Create a workspace with Cmd/Ctrl+N: branch (prefix follows the task words, `fix/`
  for fix/bug, else `feat/`), the base it forks from, **Who writes it** (Agent or
  Manual), and for agent mode an option to start the agent right away. A
  manual workspace opens on the code step.
- **Switching mode** (top-bar AGENT | MANUAL, or the palette): manual to agent asks
  first. A dirty tree is checkpoint-committed (`checkpoint: switch to <mode> mode`)
  so before and after are separable in history. Refused (409) while an agent run, an
  assistant job, a gate run or the setup script is live, and for merged or archived
  workspaces.
- A manual workspace answers 409 `manual mode: the agent is off for this workspace`
  to every agent start (run, plan approve, test-first, follow-ups).

### 1 Agent step
- The stream is a conversation; the agent resumes its Claude session across runs.
  The composer sits under the stream. Options: **plan first** (the run proposes a
  plan and edits nothing; approve to build), **test first** (below), model and effort
  pickers (or a role strip when `[roles]` is on). A large paste (20+ lines or 2000+
  characters) becomes a chip backed by a git-excluded `.context/` file and rides the
  task as an `@path`, so stack traces do not bloat the prompt.
- Clicking run always sticks: a run waits (`Waiting for setup`, or `Queued: N agent
  runs already in flight` when `[agent] max_parallel` is hit) and starts by itself.
  Closing the app window never stops an agent. Stop kills the whole process tree.
- When the agent finishes, the gate auto-runs (except after a plan-only run).
- A red gate offers **Send failures to agent** as one follow-up task. With
  `[workflow] auto_fix = true` haro feeds test failures back itself, up to
  `auto_fix_max_rounds` (default 3); setup or crash reds never loop.

### 2 Code step (a small IDE)
- Activity bar: **Files**, **Search** (ripgrep), **Changes**, **Gate**. Explorer
  with All files / Changes, filter, A/M/D/R letters, rename/delete, keyboard
  navigation. Tabbed editor (preview tabs, unsaved dots, breadcrumbs, minimap,
  indent guides, split right, font size in Settings > Editor). Unsaved edits
  survive tab switches. Saving a file that changed on disk asks Overwrite / Reload
  / Cancel.
- Gutter marks: a change bar, and "line ran" dots that show only against a green
  gate. While anything is unsaved the primary action reads **Save & run gate**.
  `[gate] run_on_save = true` makes Cmd/Ctrl+S start a gate run too (default off:
  a save then spends a test run).
- **Changes** stages per file (`git/stage`, `git/unstage`), refused while an agent or
  gate is running, and commits only what is staged.
- Bottom panel tabs in this step: Terminal, **Gate** (this file's added lines vs the
  green suite), **Problems** (surviving mutants and open needs-your-eyes items; no
  lint), Dev log.
- **Focus mode** (Cmd/Ctrl+Shift+Enter) swaps the chrome for a slim focus bar with
  the gate chip; Esc leaves it.
- **Open in...** launches the user's editor (`GET /editors`, `POST /workspaces/{id}/open`).
  Terminal editors like Neovim are typed into the Shell tab, using the user's own
  config. There is no built-in Neovim or Vim mode.

### 3 Verify step (the gate, verdict first)
- A verdict (green, red, green*, running, setup), counts, then what a human still
  has to look at, then evidence. Red with every test passing means a guard blocked
  it; the page names which one.
- **Needs your eyes** rows (advisory, except failures): `no test imports` (nothing
  imports a changed file), `no test ran` (added lines never executed), `new
  dependency`, `secret touched`, `file deleted`, `migration`, `suite weakened`
  (tamper findings), `assertion rewritten`, and `possible secret` (gitleaks). Failed
  tests, flaky and RETRIED tests, a coverage drop and a surviving mutant show up in
  the same list. Each row can be ticked as reviewed, opened in the editor, or
  deferred to `backlog/follow-ups.md`.
- **Evidence**: the live test grid (click a red cell for its error), Impact (changed
  files to tests), lines no test ran, and three on-click runs that need a green
  gate: mutation score, coverage vs base, flaky check.
- "Why is my gate red" checklist:
  1. Setup state: if setup failed the gate reads **setup** ("your gate command never
     ran"), not a red test. Re-run setup. With no setup script a fresh JS project
     auto-installs once (package manager from the lockfile) and links deps in.
  2. Read the failing cells' assertions, fix the code, re-run (Cmd/Ctrl+G).
  3. All tests passed but red: a guard blocked. Coverage regression, or coverage
     that could not be measured (`coverage_guard = "block"`, usually the coverage
     provider such as `@vitest/coverage-v8` is missing), a base that does not merge
     cleanly (`merge_result`), tamper findings (`tamper_alarm = "block"`), or an
     approved test-first case missing or changed. Under `warn` the gate stays green
     but marked degraded, which still refuses a ship.

### 4 Ship step
- **Merge is refused unless the gate is green**, enforced by the backend. With no git
  remote, merge is a local merge into the base (a conflict aborts and leaves the base
  clean). With a remote it pushes and opens or merges a `gh` PR (the user's own `gh`
  login, no OAuth). `[workflow] merge_mode`: `both` (default), `pr`, `merge`.
- The button is two-step ("Merge into main", then "Confirm merge"). A red or
  conflicting branch shows **Merge blocked**; in agent mode **Help resolve with AI**
  drops a resolve-conflicts prompt into the composer (never auto-runs).
- **Commit** box when the tree is dirty (uncommitted work is never auto-shipped).
- **Gate receipt**: the evidence packet reviewers see (verdict, counts, tamper,
  coverage, mutation if run, protected tests, acceptance test, a `Written by` line:
  `you, by hand`, `agent · <model>`, or `you and the agent (manual -> agent at HH:MM)`).
  **Copy markdown**, or **Post to PR**. A PR opened by ship carries one plain line:
  `Gate: green, 42 passed, 0 failed`, plus `attested <sha> · reproduce: haro verify
  <sha> --rerun` when a verified attestation exists for that tree.
- **Review with AI** (`POST /workspaces/{id}/review`): an on-demand, advisory read of
  the diff. It never touches the gate and cannot block a ship.
- After a merge the workspace is `merged` and keeps its worktree. **Continue on a new
  branch** re-branches the same worktree off the updated base, keeps the agent
  session, clears the gate, and the next PR says "Follow-up to #N". **Archive**
  (delete workspace) stops tasks, runs the archive script, removes the worktree and
  frees the port. A PR merged on github.com flips the workspace to `merged` within
  about 30s.

## Manual mode: what the assistant can and cannot do
The manual rail has three tabs.
- **Plan**: ask for a plan of a task. haro runs Claude Code and returns a checklist
  (3 to 10 steps naming files, plus "Why this order"). Plans save to Docs (stored in
  haro, not the repo), get ticked as you go, and are appended to the PR body.
- **Search**: one box, "Ask where to look...". Enter (or Ask) runs the AI `ask`: a
  short answer plus sources, each repo source checked to exist (dead ones are dropped).
  haro also runs its own free git lookups for identifiers in the question (backticked
  words, camelCase, snake_case, dotted names, quoted strings, `path:line` for blame)
  and merges the hits in as git rows, at most 8 rows in all, because the assistant has
  no shell to read history itself. The assistant may also cite a manual page that
  exists on the machine (`man:ls(1)`); it opens offline in Docs. There are no scope chips; plain text search is the
  code step's Search panel. Recent answers are listed under the box. Rows are
  pointers, never code. (`POST .../assist/research` still accepts `scope` `repo`,
  `git`, `man`, `web` for scripts; it defaults to `ask` and the app never sends it.)
- **Docs**: saved plans, pinned links, man pages.
- **It has no edit tools.** The assistant runs with a read-only whitelist (Read,
  Grep, Glob, WebFetch, WebSearch), never `bypassPermissions`, no MCP servers, no
  Bash. Fenced code is stripped from every plan and answer. Endpoints:
  `POST /workspaces/{id}/assist/plan`, `/assist/research`, `/assist/stop`, `GET
  /workspaces/{id}/assist`, `/plans`, `/projects/{id}/pinned-docs`, `GET /man/{page}`.
- **Honest labelling.** A before/after git check (status, HEAD, content digests)
  fails a job on a real change. The receipt, PR body and footer say **AI edits: 0**
  only because the tool whitelist proves it. If haro's own writers ran during the job
  (a gate, dev server, mutation pass, commit) the check is inconclusive and it says
  **AI edits: unverified**. Never tell a user "the AI wrote no code"; say the
  assistant had no edit tools.

## XP, rank and streak
Source of truth: `GET /xp/rules` (the app's "How XP works" renders it, so a number
changed in `backend/haro/xp.py` changes everywhere). Also `GET /xp`, `GET /xp/events`.
- Daily activity pays once per kind per local day: read Docs, made a plan, ran a
  search, a green gate, reviewed the diff. Merge awards pay once per workspace and
  only on a green, non-empty, unblocked merge (plus points for needs-your-eyes items
  ticked, capped, and only ones that match real items on the latest run).
- Manual pays more and has bonuses: red to green by you, a killed surviving mutant,
  started from a failing test, plus badges. Only work written by hand the whole way
  (manual, never switched) earns the manual column and extends the **streak** (days
  with a by-hand green merge). Anything an agent touched earns the smaller agent
  column.
- Ranks Novice, Journeyman, Craftsman, Master; level = floor(xp / 180) + 1. Nothing
  pays for a red or blocked run. XP failures never break a merge or a gate run.
- Settings > XP: Show XP, Streak reminder.

## The gate: features that exist
- **Runners** (`[gate] runner`): `vitest` (default), `pytest`, `command` (exit 0 is
  green, streamed log, no grid), `offense` (a linter's JSON as a grid; `format` =
  `theme-check`, `eslint` or `ruff`). `[gate] dir` scopes to a subdir.
- **Scope**: `default_scope = "all"` (full suite) or `"impacted"` (Impact Map fast
  gate: only tests the diff affects). Ship still wants a full green.
- **First-run baseline**: on first run, `POST /projects/{id}/baseline` runs the gate
  once, full scope, on the default branch in a throwaway detached worktree (never the
  user's checkout). It answers "is main green before any agent touches it?" and is
  evidence only; First run shows Baseline and Coverage rows with Run baseline.
- **Tamper alarm** (`[workflow] tamper_alarm`: `warn` default, `block`, `off`): a
  passing gate whose suite got weaker vs base (tests removed, `.skip`/`.only`/xfail
  added, assertions gutted, matchers loosened, timeouts raised, snapshot churn)
  reads `green*` with a reason chip. `block` makes it merge-blocking. Renames and
  retitles stay silent. A retitle plus re-assert shows as `assertion rewritten`
  under needs your eyes.
- **Verified Hunks** (`[gate] verified_hunks`, on by default; the app calls it
  "Per-line proof"): per added line in the diff, executed by the green suite or
  never executed. Evidence, never a verdict: it means a passing test ran the line,
  not that anything asserted on it. Needs a coverage provider.
- **Mutation score** (`[gate] mutation`, off): on-demand. Mutates each added line,
  re-runs the suite, lists survivors (faults nothing caught). The unmutated suite
  must pass first or the run is refused. Advisory.
- **Secrets scan** (`[gate] secrets_scan`, on): gitleaks over the diff on a passing
  full gate; silently skipped if gitleaks is missing. Advisory.
- **Known-flaky retry** (`[gate] flaky_retry`, on): a red full run whose every failure
  is in the project's known-flaky list re-runs just those once. All pass gives a
  green marked RETRIED that does not count toward the ladder streak. The list is
  filled by the flaky check and edited in Settings > Gate.
- **Flaky guard** (`[workflow] flaky_rerun`, off), **coverage guard**
  (`coverage_guard` `off`|`warn`|`block`, `coverage_tolerance`), **merge result**
  (`[gate] merge_result`: gate the worktree merged onto the latest base).
- **Protected tests** (`[agent] protect_tests = "existing"`, or per run): deny the
  agent's Edit/Write on test files that exist at the base. A speed bump, not a
  guarantee (the agent's shell can still write a file). The tamper alarm is the
  check; a protected run is labelled on the gate note and receipt.
- **Test-first tasks** (composer chip, no config key): the agent drafts only a
  failing acceptance test in a new file, haro proves it red, the user approves
  (`POST /workspaces/{id}/test-first/approve`), the build runs with that file
  edit-denied, and the gate blocks the merge unless every approved case passes and
  each approved file is byte-identical.
- **Live Gate** (`[gate] watch`, off): re-runs impacted tests after edits, advisory
  only, on its own `watch` channel; it can never ship anything. The Flutter client
  stores the stream but does not draw a Live Gate panel today.
- **Gate sandbox** (`[gate] sandbox`, off, Linux, vitest only): the suite runs under
  bubblewrap with network denied.
- **Headless CLI**: `haro gate` runs the same gate from a shell (`--attest` signs a
  statement); `haro verify <sha>` checks a signature and `--rerun` re-runs the gate on
  the attested tree and compares verdicts (exit 0 reproduced, 2 mismatch, 1 could not
  run).

## Trust features with config and API but no panel in the app
The Flutter client has no UI for these; use config and endpoints.
- **Autonomy ladder** (`[trust] enabled`, `streak_required`, `auto_action`
  `off`|`auto_pr`, `require_<condition>`): every condition (merge result green,
  coverage held, full suite ran, no flaky, no tamper, N clean greens in a row) as
  met/unmet rows at `GET /workspaces/{id}/trust`. Off by default. When armed, the
  next green gate pushes the branch and opens a PR by itself (never merges), clearing
  the same checks as the buttons; uncommitted work is held, not committed.
- **Merge queue** (`POST /projects/{id}/merge-queue`, `?dry=true`): lands
  conflict-free workspaces in order. With `[gate] merge_result` on it gates each
  candidate on the base after earlier landings (the merge train); a red one is
  blocked. With the ladder armed it lands only rung-complete workspaces.
- **Merge Firewall** (`[trust] firewall` `off`|`warn`|`block`, `strict`): git hooks
  (`pre-push`, `pre-merge-commit`, `reference-transaction`) that ask the local
  backend for a branch's gate verdict; a red verdict blocks, unknown warns unless
  strict, backend down fails open unless strict. `POST`/`DELETE
  /projects/{id}/firewall` installs and removes. It governs branches haro gated; a
  cherry-pick of red code creates a new SHA and is not caught. Adopting foreign
  worktrees is `GET /projects/{id}/worktrees` and `POST /projects/{id}/workspaces/adopt`.
- **Bulk archive** (`POST /projects/{id}/archive-queue`): serial teardown that holds
  back workspaces with unmerged work.
- Agent-session rewind (`POST /workspaces/{id}/rewind`) and multiple sessions per
  workspace exist in the API only.

## settings.toml: scripts and config
Config: `.haro/settings.toml` (committed) + `.haro/settings.local.toml` (gitignored,
personal), over an optional user-global `~/.haro/settings.toml`. Precedence, lowest
to highest: user-global, committed, local. Old `[quality]`, `[race]` and `[editor]`
tables and `review_enforce` keys are ignored.
- `[scripts] setup` runs on workspace create (surfaced as deps state). `run` is the
  dev server and must bind `$HARO_PORT`. Several named runs: `[scripts.run.<id>]`
  with `command`, `default = true`, `icon`; each on its own port from `[ports] range`.
  `archive` runs before teardown. `run_mode`, `login_shell = true` (runs via
  `$SHELL -lc` so nvm/asdf resolve).
- Env for every script: `HARO_PORT`, `HARO_WORKSPACE_PATH`, `HARO_ROOT_PATH`.
  Never hardcode a port: parallel workspaces collide.
- `[files] include` (default `[".env*"]`): globs of gitignored files copied into each
  new worktree; secrets live in `.haro/.env` (Settings > Environment), seeded too.
- `[gate]`: `runner`, `command`, `format`, `dir`, `default_scope`, `merge_result`,
  `watch`, `verified_hunks`, `secrets_scan`, `flaky_retry`, `run_on_save`, `mutation`,
  `sandbox`.
- `[workflow]`: `merge_mode`, `tamper_alarm`, `code_to_check` (`warn`|`off`),
  `coverage_guard`, `coverage_tolerance`, `flaky_rerun`, `auto_fix`,
  `auto_fix_max_rounds`, `confirm_before_commit`, `changelog_on_commit`.
- `[agent]`: `adapter` (`claude-code` | `local`), `default_model` (default sonnet),
  `default_effort`, `max_budget_usd` (hard per-run cap, 5 default, 0 uncapped),
  `cost_warn_usd`, `max_parallel` (default 4, 0 unlimited), `protect_tests`,
  `sandbox`, `local_base_url` and `local_model` (Ollama or llama.cpp, no cloud).
- `[roles]` (off): `enabled`, and `plan`/`build`/`review`/`scout` as `"model:effort"`,
  so approving a plan builds under the build role. `scout` adds a read-only scout
  sub-agent. `review` is the model behind Review with AI.
- `[trust]`, `[backlog]` (`dir` default `backlog`, `issue_assignee`, `issue_state`,
  `issue_limit`, `issue_writeback`, `files`): see above and below.
- Custom instructions: `.haro/instructions.md` (team) + `instructions.local.md`
  (personal), a standing prompt every agent run inherits. Soft guidance, unlike the
  gate.

Settings overlay: **App** tabs Display, Editor, XP, Notifications, Usage, System.
**Project** tabs Git (base branch, remote, ship mode), Setup (read-only in the app,
edit `.haro/settings.local.toml` directly), Gate, Agent, Roles, Environment,
Instructions. Gate, Agent and Roles saves have a Save to row: Personal (`.local`) or
Team (committed).

## Backlog and other project surfaces
- **Backlog** (overlay, opened from the sidebar or palette): `- [ ]` lines in
  markdown under `backlog/` (or any file with `todo` in its name) and a GitHub Issues
  tab read live through the user's `gh`. **Start as workspace** opens New
  workspace prefilled (todo title to branch, text to the task). Files group as In
  progress, Not started and Done. The overlay itself is read-only; edit the markdown
  files in your own editor. Follow-ups deferred
  from verify append to `backlog/follow-ups.md`.
- **Remove project** (sidebar right-click or palette) lists the workspaces it tears
  down and asks for the name when any is unmerged.
- The Flutter app starts its own backend (a frozen one beside the app, else
  `HARO_BACKEND` or `127.0.0.1:8000`) and keeps one instance via `~/.haro/app.lock`.

## Boundaries
- Agent adapters: Claude Code and local models. Gate runners: vitest, pytest,
  command, offense.
- Removed and not coming back: racing one prompt across N lanes, the composer fast
  toggle and dictation, a built-in Neovim editor, the Double Gate (lint/semgrep
  scanners and plan compliance) and the refuter inside the gate.
- Run logs are ephemeral; the agent transcript persists across restarts.

When unsure whether something is built, say so plainly rather than inventing a
feature. An honest map beats an over-claimed one.
