---
name: haro-dev
description: >-
  Contributor's map of the haro codebase. ONLY relevant when the current
  worktree IS the haro repo itself (dogfooding: someone is building or fixing
  haro, not using it on an unrelated project). Use for "which file handles X",
  "where do I add a new agent adapter / gate runner / REST endpoint / WS event /
  settings key / Flutter screen / shortcut / XP rule", or any "where do I make
  this change" question about haro's Python backend or its Flutter client in
  app/, to skip an open-ended file-by-file sweep. First check this really is the
  haro repo (see below). If not, this skill does not apply; defer to ordinary
  exploration instead.
---

# haro-dev: contributor's codebase map

Before using anything below, confirm this worktree really is the haro repo:
does `backend/haro/main.py` exist, and does `CLAUDE.md` describe "haro"? If not,
you are in the user's own unrelated project: skip this skill and explore normally.

If confirmed, use this map instead of an open-ended file sweep. Start with the
"Where do I add X" table (it routes most change requests directly). For a
file-by-file description, open the matching reference map:

- **Backend** (Python + FastAPI: routes, adapters, gate, git, config, backlog,
  issues, terminal, persistence, assist, XP, baseline) in
  [reference/backend.md](reference/backend.md)
- **Flutter client** (`app/`, the UI: `lib/features`, `state`, `data`, `api`, `shell`,
  `shortcuts`, `overlays`) in [reference/flutter.md](reference/flutter.md)
- **Legacy React `frontend/` and Electron `desktop/`**: behaviour reference only, pending
  deletion. New UI work never goes there. See [reference/frontend.md](reference/frontend.md)

Each reference file opens with a Contents list, so read the whole file (or grep it)
rather than previewing: the detail you need is usually one bullet deep.

## "Where do I add X" quick lookup
Backend paths are under `backend/haro/`. Flutter paths are under `app/lib/`.

| Task | Files to touch |
|---|---|
| New agent adapter (e.g. Codex) | `adapters/`, `adapters/__init__.py`, `main.py` `start_agent` selection |
| New gate runner (e.g. jest) | `adapters/test_runner/` (+ `__init__.py`), `main.py` `_test_adapter` dispatch |
| New REST endpoint | `main.py` (route) + `models.py` (schema) + Flutter: a method in `api/haro_api.dart`, a model in `api/models/*.dart`, a test in `app/test/api/` |
| New WS event / channel | `hub.py` (publish) + `api/models/ws_events.dart` (parse by `channel`) + the consumer: `data/workspace_detail.dart` (workspace socket) or `data/workspace_store.dart` / `data/xp_store.dart` (global feed) |
| Live-refresh a panel on a file/backlog change | `watcher.py` (emit signal) + the Flutter consumer of the `fs` / `notify` event |
| New `.haro/settings.toml` key | `config.py` (load/write) + `models.py` (`ProjectSettings`, and the config model such as `GateConfig` if a tab edits it) + Flutter `api/models/gate.dart` (or the matching model) + a row in `features/settings/tabs/project_tabs.dart` |
| New Settings tab or app-wide preference | `features/settings/tabs/app_tabs.dart` (rows), `settings_tab_spec.dart`, a prefs provider beside `display_prefs_provider.dart`, persisted by `device_prefs.dart` |
| Change workspace lifecycle (setup/run/archive) | `lifecycle.py` + `main.py` routes |
| Change when an agent run is allowed to START (wait for setup, wait for a slot) | `runner.py` (`_await_setup` / `_spawn_slot`). The backend owns both waits; do NOT add a refusal to `main.start_agent` or a queue in the client |
| Refuse or allow an action per workspace mode (agent vs manual) | `main._refuse_if_manual` (agent starts) and `main._assist_guard` (assistant runs); the client mirrors it in `state/workspace_flow.dart` (`visibleSteps`, `homeStep`) |
| Spawn / tear down any long-lived subprocess | spawn with `start_new_session=True`, tear down via `procs.terminate_tree`. Never a hand-rolled kill |
| Change merge/PR behavior | `integrate.py` (a new ship *refusal* goes in `ship_preflight`: one function serves the merge/PR routes AND the autonomy-ladder rungs); client side `features/workspace/steps/ship/` |
| Change what an armed trust rung DOES | `rungs.py` (`maybe_fire`), never a second copy of the preflights |
| Change a trust/rung *condition* or the merge queue's admission bar | `trust.py` (pure: `evaluate`, `policy_armed`, `admission_reason`), never in the endpoint |
| Change merge-queue ordering vs admission | ordering in `merge_queue.py` (pure engine); admission in `main.run_merge_queue` (which defers the ladder tier to `trust.py`) |
| Change which workspaces a **bulk archive** may tear down, or their order | `archive_queue.py` `plan`/`risks_of` (pure), never in `main.start_archive_queue` |
| Change AI review ("Review with AI") | `review.py` + `POST /workspaces/{id}/review` in `main.py`; client `features/workspace/steps/ship/ai_review_panel.dart`, `ai_review_state.dart`. It is never part of the gate |
| Change the manual assistant (plan, search, docs, read-only guarantees) | `assist.py` (tool whitelist, git guard, code stripping, plan parsing), `research.py` (repo/git/man/web, no AI), the `/assist/*` and `/plans` routes in `main.py`; client `features/workspace/rail/manual/` + `state/manual_rail.dart` |
| Change an XP amount or add an XP rule | `xp.py` (`RULES`, the single source served by `GET /xp/rules`) and `xp_hooks.py` (the facts and the call sites); the client renders `/xp/rules` so it needs no change for a number |
| Show XP somewhere new | `data/xp_store.dart`, `shell/shell_slots.dart` (sidebar footer), `features/triage/xp_nudge.dart`, `features/settings/xp_prefs_provider.dart` |
| Change the first-run baseline gate | `baseline.py` + `POST/GET /projects/{id}/baseline`; client `features/first_run/` |
| Change test-first tasks | `acceptance.py` + the test-first routes and `start_agent` branches in `main.py`; client `state/test_first.dart`, `features/workspace/steps/agent/acceptance_panel.dart` |
| Change protected tests | `protect_tests.py` + `adapters/claude_code.py` (`--disallowedTools`); the tamper alarm (`tamper.py`) stays the real check |
| Change what the git panel/Changes panel can do (stage, unstage, commit) | `git_panel.py` (`stage`, `unstage`, `commit(staged_only=)`) + `main.py` `git/*` routes; client `features/workspace/steps/code/workbench/changes_panel.dart`, `workbench_ops.dart` |
| Change a gate signal shown on the verify step | backend `gate.py` / `unchecked.py` / `tamper.py`; client derivation in `state/look_at.dart`, `state/review_items.dart`, `state/verdict.dart`, then render in `features/workspace/steps/verify/` |
| New step, or change step order or the primary next action | `state/workspace_flow.dart` (`StepKey`, `visibleSteps`, `NextAction`), `features/workspace/step_bar/`, `features/workspace/workspace_page.dart`, the step folder under `features/workspace/steps/` |
| New right-rail row | `features/workspace/rail/workspace_rail.dart` (agent and manual share it; the manual assistant is `rail/manual/`) |
| New keyboard shortcut | `shortcuts/key_bindings.dart` (`ShortcutAction` + `resolveShortcut`), `shortcuts/shortcuts_host.dart`, `shortcuts/app_commands.dart`, and the list in `overlays/shortcuts_overlay.dart` |
| New command-palette entry | register it via `appCommandsProvider` (`shortcuts/app_commands.dart`); items are built in `overlays/palette_model.dart` |
| New colour, size or duration | `theme/tokens.dart` only (widgets never hard-code a hex; green is the gate's colour only) |
| Change desktop launch (backend spawn, port policy, single instance, PATH) | Flutter: `app/lib/backend/`. Frozen backend: `backend/desktop_app.py`, `backend/haro-backend.spec`, `scripts/build-linux.sh` (`make linux`) |

## Boundaries
- This is a navigation aid, not a spec: always read the target file before editing;
  the map tells you where, not the current exact shape of the code.
- Removed on 2026-09-30 and not to be rebuilt: race x N / winner fan-out
  (`race.py`, `fanout.py`), the composer `fast` toggle, the Nvim editor PTY, the Double
  Gate scanners and plan compliance, and the refuter inside the gate. The gate is
  deterministic: a model never decides green or red.
- For questions about how to use haro (not edit it), use the `haro` skill.
