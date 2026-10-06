#!/usr/bin/env bash
# Build the macOS release: the Flutter client with the PyInstaller-frozen backend inside.
#
#   dist/haro.app
#
# Bundle layout (the app finds the backend relative to its executable, see
# app/lib/backend/backend_plan.dart):
#   haro.app/Contents/MacOS/haro                             Flutter executable
#   haro.app/Contents/Resources/backend/haro-backend/haro-backend  frozen backend (PyInstaller onedir)
#
# It lives in Resources, not MacOS: codesign treats everything under MacOS as code and rejects
# the .dist-info directories inside the PyInstaller bundle.
#
# The app must run WITHOUT the app-sandbox entitlement: a sandboxed parent makes the spawned
# backend sandboxed too, which blocks git, agents and ~/.haro.
#
# Env: HARO_BUILD_CACHE (default .cache/macos-build) holds the Python venv and PyInstaller work
# dir. INSTALL=1 also copies the app to ~/Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${HARO_BUILD_CACHE:-$ROOT/.cache/macos-build}"
DIST="$ROOT/dist"

if grep -q 'com.apple.security.app-sandbox' "$ROOT/app/macos/Runner/Release.entitlements"; then
  echo "app/macos/Runner/Release.entitlements still has app-sandbox; remove it first" >&2
  exit 1
fi

mkdir -p "$CACHE" "$DIST"

echo "[1/4] flutter build macos --release"
( cd "$ROOT/app" && flutter build macos --release )
APP="$ROOT/app/build/macos/Build/Products/Release/haro.app"
[ -x "$APP/Contents/MacOS/haro" ] || { echo "missing $APP" >&2; exit 1; }

echo "[2/4] freeze the backend (PyInstaller)"
PY="${PYTHON:-python3}"
[ -x "$CACHE/venv/bin/python" ] || "$PY" -m venv "$CACHE/venv"
"$CACHE/venv/bin/pip" install --quiet --upgrade pip
"$CACHE/venv/bin/pip" install --quiet -r "$ROOT/backend/requirements.txt" pyinstaller
rm -rf "$CACHE/pyi"
( cd "$ROOT/backend" && "$CACHE/venv/bin/python" -m PyInstaller --noconfirm \
    --distpath "$CACHE/pyi/dist" --workpath "$CACHE/pyi/work" haro-backend.spec )
FROZEN="$CACHE/pyi/dist/haro-backend"
[ -x "$FROZEN/haro-backend" ] || { echo "missing frozen backend" >&2; exit 1; }

echo "[3/4] stage dist/haro.app"
rm -rf "$DIST/haro.app"
cp -R "$APP" "$DIST/haro.app"
mkdir -p "$DIST/haro.app/Contents/Resources/backend"
cp -R "$FROZEN" "$DIST/haro.app/Contents/Resources/backend/haro-backend"

echo "[4/4] ad-hoc sign"
codesign --force --deep --sign - "$DIST/haro.app"
codesign --verify --strict "$DIST/haro.app"

if [ "${INSTALL:-0}" = "1" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/haro.app"
  cp -R "$DIST/haro.app" "$HOME/Applications/haro.app"
  echo "installed $HOME/Applications/haro.app"
fi

du -sh "$DIST/haro.app"
