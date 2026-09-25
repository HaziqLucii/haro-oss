---
name: haro-dev
description: >-
  Contributor's map of the haro codebase — ONLY relevant when the
  current worktree IS the haro repo itself (dogfooding: someone is
  building/fixing haro, not using it on an unrelated project). Use for "which
  file handles X", "where do I add a new agent adapter / gate runner / REST
  endpoint / WS event / settings key", or any "where do I make this change"
  question about haro's own backend or frontend, to skip an open-ended
  file-by-file sweep. First check this really is the haro repo (see below) —
  if not, this skill does not apply; defer to ordinary exploration instead.
---

# haro-dev — contributor's codebase map

Before using anything below, confirm this worktree really is the haro repo:
does `backend/haro/main.py` exist, and does `CLAUDE.md` describe
"haro"? If not, you're in the *user's own* unrelated project — this skill
does not apply, skip it entirely and explore normally.

If confirmed, use this map instead of an open-ended file sweep. Start with the
"Where do I add X" table below (it routes most change requests directly). For a
file-by-file description of a module, open the matching reference map:

- **Backend** (Python + FastAPI: routes, adapters, gate, git, config, backlog,
  issues, terminal, persistence) → see [reference/backend.md](reference/backend.md)
- **Frontend** (React + TS: App state/WS routing, the ①②③④ step components,
  backlog, terminal, composer, styles) → see [reference/frontend.md](reference/frontend.md)

Each reference file opens with a Contents list, so read the whole file (or grep it)
rather than previewing — the detail you need is usually one bullet deep.

## "Where do I add X" quick lookup
| Task | Files to touch |
|---|---|
| New agent adapter (e.g. Codex) | `adapters/`, `adapters/__init__.py`, `main.py` `start_agent` selection |
| New gate runner (e.g. jest) | `adapters/test_runner/` (+ `__init__.py`), `main.py` `_test_adapter` dispatch |
| New REST endpoint | `main.py` (route) + `models.py` (schema) + `api.ts`/`types.ts` (frontend) |
| New WS event / channel | `hub.py` (publish) + `types.ts` + the consuming component |
| Live-refresh a panel on a file/backlog change | `watcher.py` (emit signal) + `App.tsx` (route to a nonce) + the panel (refetch on the nonce) |
| New `.haro/settings.toml` key | `config.py` (load/write) + `models.py` (`ProjectSettings`) |
| Change workspace lifecycle (setup/run/archive) | `lifecycle.py` + `main.py` routes |
| Change when an agent run is allowed to START (wait for setup, wait for a slot) | `runner.py` (`_await_setup` / `_spawn_slot`) — the backend owns both waits; do NOT add a refusal to `main.start_agent` or a queue in `App.tsx` |
| Spawn / tear down any long-lived subprocess | spawn with `start_new_session=True`, tear down via `procs.terminate_tree` — never a hand-rolled kill |
| Change merge/PR behavior | `integrate.py` (a new ship *refusal* goes in `ship_preflight` — one function serves the merge/PR routes AND the autonomy-ladder rungs) |
| Change what an armed trust rung DOES | `rungs.py` (`maybe_fire`), never a second copy of the preflights |
| Change a trust/rung *condition* or the merge queue's admission bar | `trust.py` (pure — `evaluate`, `policy_armed`, `admission_reason`), never in the endpoint |
| Change merge-queue ordering vs admission | ordering ⇒ `merge_queue.py` (pure engine); admission ⇒ `main.run_merge_queue` (which defers the ladder tier to `trust.py`) |
| Change which workspaces a **bulk archive** may tear down, or their order | `archive_queue.py` `plan`/`risks_of` (pure) — never in `main.start_archive_queue`, and never re-derived client-side |
| Change how a bulk archive DRAINS (serial, stop, failure isolation) | `archive_queue.run_queue` + `main._drain_archive_queue`; the teardown itself stays `main._teardown_workspace` |
| Change how a race picks its winner (policy, tie-break, disqualifier) | `race.py` (pure `judge`/`preflight`), never in `fanout.py` or the endpoint |
| Change what a race DOES (seed lanes, budget watchdog, loser ceremony) | `fanout.py` (`start_race`/`_supervise`/`soft_archive_lane`) |
| Change AI review (verify's quality lane) | `review.py` (reviewer + parsing) + `GatePanel.tsx` `ReviewLane` + `App.tsx` (`runReview`/`fixFinding`) |
| New main-column stepper step or side-column panel | `App.tsx` + a new `components/*.tsx` |
| Edit / add a CSS rule | the matching partial in `frontend/src/styles/` (barrel: `styles.css`) |
| Change the desktop shell (port policy, PATH resolution, backend spawn, quit/update relaunch) | `desktop/main.js` (dev + packaged both go through `backendCommand`); the frozen backend's own entry point is `backend/desktop_app.py`; packaging is `backend/haro-backend.spec` (PyInstaller) + `desktop/package.json`'s `build` block (electron-builder) + `desktop/rebuild.sh` (the build/install/self-update script) |
| Add or split a lazy-loaded frontend chunk | `App.tsx`'s `lazy(() => import(...).then(m => ({ default: m.X })))` block — check first whether every render site is behind a `<Suspense>`, and whether another *statically*-imported component also renders it eagerly (that defeats the split silently; Vite/Rollup's `[INEFFECTIVE_DYNAMIC_IMPORT]` build warning is the tell) |

## Boundaries
- This is a navigation aid, not a spec — always read the target file before
  editing; the map tells you *where*, not the current exact shape of the code.
- For questions about how to *use* haro (not edit it), that's the `haro`
  skill, not this one.
