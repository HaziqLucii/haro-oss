#!/usr/bin/env bash
# Build the Linux release: the Flutter client with the PyInstaller-frozen backend inside.
#
#   dist/haro-<version>-linux-x86_64.tar.gz
#   dist/haro-<version>-x86_64.AppImage
#
# Bundle layout (the app finds the backend by path, see app/lib/backend/backend_plan.dart):
#   <bundle>/haro_app                              Flutter executable
#   <bundle>/backend/haro-backend/haro-backend     frozen backend (PyInstaller onedir)
#
# Build on the oldest glibc you want to support (CI uses ubuntu-22.04): the frozen backend
# and the Flutter engine both link against the build machine's glibc.
#
# Env: HARO_BUILD_CACHE (default .cache/linux-build) holds the Python venv, the PyInstaller
# work dir and appimagetool. SKIP_APPIMAGE=1 stops after the tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${HARO_BUILD_CACHE:-$ROOT/.cache/linux-build}"
DIST="$ROOT/dist"
VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/app/pubspec.yaml" | head -1)"
[ -n "$VERSION" ] || { echo "cannot read version from app/pubspec.yaml" >&2; exit 1; }
ARCH="x86_64"
NAME="haro-$VERSION-linux-$ARCH"

echo "haro $VERSION"
mkdir -p "$CACHE" "$DIST"

echo "[1/5] flutter build linux --release"
( cd "$ROOT/app" && flutter build linux --release )
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
[ -x "$BUNDLE/haro_app" ] || { echo "missing $BUNDLE/haro_app" >&2; exit 1; }

echo "[2/5] freeze the backend (PyInstaller)"
PY="${PYTHON:-python3}"
if [ ! -x "$CACHE/venv/bin/python" ]; then
  "$PY" -m venv "$CACHE/venv"
fi
"$CACHE/venv/bin/pip" install --quiet --upgrade pip
"$CACHE/venv/bin/pip" install --quiet -r "$ROOT/backend/requirements.txt" pyinstaller
rm -rf "$CACHE/pyi"
( cd "$ROOT/backend" && "$CACHE/venv/bin/python" -m PyInstaller --noconfirm \
    --distpath "$CACHE/pyi/dist" --workpath "$CACHE/pyi/work" haro-backend.spec )
FROZEN="$CACHE/pyi/dist/haro-backend"
[ -x "$FROZEN/haro-backend" ] || { echo "missing frozen backend" >&2; exit 1; }

echo "[3/5] stage $NAME"
STAGE="$CACHE/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/$NAME/backend"
cp -a "$BUNDLE/." "$STAGE/$NAME/"
cp -a "$FROZEN" "$STAGE/$NAME/backend/haro-backend"

# Wayland compositors ignore the window icon and match the xdg app id (set in
# app/linux/CMakeLists.txt as APPLICATION_ID) to a desktop file of that exact name.
APP_ID="dev.haro.haro_app"
cp "$ROOT/app/assets/brand/app_icon.png" "$STAGE/$NAME/$APP_ID.png"
cat > "$STAGE/$NAME/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=haro
Comment=A local-first workbench where you stay the author of your code
Exec=haro_app
Icon=$APP_ID
Categories=Development;
Terminal=false
StartupWMClass=$APP_ID
EOF
cat > "$STAGE/$NAME/install.sh" <<'EOF'
#!/bin/sh
# Registers this extracted copy of haro with the desktop (launcher entry + icon).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_ID="dev.haro.haro_app"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$DATA/applications" "$DATA/icons/hicolor/512x512/apps"
cp "$HERE/$APP_ID.png" "$DATA/icons/hicolor/512x512/apps/$APP_ID.png"
# Desktop Entry spec: Exec is quoted, and inside the quotes \ becomes four backslashes and
# " ` $ get two (the value is unescaped once as a string, then once as a command line).
EXEC="$(printf '%s' "$HERE/haro_app" | sed -e 's/\\/\\\\\\\\/g' -e 's/"/\\\\"/g' -e 's/`/\\\\`/g' -e 's/\$/\\\\$/g' -e 's/%/%%/g')"
{
  sed '/^Exec=/,$d' "$HERE/$APP_ID.desktop"
  printf 'Exec="%s"\n' "$EXEC"
  sed '1,/^Exec=/d' "$HERE/$APP_ID.desktop"
} > "$DATA/applications/$APP_ID.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" || true
echo "installed $DATA/applications/$APP_ID.desktop"
EOF
chmod +x "$STAGE/$NAME/install.sh"

echo "[4/5] tarball"
rm -f "$DIST/$NAME.tar.gz"
tar -C "$STAGE" --owner=0 --group=0 -czf "$DIST/$NAME.tar.gz" "$NAME"

if [ "${SKIP_APPIMAGE:-0}" = "1" ]; then
  echo "SKIP_APPIMAGE=1, done"
  ls -lh "$DIST/$NAME.tar.gz"
  exit 0
fi

echo "[5/5] AppImage"
APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
if [ -n "${APPIMAGETOOL:-}" ]; then
  [ -x "$APPIMAGETOOL" ] || { echo "APPIMAGETOOL=$APPIMAGETOOL is not executable" >&2; exit 1; }
else
  APPIMAGETOOL="$CACHE/appimagetool-$APPIMAGETOOL_VERSION-$ARCH.AppImage"
  if [ ! -f "$APPIMAGETOOL" ]; then
    curl -fsSL -o "$APPIMAGETOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$ARCH.AppImage"
  fi
  echo "$APPIMAGETOOL_SHA256  $APPIMAGETOOL" | sha256sum -c - \
    || { rm -f "$APPIMAGETOOL"; echo "appimagetool checksum mismatch" >&2; exit 1; }
  chmod +x "$APPIMAGETOOL"
fi

APPDIR="$CACHE/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib"
cp -a "$STAGE/$NAME" "$APPDIR/usr/lib/haro"
mkdir -p "$APPDIR/usr/share/icons/hicolor/512x512/apps" "$APPDIR/usr/share/applications"
cp "$STAGE/$NAME/$APP_ID.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/$APP_ID.png"
cp "$STAGE/$NAME/$APP_ID.png" "$APPDIR/$APP_ID.png"
cp "$STAGE/$NAME/$APP_ID.png" "$APPDIR/.DirIcon"
cp "$STAGE/$NAME/$APP_ID.desktop" "$APPDIR/$APP_ID.desktop"
cp "$STAGE/$NAME/$APP_ID.desktop" "$APPDIR/usr/share/applications/$APP_ID.desktop"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/haro/haro_app" "$@"
EOF
chmod +x "$APPDIR/AppRun"

OUT="$DIST/haro-$VERSION-$ARCH.AppImage"
rm -f "$OUT"
# --appimage-extract-and-run: appimagetool is itself an AppImage and needs no FUSE this way
# (CI containers have none).
ARCH="$ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUT"

echo
ls -lh "$DIST/$NAME.tar.gz" "$OUT"
