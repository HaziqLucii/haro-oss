#!/usr/bin/env bash
# Dev launch: starts a fresh backend on :8000, then runs the Flutter desktop
# client (app/) against it. Ctrl+C stops both.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# The backend we spawn can only see the PATH we hand it, and agents/gate need
# `claude` (~/.local/bin) + `node`/`npx` (nvm). A terminal opened before those
# were installed — or a login shell that skipped ~/.zshrc — has neither, which
# surfaces as "claude CLI not found on PATH". Guarantee both here so run.sh works
# from any terminal.
export PATH="$HOME/.local/bin:$PATH"
# Homebrew installs CLIs the agents and the gate shell out to (gh, node, rg) outside the
# default PATH; on Apple Silicon that's /opt/homebrew/bin. A login shell that only sourced
# ~/.zprofile hasn't run `brew shellenv`, so the backend would not find them. Source brew's
# env if it's present so they resolve however run.sh started.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
  [ -x "$_brew" ] && eval "$("$_brew" shellenv)" && break
done
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  set +u; . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; set -u
fi

BACK=""
cleanup() { [ -n "$BACK" ] && kill "$BACK" 2>/dev/null; }
trap cleanup EXIT INT TERM

up() { curl -sf "$1" >/dev/null 2>&1; }

# 1. Backend on :8000 — enforce ONE fresh instance.
# Never reattach to an existing backend: a stale/zombie one (an old process that
# didn't die on a previous Ctrl+C) keeps its DB connection open and autosaves its
# own stale store every few seconds — multiple such writers CLOBBER each other's
# workspaces (snapshot persistence assumes a single writer). Kill any existing
# haro backend, wait for :8000 to free, then start current source.
pkill -f "uvicorn haro.main:app" 2>/dev/null || true
for _ in $(seq 1 25); do up http://localhost:8000/health || break; sleep 0.2; done
echo "▸ starting backend on :8000"
# --timeout-graceful-shutdown: on Ctrl+C, force-close lingering WebSockets after 3s
# so the backend actually exits (runs its shutdown flush + frees :8000) instead of
# hanging on the browser's open sockets and becoming one of those zombies.
( cd "$ROOT/backend" && HARO_API=http://127.0.0.1:8000 PYTHONPATH=. .venv/bin/python -m uvicorn haro.main:app --port 8000 --log-level warning --timeout-graceful-shutdown 3 ) &
BACK=$!

# 2. Flutter desktop client. It reuses the backend answering on :8000 (HARO_BACKEND
# unset falls back to http://127.0.0.1:8000), so nothing is spawned twice.
echo -n "▸ waiting for backend"
for _ in $(seq 1 60); do up http://localhost:8000/health && break; echo -n "."; sleep 0.5; done
echo
case "$(uname)" in Darwin) DEVICE=macos ;; *) DEVICE=linux ;; esac
echo "▸ starting haro (flutter run -d $DEVICE)"
( cd "$ROOT/app" && flutter run -d "$DEVICE" )
