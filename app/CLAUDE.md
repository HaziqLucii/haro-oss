# haro app (Flutter client)

The **Flutter desktop client for haro** (`app/` in the haro repo), built from scratch to the Claude
Design redesign. It replaced the React + Vite frontend (deleted 2026-10-07; read it with `git show 7158a68:frontend/src/<file>`)
and is replacing the old desktop shell (`../desktop`). The **Python backend** (`../backend`)
is unchanged: this is a new client for it. Moved here from a standalone `haro-flutter` folder on
2026-09-29 (Flutter client migration, same repo, history kept).

- The repo root `CLAUDE.md` explains the product, the gate, the config and the backend modules. Read it
  once before product decisions; this file only covers what's different for the Flutter client.
- Run every `flutter` command from `app/`.

North star (reset 2026-10-07, see the root `CLAUDE.md`): **you stay the author.** The client lets you
keep an agent inside the files you hand it (the Scope box) and shows who wrote what (the receipt).
The gate is the quiet safety net, no longer the product; multi-agent is table stakes.

## Status

Built (2026-09-29) and in daily use against the real backend: triage, the ⌘K palette and shortcuts, the
workspace frame (step bar, rail, Dev log + Shell terminal), the agent / code / review (verify) / ship steps (one at a time: only the current step is clickable, Proceed and Back move you),
unified Settings, New workspace, Add project, Remove project, Backlog, First run, Open in…, and
Review with AI, Test first, and the backend launcher. About 1,130 widget/unit tests. Runs on macOS and
Linux (first Linux build 2026-09-29 on CachyOS KDE Wayland; `make linux` builds the AppImage and tarball, `make install-linux` builds and installs it on this machine (swaps `~/Applications`, fixes the launcher entries, verifies); macOS: `scripts/build-macos.sh`).
On Wayland the taskbar icon comes from a `dev.haro.haro_app.desktop` entry (= `APPLICATION_ID`), not
the window icon. Read `notes/progress.md` first: it is the handoff doc
(current state, open decisions, what's next). It lives in `app/notes/`, which is not published.

## Working in this repo

- Run every `flutter` command from `app/`; the backend is `../backend` (see Backend below).
- This repo (`HaziqLucii/haro`) is the private upstream. `make publish` (repo root,
  `scripts/publish-oss.sh`) force-pushes one squashed snapshot of committed `HEAD` on `main` to the
  public `HaziqLucii/haro-oss`, excluding `notes/`, `backlog/` and `app/notes/`. Never push to
  haro-oss any other way.
- The landing page is a separate repo, `HaziqLucii/haro-site` (GitHub Pages). Its screenshots come
  from this app's capture mode: build with `--dart-define=HARO_CAPTURE=true` (debug only) to hide the
  macOS window buttons, then ⌃⌥⌘S (or drop a `.shoot` file into the capture dir) saves the app's own
  pixels. Inside the macOS sandbox captures land in
  `~/Library/Containers/dev.haro.haroApp/Data/tmp/haro-captures`.
- The macOS app has NO `app-sandbox` entitlement (removed 2026-10-05): a sandboxed parent makes the
  spawned backend sandboxed too, which blocks git, agents and `~/.haro`. Do not add it back;
  `scripts/build-macos.sh` refuses to build if it returns. `userHomeDir()` in `lib/util/home_dir.dart`
  predates this (`HOME` was the container). Old sandboxed builds kept their data in
  `~/Library/Containers/dev.haro.haroApp`.
- Desktop notifications: `lib/shell/notifier.dart`. On macOS the banner goes through a `dev.haro.haroApp/notify` method channel (`macos/Runner/MainFlutterWindow.swift`, UNUserNotificationCenter) so it carries haro's icon; `osascript` is only the fallback and shows as Script Editor. Tones play through `afplay` / `canberra-gtk-play`.
- macOS release: `INSTALL=1 scripts/build-macos.sh` builds `dist/haro.app` (Flutter client + frozen
  backend, ad-hoc signed) and copies it to `~/Applications`.

## Source of truth: `design/`

- **Current target (2026-09-29):** `design/haro-plan.md` then `design/prototype/haro-finalized-ui.dc.html`
  (Manual mode, XP, code-step IDE, shell strips, focus mode). They win over the older spec and
  prototype below. Manual-mode behaviour reference: `haro-manual-journey.dc.html` (loses on conflicts:
  no kanji in UI, no Hints tab). When unsure, follow the Finalized UI exactly.
- `design/haro-redesign-spec.md`: the earlier implementation spec, still the detail reference where the
  plan and Finalized UI are silent.
- `design/prototype/haro-redesign.dc.html`: the clickable prototype. Open it in a browser. The Tweaks
  panel `startScreen` switches first run / dashboard / workspace / settings, and the **Preview state**
  bar on the workspace steps through idle, running, red, green and merged. When the spec is vague,
  the prototype decides.
- The spec names React files (`GatePanel.tsx`, `Sidebar.tsx`…). Those are the **behaviour reference**
  in the old `frontend/src/` (`git show 7158a68:frontend/src/<file>`): read them to see what data a screen uses and how it reacts to events,
  then build the Flutter widget to the new design. Don't port their layout.

## Do NOT build (removed in the redesign, decided 2026-09-29)

Race ×N / winner-only fan-out · the composer `fast` toggle · dictation mic · Nvim editor option (Monaco-style
editor only) · extra terminal shells and the Claude terminal tab (keep **Dev log + one Shell**) · the
quality scan row · the `DEPS —` header label · the purple active-workspace frame.
The gate is fully deterministic (decided 2026-09-29): the code reviewer, Double Gate plan compliance and
Double Gate lint are cut from the verdict. AI code review is an on-demand "Review with AI" button at the
top right of the review step's Files changed list (`POST /workspaces/{id}/review`), advisory only. The secrets scan stays as an advisory
needs-your-eyes item. Never let a model's judgment decide green/red.
Editor stop line (2026-10-05, `backlog/code-editor.md`): past the TS/JS language server and format-on-save, do not build
extensions, vim mode, a debugger, rename-symbol or refactors, git blame, multi-cursor, AI inline completion, line comments
routed to the agent, or editable diff hunks. The editor is a floor; "Open in..." covers the rest.
The backend for race x N, the `fast` toggle and the Nvim editor PTY was deleted 2026-09-30 (dictation and the
Claude terminal tab never had backend code; the `/terminal/{shell_id}` PTY stays because this client uses it).

## Backend

Run it from `../backend` (the Flutter app never imports backend code):

```bash
cd ../backend   # from app/
PYTHONPATH=. .venv/bin/python -m uvicorn haro.main:app --port 8000 --log-level warning
```

- ⚠ It uses the **real** database at `~/.haro/haro.db`. Never run a second backend against it: quit any
  other haro app (or `./run.sh`) first. It runs **without** `--reload` on purpose (it supervises
  agent subprocesses); restart it to pick up backend changes.
- A native client has no CORS problem (CORS only applies to browsers), so no backend change is needed
  to talk to it.
- **Contract reference:** `git show 7158a68:frontend/src/api.ts` (every REST call + WS) and
  `git show 7158a68:frontend/src/types.ts` (every payload shape, mirrors `backend/haro/models.py`). Port these
  to typed Dart models + one API client. Endpoints live in `backend/haro/main.py` (~108 REST routes).
- **WebSockets:**
  - `/ws`: global feed (coarse status/gate/notify events for every workspace; drives the triage list
    and the "need you" pill).
  - `/ws/workspaces/{id}`: per-workspace, multiplexed. Every message is `{channel: …}`: `agent`
    (stream events: `token | tool_call | file_edit | done | error`), `test` (`kind: run_started | cell |
    snapshot`, the live gate grid), `status`, `watch` (advisory Live Gate, must never overwrite `test`
    state).
  - `/ws/workspaces/{id}/terminal/{shell_id}`: PTY bytes for the Shell tab.
  - There is no editor socket (the Nvim PTY was deleted 2026-09-30). The Monaco-style editor reads and
    saves files over REST.
- **Desktop launch:** `lib/backend/` (`BootGate` above the `ProviderScope`, `BackendLauncher`,
  `backend_plan.dart`, `login_path.dart`) starts and supervises the backend. Which backend: 1)
  `HARO_BACKEND` env (or the dart-define): connect, spawn nothing (dev); 2) a frozen backend at
  `<dir of the app exe>/backend/haro-backend/haro-backend` (PyInstaller onedir, added by
  `scripts/build-linux.sh`), or on macOS `<exe dir>/../Resources/backend/haro-backend/haro-backend`
  (added by `scripts/build-macos.sh`; not under `Contents/MacOS` because codesign rejects the
  `.dist-info` dirs there): spawn it with `--port`, login-shell PATH, `HARO_PARENT_PID`, its own
  process group, log `~/.haro/backend.log`, 45s `/health` budget behind a splash; 3) else
  `http://127.0.0.1:8000`. One app instance at a time (flock on `~/.haro/app.lock`; a second launch shows "already
  running" and spawns nothing). A haro backend answering on 41417 or 8000 whose `/health` `db` path matches
  is reused (never two on one `haro.db`); one without a `db` field (older) makes the launch fail rather
  than spawn beside it; non-haro listeners are ignored. Linux release: `make linux` writes the tarball and AppImage to `dist/`.

## Flutter stack: spec §9, with these corrections

Spec §9 picks the packages, the widget map and the theme. Follow it, verify each package's current
desktop (especially Linux) support on pub.dev before adding it, and apply these overrides where §9
doesn't match the real backend:

1. **Terminal: no `flutter_pty`.** §9.1 suggests a local PTY, but the backend already runs the Shell
   PTY in the worktree with haro's env (`HARO_PORT`, login-shell PATH, reaping on archive) over
   `/ws/workspaces/{id}/terminal/{shell_id}`. Feed the `xterm` widget from that socket. A local PTY
   would bypass all of that.
2. **Real event shapes win over §9.3's examples.** The backend emits **no** `workspace_state` events,
   and gate events are `{channel:"test", kind:"run_started"|"cell"|"snapshot"}`, not
   `{type:"test"}` / `{type:"verdict"}`. Derive the state machine (`steps[4]`, `nextAction`,
   `triageGroup`, `lookAt[]`) client-side, as pure functions, from the existing workspace status,
   agent and gate events (spec §8 step 3 says the same). Use `types.ts` as the source of truth.
3. **"Open in…" (§9.2)** runs the editor from the backend (`POST /workspaces/{id}/open`, `GET /editors`)
   so it keeps the worktree's shell env. Built.
4. **Markdown:** `flutter_markdown` has been discontinued upstream. Check its status and prefer a
   maintained alternative (§9.1 already lists `markdown_widget`).
5. **Editor:** `re_editor` (no Monaco, no webview), as §9.1 says. Nvim users get "Open in… Neovim"
   in the Shell tab, which replaces the dropped Nvim mode.

## Brand (spec §0, non-negotiable)

- Dark only, one theme. Ink `#d8d0c5` on `#0b0a09`; panels `#131210`, raised `#1b1915`. Hierarchy
  comes from ink opacity (`.86 / .66 / .42`) and hairlines (`rgba(216,208,197,.08 / .12 / .2)`).
- **Green `#41d183` is for the gate only** (verdict, test cells, diff adds, "line ran"). Never on
  buttons, focus rings or generic meters. Red `#e0685e` = failures, deletions, tamper alarm. Lilac
  `#b3a0d6` = merged.
- Exception (2026-10-05): a finished sub-agent's status square in the rail is green (failed: red), so done reads at a glance.
- Exception: code syntax may use the muted `SyntaxColors` palette (Display → Syntax colours, default on); it never uses green, red or lilac hues, which stay reserved for the gate, failures and merged.
- Primary button: bone fill + dark text. Secondary: 1px hairline. Tertiary: text only.
- Fonts (registered in `pubspec.yaml`): `SpaceGrotesk` for UI and headlines, `SpaceMono` for labels,
  data, paths, kbd (uppercase, wide tracking), `Fraunces` for the `haro.` wordmark only.
- 2px radius, **no shadows / Material elevation**, film grain overlay (~7%), fades only (180–300ms,
  nothing slides). Turn off Material ink ripples and splash effects; they break the brand.
- Status glyph: a squircle (`RoundedSuperellipseBorder`, `StatusSquare`). Filled = settled (red/green/merged), hollow ink = in progress, hollow dim = idle. Not on the step bar (2026-10-09): there a step's status is the colour of its name and of the 2px line along the top of its cell (ink = the step you are on, ink at .42 = done, hairline = not started, red / green / lilac = failed / green / merged).
- Put every colour, size and duration in one tokens file; widgets never hard-code a hex value.

## Build order

Phase 0 (Flutter-only, before the spec's list): theme tokens + fonts, API client + Dart models, WS
client with reconnect, app shell (top bar + sidebar grid), backend launcher for dev. Then follow the
spec's §8 order, skipping step 2 (removals: just don't build them).

Persist progress in a checkbox handoff doc (`notes/progress.md`) rather than in chat, and reload it
after a `/compact` or a new session.

## Conventions

- Dart: `flutter analyze` clean, `dart format`, widget tests for derived UI state (step bar
  next-action, triage grouping, verdict copy). Keep derivation logic in plain Dart files, separate from
  widgets, so it's testable (the React client does this with `verdict.ts`, `flow.ts`, `gate.ts`).
- Comments only when the *why* is non-obvious. No em-dashes in copy, docs or comments.
- Git: same repo as the backend (`github.com/HaziqLucii/haro`). Author is
  `HaziqLucii <haziqdluffy@gmail.com>`. Make sure `gh` is on HaziqLucii before a push.
