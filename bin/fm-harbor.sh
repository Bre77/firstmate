#!/usr/bin/env bash
# Harbor: a read-only, loopback-only backlog dashboard (fork-only firstmate feature).
#
# One HTML page, grouped the way the captain thinks about the backlog: work
# waiting on him, work in flight, queued or blocked work, and a short recent-done
# tail. It only ever READS the backlog through tasks-axi's own list command
# (bin/fm-harbor.py owns the render); it never writes to the backlog, task files,
# or any other fleet state, and it keeps no cache or second copy of the data - a
# page load re-runs the read fresh.
#
# Auto-refresh mechanism: the server (bin/fm-harbor.py serve) renders the page
# synchronously on every request and the page itself carries a <meta
# http-equiv="refresh"> tag, so the captain's browser reloads on its own. This
# was chosen over a static file regenerated on a timer because it needs no
# scheduler or background regeneration loop - the backlog is small (tens of
# tasks), so a per-request read is cheap and always honest, with nothing that
# can drift stale between regenerations.
#
# Binds 127.0.0.1 ONLY, hardcoded, never configurable - the captain reaches it
# through his own SSH tunnel. The only knob is --port.
#
# Subcommands:
#   start [--port <n>]   background the server (default port 4173), confirm it
#                         bound, print the URL, then return
#   stop                  stop this home's running server (home-scoped, never a
#                         broad pkill)
#   status                report whether it is running, and its URL
#   render                print the current page's HTML to stdout without
#                         starting a server, e.g. `fm-harbor.sh render >out.html`
#   serve [--port <n>]   (foreground) run the server directly under the
#                         singleton lock; `start` is the usual entry point, this
#                         is for direct/test invocation
#
# Singleton per home: a second `start`/`serve` while one is already running for
# this FM_HOME reports it as already running rather than opening a second port.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

HARBOR_PY="$SCRIPT_DIR/fm-harbor.py"
BACKLOG="$DATA/backlog.md"
LOCK="$STATE/.harbor.lock"
READY="$STATE/.harbor.ready"
LOG="$STATE/.harbor.log"
DEFAULT_PORT=4173
START_CONFIRM_TIMEOUT=${FM_HARBOR_CONFIRM_TIMEOUT:-10}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "harbor: FAILED - python3 not found" >&2
    exit 1
  fi
}

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }
lock_is_this_home() { [ "$(cat "$LOCK/fm-home" 2>/dev/null || true)" = "$FM_HOME" ]; }
ready_port() { [ -f "$READY" ] && cut -d: -f2 <"$READY" 2>/dev/null || true; }

cmd_status() {
  local pid port
  pid=$(lock_pid)
  if fm_pid_alive "$pid" && lock_is_this_home; then
    port=$(ready_port)
    if [ -n "$port" ]; then
      echo "harbor: running pid=$pid  http://127.0.0.1:$port/"
    else
      echo "harbor: running pid=$pid (still starting)"
    fi
    return 0
  fi
  echo "harbor: not running"
  return 1
}

cmd_stop() {
  local pid
  pid=$(lock_pid)
  if fm_pid_alive "$pid" && lock_is_this_home; then
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 50 ] && fm_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    echo "harbor: stopped pid=$pid"
  else
    echo "harbor: not running"
  fi
  rm -f "$READY" 2>/dev/null || true
}

cmd_render() {
  require_python3
  exec python3 "$HARBOR_PY" render --file "$BACKLOG"
}

parse_port_flag() {  # <usage-label> "$@": echoes the resolved port
  local label=$1 port=$DEFAULT_PORT
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)
        [ $# -ge 2 ] || { echo "harbor: --port requires a value" >&2; exit 2; }
        port=$2
        shift 2
        ;;
      *)
        echo "usage: $(basename "$0") $label [--port <n>]" >&2
        exit 2
        ;;
    esac
  done
  case "$port" in
    ''|*[!0-9]*) echo "harbor: invalid --port: $port" >&2; exit 2 ;;
  esac
  printf '%s\n' "$port"
}

cmd_serve() {
  local port
  port=$(parse_port_flag serve "$@") || exit $?
  require_python3

  if ! fm_lock_try_acquire "$LOCK"; then
    local held=${FM_LOCK_HELD_PID:-}
    echo "harbor: already running${held:+ pid=$held}"
    exit 0
  fi
  printf '%s\n' "$FM_HOME" >"$LOCK/fm-home" || true

  child=
  # shellcheck disable=SC2317,SC2329 # invoked by the trap handlers below
  cleanup() {
    if [ -n "$child" ] && fm_pid_alive "$child"; then
      kill -TERM "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
    fi
    rm -f "$READY" 2>/dev/null || true
    fm_lock_release "$LOCK"
  }
  trap 'cleanup; exit 143' TERM INT
  trap 'cleanup; exit 129' HUP
  trap 'cleanup' EXIT

  rm -f "$READY" 2>/dev/null || true
  python3 "$HARBOR_PY" serve --file "$BACKLOG" --port "$port" --ready "$READY" &
  child=$!
  wait "$child"
  local rc=$?
  child=
  exit "$rc"
}

cmd_start() {
  local port pid
  port=$(parse_port_flag start "$@") || exit $?
  require_python3

  pid=$(lock_pid)
  if fm_pid_alive "$pid" && lock_is_this_home; then
    local existing_port
    existing_port=$(ready_port)
    if [ -n "$existing_port" ]; then
      echo "harbor: already running pid=$pid  http://127.0.0.1:$existing_port/"
    else
      echo "harbor: already running pid=$pid (still starting)"
    fi
    return 0
  fi

  rm -f "$READY" 2>/dev/null || true
  : >"$LOG" 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-harbor.sh" serve --port "$port" >>"$LOG" 2>&1 </dev/null &
  local child=$!
  disown "$child" 2>/dev/null || true

  local deadline
  deadline=$(( $(date +%s) + START_CONFIRM_TIMEOUT ))
  while :; do
    if [ -f "$READY" ]; then
      echo "harbor: started pid=$(lock_pid)  http://127.0.0.1:$(ready_port)/"
      return 0
    fi
    if ! fm_pid_alive "$child"; then
      echo "harbor: FAILED - server exited before it started listening" >&2
      [ -s "$LOG" ] && tail -n 20 "$LOG" >&2
      return 1
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  echo "harbor: FAILED - could not confirm the server started" >&2
  [ -s "$LOG" ] && tail -n 20 "$LOG" >&2
  return 1
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  render) cmd_render ;;
  serve) shift; cmd_serve "$@" ;;
  -h|--help|'') usage ;;
  *)
    echo "usage: $(basename "$0") <start|stop|status|render|serve> [--port <n>]" >&2
    exit 2
    ;;
esac
