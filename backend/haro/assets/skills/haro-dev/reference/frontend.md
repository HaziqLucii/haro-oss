# Deleted: the React `frontend/` and the old `desktop/` shell

**`frontend/` was deleted 2026-10-07 and the `desktop/` shell after it; read the React code with `git show 7158a68:frontend/<path>`. The rest of this page describes them as they were.** The UI is the Flutter client in `app/` (map in [flutter.md](flutter.md)). Do not add backend features that only the old UI used.

Some backend features lost their consumer with the 2026-09-30 removals (race x N, the composer
fast toggle, the Neovim editor socket). The old React race button, scorecard and Monaco/nvim
toggle therefore talk to endpoints that no longer exist. That is expected.

## What is still useful
Read these to see what data a screen uses and how it reacts to events, then build the Flutter
widget. Do not port the layout.

| React source (`frontend/src/`) | Flutter equivalent (`app/lib/`) |
|---|---|
| `api.ts` (every REST call and WS) | `api/haro_api.dart`, `api/haro_ws.dart` |
| `types.ts` (payload shapes, mirrors `backend/haro/models.py`) | `api/models/*.dart` |
| `flow.ts`, `verdict.ts`, `gate.ts` (state machine, verify copy, gate display logic) | `state/workspace_flow.dart`, `state/verdict.dart`, `state/gate_facts.dart`, `state/look_at.dart`, `state/review_items.dart` |
| `verifiedHunks.ts` | `features/workspace/steps/code/proof.dart` |
| `composerAutocomplete.ts`, `attachments.ts` | `features/workspace/steps/agent/composer_logic.dart` |
| `fuzzy.ts` | `overlays/fuzzy.dart` |
| `roles.ts`, `turns.ts`, `sessions.ts`, `archiveQueue.ts` | client methods exist in `haro_api.dart`; no screen yet for turns, sessions or archive queue |

The React `App.tsx` routed the WS channels (`agent`, `test`, `watch`, `status`, `run`, `fs`,
`notify`); the Flutter equivalents are `api/models/ws_events.dart` and `data/workspace_detail.dart`.
Styling was CSS partials under `frontend/src/styles/`; the Flutter tokens are `theme/tokens.dart`.

## Legacy shell pieces
- `desktop/main.js`, `desktop/rebuild.sh`, `desktop/package.json`: the old launcher and its
  self-update build. Replaced by `app/lib/backend/` (launcher) and `scripts/build-linux.sh`
  (`make linux`). The frozen backend's entry point `backend/desktop_app.py` and
  `backend/haro-backend.spec` are still used by the Flutter release build.
- `./run.sh` (repo root) still boots the backend and the React dev server for the legacy app.

If a task says "the frontend", check which one it means: the answer is almost always `app/`.
