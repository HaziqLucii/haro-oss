#!/usr/bin/env bash
# Install the AppImage you just built on THIS machine, the way a user would have it: the file in
# ~/Applications, the launcher entries pointing at it, the panel name and icon right.
#
#   scripts/install-linux-local.sh              build (unless dist/ is current), swap, fix up, verify
#   scripts/install-linux-local.sh --skip-build use the AppImage already in dist/
#   scripts/install-linux-local.sh --check      change nothing: verify the installed state only
#
# Why it exists: swapping the file by hand left two launcher entries to keep right (the one
# AppImageLauncher writes, which it renames to "haro (1)" a few seconds after every swap, and the
# hidden `dev.haro.haro_app.desktop` alias that gives the window its icon and panel name on
# Wayland). The alias once kept pointing at a deleted AppImage, so a panel pin failed with
# "Could not find the program". This does every step, in order, and checks the result.
#
# It never starts haro (an AppImage run opens a real window and a backend) and refuses to swap
# the file while haro is open.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS="${HARO_APPS_DIR:-$HOME/Applications}"
ENTRIES="${HARO_ENTRIES_DIR:-$HOME/.local/share/applications}"
ICON="${HARO_ALIAS_ICON:-$HOME/.local/share/icons/hicolor/512x512/apps/dev.haro.haro_app.png}"
ALIAS="$ENTRIES/dev.haro.haro_app.desktop"
VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/app/pubspec.yaml" | head -1)"
[ -n "$VERSION" ] || { echo "cannot read version from app/pubspec.yaml" >&2; exit 1; }
BUILT="$ROOT/dist/haro-$VERSION-x86_64.AppImage"
DEST="$APPS/haro-$VERSION-x86_64.AppImage"

mode=install
build=1
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --skip-build) build=0 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

problems=0
note() { printf '  %s\n' "$*"; }
bad() { printf '  PROBLEM: %s\n' "$*"; problems=$((problems + 1)); }

haro_running() {
  pgrep -x haro_app >/dev/null 2>&1 || pgrep -x haro-backend >/dev/null 2>&1 \
    || pgrep '^haro-[0-9]' >/dev/null 2>&1
}

launcher_daemon() {
  [ -z "${HARO_NO_LAUNCHER_DAEMON:-}" ] && systemctl --user is-active --quiet appimagelauncherd 2>/dev/null
}

# Rewrite one `Key=value` line in a desktop entry, adding it after [Desktop Entry] if missing.
set_key() {
  local file="$1" key="$2" value="$3"
  if grep -q "^$key=" "$file"; then
    sed -i "0,/^$key=.*/s|^$key=.*|$key=$value|" "$file"
  else
    sed -i "/^\[Desktop Entry\]/a $key=$value" "$file"
  fi
}

# The first Exec token of every haro entry must be a file that exists.
verify() {
  echo "Checking the installed state"
  [ -f "$DEST" ] && note "installed: $DEST" || bad "the AppImage is not at $DEST"
  if [ -f "$BUILT" ] && [ -f "$DEST" ]; then
    if [ "$(sha256sum "$BUILT" | cut -d' ' -f1)" = "$(sha256sum "$DEST" | cut -d' ' -f1)" ]; then
      note "matches the build in dist/"
    else
      note "differs from the build in dist/ (an older build is installed)"
    fi
  fi
  local found=0 f exe
  for f in "$ENTRIES"/appimagekit_*-haro.desktop "$ALIAS"; do
    [ -f "$f" ] || continue
    found=1
    exe="$(grep -m1 '^Exec=' "$f" | cut -d= -f2- | awk '{print $1}')"
    if [ "$exe" = "$DEST" ]; then
      note "$(basename "$f"): Exec ok"
    elif [ -e "$exe" ]; then
      bad "$(basename "$f"): Exec points at $exe, the installed file is $DEST"
    else
      bad "$(basename "$f"): Exec points at a missing file: $exe"
    fi
    if grep -q '^Name=haro (1)$' "$f"; then bad "$(basename "$f"): name is 'haro (1)'"; fi
  done
  [ "$found" = 1 ] || bad "no haro launcher entry found in $ENTRIES"
  if [ -f "$ALIAS" ]; then
    grep -q '^Name=haro$' "$ALIAS" || bad "alias entry name is not 'haro' (the panel tooltip shows it)"
    grep -q '^NoDisplay=true$' "$ALIAS" || bad "alias entry is not hidden (it would show twice in the menu)"
    [ -f "$ICON" ] || bad "alias icon is missing: $ICON"
  fi
  return 0
}

if [ "$mode" = check ]; then
  verify
  [ "$problems" = 0 ] && echo "OK" || { echo "$problems problem(s)"; exit 1; }
  exit 0
fi

if haro_running; then
  echo "haro is open: close it first (the AppImage cannot be swapped while it runs)." >&2
  exit 1
fi

echo "haro $VERSION"
if [ "$build" = 1 ]; then
  command -v flutter >/dev/null 2>&1 || export PATH="$HOME/flutter/bin:$PATH"
  echo "[1/4] build"
  "$ROOT/scripts/build-linux.sh" >"${TMPDIR:-/tmp}/haro-build.log" 2>&1 \
    || { echo "build failed, see ${TMPDIR:-/tmp}/haro-build.log" >&2; exit 1; }
else
  echo "[1/4] build skipped"
fi
[ -f "$BUILT" ] || { echo "no AppImage at $BUILT" >&2; exit 1; }

echo "[2/4] swap the file"
mkdir -p "$APPS"
cp "$BUILT" "$APPS/.haro-install.tmp"
# Same file name: AppImageLauncher keeps its icon and entry. A different version's file is
# removed after, so its entry is cleaned up instead of left pointing at nothing.
mv -f "$APPS/.haro-install.tmp" "$DEST"
for old in "$APPS"/haro-*-x86_64*.AppImage; do
  [ -e "$old" ] && [ "$old" != "$DEST" ] && { rm -f "$old"; note "removed $(basename "$old")"; }
done

echo "[3/4] fix the launcher entries"
if launcher_daemon; then
  # The daemon re-integrates the file 5 to 10 seconds after the swap and rewrites the entry as
  # "haro (1)"; fixing before it is done only gets overwritten.
  waited=0
  until journalctl --user --since "-1min" 2>/dev/null | grep -a appimagelauncherd | grep -aq 'Done'; do
    sleep 3; waited=$((waited + 3)); [ "$waited" -lt 60 ] || { note "the launcher daemon did not report Done in 60s"; break; }
  done
  sleep 2
fi
for f in "$ENTRIES"/appimagekit_*-haro.desktop; do
  [ -f "$f" ] || continue
  sed -i 's/^Name=haro (1)$/Name=haro/' "$f"
done
if [ -f "$ALIAS" ]; then
  set_key "$ALIAS" Exec "$DEST"
  set_key "$ALIAS" Name haro
  set_key "$ALIAS" Comment "A local-first workbench where you stay the author of your code"
  set_key "$ALIAS" NoDisplay true
else
  note "no alias entry ($ALIAS): the panel falls back to the AppImage's own entry"
fi
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true

echo "[4/4] verify"
verify
if launcher_daemon; then
  # The daemon can rewrite an entry once more after a late change; look again after a pause.
  sleep 20
  echo "Checking again after 20s"
  problems=0
  verify
fi
[ "$problems" = 0 ] && echo "Installed haro $VERSION. Open it from the launcher." \
  || { echo "$problems problem(s): see above" >&2; exit 1; }
