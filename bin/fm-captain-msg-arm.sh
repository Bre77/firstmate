#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the captain messaging inbound route, with
# honest verification (fork-only firstmate feature). This route SHARES the
# ClickStack receiver's single HTTP listener process and port (see
# docs/clickstack-webhook.md for why sharing is correct here), so arming it
# means: ensure config/captain-msg.env is complete, then ensure the shared
# daemon is running with the current Twilio Account Auth Token loaded.
#
# Unlike BetterStack's locally-generated token (bin/fm-betterstack-arm.sh),
# there is nothing to generate here - the secret lives in 1Password and
# bin/fm-clickstack-recv.sh fetches it fresh on every daemon start. That means
# this wrapper cannot cheaply tell whether the already-running daemon holds a
# stale credential (a captain-rotated Twilio Auth Token, a changed destination
# number, or an edited webhook URL), so it ALWAYS restarts rather than doing a
# plain (re)arm - the daemon is armed rarely (once per session, not per wake),
# so the extra restart is cheap and the correctness is worth it.
#
# It delegates the actual daemon lifecycle (singleton lock, ready-file confirm
# loop) to bin/fm-clickstack-arm.sh - one implementation of "start a listener
# and verify it bound", not a second one. Run this as its own standalone
# background task, exactly like bin/fm-clickstack-arm.sh.
#
# Subcommands:
#   (none)      (re-)arm the shared receiver, always via --restart
#   --show-url  print the route's path and the configured public webhook URL
#               (never the Twilio secrets); paste the URL into the Twilio
#               console's RCS/Messaging Service webhook configuration
#
# Inert by default: with no config/captain-msg.env gate, both subcommands exit
# 0 silently. With the gate present but incomplete (see cmsg_require_config),
# both subcommands fail loudly rather than arming a half-configured route.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-captain-msg-lib.sh
. "$SCRIPT_DIR/fm-captain-msg-lib.sh"

ARM="$SCRIPT_DIR/fm-clickstack-arm.sh"

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --show-url) mode=show-url ;;
  *) echo "usage: $(basename "$0") [--show-url]" >&2; exit 2 ;;
esac

# Inert unless opted in.
cmsg_enabled || exit 0

if ! cmsg_require_config; then
  echo "captain-msg webhook: FAILED - config/captain-msg.env is incomplete" >&2
  exit 1
fi

if [ "$mode" = show-url ]; then
  echo "captain-msg webhook: path=$(cmsg_path) url=$CAPTAIN_MSG_WEBHOOK_URL"
  exit 0
fi

"$ARM" --restart
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "captain-msg webhook: FAILED - could not confirm the shared receiver is listening" >&2
  exit "$rc"
fi

echo "captain-msg webhook: ready path=$(cmsg_path) - run '$(basename "$0") --show-url' for the webhook URL to paste into the Twilio console"
