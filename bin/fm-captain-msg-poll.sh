#!/usr/bin/env bash
# One check-cycle scan of the captain messaging inbound-reply inbox (fork-only
# firstmate feature). Mirrors bin/fm-betterstack-poll.sh exactly; see its header
# and docs/captain-messaging.md for the full contract this implements.
#
# Inert by default: a HARD no-op (exit 0, no output) unless captain messaging is
# opted in via config/captain-msg.env. This is the body of the watcher check
# shim state/captain-msg-watch.check.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-captain-msg-lib.sh
. "$SCRIPT_DIR/fm-captain-msg-lib.sh"

# Hard no-op when the feature is off: this is what keeps the check shim inert.
cmsg_enabled || exit 0

INBOX=$(cmsg_inbox_dir)
[ -d "$INBOX" ] || exit 0

# Only top-level *.json count as pending; handled payloads are moved into
# processed/ (a subdir the glob does not descend into).
count=0
names=""
for f in "$INBOX"/*.json; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  if [ "$count" -le 5 ]; then
    names="$names $(basename "$f")"
  fi
done

[ "$count" -gt 0 ] || exit 0

names=${names# }
if [ "$count" -gt 5 ]; then
  names="$names (+$((count - 5)) more)"
fi
printf 'captain-msg %d pending (state/captain-msg-inbox/): %s\n' "$count" "$names"
