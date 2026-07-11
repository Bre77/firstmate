#!/usr/bin/env bash
# Send an urgent/emergency push notification to the captain's phone via
# Pushover - the "last hop" channel from the captain-alert-channel-b3
# investigation (fork-only firstmate feature; never upstreamed).
#
# Tier maps straight to Pushover priority:
#   urgent    -> priority 1 (bypasses quiet hours, sounds once)
#   emergency -> priority 2 (Pushover re-sends every `retry` seconds, up to
#                `expire` seconds total, until acknowledged in the Pushover app)
#
# Secrets (the Pushover user key and application token) are read from
# 1Password at call time and never touch disk, stdout, or stderr, and never
# appear in curl's argv: they live only in shell variables and are sent to
# curl over stdin (--data @-), so `ps` never shows them. Reads item
# "Pushover" in vault "CLI": field "username" for the user key, field
# "credential" for the application token. Requires OP_SERVICE_ACCOUNT_TOKEN in
# the environment so `op` can authenticate non-interactively (source it from
# your shell profile per existing fleet practice).
#
# On a priority-2 (emergency) send, prints Pushover's receipt id so a caller
# can later poll it via the receipts API (https://pushover.net/api/receipts) -
# this script does not poll receipts itself.
#
# Usage:
#   fm-notify-captain.sh --tier <urgent|emergency> [--title <text>] [--dry-run] <message>
#
# Env overrides (emergency tier only):
#   FM_NOTIFY_RETRY   seconds between re-alerts, >= 30 (default 30)
#   FM_NOTIFY_EXPIRE  seconds until Pushover stops re-alerting, <= 10800 (default 3600)
#
# Requires: op, curl, jq on PATH.
set -eu

PUSHOVER_URL="https://api.pushover.net/1/messages.json"
OP_ITEM="Pushover"
OP_VAULT="CLI"

usage() {
  awk '/^# Usage:/{p=1} p{if($0 !~ /^#/)exit; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" >&2
}

TIER=""
TITLE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER=${2:?--tier needs a value}; shift 2 ;;
    --title) TITLE=${2:?--title needs a value}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown argument: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

[ $# -gt 0 ] || { echo "error: message is required" >&2; usage; exit 1; }
MESSAGE="$*"

case "$TIER" in
  urgent) PRIORITY=1 ;;
  emergency) PRIORITY=2 ;;
  "") echo "error: --tier is required (urgent|emergency)" >&2; usage; exit 1 ;;
  *) echo "error: --tier must be 'urgent' or 'emergency' (got: $TIER)" >&2; usage; exit 1 ;;
esac

RETRY=${FM_NOTIFY_RETRY:-30}
EXPIRE=${FM_NOTIFY_EXPIRE:-3600}

if [ "$PRIORITY" -eq 2 ]; then
  case "$RETRY" in
    ''|*[!0-9]*) echo "error: FM_NOTIFY_RETRY must be a positive integer (got: $RETRY)" >&2; exit 1 ;;
  esac
  case "$EXPIRE" in
    ''|*[!0-9]*) echo "error: FM_NOTIFY_EXPIRE must be a positive integer (got: $EXPIRE)" >&2; exit 1 ;;
  esac
  [ "$RETRY" -ge 30 ] || { echo "error: FM_NOTIFY_RETRY must be >= 30 seconds per Pushover's API (got: $RETRY)" >&2; exit 1; }
  [ "$EXPIRE" -le 10800 ] || { echo "error: FM_NOTIFY_EXPIRE must be <= 10800 seconds (3h) per Pushover's API (got: $EXPIRE)" >&2; exit 1; }
fi

# Percent-encode one form value. LC_ALL=C makes bash index by byte, so
# multi-byte UTF-8 characters are correctly split and escaped byte-by-byte.
urlencode() {
  local LC_ALL=C
  local string=$1 strlen pos c o encoded=""
  strlen=${#string}
  for (( pos = 0; pos < strlen; pos++ )); do
    c=${string:pos:1}
    case "$c" in
      [-_.~a-zA-Z0-9]) o=$c ;;
      *) printf -v o '%%%02x' "'$c" ;;
    esac
    encoded+=$o
  done
  printf '%s' "$encoded"
}

if "$DRY_RUN"; then
  echo "dry-run: would POST to $PUSHOVER_URL"
  echo "  tier=$TIER priority=$PRIORITY"
  if [ "$PRIORITY" -eq 2 ]; then
    echo "  retry=$RETRY expire=$EXPIRE"
  fi
  echo "  title=${TITLE:-<pushover app default>}"
  echo "  message=$MESSAGE"
  echo "  user=<REDACTED> token=<REDACTED>"
  exit 0
fi

[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || {
  echo "error: OP_SERVICE_ACCOUNT_TOKEN is not set; source your 1Password service-account token before running this script" >&2
  exit 1
}
command -v op >/dev/null 2>&1 || { echo "error: op (1Password CLI) not found on PATH" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "error: curl not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found on PATH" >&2; exit 1; }

# Reads one field's value to stdout; op's own stderr (never the secret, since
# a failed read reveals nothing) goes to a scratch file so a failure's message
# can name exactly which field could not be read.
fetch_field() {
  local field=$1 out rc=0 errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-notify-captain-op.XXXXXX")
  out=$(op item get "$OP_ITEM" --vault "$OP_VAULT" --fields "$field" --reveal 2>"$errfile") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: 1Password field '$field' on item $OP_ITEM (vault $OP_VAULT) could not be read: $(tr -s '\n' ' ' < "$errfile")" >&2
    rm -f "$errfile"
    exit "$rc"
  fi
  rm -f "$errfile"
  if [ -z "$out" ]; then
    echo "error: 1Password field '$field' on item $OP_ITEM (vault $OP_VAULT) is empty" >&2
    exit 1
  fi
  printf '%s' "$out"
}

USER_KEY=$(fetch_field username)
APP_TOKEN=$(fetch_field credential)

BODY="user=$(urlencode "$USER_KEY")&token=$(urlencode "$APP_TOKEN")&message=$(urlencode "$MESSAGE")&priority=$PRIORITY"
if [ -n "$TITLE" ]; then
  BODY="$BODY&title=$(urlencode "$TITLE")"
fi
if [ "$PRIORITY" -eq 2 ]; then
  BODY="$BODY&retry=$RETRY&expire=$EXPIRE"
fi

RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-notify-captain-resp.XXXXXX")
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(printf '%s' "$BODY" | curl -sS --max-time 15 -o "$RESP_FILE" -w '%{http_code}' --data @- "$PUSHOVER_URL") || {
  echo "error: curl failed to reach the Pushover API" >&2
  exit 1
}

case "$HTTP_CODE" in
  2??) ;;
  *)
    ERRORS=$(jq -c '.errors // empty' "$RESP_FILE" 2>/dev/null || true)
    echo "error: Pushover API returned HTTP $HTTP_CODE${ERRORS:+ errors=$ERRORS}" >&2
    exit 1
    ;;
esac

echo "sent: tier=$TIER priority=$PRIORITY"
if [ "$PRIORITY" -eq 2 ]; then
  RECEIPT=$(jq -r '.receipt // empty' "$RESP_FILE")
  if [ -n "$RECEIPT" ]; then
    echo "receipt: $RECEIPT"
  fi
fi
