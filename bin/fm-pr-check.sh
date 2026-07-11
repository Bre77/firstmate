#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's poll by writing
# state/<id>.check.sh, which prints "merged" iff the PR is merged (the
# watcher's check contract: output = wake firstmate, silence = keep sleeping),
# and otherwise execs bin/fm-pr-activity-poll.sh to surface new PR comments and
# reviews from anyone since a durable watermark (state/<id>.pr-activity-seen;
# see that script's header for the full contract). Merge takes precedence in
# the same poll: once merged, the shim reports "merged" and skips the activity
# poll entirely.
#
# The watermark is created here, set to "now", the first time a task arms, so
# a freshly-armed check never floods the wake with the PR's pre-arm history.
# Re-running this script (e.g. to update pr_head) regenerates state/<id>.check.sh
# so an existing task upgrades to the activity poll on next arm, but never
# resets an already-created watermark - a task's activity-poll progress
# survives every re-arm. An already-armed merge-only check.sh from before this
# watermark existed keeps working untouched until this script re-arms it.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

mkdir -p "$STATE"
ACTIVITY_SEEN="$STATE/$ID.pr-activity-seen"
[ -f "$ACTIVITY_SEEN" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$ACTIVITY_SEEN"

cat > "$STATE/$ID.check.sh" <<EOF
export FM_HOME=$(printf '%q' "$FM_HOME")
export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
if [ "\$state" = "MERGED" ]; then
  echo "merged"
else
  $(printf '%q' "$FM_ROOT/bin/fm-pr-activity-poll.sh") $(printf '%q' "$ID") $(printf '%q' "$URL")
fi
EOF
echo "armed: state/$ID.check.sh polls $URL"
