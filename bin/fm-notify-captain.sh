#!/usr/bin/env bash
# Page the captain's phone through Better Stack on-call - the "last hop"
# channel from the captain-alert-channel-b3 investigation (fork-only firstmate
# feature; never upstreamed).
#
# Each page opens a Better Stack incident, which stays open until it is
# acknowledged in the app or resolved. A caller that pages must resolve once
# the emergency is over, so every send prints the incident id and
# `--resolve <id>` closes it.
#
# Tier maps to the incident's notification channels:
#   urgent    -> critical push notification, which ignores the phone's mute
#                switch and Do Not Disturb; no phone call
#   emergency -> the same critical push plus a phone call to the on-call
#                number, plus escalation to the whole on-call team if nobody
#                acknowledges within FM_NOTIFY_TEAM_WAIT seconds
#
# Better Stack has no per-incident repeat control: an unbounded
# repeat-until-acknowledged cadence lives on an escalation policy
# (repeat_count/repeat_delay), not on the incident payload, and this account
# has no escalation policy. The emergency tier therefore escalates once,
# loudly, rather than forever.
#
# The title must be sent as the incident's `name`. Better Stack titles an
# incident that has no `name` "API request", identically for every page, so
# `name` is always populated - from --title, or from a tier-derived default.
#
# Secrets (the Better Stack API token) and the requester email the incidents
# API requires are read from 1Password at call time and never touch disk,
# stdout, or stderr, and never appear in curl's argv: they live only in shell
# variables and reach curl through a config file on stdin (--config -), so
# `ps` never shows them. Reads item "BetterStack API Token" in vault "CLI":
# field "username" for the requester email, field "credential" for the API
# token. Requires OP_SERVICE_ACCOUNT_TOKEN in the environment so `op` can
# authenticate non-interactively (source it from your shell profile per
# existing fleet practice).
#
# Usage:
#   fm-notify-captain.sh --tier <urgent|emergency> [--title <text>] [--dry-run] <message>
#   fm-notify-captain.sh --resolve <incident-id>
#
# Env overrides (emergency tier only):
#   FM_NOTIFY_TEAM_WAIT  seconds before an unacknowledged incident escalates
#                        to the entire on-call team (default 300)
#
# Requires: op, curl, jq on PATH.
set -eu

API_BASE="https://uptime.betterstack.com"
INCIDENTS_PATH="/api/v3/incidents"
OP_ITEM="BetterStack API Token"
OP_VAULT="CLI"

usage() {
  awk '/^# Usage:/{p=1} p{if($0 !~ /^#/)exit; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" >&2
}

TIER=""
TITLE=""
RESOLVE_ID=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER=${2:?--tier needs a value}; shift 2 ;;
    --title) TITLE=${2:?--title needs a value}; shift 2 ;;
    --resolve) RESOLVE_ID=${2:?--resolve needs an incident id}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown argument: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

if [ -n "$RESOLVE_ID" ]; then
  [ -z "$TIER" ] || { echo "error: --resolve cannot be combined with --tier" >&2; usage; exit 1; }
  [ $# -eq 0 ] || { echo "error: --resolve takes no message argument" >&2; usage; exit 1; }
  case "$RESOLVE_ID" in
    ''|*[!0-9]*) echo "error: --resolve needs a numeric Better Stack incident id (got: $RESOLVE_ID)" >&2; exit 1 ;;
  esac
else
  [ $# -gt 0 ] || { echo "error: message is required" >&2; usage; exit 1; }
  MESSAGE="$*"

  case "$TIER" in
    urgent) CALL=false ;;
    emergency) CALL=true ;;
    "") echo "error: --tier is required (urgent|emergency)" >&2; usage; exit 1 ;;
    *) echo "error: --tier must be 'urgent' or 'emergency' (got: $TIER)" >&2; usage; exit 1 ;;
  esac

  # Never empty: an incident with no name reaches the phone titled "API request".
  [ -n "$TITLE" ] || TITLE="Firstmate $TIER"

  TEAM_WAIT=${FM_NOTIFY_TEAM_WAIT:-300}
  if [ "$TIER" = emergency ]; then
    case "$TEAM_WAIT" in
      ''|*[!0-9]*) echo "error: FM_NOTIFY_TEAM_WAIT must be a positive integer (got: $TEAM_WAIT)" >&2; exit 1 ;;
    esac
    [ "$TEAM_WAIT" -gt 0 ] || { echo "error: FM_NOTIFY_TEAM_WAIT must be a positive integer (got: $TEAM_WAIT)" >&2; exit 1; }
  fi
fi

if "$DRY_RUN"; then
  if [ -n "$RESOLVE_ID" ]; then
    echo "dry-run: would POST to $API_BASE$INCIDENTS_PATH/$RESOLVE_ID/resolve"
    echo "  token=<REDACTED>"
  else
    echo "dry-run: would POST to $API_BASE$INCIDENTS_PATH"
    echo "  tier=$TIER push=true critical_alert=true call=$CALL"
    if [ "$TIER" = emergency ]; then
      echo "  team_wait=$TEAM_WAIT"
    fi
    echo "  title=$TITLE"
    echo "  message=$MESSAGE"
    echo "  requester_email=<REDACTED> token=<REDACTED>"
  fi
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

# Resolving an incident needs no requester, so do not make it fail on a field
# only a new page reads.
if [ -z "$RESOLVE_ID" ]; then
  REQUESTER_EMAIL=$(fetch_field username)
fi
API_TOKEN=$(fetch_field credential)

RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-notify-captain-resp.XXXXXX")
trap 'rm -f "$RESP_FILE"' EXIT

# Escape a value for a curl config file's quoted-string syntax.
config_escape() {
  local value=${1//\\/\\\\}
  printf '%s' "${value//\"/\\\"}"
}

# POST <path> <json-body>, printing curl's HTTP status code. The token and the
# body travel in a config file on stdin, so neither reaches curl's argv.
api_post() {
  local path=$1 body=$2
  printf 'url = "%s%s"\nheader = "authorization: Bearer %s"\nheader = "content-type: application/json"\ndata-raw = "%s"\n' \
    "$API_BASE" "$path" "$(config_escape "$API_TOKEN")" "$(config_escape "$body")" \
    | curl -sS --max-time 15 -X POST -o "$RESP_FILE" -w '%{http_code}' --config -
}

# Print the API's own complaint for a failed call, without dumping a whole page.
api_error_detail() {
  local errors
  errors=$(jq -c '.errors // empty' "$RESP_FILE" 2>/dev/null || true)
  if [ -n "$errors" ]; then
    printf ' errors=%s' "$errors"
  else
    printf ' body=%s' "$(tr -s '\n' ' ' < "$RESP_FILE" | cut -c1-300)"
  fi
}

if [ -n "$RESOLVE_ID" ]; then
  HTTP_CODE=$(api_post "$INCIDENTS_PATH/$RESOLVE_ID/resolve" '{}') || {
    echo "error: curl failed to reach the Better Stack API" >&2
    exit 1
  }
  case "$HTTP_CODE" in
    2??) ;;
    *) echo "error: Better Stack API returned HTTP $HTTP_CODE$(api_error_detail)" >&2; exit 1 ;;
  esac
  echo "resolved: incident=$RESOLVE_ID"
  exit 0
fi

# jq -a keeps the body ASCII-only, so a multi-byte message cannot depend on the
# config file's encoding.
BODY=$(jq -acn \
  --arg name "$TITLE" \
  --arg summary "$MESSAGE" \
  --arg requester "$REQUESTER_EMAIL" \
  --arg tier "$TIER" \
  --argjson call "$CALL" \
  --argjson team_wait "$([ "$TIER" = emergency ] && printf '%s' "$TEAM_WAIT" || printf 'null')" \
  '{
     name: $name,
     summary: $summary,
     requester_email: $requester,
     push: true,
     critical_alert: true,
     call: $call,
     sms: false,
     email: false,
     metadata: {source: "firstmate", tier: $tier},
   }
   + (if $team_wait == null then {} else {team_wait: $team_wait} end)')

HTTP_CODE=$(api_post "$INCIDENTS_PATH" "$BODY") || {
  echo "error: curl failed to reach the Better Stack API" >&2
  exit 1
}

case "$HTTP_CODE" in
  2??) ;;
  *) echo "error: Better Stack API returned HTTP $HTTP_CODE$(api_error_detail)" >&2; exit 1 ;;
esac

INCIDENT_ID=$(jq -r '.data.id // empty' "$RESP_FILE")
if [ -z "$INCIDENT_ID" ]; then
  echo "error: Better Stack accepted the page but returned no incident id, so it cannot be resolved later" >&2
  exit 1
fi

echo "paged: tier=$TIER incident=$INCIDENT_ID"
echo "resolve with: $(basename "${BASH_SOURCE[0]}") --resolve $INCIDENT_ID"
