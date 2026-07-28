#!/usr/bin/env bash
# Send one message to the captain over Twilio RCS for Business (fork-only
# firstmate feature; never upstreamed). The captain's Tesla reads his phone's
# default messaging app (Google Messages, RCS-capable) aloud and takes dictated
# replies - that in-car experience is the whole point, so every message this
# tool sends must be safe to have read aloud. See docs/captain-messaging.md for
# the full contract (authority, speech rules, setup, config schema).
#
# Usage:
#   fm-captain-msg.sh "<message>"
#
# Contract:
#   - Off (one-line refusal, exit 1) unless config/captain-msg.env is present
#     AND fully configured (see fm-captain-msg-lib.sh cmsg_require_config).
#   - Destination and sender are entirely config-driven; this tool accepts no
#     destination argument and can never send anywhere else.
#   - The message must pass the speech contract (fm-captain-msg-lib.sh
#     cmsg_speech_check): plain text, no URLs, no markdown, no code fences,
#     <=300 chars.
#   - Sends via the Twilio Messaging Service named in
#     CAPTAIN_MSG_MESSAGING_SERVICE_SID, whose sender pool holds only the RCS
#     Business sender - there is NO phone number and therefore NO automatic SMS
#     fallback. A rejected or failed send is always a loud, nonzero-exit error;
#     never swallowed.
#   - Outbound REST auth uses a Twilio Restricted API Key (SID in the
#     1Password item's "username" field, secret in "credential"), never the
#     Account Auth Token - see docs/captain-messaging.md "Setup" for why the two
#     Twilio secrets are kept apart.
#   - Secrets are read from 1Password at call time and never touch disk, stdout,
#     or stderr, and never appear in curl's argv: they travel only in shell
#     variables and reach curl through a config file on stdin (--config -), so
#     `ps` never shows them. Requires OP_SERVICE_ACCOUNT_TOKEN in the
#     environment so `op` can authenticate non-interactively.
#
# Requires: op, curl, jq on PATH.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-captain-msg-lib.sh
. "$SCRIPT_DIR/fm-captain-msg-lib.sh"

usage() {
  awk '/^# Usage:/{p=1} p{if($0 !~ /^#/)exit; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ $# -gt 0 ] || { echo "error: message is required" >&2; usage; exit 1; }
MESSAGE="$*"

# The presence gate: off, with a single-line refusal, unless the captain has
# opted in. This is not an error - it is the expected state for every home that
# has not set up captain messaging.
if ! cmsg_enabled; then
  echo "captain-msg: off (no config/captain-msg.env) - see docs/captain-messaging.md to set up" >&2
  exit 1
fi

cmsg_require_config
cmsg_speech_check "$MESSAGE"

command -v op >/dev/null 2>&1 || { echo "error: op (1Password CLI) not found on PATH" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "error: curl not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found on PATH" >&2; exit 1; }
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || {
  echo "error: OP_SERVICE_ACCOUNT_TOKEN is not set; source your 1Password service-account token before running this script" >&2
  exit 1
}

# Reads one field's value to stdout; op's own stderr (never the secret, since a
# failed read reveals nothing) goes to a scratch file so a failure's message can
# name exactly which field could not be read. Mirrors fm-notify-captain.sh.
fetch_field() {
  local item=$1 field=$2 out rc=0 errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-captain-msg-op.XXXXXX")
  out=$(op item get "$item" --vault "$CAPTAIN_MSG_OP_VAULT" --fields "$field" --reveal 2>"$errfile") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: 1Password field '$field' on item $item (vault $CAPTAIN_MSG_OP_VAULT) could not be read: $(tr -s '\n' ' ' < "$errfile")" >&2
    rm -f "$errfile"
    exit "$rc"
  fi
  rm -f "$errfile"
  if [ -z "$out" ]; then
    echo "error: 1Password field '$field' on item $item (vault $CAPTAIN_MSG_OP_VAULT) is empty" >&2
    exit 1
  fi
  printf '%s' "$out"
}

API_KEY_SID=$(fetch_field "$CAPTAIN_MSG_OP_ITEM" username)
API_KEY_SECRET=$(fetch_field "$CAPTAIN_MSG_OP_ITEM" credential)

RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-captain-msg-resp.XXXXXX")
trap 'rm -f "$RESP_FILE"' EXIT

# Escape a value for a curl config file's quoted-string syntax.
config_escape() {
  local value=${1//\\/\\\\}
  printf '%s' "${value//\"/\\\"}"
}

url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

BODY="To=$(url_encode "$CAPTAIN_MSG_DESTINATION")&MessagingServiceSid=$(url_encode "$CAPTAIN_MSG_MESSAGING_SERVICE_SID")&Body=$(url_encode "$MESSAGE")"
API_URL="https://api.twilio.com/2010-04-01/Accounts/${CAPTAIN_MSG_ACCOUNT_SID}/Messages.json"

HTTP_CODE=$(printf 'url = "%s"\nuser = "%s:%s"\ndata-raw = "%s"\n' \
    "$API_URL" "$(config_escape "$API_KEY_SID")" "$(config_escape "$API_KEY_SECRET")" "$(config_escape "$BODY")" \
    | curl -sS --max-time 15 -X POST -o "$RESP_FILE" -w '%{http_code}' --config -) || {
  echo "error: curl failed to reach the Twilio API" >&2
  exit 1
}

case "$HTTP_CODE" in
  2??) ;;
  *)
    errors=$(jq -r '(.message // "unknown error") + (if .code then " (code " + (.code|tostring) + ")" else "" end)' "$RESP_FILE" 2>/dev/null || true)
    echo "error: Twilio API returned HTTP $HTTP_CODE: ${errors:-$(tr -s '\n' ' ' < "$RESP_FILE" | cut -c1-300)}" >&2
    echo "error: RCS has no SMS fallback for this sender - the captain did NOT receive this message" >&2
    exit 1
    ;;
esac

MESSAGE_SID=$(jq -r '.sid // empty' "$RESP_FILE")
MESSAGE_STATUS=$(jq -r '.status // empty' "$RESP_FILE")
if [ -z "$MESSAGE_SID" ]; then
  echo "error: Twilio accepted the request but returned no message sid" >&2
  exit 1
fi

echo "sent: sid=$MESSAGE_SID status=$MESSAGE_STATUS"
