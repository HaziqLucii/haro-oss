#!/usr/bin/env bash
# Rebuild + reinstall the haro desktop app from the CURRENT source tree.
#
# The packaged app is a SNAPSHOT: a PyInstaller-frozen backend + a pre-built SPA
# bundled at build time. So editing source or `git pull` does NOT change the
# installed app — run this to roll those changes into it. (This is only for the
# packaged app; `run.sh` already runs live source.)
#
# After it finishes: quit any open haro window, then relaunch (Super+H / app
# menu). A running binary keeps its old files even after reinstall, so the
# update only takes effect on the next launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESTART=0
[ "${1:-}" = "--restart" ] && RESTART=1

# Coarse build progress for the in-app updater: write PCT=/LABEL= milestones to
# ~/.haro/.update-progress (same dir + format family as the build stamp) so the
# still-running old app can poll GET /update/progress and show a real percentage
# during the ~1-min rebuild. Milestones, not a continuous percent — vite/PyInstaller/
# electron-builder don't stream one, and the pcts are weighted by how long each step
# takes (the backend freeze dominates). Best-effort: never let it fail the build.
PROGRESS_FILE="$HOME/.haro/.update-progress"
mkdir -p "$HOME/.haro"
progress() { printf 'PCT=%s\nLABEL=%s\n' "$1" "$2" > "$PROGRESS_FILE" 2>/dev/null || true; }
progress 3 "Preparing"

# Stamp the build with the commit it was built from + this source checkout, so
# the installed app can later detect "source has moved past me" and offer a
# self-update. Written into the backend's bundled assets/ so it rides inside the
# frozen binary; the running app reads it (see backend/haro/update.py).
mkdir -p "$ROOT/backend/haro/assets"
BUILD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'SHA=%s\nSOURCE_ROOT=%s\n' "$BUILD_SHA" "$ROOT" > "$ROOT/backend/haro/assets/build_info.env"
echo "▸ stamped build $BUILD_SHA (source: $ROOT)"
progress 5 "Stamped build"

echo "▸ [1/4] building frontend (vite) …"
progress 10 "Building frontend"
( cd "$ROOT/frontend" && npm run build )

echo "▸ [2/4] freezing backend (PyInstaller) …"
progress 35 "Freezing backend"
( cd "$ROOT/backend" && .venv/bin/python -m PyInstaller --noconfirm haro-backend.spec )

# Steps 3 & 4 are OS-specific: Linux ships an AppImage into ~/.local/opt with a
# .desktop entry; macOS ships a .app bundle into /Applications (drag-install).
case "$(uname -s)" in
  Darwin)
    echo "▸ [3/4] packaging (electron-builder --mac) …"
    progress 70 "Packaging app"
    ( cd "$ROOT/desktop" && npx electron-builder --mac )

    APP="$(find "$ROOT/dist-desktop" -maxdepth 2 -name 'haro.app' -type d | head -1)"
    [ -n "$APP" ] || { echo "✗ haro.app not found under dist-desktop/"; exit 1; }
    # electron-builder injects our extraResources (frozen backend + SPA) AFTER
    # Electron's own ad-hoc signature, which breaks the seal. On Apple Silicon a
    # broken signature is fatal (the app is SIGKILL'd on launch), so re-seal the
    # whole bundle ad-hoc. Enough to launch locally; real distribution needs a
    # Developer ID + notarization.
    codesign --force --deep --sign - "$APP"
    # Prefer /Applications (admins can write it); fall back to ~/Applications.
    if [ -w /Applications ]; then DEST_DIR="/Applications"; else DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
    echo "▸ [4/4] installing to $DEST_DIR/haro.app …"
    progress 90 "Installing"
    rm -rf "$DEST_DIR/haro.app"
    cp -R "$APP" "$DEST_DIR/"
    echo "✓ haro updated. Quit any open haro window, then relaunch (Spotlight → haro, or open -a haro)."
    ;;
  *)
    DEST="$HOME/.local/opt/haro"
    echo "▸ [3/4] packaging (electron-builder --linux AppImage) …"
    progress 70 "Packaging app"
    ( cd "$ROOT/desktop" && npx electron-builder --linux AppImage )

    echo "▸ [4/4] installing to $DEST …"
    progress 90 "Installing"
    rm -rf "$DEST"; mkdir -p "$DEST"
    cp -r "$ROOT/dist-desktop/linux-unpacked/." "$DEST/"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    echo "✓ haro updated. Quit any open haro window, then relaunch (Super+H)."
    ;;
esac

# A terminal-run rebuild (no --restart) has no app to relaunch and clear the file, so
# drop the milestone here. The --restart path instead keeps it (set to 100 below) for
# the old app's final poll; the relaunched build clears it on boot (update.clear_progress).
[ "$RESTART" = "1" ] || rm -f "$PROGRESS_FILE"

# --restart: the in-app self-update ran this while the old app was still open, so
# swap it now. The backend launched us detached (start_new_session), so killing
# the app doesn't kill this script. Kill every haro process, then relaunch the
# freshly-installed build. Workspaces persist across the restart (SQLite).
if [ "$RESTART" = "1" ]; then
  # Signal the running app that the new build is installed. The Electron main
  # process watches this sentinel and relaunches ITSELF (app.relaunch) — which
  # restarts cleanly onto the new build with the correct window icon and proper
  # single-instance handling. A raw `setsid`/`open` relaunch here raced the old
  # instance (old window survived with a stale banner) and lost the Wayland icon.
  mkdir -p "$HOME/.haro"
  progress 100 "Restarting"
  : > "$HOME/.haro/.update-ready"
  echo "▸ signalled haro to relaunch onto the new build"
fi
