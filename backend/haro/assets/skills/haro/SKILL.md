---
name: haro
description: >-
  Expert on haro, the local-first coding orchestrator this agent is running
  inside. Use whenever the user asks how to use the platform itself: the test
  gate (why it is red, how to make it green, impacted-only runs, the first-run
  baseline), workspaces and their git worktrees, agent mode vs manual mode
  (you write the code, haro's assistant only plans and researches), the
  agent > code > review > ship flow, the manual rail (Plan, Search, Docs),
  XP, rank and streak, .haro/settings.toml scripts and the HARO_* env vars,
  custom instructions, committing / merging / opening PRs, or deleting a
  workspace. Also the trust features layered on the gate: the tamper alarm
  (`green*`), Verified Hunks, protected tests, test-first
  tasks, the autonomy ladder, the Merge Firewall, and the
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
- The right rail is on every step: **GATE** (verdict), needs
  your eyes count, **APP** (the address and a RUNNING / STOPPED badge, then three icon buttons with
  tooltips: Run / Stop, Open in browser, and
  Dev log, which opens the bottom panel on the Dev log tab; the dev server answers on
  `$HARO_PORT` unless its run script sets a `url`), and
  in agent mode a **RUN** block (model, effort, cost so far, run time, context used). In manual mode the rail
  also carries the Plan / Search / Docs assistant.
- When the agent delegates to a sub-agent (scout, Explore, code-review), an **AGENTS** section
  appears in the rail: one line per sub-agent (name, run time, what it is doing now). Click a line,
  or its `↳` row in the stream, to read that sub-agent's whole feed; **STOP** there stops just that
  sub-agent while the main run carries on; **CLEAR** drops finished ones from the list. A shell
  the agent starts in the background, or a monitor it attaches, gets a line too (`shell` /
  `monitor`) with the same **STOP**. They end with the agent's turn (haro ends the agent's
  process a few seconds after its answer, which ends them), and a finished shell or monitor
  leaves the list by itself. So a monitor only helps while the agent is working.
- The app haro runs (the Run button) also writes its output to
  `~/.haro/logs/<workspace>/run.log` (`run-<name>.log` for other run scripts; reset on every
  start, capped at 5 MB). Every agent run for a project with a `run` script is told where it is
  (`$HARO_RUN_LOG`, `$HARO_LOG_DIR`), so "monitor the app" needs no instructions. The agent can
  also use `haro-app` (not offered to a plan-only run): `start | restart [run] [--timeout N]`
  wait until the app answers (60 s by default, `--no-wait` skips), `wait`, `stop`, `status` (one
  line, with the last error from the log), `url [/path]`, `logs [-n N]`, `list`, `open [/path]`
  (offers the developer a page: the rail's APP row shows `Agent suggests /path` with Open and a
  dismiss) and `do <tool>` (runs a command the project declares under `[scripts.tools]`). So
  "restart the app and tell me what /api/slug returns" needs no instructions.
- The bottom panel (Ctrl+` to toggle) holds **Terminal** (a real shell in the
  worktree), and **Dev log** once the dev server has output. Both are selectable with the mouse:
  hold the pointer above or below the panel while dragging and it scrolls and keeps selecting, so
  long output can be copied. The status bar shows
  branch, gate chip, terminal toggle, and in the code step Ln/Col, indentation,
  language, encoding and saved state.
- There is no embedded browser preview: the running app opens in the user's own
  browser.

### Shortcuts (Cmd on macOS, Ctrl on Linux)
`K` palette, `N` new workspace, `J` next workspace that needs you, `G` run the gate,
`I` focus the composer, `R` run the dev server,
`S` save the open file, `\` split the editor, Shift+`O` open in an external editor,
Shift+Enter focus mode, `?` list them. `?` opens **Help**: a **Guide** tab (topics down the left, a search
box, written in plain words for newcomers and developers alike) and a **Keyboard shortcuts** tab; the top bar's
`?` button and the palette's "Open the guide" open the guide. The terminal toggle is Ctrl+` on both platforms.

## The flow
- **Agent mode: agent > code > review > ship.** Manual mode: **code > review > ship**
  (no agent step, no composer). Step 3 is called review on screen (it is the verify step, and the
  route is still `/verify`). You work one step at a time: only the step you are on is clickable,
  the others are dimmed, and **Proceed to <next step>** and **Back to <previous step>** move you.
  Proceed never starts the gate; the gate is started from review. On the agent and code steps
  every forward or fix action (run or re-run the gate, restore tests, re-run setup) is Proceed,
  so review is always reachable. Other primary actions: Run agent, Send failures to agent (the
  agent step's own), Proceed to ship (a green review), Continue on a new branch, and in
  manual Start coding / Save & run gate (unsaved edits on the code step). Review also lists
  An **Overview** block comes first: the first prompt (and how many
  follow-ups), the fence (its paths, runs fenced, edits refused, paths reverted, and always "commands and network
  are not restricted"; "Not fenced" when it was not), and the size (changed lines and files, a meter to 1,000
  lines with ticks at 100 and 400 (hover it for a plain-words explanation), about how long it takes at 400 lines an hour with a named fun fact under it (a 2006 Cisco study of 2,500 reviews, one team's data from before AI wrote code), and a nudge past about 400
  lines or 20 files to fence the next run to fewer files; lockfiles and generated files are not counted).
  **Files changed**: one collapsible diff per file, each with a **Viewed** box that folds it, in reading order:
  files with added lines the suite never ran, then boundary files (CI, dependencies, config, schema, auth) and
  tests that lost more lines than they gained, then new tests, then everything else, then generated files and lockfiles last; a small label
  says which kind (CI, DEPENDENCIES, CONFIG, SCHEMA, AUTH, TEST, TEST EDITED, GENERATED). Proceed to ship stays disabled until the gate is green and
  every file is Viewed; a file changed after you viewed it needs viewing again. The marks are
  kept on this device, not in the workspace.
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
  Closing the app window while work is running asks first; quitting anyway stops the agent and the gate (the backend ends, with its process groups). Stop kills the whole process tree.
- The dashboard header says how much agent work waits for you (`3 workspaces waiting for your
  review · 1,240 changed lines`: workspaces an agent has run in, not merged, nothing running, changed against the base;
  manual and plan-only ones are not counted), and once other workspaces already wait for review up
  to `review_cap` (default 3, in the user-global `~/.haro/settings.toml` `[agent]`, 0 turns it off),
  the composer shows one line under the box: `3 other workspaces already wait for your review
  (1,200 lines). Another run adds to the pile.` It never blocks a run; `max_parallel` bounds the
  machine, this reminds you that review is the limit. `GET /review-queue`.
- When the agent finishes, the gate does not start by itself (a full gate after every stop is slow
  on a big project): you start it from review. A project can opt in with `[gate] auto_run = true`
  (Settings > Gate, "Run when the agent finishes"); then it runs after every non-plan run. A
  test-first build run always gates itself. Auto-fix rounds and the auto-PR rung only happen
  with the automatic gate.
- A red gate offers **Send failures to agent** as one follow-up task. With
  `[workflow] auto_fix = true` haro feeds test failures back itself, up to
  `auto_fix_max_rounds` (default 3); setup or crash reds never loop.

### 2 Code step (a small IDE)
- Activity bar: **Files**, **Search** (ripgrep), **Changes**, **Gate**. Explorer
  with All files / Changes, filter, A/M/D/R letters, rename/delete, keyboard
  navigation. The tree follows the disk (it respects `.gitignore` and refreshes when
  an agent or another editor adds or removes files). Tabbed editor (preview tabs,
  unsaved dots, breadcrumbs, minimap, indent guides, split right, font size and word
  wrap in Settings > Editor). Unsaved edits survive tab switches, and open tabs,
  cursors and the side panel come back after a restart (never unsaved text).
- Editing: find (Cmd/Ctrl+F) with a replace row (the `⇄` toggle, Cmd+Option+F),
  go to line (command palette "Go to line", or `:42` / `path:42` in Cmd/Ctrl+P),
  bracket auto-close, comment toggle (Cmd/Ctrl+/), image preview.
- Saving is conflict-safe: if the file changed on disk since you opened it, the save
  is refused and the bar asks Overwrite / Reload / Cancel. A file deleted on disk
  shows a "deleted on disk" bar (Save anyway / Close) and is never recreated silently.
- Gutter marks: a change bar, "line ran" dots that show only against a green gate,
  a hollow circle on a
  needs-your-review row (hover for the reason, click for the Problems tab). Marks show
  only while the file is saved and are advisory. In Diff mode, click a line number
  (or double-click a row) to jump into Edit at that line; the hover label says
  `never ran` where it applies. While anything is unsaved the
  primary action reads **Save & run gate**. `[gate] run_on_save = true` makes a
  save start a gate run too: in agent mode the app starts it, in manual mode the
  backend does about 2 seconds after the worktree goes quiet, so a save from Zed or
  VS Code counts the same (default off: a save then spends a test run).
- **Changes** stages per file (`git/stage`, `git/unstage`), refused while an agent or
  gate is running, and commits only what is staged.
- Bottom panel tabs in this step: Terminal, **Gate** (this file's added lines vs the
  green suite, plus "Run the tests touching this file": an advisory vitest run for
  the open source file that never changes the verdict), **Problems** (open needs-your-eyes items; no
  lint), Dev log.
- **Focus mode** (Cmd/Ctrl+Shift+Enter) swaps the chrome for a slim focus bar with
  the gate chip; Esc leaves it.
- **Open in...** launches the user's editor (`GET /editors`, `POST /workspaces/{id}/open`).
  Terminal editors like Neovim are typed into the Shell tab, using the user's own
  config. There is no built-in Neovim or Vim mode.

### 3 Review step (the verify step: the gate, verdict first)
- A verdict (green, red, green*, running, setup), counts, then what a human still
  has to look at, and the failed tests. Red with every test passing means a guard blocked
  it; the page names which one.
- **Needs your review** rows (advisory, except failures): `no test imports` (nothing
  imports a changed file), `no test ran` (added lines never executed), `new
  dependency`, `secret touched`, `file deleted`, `migration`, `suite weakened`
  (tamper findings), `assertion rewritten`, and `possible secret` (gitleaks). Failed
  tests, suspected-flaky tests, and a coverage drop show up in
  the same list. Each row can be ticked as reviewed, opened in the editor, or
  deferred to `backlog/follow-ups.md`.
- "Why is my gate red" checklist:
  1. Setup state: if setup failed the gate reads "The gate couldn't run: setup failed"
     (**setup**), not a red test. A red banner under the step bar on every step shows the exit code, the
     last lines the script printed and a **Re-run setup** button (any workspace, not only adopted
     ones). Re-running setup first removes a `node_modules` link into the project checkout, so an
     install cannot write through it. With no setup script a fresh JS project
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
  coverage, protected tests, acceptance test, a `Written by` line:
  `you, by hand`, `agent · <model>`, `you and the agent (manual -> agent at HH:MM)`, or
  `you and the agent (2 files edited by hand)` when files changed outside every agent run, in
  any editor; those files are listed under it. Changes the setup script made are never credited
  to you, and when haro has no record of what a run touched the receipt says so instead of
  guessing. A file you edit while an agent run is going counts as the agent's, since haro
  compares the worktree at the run's start and end). A `Review in haro` line says what the
  review step recorded: `Viewed 3 of 5 files, median 12 s open per file, 1 marked Viewed in under
  5 s`, measured against the files changed now, or "no Viewed marks were recorded". It is a fact
  about the screen, never a verdict on the review. The developer can type one sentence under the
  card, "Why you are approving this", and it is added as `Approval reason` marked as typed by
  the developer; haro never drafts it).
  **Copy markdown**, **Copy for PR** (intent, constraints, evidence, decision: the intent is the
  first prompt as typed, empty fields say "Not applicable" and why) or **Post to PR**. A PR opened by ship carries one plain line:
  `Gate: green, 42 passed, 0 failed`, plus `attested <sha> · reproduce: haro verify
  <sha> --rerun` when a verified attestation exists for that tree.
- **Review with AI** (`POST /workspaces/{id}/review`): an on-demand, advisory read of
  the diff, a button at the top right of the review step's Files changed list. Findings appear
  under their file; the rest sit in the summary above the list. It never touches the gate and
  cannot block a ship. The result is kept in memory only (lost on restart).
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
  (a gate, dev server, commit) the check is inconclusive and it says
  **AI edits: unverified**. Never tell a user "the AI wrote no code"; say the
  assistant had no edit tools.

## XP, rank and streak
Source of truth: `GET /xp/rules` (the app's "How XP works" renders it, so a number
changed in `backend/haro/xp.py` changes everywhere). Also `GET /xp`, `GET /xp/events`.
- Daily activity pays once per kind per local day: read Docs, made a plan, ran a
  search, a green gate, reviewed the diff. Merge awards pay once per workspace and
  only on a green, non-empty, unblocked merge (plus points for needs-your-eyes items
  ticked, capped, and only ones that match real items on the latest run).
- Manual pays more and has bonuses: red to green by you,
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
  under needs your review.
- **Verified Hunks** (`[gate] verified_hunks`, on by default; the app calls it
  "Per-line proof"): per added line in the diff, executed by the green suite or
  never executed. Evidence, never a verdict: it means a passing test ran the line,
  not that anything asserted on it. Needs a coverage provider.
- **Secrets scan** (`[gate] secrets_scan`, on): gitleaks over the diff on a passing
  full gate; silently skipped if gitleaks is missing. Advisory.
- **Flaky guard** (`[workflow] flaky_rerun`, off), **coverage guard**
  (`coverage_guard` `off`|`warn`|`block`, `coverage_tolerance`), **merge result**
  (`[gate] merge_result`: gate the worktree merged onto the latest base).
- **Restore point**: every agent run (not a plan run) keeps the worktree as it was when it
  started, under `refs/haro/start/<workspace>/<run>` (the newest 10 per workspace). Under the
  newest run's footer in the agent stream, **Restore files to before this run** (two steps) puts
  those files back: files the run added are deleted, files it changed or deleted come back, and
  what the worktree held a moment before is kept under `refs/haro/before-restore/...` first. It
  restores files only: a commit the run made stays, and ignored files such as `node_modules` are
  not saved. It is how you undo a `git reset --hard` or a clean the agent ran.
  `POST /workspaces/{id}/runs/{run}/restore-start` (refused while the agent or gate runs).
- **Command guard** (`[agent] command_guard`, on by default): before the agent's Bash or Read call
  runs, haro matches it against a short list and refuses it with a reason the agent reads:
  `git reset --hard`, `git clean -f`, `git checkout .`, `git restore .`, `git push --force`, `rm -r`
  on the whole worktree, `.git`, the home directory, a path outside the worktree (`/tmp` is fine)
  or one it cannot resolve; and reading `.env`, `.env.*` (not `.env.example`), key files, `~/.ssh`,
  `printenv`, `env`, `echo $SOME_TOKEN`, `/proc/*/environ`. It is a text match, a speed bump and
  not a guarantee: the agent's shell can reach the same files another way, so the restore point
  is the safety net. Refusals show on the stream and the receipt (`Refused before they ran`).
  Needs haro's own address like the fence hook (the desktop app, or `HARO_API` under `./run.sh`).
  haro also copies `.env*` into every worktree by default (`[files] include`) so dev servers and
  tests work; the guard stops the agent's tools from reading them, not the gate or run scripts.
- **Protected tests** (`[agent] protect_tests = "existing"`, or per run): deny the
  agent's Edit/Write on test files that exist at the base. A speed bump, not a
  guarantee (the agent's shell can still write a file). The tamper alarm is the
  check; a protected run is labelled on the gate note and receipt.
- **Scope fence** (the "Scope" box under the prompt, agent mode only, no config key; it says "all files" until you add something): a list of paths or
  globs the agent may edit in this run, shown as chips. Click a folder or file in the list that opens when you focus
  the box, or type a name (it searches folders and files anywhere, so `comp` finds `app/components/`); Enter adds the
  highlighted one, Tab steps into a folder, the Open button on a folder row looks inside it (a row click adds the
  whole folder; inside a folder a back row goes up), a comma or a pasted list (one path per
  line) makes one chip per path, Backspace on an empty box removes the last chip. A folder chip covers everything under
  it, so no `**` is ever needed (typing `src/**` becomes the folder `src/`); a real pattern (`*.md`, `src/**/*.ts`)
  becomes a pattern chip, and a path that does not exist yet is a new file. Reading is unrestricted. When the run ends, haro puts back every
  change outside the list, including after a stop or an error, and says so on the stream and the
  receipt; what the run had written there is kept under `refs/haro/scope/<run id>`. Your own
  uncommitted work from before the run is never touched. If the agent needs a file outside the
  fence it is told to stop and say so: widen the fence and run again. It is a guarantee about the
  worktree after the run, not about the agent's tools. A concurrent edit of yours in a fenced-out
  file during the run is reverted too. The scope you typed is sticky for the workspace, and the
  runs the buttons start for you (send failures to the agent, send to agent, restore test) use
  it too, so a fix cannot edit what the original run could not; empty the field to lift it. The
  same goes for the build run that starts when you approve a plan or a test-first test (the
  field stays visible while plan-first is on for that reason); the test-first drafting run is
  never fenced. A write outside the fence by an edit tool is refused before it happens (the agent is
  told the fence and that nothing was written; the receipt's Scope row counts it as "blocked");
  anything that still lands outside (a shell write) is put back after the run. If a fix needs a file
  outside the fence, haro refuses or reverts it and says so on the stream: widen the fence and send
  it again.
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
  dev server and should bind `$HARO_PORT`; an app with fixed ports of its own sets a `url`
  (`[scripts.run.app]` with `command` and `url = "http://localhost:4200"`, http or https; name the
  default run `app`, the APP row follows that id) so the APP row and Open go to the right place.
  Several named runs: `[scripts.run.<id>]`
  with `command`, `default = true`, `icon`, `url`; each on its own port from `[ports] range`.
  `archive` runs before teardown. `run_mode`, `login_shell` (off by default; `true` runs via
  `$SHELL -lc` so nvm/asdf resolve).
- Env for every script: `HARO_PORT`, `HARO_WORKSPACE_PATH`, `HARO_ROOT_PATH`.
  Never hardcode a port: parallel workspaces collide. Agent runs also get `HARO_RUN_LOG` and
  `HARO_LOG_DIR` (the run output) and `haro-app` on the PATH, for a project with a run script.
- `[scripts.tools.<name>]`: a command the agent may run with `haro-app do <name>`: `command`
  (required), `description`, `timeout` seconds (default 300, max 1800). It runs in the worktree
  with the same env as the setup script, no arguments; the last 40 lines come back to the agent.
  The agent can run only what the repo declares here.
- `[files] include` (default `[".env*"]`): globs of gitignored files copied into each
  new worktree; secrets live in `.haro/.env` (Settings > Environment), seeded too.
- `[gate]`: `runner`, `command`, `format`, `dir`, `default_scope`, `merge_result`,
  `watch`, `verified_hunks`, `secrets_scan`, `run_on_save`, `auto_run` (default off: start the
  gate when an agent run finishes), `sandbox`.
- `[workflow]`: `merge_mode`, `tamper_alarm`, `code_to_check` (`warn`|`off`),
  `coverage_guard`, `coverage_tolerance`, `flaky_rerun`, `auto_fix`,
  `auto_fix_max_rounds`, `confirm_before_commit`, `changelog_on_commit`.
- `[agent]`: `adapter` (`claude-code` | `local`), `default_model` (default sonnet),
  `default_effort`, `max_budget_usd` (hard per-run cap, 5 default, 0 uncapped),
  `cost_warn_usd`, `max_parallel` (default 4, 0 unlimited), `protect_tests`, `ignore_user_claude_md`
  (keep your own `~/.claude/CLAUDE.md` out of agent runs), `command_guard` (default true; see Command
  guard), `review_cap` (user-global only), `auto_open_app` (open the page the
  agent offers with `haro-app open` in the browser at once; off by default),
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
- **Backlog** (a page, opened from the sidebar or palette): `- [ ]` lines in
  markdown under `backlog/` (or any file with `todo` in its name) and a GitHub Issues
  tab read live through the user's `gh`. **Start as workspace** opens New
  workspace prefilled (todo title to branch, text to the task). Files group as In
  progress, Not started and Done. The user edits the todos on the page itself: the
  line at the top adds one, the box checks it, and the `···` menu edits it, moves it
  up or down, moves it to another file or deletes it (a parent takes its sub-items
  with it); `+ NEW FILE` and `rename` handle files. A file an agent changed
  meanwhile answers with "The file changed", reloads, and the edit is dropped.
  **Capture a todo** (Cmd/Ctrl+Shift+T, from any step, also in the palette) files one
  line into `backlog/inbox.md`. Follow-ups deferred from verify append to
  `backlog/follow-ups.md`. The **Notes** tab holds free-form markdown pages in
  `.haro/notes/` (brainstorms, sketches; plain files that go with git). The editor
  saves by itself and refuses to overwrite a note changed on disk (Reload it or Keep
  mine). **Make todo** files the selected text or cursor line into the inbox, and
  **Start as workspace** opens New workspace prefilled from it. Only the user writes
  notes in haro; no agent action edits them.
- **Remove project** (sidebar right-click or palette) lists the workspaces it tears
  down and asks for the name when any is unmerged.
- The Flutter app starts its own backend (a frozen one beside the app, else
  `HARO_BACKEND` or `127.0.0.1:8000`) and keeps one instance via `~/.haro/app.lock`.

## Boundaries
- Agent adapters: Claude Code and local models. Gate runners: vitest, pytest,
  command, offense.
- Removed and not coming back: racing one prompt across N lanes, the composer fast
  toggle and dictation, a built-in Neovim editor, the Double Gate (lint/semgrep
  scanners and plan compliance) and the code reviewer inside the gate.
- Run logs are ephemeral; the agent transcript persists across restarts.

When unsure whether something is built, say so plainly rather than inventing a
feature. An honest map beats an over-claimed one.
