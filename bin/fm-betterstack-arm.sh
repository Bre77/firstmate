#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the BetterStack status-page webhook route, with
# honest verification (fork-only firstmate feature). This route SHARES the
# ClickStack receiver's single HTTP listener process and port (see
# docs/betterstack-webhook.md and docs/clickstack-webhook.md for why sharing is
# correct here), so arming it means:
#   1. generate this route's unguessable token if the gate file does not already
#      carry one (bshook_ensure_token, in fm-betterstack-lib.sh)
#   2. ensure the shared daemon is running with that token loaded - forcing a
#      restart when we just generated a fresh token or no healthy daemon is up,
#      since the listener reads its config once, at process start, and a plain
#      (re-)arm no-ops on an already-healthy daemon without picking up new config
#
# It delegates the actual daemon lifecycle (singleton lock, ready-file confirm
# loop) to bin/fm-clickstack-arm.sh - one implementation of "start a listener and
# verify it bound", not a second one. Run this as its own standalone background
# task, exactly like bin/fm-clickstack-arm.sh.
#
# Subcommands:
#   (none)      (re-)arm the shared receiver, generating a token if needed
#   --show-url  print the route's path and token (the pieces of the paste-into-
#               BetterStack URL); never printed by plain arm, since the secret
#               should not land in ordinary status/log output unasked
#
# Inert by default: with no config/betterstack-webhook.env gate, both subcommands
# exit 0 silently.
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

ARM="$SCRIPT_DIR/fm-clickstack-arm.sh"
# The shared daemon's singleton lock/ready-file live under the ClickStack lib's
# naming (cshook_*) because it owns the daemon lifecycle; this route just checks
# the same two paths to decide whether a restart is needed.
LOCK=$(cshook_lock_dir)
READY=$(cshook_ready_file)

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }
lock_is_this_home() { [ "$(cat "$LOCK/fm-home" 2>/dev/null || true)" = "$FM_HOME" ]; }
shared_daemon_healthy() {
  local pid
  pid=$(lock_pid)
  fm_pid_alive "$pid" && lock_is_this_home && [ -f "$READY" ]
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --show-url) mode=show-url ;;
  *) echo "usage: $(basename "$0") [--show-url]" >&2; exit 2 ;;
esac

# Inert unless opted in.
bshook_enabled || exit 0

if [ "$mode" = show-url ]; then
  bshook_load_config
  if [ -z "$BSHOOK_TOKEN" ]; then
    echo "betterstack webhook: no token yet - run $(basename "$0") to generate one" >&2
    exit 1
  fi
  echo "betterstack webhook: path=$(bshook_path) token=$BSHOOK_TOKEN"
  exit 0
fi

GATE_FILE=$(bshook_env_file)
bshook_load_config
had_token=0
[ -n "$BSHOOK_TOKEN" ] && had_token=1

if [ "$had_token" = 0 ]; then
  if ! bshook_ensure_token "$GATE_FILE"; then
    echo "betterstack webhook: FAILED - could not generate a token" >&2
    exit 1
  fi
fi

# A brand-new token needs a restart to reach the listener even if a daemon
# (serving ClickStack alone, most likely) is already healthy.
if [ "$had_token" = 1 ] && shared_daemon_healthy; then
  "$ARM"
else
  "$ARM" --restart
fi
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "betterstack webhook: FAILED - could not confirm the shared receiver is listening" >&2
  exit "$rc"
fi

echo "betterstack webhook: ready path=$(bshook_path) - run '$(basename "$0") --show-url' for the token"
