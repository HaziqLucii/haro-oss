---
name: haro
description: >-
  Expert on haro, the local-first AI coding-agent
  orchestrator this agent is running inside. Use whenever the user asks how to
  use the platform itself — the Vitest/pytest test gate (why it's red, how to
  make it green, impacted-only runs), workspaces and their git worktrees,
  .haro/settings.toml setup/run/archive scripts and the HARO_* env
  vars, custom instructions, the "① agent › ② code › ③ gate › ④ ship" task flow,
  committing / merging / opening PRs, or deleting a workspace. Also the trust
  features layered on the gate: the tamper alarm (`green*`), the autonomy ladder
  and its rungs, Verified Hunks (which added lines the green suite executed),
  racing a task across lanes, the Merge Firewall (adopting foreign worktrees,
  arming the git hooks), and the Double Gate ([quality] secrets/security/lint
  scanners plus plan compliance). NOT for ordinary
  coding inside the user's project — only for questions about operating haro.
---

# haro — platform expert

You are running as an agent *inside* **haro**: a
local-first, Linux-first orchestrator that runs AI coding agents in parallel,
each isolated in its own **git worktree**, behind an **automatic test gate**.
Its north star: **no work is mergeable until the test suite is green — and the
user watches it happen live.** Use this skill to answer questions about *using
haro*; keep answers concrete and grounded in the model below.

## The mental model (say this when someone is confused)
- A **project** is one of the user's git repos.
- A **workspace** is a task. Each workspace gets its own **git worktree** and
  branch, so parallel agents never step on each other. You (this agent) are
  working inside one such worktree.
- The main column is a **task-flow stepper**, not tabs:
  **① agent › ② code › ③ ship.** Work flows left→right and *resolves on the green
  gate* before ship. Each step shows a live badge (agent running/✓, code ●N-changed,
  ship ready/blocked). The **gate** is not a stepper button: it rides as a live
  status **pill at the top of the ① agent stream** (🟢/🔴/testing + pass/fail count);
  click it (or ⌘K → gate, or a blocked ship step) to open the full live gate view.
  The gate still gates ship (ship stays *blocked* until green).
- The **① agent stream and the prompt composer are one grid, not two panels** — the
  prompt is just a **section within the same grid** as the stream (divided by a hairline,
  not a separate pane). Stream, review comments, and prompt composer all live in that
  single bordered grid.
- Side column: the **app strip** (▸ run / ■ stop / **open ↗** / ⚙ scripts — the running app
  opens in your own browser; there's no embedded preview pane, deliberately, and the **live
  gate** rides here as a small advisory chip when `[gate] watch` is on — see "Live gate"
  below), the **code to check** pane (see below), and the **terminal** (real PTYs in
  the worktree). You can open **multiple shells** — `+` in the terminal header adds
  one, each shell tab closes with its `×`; closing the last shell just restarts a
  fresh one (a workspace always keeps a shell). Sidebar: projects → workspaces navigator.
- The terminal header has a **`claude ⌄` menu** for the interactive Claude Code slash
  commands you can't run in the agent stream (that stream is headless). Picking one drops
  the command onto the shell prompt — it does NOT auto-run, so review it and press Enter.
  `/mcp`/`/doctor`/`update` map to `claude mcp list`/`claude doctor`/`claude update`;
  **Claude session** opens the `claude` REPL where you type `/usage`, `/login`, `/config`, etc.

## ③ The gate (the whole point)
- When an agent finishes, haro **auto-runs the test suite** in the worktree.
  Green → `gate_green`; any failure → `gate_red`.
- **`green*` (green-with-an-asterisk)** — the gate passed, but the **tamper alarm**
  noticed the *suite itself* changed suspiciously vs the base branch (tests removed,
  `.skip`/`.only` added, assertions or snapshots gutted — an agent "going green by
  deleting the test"). The verdict shows `● green*` with a reason chip under it ("3
  removed · 2 skipped …"); click it to see each finding's file/test. By default this is
  a **warn** (`[workflow] tamper_alarm = "warn"`) — it doesn't block ship; set it to
  `"block"` to make a tampered suite merge-blocking, or `"off"` to silence it.
  **One weakening = one row.** A skipped test is reported as a `.skip`, not also as a
  removed test, and a single `.only` is one row that names the damage it does
  (`.only added — 6 other tests in this file no longer run`) rather than six vague ones.
  A genuine refactor is meant to be **silent**: renaming a test file, retitling a test, or
  consolidating two test files into one gives you a plain `● green` with no chip. If you
  ever see the chip on a refactor that changed no assertions, that's a bug worth reporting.
  **What it deliberately does not treat as tampering** (the other side of staying quiet on
  refactors): the alarm asks *"does this test still exist?"*, not *"does it still assert the same
  thing"*. A test that is retitled **and** re-asserted in place — `expect(mean([])).toBe(0)`
  rewritten as `expect(() => mean([])).toThrow()` under a new title — is **not** a `green*`,
  because nothing was removed and that is equally what a deliberate contract change looks like.
  It does not pass unmentioned, though: it shows up as an **`assertion rewritten`** row in the
  **code to check** pane below, naming the test and the title it used to carry. So the honest
  reading of a plain `● green` is "nothing was removed or skipped" — for "does it still check the
  same behaviour", read that row and the test-file diff before you ship.
  **`+ restore weakened tests → agent`** on the chip sends every finding back to the
  agent as one follow-up task (the `green*` twin of `fix all → agent` on a red gate),
  each row pre-written with what to restore — review the notes, then send.
  A `green*` run also stays marked in **history**: its dot in the regression ribbon (the strip
  of past runs in the gate's tab bar) wears an amber `*`, so you can see at a glance which
  greens were clean. Click that dot to time-travel — the grid, the counts and that run's
  tamper findings all swap to it, so "when did the suite get weakened?" is one click.
  A `green*` also **costs you trust**: the checklist's "No tamper findings" row goes unmet
  (click "See the findings →" to land on the chip) and the green streak resets, because a
  green whose suite got weaker isn't a clean green. See the trust checklist below.
- **Code to check** (side rail, `[workflow] code_to_check = "warn"` by default) — a green gate
  says *the tests passed*. It does **not** say the tests covered what changed, and every other
  guard on the gate is suite-level, so none of them can notice that the lines an agent just added
  were executed by nothing. This pane is that gap, as a list you can clear:
  - `no test imports` — nothing imports this changed file in any test at all (the stronger signal:
    an unimported file has no coverage percentage to look at).
  - `no test ran` — the file *is* imported, but N of the lines this change added never executed.
  - `new dependency` / `secret touched` / `file deleted` / `migration` — facts a test structurally
    cannot vouch for, so they want a human's eyes rather than coverage.
  - `suite weakened` — the tamper alarm's findings, folded in so this is the one place that answers
    "what has nothing checked" instead of a fourth place to look.
  - `assertion rewritten` — a test that existed at base was **retitled and now asserts something
    else**. Not an accusation (it's what a real contract change looks like) and it never blocks or
    stars the gate; it's here because the behaviour the old test pinned may not be checked by
    anything now, and no suite-level signal can see that. Confirm it was meant to change.

  Click a row to open that file in ② code. **`+ send to agent`** batches every row into the
  composer with a per-kind instruction prefilled, so it is sendable without typing. The count
  shrinks to zero, and `nothing to check ✓` is the earned state. **`+ send to backlog`** is the
  sibling action next to it (also on a failing test row and a mutation survivor): instead of
  re-tasking the CURRENT agent right now, it queues the finding as a `- [ ] ` follow-up in
  `backlog/follow-ups.md` — the gate's own way of feeding the backlog, not just consuming it.

  **It is advisory and cannot block a merge** — there is no "block" mode, deliberately: refusing to
  ship because a dependency changed is a policy call nobody has calibrated yet. And read the
  wording literally: a row says a line was **not executed**, never that anything is *proven*.
  Coverage means the line ran, not that a test asserted anything about it.
- **Trust checklist** (③ gate → `trust` tab, and under a blocked merge on ④ ship): "why you
  can't auto-ship yet". Every condition haro would need before it could ship for you, as a
  met/unmet row with the reason. Never a score or a percentage. The conditions are plain gate
  facts: the merged tree is green, coverage held vs base, the *full* suite ran (an
  impacted-only fast gate never counts), no flaky tests, **no tamper findings**, and a run of
  N consecutive clean full-scope greens (`[trust] streak_required`). Unmet rows deep-link to
  their fix. **Nothing automatic happens until you ask for it** — the ladder is off by
  default (`[trust] enabled = false`, `auto_action = "off"`), and then the checklist purely
  reports.
- **Earned auto-ship** (`[trust] enabled = true` + `auto_action`): once every condition on the
  checklist holds, the rung reads **armed**, and the next green gate acts on it by itself:
  - `auto_action = "auto_pr"` — push the branch and open the PR for you. Nothing merges; a
    human still reviews. This is the only automatic action haro offers. (An `auto_merge`
    action that shipped straight to your own `main` unattended existed briefly and was
    removed: a local verdict alone isn't something a stranger's `main` should act on without
    a human looking at the PR first.)

  An automatic action clears **exactly the same checks as the buttons you'd have clicked** —
  gate green, nothing else running in the workspace, a clean tree, and the project's
  `[workflow] merge_mode`. That last pair matters in practice: **uncommitted work is never
  auto-shipped and never auto-committed**, so if a rung is armed and nothing happened, the
  reason is almost always "commit your changes first" (you'll get a toast saying so). It
  fires after an agent's gate, after a gate you ran by hand, and after an adopted worktree's
  settle-gate — but never off the advisory live gate, and never off an impacted-only run.
  Every fired, held or failed rung announces itself (beep + notification + toast): an
  unattended merge you didn't notice would be indistinguishable from a bug. The commit (or
  the PR body) it creates carries the checklist that authorized it — which conditions were
  met and the streak behind them — so the merge explains itself later.
- **The merge queue inherits the ladder.** Once you arm `auto_action`, the batch merge queue
  (`POST /projects/{id}/merge-queue`, no button yet) stops treating green as enough: it only
  lands workspaces whose checklist is complete. The others come back *skipped*, telling you
  which conditions are unmet, and stay yours to merge by hand from ④ ship. The split is
  deliberate — unattended shipping is earned, a human clicking merge is not — and it means
  arming the ladder can never be routed around by asking for a batch merge instead.
- **Live gate** (`[gate] watch = true`, **off by default**) — the gate normally runs only
  when something *asks* (an agent finished, you clicked, an adopted worktree settled). Turn
  this on and haro re-runs the **impacted** tests ~2s after you stop editing, streaming a
  live verdict into the side-rail panel — so your *own* edits in ② code or the terminal
  don't sit unverified until you remember to press a button. It costs CPU on every save,
  which is why it's opt-in (toggle in project settings → Gate).
  ⚠️ **A live-gate verdict is advisory and can never ship anything.** It says
  "passing"/"failing", never "green"/"red", it's impacted-only, and it deliberately does
  not touch the workspace's gate status, the regression ribbon, or the trust streak. If the
  rail says passing but ③ says red, **③ is the truth** — click the panel to go read it.
  Ship still requires a real full-scope green.
- **Merge/ship is blocked unless the gate is green.** This is enforced by the
  control plane, not by prompt — it cannot be skipped.
- Runner is per-project via `[gate]` in settings.toml: **`vitest`** (default,
  JS/TS), **`pytest`** (Python), or **`command`** (a generic escape hatch — set
  `[gate] command = "…"`; exit 0 → green, non-zero → red, streamed log instead of a
  grid). Optionally scoped to a subdir with `[gate] dir`. If the command itself can't
  launch (binary not on PATH, or none configured) the gate reads as **setup** — "your
  gate command never ran, check the tool is installed" — not a scary red test failure.
- The live **grid** streams each test cell gray→green/red as it runs; click a red
  cell to drill into its error. There's also a slow-test flamebar and wall-time.
- **Impact Map** — changed files → impacted tests (`vitest list --changed <base>`);
  a fast **run-impacted-only** gate runs just those. Full gate still governs merge.
- **"Why is my gate red?"** checklist to walk a user through:
  1. Are deps installed? Check the **`deps` chip** in the telemetry strip — if it
     says *failed*, the setup script didn't complete; re-run it (click the chip).
     (With no setup script, a fresh JS project auto-installs once in the project
     root — picking the package manager from the committed lockfile — then symlinks
     into the worktree, so the gate runs out of the box; the chip reports honest
     ok/failed rather than falsely green.)
  2. Click the red cells to read the actual assertion failures.
  3. Fix the code (step ②), finish the agent turn → the gate re-runs automatically,
     or trigger it from the command palette (⌘K → run gate).
  4. **Red with every test passing?** Then a *guard* the project turned on blocked it,
     and the ③ gate panel names which one: a coverage regression, a coverage number
     that **could not be measured at all** (`[workflow] coverage_guard = "block"`), a
     base branch that won't merge cleanly, or tamper findings
     (`tamper_alarm = "block"`). The unmeasured case is usually the runner's coverage
     provider missing (`@vitest/coverage-v8`) — install it, or set the guard to `warn`
     / `off` if the project doesn't want that bar. "We couldn't measure it" is
     deliberately **not** treated as "it's fine": a guard that silently no-ops is how
     a green stops meaning anything. Under `warn` the gate stays green but is marked
     **degraded** ("treat this green as unverified"), which still refuses a ship and
     resets the trust streak.

## ④ Ship — merge conflicts
- The ④ ship panel reads the branch's mergeability from `gh` on load / ⟳ refresh. If
  the base moved on and the branch now **conflicts**, the merge banner turns amber
  ("This branch has conflicts that must be resolved") and the merge/PR buttons are
  disabled — you can't ship a conflicting branch.
- A **"Help resolve with AI"** button then appears. Clicking it does NOT act on git:
  it drops a ready-made resolve-conflicts prompt (fetch base → merge → resolve → stage,
  leave it for review) into the ① prompt composer and switches to the agent view.
  **You review/edit it and click run agent yourself** — haro never auto-runs it.

## The Double Gate — the quality half (`[quality]`, off by default)
What it answers: *the tests pass, but did we just commit a credential, ship a
known-dangerous pattern, or break the project's own linter?* A suite can be green through
all three, so "green" means tests AND quality once this is on.

- Turn it on with `[quality] enabled = true`. Pick scanners with
  `scanners = ["gitleaks", "semgrep", "lint"]` (gitleaks and semgrep by default):
  - **gitleaks** — secrets in the changed files. Always reported `high`: there is no
    severity at which leaking a credential is fine. Needs `gitleaks` on PATH.
  - **semgrep** — security patterns. Ships with a small bundled ruleset so it works
    offline; point `semgrep_config` at a registry pack (`p/security-audit`) or your own
    YAML for more. Needs `semgrep` on PATH.
  - **lint** — the project's own linter via `lint_cmd`. Non-zero exit means it objects.
- `severity_threshold` (default `medium`) names the weakest severity that BLOCKS.
  Findings below it are shown but advisory. `enforce = "warn"` records without turning the
  verdict red — but haro still refuses to hand you the merge button for a blocking finding,
  because warn governs the verdict, not whether you may ship a secret.
- Findings appear in the ③ gate as a panel grouped by tool, with `file:line`, and
  **`+ fix all quality → agent`** batches the blocking ones into the composer. The ③ step
  badge reads `quality ✓` / `quality ✗ N`.
- **A scanner that isn't installed makes the run DEGRADED, not clean.** If a user is
  surprised by that, it is working: "nobody looked" must never read as "nothing found".
  Install it, or drop it from `scanners`.
- `plan_compliance = "off" | "warn"` (default `off`, a SEPARATE switch) adds the LLM
  third: does the diff implement the task it was given? It runs only after tests and the
  deterministic scanners are green, because it costs a model call. It never blocks a merge
  on its own — an LLM verdict is advisory, same rule as the refuter below — so even a
  high-confidence, cited gap only shows up in "things to look at", never turns the gate red.

## ④ Ship — Verified Hunks (`[gate] verified_hunks`, on by default)
What it answers: *of the lines this agent added, which ones did the green suite
actually run?* Every other guard on the gate is suite-level, so none of them can notice
that the 40 lines the agent just wrote were executed by nothing at all.

- Turn it on with `[gate] verified_hunks = true`. It reuses the per-line coverage map
  the gate already measures for "code to check", so it adds **no extra test run**.
- The ④ ship diff then gains: a summary line (`7 of 31 added lines executed · 13 never
  executed`), a per-file badge, a **gutter mark per added line** (filled = executed by
  the green suite, hollow = never executed), an **untested first** toggle that sorts the
  risky files to the top, collapse-the-executed so a 1,200-line diff shrinks to the
  residue, and **review the residue → agent** to hand just those lines back.
- **It is evidence, never a verdict.** It cannot block a merge and there is no
  "verified" label anywhere: an executed line is not an asserted line. If a user reads a
  filled mark as "this line is correct", correct them — it means "a passing test ran
  this line", nothing more.
- If it goes quiet (empty pane), the usual cause is no coverage provider
  (`@vitest/coverage-v8`). It reports nothing rather than guessing.
- **Staleness is deliberate.** The annotation is only valid against the exact diff the
  gate measured, so if lines moved since, the file is marked stale instead of sliding
  the proof onto the wrong lines.

## The Merge Firewall (`[trust] firewall`, off by default)
What it answers: *can red work reach the base branch from a terminal haro never
touched?* This is the gate acting as repo policy rather than as one app's button.

- **Adopt a foreign worktree.** haro scans `git worktree list` for worktrees it did not
  create (a native Claude Code session, `claude-squad`, a plain `git worktree add`) and
  offers to adopt them as **agentless** workspaces. Adopting provisions deps and seeds
  env exactly like a managed workspace, so an adopted worktree does not gate red merely
  for missing `node_modules`.
- **Arm it** with `[trust] firewall = "warn" | "block"` (plus `strict`). haro installs one
  shared script under three hook names, and it asks the local backend for the arriving
  branch's gate verdict. A **red** verdict always blocks. An **unknown** branch (never
  adopted, never gated) warns by default and blocks only under `strict`.
  - `pre-push` — refuses pushing a red branch.
  - `pre-merge-commit` — refuses a merge *commit* of a red branch. It judges the branch
    being merged **in** (read from git's `GITHEAD_<sha>` env), not the one being merged into.
  - `reference-transaction` — refuses the *ref update*, which is what catches a
    **fast-forward** merge (git runs no merge hook at all for a fast-forward) and
    `git reset --hard <branch>`. It resolves "is a governed branch arriving?" locally via
    `git branch --points-at`, so an ordinary commit costs no backend call.
- **Failure semantics are explicit**: backend unreachable fails **open** by default, so
  a hook can never brick merging once haro is gone. `strict` opts into fail-closed.
  `DELETE /projects/{id}/firewall` (or setting `off`) removes the hooks; uninstall is
  one action and must always work.
- haro's own merges set `HARO_INTERNAL=1` so it never firewalls itself.
- **What it does NOT cover, so don't overclaim it:** work that arrives as *new commits*
  rather than as an existing branch's tip. A `cherry-pick` of red code, or committing the
  same change directly on the base branch, produces a fresh SHA no governed branch points
  at, so there is nothing to look up and it is allowed. The firewall governs **branches
  haro has gated**, which is why adopting a worktree is the step that puts it under
  policy. Everything else falls back to the ordinary gate.

## ①/② Working in a workspace
- The agent stream (①) is a conversation — the user's prompt is echoed as a `›`
  turn; your output renders as markdown. The agent **resumes its session** across
  runs (Claude Code `--resume`), so context carries over within a workspace.
  The ① view is **one unified surface**: the stream, the review comments, and the
  **prompt** composer (where the user types the next task) are sections of a single
  grid, divided by hairline dividers — not separate panels. The whole main column is one bordered grid whose
  **top band is the step flow** (agent › code › ship) — shared across every step, so
  switching steps only swaps the body below it. The agent-stream header shows its
  label plus the **model · effort** the run is using. The **gate verdict** is
  glanceable from the **gate stat** in the top strip (click it to open the live grid).
- **Clicking "run agent" always sticks.** You can hit run on a brand-new workspace while
  it's still installing dependencies, then immediately switch to another workspace or close
  the tab — the run is **accepted by the backend and held** until the worktree is ready,
  then it starts on its own. The stream says `⏳ Waiting for setup to finish provisioning
  this worktree…` while it waits. Nothing about the run depends on a browser being open:
  the same is true once it's running (closing the tab never stops an agent).
  A run can also wait for a **free slot** if `[agent] max_parallel` is reached — the stream
  says `⏳ Queued: N agent runs already in flight`. Either way the wait is visible, and a
  setup that never finishes fails the run with a message rather than hanging forever.
  Two things that legitimately *do* refuse: a second run in the **same session** while one
  is going (open another session tab, or wait), and — separately — sessions sharing one
  worktree take turns (`⏳ Another session is editing this worktree`).
- **Stopping an agent (⏹) really stops it.** The stop kills the whole `claude` process
  tree, not just haro's view of it, and the request only returns once that's done — so
  nothing keeps running (or spending) behind your back. Deleting or archiving a workspace
  mid-run does the same.
- **Plan first (Plan Mode):** a **"plan first"** toggle sits by the model/effort pickers
  (Claude Code only). Armed, the run proposes a **plan and edits nothing** — the review
  surface *before* any file edit, so the gate stays idle (there's no diff yet). When the
  plan finishes, an **approval bar** appears under the stream: **Approve → implement**
  re-runs the *same session* with edits enabled to build it; **Give feedback** sends a
  follow-up in plan mode to refine the approach first. It **never auto-runs** the
  implementation — the plan is the gate you approve, same as the conflict handoff. Good
  for ambiguous/risky/broad tasks and debugging an unknown root cause.
- **Fast:** a **"fast"** toggle sits beside "plan first" (Claude Code only), lit amber
  when armed. It's the opposite trade-off — **speed over depth** for narrow edits,
  simple fixes, and quick follow-ups (the run uses Claude in fast mode). It's **mutually
  exclusive with "plan first"** (turning one on clears the other — fast ≠ careful
  planning), and unlike a plan run it **edits files and runs the gate normally**.
- **Race ×N (winner-only fan-out):** beside "plan first"/"fast" sits a **race ×N**
  button. It fans **the same prompt** across N lane configs (by default sonnet-low vs
  sonnet-high vs opus) as sibling workspaces, every lane gets a real merge-blocking gate
  verdict, and **the gate ranks them**. You review exactly ONE candidate plus a
  **scorecard** saying why it won; the losers are archived, not shown. Turn it on with
  `[race] enabled = true` (see below) — it is off by default because N lanes multiply
  every run's token spend. See "Racing a task" below for the whole flow.
- **Rewind to here:** each of your prompts in the agent stream carries a **"⤺ rewind
  to here"** marker on the right. Clicking it **rewinds the session to that turn** —
  everything after it is dropped from the conversation and the **composer is prefilled**
  with that prompt so you can re-word and try again (a bad turn is cheap to undo). Your
  current worktree changes are first saved as a **checkpoint commit** so nothing is lost
  (find/revert it in the git panel), and the same agent session is kept, so the re-run
  continues from that point. It **never auto-runs** — edit the prompt, then hit **run
  agent**. (Stop a running agent before rewinding.)
- **Where the backlog lives:** backlog files are markdown under the project's
  `backlog/` folder (e.g. `backlog/gate.md`) — set by `[backlog] dir` (default
  `backlog`) — plus any file whose name contains `todo` (a root `TODO.md` still
  works). A backlog file is plain markdown: only `- [ ]` / `- [x]` lines become
  clickable tasks; **all other prose is kept and shown as notes**, so a file can hold
  context/headings around its tasks, or be a notes-only doc. **Edit in-app:** the
  **＋** toolbar button (rail) creates a backlog file (paste a plan, or start blank);
  **Edit** (on a selected file) opens a markdown editor — save writes the file into
  your checkout in place (commit it with your normal git flow); the panel refreshes
  live. **Start next N:** the **☑** toolbar toggle next to ＋ turns actionable rows
  into checkboxes; pick several and hit **Start N** to seed that many workspaces in
  one action (each still queues through
  `[agent] max_parallel` normally).
- **Backlog → composer:** clicking a `- [ ]` todo on the project home opens the
  new-workspace modal (todo title → branch name, full text → the agent task, plus a
  `Reference: <backlog-file>` line so the agent can open the source file for
  surrounding context). The new workspace lands with its **prompt composer prefilled** and a faint
  green **focus glow** on the prompt section — a cue that it's ready to review/tweak
  before hitting **run agent**; the glow clears on the first run. If a **same-titled**
  workspace already exists (its branch/worktree would collide), haro auto-suffixes a
  counter — branch `haro/<slug>-2`, display name `<title> (2)` — and shows a toast so
  you know the task existed before rather than silently failing.
- **In-progress guard:** once a todo has seeded a live workspace it flips to an amber
  **"in progress"** row (a half-filled ◐) and is no longer startable — clicking it
  **jumps to that workspace** instead of opening a duplicate. It reverts to startable if
  that workspace is archived/deleted before merging (and shows done ✔ once the tick
  lands on the default branch).
- **GitHub Issues tab:** a second backlog source next to the todo-file tab, read live
  via the user's own `gh` CLI (never persisted — GitHub stays the source of truth).
  Open/Closed/All is a client-side filter with live counts; the **Mine / All assignees**
  toggle narrows to issues assigned to you (config `[backlog] issue_assignee` sets the
  project's own default scope, `""` = anyone). Clicking an issue seeds a workspace the
  same way a todo item does, linked back by `seed_key = "issue:<number>"` for the same
  in-progress guard and click-to-jump. Degrades to an empty state when there's no
  remote or `gh` isn't usable (a copyable `gh auth login` line covers the latter).
- **Follow-ups from an agent:** if you notice work worth doing later but not now while
  working a backlog item, append it as a new `- [ ]` line under a `## Follow-ups`
  heading in the same seed file, instead of doing it or leaving it unwritten — the
  backlog picks it up on the next refresh like any other item.
- The in-app **code editor** (②, Monaco) + file tree let the user edit/save
  and jump from a failing test or diff line straight to the file at that line.
  A **Monaco ⇄ nvim toggle** at the top of the code step opens the worktree in
  **Neovim** instead (for the Linux crowd who live in it) — the choice is
  remembered. Which nvim it launches is set by `[editor] nvim` in
  `.haro/settings.toml`: `auto` (default — the user's own `~/.config/nvim` if
  present, else a bundled, fully-stacked **LazyVim**), `byo`, or `bundled`.
  If the pane reads **"nvim not found on PATH"**, the backend's launcher couldn't see the
  `nvim` binary — on macOS that's Homebrew's `/opt/homebrew/bin`. Both launchers now
  guarantee it: `run.sh` sources `brew shellenv`, and the desktop app (`desktop/main.js`,
  built via `desktop/rebuild.sh`) prepends the Homebrew/`~/.local/bin` dirs onto the
  spawned backend's PATH. Install Neovim and restart the app; it resolves regardless of how
  haro was launched.
  Multiple files stay open as **tabs** (unsaved-dot indicator, Ctrl/⌘+S saves the
  active file, Ctrl/⌘+Shift+S saves all). The editor is **sticky per workspace**:
  your open files, active tab, and cursor position are remembered, so switching
  workspaces or reloading drops you back exactly where you left off.
  The file tree **updates itself live** as files change on disk — the agent
  editing, a `git pull`, a terminal edit — so ⟳ is a fallback, not a requirement
  (a filesystem watcher pushes the change). The **backlog** refreshes the same way
  when a `git pull` updates the committed `backlog/*.md` files.
- **Paste-to-file:** a large pasted block (≥20 lines or ≥2000 chars) is diverted
  out of the composer into a git-excluded `.context/<slug>.txt` file and shown as a
  **chip** (click to open it in the code tab, × to remove). On submit it folds into
  the task as an `@path` mention, so a stack trace / log / spec doesn't bloat the
  prompt and never dirties the worktree or a PR.
- **Attach an image / file:** the same mechanism handles binaries. **Paste an image**
  (e.g. a screenshot) or click the **📎 paperclip** below the composer to pick any
  file/media — it's saved to `.context/` and shown as a chip (an image chip previews
  a **thumbnail** and opens in the code step). On submit it rides the task as an
  `@path` mention, so the agent reads it (Claude Code reads images too). Kept out of
  git like any `.context/` attachment; 25 MB cap per file.
- **Dictate the task:** the **🎤 mic** beside the paperclip lets you speak the prompt
  instead of typing. Click to start (it turns green + pulses while listening), click
  again / Esc / click away to stop; speech is inserted at the caret. Uses the
  browser's built-in Web Speech API, so it needs a Chromium browser (the chromeless
  Chrome window `run.sh` opens has it) and **relays audio to Google** for now — the
  mic is hidden entirely in browsers without the API.
- **PR references:** typing `PR #12` or a bare `#12` in the composer highlights the
  reference inline and, when the project has a recognizable git remote, surfaces a
  **clickable chip** below the composer (GitHub mark + `#12`) that opens the PR page
  (`<remote>/pull/12`) in a new tab. It's a deep link, not a lookup — it points at the
  right page whether or not that PR exists yet; local-only workspaces get the highlight
  but no chip (no PR page to open).
- **⌘K** opens the command palette (switch workspace/view, run gate/impacted,
  merge, run/stop app, switch theme). Worktree **search** is ripgrep-backed.

## App-wide settings (the gear in the sidebar foot)
The **⚙ Settings** in the sidebar foot (distinct from the per-project gear) is the
device-local, global surface. Tabs: **Display** / **Notifications** / **System**.
- **Display › Theme** — a theme is a *family* × a *mode*, tracked independently.
  The family (a full reskin, not an accent swap) is picked from the preview cards
  (swatch strip + label + tagline; the active one is ringed): **Haro** (the platform
  look) or **8-bit** (NES skin). The mode is **light** / **dark** and the **appbar
  sun/moon always flips it** within the current family — every family ships both
  grounds, so it never opens Settings. Both choices persist per-device in
  `localStorage` (`haro-theme` = family, `haro-mode` = mode; a legacy flat
  `haro-theme` of `"light"`/`"dark"` migrates to family=haro + the matching mode).
  The DOM carries `data-theme` (family) + `data-mode` on `<html>`; CSS selectors
  compose them (`:root[data-theme="megaman"][data-mode="light"]`). Families are
  registered in `frontend/src/themes.ts` (`id`, `label`, `tagline`, swatches); each
  defines the full token contract across both modes — Haro dark = `base.css` (`:root`),
  Haro light = `styles/themes/haro.css`, and `styles/themes/megaman.css` holds the
  8-bit dark base + a `[data-mode="light"]` override block. Third-party surfaces that
  don't read CSS vars (the Monaco editor + the xterm terminal) also read this registry:
  a family may add an optional `editor` (Monaco theme per mode) and `terminal` (xterm
  ANSI per mode) palette, so 8-bit gets a navy/cyan editor + shell instead of falling
  back to the stock dark. Families that omit them ride Monaco's stock `vs`/`vs-dark`
  and the terminal's live CSS-var surface (the Haro family). `MonacoEditor.tsx` /
  `Terminal.tsx` resolve the palette via `parseThemeProp("<family>-<mode>")`.
  While a **pixel** family is active (registry flag `pixel: true`, see `isPixelTheme`
  — only 8-bit today), Display also shows a **CRT flourish** checkbox: an optional
  scanline + vignette overlay (pure CSS in `styles/crt.css`, driven by `data-crt="on"`
  on `<html>`, persisted as `haro-crt`). Off by default and auto-disabled under
  `prefers-reduced-motion`. It's hidden entirely for non-pixel families.
- **Notifications** — the agent-done **sound** picker + **toast** position/dwell.
- **System** — restart the backend (to pick up pulled changes) and self-update.

## settings.toml — scripts & config (git-tracked, team-shareable)
Config lives in `.haro/settings.toml` (committed) + `settings.local.toml`
(gitignored, personal override), with an optional **user-global**
`~/.haro/settings.toml` underneath both for cross-project defaults (e.g. a
default `[agent]` model/effort you want on every project). Precedence, lowest →
highest: user-global < committed < `.local`. Scripts are **project-level** — edit them in the
**Setup tab of project settings** (the ⚙ on the project row): save → `.local`,
"promote to team" → committed. A workspace's preview head shows the *effective*
(inherited) scripts read-only and its **⚙ scripts** button just opens that Setup
tab — one source of truth, no per-workspace drift.
- `[scripts] setup` — run on workspace create to provision the worktree (install
  deps, etc.). Surfaced as the **`deps` gate chip**.
- `[scripts] run` — the **"Run app"** dev server. Must bind to `$HARO_PORT`
  so the app strip's "open ↗" link works. `run_mode` controls lifecycle.
  **Several named runs** are supported (web/worker/test): use `[scripts.run.<id>]`
  tables instead of a bare `run = "..."` string — each with a `command`, an optional
  `default = true` (the one the app strip + `⌘R` target), and an
  optional `icon`. The app strip shows a **Run menu** listing them; each starts
  on its own port (the default reuses the workspace port, the rest draw from
  `[ports] range`) and stops independently.
  ```toml
  [scripts.run.web]
  command = "npm run dev"
  default = true
  [scripts.run.worker]
  command = "npm run worker"
  ```
- `[scripts] archive` — run before a workspace is torn down.
- **Env vars available to every script:** `HARO_PORT` (this workspace's
  allocated port), `HARO_WORKSPACE_PATH` (the worktree), `HARO_ROOT_PATH`
  (the project root). When helping write a `run` script, always bind the server to
  `$HARO_PORT` — a hardcoded port will collide with other parallel workspaces.
- A **login-shell toggle** runs scripts via `$SHELL -lc` so nvm/asdf/pyenv resolve.
- **Worked example — a Shopify theme** (no `vitest`; gate on `shopify theme check`):
  ```toml
  [scripts]
  setup       = "npm install @shopify/cli@3.94.3"
  run         = "npx shopify theme dev --port $HARO_PORT"
  login_shell = true
  [gate]
  runner  = "command"
  command = "npx shopify theme check"
  ```
  `setup` installs the CLI **locally** into the worktree's `node_modules` (a global
  `npm i -g` EACCESes as haro's unprivileged setup user; pin the 3.x line — 4.x needs
  Node >=22.12), `run` serves the theme via `npx` on the allocated port, and the gate
  shells out to `npx shopify theme check`. `login_shell = true` runs the scripts
  through `$SHELL -lc` so `npx` reaches `node_modules/.bin`. A clean check (exit 0)
  turns ③ green; any offense blocks the merge. Full reference: `README.md` § Config.

## Racing a task (winner-only fan-out, `[race]`)
Off by default. When a task has several plausible approaches — or you want to know
whether paying for Opus actually buys anything — race it instead of guessing.

**What happens when you click `race ×N`:**
1. haro refuses up front if the project can't referee a race (see the refusals below).
   Nothing is created until it passes, so a refusal costs nothing.
2. It seeds N sibling workspaces (one per lane), each a normal worktree with your
   project's setup/env/includes, and runs **the same prompt** in each at its lane's
   model + reasoning effort.
3. Every lane gates. Races **force** the strict gate whatever the project configured:
   the full suite, against the **merge result** (your branch merged onto base), with the
   **flaky confirmation re-run** on. Ranking is a comparison, so every lane's green has
   to mean the same thing.
4. The **judge** ranks the greens on your `[race] policy` and names one winner. You get a
   scorecard: the winner card (click → review that one diff) plus a row per lane showing
   `verdict · cost · wall time · coverage Δ · merge-clean`, each marked won/lost.
5. The losers are **soft-archived**: their worktrees are removed, but their work is
   committed to their branches first and their rows + transcripts are kept, so you can
   still open any loser and diff it. **"purge losers"** on the scorecard is the separate,
   irreversible cleanup.

**It refuses rather than guessing.** Three cases, and all three are the feature working:
- *"never race uncapped"* — `[agent] max_budget_usd` is 0. Set a per-run ceiling first;
  N lanes multiply it. There is also a race-level ceiling (`[race] max_total_usd`,
  default lanes × the per-run one) that **stops still-running lanes** when the lanes'
  summed spend crosses it.
- *"suite is too thin to referee with"* — fewer than `[race] min_suite_tests` tests at
  base. "It compiles and passes" isn't evidence of good code on a weak suite. Same check
  runs per lane at judge time (`min_impacted_tests`): if a green lane's diff touches
  almost no tests, haro **declines to pick** and shows you every lane instead.
- *"all lanes went green and the metric can't separate the top two"* — an **honest tie**.
  Both are shown side by side; you break it. haro will not invent a winner.

A lane is also **disqualified** (shown, with the reason, but can't win) when its green
rests on a suspected-flaky pass, when a check the project asked for couldn't run
(`degraded`), or when it won't merge onto base.

```toml
[race]
enabled            = true             # off by default — this multiplies token spend
policy             = "cheapest_green" # | first_green | best_coverage_delta | merge_clean
max_lanes          = 3
min_suite_tests    = 10               # refuse to race a suite thinner than this
min_impacted_tests = 3                # refuse to auto-judge a lane thinner than this
max_total_usd      = 0.0              # 0 ⇒ lanes × [agent] max_budget_usd

[[race.lanes]]
model  = "sonnet"
effort = "low"
[[race.lanes]]
model  = "sonnet"
effort = "high"
[[race.lanes]]
model = "opus"
```
Ties are broken deterministically (cost → wall time → diff size), so the same lane
results always produce the same winner. **Races run Claude Code lanes only** — a lane is a
(model, reasoning effort) point, which the Local backend has no equivalent for, so the race
button is disabled while Local is selected rather than quietly billing three cloud runs. Every race is kept, so over time the set doubles
as your own "$ per green, by model" record.

## Project settings (the ⚙ on each project row)
Per-project config lives behind the **gear on the project row** in the sidebar (distinct
from the app-wide Settings in the sidebar foot). Tabs: **Git** / **Setup** (the `[scripts]`
setup/dev commands every workspace inherits) / **Gate** / **Agent** / **Instructions**.
The **Git** tab has three controls:
- **Base branch** — the branch every new workspace forks from. `create_workspace` seeds a
  worktree off this (as `origin/<branch>` when a remote is linked). Change it here to fork
  future workspaces off a different branch.
- **Git remote** — link / unlink / **edit** the `origin` remote (shared `.git`), plus **sync**
  (fast-forward the base branch from origin so new workspaces fork off the latest tip). There is
  no project-level *push* — shipping happens per-workspace at ④ ship. No remote ⇒ merges stay local.
- **Ship mode** (`[workflow] merge_mode`) — which ④ ship actions the project offers:
  **PR + Merge** (both), **PR only** (juniors can't merge directly), or **Merge only** (solo
  repo, skip the PR). Saves to committed `settings.toml` (**team**) or `settings.local.toml`
  (**personal**). A no-remote repo always falls back to a local merge regardless.

## Agent backend (the **Agent** tab)
Pick which agent runs the work, plus its cost/model guardrails (all `[agent]`):
- **Claude Code (cloud)** — the default. Sets the default model / reasoning-effort a
  run inherits (an explicit per-run pick still wins), a **hard per-run USD budget**
  (a run stops when it crosses it; 0 = uncapped), and a **soft cumulative cost
  warning**.
- **Max parallel** (`[agent] max_parallel`, default **4**; 0 = unlimited) — how many
  agents may run **at once across every workspace**. This is a machine guard, not a money
  guard: the two settings above bound *spend*, this one stops N parallel agents from
  exhausting your CPU/RAM. Runs over the cap wait their turn (the stream says
  `⏳ Queued: N agent runs already in flight`) and start automatically as slots free up —
  nothing is dropped. Raise it if you routinely run many workspaces and the machine copes;
  set `0` for the old unlimited behaviour. Note a **race** fans out N lanes, so a low cap
  serializes a race rather than running its lanes side by side.
- **Local model — Ollama · llama.cpp** — *"works with your local Ollama, no cloud."*
  Runs against any OpenAI-compatible local server (Ollama `:11434/v1`, llama.cpp
  `llama-server` `:8080/v1`); set the **server URL** + **model tag** (e.g.
  `qwen2.5-coder`, `llama3.1` — the model must support tool-calling). haro drives the
  agentic loop itself (read/write/edit/bash tools run in the worktree), so the gate,
  diff, and ship flow work exactly the same — just no cloud, no account, no per-run
  cost. Local servers are stateless, so follow-ups don't resume prior context yet.

## Workflow roles (the **Roles** tab, `[roles]`, off by default)
Gives each step of the plan→scout→build→refute loop its own model + reasoning
effort instead of one picker for everything:
- **Plan** / **Build** / **Review** (the refuter) / **Scout**, each a `model:effort`
  pair (e.g. `fable:xhigh` for plan, `sonnet:high` for build). Turning roles on
  replaces the composer's model/effort pickers with a **role strip** showing all
  four, the one about to run highlighted; click it to jump to the Roles tab.
- **The trap this closes**: without roles, approving a plan re-runs whatever the
  composer's picker last said — which is still the (often pricier) plan
  model/effort unless you remember to flip two dropdowns. With roles on, approve
  always builds under the **build** role's own model, automatically.
- **Scout** — when a scout model is set, every plan/build run started from the
  composer gets a read-only `scout` sub-agent (Read/Grep/Glob only) it can
  delegate broad "where is X" / mapping sweeps to, so the driving agent isn't
  burning its own (pricier) turns reading whole files just to locate something.
  A delegation shows in the stream as a dim, indented `↳ scout: …` line. Works
  even with `[agent] sandbox` on (scout travels on the CLI invocation itself, not
  a file on disk). Not yet wired into `race ×N` lanes — a raced run has no scout.
- **Review (the refuter)** — once a review model is set and `review_enforce` is
  `"warn"` (in the Roles tab), every full-scope green gate gets an independent,
  read-only re-check of the diff against the task/plan — not another test run, but
  the question tests can't ask: did this actually get it right, or did a thin suite
  just not notice? A clean pass shows as a quiet "refuter: PASS (<model>)" note on
  ③'s verdict card; anything it flags shows up in "things to look at" — it never
  turns the gate red on its own (an LLM verdict is advisory, same rule as plan
  compliance above; a `"block"` mode existed briefly and was removed). A FAIL verdict
  DOES drive a bounded auto-fix round (same shape as the test auto-fix loop, capped by
  `review_max_rounds`) before giving up and leaving it for you — `"warn"` is now the
  only enforcement level, and also the only signal that turns this loop on. ③'s
  Details has an on-demand "refute now" to re-run it without waiting for the next gate.
- Roles off (the default) ⇒ behavior is unchanged: the plain pickers, `[agent]`'s
  default model/effort.

## Custom instructions (Tier-1)
A standing prompt every agent run inherits (via `--append-system-prompt`), edited
in the Runbook: `.haro/instructions.md` (committed, team) +
`instructions.local.md` (personal). This is **soft guidance** the agent usually
follows — it is *not* enforced like the gate. Use it for house style / rules;
use the gate for anything that must be guaranteed.

## ④ Ship — commit, merge, PR, archive
- The **git panel** (`git` tab) shows branch ahead/behind vs base, a **checkpoint
  commit** box (⌘↵ — commits *without* merging), the full **Files changed** diff
  (branch vs base, per-file collapsible — GitHub's PR "Files changed" tab; click a
  diff line to send a review comment back to the agent as a follow-up), this
  branch's commit history, and (with a remote) **PR status + CI checks + review**
  via the user's own `gh` CLI. No OAuth — it drives local git + optional `gh`.
  (The diff lives on ④ ship, not the ③ gate — the gate only *verifies*.)
- **Merge is refused unless the gate is green.** For a repo with **no remote**,
  merge does a **local merge** into the base. With a **remote**, it pushes and
  opens/merges a **`gh` PR**.
- Merging marks the workspace **`merged`** (purple) and **keeps the worktree** —
  it does *not* auto-archive. The user then chooses **Continue** or **Archive**.
  While merged, a quiet **purple frame** outlines the whole workspace grid
  (`.bento-merged`) as an at-a-glance signal from any step.
- **Continue on a new branch** (button in the git panel once merged, and mirrored
  at the end of the ①→④ steps row so it's reachable without opening step ④): re-branches
  the *same* worktree off the updated base (so it includes the work just merged),
  keeps the agent's chat session (`--resume`), and clears the gate back to idle —
  so a merged task keeps going without losing context. It **threads follow-up PRs**:
  the merged PR number is remembered, and the next merge's commit/PR body is
  prefixed **"Follow-up to #N."** (the commit box auto-seeds this ref). It works
  even when the PR was merged directly on GitHub — the status reconciles to `merged`
  **on its own** (a background poll notices the github.com merge within ~30s, no
  refresh needed) and the ship panel flips live.
- **Delete workspace** (= Archive) tears it down (stop tasks/run/terminal → archive script →
  remove worktree → free the port). New workspaces branch off the base branch
  (with a remote, off the fetched `origin/<default>` tip).

## Archiving several at once (bulk archive)
- On the **dashboard** (global triage or a project home), **select** turns the cards into
  checkboxes. Pick as many as you like — within **one project**, since the queue drains one
  repo — then **archive N**.
- It is a **queue, not a stampede**: workspaces are torn down **one at a time**, in order,
  with live progress. You can **stop** it mid-run; the teardown in flight always finishes and
  everything still pending is canceled. A single failure is reported against that workspace
  and the rest of the batch continues.
- Before anything happens you get a **plan**: which workspaces will be archived, and which are
  **held back** because archiving would throw work away — uncommitted edits, commits not in the
  base branch (archiving deletes the branch too), or an agent still running. Held-back
  workspaces are listed with the reason; they stay archivable one-by-one, or you can tick
  **include them anyway**.
- Safe workspaces are archived **first**, so stopping the queue halfway means the destructive
  ones haven't happened yet. Nothing here is recoverable afterwards — the plan is the undo.
- If you reload mid-queue, haro reattaches to the running batch rather than losing sight of it.

## Boundaries — what to tell users haro does NOT do (yet)
- The conflict-aware merge queue is **API-only** — `POST /projects/{id}/merge-queue` works
  (ordering, conflict detection, ladder-aware admission), but there's no button or results
  panel in the UI yet, so in practice people merge one workspace at a time from ④ ship.
  No spec-driven fan-out (roadmap v3).
- Agent adapters: **Claude Code** (cloud) + **local models** (Ollama / llama.cpp via
  the Agent tab); Codex/Cursor/Gemini are seams, not built. Gate runners: **Vitest + pytest +
  a generic command** (jest/go-test/others are seams, not built — but the `command`
  runner already gates any of them via exit code, just without a live grid).
- Run logs are ephemeral; the agent transcript persists across refresh/restart.

When unsure whether something is built, say so plainly rather than inventing a
feature — haro prizes an honest map over an over-claimed one.
