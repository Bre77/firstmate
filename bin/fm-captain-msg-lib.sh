#!/usr/bin/env bash
# Shared config resolution, path helpers, and the speech contract for the
# captain messaging channel over Twilio RCS for Business (fork-only firstmate
# feature; never upstreamed).
#
# The captain's Android runs Google Messages (RCS-capable) and his Tesla reads
# the phone's default messaging app aloud and takes dictated replies - that
# in-car experience is the whole point, so every outbound message must be safe
# to have read aloud by a car or headset. See docs/captain-messaging.md for the
# full contract (authority, speech rules, setup, config schema) - this file only
# implements it.
#
# This file is sourced, never executed. Callers set FM_ROOT/FM_HOME/STATE/CONFIG
# first (as the ClickStack/BetterStack libs do), then source this file. It defines:
#   cmsg_env_file            - path to the gitignored config/captain-msg.env gate
#   cmsg_enabled              - 0 iff the gate file exists (the presence gate)
#   cmsg_env_get <key> <file> - read one KEY=VALUE from a .env-style file
#   cmsg_load_config          - resolve CAPTAIN_MSG_* (env wins over the gate file)
#   cmsg_require_config       - cmsg_load_config, then fail loudly (stderr + return
#                                1) naming every required key left unset
#   cmsg_inbox_dir            - state/captain-msg-inbox
#   cmsg_path                 - fixed URL path the inbound route answers on
#   cmsg_speech_check <text>  - the speech contract; see below
#
# Twilio RCS for Business has NO SMS fallback without a phone number, and this
# sender ("Teslemetry") has none by design (see docs/captain-messaging.md), so a
# delivery failure must surface loudly - callers must treat cmsg_require_config
# and every send failure as a hard error, never a silent skip.
#
# The gate file mirrors config/clickstack-webhook.env and config/betterstack-webhook.env
# in being gitignored, local, opt-in state, but unlike those two every setting
# here has NO safe default for the required keys: an empty or absent gate file
# means the feature is off, and a present-but-incomplete gate file is a
# misconfiguration that must be reported, not silently patched over.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset". Same contract as cshook_env_get.
cmsg_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

cmsg_env_file() {
  printf '%s/captain-msg.env' "${CONFIG:-$FM_HOME/config}"
}

# The presence gate: the feature is off unless the gitignored gate file exists.
cmsg_enabled() {
  [ -f "$(cmsg_env_file)" ]
}

cmsg_inbox_dir() { printf '%s/captain-msg-inbox' "${STATE:-$FM_HOME/state}"; }
cmsg_path()      { printf '/captain-msg'; }

# Resolve CAPTAIN_MSG_DESTINATION, CAPTAIN_MSG_ACCOUNT_SID,
# CAPTAIN_MSG_MESSAGING_SERVICE_SID, CAPTAIN_MSG_FROM_ADDRESS, CAPTAIN_MSG_WEBHOOK_URL,
# CAPTAIN_MSG_OP_VAULT, CAPTAIN_MSG_OP_ITEM, CAPTAIN_MSG_OP_AUTHTOKEN_ITEM. An
# explicit environment variable always wins over the gate file, mainly for
# tests. Every value is non-secret (SIDs, an RCS channel address, a public URL,
# and 1Password item/vault NAMES, never the secrets themselves) - see
# docs/captain-messaging.md "Config schema".
#
# A Twilio account can address an RCS sender either through a Messaging
# Service's sender pool (CAPTAIN_MSG_MESSAGING_SERVICE_SID, Twilio picks the
# channel) or directly by channel address (CAPTAIN_MSG_FROM_ADDRESS, e.g.
# "rcs:teslemetry_fwz8vdzw_agent" - no Messaging Service needed, and none
# exists on every account). Exactly one is required; cmsg_require_config
# enforces that.
cmsg_load_config() {
  local file raw
  file=$(cmsg_env_file)

  if [ -n "${CAPTAIN_MSG_DESTINATION+x}" ]; then raw=${CAPTAIN_MSG_DESTINATION-}; else raw=$(cmsg_env_get CAPTAIN_MSG_DESTINATION "$file"); fi
  CAPTAIN_MSG_DESTINATION=$raw

  if [ -n "${CAPTAIN_MSG_ACCOUNT_SID+x}" ]; then raw=${CAPTAIN_MSG_ACCOUNT_SID-}; else raw=$(cmsg_env_get CAPTAIN_MSG_ACCOUNT_SID "$file"); fi
  CAPTAIN_MSG_ACCOUNT_SID=$raw

  if [ -n "${CAPTAIN_MSG_MESSAGING_SERVICE_SID+x}" ]; then raw=${CAPTAIN_MSG_MESSAGING_SERVICE_SID-}; else raw=$(cmsg_env_get CAPTAIN_MSG_MESSAGING_SERVICE_SID "$file"); fi
  CAPTAIN_MSG_MESSAGING_SERVICE_SID=$raw

  if [ -n "${CAPTAIN_MSG_FROM_ADDRESS+x}" ]; then raw=${CAPTAIN_MSG_FROM_ADDRESS-}; else raw=$(cmsg_env_get CAPTAIN_MSG_FROM_ADDRESS "$file"); fi
  CAPTAIN_MSG_FROM_ADDRESS=$raw

  if [ -n "${CAPTAIN_MSG_WEBHOOK_URL+x}" ]; then raw=${CAPTAIN_MSG_WEBHOOK_URL-}; else raw=$(cmsg_env_get CAPTAIN_MSG_WEBHOOK_URL "$file"); fi
  [ -n "$raw" ] || raw="https://fm.ba.id.au/captain-msg"
  CAPTAIN_MSG_WEBHOOK_URL=$raw

  if [ -n "${CAPTAIN_MSG_OP_VAULT+x}" ]; then raw=${CAPTAIN_MSG_OP_VAULT-}; else raw=$(cmsg_env_get CAPTAIN_MSG_OP_VAULT "$file"); fi
  [ -n "$raw" ] || raw="CLI"
  CAPTAIN_MSG_OP_VAULT=$raw

  if [ -n "${CAPTAIN_MSG_OP_ITEM+x}" ]; then raw=${CAPTAIN_MSG_OP_ITEM-}; else raw=$(cmsg_env_get CAPTAIN_MSG_OP_ITEM "$file"); fi
  [ -n "$raw" ] || raw="Twilio API key"
  CAPTAIN_MSG_OP_ITEM=$raw

  if [ -n "${CAPTAIN_MSG_OP_AUTHTOKEN_ITEM+x}" ]; then raw=${CAPTAIN_MSG_OP_AUTHTOKEN_ITEM-}; else raw=$(cmsg_env_get CAPTAIN_MSG_OP_AUTHTOKEN_ITEM "$file"); fi
  [ -n "$raw" ] || raw="Twilio Auth token"
  CAPTAIN_MSG_OP_AUTHTOKEN_ITEM=$raw

  # shellcheck disable=SC2034 # Read by callers after sourcing.
  : "$CAPTAIN_MSG_DESTINATION" "$CAPTAIN_MSG_ACCOUNT_SID" "$CAPTAIN_MSG_MESSAGING_SERVICE_SID" \
    "$CAPTAIN_MSG_FROM_ADDRESS" "$CAPTAIN_MSG_WEBHOOK_URL" "$CAPTAIN_MSG_OP_VAULT" \
    "$CAPTAIN_MSG_OP_ITEM" "$CAPTAIN_MSG_OP_AUTHTOKEN_ITEM"
}

# cmsg_load_config, then fail loudly (stderr + return 1) if any key with no safe
# default is unset - a present gate file with missing required keys is a
# misconfiguration, not "feature off". Destination and account SID are always
# required; exactly one of MESSAGING_SERVICE_SID/FROM_ADDRESS must be set (see
# cmsg_load_config for why both exist).
cmsg_require_config() {
  cmsg_load_config
  local missing=""
  [ -n "$CAPTAIN_MSG_DESTINATION" ] || missing="$missing CAPTAIN_MSG_DESTINATION"
  [ -n "$CAPTAIN_MSG_ACCOUNT_SID" ] || missing="$missing CAPTAIN_MSG_ACCOUNT_SID"
  if [ -n "$missing" ]; then
    echo "captain-msg: config/captain-msg.env is missing required key(s):$missing" >&2
    return 1
  fi
  if [ -z "$CAPTAIN_MSG_MESSAGING_SERVICE_SID" ] && [ -z "$CAPTAIN_MSG_FROM_ADDRESS" ]; then
    echo "captain-msg: config/captain-msg.env must set exactly one of CAPTAIN_MSG_MESSAGING_SERVICE_SID or CAPTAIN_MSG_FROM_ADDRESS" >&2
    return 1
  fi
  if [ -n "$CAPTAIN_MSG_MESSAGING_SERVICE_SID" ] && [ -n "$CAPTAIN_MSG_FROM_ADDRESS" ]; then
    echo "captain-msg: config/captain-msg.env must set only one of CAPTAIN_MSG_MESSAGING_SERVICE_SID or CAPTAIN_MSG_FROM_ADDRESS, not both" >&2
    return 1
  fi
}

# Fetch the Twilio Account Auth Token from 1Password (item
# CAPTAIN_MSG_OP_AUTHTOKEN_ITEM, field "credential"). This is a DIFFERENT
# secret from the Restricted API Key used for outbound sends: Twilio always
# signs inbound webhook requests with the Account Auth Token, never an API key
# secret, so the receiver needs its own credential lookup. Prints the token to
# stdout and nothing else; op's own stderr goes nowhere secret-bearing. Callers
# must not log stdout on failure - the return code plus stderr already say
# enough. Requires OP_SERVICE_ACCOUNT_TOKEN and op on PATH.
cmsg_fetch_auth_token() {
  local out rc=0
  out=$(op item get "$CAPTAIN_MSG_OP_AUTHTOKEN_ITEM" --vault "$CAPTAIN_MSG_OP_VAULT" --fields credential --reveal 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    echo "captain-msg: could not read the Twilio Account Auth Token from 1Password (item '$CAPTAIN_MSG_OP_AUTHTOKEN_ITEM', vault $CAPTAIN_MSG_OP_VAULT)" >&2
    return 1
  fi
  printf '%s' "$out"
}

# The speech contract (docs/captain-messaging.md "Speech contract"): the car and
# headsets read every outbound message aloud, so it must be plain, short,
# link-free text. Prints the rejection reason to stderr and returns 1 on the
# first violation found; returns 0 (silently) for an accepted message.
cmsg_speech_check() {
  local text=$1
  if [ -z "${text//[[:space:]]/}" ]; then
    echo "captain-msg: message is empty" >&2
    return 1
  fi
  if [ "${#text}" -gt 300 ]; then
    echo "captain-msg: message is ${#text} chars, over the 300-char speech limit" >&2
    return 1
  fi
  if printf '%s' "$text" | grep -qEi '(https?://|www\.)'; then
    echo "captain-msg: message contains a URL, which cannot be read aloud" >&2
    return 1
  fi
  if printf '%s' "$text" | grep -qF '```'; then
    echo "captain-msg: message contains a code fence" >&2
    return 1
  fi
  if printf '%s' "$text" | grep -qE '[`*_#]' || printf '%s' "$text" | grep -qF '[' || printf '%s' "$text" | grep -qF ']'; then
    echo "captain-msg: message contains markdown formatting characters (\` * _ # [ ])" >&2
    return 1
  fi
  # Portable (GNU/BSD) check for anything outside plain printable ASCII plus
  # tab/newline: octal escapes in tr, not a regex engine, so this behaves
  # identically on Linux and stock macOS. Control characters and raw non-ASCII
  # cannot be spoken sensibly by the car or a headset.
  if [ -n "$(printf '%s' "$text" | LC_ALL=C tr -d '\11\12\40-\176')" ]; then
    echo "captain-msg: message contains control characters or non-ASCII text" >&2
    return 1
  fi
}
