#!/usr/bin/env bash
# Behavior tests for the fork-only BetterStack status-page webhook route: the
# inbox poll shim (fm-betterstack-poll.sh), the shared listener's /betterstack
# path (fm-clickstack-listener.py via fm-clickstack-recv.sh), token generation
# (fm-betterstack-arm.sh / bshook_ensure_token), and bootstrap's config-gate
# activation.
#
# This route shares the ClickStack receiver's single HTTP listener process and
# port (docs/betterstack-webhook.md), so this suite also exercises the
# dual-gate independence: BetterStack alone must start the shared daemon and
# 404 the ClickStack path, ClickStack alone must 404 the BetterStack path, and
# both together must both work on the same port.
#
# The feature must be INERT by default (no gate -> the poll is a hard no-op,
# the route 404s, and bootstrap writes/prints nothing) and additive when on. It
# must never touch the watcher backbone. Events must reach firstmate only
# through the EXISTING durable wake queue, surfaced by the real watcher.
#
# Live-server tests bind an ephemeral loopback port (retried) and drive it with
# a real curl, so the HTTP path, token checks, idempotency, and the shared
# daemon are exercised end to end. curl and python3 are the real host tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
for tool in python3 curl; do
  d=$(command -v "$tool" 2>/dev/null) && d=$(dirname "$d") || d=
  [ -n "$d" ] && BASE_PATH="$d:$BASE_PATH"
done
TMP_ROOT=$(fm_test_tmproot fm-betterstack-tests)

# A realistic BetterStack incident webhook body (first delivery: one update).
SAMPLE_INCIDENT_V1='{"event_type":"incident","page":{"id":12345,"status_indicator":"downtime","status_description":"Some services are down"},"incident":{"id":98765,"name":"Database connection issues","incident_updates":[{"id":1,"status":"investigating","body":"We are investigating"}]}}'
# A second delivery for the SAME incident with an additional update - must
# overwrite the same inbox file (see docs/betterstack-webhook.md).
SAMPLE_INCIDENT_V2='{"event_type":"incident","page":{"id":12345,"status_indicator":"operational","status_description":"All systems operational"},"incident":{"id":98765,"name":"Database connection issues","incident_updates":[{"id":1,"status":"investigating","body":"We are investigating"},{"id":2,"status":"resolved","body":"Fixed"}]}}'
# A distinct incident.
SAMPLE_INCIDENT_OTHER='{"event_type":"incident","page":{"id":12345,"status_indicator":"degraded","status_description":"Partial outage"},"incident":{"id":11111,"name":"API latency spike","incident_updates":[{"id":1,"status":"investigating"}]}}'
# A component_update event.
SAMPLE_COMPONENT='{"event_type":"component_update","page":{"id":12345,"status_indicator":"degraded"},"component_update":{"id":555,"old_status":"operational","new_status":"degraded"},"component":{"id":42,"name":"API"}}'

bs_alive() { kill -0 "$1" 2>/dev/null; }

RECV_PIDS=()
bs_cleanup() {
  local pid
  for pid in "${RECV_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  fm_test_cleanup
}
trap bs_cleanup EXIT

# bs_start_receiver <home> [cs_gate] [bs_gate] [bs_token]: write the requested
# gate file(s) with an ephemeral port (always via a CLICKSTACK_WEBHOOK_PORT env
# override, even when the ClickStack gate itself is not written, so a
# BetterStack-only daemon still picks a random free port instead of the fixed
# 8092 default - the documented "port stays owned by the ClickStack config or
# its defaults" behavior, exercised here via the env-var escape hatch that
# fm-clickstack-lib.sh reserves for tests). Starts the receiver in the
# background, waits for it to bind. Echoes "<pid> <port>".
bs_start_receiver() {
  local home=$1 cs_gate=${2:-0} bs_gate=${3:-0} bs_token=${4:-} port pid ready
  mkdir -p "$home/state" "$home/config"
  ready="$home/state/.clickstack-recv.ready"
  if [ "$cs_gate" = 1 ]; then : > "$home/config/clickstack-webhook.env"; fi
  if [ "$bs_gate" = 1 ]; then
    if [ -n "$bs_token" ]; then
      printf 'BETTERSTACK_WEBHOOK_TOKEN=%s\n' "$bs_token" > "$home/config/betterstack-webhook.env"
    else
      : > "$home/config/betterstack-webhook.env"
    fi
  fi
  for _ in 1 2 3 4 5; do
    port=$(( 20000 + (RANDOM % 20000) ))
    rm -f "$ready"
    PATH="$BASE_PATH" FM_HOME="$home" CLICKSTACK_WEBHOOK_PORT="$port" \
      "$ROOT/bin/fm-clickstack-recv.sh" serve >"$home/recv.out" 2>&1 &
    pid=$!
    local i=0
    while [ "$i" -lt 40 ]; do
      [ -f "$ready" ] && { RECV_PIDS+=("$pid"); printf '%s %s\n' "$pid" "$port"; return 0; }
      bs_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fail "receiver never bound a port after retries"$'\n'"$(cat "$home/recv.out" 2>/dev/null)"
}

bs_stop_receiver() {
  local pid=$1
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 30 ] && bs_alive "$pid"; do sleep 0.1; i=$((i + 1)); done
}

# --- inert-by-default (the presence gate) -----------------------------------

test_poll_inert_without_gate() {
  local home out rc
  home="$TMP_ROOT/poll-off"; mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-betterstack-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-gate exit"
  [ -z "$out" ] || fail "poll must be silent without a gate (got: $out)"
  mkdir -p "$home/state/betterstack-inbox"
  printf '%s' "$SAMPLE_INCIDENT_V1" > "$home/state/betterstack-inbox/event-x.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-betterstack-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-gate-with-inbox exit"
  [ -z "$out" ] || fail "poll must stay inert without a gate even with inbox files (got: $out)"
  pass "poll is a hard no-op without the config gate"
}

test_recv_and_arm_inert_without_either_gate() {
  local home out rc
  home="$TMP_ROOT/recv-off"; mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-recv.sh" serve); rc=$?
  expect_code 0 "$rc" "recv no-gate exit"
  [ -z "$out" ] || fail "recv serve must be silent with neither gate (got: $out)"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-arm.sh"); rc=$?
  expect_code 0 "$rc" "clickstack arm no-gate exit"
  [ -z "$out" ] || fail "clickstack arm must be silent with neither gate (got: $out)"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-betterstack-arm.sh"); rc=$?
  expect_code 0 "$rc" "betterstack arm no-gate exit"
  [ -z "$out" ] || fail "betterstack arm must be silent without its gate (got: $out)"
  assert_absent "$home/state/.clickstack-recv.lock" "no gate -> no receiver lock"
  pass "recv and both arm wrappers are inert without either config gate"
}

# --- poll surfacing ---------------------------------------------------------

test_poll_surfaces_pending_inbox() {
  local home out
  home="$TMP_ROOT/poll-surface"; mkdir -p "$home/state/betterstack-inbox" "$home/config"
  : > "$home/config/betterstack-webhook.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-betterstack-poll.sh")
  [ -z "$out" ] || fail "poll must be silent with an empty inbox (got: $out)"
  printf '%s' "$SAMPLE_INCIDENT_V1" > "$home/state/betterstack-inbox/event-incident-98765.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-betterstack-poll.sh")
  assert_contains "$out" "betterstack-alert 1 pending" "poll must surface a pending event"
  assert_contains "$out" "event-incident-98765.json" "poll must name the pending file"
  mkdir -p "$home/state/betterstack-inbox/processed"
  mv "$home/state/betterstack-inbox/event-incident-98765.json" "$home/state/betterstack-inbox/processed/"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-betterstack-poll.sh")
  [ -z "$out" ] || fail "poll must ignore processed/ payloads (got: $out)"
  pass "poll surfaces only unhandled top-level inbox payloads"
}

# --- shared-daemon dual-gate independence -----------------------------------

test_betterstack_only_starts_daemon_and_disables_clickstack_route() {
  local home info pid port code
  home="$TMP_ROOT/bs-only"
  info=$(bs_start_receiver "$home" 0 1 "tok-bsonly"); pid=${info%% *}; port=${info##* }
  # The ClickStack default path must 404 - its own gate is absent.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/webhook")
  expect_code 404 "$code" "clickstack path with no clickstack gate"
  # The BetterStack route must work.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=tok-bsonly")
  expect_code 202 "$code" "betterstack path with betterstack gate only"
  [ -f "$home/state/betterstack-inbox/event-incident-98765.json" ] || fail "must persist the accepted event"
  n=$(find "$home/state/clickstack-inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "0" ] || fail "a betterstack-only daemon must never accept a clickstack payload (found $n)"
  bs_stop_receiver "$pid"
  pass "a BetterStack-only gate starts the shared daemon and leaves the ClickStack path 404"
}

test_clickstack_only_disables_betterstack_route() {
  local home info pid port code
  home="$TMP_ROOT/cs-only"
  info=$(bs_start_receiver "$home" 1 0); pid=${info%% *}; port=${info##* }
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/webhook")
  expect_code 202 "$code" "clickstack path still works with only the clickstack gate"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=anything")
  expect_code 404 "$code" "betterstack path with no betterstack gate, any token"
  bs_stop_receiver "$pid"
  pass "a ClickStack-only gate leaves the BetterStack route 404 regardless of token"
}

test_both_gates_together() {
  local home info pid port code
  home="$TMP_ROOT/both-gates"
  info=$(bs_start_receiver "$home" 1 1 "tok-both"); pid=${info%% *}; port=${info##* }
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/webhook")
  expect_code 202 "$code" "clickstack path with both gates"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=tok-both")
  expect_code 202 "$code" "betterstack path with both gates"
  # ClickStack's own id-extraction nests "incident" as a known parent object
  # (see fm-clickstack-listener.py _derive_id), so this shared fixture lands as
  # alert-incident-98765.json on the ClickStack side.
  [ -f "$home/state/clickstack-inbox/alert-incident-98765.json" ] || fail "clickstack inbox must persist independently"
  [ -f "$home/state/betterstack-inbox/event-incident-98765.json" ] || fail "betterstack inbox must persist independently"
  bs_stop_receiver "$pid"
  pass "both gates together serve both routes concurrently on the shared port"
}

# --- token checks ------------------------------------------------------------

test_token_rejected() {
  local home info pid port code
  home="$TMP_ROOT/bs-token"
  info=$(bs_start_receiver "$home" 0 1 "topsecret"); pid=${info%% *}; port=${info##* }
  # Missing token -> 401, nothing persisted.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack")
  expect_code 401 "$code" "missing-token HTTP code"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=nope")
  expect_code 401 "$code" "wrong-token HTTP code"
  [ -z "$(ls -A "$home/state/betterstack-inbox" 2>/dev/null)" ] || fail "a rejected webhook must not persist anything"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=topsecret")
  expect_code 202 "$code" "correct-token HTTP code"
  bs_stop_receiver "$pid"
  pass "the route rejects a missing or wrong token and accepts the right one"
}

test_no_token_configured_rejects_all() {
  local home info pid port code
  home="$TMP_ROOT/bs-no-token"
  # Gate present but no token generated yet (arm not yet run): must reject.
  info=$(bs_start_receiver "$home" 0 1 ""); pid=${info%% *}; port=${info##* }
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=")
  expect_code 401 "$code" "no-token-configured with empty supplied token"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=guess")
  expect_code 401 "$code" "no-token-configured with a guessed token"
  bs_stop_receiver "$pid"
  pass "an unconfigured (empty) token rejects every request rather than defaulting open"
}

# --- idempotent redelivery ---------------------------------------------------

test_idempotent_redelivery() {
  local home info pid port n
  home="$TMP_ROOT/bs-idem"
  info=$(bs_start_receiver "$home" 0 1 "tok"); pid=${info%% *}; port=${info##* }
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_INCIDENT_V1" "http://127.0.0.1:$port/betterstack?token=tok"
  n=$(find "$home/state/betterstack-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "first delivery must persist exactly one file (found $n)"
  # A later update to the SAME incident overwrites, per BetterStack's own
  # dedupe-on-id guidance (see docs/betterstack-webhook.md).
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_INCIDENT_V2" "http://127.0.0.1:$port/betterstack?token=tok"
  n=$(find "$home/state/betterstack-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "a same-id update must overwrite, not pile up (found $n)"
  assert_grep '"status":"resolved"' "$home/state/betterstack-inbox/event-incident-98765.json" \
    "the overwritten file must hold the LATEST full update history"
  # A genuinely distinct incident gets its own file.
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_INCIDENT_OTHER" "http://127.0.0.1:$port/betterstack?token=tok"
  n=$(find "$home/state/betterstack-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "2" ] || fail "a distinct incident id must persist separately (found $n)"
  assert_present "$home/state/betterstack-inbox/event-incident-11111.json" "distinct incident id must name its own file"
  # A component_update event dedupes on its own nested id.
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_COMPONENT" "http://127.0.0.1:$port/betterstack?token=tok"
  assert_present "$home/state/betterstack-inbox/event-component_update-555.json" "component_update must dedupe on its own id"
  # A payload with no recognizable id gets a unique name each time.
  PATH="$BASE_PATH" curl -s -o /dev/null -d '{"event_type":"unknown"}' "http://127.0.0.1:$port/betterstack?token=tok"
  PATH="$BASE_PATH" curl -s -o /dev/null -d '{"event_type":"unknown"}' "http://127.0.0.1:$port/betterstack?token=tok"
  n=$(find "$home/state/betterstack-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "5" ] || fail "id-less events must each persist distinctly (found $n)"
  bs_stop_receiver "$pid"
  pass "same-id redelivery (including an in-progress update) is idempotent; distinct/id-less events stay separate"
}

# --- token generation (fm-betterstack-arm.sh / bshook_ensure_token) ---------

test_ensure_token_generates_and_is_idempotent() {
  local home file tok1 tok2
  home="$TMP_ROOT/ensure-token"; mkdir -p "$home/config"
  file="$home/config/betterstack-webhook.env"
  : > "$file"
  bash -c ". '$ROOT/bin/fm-betterstack-lib.sh'; bshook_ensure_token '$file'"
  assert_grep "BETTERSTACK_WEBHOOK_TOKEN=" "$file" "ensure_token must write a token line"
  tok1=$(FM_HOME="$home" bash -c ". '$ROOT/bin/fm-betterstack-lib.sh'; bshook_load_config; printf '%s' \"\$BSHOOK_TOKEN\"")
  [ -n "$tok1" ] || fail "generated token must be non-empty"
  [ "${#tok1}" -ge 32 ] || fail "generated token looks too short to be unguessable (len=${#tok1})"
  # Idempotent: a second call must not change an existing token.
  bash -c ". '$ROOT/bin/fm-betterstack-lib.sh'; bshook_ensure_token '$file'"
  tok2=$(FM_HOME="$home" bash -c ". '$ROOT/bin/fm-betterstack-lib.sh'; bshook_load_config; printf '%s' \"\$BSHOOK_TOKEN\"")
  [ "$tok1" = "$tok2" ] || fail "ensure_token must not rotate an already-present token"
  pass "bshook_ensure_token generates an unguessable token once and is idempotent thereafter"
}

test_arm_show_url_and_no_restart_when_already_healthy() {
  # bin/fm-clickstack-arm.sh blocks on the child once it starts a NEW daemon
  # (by design: it is meant to run as a tracked background task and notify on
  # daemon exit - see its own header). fm-betterstack-arm.sh's plain (no
  # --restart) delegation only avoids that block when a healthy daemon with a
  # token already exists, exactly the case exercised here, mirroring how
  # tests/fm-clickstack.test.sh itself never drives fm-clickstack-arm.sh's
  # blocking start path and instead starts the daemon directly via `recv.sh serve`.
  local home info pid port token out code
  token="pretoken-$$"
  home="$TMP_ROOT/arm-healthy"
  info=$(bs_start_receiver "$home" 0 1 "$token"); pid=${info%% *}; port=${info##* }
  out=$(PATH="$BASE_PATH" FM_HOME="$home" timeout 5 "$ROOT/bin/fm-betterstack-arm.sh" 2>&1)
  assert_contains "$out" "betterstack webhook: ready" "arm must report ready without needing a restart"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-betterstack-arm.sh" --show-url)
  assert_contains "$out" "path=/betterstack" "show-url must name the path"
  assert_contains "$out" "token=$token" "show-url must print the pre-existing token unchanged"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=$token")
  expect_code 202 "$code" "the token surfaced by --show-url must actually work against the live route"
  bs_stop_receiver "$pid"
  pass "fm-betterstack-arm.sh recognizes an already-healthy daemon and skips the restart, --show-url matches"
}

# --- the real end-to-end wake: port -> inbox -> durable queue via the watcher -

test_wake_lands_through_watcher() {
  local home info pid port out rc code
  home="$TMP_ROOT/e2e-wake"; mkdir -p "$home"
  info=$(bs_start_receiver "$home" 0 1 "tok"); pid=${info%% *}; port=${info##* }
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/betterstack-watch.check.sh" "bootstrap must arm the inbox poll shim"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_INCIDENT_V1" \
    "http://127.0.0.1:$port/betterstack?token=tok")
  expect_code 202 "$code" "e2e webhook accepted"
  out=$(FM_HOME="$home" FM_CHECK_INTERVAL=0 FM_POLL=1 timeout 20 \
    "$ROOT/bin/fm-watch.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "watcher exit on the betterstack check wake"
  assert_contains "$out" "betterstack-alert" "the watcher must surface the event as a check wake"
  assert_present "$home/state/.wake-queue" "the wake must be enqueued durably"
  assert_grep "betterstack-alert" "$home/state/.wake-queue" "the durable queue must hold the event wake"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$out" "$(printf '\tcheck\t')" "drain must surface a check-kind wake"
  assert_contains "$out" "betterstack-alert" "drain must surface the betterstack event wake"
  bs_stop_receiver "$pid"
  pass "a delivered webhook lands as a durable check wake through the real watcher"
}

# --- bootstrap activation contract ------------------------------------------

test_bootstrap_inert_without_gate() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "BETTERSTACK:" "bootstrap must say nothing about the route without a gate"
  assert_absent "$home/state/betterstack-watch.check.sh" "no gate -> no poll shim"
  pass "bootstrap is inert without the config gate (non-users unaffected)"
}

test_bootstrap_activates_and_opts_out() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; mkdir -p "$home/config"
  : > "$home/config/betterstack-webhook.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "BETTERSTACK: webhook route on" "bootstrap must announce the route"
  assert_present "$home/state/betterstack-watch.check.sh" "bootstrap must drop the poll shim"
  [ -x "$home/state/betterstack-watch.check.sh" ] || fail "the poll shim must be executable"
  assert_grep "fm-betterstack-poll.sh" "$home/state/betterstack-watch.check.sh" \
    "the shim must exec the poll script"
  sum1=$(shasum < "$home/state/betterstack-watch.check.sh")
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(shasum < "$home/state/betterstack-watch.check.sh")
  [ "$sum1" = "$sum2" ] || fail "bootstrap route setup must be idempotent"
  # Exactly the shim plus its registered watcher check-trust binding (bin/fm-check-register.sh);
  # no other betterstack-watch* artifact should appear.
  n=$(find "$home/state" -maxdepth 1 -name 'betterstack-watch*' | wc -l | tr -d ' ')
  [ "$n" = "2" ] || fail "bootstrap must not duplicate the poll shim (found $n)"
  assert_present "$home/state/betterstack-watch.check-trust" "bootstrap must register the poll shim as a trusted watcher check"
  rm -f "$home/config/betterstack-webhook.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "BETTERSTACK: webhook route off" "opt-out must report cleanup"
  assert_absent "$home/state/betterstack-watch.check.sh" "opt-out must remove the poll shim"
  assert_absent "$home/state/betterstack-watch.check-trust" "opt-out must remove the check-trust binding"
  pass "bootstrap activates from the gate idempotently and cleans up on opt-out"
}

test_poll_inert_without_gate
test_recv_and_arm_inert_without_either_gate
test_poll_surfaces_pending_inbox
test_betterstack_only_starts_daemon_and_disables_clickstack_route
test_clickstack_only_disables_betterstack_route
test_both_gates_together
test_token_rejected
test_no_token_configured_rejects_all
test_idempotent_redelivery
test_ensure_token_generates_and_is_idempotent
test_arm_show_url_and_no_restart_when_already_healthy
test_wake_lands_through_watcher
test_bootstrap_inert_without_gate
test_bootstrap_activates_and_opts_out
