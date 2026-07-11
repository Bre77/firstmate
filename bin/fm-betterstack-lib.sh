#!/usr/bin/env bash
# Shared config resolution and path helpers for the BetterStack status-page
# webhook route (fork-only firstmate feature).
#
# BetterStack status-page webhook subscriptions cannot deliver a custom auth
# header (see docs/betterstack-webhook.md), so authentication is a single
# unguessable token carried in the URL query string instead of a header, unlike
# the ClickStack receiver's header-or-query secret.
#
# This route SHARES the ClickStack receiver's HTTP listener process and port
# (see docs/clickstack-webhook.md) rather than running a second daemon: the
# captain's reverse proxy forwards the whole host to one port, so a second
# listener on a different port would be unreachable without an out-of-repo
# proxy change. bin/fm-clickstack-recv.sh and bin/fm-clickstack-arm.sh source
# this file alongside fm-clickstack-lib.sh and start the shared daemon when
# EITHER gate is present; fm-clickstack-listener.py dispatches by path.
#
# This file is sourced, never executed. Callers set FM_ROOT/FM_HOME/STATE/CONFIG
# first, then source this library. It defines:
#   bshook_env_file            - path to the gitignored config/betterstack-webhook.env gate
#   bshook_enabled              - 0 iff the gate file exists (the presence gate)
#   bshook_env_get <key> <file> - read one KEY=VALUE from a .env-style file
#   bshook_load_config          - resolve BSHOOK_TOKEN (env wins over the gate file)
#   bshook_path                 - fixed URL path the route answers on ("/betterstack")
#   bshook_inbox_dir            - state/betterstack-inbox
#   bshook_ensure_token <file>  - generate and persist a token into the gate file if absent
#
# The gate file mirrors config/clickstack-webhook.env in being gitignored, local,
# opt-in state. Unlike ClickStack, the token has no safe empty default: with no
# token configured the route rejects every request (see fm-clickstack-listener.py).

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset". Same contract as cshook_env_get.
bshook_env_get() {
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

bshook_env_file() {
  printf '%s/betterstack-webhook.env' "${CONFIG:-$FM_HOME/config}"
}

# The presence gate: the route is off unless the gitignored gate file exists.
bshook_enabled() {
  [ -f "$(bshook_env_file)" ]
}

bshook_path()       { printf '/betterstack'; }
bshook_inbox_dir()  { printf '%s/betterstack-inbox' "${STATE:-$FM_HOME/state}"; }

# Resolve BSHOOK_TOKEN. An explicit environment variable always wins over the
# gate file, mainly for tests. Empty means "not yet generated" - the listener
# must reject every request in that state rather than defaulting open, because
# unlike ClickStack's loopback-and-proxy secret, this route has no other guard.
bshook_load_config() {
  local file raw
  file=$(bshook_env_file)

  if [ -n "${BETTERSTACK_WEBHOOK_TOKEN+x}" ]; then raw=${BETTERSTACK_WEBHOOK_TOKEN-}; else raw=$(bshook_env_get BETTERSTACK_WEBHOOK_TOKEN "$file"); fi
  BSHOOK_TOKEN=$raw

  # shellcheck disable=SC2034 # Read by callers after sourcing.
  : "$BSHOOK_TOKEN"
}

# Generate and persist an unguessable token into the gate file if it does not
# already carry one. Idempotent: a file that already has a non-empty
# BETTERSTACK_WEBHOOK_TOKEN is left untouched. Requires python3 (already a hard
# dependency of this feature) for a CSPRNG-backed urlsafe token.
bshook_ensure_token() {
  local file=$1 existing tmp token
  existing=$(bshook_env_get BETTERSTACK_WEBHOOK_TOKEN "$file")
  [ -n "$existing" ] && return 0

  token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))') || return 1
  [ -n "$token" ] || return 1

  tmp="${file}.tmp.$$"
  if [ -f "$file" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?BETTERSTACK_WEBHOOK_TOKEN=' "$file"; then
    sed -E "s/^([[:space:]]*(export[[:space:]]+)?BETTERSTACK_WEBHOOK_TOKEN=).*/\\1${token}/" "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    if [ -f "$file" ]; then cat "$file" > "$tmp"; else : > "$tmp"; fi
    printf 'BETTERSTACK_WEBHOOK_TOKEN=%s\n' "$token" >> "$tmp"
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}
