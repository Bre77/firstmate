#!/usr/bin/env bash
# Behavior tests for the fork-only ClickStack webhook receiver: the inbox poll
# shim (fm-clickstack-poll.sh), the listener daemon (fm-clickstack-listener.py via
# fm-clickstack-recv.sh), and bootstrap's config-gate activation.
#
# The feature must be INERT by default (no gate -> the poll is a hard no-op and
# bootstrap writes/prints nothing) and additive when on (a single check shim,
# idempotent). It must never touch the watcher backbone: its own process, its own
# lock, no writes to the watcher lock or beacon. Alerts must reach firstmate only
# through the EXISTING durable wake queue, surfaced by the real watcher.
#
# Live-server tests bind an ephemeral loopback port (retried) and drive it with a
# real curl, so the HTTP path, secret checks, idempotency, and the singleton are
# exercised end to end. curl and python3 are the real host tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# Make the real python3 and curl resolvable regardless of install location.
for tool in python3 curl; do
  d=$(command -v "$tool" 2>/dev/null) && d=$(dirname "$d") || d=
  [ -n "$d" ] && BASE_PATH="$d:$BASE_PATH"
done
TMP_ROOT=$(fm_test_tmproot fm-clickstack-tests)

# A realistic ClickStack alert webhook body.
SAMPLE_ALERT='{"alertId":"AL-1001","title":"High error rate on payment-svc","severity":"critical","state":"firing","source":"clickstack","threshold":0.05,"value":0.12,"labels":{"service":"payment-svc","env":"prod"}}'

cs_alive() { kill -0 "$1" 2>/dev/null; }

RECV_PIDS=()
cs_cleanup() {
  local pid
  for pid in "${RECV_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  fm_test_cleanup
}
trap cs_cleanup EXIT

# cs_start_receiver <home> <secret>: write a gate with an ephemeral port, start
# the receiver in the background, wait for it to bind. Echoes "<pid> <port>".
# Retries a few ephemeral ports so a busy port never flakes the suite.
cs_start_receiver() {
  local home=$1 secret=${2:-} port pid ready
  mkdir -p "$home/state" "$home/config"
  ready="$home/state/.clickstack-recv.ready"
  for _ in 1 2 3 4 5; do
    port=$(( 20000 + (RANDOM % 20000) ))
    {
      printf 'CLICKSTACK_WEBHOOK_PORT=%s\n' "$port"
      [ -n "$secret" ] && printf 'CLICKSTACK_WEBHOOK_SECRET=%s\n' "$secret"
    } > "$home/config/clickstack-webhook.env"
    rm -f "$ready"
    PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-clickstack-recv.sh" serve \
      >"$home/recv.out" 2>&1 &
    pid=$!
    local i=0
    while [ "$i" -lt 40 ]; do
      [ -f "$ready" ] && { RECV_PIDS+=("$pid"); printf '%s %s\n' "$pid" "$port"; return 0; }
      cs_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fail "receiver never bound a port after retries"$'\n'"$(cat "$home/recv.out" 2>/dev/null)"
}

cs_stop_receiver() {
  local pid=$1
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 30 ] && cs_alive "$pid"; do sleep 0.1; i=$((i + 1)); done
}

# --- inert-by-default (the presence gate) -----------------------------------

test_poll_inert_without_gate() {
  local home out rc
  home="$TMP_ROOT/poll-off"; mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-gate exit"
  [ -z "$out" ] || fail "poll must be silent without a gate (got: $out)"
  # An inbox with a payload must STILL be silent when the gate is absent.
  mkdir -p "$home/state/clickstack-inbox"
  printf '%s' "$SAMPLE_ALERT" > "$home/state/clickstack-inbox/alert-x.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-gate-with-inbox exit"
  [ -z "$out" ] || fail "poll must stay inert without a gate even with inbox files (got: $out)"
  pass "poll is a hard no-op without the config gate"
}

test_recv_and_arm_inert_without_gate() {
  local home out rc
  home="$TMP_ROOT/recv-off"; mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-recv.sh" serve); rc=$?
  expect_code 0 "$rc" "recv no-gate exit"
  [ -z "$out" ] || fail "recv serve must be silent without a gate (got: $out)"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-arm.sh"); rc=$?
  expect_code 0 "$rc" "arm no-gate exit"
  [ -z "$out" ] || fail "arm must be silent without a gate (got: $out)"
  assert_absent "$home/state/.clickstack-recv.lock" "no gate -> no receiver lock"
  pass "recv and arm are inert without the config gate"
}

# --- poll surfacing ---------------------------------------------------------

test_poll_surfaces_pending_inbox() {
  local home out
  home="$TMP_ROOT/poll-surface"; mkdir -p "$home/state/clickstack-inbox" "$home/config"
  : > "$home/config/clickstack-webhook.env"
  # Empty inbox -> silent.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-poll.sh")
  [ -z "$out" ] || fail "poll must be silent with an empty inbox (got: $out)"
  # A pending payload -> one compact line naming it.
  printf '%s' "$SAMPLE_ALERT" > "$home/state/clickstack-inbox/alert-AL-1001.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-poll.sh")
  assert_contains "$out" "clickstack-alert 1 pending" "poll must surface a pending alert"
  assert_contains "$out" "alert-AL-1001.json" "poll must name the pending file"
  # Handled payloads live under processed/ and must NOT be surfaced.
  mkdir -p "$home/state/clickstack-inbox/processed"
  mv "$home/state/clickstack-inbox/alert-AL-1001.json" "$home/state/clickstack-inbox/processed/"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-clickstack-poll.sh")
  [ -z "$out" ] || fail "poll must ignore processed/ payloads (got: $out)"
  pass "poll surfaces only unhandled top-level inbox payloads"
}

# --- live HTTP: accept, persist, secret, idempotency, singleton -------------

test_listener_accepts_and_persists() {
  local home info pid port code inbox
  home="$TMP_ROOT/recv-accept"
  info=$(cs_start_receiver "$home"); pid=${info%% *}; port=${info##* }
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' -d "$SAMPLE_ALERT" \
    "http://127.0.0.1:$port/webhook")
  expect_code 202 "$code" "accepted webhook HTTP code"
  inbox="$home/state/clickstack-inbox"
  [ -f "$inbox/alert-AL-1001.json" ] || fail "webhook must persist a stably-named inbox payload"
  assert_grep "payment-svc" "$inbox/alert-AL-1001.json" "inbox payload must be the raw body"
  # It must NOT have touched the watcher backbone.
  assert_absent "$home/state/.last-watcher-beat" "receiver must not touch the watcher beacon"
  assert_absent "$home/state/.watch.lock" "receiver must not touch the watcher lock"
  cs_stop_receiver "$pid"
  pass "listener accepts a POST, persists the raw payload, and leaves the watcher untouched"
}

test_secret_rejected() {
  local home info pid port code inbox
  home="$TMP_ROOT/recv-secret"
  info=$(cs_start_receiver "$home" "topsecret"); pid=${info%% *}; port=${info##* }
  inbox="$home/state/clickstack-inbox"
  # Missing secret -> 401, nothing persisted.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_ALERT" \
    "http://127.0.0.1:$port/webhook")
  expect_code 401 "$code" "missing-secret HTTP code"
  # Wrong secret -> 401.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-ClickStack-Secret: nope' -d "$SAMPLE_ALERT" "http://127.0.0.1:$port/webhook")
  expect_code 401 "$code" "wrong-secret HTTP code"
  [ -z "$(ls -A "$inbox" 2>/dev/null)" ] || fail "a rejected webhook must not persist anything"
  # Correct secret in the header -> 202.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-ClickStack-Secret: topsecret' -d "$SAMPLE_ALERT" "http://127.0.0.1:$port/webhook")
  expect_code 202 "$code" "header-secret HTTP code"
  # Correct secret as a query parameter -> 202 (proxies that cannot add headers).
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -d "$SAMPLE_ALERT" "http://127.0.0.1:$port/webhook?secret=topsecret")
  expect_code 202 "$code" "query-secret HTTP code"
  cs_stop_receiver "$pid"
  pass "listener rejects a missing or wrong shared secret and accepts the right one"
}

test_idempotent_redelivery() {
  local home info pid port n
  home="$TMP_ROOT/recv-idem"
  info=$(cs_start_receiver "$home"); pid=${info%% *}; port=${info##* }
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_ALERT" "http://127.0.0.1:$port/webhook"
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_ALERT" "http://127.0.0.1:$port/webhook"
  PATH="$BASE_PATH" curl -s -o /dev/null -d "$SAMPLE_ALERT" "http://127.0.0.1:$port/webhook"
  n=$(find "$home/state/clickstack-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "a redelivered alert (same id) must not pile up duplicates (found $n)"
  # A payload with no id gets a unique name, so distinct alerts never collide.
  PATH="$BASE_PATH" curl -s -o /dev/null -d '{"title":"no id here","state":"firing"}' \
    "http://127.0.0.1:$port/webhook"
  PATH="$BASE_PATH" curl -s -o /dev/null -d '{"title":"another no id","state":"firing"}' \
    "http://127.0.0.1:$port/webhook"
  n=$(find "$home/state/clickstack-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "3" ] || fail "id-less alerts must each persist distinctly (found $n)"
  cs_stop_receiver "$pid"
  pass "same-id redelivery is idempotent; id-less alerts stay distinct"
}

test_singleton() {
  local home info pid port out rc
  home="$TMP_ROOT/recv-singleton"
  info=$(cs_start_receiver "$home"); pid=${info%% *}; port=${info##* }
  # A second serve for the same home must no-op cleanly, not double-bind.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-clickstack-recv.sh" serve); rc=$?
  expect_code 0 "$rc" "second serve exit"
  assert_contains "$out" "already running" "a second receiver must report the singleton"
  # The original is still the one serving.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_ALERT" \
    "http://127.0.0.1:$port/webhook")
  expect_code 202 "$code" "original receiver still serving"
  # status reports it running; after stop it reports not running.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-clickstack-recv.sh" status)
  assert_contains "$out" "running pid=$pid" "status must report the live receiver"
  cs_stop_receiver "$pid"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-clickstack-recv.sh" status); rc=$?
  expect_code 1 "$rc" "status exit when not running"
  assert_contains "$out" "not running" "status must report a stopped receiver"
  pass "receiver is a clean home-scoped singleton"
}

# --- the real end-to-end wake: port -> inbox -> durable queue via the watcher -

test_wake_lands_through_watcher() {
  local home info pid port out rc
  home="$TMP_ROOT/e2e-wake"; mkdir -p "$home"
  # Bootstrap generates the real check shim from the gate (also proves activation).
  # Start the receiver first so the gate exists; then bootstrap wires the shim.
  info=$(cs_start_receiver "$home"); pid=${info%% *}; port=${info##* }
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/clickstack-watch.check.sh" "bootstrap must arm the inbox poll shim"
  # Deliver a realistic alert over HTTP.
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d "$SAMPLE_ALERT" \
    "http://127.0.0.1:$port/webhook")
  expect_code 202 "$code" "e2e webhook accepted"
  # Run the REAL watcher; with checks due immediately it must run the shim, see the
  # inbox payload, enqueue a durable check wake, and exit.
  out=$(FM_HOME="$home" FM_CHECK_INTERVAL=0 FM_POLL=1 timeout 20 \
    "$ROOT/bin/fm-watch.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "watcher exit on the clickstack check wake"
  assert_contains "$out" "clickstack-alert" "the watcher must surface the alert as a check wake"
  # The wake is durable: it is in the queue and drains as a check record.
  assert_present "$home/state/.wake-queue" "the wake must be enqueued durably"
  assert_grep "clickstack-alert" "$home/state/.wake-queue" "the durable queue must hold the alert wake"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$out" "$(printf '\tcheck\t')" "drain must surface a check-kind wake"
  assert_contains "$out" "clickstack-alert" "drain must surface the clickstack alert wake"
  cs_stop_receiver "$pid"
  pass "a delivered webhook lands as a durable check wake through the real watcher"
}

# --- bootstrap activation contract ------------------------------------------

test_bootstrap_inert_without_gate() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "CLICKSTACK:" "bootstrap must say nothing about the receiver without a gate"
  assert_absent "$home/state/clickstack-watch.check.sh" "no gate -> no poll shim"
  pass "bootstrap is inert without the config gate (non-users unaffected)"
}

test_bootstrap_activates_and_opts_out() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; mkdir -p "$home/config"
  : > "$home/config/clickstack-webhook.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CLICKSTACK: webhook receiver on" "bootstrap must announce the receiver"
  assert_present "$home/state/clickstack-watch.check.sh" "bootstrap must drop the poll shim"
  [ -x "$home/state/clickstack-watch.check.sh" ] || fail "the poll shim must be executable"
  assert_grep "fm-clickstack-poll.sh" "$home/state/clickstack-watch.check.sh" \
    "the shim must exec the poll script"
  # Idempotent.
  sum1=$(shasum < "$home/state/clickstack-watch.check.sh")
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(shasum < "$home/state/clickstack-watch.check.sh")
  [ "$sum1" = "$sum2" ] || fail "bootstrap receiver setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'clickstack-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the poll shim (found $n)"
  # Opt out: remove the gate -> next bootstrap removes the shim and says off.
  rm -f "$home/config/clickstack-webhook.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CLICKSTACK: webhook receiver off" "opt-out must report cleanup"
  assert_absent "$home/state/clickstack-watch.check.sh" "opt-out must remove the poll shim"
  pass "bootstrap activates from the gate idempotently and cleans up on opt-out"
}

test_poll_inert_without_gate
test_recv_and_arm_inert_without_gate
test_poll_surfaces_pending_inbox
test_listener_accepts_and_persists
test_secret_rejected
test_idempotent_redelivery
test_singleton
test_wake_lands_through_watcher
test_bootstrap_inert_without_gate
test_bootstrap_activates_and_opts_out
