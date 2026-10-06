#!/usr/bin/env bash
# Launch haro as a desktop-style app: starts the backend + frontend if they
# aren't already running, then opens a chromeless "app mode" window (its own
# window + taskbar entry, no tabs/address bar). Ctrl+C stops what this launched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# The backend we spawn can only see the PATH we hand it, and agents/gate need
# `claude` (~/.local/bin) + `node`/`npx` (nvm). A terminal opened before those
# were installed — or a login shell that skipped ~/.zshrc — has neither, which
# surfaces as "claude CLI not found on PATH". Guarantee both here so run.sh works
# from any terminal.
export PATH="$HOME/.local/bin:$PATH"
# Homebrew installs CLIs like `nvim` (the code step's editor) outside the default
# PATH; on Apple Silicon that's /opt/homebrew/bin. An app-launcher/Spotlight start
# (or a login shell that only sourced ~/.zprofile) hasn't run `brew shellenv`, so
# the backend can't find nvim and the editor pane reports "nvim not found on PATH".
# Source brew's env if it's present so nvim & friends resolve however run.sh started.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
  [ -x "$_brew" ] && eval "$("$_brew" shellenv)" && break
done
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  set +u; . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; set -u
fi

BACK=""; FRONT=""
cleanup() { [ -n "$BACK" ] && kill "$BACK" 2>/dev/null; [ -n "$FRONT" ] && kill "$FRONT" 2>/dev/null; }
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
( cd "$ROOT/backend" && PYTHONPATH=. .venv/bin/python -m uvicorn haro.main:app --port 8000 --log-level warning --timeout-graceful-shutdown 3 ) &
BACK=$!

# 2. Frontend on :5173
if ! up http://localhost:5173; then
  echo "▸ starting frontend on :5173"
  ( cd "$ROOT/frontend" && npm run dev -- --port 5173 >/dev/null 2>&1 ) &
  FRONT=$!
fi

# 3. Wait for the frontend to answer
echo -n "▸ waiting for UI"
for _ in $(seq 1 60); do up http://localhost:5173 && break; echo -n "."; sleep 0.5; done
echo

# 4. Open a chromeless app window in whichever Chromium-family browser exists.
#    Linux browsers are CLI binaries on PATH; macOS ships them as .app bundles
#    (no PATH binary), so look inside /Applications for the bundle's executable.
URL="http://localhost:5173"
BROWSER=""
if [ "$(uname)" = "Darwin" ]; then
  for app in "Google Chrome" "Chromium" "Brave Browser" "Microsoft Edge" "Vivaldi"; do
    bin="/Applications/$app.app/Contents/MacOS/$app"
    [ -x "$bin" ] && { BROWSER="$bin"; break; }
  done
else
  for b in chromium chromium-browser google-chrome-stable google-chrome brave brave-browser vivaldi-stable microsoft-edge; do
    command -v "$b" >/dev/null 2>&1 && { BROWSER="$(command -v "$b")"; break; }
  done
fi
if [ -z "$BROWSER" ]; then
  echo "No Chromium-family browser found. Open $URL manually,"
  echo "or install Chrome/Chromium for the app-window experience."
else
  echo "▸ opening haro (${BROWSER##*/} --app)"
  # --class/--name are X11-only (Linux); macOS Chrome ignores them harmlessly.
  "$BROWSER" --app="$URL" --class="haro" --name="haro" \
             --start-maximized --window-size=1920,1200 >/dev/null 2>&1 &
fi

# Keep servers alive while the app is open; Ctrl+C here tears them down.
[ -n "$BACK$FRONT" ] && wait
