#!/usr/bin/env bash
# Smoke-test the frozen backend inside a built tarball: extract it, boot the backend on a free
# loopback port against a TEMP database (never ~/.haro/haro.db), curl /health, then stop it.
#   scripts/smoke-linux.sh dist/haro-<version>-linux-x86_64.tar.gz
set -euo pipefail

TARBALL="${1:?usage: smoke-linux.sh <tarball>}"
TMP="$(mktemp -d)"
trap 'kill "${PID:-0}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

tar -xzf "$TARBALL" -C "$TMP"
BIN="$(echo "$TMP"/*/backend/haro-backend/haro-backend)"
[ -x "$BIN" ] || { echo "no frozen backend in tarball" >&2; exit 1; }
[ -x "$(dirname "$BIN")/../../haro_app" ] || { echo "no haro_app in tarball" >&2; exit 1; }

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
HARO_DB="$TMP/haro.db" "$BIN" --port "$PORT" >"$TMP/backend.log" 2>&1 &
PID=$!

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >"$TMP/health.json" 2>/dev/null; then
    echo "port $PORT: /health -> $(cat "$TMP/health.json")"
    echo "projects -> $(curl -fsS "http://127.0.0.1:$PORT/projects")"
    exit 0
  fi
  kill -0 "$PID" 2>/dev/null || { echo "backend exited:" >&2; cat "$TMP/backend.log" >&2; exit 1; }
  sleep 0.5
done
echo "backend never answered /health" >&2
cat "$TMP/backend.log" >&2
exit 1
