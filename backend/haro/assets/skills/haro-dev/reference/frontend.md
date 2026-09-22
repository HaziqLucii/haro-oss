# haro frontend map (`frontend/src/`, React + TS + Vite)

A navigation aid, not a spec — always read the target file before editing.

## Contents
- `App.tsx` — top-level state + WS channel routing; composer agent config; Plan/Fast Mode toggles
- `components/Sidebar.tsx` — projects→workspaces navigator + `ProjectSettingsModal.tsx` tabs
- `components/AgentStream.tsx` + `AgentMarkdown.tsx` — step ① console, per-turn markers, `.main-stage` grid
- `components/CodePanel.tsx` — step ② Monaco editor + file tree, diff review, Monaco⇄nvim toggle
- `components/GatePanel.tsx` / `ImpactMap.tsx` / `AnalysisPanel.tsx` — step ③ verify (grid/impact/AI review)
- `components/CodeToCheck.tsx` — the side rail's **code to check** pane (`backlog/code-to-check.md`):
  the DIFF-level signal every other guard misses, since they are all suite-level. Rows come off
  `TestRun.unchecked_items` (computed in `run_gate`, engine in `backend/haro/unchecked.py`); a row
  opens its file in ② code, and `+ send to agent` batches them via `gate.ts`
  `uncheckedReviewItems`. Advisory: no `unchecked_blocked` exists, so it cannot refuse a merge.
  Two contracts to keep when touching it: (1) `unchecked_items` is **tri-state** (`None` = the
  pass never ran, `[]` = it ran and found nothing) and `unchecked_covered_files` is what
  licenses the clean state, so never normalize a missing value to `[]`; the pure resolver is
  `gate.ts` `uncheckedState`. (2) Rows tick off against `UncheckedRow.key` into
  `Workspace.checked_rows` (`POST /workspaces/{id}/checked`, pruned to the live rows on every
  gate) — that is what lets the pane reach zero on the four kinds no test can ever close.
  ⚠ `GateLive.tsx` is **deleted**. Its pane was empty unless you hand-edited inside a worktree, so
  the Live Gate now rides as a `.live-chip` on the app strip in `App.tsx`, rendered straight from
  `gate.ts` `watchVerdict`/`watchSummary`. The watch LOOP (`gate.run_watch`) is untouched.
- `components/GitPanel.tsx` — step ④ ship (commit/merge/PR, conflict handoff, merge-blocked trust checklist)
- `components/TrustChecklist.tsx` — shared autonomy-ladder checklist (③ gate `trust` tab + ④ ship merge-blocked banner)
- `components/DiffView.tsx` — collapsible per-file unified-diff renderer + **Verified Hunks**
  (per-line proof); pure copy/tallying in `verifiedHunks.ts`
- `components/ReviewPanel.tsx` — inline review comments → composer
- `components/RaceScorecard.tsx` — the winner ceremony (winner card + per-lane criteria)
- `components/Dashboard.tsx` / `ProjectDashboard.tsx` — global triage / per-project home
- `components/ArchiveQueuePanel.tsx` — bulk archive: the dry-run plan, then the live queue
- `components/Backlog.tsx` — the project backlog (todo files + GitHub Issues tabs)
- `components/RunbookPanel.tsx` — scripts editor (project-level, Setup tab)
- `components/Terminal.tsx` — xterm.js over the terminal WS; multiple shells; `claude` menu
- `components/CommandPalette.tsx` — ⌘K actions
- `races.ts` (+ `races.test.ts`) — pure winner-only-fan-out helpers (grouping, headline, button state)
- `archiveQueue.ts` (+ `archiveQueue.test.ts`) — pure bulk-archive helpers: preview headline,
  progress reading, tallies, the **select-mode rules** (`bulkBar`/`cardPick`/`togglePicked`) and
  the **feed reducers** (`mergeArchiveRun`/`archiveFeedEffects`)
- `archiveActions.ts` (+ `archiveActions.test.ts`) — the bulk-archive **action sequence**
  (plan → re-plan → start → stop), lifted out of `App.tsx` with injected deps
- `api.ts` / `types.ts` — REST + WS calls / mirrored backend shapes (keep in sync)
- `attachments.ts` — composer paste-to-file + image/file attach
- Voice dictation — `TaskComposer.tsx` Web Speech API
- `composerAutocomplete.ts` — `/` + `@` triggers, PR-ref detection
- `highlight.ts` + `lang.ts` — Monaco static syntax highlighting
- `styles.css` — the barrel of topic partials in `styles/`

---

- `App.tsx` — top-level state + WS channel routing; decides which main view shows
  (global triage / project home / workspace bento) based on selection. Routes the
  live-refresh signals: `fs` → `codeNonce` (CodePanel reloads its tree), global
  `backlog_changed` → per-project `backlogNonces` (Backlog refetches) — the "no
  manual refresh" wiring. **Agent sessions (WS multiplexing):** a workspace hosts N agent
  sessions (like the shell tabs) — `sessions` (ordered tab ids, client-owned, hydrated
  from `api.getSessions` on open), `sessionTab` (active), `sessionEvents` (each session's
  transcript keyed by id). The `agent` WS envelope carries `session_id`, so the handler
  routes each event to its session's bucket (`mergeSession` registers unseen ones). `events`
  is the ACTIVE session's transcript (what the stream/`StreamMeta`/`awaitingPlan` read);
  `setEvents` targets `sessionTab` via `sessionTabRef` so every existing call-site is
  unchanged. `sendTask`/`rewindTo` scope to the active session (`api.startAgent(…, session)`
  / `api.rewind(…, session)`); `selectSession` lazy-loads a tab's transcript, `addSession`
  opens a fresh one (`nextSessionId`, pure helpers in `src/sessions.ts` + `sessions.test.ts`).
  The switcher tab strip renders in the stream `card-head` (`.stream-sessions`/
  `.stream-session-tab`/`.stream-session-add` in `styles/stream.css`).
  **Submitting while busy (backlog/agent-session-lifecycle.md §1):** `runComposer` client-queues
  ONLY when `shouldClientQueue(wsStatus)` (`composerButton.ts` — the same predicate the button
  label reads, so the label and the behaviour can't disagree), i.e. only behind a genuinely
  running agent/test run. It deliberately does **NOT** queue on `setting_up`: that path filed
  the task into a localStorage queue whose only drainer is an effect scoped to the *selected*
  workspace, so "create from the backlog → run → switch away" stranded it forever. Setup is
  the backend's wait now — POST straight through and the run is held server-side as `queued`.
  `busy` (which still folds in `setting_up`) gates run-app buttons and mutating actions; it is
  no longer what decides queuing. `sendTask` flips `wsStatus` to `agent_running` optimistically
  and **rolls it back in its catch** (via `wsStatusRef`, since it's memoized with `[]`): a
  failed POST means no status event is ever coming to unstick it, and the composer used to
  wedge "busy" until a reload. The drain effect deliberately does not re-queue a failed item —
  it re-fires whenever `queues` changes, so re-queueing would spin.
  **Composer agent config:** the per-run backend/model/effort
  pickers are `App.tsx` state persisted to *global* localStorage (`haro-model`/
  `haro-effort`/`haro-backend`/`haro-local-model`), but `seedAgentConfig` re-seeds them
  from the selected project's `[agent]` default (`api.getAgent`) on project switch
  (`seededAgentProject` ref → fires once per project id, so same-project workspace
  switches keep a per-run override) and on Agent-tab save (`ProjectSettingsModal`'s
  `onAgentChanged` prop). Without the seed the global localStorage value bleeds across
  projects and, because `start_agent` only falls back to the project default when
  `req.model`/`req.effort` are empty, a stale explicit pick silently overrides the
  Agent-tab default. `runArgs` maps the sentinel `"default"` → `undefined` (omit the CLI
  flag); any concrete value is sent verbatim. **Plan Mode:** a `planFirst` toggle
  (`.composer-plan`, persisted `haro-plan`, Claude Code only) sends `start_agent` with
  `plan:true`; when a plan run finishes, `awaitingPlan` (the last terminal event is a plan
  `done`) shows the `.plan-approve` bar between the stream and prompt — **Approve →
  implement** (`approvePlan` → re-run the same session in auto-edit to build it) /
  **Give feedback** (`feedbackPlan` → `runComposer(true)`, another plan turn). Never
  auto-runs (the plan is the review gate). `sendTask(ws, text, plan?)` carries the flag;
  `.plan-approve*`/`.composer-plan*` live in `styles/composer.css`. **Fast Mode:** a
  `fastMode` toggle (`.composer-fast`, amber, persisted `haro-fast`, Claude Code only)
  sends `start_agent` with `fast:true` — mutually exclusive with `planFirst` (enabling
  either toggle clears the other; `sendTask` also lets plan win as a backstop). No
  approval bar: a fast run edits + gates like any normal run, so it just rides the
  composer/optsRef default (including the resume/follow-up send). `.composer-fast*`
  mirrors the plan toggle in `styles/composer.css`.
- `components/Sidebar.tsx` — projects → workspaces navigator. Each project row has a
  **⚙ gear** → `ProjectSettingsModal.tsx` (per-project settings surface: tab-rail +
  pane; the **Git** tab has base-branch picker + `ProjectRemote` + ship-mode selector,
  the **Gate** tab picks the runner/command/dir/scope + merge-result & flaky/coverage
  guards, the tamper alarm, **code to check**, **per-line proof** (`verified_hunks`) and the
  live gate, and surfaces the generated `[gate]` block, the **Setup** tab holds the scripts
  editor, the **Agent** tab picks the backend (Claude Code vs local Ollama/llama.cpp
  — with server URL + model fields for local) and sets the `[agent]` default
  model/effort + budget guardrails,
  the **Environment** tab edits the worktree `.env` seed (`.haro/.env`, gitignored —
  new workspaces are seeded with it), the **Instructions** tab holds the Tier-1
  custom-instructions editor (`ProjectInstructions.tsx`,
  shared with the app-wide Settings so there's one editor impl)).
  Distinct from the
  app-wide `SettingsModal.tsx` (appbar ⚙: Display/Notifications/System — only truly
  global controls; custom instructions are per-project so they live ONLY in
  `ProjectSettingsModal`'s Instructions tab, not here).
  Add a project-config tab by extending `TABS` in `ProjectSettingsModal.tsx`.
  Each workspace row shows a dim `.side-ws-adopted` pill (`adopted · <source>`) when
  `w.kind === "adopted"` — provenance for a foreign worktree registered via the Merge
  Firewall (agentless). Mirrored on Dashboard cards as `.dash-adopted`.
  Rows with `status === "archived"` are **filtered out**: a soft-archived race loser keeps
  its store row so the scorecard can still reach its transcript + branch, but its worktree
  is gone, so it isn't navigable work. The scorecard is its home. (Nothing else produces an
  `archived` row — every other archive path deletes it outright.)
- `components/AgentStream.tsx` + `AgentMarkdown.tsx` — step ① conversation pane.
  The step ① agent view is **one unified surface** (`.agent-console` in `App.tsx`):
  the stream (`AgentStream`, grows), the `ReviewPanel`, and the **prompt** composer
  (`TaskComposer`) are folded into a single bordered card sectioned by hairline
  dividers (not three floating cards). **Per-turn markers:** each `user` prompt row
  renders a `TurnMark` (`.ev-turn-mark`/`.ev-turn-rewind` in `styles/stream.css`) off the
  event's `turn` ordinal (tagged by the backend store). With the `onRewind?(turn)` prop
  wired (App passes `rewindTo`), the marker is a **"⤺ rewind to here"** button: `App.rewindTo`
  confirms, calls `api.rewind(ws, turn, checkpoint=true)` → `POST /workspaces/{id}/rewind`,
  refetches `/events` into the stream, prefills the composer with the returned prompt, and
  switches to the agent view (never auto-runs — mirrors the conflict handoff). Refuses while
  the agent is busy. The pure `deriveTurns(events)` helper (`src/turns.ts`, `turns.test.ts`)
  mirrors `Store.turns` so the UI can compute rewind anchors client-side (`api.getTurns`
  fetches the backend's derived summary). The composer's on-screen header label is
  **"prompt"** (the code names stay `composer`/`submitTask`). `.agent-console` keeps
  `overflow: visible` so the composer autocomplete (`.ac-menu`) can pop upward over
  the stream. The stream section header is a plain `.card-head`: the label on the
  left, the **model · effort badge** (`StreamMeta`, still exported here) + `running…`
  pulse + a **fullscreen toggle** (`streamFull` state → shared `.card--full` overlay +
  `.card-backdrop`, Maximize/Minimize keycap, Esc to exit, ⌘K "Toggle agent stream
  fullscreen") in `.card-head-right`, mirroring the shell/editor cards. The
  `.card--full` class goes on the whole **`.agent-console`** (not just the stream
  section) so fullscreen floats the entire grid — stream + review + prompt composer —
  together; the only CSS caveat is that `.stage-body .agent-console` is excluded from
  the chrome-strip rule via `:not(.card--full)` so it keeps its border/radius/shadow
  when floated (bento.css). **The whole main column is ONE grid** (`.main-stage`
  in `App.tsx`): a shared top steps band (`.stage-steps` → `renderFlow()`, hoisted in
  `App.tsx`) over a `.stage-body` that holds every step's `.main-view` (only the
  `mainView`-active one is shown). The stage owns the border/radius/shadow and strips
  each inner card's chrome (`.stage-body .agent-console/.card/.pane`) so agent ①,
  code ②, gate ③, ship all read as one seamless grid with the stepper as its top
  band. `.card--full`/`.pane--full` (fullscreen) keep their own chrome. **Adopted
  worktrees (`workspace.kind === "adopted"`) are agentless** — `renderFlow` passes
  `kind` to `flowSteps`, which drops the ① agent step (returns `[code, verify, ship]`),
  so `②` renumbers to `①`; `selectWorkspace` also opens `mainView` on `"code"` instead
  of the empty agent stream. Change the
  agent-view layout there + the `.main-stage`/`.stage-steps`/`.stage-body`/
  `.agent-console`/`.console-sec` rules in `styles/bento.css` (mobile hides
  `.stage-steps` — the bottom tab bar navigates). When `wsStatus === "merged"` the
  steps row also renders a `.flow-continue` button (right-aligned via `margin-left:auto`)
  that fires the same `continueWork` handler as GitPanel's "Continue on a new branch",
  and the outer `.bento` grid gains `.bento-merged` (a subtle purple frame, `--merged`).
- `components/CodePanel.tsx` — step ②, Monaco editor + file tree (`MonacoEditor.tsx`, lazy-loaded, local workers). Multi-file **open tabs** (unsaved dot, close-guard, save-all/⇧⌘S); pure tab logic in `src/codeTabs.ts` (`codeTabs.test.ts`). **Clickable breadcrumb** path header (`.ed-crumbs`): each folder segment reveals that folder in the tree (`revealDir` → expand ancestors + scroll the `data-ftdir` row via `treeRef`), the file segment is inert. **Go-to-file (⌘P)** fuzzy open: `GoToFile.tsx` overlay (reuses `.cmdk-*` styling + `.gtf-*`) over the flattened worktree tree, ranked by `src/fuzzy.ts` (`fuzzy.test.ts`); gated on the `viewActive` prop (App passes `mainView === "code"`) so the hotkey doesn't hijack browser-print from other steps. **Binary / large-file guard**: `files.read_file` (backend) size-caps at `_MAX_BYTES` (1.5 MB) and binary-sniffs (NUL byte or non-UTF-8), returning `{content:"", error, size}`; `CodePanel` stores that as the tab's `guard` and renders a `.ed-guard` "preview not available / download" panel (never Monaco/diff/md-preview) with a download link via `api.downloadUrl` → `GET /raw?download=1` (attachment disposition). Backend covered by `tests/test_read_file_guard.py`. **Tree file ops** (right-click a tree row / empty space → `.ctx-menu`): new file, new folder, rename/move, delete-with-confirm — backed by `files.create_entry`/`rename_entry`/`delete_entry` (traversal-guarded, no-clobber, root-delete-refused; `tests/test_file_ops.py`) via `POST /workspaces/{id}/fs/{create,rename,delete}` (`api.createEntry`/`renameEntry`/`deleteEntry`); open tabs are remapped on rename and closed on delete. **Inline diagnostics**: `MonacoEditor.tsx` runs the TS/JS language service with *syntax* validation ON (real parse errors, no false positives) but *semantic* OFF (no node_modules type graph → would be all "cannot find module" noise); it passes the file `path` to `<Editor>` (real URI → correct .ts/.tsx script kind) and applies the worktree's tsconfig `compilerOptions` (jsx/target/decorators) via `applyTsCompilerOptions`, fetched by `CodePanel` from `GET /workspaces/{id}/tsconfig` (`api.getTsconfig` → `files.resolve_tsconfig`, follows `extends`, JSONC-tolerant; `tests/test_tsconfig.py`). *Semantic* type-squiggles are **closed as not-planned** (`backlog/code-editor.md` → "Closed, not planned"), not a gap: they'd need the whole node_modules type graph loaded into the worker per arbitrary worktree, and the ③ gate already type-checks the real project with the real resolver. Reopening it is a one-line flip (`noSemanticValidation: false`) plus a type-defs loader. **Per-file diff review** (the `diff` toggle in `.ed-head` → `MonacoDiffEditor`, read-only): two reviewer controls beside the toggle. **Commit-by-commit** — a `.ed-diff-commit` `<select>` steps the diff through the branch's own commits (`api.gitLog` filtered to `own`, refreshed each time the lens opens) instead of the full squashed working-vs-base: picking a sha diffs `<sha>^` vs `<sha>` (both fetched via `api.readFileBase(ws, path, ref)` → `GET /file/base?ref=` → `git_ops.show_file`, cached per-sha on the tab as `commitSides`); the default empty option is working-tree (`base` cached + live buffer). **Split vs unified** — a `.ed-diff-layout` seg2 toggle drives `MonacoDiffEditor`'s `renderSideBySide` (applied live via `updateOptions`, no remount); the choice is a global reviewer pref persisted to `localStorage["haro.diffSplit"]`. The `diffSides` memo resolves the two panes for the current mode (loading / not-diffable / content); the editor is keyed by `path + commit` so a mode switch loads fresh content. Backend `ref` path covered by `tests/test_show_file.py`. **Sticky editor state per workspace**: open files, active tab, per-file cursor, and markdown code/preview mode persist to `localStorage` (key `haro-editor-<workspaceId>`) and restore on workspace switch / reload — pure serialize/parse in `src/codeSticky.ts` (`codeSticky.test.ts`); `CodePanel` hydrates on `workspaceId` change (re-reads each file via `hydrateTab`, drops missing ones, gated by `hydratedRef` so a mid-switch empty list never clobbers the saved snapshot), tracks the cursor through Monaco `onDidChangeCursorPosition` into `cursorsRef` + a 400 ms debounced write (`schedulePersist`), and restores it in the editor's `onMount`. Buffer contents are NOT stored (re-read from disk) — it remembers *where you were*, not unsaved edits. ⚠️ `monaco-editor` + `@monaco-editor/react` MUST stay in `vite.config.ts` `optimizeDeps.include` — they're only reached via a lazy `import()`, so without it Vite discovers them mid-session on first file-open and forces a full page reload (bounces the SPA back to root). **Monaco⇄nvim toggle:** the panel root is `.code-wrap` (column) — a `.code-topbar` seg2 toggle (`.code-kind`, `editorKind` state, persisted to `localStorage["haro-code-editor"]`) over either the Monaco split (`.code`, shown when `editorKind==="monaco"`) or the nvim PTY pane (`.code-nvim`, a `<Terminal path="/ws/workspaces/{id}/editor">`). The nvim pane mounts lazily on first switch then stays mounted (display-toggled) so flipping back to Monaco keeps the nvim session + unsaved buffers alive; it only closes on workspace switch (CodePanel unmount). Which nvim config launches is the backend's `[editor] nvim` (see `terminal.spawn_editor`).
- `components/GatePanel.tsx` / `ImpactMap.tsx` / `AnalysisPanel.tsx` — the **verify**
  step view (`mainView === "gate"`; step ③): the live test grid, impact map,
  coverage/flaky insights, **and the AI-review lane**. Verify **is** the ③ stepper
  button now (`flow.ts` labels it "verify" but keeps `key: "gate"` — routing/`mainView`
  all still use `"gate"`, so don't rename the key); its badge shows the pass/fail
  tally (`N✓ M✗`, tone-colored, no emoji). It used to be filtered out of the stepper
  into a top-strip `.stat-gate` chip — **that chip was removed** (redundant with the
  step); the top strip keeps only `deps`. Opened by clicking step ③, ⌘K → gate, or a
  blocked ship step (`stepTarget` routes a blocked `git` step to `gate`).
  **Tabs:** `grid` (test cells) · `impact` · **`AI review`** · **`trust`**. The AI-review
  tab is the `ReviewLane` subcomponent: `onRunReview` → `App.runReview` → `api.runReview` →
  `POST /review` (backend `review.py`); findings render sorted by severity, each
  dismissable (local state) or sent to the agent via `onFixFinding` → `App.fixFinding`
  (reuses the `addComment` composer round-trip + switches to the agent view). Advisory
  — findings never change gate status. The **`trust` tab** renders the shared
  `components/TrustChecklist.tsx` component (`backlog/autonomy-ladder.md` §2): the
  autonomy-ladder checklist — every `TrustReport.condition` as a **met/unmet row with its
  backend `detail`**, deliberately **never a score/percentage** ("why you can't auto-ship
  yet"). Fed by the `trust` prop (`TrustReport | null`) App hydrates via `api.getTrust`
  (`GET /workspaces/{id}/trust`) on workspace select and refreshes live off the `trust`
  payload piggybacked on the `status` channel (`msg.trust` → `setTrust`) — no
  fetch-per-verdict. Headline is a state, not a number (`armed` → `all conditions met` →
  `locked`); the tab badge counts *required unmet* blockers (`trustUnmet`). **The checklist,
  the label maps (`TRUST_LABELS`/`TRUST_ACTION_LABELS`/`TRUST_FIX_LABELS`), and `trustUnmet`
  all live in `TrustChecklist.tsx`** — one source of truth so the ③ gate tab and the ④ ship
  merge-blocked banner (below) render *identically*; the `TrustReport`/`TrustCondition` shape
  mirrors `backend/haro/trust.py` in `types.ts`. An unmet row's **`fix` token** (`TrustFix` in
  `types.ts`: `gate_settings` · `run_full` · `ribbon` · `tamper`) is routed by each host's own
  handler: `GatePanel.handleTrustFix` (`tamper` and `ribbon` both snap to the `grid` tab, which
  carries the `green*` chip and the regression ribbon) and `App.shipTrustFix` from the ④ ship step
  (everything but `gate_settings` hops to the gate view + bumps `gateFocusNonce`, which snaps to
  `grid`). Adding a token means: the backend `Condition.fix` branch, the `TrustFix` union,
  `TRUST_FIX_LABELS`, and both handlers. `Record<TrustFix, string>` makes `tsc` catch a missed
  label, but not a missed handler. Rendering is covered by `TrustChecklist.test.tsx`
  (`renderToStaticMarkup`, no jsdom). **Fullscreen** (`.pane--full`) must stay
  excluded from `.main-gate > .pane { width: 100% }` (bento.css) or the fixed pane
  overflows the right screen edge. The gate stays in the `flow.ts` truth model (drives
  the ship step's blocked/ready state); don't remove it there.
  **`GateErrorCard`** (a gate that *couldn't run*, `test.status === "error"`) frames the
  failure by `error_kind` via `gate.ts` `gateErrorFraming(kind, adopted)` — setup vs
  no-tests vs crash. For an **adopted** worktree (`adopted` + `onReRunSetup` props threaded
  from `App.tsx`: `workspace.kind === "adopted"` + `rerunSetup`) a `setup`-kind error reads
  **"Environment, not code"** (`.gate-errcard-env`, off the red palette) with a **re-run
  setup** button (`POST /workspaces/{id}/setup`) beside re-run-gate — the Merge Firewall
  cry-wolf fix (backlog/merge-firewall.md §2). Backend side: `gate.auto_gate_allowed`.
  **Regression ribbon** (the `Ribbon` subcomponent in the tab strip, last 24 runs of the
  `history` prop ← `GET /workspaces/{id}/history`, oldest → newest): each dot's class + tooltip
  come from `gate.ts` **`ribbonDot(run, selected)`** (pure, `gate.test.ts`) — `.rdot-{status}`,
  `.rdot-impacted` for a partial run, `.rdot-sel`, and **`.rdot-star`** for a `green*` run
  (`tamper_findings.length > 0`), an amber asterisk hung above the dot in `test-grid.css`
  (`.rdot-star::after`; `.rdot-star-block` recolors it red when `tamper_blocked` already turned
  the run red, so the star never implies "green" on a dot that blocked a merge). That's
  backlog/tamper-alarm.md §3's history half: without it a suspicious green launders itself into
  the record as soon as the next clean run lands. **Time-travel:** clicking a dot sets
  `pastRunId`, and `viewTest = pastRun ?? test` / `viewCells = casesToCells(pastRun.cases)`
  re-point the WHOLE grid body at that run — cells, summary, `merge_note`, and the `green*`
  `TamperBanner` (findings persist per-run because `db.py` snapshots a `TestRun` as one
  `model_dump_json` blob). The `.gate-timetravel` strip renders **first**, above those banners
  (they describe the past run, not the live one) and states the past run's own `green*` verdict
  (`.s-star`, or `.s-fail` when blocked) — the header verdict tracks the LIVE `workspace.status`,
  so it can't. The banner is keyed by run id + `defaultOpen={!!pastRun}` so hopping between
  starred dots lands on the findings; `onRestore` is withheld while time-travelling (a past
  run's findings describe a diff that may be gone, so "restore" would be stale work). A live
  run clears `pastRunId`.
- `components/GitPanel.tsx` — step ④, checkpoint commit / merge / PR + CI status,
  and the **Files changed** diff (renders `DiffView.tsx`, the branch-vs-base
  unified diff — promoted here from the gate, since ④ ship is where you review; it also
  forwards the `verified`/`onReviewResidue` props to `DiffView` for Verified Hunks, but
  **only when no single commit is selected** — see `DiffView` below).
  **The merged verdict:** `merged = gateStatus === "merged" || pr?.workspace_merged`.
  ⚠ Never `pr?.state === "MERGED"` — a branch NAME stays MERGED on github.com forever, so
  the SHA-blind version painted ④ purple while the sidebar dot, `.bento-merged` and
  "Continue on a new branch" (all keyed on `workspace.status`) correctly read green, and
  Continue then 409'd. `workspace_merged` is the head_sha-aware verdict the backend
  reconciles on that very `GET /git/pr` (`main._adopt_merged_state`) — one predicate, both
  sides. Tests: `backend/tests/test_merged_status_sync.py`.
  **Conflict handoff:** `pr.mergeable === "CONFLICTING"` (from `git_panel.pr_status`,
  refreshed on load/⟳) drives the amber merge banner + blocks `canShip`; a **"Help
  resolve with AI"** button builds a resolve-conflicts prompt and calls the
  `onResolveConflict` prop → `App.tsx` `resolveConflictWithAI` prefills the composer
  (`setTask`) + switches to the agent view (no auto-run — the dev clicks run).
  **Merge-blocked trust checklist:** when the merge is blocked *because the gate isn't
  green* (`blockedByGate` = the exact `409 merge blocked: gate is not green` case) AND the
  project is on the ladder (`trust.enabled`), GitPanel renders the shared `TrustChecklist`
  under the blocked banner (`.gh-trust` wrapper), so "merge blocked" and "auto-merge locked"
  speak one language. Fed by the `trust` prop; unmet rows deep-link via `onTrustFix` →
  `App.tsx` `shipTrustFix`, which hops to the ③ gate step (guard toggle → Gate settings;
  `run_full` → gate view + `runGate`; `ribbon` → gate view + `gateFocusNonce`).
- `components/DiffView.tsx` — collapsible per-file unified-diff renderer (parses
  raw `git diff`); click an add/del line → review comment to the composer.
  **Verified Hunks** (`backlog/verified-hunks.md` §3): the optional `verified` prop
  (`VerifiedHunksResponse`, App fetches it via `api.getVerifiedHunks` on workspace select + on
  every gate verdict) turns the diff into a triage surface — a per-hunk badge, a per-line gutter
  dot on added lines (unified rows AND `SplitCell`, new side only), untested files/hunks sorted
  first, and fully-executed files collapsed on arrival. **Absent prop ⇒ byte-identical to the
  pre-feature diff**, pinned by `DiffView.test.tsx`. Threaded from `App.tsx` → `GitPanel` →
  here, and deliberately NOT passed for GitPanel's single-commit lens (`selectedCommit`) — that
  patch has different line numbers, so the map would describe other lines.
  **All copy + tallying lives in `src/verifiedHunks.ts`** (pure, `verifiedHunks.test.ts`):
  `indexProof` · `lineDot` · `hunkProof` (computed from the lines the hunk actually RENDERS, so a
  badge can't describe lines it isn't showing) · `mergeProof` · `hunkBadge` · `unexecutedCount`
  (the sort key) · `collapsesByDefault` · `residueReviewItems`. The word "executed" is
  load-bearing: an executed line is not an *asserted* line, and a test asserts that no label or
  tooltip anywhere contains verified/proven/correct — change copy there, not in the component.
  Five hunk kinds: `executed` ("executed by the green suite" — §4's "by N passing tests" waits for
  real attribution) · `partial` ("K of M added lines never executed") · `unmapped` ("no test
  imports this file") · `nonexec` ("no executable lines added", so a comment-only hunk isn't
  accused) · `stale` ("gate ran on an older version of this file", and NO dots at all).
  `+ review the residue → agent` → `App.reviewResidue`, the same batch-into-the-composer path as
  fix-all / restore-weakened-tests / code-to-check. Reviewer prefs persist:
  `haro-diff-untested-first` (defaults ON) and `haro-diff-mode` (Unified/Split, which was never
  persisted before). Styles: `.diff-proof*` / `.diff-dot` / `.diff-hunk-toggle` /
  `.diff-sort-toggle` in `styles/diff.css`. Backend half: `backend/haro/verified_hunks.py`.
- `components/ReviewPanel.tsx` — inline review comments round-tripping to the
  composer as follow-up tasks.
- `components/Dashboard.tsx` / `ProjectDashboard.tsx` — global triage / per-project
  home (backlog rail + cards). Each card's glance data is denormalized off the workspace
  (no fetch-per-card): the `gateLine` helper reads `w.gate` (`GateSummary`) and the
  `trustMeter` helper reads `w.trust` (`TrustSummary`) → a streak bar + rung label
  (`locked`/`ready`/`auto-PR`/`auto-merge`), hidden when the project isn't on the ladder.
  Both refresh live off the `status`-channel `gate`/`trust` payload merged in `App.tsx`.
  `tamperStar(status, gate)` reads the same summary's `tamper_count`/`tamper_note` → the
  **`green*`** card (starred verdict word, dashed-green rail `.dash-card-star`, `.dash-tamper`
  reason line), and `attentionSummary(reds, starred)` builds the attention banner's headline
  over reds **plus** starred greens (amber-keyed `.dash-attention-star` when nothing is
  actually failing). Both are pure + tested in `dashboardStatus.test.ts`; the shared `green*`
  wording lives in `gate.ts` `tamperCountSummary`. backlog/tamper-alarm.md §3.
  **Winner-only fan-out (backlog/winner-fanout.md §3):** an optional `races` prop is run
  through `races.ts` `groupRaces` FIRST, and everything after it — the counts, the attention
  banner, the card grid — works on the returned `loose` list only. A race owns its lanes'
  triage (that IS the scorecard), so surfacing three red lanes in "N gates need you" would
  rebuild the pile of N results the feature exists to remove. Each race renders as a
  `RaceScorecard` ABOVE the grid, because a decided race is one diff waiting for review —
  more actionable than any card below it. `ProjectDashboard` just forwards the same four
  props (`races`/`onPurgeRaceLosers`/`onStopRace`/`purgingRace`) to the shared `Dashboard`.
  **Bulk archive select mode (backlog/bulk-archive.md):** with an `onBulkArchive` prop the
  head grows a `select` toggle; while `picking`, a card **is a checkbox** (click picks instead
  of navigating, `.dash-tick` is a painted span because the card is already a `<button>` and a
  nested checkbox would be invalid interactive nesting), and cards outside the first-picked
  project are locked out — a queue drains one repo. Select mode is opt-in precisely because
  turning an ordinary card click into "tick one for a destructive batch" is how you archive by
  accident. The dashboard only ever **collects a selection**; `App.planBulkArchive` turns it
  into a backend plan.
  ⚠ The component keeps only the `useState`: every select-mode *decision* is
  `archiveQueue.ts` (`bulkBar` — counts, legality, and the exact id list an archive targets;
  `cardPick` — ticked/locked/class; `togglePicked`), because those decide what a destructive
  button aims at. Two presentational pieces are **exported for test**: `BulkSelectBar` and
  `WorkspaceCard` (the card was lifted out of the grid `.map` so its select-mode states can be
  rendered directly — inside the map they were reachable only by clicking, which this suite
  can't do). `Dashboard.test.tsx` covers all three.
- `components/ArchiveQueuePanel.tsx` — bulk archive's one panel for both halves
  (backlog/bulk-archive.md): the **dry-run plan** the user confirms, and the **live queue** it
  becomes — the same `ArchiveQueueRun` model, so the dialog can't promise what the queue won't
  do. Two rules: (1) it **never computes admission** — the "include them anyway" checkbox calls
  `onToggleForce` → App re-fetches the backend's plan (a round trip, on purpose; a client-side
  copy of a `branch -D` rule is how a UI deletes something it said it wouldn't); (2) held-back
  workspaces are listed **with the reason each one would lose**, since "3 skipped" alone is an
  invitation to force it blindly. The risk block keys on `held.length > 0 || run.force` — on
  `held` alone the include-them checkbox **vanished the moment you ticked it**, leaving no way
  back to the safe plan (caught by `ArchiveQueuePanel.test.tsx`, which renders every state the
  backend can put the panel in: plan · held-back · forced · draining · stopping · done ·
  stopped). Copy/tallying is pure in `archiveQueue.ts` (`previewHeadline` · `progress` ·
  `summary` · `counts` · `heldBack` · `outcomeTone` · `selectable`). App wiring: `archiveRun`
  (plan *or* live) + `archiveRunRef`, `archivePickRef` (the selection, so a re-plan targets the
  same set), `archiveSeenRef` (resync the sidebar per completed item, and drop the selected
  workspace if the queue archived it), the `notify`/`archive_queue` feed handler, and
  `loadAll`'s reattach of a still-draining run — but the *logic* under all of it is
  `archiveQueue.archiveFeedEffects`/`mergeArchiveRun` and `archiveActions.bulkArchiveActions`,
  both unit-tested, leaving App with declarations and JSX. Styles: `styles/archive-queue.css`.
- `components/RaceScorecard.tsx` — the winner ceremony (backlog/winner-fanout.md §3), the
  panel that IS the argument for this feature: rivals hand you N diffs, haro hands you one
  candidate plus a receipt. Three rules: the **winner** gets the card (`.race-winner`, the
  one thing you're asked to click); the **losers are never censored** — every lane keeps its
  five-criterion row (`verdict · cost · wall · coverage Δ · merge-clean`, each won/lost, with
  the policy's own axis `decisive`), because a judge you can't second-guess is just another
  opinion; and a **tie or a refusal looks nothing like a win** (its own headline tone, not a
  winner card with a caveat). Falls back to the lane cache when `race.verdict` is still null,
  so a live race populates from the first lane rather than sitting empty. `purge losers` only
  renders after the ceremony archived them, and says what it costs. Display logic is pure +
  tested in `races.ts`/`races.test.ts` (`groupRaces`, `raceHeadline`, `raceButtonState`).
- **Race wiring in `App.tsx`** — `races` (keyed by project) + `racePreflight` state, hydrated
  in `loadAll` and re-fetched per project (§0's answer is per project; a stale "ok" would
  enable a button about to 400). The `notify`/`race_*` global-feed events carry the whole
  `RaceRun`, so the handler merges it in with no fetch; `race_done` beeps + toasts (an
  unattended decision you didn't notice is worse than noise) and `race_budget` toasts
  (stopping lanes for money must never be silent). The composer's **`race ×N`** button
  (`.composer-race`, beside the model/effort pickers — a race IS a sweep over those two
  knobs) is driven by `races.ts` `raceButtonState`, which surfaces §0's refusals **verbatim**
  as the tooltip: they're written to be actionable, and a paraphrase costs the user the fix.
  A lane workspace shows a `.race-chip` in the stats strip linking back to its scorecard.
  Styles: `styles/race.css` (imported right after `dashboard.css`).
- `components/Backlog.tsx` — the project backlog. Two backlog sources behind
  top-level source tabs (`.backlog-tab`, `tab: "todo" | "issues"`): **Todo files**
  (`api.getTodo`, grouped active/todo/done) is a searchable master-detail (file rail
  + selected file). The detail pane renders the file's `blocks` **interleaved** —
  note blocks via `<FileMarkdown>` (read-only context), item blocks as the clickable
  seed-to-workspace rows (`renderTodoItem`, mechanism unchanged) — so a backlog file
  doubles as a notes doc. **In-app editing:** a **New** button (rail) + **Edit**
  button (detail head) open a raw-markdown editor (`editorBody`) that `PUT`s via
  `api.putTodo` → refetch (`reloadNonce`); a `- [ ]` line is a task, any other prose
  is notes (no forced checkbox). Editor/new-file state closes on file/project switch.
  **Fullscreen** toggle (`full` state → shared `.card--full` overlay + `.card-backdrop`,
  Maximize/Minimize keycap, Esc to exit) in `.side-backlog-head-right`, self-contained
  in the component; `.side-backlog.card--full` overrides the base `height:42%` so the
  fixed insets govern.
  **GitHub Issues** (`api.getIssues`) is a full-width live list
  with a GitHub-style Open/Closed/All state filter (`issueFilter`, defaults to open),
  plus client-side display polish over the live fetch (no refetch): a text search
  (`issueQuery`, matches #number/title/label), clickable **label-filter chips**
  (`labelFilter`, single-select toggle; `labelCountsOf`), and a **group-by-label**
  toggle (`groupByLabel`, `groupIssuesByLabel` — one group per first label, unlabeled
  last, mirroring the todo `## heading` model). Those three pipeline helpers are pure +
  exported from `Backlog.tsx` and unit-tested in `issueFilters.test.ts`. (No assignee
  chip: the fetch is `--assignee @me`, so every row is the same assignee.)
  Issue rows reuse the pending ○ / seeded ◐ states — a closed issue shows a dimmed ✔ +
  "closed" badge but stays clickable-to-seed (backtrack). Both sources click through
  the same `onStartTodo(title, task, seedKey)` path; an issue seeds `title`→branch,
  `body`→brief + a `Reference: #<n>` line, `seed_key="issue:<n>"`. Issues refetch on the
  same `statusKey`/`refreshSignal` as todos (no new poller) plus a ⟳ force-refresh;
  offline/rate-limited shows the cache "as of HH:MM". Each issue row has an expand
  chevron (`expandedIssue`) that opens `components/IssueDetail.tsx` inline — a
  read-only `api.getIssueDetail(projectId, n)` fetch of body + comments (`gh issue
  view`), so a dev reads the discussion without leaving haro. Styles in `styles/backlog.css`.
- `components/RunbookPanel.tsx` — scripts editor (setup/run/archive, login-shell
  toggle, save-local vs promote-to-team); mounted **project-level** in the Setup
  tab of `ProjectSettingsModal.tsx`. Workspaces show the effective (inherited)
  config read-only in the rail's app strip and link to the Setup tab — no per-workspace
  scripts editor (single source of truth). `GET /workspaces/{id}/scripts` is the
  read-only effective config; edits go through `PUT /projects/{id}/scripts`.
- `components/Terminal.tsx` — xterm.js over the terminal WS; props `workspaceId` +
  `shellId` (→ `/ws/workspaces/{id}/terminal/{shellId}`, in the effect deps so a new
  id remounts onto a fresh PTY) + an optional `path` override (the nvim editor pane
  passes `/ws/workspaces/{id}/editor` to reuse this exact xterm↔PTY plumbing for a
  different backend program; also in the effect deps) + `autoFocus` (gates
  `term.focus()` in the PTY `onopen` handler, read via a ref so it stays current
  without re-running the effect).
  **Focus on open:** the terminal only grabs focus on connect when its shell was
  opened intentionally — `App.tsx` tracks the one such shell in `focusShellOnOpen`
  (set by `addShell`/last-shell-restart) and passes `autoFocus={id === focusShellOnOpen}`.
  On workspace select `selectWorkspace` clears it to `null` and focuses the composer
  (`#agent-input`, rAF-deferred) instead, so a freshly-opened workspace (esp. one seeded
  from a backlog item) lands on the prompt for an immediate `⌘↵`, not the terminal.
  **Multiple shells per workspace:** `App.tsx` owns
  `shells: string[]` (ordered shell ids, monotonic via a `shellSeq` ref so ids are
  never reused) + `termTab` (active pane — a shell id or `"log"`). The `.term-card`
  header is a **pane-tab strip** (`dev log` · `shell 1` · `shell 2` … · `+` add) with
  the actions on the right; `addShell`/`closeShell` mutate `shells`, and closing the
  **last** shell respawns a fresh one in place (never zero — new id → remount). Every
  shell stays mounted (PTY persists), inactive ones just `display:none`. Per-shell
  imperative handles live in a `termHandles` ref-`Map` (callback ref per `<Terminal>`);
  the `claude` menu + `⌃\`` focus hotkey resolve the active shell via `activeShellId()`
  (stale-closure-free via `shellsRef`/`termTabRef`). The card also has a **fullscreen
  toggle** (`termFull` → `.card--full` + `.card-backdrop`, Esc to exit); xterm refits
  via its `ResizeObserver`. `TerminalHandle` (`forwardRef` → `insert(text)`/`focus()`):
  `insert` writes `{t:"in", d:"\x15"+text}` (Ctrl-U clears the line; NO trailing
  newline). The **`claude` command menu** (`.claude-menu`/`.claude-pop`, `CLAUDE_CMDS`
  in `App.tsx`, styled in `runbook.css` reusing `.ctx-menu`/`.ctx-item`; shell-tabs
  only): interactive claude slash commands (`/mcp`, `/usage`, `/login`, `/config`)
  can't run in the agent stream (headless `claude -p --output-format stream-json`), so
  the menu drops the equivalent onto the active shell's prompt — `/mcp`→`claude mcp
  list`, `/doctor`→`claude doctor`, `update`→`claude update` (verified CLI subcommands;
  there is NO `claude config`), and **Claude session**→`claude` (opens the REPL).
  `App.runClaudeCmd` switches to the active shell then `requestAnimationFrame`s the
  insert (the PTY is hidden, not unmounted, on the dev-log tab). Add a command →
  extend `CLAUDE_CMDS`. Tab-strip styles (`.term-shell-tab`/`.term-shell-x`/
  `.term-add`/`.term-focus-key`) live in `runbook.css`.
- `components/CommandPalette.tsx` — ⌘K actions.
- `api.ts` — all REST + WS calls; `types.ts` mirrors backend pydantic shapes —
  keep these two in sync when changing a request/response shape.
- `attachments.ts` (+ `attachments.test.ts`) — composer **paste-to-file**: the
  ≥20-line / ≥2000-char threshold, folding `.context/` attachments into the task as
  `@path` mentions (`shouldAttachPaste`, `composeWithAttachments`), plus **image /
  file attach** (`fileToBase64`, `attachmentStat`) — pasted images + the 📎 paperclip
  upload to `.context/` via `POST /workspaces/{id}/context/upload` (base64 JSON, no
  multipart dep; backend `files.write_bytes`). Chips + paste live in `TaskComposer.tsx`
  (`onAttachFiles`) / `App.tsx` (`attachFiles`); image chips preview via `api.rawUrl`.
- **Voice dictation** (frontend-only, no backend/deps): `TaskComposer.tsx` owns the
  Web Speech API recognition (`SpeechRecognition ?? webkitSpeechRecognition`, feature-
  detected → exported `SPEECH_SUPPORTED`) — it inserts finalized + interim transcript
  at the caret through the existing `onChange`/`pendingCaret` path (overlay stays in
  sync). The mic **button** is rendered in `App.tsx`'s `.composer-actions` beside the
  📎 paperclip, driven via `micToggleRef` + `onListeningChange` (`.composer-mic`/
  `.composer-mic-live` pulse in `styles.css`). `Mic` glyph in `icons.tsx`. Caveat: the
  API relays audio to Google — a `TODO(local-first)` in `TaskComposer.tsx` flags a
  future on-device (whisper.cpp) swap.
- `composerAutocomplete.ts` (+ `.test.ts`) — pure composer logic: `/` + `@` trigger
  detection/filtering AND `findPrRefs` (detects `PR #N` / bare `#N` at word boundaries).
  `TaskComposer.tsx` renders these: inline `.ctok-pr` highlight in the overlay + a
  clickable PR **chip strip** (`prBaseUrl` prop → `${base}/pull/N`). The base is
  `RemoteConfig.web_url` from `GET /projects/{id}/remote` (backend `git_ops.web_url_from_remote`
  normalizes ssh/https origin → `https://host/owner/repo`); `App.tsx` fetches it per project.
- `highlight.ts` + `lang.ts` — diff/code-block syntax highlighting via Monaco's
  static `colorize` tokenizer (no editor instance); `lang.ts` is the shared
  extension→Monaco-language map used by both the highlighter and `CodePanel`.
- `styles.css` is a **barrel** — it only `@import`s topic partials from
  `styles/` (one per surface: `base` = tokens/`@font-face`/reset, `buttons`,
  `sidebar`, `backlog`, `bento`, `editor`, `composer`, `gate`, `test-grid`,
  `git-ship`, `mobile`, …). Vite inlines the imports **in barrel order**, so the
  cascade equals the old single sheet: `base` first, `mobile` last. To edit a
  rule, grep the class and open its partial; to add one, drop it in the matching
  partial (new surface → new partial + an `@import` in the right cascade slot).
  Shared form controls live in `styles/forms.css` — e.g. `.switch` is the on/off
  **toggle** (a bare `<input type="checkbox">` painted as an accent-green track +
  knob via `appearance:none` + `::before`). For any settings/runbook boolean, add
  `className="switch"` to the checkbox rather than styling a new tick-box; it
  intentionally resets the global `input { flex:1 }` rule, so don't re-add a
  container-scoped `input` rule (its higher specificity would collapse the knob).
