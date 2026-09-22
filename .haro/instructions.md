# haro — standing instructions

These apply to every agent run in this project (prepended via
`--append-system-prompt`). Keep them short and workflow-focused.

The backlog format, backlog close-out (tick the item when done + gate green), and
gate integrity are **platform-level** defaults every project inherits — see
`TODO_CONTRACT` / `BACKLOG_TICK` / `GATE_CONTRACT` in `backend/haro/config.py`.
Only haro-repo-specific rules live here.

## Keep the skills in sync with the code
This repo *is* haro, so its skills (`haro`, `haro-dev`) are how the platform teaches
agents about itself. When you change how haro works — a new agent adapter, gate
runner, REST endpoint, settings key, WS event/channel, or a moved/renamed file the
`haro-dev` map points at — update the matching skill under
`backend/haro/assets/skills/…` in the *same* change, so the skills never drift
from the code.
