# haro: plan so far

Living summary of every decision made in the design sessions. Reference prototype: **Haro Finalized UI.dc.html** (fully clickable). Older, deeper detail lives in `haro-redesign-spec.md`.

Stack: **Flutter desktop frontend, Python backend (unchanged).** Linux first, open source: github.com/HaziqLucii/haro-oss

---

## 1. Positioning

- **One-line promise:** no agent's work merges until the tests are green.
- **The gate is the product.** Running many agents in parallel is expected, not the pitch.
- **Second pillar, Manual mode:** *"What if an AI code assistant could only help you plan and research?"* For developers who want to write the code themselves again, with the same gate and a reward loop.
- **Audience:** developers who hand off tasks to agents, and developers who want to code by hand. The UI must stay readable for less technical users: plain words, one next action, no jargon in primary labels.

## 2. Brand (unchanged, enforced)

- Dark only. Bone ink `#d8d0c5` on near-black `#0b0a09`. Hierarchy from ink opacity (86 / 66 / 42%) and 1px lines, not colour.
- Green `#41d183` is **only** the gate and added lines. Red `#e0685e` is **only** failures and deletions. Lilac `#b3a0d6` only for merged.
- Primary button: bone background, dark text. Only one primary per view.
- Type: Space Grotesk (UI), Space Mono (labels, data, code; uppercase + wide tracking for labels), Fraunces (wordmark only).
- 2px corners, no shadows, film grain, fades only (no slides, no bounces).
- **No Japanese characters in functional UI** (not everyone reads them). Icons and plain words instead. Kanji may stay as decoration on the landing page only.

## 3. App shell

```
┌ top bar: ☰ haro. · crumb · WHO WRITES THE CODE [AGENT|MANUAL] · ⌘K · N NEED YOU · ? · Settings
├ left sidebar (220px ⇄ 52px strip ⇄ hidden in focus)
│   Triage · Backlog · projects → workspaces (status square + short state)
│   New workspace (⌘N)
│   XP footer: level, rank, XP bar, streak, latest reward, "?" → How XP works
├ main column: workspace title · step bar · step content
└ right rail (290px ⇄ 44px strip ⇄ hidden in focus)
```

- Both sidebars are **minimizable** to a slim strip that keeps the essentials (status squares / gate square + eyes count + mode + terminal).
- **Focus mode (⌘⇧↵)** in the code step hides top bar, step bar and both sidebars; a slim bar keeps workspace name, live gate chip and "Exit focus ⎋".

## 4. The step flow

- **Agent mode:** `agent › code › verify › ship` (4 steps).
- **Manual mode:** `code › verify › ship` (3 steps). Terms are identical across modes ("code", never "write").
- Every step shows its own live status under its name.
- One **next-action button** on the right of the step bar, always:
  - agent: Run agent → Review code
  - code: Save & run gate (if unsaved) → Verify
  - verify: Ship (green) · Send failures to agent / Back to code (red) · Gate running (disabled)
  - ship: Merge into main (green only) · Go to verify (blocked) · Continue on a new branch (merged)
- Workspace states to design for: idle, agent running, plan ready, gate running, red, green, merged.

## 5. Screens

### Triage (dashboard)
- Rows, not cards. Groups: **Needs you → Running → Ready to ship → Idle → Merged.**
- Row: status · name + project + mode · one-line reason · 4-tick progress · one action button (primary only in "Needs you").
- Headline states the count: "3 workspaces need you."

### Agent step
- Empty state: "What should the agent do?" + suggested tasks (backlog, issues, coverage gaps).
- Stream: your message, then tool lines (Read / Edit / Bash with +/−), then short prose. Quiet, single column.
- Composer: model picker, plan first toggle, @ files, / commands, Run agent ⌘↵. Stop while running.
- Plan-first runs end in "plan ready"; approving builds it on the build model.

### Code step (built-in editor, feels like Zed/VS Code)
- Activity bar with **icons**: Files, Search, Changes, Gate.
- **File tree:** All files / Changes toggle, filter, arrow + folder/file icons, A/M letters, • on folders with changes, right-click menu (open, open to the side, rename, copy path, show diff, also open in Zed, delete), keyboard navigation, resizable.
- **Search:** results grouped by file, click jumps to line.
- **Changes:** staged list + commit box.
- **Editor:** tabs (italic = preview, ● = unsaved), breadcrumbs to symbol, line numbers, current-line highlight, indent guides, change bar, ● on lines the green suite ran, minimap, Edit/Diff, split right.
- Bottom panel (⌃`): Terminal · Gate · Problems.
- ⌘P quick open (changed files first). ⌘S saves and re-runs the gate.
- "Also open in… Zed ▾" is secondary, not the main path.

### Verify step (the centre of the product)
1. **Verdict first:** GREEN / RED / RUNNING / NOT RUN, one headline, one sentence, metrics row (tests, duration, coverage, mutation, flaky), live progress while running.
2. **Failing** (red only): blocks the merge.
3. **Needs your eyes:** advisory, never blocks. Tick to resolve, "Open in code" jumps to the line.
4. **Evidence on demand:** test grid, impact, coverage, flaky tests, mutation score.

### Ship step
- Editable PR title and commit message.
- Merge panel: green = Open PR + Merge; not green = Merge blocked + Go to verify; merged = Continue on a new branch.
- **Gate receipt** (copy as markdown / post to PR): suite, written by (agent / you / both), needs-your-eyes open vs resolved, mutation, tamper alarm, diff reviewed.

### Right rail
- Always: **Gate** block (click → verify).
- Agent mode: Needs your eyes · App (dev server Run/Stop, Open ↗ in real browser) · Last agent run (model, cost, context) · Ask the agent (sends to agent step).
- Manual mode: **Plan · Search · Docs** tabs. Footer: "AI: plan and research only · 0 lines of code".

### Overlays
- ⌘K command palette: workspaces + actions, arrow keys.
- ⌘N new workspace: task, auto branch name, **Who writes it: Agent / Me, by hand**.
- Settings (⌘,): one row = label + help + control, changes apply immediately, scope shown (device / personal / team).
- Keyboard shortcuts (?), Backlog (issues + todo files, "Start" fills New workspace), Add project, First run.

## 6. Manual mode

- Toggle per workspace in the top bar: **WHO WRITES THE CODE [AGENT | MANUAL]**, also in New workspace and ⌘K.
- The agent cannot edit files. AI does two things only:
  - **Plan:** the user types what they want to build; AI does the heavy thinking and returns a plain checklist plan. No questions back to the user, no extra ceremony. The developer implements.
  - **Research:** answers "where to look", with sources (official docs, offline docsets, the user's own repo via blame/history). Pointers only, never code to paste.
- **Docs tab:** plans saved from Plan, pinned web docs (open in the real browser), offline docsets (framework docs, man pages). Content comes from real sources, not AI-generated text.
- Hints tab was **dropped** (coding has no single right answer).
- Same gate, same verify and ship. Receipt records "written by you".

## 7. Gamification

- Lives in the **left sidebar footer**, visible in both modes. Collapsed sidebar shows a small level badge.
- Shows level, rank (Novice → Journeyman → Craftsman → Master), XP bar, 14-day streak, latest reward.
- **How XP works:**
  - Every workspace: merge on green **+10**, resolve a needs-your-eyes item **+5**.
  - Agent mode (review bonus): review the whole diff yourself **+15**, fix or add a test by hand **+10**.
  - Manual mode: **×2 on everything**, plus red → green written by you **+120**, kill a surviving mutant **+40**, start from a failing test **+30**.
  - Streak: any day you merge on green. Only merges count, so busywork earns nothing.
- Settings: show/hide XP, streak reminder.

## 8. Cuts and demotions (from the Claude Code review)

- **Cut:** refuter / LLM review inside the gate (costly, can't block, caused false reds). May return later as an on-demand "Review with AI" button on ship, outside the verdict.
- **Cut:** Double Gate plan-compliance check (LLM judging the diff).
- **Cut:** built-in lint scanning. Lint belongs in the project's own gate command.
- **Demote:** secrets scan becomes a "needs your eyes" item, not part of green/red.
- Earlier removals: extra frames around the workspace, "DEPS" label, Monaco/Nvim switch, composer "fast" and "race ×3", green on generic buttons.

## 9. Flutter implementation notes

- Editor: `re_editor` + `re_highlight` (no webview, no Monaco).
- Diff and verified-lines view: custom widget.
- Terminal: `xterm` + `flutter_pty`.
- Backend link: REST for actions, WebSocket for agent stream, gate test events, dev log.
- State: one provider per workspace holding the state machine; derive steps, next action, triage group and needs-your-eyes as pure functions.
- Shortcuts via `Shortcuts`/`Actions`; window chrome via `window_manager`; notifications `local_notifier`.
- "Open in…" handled by the Python backend so it runs in the worktree's environment: Zed, VS Code, Cursor, JetBrains, Sublime, Neovim/Helix (in haro's shell), `$EDITOR`, file manager.
- Theme: a `ThemeExtension` with the colours above; name the green `gate` so it isn't reused on buttons. Fades only (`FadeTransition`), no page slide transitions.
- Verify package versions and Linux support before committing.

## 10. Marketing assets

- **Landing page** (`Haro Landing.dc.html`) and **mobile landing** (separate file): desktop-app focused, Download for Linux (AppImage, .deb, build from source), links to the repo. Replace screenshot placeholders, install commands, license and the "works today / not yet" lists with real values.
- **Logo** (`Haro Logo.dc.html`): four options; recommended **1b Torii** (a gate with the green square in its opening).
- Candidate slogan for manual mode: *"What if an AI code assistant could only help you plan and research?"*

## 11. Out of scope

Light mode, extra themes, an embedded browser (haro opens the real browser), Windows builds for now.

## 12. Open items

- Pick the final logo and export app icons.
- Confirm the XP numbers and rank thresholds after real use.
- Real release file names, install commands and license text for the landing page.
- Decide whether "Review with AI" returns on ship.
