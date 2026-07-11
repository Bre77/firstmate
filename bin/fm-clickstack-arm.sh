#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the shared ClickStack/BetterStack webhook
# receiver, with honest verification (fork-only firstmate feature). This mirrors
# bin/fm-watch-arm.sh: firstmate runs it as the harness's own tracked background
# task so the daemon SURVIVES the call and NOTIFIES on exit, letting firstmate
# re-arm it. Run it as its own standalone background task, never bundled onto
# another command, and never fire-and-forget with a shell `&` inside another call.
#
# It forks the receiver (bin/fm-clickstack-recv.sh serve) as a tracked child,
# then VERIFIES the outcome before settling in: a live singleton holder for THIS
# home plus a fresh bound-and-listening marker. It prints exactly one status line:
#   clickstack receiver: started pid=<N> (listening on <bind>:<port>)
#   clickstack receiver: healthy pid=<N> (already listening)
#   clickstack receiver: FAILED - could not confirm a listening receiver
# On started/healthy it exits zero (after blocking on the child for started); on
# FAILED it exits non-zero. Inert by default: with NEITHER gate (ClickStack's
# config/clickstack-webhook.env or BetterStack's config/betterstack-webhook.env;
# see docs/betterstack-webhook.md) it exits 0 silently. A config change to
# either gate needs a `--restart` to take effect, since the listener reads its
# config once at process start (bin/fm-betterstack-arm.sh does this for you).
#
# --stop / --restart are home-scoped: they act only on the pid recorded in THIS
# home's state/.clickstack-recv.lock, never a broad pkill that would hit sibling
# firstmate homes running the same daemon. They act on the WHOLE shared process,
# so they affect both integrations together.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-clickstack-lib.sh
. "$SCRIPT_DIR/fm-clickstack-lib.sh"
# shellcheck source=bin/fm-betterstack-lib.sh
. "$SCRIPT_DIR/fm-betterstack-lib.sh"

RECV="$SCRIPT_DIR/fm-clickstack-recv.sh"
LOCK=$(cshook_lock_dir)
READY=$(cshook_ready_file)
CONFIRM_TIMEOUT=${FM_CLICKSTACK_CONFIRM_TIMEOUT:-10}

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }
lock_is_this_home() { [ "$(cat "$LOCK/fm-home" 2>/dev/null || true)" = "$FM_HOME" ]; }

# A receiver is "healthy" iff the singleton lock names a live process that is this
# home's receiver AND the bound-and-listening marker exists. Sets HEALTHY_PID.
HEALTHY_PID=
healthy_receiver() {
  HEALTHY_PID=
  local pid
  pid=$(lock_pid)
  fm_pid_alive "$pid" || return 1
  lock_is_this_home || return 1
  [ -f "$READY" ] || return 1
  HEALTHY_PID=$pid
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  --stop) "$RECV" stop; exit $? ;;
  *) echo "usage: $(basename "$0") [--restart|--stop]" >&2; exit 2 ;;
esac

# Inert unless opted in to at least one of the two integrations.
{ cshook_enabled || bshook_enabled; } || exit 0

if [ "$mode" = restart ]; then
  "$RECV" stop >/dev/null 2>&1 || true
fi

if [ "$mode" = arm ] && healthy_receiver; then
  echo "clickstack receiver: healthy pid=$HEALTHY_PID (already listening)"
  exit 0
fi

child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

child_out=$(mktemp "$STATE/.clickstack-arm-output.XXXXXX") || {
  echo "clickstack receiver: FAILED - could not confirm a listening receiver"
  exit 1
}
"$RECV" serve >"$child_out" 2>&1 &
child=$!

deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_receiver; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cshook_load_config
      echo "clickstack receiver: started pid=$child (listening on $CSHOOK_BIND:$CSHOOK_PORT)"
      wait "$child"
      rc=$?
      [ -s "$child_out" ] && cat "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit "$rc"
    fi
    # Another receiver won the singleton; our child stood down. Report the live one.
    echo "clickstack receiver: healthy pid=$HEALTHY_PID (already listening)"
    wait "$child" 2>/dev/null || true
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if ! fm_pid_alive "$child"; then
    # The serve child exited before confirming (e.g. singleton no-op, or a bind
    # failure). Surface its output so the reason is visible.
    wait "$child" 2>/dev/null
    rc=$?
    # A clean singleton no-op ("already running") is success, not a failure.
    if grep -q 'already running' "$child_out" 2>/dev/null; then
      cat "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
    [ -s "$child_out" ] && cat "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    echo "clickstack receiver: FAILED - could not confirm a listening receiver"
    exit "${rc:-1}"
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "clickstack receiver: FAILED - could not confirm a listening receiver"
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
