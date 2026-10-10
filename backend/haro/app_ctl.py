"""``haro-app``: the agent's way to run, check and look at the app haro runs for its workspace, and
to run the commands the project declares (``[scripts.tools.<name>]``).

haro owns the dev server (the Run button, ``lifecycle.start_run``) and keeps its output in a
file the agent watches (``run_logs.py``). Seeing is half of it: after the agent fixes a bug the
running app is still the old code. This small script lets it act on that same process, through
haro's own run endpoints, instead of asking the developer to press Stop and Run. Every verb
prints one short fact per line, written for the model that reads it, so the agent never has to
be told how to run or check the app.

It is a POSIX shell script around ``curl`` (no jq, no python) that is written to ``~/.haro/bin``
and put on the agent's PATH, with ``$HARO_API`` (the backend's address) and
``$HARO_WORKSPACE_ID`` in its environment. It reads the backend's ``?format=text`` answers
(``key=value`` lines), so it needs no JSON parser. It only reaches endpoints of its own
workspace. The agent has a shell and could call the backend directly anyway, so this takes
nothing away and nothing is added.
"""

from __future__ import annotations

import logging
import os
import stat
import tempfile
from pathlib import Path

from .config import settings

log = logging.getLogger(__name__)

SCRIPT = r"""#!/bin/sh
# haro-app: the app haro runs for this workspace, and the commands the project declares.
#   start | restart [run] [--timeout N] [--no-wait]   (it waits until the app answers, 60s)
#   stop [run]        wait [run] [--timeout N]        status [run]
#   url [/path] [run] logs [-n N] [run]               open [/path] [run]
#   list              do <tool>
# The app is the process the Run button starts; its output goes to $HARO_RUN_LOG. Without a run
# name, the commands act on the default run and stop ends every run in the workspace.
set -eu
: "${HARO_API:?haro-app only works inside a haro agent run (HARO_API is not set)}"
: "${HARO_WORKSPACE_ID:?haro-app only works inside a haro agent run (HARO_WORKSPACE_ID is not set)}"
base="$HARO_API/workspaces/$HARO_WORKSPACE_ID"
esc=$(printf '\033')

usage() {
  echo "usage: haro-app start|restart|wait|stop|status|url|logs|open|list|do ... (see the comment at the top of this script)" >&2
  exit 2
}

verb="${1:-}"
[ $# -eq 0 ] || shift
run="" path="" tool="" timeout=60 wait=1 lines=60
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) [ $# -ge 2 ] || usage; timeout="$2"; shift ;;
    --no-wait) wait=0 ;;
    -n) [ $# -ge 2 ] || usage; lines="$2"; shift ;;
    -*) usage ;;
    "") ;;
    /*) case "$verb" in url | open) path="$1" ;; *) run="$1" ;; esac ;;
    *) case "$verb" in do) tool="$1" ;; *) run="$1" ;; esac ;;
  esac
  shift
done
case "$timeout$lines" in *[!0-9]* | "") echo "haro-app: --timeout and -n take a whole number" >&2; exit 2 ;; esac
case "$run$tool" in *[!A-Za-z0-9_.-]*) echo "haro-app: '$run$tool' is not a run or tool name (letters, digits, _ . -); a path starts with /" >&2; exit 2 ;; esac

query="" sfx=""
[ -z "$run" ] || { query="?run_id=$run"; sfx=" $run"; }
maxtime=60

req() {
  method="$1"; target="$2"; shift 2
  resp=$(curl -sS --max-time "$maxtime" -w '\n%{http_code}' -X "$method" "$@" "$target") || {
    echo "haro-app: could not reach haro at $HARO_API" >&2
    exit 1
  }
  code=$(printf '%s\n' "$resp" | tail -n 1)
  body=$(printf '%s\n' "$resp" | sed '$d')
}

fail() {
  detail=$(printf '%s' "$body" | sed -n 's/^{"detail":"\(.*\)"}$/\1/p' | sed 's/\\"/"/g; s/\\u0027/'"'"'/g')
  [ -n "$detail" ] || detail="HTTP $code $(printf '%s' "$body" | cut -c1-200)"
  echo "haro-app: $detail"
  exit 1
}

ok() { [ "$code" -lt 400 ] || fail; }

field() { printf '%s\n' "$body" | sed -n "s/^$1=//p" | head -n 1; }

strip_ansi() { sed "s/$esc\[[0-9;?]*[A-Za-z]//g"; }

get_info() {
  saved=$maxtime; maxtime=15
  req GET "$base/run/info?format=text${run:+&run_id=$run}"
  maxtime=$saved
  ok
  running=$(field running); url=$(field url); up=$(field up_seconds); logfile=$(field log); probe=$(field probe)
}

wait_ready() {
  t0=$(date +%s)
  get_info
  if [ "$running" != 1 ]; then
    echo "app: exited before answering, read the log with: haro-app logs$sfx"
    return 1
  fi
  if [ "$probe" != 1 ] || [ -z "$url" ]; then
    echo "app: started (this run has no address to check, read the log with: haro-app logs$sfx)"
    return 0
  fi
  n=0
  while :; do
    c=$(curl -ksS -o /dev/null --max-time 2 -w '%{http_code}' "$url" 2>/dev/null || true)
    case "$c" in
      "" | 000 | 502 | 503 | 504) ;;
      5*) echo "app: running at $url (ready in $(($(date +%s) - t0))s, but it answers HTTP $c: read the log with: haro-app logs$sfx)"; return 0 ;;
      *) echo "app: running at $url (ready in $(($(date +%s) - t0))s)"; return 0 ;;
    esac
    if [ $(($(date +%s) - t0)) -ge "$timeout" ]; then
      echo "app: started but not answering after ${timeout}s, read the log with: haro-app logs$sfx"
      return 1
    fi
    n=$((n + 1))
    if [ $((n % 6)) -eq 0 ]; then
      get_info
      if [ "$running" != 1 ]; then
        echo "app: exited before answering, read the log with: haro-app logs$sfx"
        return 1
      fi
    fi
    sleep 0.5
  done
}

log_path() {
  if [ -z "$run" ] && [ -n "${HARO_RUN_LOG:-}" ]; then
    lp="$HARO_RUN_LOG"
  else
    [ -n "${logfile:-}" ] || get_info
    lp="$logfile"
  fi
}

case "$verb" in
  start | restart)
    req POST "$base/run$query"; ok
    if [ "$wait" = 1 ]; then
      wait_ready || exit 1
    else
      get_info
      echo "app: started at $url (not waiting for it to answer)"
    fi
    ;;
  wait)
    get_info
    [ "$running" = 1 ] || { echo "app: not running, start it with: haro-app start$sfx"; exit 1; }
    wait_ready || exit 1
    ;;
  stop)
    req POST "$base/run/stop$query"; ok
    echo "app: stopped"
    ;;
  status)
    get_info
    if [ "$running" = 1 ]; then line="app: running at $url (up ${up}s)"; else line="app: stopped"; fi
    log_path
    if [ -r "$lp" ]; then
      last=$(tail -n 50 "$lp" | strip_ansi | grep -E 'Error:|Traceback|Exception|EADDRINUSE|[Ff]ailed to (compile|start|load)' | grep -vE '(^|[^0-9])0 (errors?|failed)' | tail -n 1 |
        sed 's/^[[:space:]]*//' | cut -c1-120) || true
      [ -z "$last" ] || line="$line | last error: $last"
    fi
    echo "$line"
    ;;
  url)
    get_info
    if [ "$running" != 1 ] || [ -z "$url" ]; then
      echo "app: not running, start it with: haro-app start$sfx"
      exit 1
    fi
    if [ -z "$path" ]; then
      echo "$url"
    else
      echo "$(printf '%s' "$url" | sed 's|^\([a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*\).*|\1|')$path"
    fi
    ;;
  logs)
    log_path
    if [ ! -r "$lp" ]; then
      echo "app: no log yet, start the app with: haro-app start$sfx"
      exit 0
    fi
    tail -n "$lines" "$lp" | strip_ansi
    ;;
  open)
    json="{\"path\":\"$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    [ -z "$run" ] || json="$json,\"run_id\":\"$run\""
    req POST "$base/run/open?format=text" -H 'Content-Type: application/json' --data-binary "$json}"; ok
    echo "app: offered $(field url) to the developer"
    ;;
  list)
    maxtime=15; req GET "$base/run/list?format=text"; ok
    printf '%s\n' "$body"
    ;;
  do)
    [ -n "$tool" ] || { echo "usage: haro-app do <tool> (haro-app list shows them)" >&2; exit 2; }
    maxtime=1900; req POST "$base/tools/$tool?format=text"; ok
    printf '%s\n' "$body"
    exit_code=$(printf '%s\n' "$body" | tail -n 1 | sed -n 's/^tool .*: exit \([0-9][0-9]*\) in .*/\1/p')
    [ "$exit_code" = 0 ] || exit 1
    ;;
  *) usage ;;
esac
"""

_written: set[str] = set()


def bin_dir() -> Path:
    return Path(settings.bin_dir).expanduser()


def ensure_script() -> Path | None:
    """Write ``haro-app`` (executable) when it is missing or out of date; return its folder, or
    None when it could not be written (the runner then offers no command). Checked once per
    process: the content is constant, and this runs on the event loop."""
    folder = bin_dir()
    key = str(folder)
    if key in _written and (folder / "haro-app").exists():
        return folder
    path = folder / "haro-app"
    try:
        if not path.exists() or path.read_text() != SCRIPT:
            folder.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".haro-app.", dir=folder)
            with os.fdopen(fd, "w") as f:
                f.write(SCRIPT)
            os.chmod(tmp, os.stat(tmp).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            os.replace(tmp, path)
    except OSError as exc:
        log.warning("haro-app could not be written to %s: %s", folder, exc)
        return None
    _written.add(key)
    return folder
