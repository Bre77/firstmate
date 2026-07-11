#!/usr/bin/env bash
# One check-cycle scan of the BetterStack webhook inbox (fork-only firstmate feature).
#
# Inert by default: a HARD no-op (exit 0, no output) unless the route is opted in
# via config/betterstack-webhook.env. This script is the body of the watcher
# check shim state/betterstack-watch.check.sh, where the contract is "output =>
# wake firstmate, silence => keep sleeping", mirroring bin/fm-clickstack-poll.sh.
#
# When opted in, it prints one compact line iff the shared receiver has persisted
# event payloads to state/betterstack-inbox/ that firstmate has not yet cleared.
# The watcher turns that line into a check: wake and enqueues it through the
# EXISTING durable wake queue (fm_wake_append), identical to the ClickStack poll.
#
# No local "seen" bookkeeping is kept here, mirroring both ClickStack and X mode:
# the inbox file is the single source of truth. It re-surfaces every pending
# payload until firstmate's handling clears it (the betterstack-alert-response
# skill moves each handled payload into state/betterstack-inbox/processed/, out
# of this scan). The watcher is not running while firstmate handles a wake and
# only re-arms once the turn is done, so a handled-then-cleared inbox never re-fires.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-betterstack-lib.sh
. "$SCRIPT_DIR/fm-betterstack-lib.sh"

# Hard no-op when the route is off: this is what keeps the check shim inert.
bshook_enabled || exit 0

INBOX=$(bshook_inbox_dir)
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
printf 'betterstack-alert %d pending (state/betterstack-inbox/): %s\n' "$count" "$names"
