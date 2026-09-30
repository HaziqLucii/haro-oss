# haro redesign: implementation spec

This is the handoff for implementing the redesign shown in `prototype/haro-redesign.dc.html` (the clickable prototype). Open the prototype next to this doc. The Tweaks panel option `startScreen` switches between first run, dashboard, workspace and settings. The **Preview state** bar on the workspace screen steps through idle, running, red, green and merged.

The north star is unchanged: **no agent's work is mergeable until the gate is green, and you can watch it happen.** Every change below exists to make that promise easier to see and easier to trust.

---

## 0. Ground rules (brand, unchanged)

- Dark only, one theme. Warm monochrome: ink `#d8d0c5` on `#0b0a09`. Panels `#131210`, raised `#1b1915`.
- Hierarchy comes from ink opacity (`.86 / .66 / .42`) and hairlines (`rgba(216,208,197,.08 / .12 / .2)`).
- **Green `#41d183` means the gate only**: gate verdict, test cells, diff adds, "line ran" markers, coverage bar for this tree. Never use it on buttons, focus rings or generic meters. Fix `copy markdown` / `post to PR`, which are green today.
- Red `#e0685e` means failures, deletions and the tamper alarm. Lilac `#b3a0d6` means merged.
- Primary button: bone fill `#d8d0c5` with dark text. Secondary: 1px hairline border. Tertiary: text only.
- Type: Space Grotesk for UI and headlines, Space Mono for labels, data, paths and kbd (uppercase, `letter-spacing .14–.2em`), Fraunces for the `haro.` wordmark only.
- 2px radius, no shadows, film grain overlay (~7% opacity), fades only (`opacity 0→1`, 180–300ms). Nothing slides.
- Status glyph: a square, 7–14px. Filled = settled state (red, green, merged). Hollow ink = in progress (agent, gate running, plan). Hollow dim = idle.

## 1. Remove

| Remove | Where (current source) | Why |
|---|---|---|
| Race ×N | `races.ts`, `RaceScorecard.tsx`, `styles/race.css`, race toggle in `TaskComposer.tsx` | Triples cost and clashes with one workspace = one agent. Comparing three diffs is rarely done. If kept, hide it behind an "experimental" setting. |
| `fast` toggle | `TaskComposer.tsx` | Duplicates model/effort; roles cover it. |
| Dictation mic | `TaskComposer.tsx` | Rarely used on desktop; the OS already provides it. |
| Monaco / Nvim switch | `CodePanel.tsx`, `MonacoEditor.tsx` | Keep one editor (Monaco) for quick fixes. Nvim users have the terminal. |
| Extra shells + Claude tab | `Terminal.tsx` | Keep **Dev log** and **one Shell**. The Claude tab duplicates the agent step. |
| Quality scan row | `ReceiptPanel.tsx`, `TrustChecklist.tsx` | Always "not measured", so it's noise. |
| `DEPS —` header label | workspace header in `App.tsx` | Unclear meaning. |
| Purple frame around the active workspace | `styles/base.css` / `App.tsx` | Competes with the gate colours. |
| Long composer placeholder | `TaskComposer.tsx` | Replace with "Describe the next task for the agent…" plus a small `/ commands · @ files` hint. |

## 2. App shell

```
┌ top bar 48px ─────────────────────────────────────────────────────────────┐
│ haro. │ PROJECT / WORKSPACE (breadcrumb, ellipsis) │ [Search ⌘K] [■ 3 need you ⌘J] [?] [Settings] │
├ sidebar 240 ┬ main ───────────────────────────────────────────────────────┤
```

- Root grid: `grid-template-rows: 48px minmax(0,1fr); grid-template-columns: minmax(0,1fr)`. **Must** have explicit `minmax(0,1fr)` columns or the page overflows at ~900px.
- Top bar: the breadcrumb is `flex:1 1 auto; min-width:0` with ellipsis. The search button is `flex:0 1 260px; min-width:0`. The need-you pill and Settings are `flex:none; white-space:nowrap`.
- **Need-you pill**: red square + count + `⌘J`. Click, or press ⌘J, to open the **next workspace in the "needs you" group**, cycling through them. This is a signature interaction.
- Drop the tagline from the top bar; it moves into the first-run screen.

### Sidebar (`Sidebar.tsx`)
- Top: `Triage` (count) and `Backlog` (open count).
- Per project: mono uppercase name + `+` (new workspace). Rows: status square, name (ellipsis), short state word in the state colour (`red`, `green`, `gate`, `agent`, `plan`, `merged`). Merged rows at 55% opacity.
- Bottom: primary `New workspace ⌘N`, secondary `Add project`.
- Remove the per-project ✓ / gear / ⋯ icon cluster. Project settings are reached via Settings → Project, and removal via ⌘K or right-click.

## 3. First run (new; the missing piece)

This opens after Add project, whichever option is chosen (open folder, clone from GitHub, new project). The prototype opens here by default.

- Label `ADDING ~/code/shop-api`, heading "Checking how this project proves itself", one line of explanation.
- Detection rows (square, label, finding, optional one-click fix):
  - Git repository: branch · remote linked
  - Test runner: detected runner + folder + test count
  - Baseline run: runs the suite **on main** once and shows the pass count and duration
  - Dev server: detected command + port
  - Coverage: provider found, or `Install` (needed for per-line proof and "lines no test ran")
  - Secrets: `.env` gitignored → `Copy to Environment`
- Result line: green square + "Gate ready." + "Green means all N <runner> tests in <dir> pass."
- If the baseline is red: show "main is already red (k failing)". Offer "Continue anyway (the gate compares against this baseline)" or "Pick a different test command".
- Footer: `Adjust gate settings` (text) and `Create first workspace` (primary).
- Backend: reuse the stack detection behind `StackProposalModal.tsx` / `InitRepoModal.tsx`, and add a baseline gate run.

## 4. Triage dashboard (`Dashboard.tsx`, `styles/dashboard.css`)

A **list with groups, not a card grid**.

- Header: `TRIAGE · 10 WORKSPACES · 2 PROJECTS`. Headline "3 workspaces need you." (Space Grotesk 38/500). One summary sentence written from the data.
- Filter chips: All · Needs you · Running · Ready to ship · Idle · Merged (with counts). The active chip is bone-filled.
- Groups, in order:
  1. **Needs you**: red gate · plan awaiting approval · green with open look-at items · agent waiting on input
  2. **Running**: agent working · gate running
  3. **Ready to ship**: green, nothing open
  4. **Idle**: no task yet
  5. **Merged**: collapsed by default in production
- Row grid: `78px | minmax(0,1fr) | 54px | 32px | auto`, gap 16.
  - col 1: square + state word (mono, state colour)
  - col 2: flex-wrap of `[name + project · branch]` and `[one-line detail]`, so the detail drops under the name when narrow
  - col 3: 4 progress ticks, one per step (done = ink .42, current = ink, red/green/lilac for verify/ship outcome, pending = hairline)
  - col 4: relative time
  - col 5: one next-action button. Primary (bone) for the Needs-you group, secondary elsewhere.
- Detail line examples: "3 of 16 tests failing in lib/shipping.test.ts", "Plan ready to approve · 6 steps, 4 files", "594 passed · 2 lines no test ran", "Agent editing lib/rates.ts · 3m in", "Gate 412 / 594 · no failures yet".
- Faint katakana watermark (72px, 2% ink) in the bottom-right corner and vertical margin text on the left, both behind the content.
- Multi-select/archive: keep it, but reach it via ⌘K ("Archive merged workspaces") or shift-click rows, not a permanent `select` button.

## 5. Workspace

```
┌ header: name (22/500) · project · branch → main · N behind        [Rename] [Archive] ┐
├ step bar: 01 agent │ 02 code │ 03 verify │ 04 ship │ [Next action →]              ─┤
│ step content (scroll)                                          │ right rail        │
│                                                                │ (clamp 220–296px) │
├ terminal drawer (240px, optional, ⌃`)                          │                   │
└ composer (agent step only)                                     │                   ┘
```

### 5.1 Step bar (replaces the stepper in `App.tsx`)
- Grid `repeat(auto-fit, minmax(150px,1fr))`. The next-action cell wraps to its own row when narrow.
- Each step shows the number, a status square, the name, and **a status line under it**. The active step has a 2px ink top rule and a `#131210` fill.
- Status lines by state:

| state | agent | code | verify | ship | Next action |
|---|---|---|---|---|---|
| idle | ready for a task | no changes yet | runs when agent finishes | blocked | **Run agent** (focus composer) |
| running | done · 14m | 21 files · +367 −130 | running · 412 / 594 | waits for green | *Gate running* (disabled) |
| red | done | 21 files… | red · 3 failing | blocked | **Send failures to agent** |
| green | done | 21 files… | green · 594 passed | ready to merge | **Review & ship** |
| merged | done | 21 files… | green · 594 passed | merged · #232 | **Continue on a new branch** |

- The step opened by default follows the state: idle → agent, running/red/green → verify, merged → ship.
- There is always exactly one primary action on screen for the workspace.

### 5.2 Right rail (replaces app strip + look-at chip + terminal column)
Sections from top to bottom, each clickable:
1. **Gate**: 14px square, verdict word (mono bold, state colour), one-line summary, time. Click → verify. *Visible on every step*, so you never lose the gate.
2. **Needs your eyes**: open count + up to 3 short items (`✕ file` for failures, `○ file` for untested lines). Click → verify.
3. **App**: `:port · running/stopped`, `Run/Stop` (⌘R) and `Open ↗` (external browser).
4. **Run**: model · effort, spend · duration, context meter (ink, never green).
5. Bottom: `Terminal ⌃`` toggle.

### 5.3 Terminal (`Terminal.tsx`)
A bottom drawer in the main column, 240px, toggled with ⌃`. Tabs: Dev log, Shell. Prompt line: `workspace on branch via node vX`.

### 5.4 Agent step (`AgentStream.tsx`, `TaskComposer.tsx`, `styles/stream.css`, `styles/composer.css`)
- Single column, max 760px, generous spacing (gap 20).
- User message: `YOU · 14m ago` label + message in a `#131210` box.
- Agent label: `AGENT · build · sonnet-5 · high`.
- Tool calls: one mono line each: `■ Edit  desktop/main.js  +211 −134`.
- Prose: Space Grotesk 15/1.6, ink .86.
- Turn footer: `done in 14m 1s · 21 files · $9.89` + `Review changes in code →`.
- **Empty state** (idle): "What should the agent do?", one explanatory line, and 3 suggested tasks from backlog/issues.
- **Composer**: textarea, then one row: `[build · sonnet-5 · high ▾]` (opens Roles), `[○ plan first]`, `[+ attach]`, `/ commands · @ files`, `21% context`, `[Run agent ⌘↵]`.

### 5.5 Code step (`CodePanel.tsx`, `DiffView.tsx`, `FileIcon.tsx`)
- Left 260px: **CHANGED · 21** first. Each file has a proof square (green = every added line ran, hollow = some lines never ran, dim = not code), name, `+a −d`. `ALL FILES ▸` is collapsed below.
- Right: sticky file header with path, `+a −d`, legend `● ran in green suite ○ never ran`, `Diff | Edit` toggle.
- Diff gutter: `● / ○` marker column, line number, sign, code. Add rows tinted `rgba(65,209,131,.06)`, delete rows `rgba(224,104,94,.07)`.

### 5.6 Verify step, the centre of the product (`GatePanel.tsx`, `ReviewPanel.tsx`, `LookAt.tsx`, `ImpactMap.tsx`, `styles/gate.css`, `styles/test-grid.css`)
Order is strict: **verdict → what needs a human → evidence on demand.**

1. **Verdict**
   - `■ GREEN` (mono 12 bold, `.22em`) + `vitest · frontend/ · all tests · 4m ago · 2.0s`
   - Headline 44/500: "All 594 tests pass" / "3 tests are failing" / "412 of 594 tests done" / "The gate hasn't run on this tree." / "Merged into origin/main"
   - One sentence of consequence and next step (see the prototype copy)
   - Running: a 2px progress bar
   - Metrics row `repeat(auto-fit,minmax(120px,1fr))`: Tests · Duration · Coverage · Mutation · Flaky
   - Buttons: primary next action · `Run again` · `Impacted tests only`
2. **Tamper alarm (red, when a test was removed or weakened)**: a full-width banner with a 1px red border. `TAMPER ALARM`, "The agent deleted a test that covered this change.", test name + file, buttons `See deletion` and `Restore test` (sends to agent). This is the scariest thing an agent can do, so it should be the loudest element in the app after a red verdict.
3. **Needs your eyes** (green) / **Failing & flagged** (red). The hint reads "Advisory · never blocks the merge" or "Failures block the merge".
   - Row: review checkbox · kind (mono uppercase: `FAILED` in red, `NO TEST RAN`, `NO TEST IMPORTS`, `TEST REMOVED`) · path · one-line detail · `Open diff` · `Ask agent`
   - Reviewed rows drop to 45% opacity
   - Footer: `Add to backlog` · `Send N to agent` (sends all open items as one follow-up prompt)
   - Empty: "Appears when the run finishes." / "Nothing to review until the gate has run."
4. **Evidence**, headed "Can you trust green? Start with the first two." Accordion rows `+ name  meta`:
   1. **Mutation score** (open by default, full ink): "Would the tests notice if this code were wrong? haro made 50 small, deliberate mistakes… caught 41. These survived:" + list of surviving mutants
   2. **Lines no test ran** (full ink): file:line → code
   3. Test grid (live squares, one per ~3 tests, grouped by file)
   4. Impact (tests that touch the change)
   5. Coverage (main vs this tree bars)
   6. Flaky tests (one sentence)

   Rows 3–6 use dimmer names (ink .66).

### 5.7 Ship step (`GitPanel.tsx`, `ReceiptPanel.tsx`, `BranchBadge.tsx`)
- PR title (28/500) with hairline underline, then `branch → origin/main · 1 commit · +367 −130 · 21 files`.
- **Merge panel** (one box):
  - green: green square, "Gate is green. Ready to merge.", count of open look-at items ("won't block the merge"), `Open pull request` (secondary) + `Merge into main` (primary). Border tinted green at 45%.
  - red/idle/running: "Merging is blocked" + reason, `Go to verify` + a dashed disabled "Merge blocked".
  - merged: lilac, "Merged into origin/main as #232", `View #232 ↗` + `Continue on a new branch`.
- **Gate receipt, styled as a shareable card.** Header `haro.` (Fraunces) + `GATE RECEIPT · <sha>` + verdict. Rows: Suite · Tamper alarm · Verified lines ("361 of 367 added lines ran") · Mutation · Agent (model · effort · cost). Footer: "Ran 594 tests on this exact tree · haro.dev/r/<sha>". Actions: `Copy link` · `Copy markdown` · `Post to PR`. **Every merged PR advertises haro**, so make the markdown version beautiful too.
- Commit: one line with sha, message and age. Show a commit box only when the working tree is dirty.

## 6. Overlays

All overlays: backdrop `rgba(8,7,6,.8)` + 3px blur, fade in 180ms, Esc closes, click outside closes.

### 6.1 Settings, merged into one surface (`SettingsModal.tsx` + `ProjectSettingsModal.tsx` → one component)
- 980×660. Left nav: `Search settings`, group **App** (Display, Notifications, Usage, System), group **Project · <name>** (Git, Setup, Gate, Agent, Roles, Environment, Instructions).
- Header: title (24/500), one-sentence intro, **scope tag** (`This device` / `Personal · .haro/local.toml` / `Team · .haro/config.toml` / `Personal · gitignored` / `Read only`).
- Rows: `label + one-line help | control`, hairline between rows. Controls: toggle (34×18 square), select, mono input, segmented control, value, meter (ink), code block.
- Section subheads inside a tab (mono uppercase), e.g. Gate → `BLOCKS MERGE` / `ADVISORY · NEVER BLOCKS`, and Agent → `MODEL` / `GUARDRAILS` / `LOCAL MODEL`.
- **Save bar** appears only when there are changes: "Unsaved changes · saves to <scope>" + `Discard` / `Save`. It replaces the scattered `save`, `save local`, `save shared` and `promote to team` buttons.
- Gate tab opens with a summary line: "Green means every Vitest test in frontend/ passes. Advisory checks below list what to look at but never block a merge."
- Roles: **on by default with sensible picks** (plan Opus·high, build Sonnet·high, review off, scout Haiku). Intro: "Most people never open this page." Drop the generated-TOML preview from the default view; put it behind "View config".
- Display: coding font, density, film grain. Remove the theme card (there is only one theme).
- Usage: meters in ink, never green. Keep an error state but give it a `Retry` button.
- System was empty. Fill it with data folder, shell, launch at login, updates.
- Setup: remove "custom instructions" from Setup, since it lives in Instructions.

### 6.2 Command palette ⌘K (`CommandPalette.tsx`)
- 620px. Input: "Jump to a workspace, run an action, open a setting…"
- Grouped results: **Workspaces** (with status square + project), **Actions** (Next workspace that needs you ⌘J, New workspace ⌘N, Run gate ⌘G, Open backlog, Toggle terminal ⌃`, Keyboard shortcuts ?), **Settings** (deep-links to a tab).
- Coding-font switching moves out of the palette into Settings → Display.
- Footer: `↑↓ move ↵ open esc close`.

### 6.3 Keyboard shortcuts `?` (`HotkeysModal.tsx`)
Two-column list: ⌘K palette · ⌘N new workspace · ⌘I focus prompt · ⌘↵ run agent/commit · ⌘1–4 go to step · ⌘G run gate · ⌘P go to file · ⌘R dev server · ⌃` terminal · ⌘S save · **⌘J next workspace that needs you** · Esc close.

### 6.4 New workspace ⌘N (`NewWorkspaceModal.tsx`)
- Big task input (24/500): "What's the task?"
- Branch: prefix chips (feat/ fix/ chore/ docs/ refactor/ test/) + **branch auto-derived from the task** (`feat/add-multiply-helper`), still editable.
- From: `origin/main · synced 3m ago ▾`.
- Checkbox, **on by default**: "Start the agent with this task right away". The primary button then reads `Create & run agent ⌘↵`, otherwise `Create workspace`.
- Footer note: "Its own worktree. Your main checkout is untouched."

### 6.5 Add project (`AddProjectModal.tsx`, `FolderPicker.tsx`)
Three rows: Open a folder on disk · Clone from GitHub · Start a new project, plus a drop zone. All three lead into **First run** (§3).

### 6.6 Backlog (`Backlog.tsx`, `IssueDetail.tsx`)
- 1080×660. Tabs: Todo files · GitHub issues. Left list grouped (In progress / Not started / Done) with thin progress bars. Right: path + progress, title, summary, checklist.
- The **only** primary action is `Start as workspace`, which opens New workspace pre-filled. Editing links out: "edit in your editor ↗".

## 7. Copy rules
- Say what happened and what to do next, in one sentence each.
- Numbers first: "3 of 16 tests failing in lib/shipping.test.ts", not "Tests failed".
- Mono for anything machine-ish (paths, branches, counts, kbd); Space Grotesk for sentences.
- Lowercase step names (`agent`, `code`, `verify`, `ship`); uppercase mono for state words (`GREEN`, `RED`, `MERGED`, `RUNNING`, `NOT RUN`).

## 8. Suggested implementation order
1. Tokens and global cleanup: green-only-for-gate audit, remove the purple frame, fix root grid overflow.
2. Removals (§1).
3. Step bar + next-action logic (§5.1). Pure UI state derived from existing gate/agent status.
4. Right rail + terminal drawer (§5.2–5.3).
5. Verify step reorder + tamper banner + evidence ordering (§5.6).
6. Triage list + ⌘J (§4, §2).
7. Ship merge panel + receipt card (§5.7).
8. Unified settings + save bar (§6.1).
9. New workspace auto-branch + run-on-create (§6.4).
10. First run with baseline gate (§3). Needs backend work.
11. Palette, shortcuts, backlog polish (§6.2, 6.3, 6.6).

## 9. Flutter implementation (desktop frontend, Python backend unchanged)

Verify every package version and platform-support claim against its current release before committing. Desktop plugin support changes often.

### 9.1 Package choices
| Need | Package | Notes |
|---|---|---|
| Code editor (quick fixes only) | `re_editor` + `re_highlight` | Pure Flutter, no webview; handles large files; line numbers, find/replace, highlighting. |
| Diff + verified-lines view | **custom widget** | `ListView.builder` of `DiffRow(marker ●/○, lineNo, sign, spans)`; reuse `re_highlight` for tokens. This is haro's core surface, so own it. |
| Terminal | `xterm` + `flutter_pty` | Real PTY, native rendering. Tabs: Dev log (read-only `Terminal` fed from backend log stream) + one Shell (PTY). |
| Backend link | `http` / `dio` + `web_socket_channel` | REST for actions, WebSocket for agent tokens, gate test events, dev log. |
| State | `flutter_riverpod` (or `bloc`) | One provider per workspace holding the state machine below. |
| Routing | `go_router` | `/`, `/first-run`, `/w/:id/:step`. Overlays are dialogs, not routes. |
| Markdown (agent prose, backlog) | `flutter_markdown` or `markdown_widget` | Theme code spans with Space Mono. |
| Shortcuts | built-in `Shortcuts` / `Actions` / `CallbackShortcuts` | ⌘/Ctrl mapping via `LogicalKeyboardKey.meta` on macOS, `control` elsewhere (Super on Linux if you prefer). |
| Window chrome | `window_manager` | Custom 48px top bar as a drag area; min window size ~960×640. |
| Desktop notifications | `local_notifier` | Gate result / agent done when unfocused. |
| Sounds | `audioplayers` | chime / beep / blip / glass. |
| Launch external apps | `url_launcher` + `dart:io Process` | For "Open in…" and "Open ↗" (dev server in the real browser). |
| File watching (optional) | backend-driven | Python already watches worktrees; push `files_changed` over WebSocket instead of watching in Dart. |

Avoid embedding Monaco in a webview. Desktop webview support is uneven (Linux is typically the weakest), and it adds a JS bundle, a message bridge and focus/keyboard bugs. Revisit only if in-app LSP features become a requirement.

### 9.2 "Open in…" (external editors)
The built-in editor is for small fixes. Everything else hands off to the user's own tools.

- Button in the code step file header: **`Open in Zed ▾`** (labelled with the last-used choice). The same action appears in the ⌘K palette, and a file-row right-click offers "Open in…".
- Detected targets (probe `PATH` / known install locations at startup, cache the result):

| Target | Command |
|---|---|
| VS Code | `code --goto <file>:<line>` (workspace: `code <worktree>`) |
| VS Code Insiders | `code-insiders --goto …` |
| Cursor | `cursor --goto <file>:<line>` |
| Zed | `zed <file>:<line>` (workspace: `zed <worktree>`) |
| JetBrains (IDEA, PyCharm, WebStorm…) | `idea --line <line> <file>` / `pycharm …` / `webstorm …` |
| Sublime Text | `subl <file>:<line>` |
| Neovim / Vim | open in haro's Shell tab: `nvim +<line> <file>` (replaces the old Nvim mode) |
| Helix | Shell tab: `hx <file>:<line>` |
| `$VISUAL` / `$EDITOR` | fallback, run in the Shell tab if it's a terminal editor |
| File manager | `xdg-open` / `open` / `explorer` on the worktree folder |

- Also offer **"Open worktree in…"** from the workspace header ⋯ menu, which opens the whole worktree folder rather than a single file.
- Settings → Display → **Preferred editor** (select, device scope) lists only the detected targets and "Ask every time".
- Line-aware everywhere: "Open diff" and "Lines no test ran" items open the external editor **at that line**.
- Run these in the Python backend (`POST /workspaces/:id/open {target, path, line}`) so the process runs in the worktree environment (login shell, nvm, etc.); Flutter only calls the endpoint.

### 9.3 Workspace state machine (drives step bar, next action, rail)
```
idle ──run agent──▶ agent_running ──done──▶ gate_running ──▶ red | green
red ──send failures / edit──▶ agent_running
green ──merge──▶ merged        green ──new commit──▶ gate_running
plan_ready (plan-first runs) ──approve──▶ agent_running
```
- The backend emits `workspace_state` events; Flutter derives `steps[4]`, `nextAction`, `triageGroup` and `lookAt[]` from them as pure functions. This gives one source of truth for dashboard rows, sidebar glyphs, the step bar and the rail.
- Gate stream event shape (example): `{type:"test", id, file, name, status:"pass|fail|skip", ms}` then `{type:"verdict", status, passed, failed, duration_ms, coverage, mutation}`.

### 9.4 Widget map
| Screen / element | Widget | Built from |
|---|---|---|
| App shell | `HaroShell` (`Column` → `TopBar` 48 + `Row[Sidebar 240, Expanded(child)]`) | `window_manager` drag area |
| Status glyph | `StatusSquare(size, color, filled)` | `Container` with 1px border |
| Triage | `TriagePage` → `CustomScrollView` with `SliverList` per group; `TriageRow` uses `LayoutBuilder` to stack the detail under the name below ~720px | |
| Step bar | `StepBar` (`Wrap`/`LayoutBuilder` → 4 `StepCell` + `NextActionButton`) | state machine |
| Right rail | `GateRail` (`ListView` of `RailSection`) | gate + app + run providers |
| Agent step | `AgentStream` (`ListView.builder` of `UserTurn`, `ToolLine`, `AgentProse`, `TurnFooter`) + `Composer` | WebSocket token stream |
| Code step | `CodeStep` (`Row[ChangedFilesList 260, Expanded(DiffView / ReEditor)]`) | `re_editor`, custom `DiffView` |
| Verify step | `VerifyPage` (`VerdictHeader`, `MetricsRow` via `Wrap`, `TamperBanner`, `LookAtList`, `EvidenceAccordion`) | gate provider |
| Test grid | `TestGrid` (`Wrap` of 9px squares, or `CustomPainter` for 1000+ tests) | gate stream |
| Ship step | `ShipPage` (`MergePanel`, `ReceiptCard`, `CommitLine`) | git provider |
| Terminal drawer | `TerminalDrawer` (`AnimatedSize` 0↔240, `TerminalView`) | `xterm`, `flutter_pty` |
| Overlays | `showGeneralDialog` + `FadeTransition` + `BackdropFilter(blur 3)` | Settings, Palette, Shortcuts, New workspace, Add project, First run, Backlog |
| Settings rows | `SettingRow(label, help, control)` + `SaveBar` shown when dirty | |

### 9.5 Theme in Flutter
- `HaroColors extends ThemeExtension` with `ink, ink86, ink66, ink42, line08, line12, line20, bg, panel, raised, gate (#41d183), fail (#e0685e), merged (#b3a0d6)`. Name the green **`gate`** so it's obvious it doesn't belong on buttons. A lint/test can grep for `gate` usage outside gate widgets.
- `TextTheme`: Space Grotesk (UI), a `HaroMono` style helper for Space Mono labels (uppercase + letterSpacing ≈ 0.14–0.2 × fontSize), Fraunces for the wordmark only. Bundle the fonts as assets.
- Shapes: `BorderRadius.circular(2)`, `elevation: 0`, `splashFactory: NoSplash.splashFactory`, and hover handled with `MouseRegion` + fill change.
- Motion: `AnimatedOpacity` / `FadeTransition` only, 180–300ms, `Curves.easeOut`. No slide or scale transitions (override `PageTransitionsTheme` with a fade).
- Film grain: tiled noise PNG in a top-level `IgnorePointer(Opacity(0.07, …))`.

## 10. Out of scope
Light mode, extra themes, embedded live preview (the app strip opens a real browser), mobile layouts (to be designed next).
