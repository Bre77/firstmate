#!/usr/bin/env bash
# One check-cycle scan of the ClickStack webhook inbox (fork-only firstmate feature).
#
# Inert by default: a HARD no-op (exit 0, no output) unless the receiver is opted
# in via config/clickstack-webhook.env. This script is the body of the watcher
# check shim state/clickstack-watch.check.sh, where the contract is "output =>
# wake firstmate, silence => keep sleeping", so the no-op keeps the watcher
# behaving exactly as today until a user opts in.
#
# When opted in, it prints one compact line iff the receiver has persisted alert
# payloads to state/clickstack-inbox/ that firstmate has not yet cleared. The
# watcher turns that line into a check: wake and enqueues it through the EXISTING
# durable wake queue (fm_wake_append), identical to how the X-mode poll's output
# is enqueued - deliberate reuse of the existing helper, never a parallel queue.
#
# No local "seen" bookkeeping is kept here, mirroring X mode: the inbox file is
# the single source of truth. It re-surfaces every pending payload until
# firstmate's handling clears it (the clickstack-alert-response skill moves each
# handled payload into state/clickstack-inbox/processed/, out of this scan). The
# watcher is not running while firstmate handles a wake and only re-arms once the
# turn is done, so a handled-then-cleared inbox never re-fires.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-clickstack-lib.sh
. "$SCRIPT_DIR/fm-clickstack-lib.sh"

# Hard no-op when the receiver is off: this is what keeps the check shim inert.
cshook_enabled || exit 0

INBOX=$(cshook_inbox_dir)
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
printf 'clickstack-alert %d pending (state/clickstack-inbox/): %s\n' "$count" "$names"
