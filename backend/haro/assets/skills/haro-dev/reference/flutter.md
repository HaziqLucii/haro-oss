# haro Flutter client map (`app/`, the UI)

The Flutter desktop client in `app/` is the UI. It replaced the React `frontend/` and the
old `desktop/` shell (both deleted, see `frontend.md`). It is a client of the unchanged Python
backend: it never imports backend code. A navigation aid, not a spec: read the target file before
editing. Run every `flutter` command from `app/`. Conventions live in `app/CLAUDE.md`.

## Contents
- Ground rules
- `lib/` top level
- `api/`: REST client, WS client, models
- `data/`: live per-project and per-workspace state
- `state/`: pure derivation (the state machine)
- `shell/`, `shortcuts/`, `overlays/`, `widgets/`, `theme/`, `backend/`
- `features/`: one folder per surface
- Tests

## Ground rules
- `lib/state/` is pure Dart with no widget imports (`test/state/purity_test.dart` enforces it, and
  also bans em-dashes in source and copy). Derive UI state there, render it in `features/`.
- Every colour, size and duration comes from `lib/theme/tokens.dart` (`HaroTokens`). Widgets never
  hard-code a hex. Green is the gate's colour only; red is failures and tamper; lilac is merged.
- The workspace state machine is derived client-side from workspace status, the agent transcript and
  gate events (the backend sends no `workspace_state` event). Entry point `deriveWorkspaceFlow` in
  `state/workspace_flow.dart`.
- Dead ends: do not build race x N, the composer fast toggle, dictation, an Nvim editor mode, extra
  terminal shells, or anything that lets a model decide green/red. See `app/CLAUDE.md`.

## `lib/` top level
- `main.dart` app entry (wraps `BootGate` above the `ProviderScope`).
- `router.dart` go_router with three locations: `/` (triage), `/first-run`, `/w/:id/:step` (a
  workspace on a step: `agent`, `code`, `verify`, `ship`). Fade transitions only.

## `api/`
- `haro_api.dart` the one REST client (`HaroApi`, ~1000 lines). One method per endpoint, grouped by
  resource (xp, usage/update, projects, project config, backlog/issues, workspaces, assist/plans,
  agent, files, gate/verify, run/setup, git/ship, merge queue, archive queue). Some methods exist
  with no screen behind them yet (merge queue, archive queue, firewall, rewind, sessions, trust
  panel): grep the method name in `features/` before assuming a UI exists.
- `haro_ws.dart` sockets with reconnect: `HaroGlobalSocket` (`/ws`), `HaroWorkspaceSocket`
  (`/ws/workspaces/{id}`, multiplexed by `channel`), `HaroTerminalSocket`
  (`/ws/workspaces/{id}/terminal/{shell_id}`, PTY bytes).
- `models/` Dart twins of `backend/haro/models.py`, re-exported by `models.dart`: `workspace.dart`,
  `project.dart`, `gate.dart` (TestRun, GateSummary, tamper, unchecked rows, GateConfig, receipt),
  `git.dart`, `backlog.dart`, `review.dart`, `test_first.dart`, `assist.dart` (jobs, plans, research
  rows, pinned docs), `baseline.dart`, `xp.dart`, `editors.dart`, `system.dart` (usage, update),
  `json_util.dart` (`Json` helpers). `ws_events.dart` parses every socket envelope by `channel`
  (`agent`, `test`, `watch`, `status`, `run`, `assist`, `fs`, `notify`, `baseline`, `xp`; `notify`
  kinds `agent_done`, `cost_warning`, `gate_green`/`gate_red`, `rung`, `backlog_changed`,
  `archive_queue`, `update_*`).

## `data/`
- `workspace_store.dart` projects and workspaces from REST, kept live by the global feed; a
  reconnect or an unknown workspace triggers a full reload.
- `workspace_detail.dart` one live view per open workspace: owns that workspace's only workspace
  socket, transcript, gate run and cells, watch state, dev log, run state, assist events.
  `workspace_detail_models.dart` holds its value types; `workspace_detail_lazy.dart` the providers
  verify and ship need (verified hunks, receipt, history, impact, blame, trust, repo status and log, PR status) created on first
  watch and refetched off a revision counter.
- `workspace_actions.dart` per-workspace mutations (start and stop agent, approve plan, test-first
  approve or leave, send failures or look-at rows to the agent, run gate, commit and commit staged, open PR, merge, continue, rename, set mode, archive, post
  receipt, Review with AI, dev server start and stop, read and save file). Failures surface as `HaroApiException`.
- `xp_store.dart` XP status and rules, award toasts; started by `xpWiringProvider`.

## `state/` (pure derivation)
- `workspace_flow.dart` `StepKey`, `visibleSteps(mode)` (manual has no agent step), `NextAction`
  and its kinds, `withUnsavedEdits`, `deriveWorkspaceFlow`. Change step order or the primary action
  here. `workflow.dart` `withWorkflow(action, active:, mode:)` turns the flow's forward and fix
  actions into Proceed (the workspace page applies it after `withUnsavedEdits`), `stepAfter` and
  `stepBefore` give Proceed/Back their targets. Step 3 is shown as "review" (`stepLabel`); its key
  and route stay `verify`.
- `display_state.dart` the seven visible states and `TriageGroup`; sidebar, triage, step bar and
  rail all read it. `gate_facts.dart` gate facts from a TestRun, a GateSummary or nothing.
  `live_gate.dart` cell tally and the watch (Live Gate) state, kept apart from the authoritative
  grid. `agent_signals.dart` plan-ready and waiting-on-input from the transcript.
- `verdict.dart` verify-step copy (never says verified, proven or correct). `look_at.dart` and
  `review_items.dart` the "Needs your review" rows, their kind labels and the send-to-agent text.
  `test_first.dart` acceptance-test derivations. `manual_rail.dart` manual rail derivation and the
  "AI edits" footer wording. `diff_stats.dart`, `format.dart` small helpers.

## `shell/`, `shortcuts/`, `overlays/`, `widgets/`, `theme/`, `backend/`
- `shell/` window frame: `haro_shell.dart` (top bar 48, sidebar 220 or 52px strip, status bar 24),
  `shell_host.dart` (binds it to providers and the router), `sidebar.dart`, `sidebar_strip.dart`,
  `top_bar.dart`, `status_bar.dart`, `focus_bar.dart` (focus mode), `gate_chip.dart`,
  `shell_layout.dart` (collapse and focus flags), `shell_slots.dart` (XP footer), `shell_models.dart`,
  `shell_providers.dart`.
- `shortcuts/` `key_bindings.dart` (`ShortcutAction` enum and `resolveShortcut`, pure),
  `shortcuts_host.dart` (binds keys, registers built-in commands), `app_commands.dart` (every action
  the keys, palette and top bar can trigger; screens register real callbacks), `platform_keys.dart`
  (Cmd on macOS, Ctrl on Linux), `need_you.dart` (Cmd/Ctrl+J cycling).
- `overlays/` `overlay.dart` (modal shell), `command_palette.dart` + `palette_model.dart` +
  `fuzzy.dart`, `shortcuts_overlay.dart` (keep in step with `key_bindings.dart`), `toast.dart`,
  `xp_rules_popover.dart` ("How XP works", rendered from `GET /xp/rules`).
- `widgets/` shared primitives (`haro_button`, `haro_text_field`, `haro_menu`, `haro_segmented`,
  `panel_switcher`, `kbd`, `status_square`, `haro_mark`, `shell_icons`: `ShellIcon` stroke icons
  incl. play, stop, openExternal, log, and `ShellIconButton` (tooltip, `on`, disabled when `onTap` is null)).
- `theme/` `tokens.dart` (all colours, sizes, durations, syntax palette), `haro_theme.dart`,
  `coding_font.dart`, `display_scope.dart`, `grain.dart`.
- `backend/` desktop launch: `boot_gate.dart`, `backend_plan.dart` (which backend: `HARO_BACKEND`,
  a frozen one next to the exe, else `127.0.0.1:8000`), `backend_launcher.dart` (spawn, `/health`
  wait, kill group), `backend_health.dart`, `app_lock.dart` (`~/.haro/app.lock`), `login_path.dart`,
  `backend_config.dart`. `capture/capture_mode.dart` is the screenshot mode.
- `util/home_dir.dart` `userHomeDir()` (`HOME` is a container path in the macOS sandbox).

## `features/`
- `triage/` home screen: `triage_model.dart` groups (needs you, running, ready to ship, idle,
  merged), `triage_page.dart`, `triage_providers.dart` (the streak nudge was removed).
- `first_run/` opens after Add project: test runner, dev server, secrets rows and the Baseline and
  Coverage rows fed by `POST /projects/{id}/baseline` (`first_run_model/page/providers.dart`).
- `new_workspace/` Cmd/Ctrl+N: `new_workspace_overlay.dart` (branch, base, Who writes it, start
  agent), `branch_naming.dart` (fix/ vs feat/ prefix), `prefill.dart` (from a backlog item or
  issue), `creation_commands.dart` (registers New workspace, Add project).
- `rename_workspace/` and `archive_workspace/` overlays (archive confirm with `archive_workspace_model.dart`).
- `add_project/` clone or pick a folder (`/fs` browse, `clone_runner.dart`), `remove_project/`
  confirm overlay, `backlog/` the Backlog overlay (todo files + GitHub issues), `open_in/` Open in
  an external editor (`GET /editors`, `POST /workspaces/{id}/open`).
- `settings/` unified Settings overlay: `settings_overlay.dart`, `settings_tab_spec.dart` (row
  spec), `settings_controller.dart` (drafts and saves), `settings_scope.dart` (device, team,
  personal), `settings_layers.dart` (which layer declares a table, gates the Team save),
  `settings_logic.dart`, `settings_register.dart`, `device_prefs.dart` (one JSON file for device
  prefs, shared lock, atomic write), `display_prefs_provider.dart`, `editor_prefs_provider.dart`,
  `xp_prefs_provider.dart`, `controls/` (toggle, select, segmented, meter, previews),
  `tabs/app_tabs.dart` (Display, Editor, XP, Notifications, Usage, System), `tabs/project_tabs.dart`
  (Git, Setup [read-only], Gate, Agent, Roles, Environment, Instructions).
- `workspace/` the workspace page (`workspace_page.dart`, `workspace_ui.dart`, `mode_switch.dart`):
  - `header/workspace_header.dart` project, branch, behind count, mode switch.
  - `step_bar/` the four (or three) step cells and the one primary action (`next_action.dart`). Only
    the step you are on is clickable, the others are dimmed; the bar also has Proceed (the primary
    action) and a `Back to <step>` button. `workflow_nav.dart` `moveToStep` is how actions open a step.
  - `steps/agent/` stream and composer: `agent_step.dart`, `agent_transcript.dart` (pure stream
    derivation), `stream_rows.dart`, `composer_slot.dart`, `composer_state.dart` (draft: plan
    first, test first, model, effort, attachments), `composer_logic.dart` (paste-to-file, `/` and
    `@` autocomplete), `acceptance_panel.dart` (test-first approval).
  - `steps/code/` the code IDE: `code_step.dart`; `workbench/` (activity bar, explorer, search,
    Changes with stage/unstage/commit-index, dialogs, ops); `editor/` (tab strip, gutter marks,
    breadcrumbs, symbols, minimap, editor area with split, `editor_sticky.dart` +
    `editor_sticky_provider.dart` = per-workspace tabs/cursors/side panel persisted under
    `code_sticky` in `~/.haro/flutter-client.json`); `diff_view.dart` (click a gutter cell or
    double-click a row to `onEdit(line)`, hover label) and `diff_model.dart` (`lineFor`);
    `proof.dart` (per-line proof dots, the Verified Hunks half); `proof_marks.dart` (needs-your-eyes
    circles for the gutter, one derivation shared with the Problems tab); `code_buffers.dart` + `edit_buffer.dart` (unsaved buffers; `etag`, `missingOnDisk`,
    409-driven conflict flags, `recheckMissing`); `fs_sync.dart` (`codeFsSyncProvider`: `fs`
    event paths -> tree refetch + open-buffer refresh; `planFsEffects` is the pure part);
    `quick_open.dart` + `go_to_line.dart` (`:n` and `path:n`); `run_on_save.dart`; `syntax.dart`
    (languages, `commentFormatterFor`) and `edit_pane.dart` (re_editor: replace row, wrap, image
    preview, bracket auto-close, `goToLine` / `runRelatedTests` palette registrations).
  - `terminal/related_tests.dart` the Gate tab's "Run the tests touching this file" row state
    (`POST /workspaces/{id}/watch/related`, result line only for the file that started it).
  - `steps/verify/` zones: `verdict_block.dart`, `tamper_banner.dart`, `look_at_section.dart`,
    `verify_model.dart` (pure). The on-demand Evidence zone (mutation, grid, impact rows) was removed
    2026-10-07; `git show 2857101^:app/lib/features/workspace/steps/verify/evidence_section.dart` reads it.
  - `steps/ship/` `ship_step.dart`, `merge_panel.dart` (two-step merge, PR, resolve, continue),
    `receipt_card.dart`, `commit_section.dart`, `ship_model.dart` (pure). `ai_review_panel.dart` +
    `ai_review_state.dart` now live in `steps/verify/`, beside `files_changed_section.dart` (Files
    changed list, Viewed marks in `files_viewed.dart`).
  - `rail/` right rail: `workspace_rail.dart` (GATE, needs your review, APP as three icon buttons:
    Run/Stop, Open in browser, Dev log; the APP row follows the run script with id `app` and shows
    its `url` when set via `workspaceDefaultRunProvider` in `data/workspace_detail_lazy.dart`; under
    it a dismissible `Agent suggests /path` line with an Open ↗ control when the agent ran
    `haro-app open`: `StatusEvent.suggestOpen` (`AppSuggestion`), kept as
    `WorkspaceDetail.appSuggestion`, auto-opened by the row only when `auto` and under 15 s old; RUN),
    `rail_frame.dart`
    (290px and 44px strip), `run_facts.dart`, `agents_panel.dart` (AGENTS: one line per delegated
    sub-agent, or background shell/monitor (`SubAgent.isShell`, no steps; finished ones are not
    listed), detail view with its own feed, STOP and CLEAR; data from `state/sub_agents.dart`
    + `data/sub_agents_provider.dart`); `rail/manual/` Plan, Search, Docs tabs
    (`manual_controller.dart` state and assist events, `plan_tab`, `search_tab`, `docs_tab`).
  - `terminal/` bottom panel: Terminal (xterm over the PTY socket), Gate and Problems tabs
    (`panel_model.dart`, pure), Dev log. Both terminals are `selectable_terminal.dart`
    (`SelectableTerminal`: a drag selection scrolls while the pointer is held outside the panel;
    raw pointer events on top of xterm's own handling, which cannot scroll a selection);
    `workspaceDevLogAvailableProvider` says when the Dev log exists, for the tab and the rail button.

## Where the pieces meet the backend
- Manual assistant: `rail/manual/*` and `state/manual_rail.dart` <-> `assist.py`, `research.py`,
  `POST /workspaces/{id}/assist/*`, the `assist` channel.
- XP: `data/xp_store.dart`, `shell/shell_slots.dart`, `overlays/xp_rules_popover.dart` <->
  `xp.py`, `xp_hooks.py`, `/xp*`, the `xp` channel. `xp_hooks` is called from `gate.py` (`on_gate_finished`), the
  merge routes and the merge queue in `main.py` (`record_merge`), the assist routes and file save;
  the client only reports `docs_read` and `diff_reviewed` (`POST /xp/activity`).
- Baseline: `features/first_run/*` <-> `baseline.py`, the `baseline` channel.

## Tests
`app/test/` mirrors `lib/` (`api`, `backend`, `data`, `features`, `overlays`, `shell`, `shortcuts`,
`state`, `theme`, `util`, `widgets`). Run `cd app && flutter test`; `flutter analyze` must be clean.
`test/live/` needs a running backend: `flutter test -t live --run-skipped`. Shared harnesses:
`test/data/detail_harness.dart`, `test/shell/fake_shell_data.dart`, `test/state/builders.dart`,
`test/features/creation_harness.dart`.
