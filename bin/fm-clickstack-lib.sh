#!/usr/bin/env bash
# Shared config resolution and path helpers for the ClickStack webhook receiver.
#
# Fork-only feature (Bre77/firstmate): a small localhost HTTP listener that
# accepts ClickStack alert webhooks and wakes firstmate through the EXISTING
# durable wake queue, mirroring the presence-gated, additive, watcher-non-
# interfering model of X mode (see docs/clickstack-webhook.md).
#
# This file is sourced, never executed. Callers set FM_ROOT/FM_HOME/STATE/CONFIG
# first (as fm-x-poll.sh and fm-bootstrap.sh do), then source this library.
# It defines:
#   cshook_env_file            - path to the gitignored config/clickstack-webhook.env gate
#   cshook_enabled             - 0 iff the gate file exists (the presence gate)
#   cshook_env_get <key> <file> - read one KEY=VALUE from a .env-style file
#   cshook_load_config         - resolve CSHOOK_PORT, CSHOOK_BIND, CSHOOK_SECRET,
#                                CSHOOK_SECRET_HEADER (env wins over the gate file)
#   cshook_inbox_dir           - state/clickstack-inbox
#   cshook_lock_dir            - state/.clickstack-recv.lock (receiver singleton)
#   cshook_ready_file          - state/.clickstack-recv.ready (bound-and-listening marker)
#   cshook_seen_dir            - state/.clickstack-seen (per-payload surfaced markers)
#
# The gate file mirrors config/x-mode.env in being gitignored, local, opt-in
# state. Presence alone opts in; every value has a safe default, so an empty gate
# file enables the receiver on 127.0.0.1:8092 with no shared secret.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset". Same contract as fmx_env_get.
cshook_env_get() {
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

cshook_env_file() {
  printf '%s/clickstack-webhook.env' "${CONFIG:-$FM_HOME/config}"
}

# The presence gate: the receiver is off unless the gitignored gate file exists.
cshook_enabled() {
  [ -f "$(cshook_env_file)" ]
}

cshook_inbox_dir()  { printf '%s/clickstack-inbox' "${STATE:-$FM_HOME/state}"; }
cshook_lock_dir()   { printf '%s/.clickstack-recv.lock' "${STATE:-$FM_HOME/state}"; }
cshook_ready_file() { printf '%s/.clickstack-recv.ready' "${STATE:-$FM_HOME/state}"; }
cshook_seen_dir()   { printf '%s/.clickstack-seen' "${STATE:-$FM_HOME/state}"; }

# Resolve receiver settings into CSHOOK_PORT, CSHOOK_BIND, CSHOOK_SECRET, and
# CSHOOK_SECRET_HEADER. An explicit environment variable always wins over the
# gate file. The bind address defaults to loopback because the captain fronts the
# receiver with a reverse proxy; the port defaults to the verified-free 8092.
cshook_load_config() {
  local file raw
  file=$(cshook_env_file)

  if [ -n "${CLICKSTACK_WEBHOOK_PORT+x}" ]; then raw=${CLICKSTACK_WEBHOOK_PORT-}; else raw=$(cshook_env_get CLICKSTACK_WEBHOOK_PORT "$file"); fi
  case "$raw" in ''|*[!0-9]*) raw=8092 ;; esac
  { [ "$raw" -ge 1 ] && [ "$raw" -le 65535 ]; } 2>/dev/null || raw=8092
  CSHOOK_PORT=$raw

  if [ -n "${CLICKSTACK_WEBHOOK_BIND+x}" ]; then raw=${CLICKSTACK_WEBHOOK_BIND-}; else raw=$(cshook_env_get CLICKSTACK_WEBHOOK_BIND "$file"); fi
  [ -n "$raw" ] || raw=127.0.0.1
  CSHOOK_BIND=$raw

  if [ -n "${CLICKSTACK_WEBHOOK_SECRET+x}" ]; then raw=${CLICKSTACK_WEBHOOK_SECRET-}; else raw=$(cshook_env_get CLICKSTACK_WEBHOOK_SECRET "$file"); fi
  CSHOOK_SECRET=$raw

  if [ -n "${CLICKSTACK_WEBHOOK_SECRET_HEADER+x}" ]; then raw=${CLICKSTACK_WEBHOOK_SECRET_HEADER-}; else raw=$(cshook_env_get CLICKSTACK_WEBHOOK_SECRET_HEADER "$file"); fi
  [ -n "$raw" ] || raw=X-ClickStack-Secret
  CSHOOK_SECRET_HEADER=$raw

  # shellcheck disable=SC2034 # All four are read by callers after sourcing.
  : "$CSHOOK_PORT" "$CSHOOK_BIND" "$CSHOOK_SECRET" "$CSHOOK_SECRET_HEADER"
}
