#!/usr/bin/env bash
# ClickStack + BetterStack webhook receiver daemon controller (fork-only firstmate feature).
#
# Runs the shared localhost HTTP listener (bin/fm-clickstack-listener.py) under a
# home-scoped singleton lock, so at most one receiver serves a given firstmate
# home. It is its OWN process with its OWN lock (state/.clickstack-recv.lock); it
# never touches the watcher, the watcher's lock, or state/.last-watcher-beat, so
# it cannot interfere with the supervision backbone (see docs/clickstack-webhook.md).
#
# Two independent, independently-gated integrations share this one process and
# port: ClickStack alerts (config/clickstack-webhook.env) and BetterStack
# status-page webhooks (config/betterstack-webhook.env; docs/betterstack-webhook.md).
# They share it because the reverse proxy forwards the whole host to one port, so
# a second listener on a different port would be unreachable without an
# out-of-repo proxy change; the listener dispatches by path and keeps each
# integration's route 404 unless that integration's own gate is present.
#
# Subcommands:
#   serve   (default) acquire the singleton and run the listener in the foreground
#   stop    signal this home's running receiver (never a broad pkill)
#   status  print whether this home's receiver is live
#
# Inert by default: with NEITHER gate file present, `serve` exits 0 silently,
# exactly like the X-mode poll's hard no-op.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-clickstack-lib.sh
. "$SCRIPT_DIR/fm-clickstack-lib.sh"
# shellcheck source=bin/fm-betterstack-lib.sh
. "$SCRIPT_DIR/fm-betterstack-lib.sh"

LISTENER="$SCRIPT_DIR/fm-clickstack-listener.py"
LOCK=$(cshook_lock_dir)
READY=$(cshook_ready_file)
INBOX=$(cshook_inbox_dir)
BS_INBOX=$(bshook_inbox_dir)

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }

lock_is_this_home() {
  [ "$(cat "$LOCK/fm-home" 2>/dev/null || true)" = "$FM_HOME" ]
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
    echo "clickstack receiver: stopped pid=$pid"
  else
    echo "clickstack receiver: not running"
  fi
  rm -f "$READY" 2>/dev/null || true
}

cmd_status() {
  local pid
  pid=$(lock_pid)
  if fm_pid_alive "$pid" && lock_is_this_home; then
    echo "clickstack receiver: running pid=$pid ready=$([ -f "$READY" ] && echo yes || echo no)"
    return 0
  fi
  echo "clickstack receiver: not running"
  return 1
}

cmd_serve() {
  local cs_on=0 bs_on=0
  cshook_enabled && cs_on=1
  bshook_enabled && bs_on=1
  { [ "$cs_on" = 1 ] || [ "$bs_on" = 1 ]; } || exit 0

  # Port/bind stay owned by the ClickStack gate (or its defaults) even when only
  # BetterStack is enabled: BetterStack has no port/bind config of its own, since
  # it always rides the one shared, proxy-fronted port.
  cshook_load_config
  bshook_load_config

  if ! command -v python3 >/dev/null 2>&1; then
    echo "clickstack receiver: FAILED - python3 not found" >&2
    exit 1
  fi

  if ! fm_lock_try_acquire "$LOCK"; then
    local held=${FM_LOCK_HELD_PID:-}
    echo "clickstack receiver: already running${held:+ pid=$held}"
    exit 0
  fi
  printf '%s\n' "$FM_HOME" > "$LOCK/fm-home" || true

  child=
  # shellcheck disable=SC2317,SC2329 # Invoked by the trap handlers below.
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
  mkdir -p "$INBOX" 2>/dev/null || true
  if [ "$bs_on" = 1 ]; then mkdir -p "$BS_INBOX" 2>/dev/null || true; fi

  CSHOOK_BIND="$CSHOOK_BIND" \
  CSHOOK_PORT="$CSHOOK_PORT" \
  CSHOOK_ENABLED="$cs_on" \
  CSHOOK_SECRET="$CSHOOK_SECRET" \
  CSHOOK_SECRET_HEADER="$CSHOOK_SECRET_HEADER" \
  CSHOOK_INBOX="$INBOX" \
  CSHOOK_READY="$READY" \
  BSHOOK_ENABLED="$bs_on" \
  BSHOOK_TOKEN="$BSHOOK_TOKEN" \
  BSHOOK_INBOX="$BS_INBOX" \
    python3 "$LISTENER" &
  child=$!
  wait "$child"
  local rc=$?
  child=
  exit "$rc"
}

case "${1:-serve}" in
  serve|'') cmd_serve ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: $(basename "$0") [serve|stop|status]" >&2; exit 2 ;;
esac
