#!/usr/bin/env bash
# Body of the PR-activity half of a task's state/<id>.check.sh. fm-pr-check.sh
# generates a shim that execs this after its merge check finds the PR still
# open (merge takes precedence: once merged, the shim reports "merged" and
# never invokes this, so a landed task stops paying gh api calls).
#
# Surfaces NEW issue comments, inline review comments, and review summaries on
# the tracked PR since a durable per-task watermark, from ANYONE - the
# supervising agent triages who matters (captain feedback on a fleet PR,
# maintainer review on a secondmate's upstream PR, or bot noise to ignore).
# This is deliberately generic: no special-casing of captains or PR authors.
#
# Watermark: state/<id>.pr-activity-seen holds the newest-seen item's UTC ISO
# 8601 timestamp. fm-pr-check.sh creates it set to "now" the first time a task
# arms, so a freshly-armed check never floods the wake with the PR's pre-arm
# history. This script also creates it (and exits silently) if it ever finds
# the file missing, as a defensive fallback with the same no-flood behavior.
# Each poll advances the watermark to the newest timestamp it actually
# surfaced; a poll that finds nothing new leaves it untouched.
#
# Three gh api calls per poll: issue comments and inline review comments both
# take a server-side `since`, cutting response size on a chatty PR; the
# reviews endpoint has no `since` support, so its whole list is fetched and
# filtered client-side by submitted_at. All three are re-filtered client-side
# for strict > watermark regardless of server-side filtering, because `since`
# semantics are inclusive on some endpoints and an inclusive boundary would
# otherwise re-surface the same newest item on every following poll.
#
# Wake-line contract (the watcher's check.sh contract: output wakes firstmate,
# silence keeps it sleeping), one line per new item:
#   pr-comment <task-id> <author> (<kind>): <first ~120 chars, one line>
# kind is one of: comment (issue comment), review-comment (inline diff
# comment), review (a submitted review's summary; body falls back to the
# review state - approved / changes_requested / commented - when empty).
#
# Usage: fm-pr-activity-poll.sh <task-id> <pr-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:?usage: fm-pr-activity-poll.sh <task-id> <pr-url>}
URL=${2:?usage: fm-pr-activity-poll.sh <task-id> <pr-url>}

command -v gh >/dev/null 2>&1 || exit 0

mkdir -p "$STATE" 2>/dev/null || exit 0
WATERMARK_FILE="$STATE/$ID.pr-activity-seen"

if [ ! -f "$WATERMARK_FILE" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$WATERMARK_FILE" 2>/dev/null
  exit 0
fi

WATERMARK=$(tr -d '[:space:]' < "$WATERMARK_FILE" 2>/dev/null)
if [ -z "$WATERMARK" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$WATERMARK_FILE" 2>/dev/null
  exit 0
fi

if [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  NUMBER="${BASH_REMATCH[3]}"
else
  exit 0
fi

# format_line <field-1..4 tsv>: normalize an item's body into one truncated,
# single-line display string. jq's @tsv escapes embedded tabs/newlines/
# backslashes as two-char sequences (never raw bytes), so this only ever
# collapses those escape sequences and real whitespace runs, never re-parses
# an accidentally-split line.
squash_body() {
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed -e 's/\\r/ /g' -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\\\\/\\/g' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +//; s/ +$//'
}

# gh api prints the error body to stdout (not just stderr) on a non-2xx
# response, e.g. a 404 or a rate limit - so a failed call's captured output
# must be discarded on a non-zero exit, never treated as TSV rows.
# --method GET is required: gh api silently switches to POST whenever -f
# parameters are present unless the method is pinned, which would otherwise
# turn this read-only "since" filter into an attempt to CREATE a new comment.
comments=$(gh api "repos/$OWNER/$REPO/issues/$NUMBER/comments" --method GET --paginate \
  -f "since=$WATERMARK" \
  -q ".[] | select(.created_at > \"$WATERMARK\") | [.created_at, (.user.login // \"unknown\"), \"comment\", (.body // \"\")] | @tsv" \
  2>/dev/null) || comments=""

review_comments=$(gh api "repos/$OWNER/$REPO/pulls/$NUMBER/comments" --method GET --paginate \
  -f "since=$WATERMARK" \
  -q ".[] | select(.created_at > \"$WATERMARK\") | [.created_at, (.user.login // \"unknown\"), \"review-comment\", (.body // \"\")] | @tsv" \
  2>/dev/null) || review_comments=""

reviews=$(gh api "repos/$OWNER/$REPO/pulls/$NUMBER/reviews" --method GET --paginate \
  -q ".[] | select(.submitted_at != null and .submitted_at > \"$WATERMARK\") | [.submitted_at, (.user.login // \"unknown\"), \"review\", ((.body // \"\") as \$b | if (\$b | length) > 0 then \$b else (.state // \"\") end)] | @tsv" \
  2>/dev/null) || reviews=""

all=$(printf '%s\n%s\n%s\n' "$comments" "$review_comments" "$reviews" | grep -v '^$')
[ -n "$all" ] || exit 0

sorted=$(printf '%s\n' "$all" | LC_ALL=C sort -t "$(printf '\t')" -k1,1)

newest="$WATERMARK"
while IFS=$'\t' read -r ts author kind body; do
  [ -n "$ts" ] || continue
  display=$(squash_body "$body")
  display="${display:0:120}"
  printf 'pr-comment %s %s (%s): %s\n' "$ID" "$author" "$kind" "$display"
  if [[ "$ts" > "$newest" ]]; then
    newest=$ts
  fi
done <<< "$sorted"

if [ "$newest" != "$WATERMARK" ]; then
  printf '%s\n' "$newest" > "$WATERMARK_FILE"
fi
