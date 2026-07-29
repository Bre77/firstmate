#!/usr/bin/env bash
# One check-cycle scan of the captain messaging inbound-reply inbox (fork-only
# firstmate feature). See docs/captain-messaging.md "Inbound route" for the
# full contract this implements.
#
# Inert by default: a HARD no-op (exit 0, no output) unless captain messaging is
# opted in via config/captain-msg.env. This is the body of the watcher check
# shim state/captain-msg-watch.check.sh.
#
# Two payload shapes can land in the inbox, both keyed by MessageSid so a
# Twilio redelivery overwrites its own file:
#   - {"received_at":..., "params": {...}} - already validated. Written either
#     by bin/fm-clickstack-listener.py's own /captain-msg route (the
#     direct-webhook path, still valid for a home that owns its public URL) or
#     by THIS script after successfully validating the shape below.
#   - {"url":..., "signature":..., "body":...} - relayed verbatim by the
#     alert-router (Teslemetry/tools PR 26), which holds no Twilio Account Auth
#     Token and validates nothing. This script validates the signature (via
#     fm-twilio-sig-verify.py, sharing fm_twilio_sig.py's one HMAC
#     implementation with the listener) and the From number, THEN normalizes a
#     valid payload into the first shape in place so every downstream consumer
#     (the captain-msg-response skill, this script's own pending scan) only
#     ever has to understand one trusted shape. An invalid payload is moved to
#     state/captain-msg-inbox/quarantine/ with a reason sidecar - never
#     silently dropped and never counted as a trusted pending reply.
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

# quarantine_payload <file> <reason>: move an unvalidated payload out of the
# top-level scan and record why, loudly - printed to OUT (this check's output
# is what wakes firstmate; stderr is discarded by the watcher's check capture).
QUAR=$(cmsg_quarantine_dir)
OUT=""
quarantine_payload() {
  local f=$1 reason=$2 name
  name=$(basename "$f")
  mkdir -p "$QUAR" 2>/dev/null || { OUT="$OUT
captain-msg-quarantine: could not create quarantine dir for $name: $reason"; return; }
  if mv -f "$f" "$QUAR/$name" 2>/dev/null; then
    printf '%s\n' "$reason" > "$QUAR/$name.reason" 2>/dev/null || true
    OUT="$OUT
captain-msg-quarantine 1 invalid payload (state/captain-msg-inbox/quarantine/): $name - $reason"
  else
    OUT="$OUT
captain-msg-quarantine: could not quarantine $name: $reason"
  fi
}

# validate_and_normalize <file>: for a router-relayed {"url","signature","body"}
# payload, validate the Twilio signature and From number, then atomically
# rewrite the file in place as {"received_at","params"} on success, or
# quarantine it on failure. auth_token/destination are resolved once by the
# caller, not per file.
validate_and_normalize() {
  local f=$1 auth_token=$2 destination=$3 name url sig body_file form from tmp rc
  name=$(basename "$f")
  url=$(jq -r '.url // empty' "$f" 2>/dev/null)
  sig=$(jq -r '.signature // empty' "$f" 2>/dev/null)
  body_file=$(mktemp "$INBOX/.tmp.body.XXXXXX") || { quarantine_payload "$f" "could not allocate a temp file to validate"; return; }
  # printf, not a redirected `jq -r`, so jq's own trailing newline never joins
  # the raw body - that would corrupt the last form field's value and always
  # fail signature validation, since Twilio's real POST body carries no
  # trailing newline for us to reproduce.
  printf '%s' "$(jq -r '.body // empty' "$f" 2>/dev/null)" > "$body_file"

  form=$(printf '%s' "$auth_token" | python3 "$SCRIPT_DIR/fm-twilio-sig-verify.py" --url "$url" --signature "$sig" --body-file "$body_file" 2>/dev/null)
  rc=$?
  rm -f "$body_file"
  if [ "$rc" -ne 0 ]; then
    quarantine_payload "$f" "invalid or missing X-Twilio-Signature for the relayed url/body"
    return
  fi

  from=$(printf '%s' "$form" | jq -r '.From // empty')
  from=${from#rcs:}
  if [ -z "$destination" ] || [ "$from" != "$destination" ]; then
    quarantine_payload "$f" "From ($from) does not match the configured captain number"
    return
  fi

  tmp=$(mktemp "$INBOX/.tmp.norm.XXXXXX") || { quarantine_payload "$f" "could not allocate a temp file to normalize"; return; }
  if ! jq -n --arg ra "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson params "$form" \
      '{received_at: $ra, params: $params}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    quarantine_payload "$f" "could not build the normalized envelope"
    return
  fi
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; quarantine_payload "$f" "could not persist the normalized envelope"; return; }
}

# --- pass 1: classify, then validate/normalize any router-relayed (raw)
# payloads. A file matching neither known shape is quarantined immediately as
# malformed - never counted as pending, never left silently ambiguous.
raw_files=()
for f in "$INBOX"/*.json; do
  [ -f "$f" ] || continue
  if grep -q '"params"[[:space:]]*:' "$f" 2>/dev/null; then
    continue  # already trusted; picked up by pass 2
  elif grep -q '"body"[[:space:]]*:' "$f" 2>/dev/null; then
    raw_files+=("$f")
  else
    quarantine_payload "$f" "unrecognized envelope shape (neither params nor body)"
  fi
done

if [ "${#raw_files[@]}" -gt 0 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    OUT="$OUT
captain-msg: cannot validate ${#raw_files[@]} router-relayed payload(s) - jq not found on PATH"
  elif ! command -v python3 >/dev/null 2>&1; then
    OUT="$OUT
captain-msg: cannot validate ${#raw_files[@]} router-relayed payload(s) - python3 not found on PATH"
  else
    cmsg_load_config
    destination=$CAPTAIN_MSG_DESTINATION
    if [ -z "$destination" ]; then
      OUT="$OUT
captain-msg: cannot validate ${#raw_files[@]} router-relayed payload(s) - config/captain-msg.env is incomplete (no CAPTAIN_MSG_DESTINATION)"
    else
      auth_token=$(cmsg_fetch_auth_token 2>/dev/null)
      if [ -z "$auth_token" ]; then
        OUT="$OUT
captain-msg: cannot validate ${#raw_files[@]} router-relayed payload(s) - could not fetch the Twilio Account Auth Token from 1Password"
      else
        for f in "${raw_files[@]}"; do
          validate_and_normalize "$f" "$auth_token" "$destination"
        done
      fi
    fi
  fi
fi

# --- pass 2: scan for pending, already-trusted ("params"-shaped) payloads -
# only, so a raw payload that could not be validated this cycle (e.g. the
# 1Password fetch above failed) is never reported as a trusted pending reply.
# Top-level *.json only; handled payloads move into processed/, invalid ones
# into quarantine/ (subdirs this glob does not descend into).
count=0
names=""
for f in "$INBOX"/*.json; do
  [ -f "$f" ] || continue
  grep -q '"params"[[:space:]]*:' "$f" 2>/dev/null || continue
  count=$((count + 1))
  if [ "$count" -le 5 ]; then
    names="$names $(basename "$f")"
  fi
done

if [ "$count" -gt 0 ]; then
  names=${names# }
  if [ "$count" -gt 5 ]; then
    names="$names (+$((count - 5)) more)"
  fi
  OUT="$OUT
captain-msg $count pending (state/captain-msg-inbox/): $names"
fi

OUT=${OUT#$'\n'}
[ -z "$OUT" ] || printf '%s\n' "$OUT"
