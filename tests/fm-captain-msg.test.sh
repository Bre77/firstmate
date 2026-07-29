#!/usr/bin/env bash
# Behavior tests for the fork-only captain messaging channel over Twilio RCS for
# Business: the speech contract and config resolution (fm-captain-msg-lib.sh),
# the send tool (fm-captain-msg.sh, with op/curl mocked - no live Twilio calls),
# the shared listener's /captain-msg path (fm-clickstack-listener.py via
# fm-clickstack-recv.sh, including real Twilio signature validation), the shared
# signature module (fm_twilio_sig.py) and its standalone verifier CLI
# (fm-twilio-sig-verify.py), the inbox poll shim (fm-captain-msg-poll.sh,
# including its router-relayed-payload validate/normalize/quarantine path), and
# bootstrap's config-gate activation.
#
# The route shares the ClickStack/BetterStack receiver's single HTTP listener
# process and port (docs/captain-messaging.md), so it must stay INERT by default
# (no gate -> the poll is a hard no-op, the route 404s, bootstrap writes/prints
# nothing) and never touch the watcher backbone. Events reach firstmate only
# through the EXISTING durable wake queue, surfaced by the real watcher.
#
# No live Twilio calls anywhere in this suite: op and curl are always
# PATH-shimmed mocks for the send-tool tests, and the signature-validation
# tests exercise our OWN listener over a real loopback socket with a signature
# WE compute locally using the same HMAC-SHA1 algorithm Twilio documents (see
# docs/captain-messaging.md "Verification" for the canonical test vector this
# implementation matches).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
for tool in python3 curl jq; do
  d=$(command -v "$tool" 2>/dev/null) && d=$(dirname "$d") || d=
  [ -n "$d" ] && BASE_PATH="$d:$BASE_PATH"
done
TMP_ROOT=$(fm_test_tmproot fm-captain-msg-tests)

CMSG="$ROOT/bin/fm-captain-msg.sh"
CMSG_LIB="$ROOT/bin/fm-captain-msg-lib.sh"

FAKE_URL="https://example.invalid/captain-msg"
FAKE_AUTH_TOKEN="fake-account-auth-token-12345"
FAKE_DEST="+14158675309"

cm_alive() { kill -0 "$1" 2>/dev/null; }

RECV_PIDS=()
cm_cleanup() {
  local pid
  for pid in "${RECV_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  fm_test_cleanup
}
trap cm_cleanup EXIT

# --- signature helper (mirrors fm-clickstack-listener.py's algorithm) -------

# twilio_sign <url> <token> <key=val> ...: print the base64 HMAC-SHA1 signature
# Twilio would send for this URL/params/token combination.
twilio_sign() {
  local url=$1 token=$2
  shift 2
  python3 -c '
import sys, hmac, hashlib, base64
url, token = sys.argv[1], sys.argv[2]
form = {}
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    form[k] = v
s = url
for k in sorted(form):
    s += k + form[k]
digest = hmac.new(token.encode(), s.encode(), hashlib.sha1).digest()
print(base64.b64encode(digest).decode())
' "$url" "$token" "$@"
}

# --- config gate writer -------------------------------------------------------

FAKE_FROM_ADDRESS="teslemetry_fwz8vdzw_agent"

# write_gate <home> [dest] [account]: direct-channel addressing
# (CAPTAIN_MSG_FROM_ADDRESS), matching the real production account shape (no
# Messaging Service).
write_gate() {
  local home=$1 dest=${2:-$FAKE_DEST} account=${3:-ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx}
  mkdir -p "$home/config"
  {
    printf 'CAPTAIN_MSG_DESTINATION=%s\n' "$dest"
    printf 'CAPTAIN_MSG_ACCOUNT_SID=%s\n' "$account"
    printf 'CAPTAIN_MSG_FROM_ADDRESS=%s\n' "$FAKE_FROM_ADDRESS"
    printf 'CAPTAIN_MSG_WEBHOOK_URL=%s\n' "$FAKE_URL"
  } > "$home/config/captain-msg.env"
}

# write_gate_msid <home> [dest] [account] [mgsvc]: Messaging Service
# addressing, for an account that has one instead.
write_gate_msid() {
  local home=$1 dest=${2:-$FAKE_DEST} account=${3:-ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} \
    mgsvc=${4:-MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx}
  mkdir -p "$home/config"
  {
    printf 'CAPTAIN_MSG_DESTINATION=%s\n' "$dest"
    printf 'CAPTAIN_MSG_ACCOUNT_SID=%s\n' "$account"
    printf 'CAPTAIN_MSG_MESSAGING_SERVICE_SID=%s\n' "$mgsvc"
    printf 'CAPTAIN_MSG_WEBHOOK_URL=%s\n' "$FAKE_URL"
  } > "$home/config/captain-msg.env"
}

# --- op/curl mocks for the send tool (mirrors tests/fm-notify-captain.test.sh) -

write_op_mock() {
  local fakebin=$1
  cat > "$fakebin/op" <<'SH'
#!/usr/bin/env bash
field=""
item=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--fields" ]; then j=$((i + 1)); field="${!j}"; fi
  if [ "$i" = 3 ]; then item="${!i}"; fi
done
case "$field" in
  username) val=${FM_TEST_OP_USERNAME-SKfakeapikeysidfakeapikeysid1234} ;;
  credential)
    if [ "$item" = "Twilio Auth token" ]; then
      val=${FM_TEST_OP_AUTHTOKEN-fake-account-auth-token-12345}
    else
      val=${FM_TEST_OP_CREDENTIAL-fake-api-key-secret-000000000000} ;
    fi ;;
  *) echo "op mock: unexpected --fields value: $field" >&2; exit 1 ;;
esac
case "$val" in
  __MISSING__) echo "[ERROR] '$field' isn't a field in the item." >&2; exit 1 ;;
  __EMPTY__) printf '' ;;
  *) printf '%s' "$val" ;;
esac
SH
  chmod +x "$fakebin/op"
}

write_curl_mock() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-o" ]; then outfile="${args[$((i + 1))]}"; fi
done
if [ -n "${FM_TEST_CURL_ARGV_LOG:-}" ]; then printf '%s\n' "$*" >> "$FM_TEST_CURL_ARGV_LOG"; fi
if [ -n "${FM_TEST_CURL_STDIN_LOG:-}" ]; then cat > "$FM_TEST_CURL_STDIN_LOG"; else cat >/dev/null; fi
printf '%s' "$FM_TEST_CURL_BODY" > "$outfile"
printf '%s' "$FM_TEST_CURL_HTTP_CODE"
SH
  chmod +x "$fakebin/curl"
}

write_tripwire_mock() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
echo "TRIPWIRE: $name should not have been invoked" >&2
exit 99
SH
  chmod +x "$fakebin/$name"
}

new_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin" "$case_dir/state" "$case_dir/config"
  printf '%s\n' "$case_dir"
}

run_cmsg() {
  local home=$1; shift
  OP_SERVICE_ACCOUNT_TOKEN="fake-service-account-token" \
  FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    "$CMSG" "$@"
}

# --- speech contract (fm-captain-msg-lib.sh cmsg_speech_check) --------------

check_speech() {
  bash -c ". '$CMSG_LIB'; cmsg_speech_check \"\$1\"" _ "$1"
}

test_speech_contract_accepts_plain_text() {
  check_speech "All systems nominal. No action needed from you right now." \
    || fail "a normal multi-sentence message should pass the speech contract"
  pass "the speech contract accepts plain multi-sentence text"
}

test_speech_contract_rejects_url() {
  local out rc
  out=$(check_speech "Check https://example.com for details" 2>&1); rc=$?
  expect_code 1 "$rc" "url-rejection exit code"
  assert_contains "$out" "URL" "url-rejection message did not mention URLs"
  out=$(check_speech "See www.example.com" 2>&1); rc=$?
  expect_code 1 "$rc" "www-rejection exit code"
  pass "the speech contract rejects URLs (scheme and www.)"
}

test_speech_contract_rejects_markdown_and_code_fence() {
  local rc
  check_speech "This is *bold* text" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "asterisk should be rejected"
  check_speech "Run \`ls -la\` please" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "backtick should be rejected"
  check_speech $'```\ncode\n```' >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "code fence should be rejected"
  check_speech "See [here](there)" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "markdown link brackets should be rejected"
  pass "the speech contract rejects markdown formatting and code fences"
}

test_speech_contract_rejects_over_length() {
  local long out rc
  long=$(python3 -c "print('a' * 301)")
  out=$(check_speech "$long" 2>&1); rc=$?
  expect_code 1 "$rc" "over-length exit code"
  assert_contains "$out" "300-char" "over-length message did not name the limit"
  pass "the speech contract rejects messages over 300 characters"
}

test_speech_contract_rejects_empty() {
  local rc
  check_speech "" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "empty message should be rejected"
  check_speech "   " >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "whitespace-only message should be rejected"
  pass "the speech contract rejects empty or whitespace-only messages"
}

# --- send tool: presence gate and config -------------------------------------

test_send_refuses_without_gate() {
  local home out rc
  home=$(new_case send-no-gate)
  out=$(run_cmsg "$home" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "send with no gate should be refused"
  assert_contains "$out" "captain-msg: off" "refusal did not explain the channel is off"
  pass "fm-captain-msg.sh refuses with a one-line message when config/captain-msg.env is absent"
}

test_send_refuses_incomplete_config() {
  local home out rc
  home=$(new_case send-incomplete)
  mkdir -p "$home/config"
  : > "$home/config/captain-msg.env"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  out=$(run_cmsg "$home" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "send with incomplete config should be refused"
  assert_contains "$out" "missing required key" "refusal did not name the missing keys"
  assert_contains "$out" "CAPTAIN_MSG_DESTINATION" "refusal did not name CAPTAIN_MSG_DESTINATION"
  pass "fm-captain-msg.sh refuses loudly when the gate file is present but incomplete"
}

test_send_refuses_message_failing_speech_contract() {
  local home out rc
  home=$(new_case send-bad-speech)
  write_gate "$home"
  write_op_mock "$home/fakebin"
  write_tripwire_mock "$home/fakebin" curl
  out=$(run_cmsg "$home" "visit https://example.com now" 2>&1); rc=$?
  expect_code 1 "$rc" "a URL-bearing message should be refused before any send attempt"
  assert_contains "$out" "URL" "refusal did not explain the URL rejection"
  assert_not_contains "$out" "TRIPWIRE" "the speech contract must reject before curl is ever invoked"
  pass "fm-captain-msg.sh enforces the speech contract before attempting to send"
}

test_send_missing_op_token_fails_loud() {
  local home out rc
  home=$(new_case send-no-op-token)
  write_gate "$home"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  out=$(env -u OP_SERVICE_ACCOUNT_TOKEN FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    "$CMSG" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "missing OP_SERVICE_ACCOUNT_TOKEN should be refused"
  assert_contains "$out" "OP_SERVICE_ACCOUNT_TOKEN is not set" "refusal did not name the missing token"
  pass "fm-captain-msg.sh refuses to run without OP_SERVICE_ACCOUNT_TOKEN"
}

test_send_missing_credential_field_names_it() {
  local home out rc
  home=$(new_case send-missing-cred)
  write_gate "$home"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  out=$(FM_TEST_OP_CREDENTIAL=__MISSING__ run_cmsg "$home" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "missing API key secret should be refused"
  assert_contains "$out" "1Password field 'credential'" "refusal did not name the credential field"
  pass "fm-captain-msg.sh names the 1Password field when the API key secret cannot be read"
}

test_send_non_2xx_response_fails_loud_and_warns_no_fallback() {
  local home out rc
  home=$(new_case send-non-2xx)
  write_gate "$home"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  out=$(FM_TEST_CURL_HTTP_CODE=400 \
    FM_TEST_CURL_BODY='{"message":"The From/MessagingServiceSid pair is not valid","code":21606}' \
    run_cmsg "$home" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "a non-2xx Twilio response should be refused"
  assert_contains "$out" "HTTP 400" "refusal did not include the HTTP status"
  assert_contains "$out" "no SMS fallback" "refusal did not warn about the missing SMS fallback"
  pass "fm-captain-msg.sh fails loudly on a rejected send and warns there is no SMS fallback"
}

test_send_success_and_no_secret_in_argv() {
  local home out argv_log stdin_log body
  home=$(new_case send-success)
  write_gate "$home"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  argv_log="$home/curl-argv.log"
  stdin_log="$home/curl-stdin.log"

  out=$(FM_TEST_CURL_HTTP_CODE=201 FM_TEST_CURL_BODY='{"sid":"SMfakemessagesid00000000000000","status":"queued"}' \
    FM_TEST_OP_CREDENTIAL='super-secret-api-key-value' \
    FM_TEST_CURL_ARGV_LOG="$argv_log" FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_cmsg "$home" "All systems nominal, no action needed." 2>&1) \
    || fail "a valid send should succeed"

  assert_contains "$out" "sent: sid=SMfakemessagesid00000000000000 status=queued" "missing sent confirmation"
  assert_no_grep 'super-secret-api-key-value' "$argv_log" "the API key secret leaked into curl's argv"
  assert_grep 'super-secret-api-key-value' "$stdin_log" "the API key secret was not passed through curl's stdin config"
  body=$(sed -n 's/^data-raw = "\(.*\)"$/\1/p' "$stdin_log")
  assert_contains "$body" "Body=All" "the request body did not carry the message text"
  pass "fm-captain-msg.sh sends successfully and keeps the API key secret out of curl's argv"
}

test_send_direct_address_uses_rcs_prefixed_from_and_to() {
  local home out stdin_log body
  home=$(new_case send-direct-address)
  write_gate "$home"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  stdin_log="$home/curl-stdin.log"

  out=$(FM_TEST_CURL_HTTP_CODE=201 FM_TEST_CURL_BODY='{"sid":"SMdirect00000000000000000000000","status":"queued"}' \
    FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_cmsg "$home" "Direct channel addressing check." 2>&1) \
    || fail "a direct-address send should succeed"

  body=$(sed -n 's/^data-raw = "\(.*\)"$/\1/p' "$stdin_log")
  assert_contains "$body" "From=rcs%3A${FAKE_FROM_ADDRESS}" "the direct-address send did not carry a rcs:-prefixed From"
  assert_contains "$body" "To=rcs%3A%2B" "the direct-address send did not carry a rcs:-prefixed To"
  assert_not_contains "$body" "MessagingServiceSid" "a direct-address send must not also carry MessagingServiceSid"
  pass "fm-captain-msg.sh uses rcs:-prefixed From/To when CAPTAIN_MSG_FROM_ADDRESS is configured"
}

test_send_messaging_service_uses_plain_to() {
  local home out stdin_log body
  home=$(new_case send-msid)
  write_gate_msid "$home"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  stdin_log="$home/curl-stdin.log"

  out=$(FM_TEST_CURL_HTTP_CODE=201 FM_TEST_CURL_BODY='{"sid":"SMmsid0000000000000000000000000","status":"queued"}' \
    FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_cmsg "$home" "Messaging Service addressing check." 2>&1) \
    || fail "a Messaging-Service send should succeed"

  body=$(sed -n 's/^data-raw = "\(.*\)"$/\1/p' "$stdin_log")
  assert_contains "$body" "MessagingServiceSid=MG" "the Messaging-Service send did not carry MessagingServiceSid"
  assert_not_contains "$body" "rcs%3A" "a Messaging-Service send must use a plain To, not rcs:-prefixed"
  assert_not_contains "$body" "From=" "a Messaging-Service send must not also carry a direct From"
  pass "fm-captain-msg.sh uses a plain To and MessagingServiceSid when CAPTAIN_MSG_MESSAGING_SERVICE_SID is configured"
}

test_require_config_rejects_neither_addressing_mode() {
  local home out rc
  home=$(new_case cfg-neither-mode); mkdir -p "$home/config"
  {
    printf 'CAPTAIN_MSG_DESTINATION=%s\n' "$FAKE_DEST"
    printf 'CAPTAIN_MSG_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
  } > "$home/config/captain-msg.env"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  out=$(run_cmsg "$home" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "neither addressing mode set should be refused"
  assert_contains "$out" "exactly one of" "refusal did not explain exactly one addressing mode is required"
  pass "fm-captain-msg.sh refuses when neither CAPTAIN_MSG_FROM_ADDRESS nor CAPTAIN_MSG_MESSAGING_SERVICE_SID is set"
}

test_require_config_rejects_both_addressing_modes() {
  local home out rc
  home=$(new_case cfg-both-modes); mkdir -p "$home/config"
  {
    printf 'CAPTAIN_MSG_DESTINATION=%s\n' "$FAKE_DEST"
    printf 'CAPTAIN_MSG_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
    printf 'CAPTAIN_MSG_FROM_ADDRESS=%s\n' "$FAKE_FROM_ADDRESS"
    printf 'CAPTAIN_MSG_MESSAGING_SERVICE_SID=MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
  } > "$home/config/captain-msg.env"
  write_op_mock "$home/fakebin"
  write_curl_mock "$home/fakebin"
  out=$(run_cmsg "$home" "hello captain" 2>&1); rc=$?
  expect_code 1 "$rc" "both addressing modes set should be refused"
  assert_contains "$out" "only one of" "refusal did not explain only one addressing mode is allowed"
  pass "fm-captain-msg.sh refuses when both CAPTAIN_MSG_FROM_ADDRESS and CAPTAIN_MSG_MESSAGING_SERVICE_SID are set"
}

# --- shared listener: /captain-msg signature validation ---------------------

# The listener needs several CMHOOK_* env vars that only fm-clickstack-recv.sh
# resolves (from cshook/bshook/cmsg config plus, for CMHOOK_AUTH_TOKEN, a
# 1Password read). To exercise the real route without any live 1Password call,
# these tests invoke fm-clickstack-listener.py directly with env vars set by
# hand - the same approach, one layer lower, that keeps the daemon's HTTP
# behavior under test without needing the full recv.sh/op chain.
cm_start_listener() {
  local home=$1 auth_token=${2:-$FAKE_AUTH_TOKEN} from=${3:-$FAKE_DEST} port pid ready
  mkdir -p "$home/inbox"
  ready="$home/ready"
  for _ in 1 2 3 4 5; do
    port=$(( 20000 + (RANDOM % 20000) ))
    rm -f "$ready"
    PATH="$BASE_PATH" \
    CSHOOK_BIND=127.0.0.1 CSHOOK_PORT="$port" CSHOOK_ENABLED=0 CSHOOK_INBOX="$home/cs-inbox" CSHOOK_READY="$ready" \
    BSHOOK_ENABLED=0 BSHOOK_INBOX="$home/bs-inbox" \
    CMHOOK_ENABLED=1 CMHOOK_AUTH_TOKEN="$auth_token" CMHOOK_WEBHOOK_URL="$FAKE_URL" CMHOOK_FROM="$from" CMHOOK_INBOX="$home/inbox" \
      python3 "$ROOT/bin/fm-clickstack-listener.py" >"$home/listener.out" 2>&1 &
    pid=$!
    local i=0
    while [ "$i" -lt 40 ]; do
      [ -f "$ready" ] && { RECV_PIDS+=("$pid"); printf '%s %s\n' "$pid" "$port"; return 0; }
      cm_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fail "listener never bound a port after retries"$'\n'"$(cat "$home/listener.out" 2>/dev/null)"
}

cm_stop_listener() {
  local pid=$1
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 30 ] && cm_alive "$pid"; do sleep 0.1; i=$((i + 1)); done
}

test_route_404_when_disabled() {
  local home port pid code
  home="$TMP_ROOT/route-disabled"
  mkdir -p "$home/inbox"
  # Reuse cm_start_listener's port-pick loop but with CMHOOK_ENABLED=0.
  port=$(( 20000 + (RANDOM % 20000) ))
  PATH="$BASE_PATH" \
  CSHOOK_BIND=127.0.0.1 CSHOOK_PORT="$port" CSHOOK_ENABLED=1 CSHOOK_INBOX="$home/cs-inbox" CSHOOK_READY="$home/ready" \
  BSHOOK_ENABLED=0 BSHOOK_INBOX="$home/bs-inbox" \
  CMHOOK_ENABLED=0 CMHOOK_AUTH_TOKEN="" CMHOOK_WEBHOOK_URL="$FAKE_URL" CMHOOK_FROM="" CMHOOK_INBOX="$home/inbox" \
    python3 "$ROOT/bin/fm-clickstack-listener.py" >"$home/listener.out" 2>&1 &
  pid=$!
  local i=0
  while [ "$i" -lt 40 ] && [ ! -f "$home/ready" ]; do cm_alive "$pid" || break; sleep 0.1; i=$((i + 1)); done
  RECV_PIDS+=("$pid")
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -d 'Body=hi' "http://127.0.0.1:$port/captain-msg")
  expect_code 404 "$code" "the route must 404 when its own gate is off, even with ClickStack on"
  cm_stop_listener "$pid"
  pass "the /captain-msg route 404s when captain messaging is disabled"
}

test_valid_signature_accepted_and_persisted() {
  local home info pid port sig code
  home="$TMP_ROOT/sig-valid"
  info=$(cm_start_listener "$home"); pid=${info%% *}; port=${info##* }
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000001" "From=$FAKE_DEST" "To=rcs:agent" "Body=Reply from the road")
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000001" \
    --data-urlencode "From=$FAKE_DEST" --data-urlencode "To=rcs:agent" \
    --data-urlencode "Body=Reply from the road" \
    "http://127.0.0.1:$port/captain-msg")
  expect_code 200 "$code" "a correctly signed request must be accepted"
  assert_present "$home/inbox/message-SM00000000000000000000000000000001.json" "the accepted reply must be persisted under its MessageSid"
  assert_grep '"Body": "Reply from the road"' "$home/inbox/message-SM00000000000000000000000000000001.json" \
    "the persisted envelope must carry the reply body"
  cm_stop_listener "$pid"
  pass "a validly signed request from the configured captain number is accepted and persisted"
}

test_valid_signature_with_rcs_prefixed_from_accepted() {
  # Twilio's real inbound RCS "From" is channel-prefixed ("rcs:+<E.164>"), not
  # the plain number cm_start_listener's CMHOOK_FROM is configured with -
  # confirmed against a live account's message history. This is the real wire
  # shape; test_valid_signature_accepted_and_persisted above covers the
  # already-plain case for completeness.
  local home info pid port sig code from
  home="$TMP_ROOT/sig-valid-rcs-prefix"
  info=$(cm_start_listener "$home"); pid=${info%% *}; port=${info##* }
  from="rcs:$FAKE_DEST"
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000008" "From=$from" "Body=Real wire shape")
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000008" \
    --data-urlencode "From=$from" --data-urlencode "Body=Real wire shape" \
    "http://127.0.0.1:$port/captain-msg")
  expect_code 200 "$code" "a rcs:-prefixed From matching the configured captain number must be accepted"
  assert_present "$home/inbox/message-SM00000000000000000000000000000008.json" "the accepted reply must be persisted"
  cm_stop_listener "$pid"
  pass "an inbound rcs:-prefixed From is accepted after channel-prefix stripping"
}

test_invalid_signature_rejected() {
  local home info pid port code n
  home="$TMP_ROOT/sig-invalid"
  info=$(cm_start_listener "$home"); pid=${info%% *}; port=${info##* }
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Twilio-Signature: totally-wrong-signature" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000002" \
    --data-urlencode "From=$FAKE_DEST" --data-urlencode "Body=forged" \
    "http://127.0.0.1:$port/captain-msg")
  expect_code 403 "$code" "an incorrectly signed request must be rejected"
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    --data-urlencode "MessageSid=SM00000000000000000000000000000003" --data-urlencode "Body=no sig at all" \
    "http://127.0.0.1:$port/captain-msg")
  expect_code 403 "$code" "a request with no signature header at all must be rejected"
  n=$(find "$home/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "0" ] || fail "a rejected request must never persist anything (found $n)"
  cm_stop_listener "$pid"
  pass "an invalid or missing X-Twilio-Signature is rejected and nothing is persisted"
}

test_from_mismatch_rejected_even_with_valid_signature() {
  local home info pid port sig code n
  home="$TMP_ROOT/from-mismatch"
  info=$(cm_start_listener "$home" "$FAKE_AUTH_TOKEN" "$FAKE_DEST"); pid=${info%% *}; port=${info##* }
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000004" "From=+19995551234" "Body=not the captain")
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000004" \
    --data-urlencode "From=+19995551234" --data-urlencode "Body=not the captain" \
    "http://127.0.0.1:$port/captain-msg")
  expect_code 403 "$code" "a validly signed request from an unexpected From must still be rejected"
  n=$(find "$home/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "0" ] || fail "a From-mismatched request must never persist anything (found $n)"
  cm_stop_listener "$pid"
  pass "a valid signature from a non-captain number is still rejected"
}

test_idempotent_redelivery_by_message_sid() {
  local home info pid port sig n
  home="$TMP_ROOT/idem"
  info=$(cm_start_listener "$home"); pid=${info%% *}; port=${info##* }
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000005" "From=$FAKE_DEST" "Body=first")
  PATH="$BASE_PATH" curl -s -o /dev/null -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000005" --data-urlencode "From=$FAKE_DEST" --data-urlencode "Body=first" \
    "http://127.0.0.1:$port/captain-msg"
  n=$(find "$home/inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "first delivery must persist exactly one file (found $n)"
  # Twilio's own retry of the SAME MessageSid (e.g. after a timeout) must
  # overwrite in place, not pile up a second file.
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000005" "From=$FAKE_DEST" "Body=first")
  PATH="$BASE_PATH" curl -s -o /dev/null -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000005" --data-urlencode "From=$FAKE_DEST" --data-urlencode "Body=first" \
    "http://127.0.0.1:$port/captain-msg"
  n=$(find "$home/inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "a same-MessageSid redelivery must overwrite, not pile up (found $n)"
  # A distinct MessageSid gets its own file.
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000006" "From=$FAKE_DEST" "Body=second")
  PATH="$BASE_PATH" curl -s -o /dev/null -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000006" --data-urlencode "From=$FAKE_DEST" --data-urlencode "Body=second" \
    "http://127.0.0.1:$port/captain-msg"
  n=$(find "$home/inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  [ "$n" = "2" ] || fail "a distinct MessageSid must persist separately (found $n)"
  assert_present "$home/inbox/message-SM00000000000000000000000000000006.json" "distinct MessageSid must name its own file"
  cm_stop_listener "$pid"
  pass "same-MessageSid redelivery is idempotent; a distinct MessageSid stays separate"
}

test_inbox_write_is_atomic_no_partial_files_visible() {
  local home info pid port sig
  home="$TMP_ROOT/atomic"
  info=$(cm_start_listener "$home"); pid=${info%% *}; port=${info##* }
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000007" "From=$FAKE_DEST" "Body=atomic check")
  PATH="$BASE_PATH" curl -s -o /dev/null -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000007" --data-urlencode "From=$FAKE_DEST" --data-urlencode "Body=atomic check" \
    "http://127.0.0.1:$port/captain-msg"
  # No .tmp.* leftovers: the write path is temp-file-then-os.replace, so a
  # completed request must leave only the final name behind.
  local leftovers
  leftovers=$(find "$home/inbox" -maxdepth 1 -name '*.tmp.*' | wc -l | tr -d ' ')
  [ "$leftovers" = "0" ] || fail "atomic write left a temp file behind (found $leftovers)"
  assert_present "$home/inbox/message-SM00000000000000000000000000000007.json" "the final file must exist"
  cm_stop_listener "$pid"
  pass "the inbox write is atomic: no partial or temp files are left visible"
}

# --- fm-clickstack-recv.sh: the real daemon-start path, including the actual
# 1Password fetch (mocked) for the Twilio Account Auth Token -----------------

test_recv_serve_fetches_auth_token_from_1password_and_serves_route() {
  local home port pid ready sig code i
  home="$TMP_ROOT/recv-real"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  ready="$home/state/.clickstack-recv.ready"
  for _ in 1 2 3 4 5; do
    port=$(( 20000 + (RANDOM % 20000) ))
    rm -f "$ready"
    OP_SERVICE_ACCOUNT_TOKEN=fake PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" CLICKSTACK_WEBHOOK_PORT="$port" \
      "$ROOT/bin/fm-clickstack-recv.sh" serve >"$home/recv.out" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 40 ]; do
      [ -f "$ready" ] && break
      cm_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    if [ -f "$ready" ]; then RECV_PIDS+=("$pid"); break; fi
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [ -f "$ready" ] || fail "receiver never bound a port after retries"$'\n'"$(cat "$home/recv.out" 2>/dev/null)"

  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000099" "From=$FAKE_DEST" "Body=via recv.sh")
  code=$(PATH="$BASE_PATH" curl -s -o /dev/null -w '%{http_code}' -H "X-Twilio-Signature: $sig" \
    --data-urlencode "MessageSid=SM00000000000000000000000000000099" --data-urlencode "From=$FAKE_DEST" --data-urlencode "Body=via recv.sh" \
    "http://127.0.0.1:$port/captain-msg")
  expect_code 200 "$code" "a correctly signed request must be accepted when served through the real recv.sh + 1Password chain"
  assert_present "$home/state/captain-msg-inbox/message-SM00000000000000000000000000000099.json" "the reply must be persisted"
  cm_stop_listener "$pid"
  pass "fm-clickstack-recv.sh fetches the Twilio Account Auth Token from 1Password (mocked) and serves a working /captain-msg route"
}

# --- fm-twilio-sig-verify.py: the shared HMAC-SHA1 validator, exercised
# directly (fm-clickstack-listener.py's own /captain-msg route above already
# exercises the SAME implementation from the direct-webhook side; this proves
# the extracted module works standalone against a STORED payload, the shape
# the alert-router relays per Teslemetry/tools PR 26) -------------------------

VERIFY="$ROOT/bin/fm-twilio-sig-verify.py"

# router_envelope <url> <token> <body>: print a {"url","signature","body"}
# envelope with the correctly-computed Twilio signature, mirroring exactly
# what the alert-router relays (Teslemetry/tools PR 26 "What's relayed").
router_envelope() {
  PATH="$BASE_PATH" python3 -c '
import sys, json
sys.path.insert(0, sys.argv[4])
from fm_twilio_sig import parse_form
import hmac, hashlib, base64
url, token, body = sys.argv[1], sys.argv[2], sys.argv[3]
form = parse_form(body)
s = url
for k in sorted(form):
    s += k + form[k]
sig = base64.b64encode(hmac.new(token.encode(), s.encode(), hashlib.sha1).digest()).decode()
print(json.dumps({"url": url, "signature": sig, "body": body}))
' "$1" "$2" "$3" "$ROOT/bin"
}

test_verify_cli_accepts_valid_stored_payload() {
  local bf out rc
  bf=$(mktemp "$TMP_ROOT/verify-valid.XXXXXX")
  # The "+" in FAKE_DEST must be percent-encoded in the STORED (wire-shaped)
  # body - form-urlencoded decoding treats a literal "+" as a space - while
  # twilio_sign below takes the already-decoded value, exactly like a real
  # Twilio request: encoded on the wire, decoded before signing/validating.
  printf '%s' "MessageSid=SM1&From=$(printf '%s' "$FAKE_DEST" | sed 's/+/%2B/')&Body=hi" > "$bf"
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM1" "From=$FAKE_DEST" "Body=hi")
  out=$(printf '%s' "$FAKE_AUTH_TOKEN" | PATH="$BASE_PATH" python3 "$VERIFY" --url "$FAKE_URL" --signature "$sig" --body-file "$bf"); rc=$?
  expect_code 0 "$rc" "a correctly signed stored payload must validate"
  assert_contains "$out" '"MessageSid": "SM1"' "the verifier did not print the decoded form fields"
  pass "fm-twilio-sig-verify.py accepts a validly signed stored payload and prints its decoded fields"
}

test_verify_cli_rejects_tampered_body() {
  local bf rc
  bf=$(mktemp "$TMP_ROOT/verify-tampered.XXXXXX")
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM2" "From=$FAKE_DEST" "Body=original")
  # The signature was computed over "Body=original"; the stored body was
  # tampered with after the fact (or corrupted in transit/at rest).
  printf '%s' "MessageSid=SM2&From=$(printf '%s' "$FAKE_DEST" | sed 's/+/%2B/')&Body=tampered" > "$bf"
  printf '%s' "$FAKE_AUTH_TOKEN" | PATH="$BASE_PATH" python3 "$VERIFY" --url "$FAKE_URL" --signature "$sig" --body-file "$bf" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a tampered body must fail signature validation"
  pass "fm-twilio-sig-verify.py rejects a stored payload whose body was tampered with"
}

test_verify_cli_rejects_wrong_url() {
  local bf rc
  bf=$(mktemp "$TMP_ROOT/verify-wrong-url.XXXXXX")
  sig=$(twilio_sign "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM3" "From=$FAKE_DEST" "Body=hi")
  printf '%s' "MessageSid=SM3&From=$(printf '%s' "$FAKE_DEST" | sed 's/+/%2B/')&Body=hi" > "$bf"
  # Twilio signed against $FAKE_URL; validating against a different URL (e.g. a
  # misconfigured ALERT_ROUTER_CAPTAIN_MSG_WEBHOOK_URL) must fail, since the
  # webhook URL is part of the signed material.
  printf '%s' "$FAKE_AUTH_TOKEN" | PATH="$BASE_PATH" python3 "$VERIFY" --url "https://example.invalid/wrong-path" --signature "$sig" --body-file "$bf" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "validating against the wrong URL must fail even with an otherwise-correct signature"
  pass "fm-twilio-sig-verify.py rejects a signature computed for a different URL"
}

# --- inbox poll shim ----------------------------------------------------------

test_poll_inert_without_gate() {
  local home out rc
  home="$TMP_ROOT/poll-off"; mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-gate exit"
  [ -z "$out" ] || fail "poll must be silent without a gate (got: $out)"
  pass "the poll is a hard no-op without the config gate"
}

test_poll_surfaces_pending_inbox() {
  local home out
  home="$TMP_ROOT/poll-surface"; mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-poll.sh")
  [ -z "$out" ] || fail "poll must be silent with an empty inbox (got: $out)"
  printf '{"params":{"Body":"hi"}}' > "$home/state/captain-msg-inbox/message-SM1.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-poll.sh")
  assert_contains "$out" "captain-msg 1 pending" "poll must surface a pending reply"
  assert_contains "$out" "message-SM1.json" "poll must name the pending file"
  mkdir -p "$home/state/captain-msg-inbox/processed"
  mv "$home/state/captain-msg-inbox/message-SM1.json" "$home/state/captain-msg-inbox/processed/"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-poll.sh")
  [ -z "$out" ] || fail "poll must ignore processed/ payloads (got: $out)"
  pass "the poll surfaces only unhandled top-level inbox payloads"
}

# --- inbox poll shim: router-relayed payloads (Teslemetry/tools PR 26 shape) -
# The alert-router holds no Twilio Account Auth Token and validates nothing;
# it relays {"url","signature","body"} verbatim into the SAME inbox the direct
# listener uses. The poll must validate this shape itself before ever trusting
# it as a pending reply - these tests exercise that path end to end (real
# 1Password fetch mocked, real signature computation and validation).
run_poll() {
  local home=$1
  FM_HOME="$home" PATH="$home/fakebin:$BASE_PATH" "$ROOT/bin/fm-captain-msg-poll.sh"
}

test_poll_router_relay_valid_normalizes_and_surfaces_pending() {
  local home body
  home=$(new_case poll-router-valid); mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  body="MessageSid=SM00000000000000000000000000000201&From=$(printf '%s' "$FAKE_DEST" | sed 's/+/%2B/')&Body=Reply+from+the+road"
  router_envelope "$FAKE_URL" "$FAKE_AUTH_TOKEN" "$body" > "$home/state/captain-msg-inbox/captain-msg-SM00000000000000000000000000000201.json"
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg 1 pending" "a validly signed router-relayed payload must surface as pending"
  assert_contains "$out" "captain-msg-SM00000000000000000000000000000201.json" "poll must name the normalized file"
  assert_grep '"params"' "$home/state/captain-msg-inbox/captain-msg-SM00000000000000000000000000000201.json" \
    "a valid router-relayed payload must be normalized to the {received_at,params} shape in place"
  assert_grep '"Body": "Reply from the road"' "$home/state/captain-msg-inbox/captain-msg-SM00000000000000000000000000000201.json" \
    "the normalized envelope must carry the decoded reply body"
  pass "the poll validates a router-relayed payload's signature and normalizes it into the trusted pending shape"
}

test_poll_router_relay_tampered_body_quarantined() {
  local home name
  home=$(new_case poll-router-tampered); mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  name="captain-msg-SM00000000000000000000000000000202.json"
  # Sign one body, then store a DIFFERENT one under that same signature - the
  # same tamper this suite's fm-twilio-sig-verify.py tests exercise, but here
  # through the full poll path: jq mutates only .body, leaving the envelope's
  # .signature as computed for the original (now-mismatched) content.
  router_envelope "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000202&From=$(printf '%s' "$FAKE_DEST" | sed 's/+/%2B/')&Body=original" \
    | jq '.body = "MessageSid=SM00000000000000000000000000000202&From=%2B14158675309&Body=tampered"' \
    > "$home/state/captain-msg-inbox/$name"
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg-quarantine" "a tampered router-relayed payload must be quarantined loudly, not silently dropped"
  assert_contains "$out" "$name" "the quarantine notice must name the file"
  assert_not_contains "$out" "captain-msg 1 pending" "a quarantined payload must never be reported as a trusted pending reply"
  assert_present "$home/state/captain-msg-inbox/quarantine/$name" "the tampered payload must be moved into quarantine/"
  assert_present "$home/state/captain-msg-inbox/quarantine/$name.reason" "quarantine must record why, not just move the file silently"
  assert_absent "$home/state/captain-msg-inbox/$name" "a quarantined payload must not remain at the top level (it would re-surface as pending)"
  pass "the poll quarantines a router-relayed payload whose body was tampered with, loudly and with a reason"
}

test_poll_router_relay_missing_signature_quarantined() {
  local home name
  home=$(new_case poll-router-nosig); mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  name="captain-msg-SM00000000000000000000000000000203.json"
  printf '{"url":"%s","signature":"","body":"MessageSid=SM00000000000000000000000000000203&From=%s&Body=hi"}' \
    "$FAKE_URL" "$FAKE_DEST" > "$home/state/captain-msg-inbox/$name"
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg-quarantine" "a missing X-Twilio-Signature must be quarantined, exactly like an invalid one"
  assert_present "$home/state/captain-msg-inbox/quarantine/$name" "the unsigned payload must be quarantined"
  pass "the poll quarantines a router-relayed payload with an empty/missing signature"
}

test_poll_router_relay_from_mismatch_quarantined() {
  local home name
  home=$(new_case poll-router-from-mismatch); mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  name="captain-msg-SM00000000000000000000000000000204.json"
  router_envelope "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000204&From=%2B19995551234&Body=not+the+captain" \
    > "$home/state/captain-msg-inbox/$name"
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg-quarantine" "a validly signed reply from an unexpected From must still be quarantined"
  assert_contains "$out" "does not match" "the quarantine reason must explain the From mismatch"
  assert_present "$home/state/captain-msg-inbox/quarantine/$name" "the From-mismatched payload must be quarantined"
  pass "the poll quarantines a validly signed router-relayed payload from a non-captain number"
}

test_poll_router_relay_unrecognized_shape_quarantined() {
  local home name
  home=$(new_case poll-router-garbage); mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  name="captain-msg-garbage.json"
  printf '{"not_a_known_shape": true}' > "$home/state/captain-msg-inbox/$name"
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg-quarantine" "a payload matching neither known envelope shape must be quarantined, never silently ignored"
  assert_present "$home/state/captain-msg-inbox/quarantine/$name" "the malformed payload must be quarantined"
  pass "the poll quarantines a payload matching neither the trusted nor the router-relay envelope shape"
}

test_poll_router_relay_auth_token_fetch_failure_stays_pending_not_trusted() {
  local home name out
  home=$(new_case poll-router-op-fail); mkdir -p "$home/state/captain-msg-inbox" "$home/fakebin"
  write_gate "$home"
  name="captain-msg-SM00000000000000000000000000000205.json"
  router_envelope "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000205&From=$FAKE_DEST&Body=hi" \
    > "$home/state/captain-msg-inbox/$name"
  cat > "$home/fakebin/op" <<'SH'
#!/usr/bin/env bash
echo "op mock: simulated 1Password outage" >&2
exit 1
SH
  chmod +x "$home/fakebin/op"
  out=$(run_poll "$home")
  assert_contains "$out" "cannot validate" "an inability to fetch the Auth Token must be reported loudly"
  assert_not_contains "$out" "captain-msg 1 pending" "an unvalidated router-relayed payload must NEVER be reported as a trusted pending reply"
  assert_not_contains "$out" "captain-msg-quarantine" "an infra failure to validate is not proof of forgery - it must not quarantine a payload that was never checked"
  assert_present "$home/state/captain-msg-inbox/$name" "the payload must remain in place, untouched, for a retry on the next poll cycle"
  pass "the poll neither trusts nor quarantines a router-relayed payload it could not validate, and says so loudly"
}

test_poll_router_relay_normalized_payload_not_revalidated() {
  local home name out
  home=$(new_case poll-router-no-reval); mkdir -p "$home/state/captain-msg-inbox"
  write_gate "$home"
  write_op_mock "$home/fakebin"
  name="captain-msg-SM00000000000000000000000000000206.json"
  router_envelope "$FAKE_URL" "$FAKE_AUTH_TOKEN" "MessageSid=SM00000000000000000000000000000206&From=$(printf '%s' "$FAKE_DEST" | sed 's/+/%2B/')&Body=first+pass" \
    > "$home/state/captain-msg-inbox/$name"
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg 1 pending" "the first poll must validate and surface the reply"
  # Replace op with a tripwire: a second poll must never call it again, since
  # the payload is already normalized to the trusted {received_at,params}
  # shape and pass 1 only looks at un-normalized (raw) files.
  write_tripwire_mock "$home/fakebin" op
  out=$(run_poll "$home")
  assert_contains "$out" "captain-msg 1 pending" "an already-normalized payload must keep surfacing as pending until handled"
  assert_not_contains "$out" "TRIPWIRE" "a second poll must not re-fetch the Auth Token or re-validate an already-normalized payload"
  pass "the poll never re-validates a payload it has already normalized"
}

# --- fm-captain-msg-arm.sh (the non-blocking paths only: gate check and
# --show-url both return before touching the shared daemon's blocking start
# path, mirroring how tests/fm-betterstack.test.sh avoids driving
# fm-clickstack-arm.sh's blocking new-daemon start directly) -----------------

test_arm_inert_without_gate() {
  local home out rc
  home=$(new_case arm-off); mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-arm.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "arm with no gate should be a silent no-op"
  [ -z "$out" ] || fail "arm must be silent with no gate (got: $out)"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-arm.sh" --show-url 2>&1); rc=$?
  expect_code 0 "$rc" "arm --show-url with no gate should be a silent no-op"
  [ -z "$out" ] || fail "arm --show-url must be silent with no gate (got: $out)"
  pass "fm-captain-msg-arm.sh is inert without config/captain-msg.env"
}

test_arm_refuses_incomplete_config() {
  local home out rc
  home=$(new_case arm-incomplete); mkdir -p "$home/state" "$home/config"
  : > "$home/config/captain-msg.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-arm.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "arm with an incomplete gate should fail"
  assert_contains "$out" "config/captain-msg.env is incomplete" "arm refusal did not explain the incomplete config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-arm.sh" --show-url 2>&1); rc=$?
  expect_code 1 "$rc" "arm --show-url with an incomplete gate should fail"
  pass "fm-captain-msg-arm.sh refuses loudly on an incomplete config, both subcommands"
}

test_arm_show_url_prints_path_and_configured_url() {
  local home out
  home=$(new_case arm-show-url)
  write_gate "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-msg-arm.sh" --show-url 2>&1)
  assert_contains "$out" "path=/captain-msg" "show-url must name the route path"
  assert_contains "$out" "url=$FAKE_URL" "show-url must print the configured webhook URL"
  pass "fm-captain-msg-arm.sh --show-url prints the route path and configured webhook URL"
}

# --- bootstrap activation contract -------------------------------------------

test_bootstrap_inert_without_gate() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "CAPTAIN_MSG:" "bootstrap must say nothing about the channel without a gate"
  assert_absent "$home/state/captain-msg-watch.check.sh" "no gate -> no poll shim"
  pass "bootstrap is inert without the config gate (non-users unaffected)"
}

test_bootstrap_reports_incomplete_config_and_writes_no_shim() {
  local home out
  home="$TMP_ROOT/boot-incomplete"; mkdir -p "$home/config"
  : > "$home/config/captain-msg.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CAPTAIN_MSG: messaging channel off" "bootstrap must report the incomplete config"
  assert_contains "$out" "incomplete" "bootstrap must say the config is incomplete"
  assert_absent "$home/state/captain-msg-watch.check.sh" "an incomplete config must never arm a poll shim"
  pass "bootstrap reports an incomplete gate as a misconfiguration rather than silently arming"
}

test_bootstrap_activates_and_opts_out() {
  local home out sum1 sum2
  home="$TMP_ROOT/boot-on"; mkdir -p "$home/config"
  write_gate "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CAPTAIN_MSG: messaging channel on" "bootstrap must announce the channel"
  assert_present "$home/state/captain-msg-watch.check.sh" "bootstrap must drop the poll shim"
  [ -x "$home/state/captain-msg-watch.check.sh" ] || fail "the poll shim must be executable"
  assert_grep "fm-captain-msg-poll.sh" "$home/state/captain-msg-watch.check.sh" "the shim must exec the poll script"
  sum1=$(shasum < "$home/state/captain-msg-watch.check.sh")
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(shasum < "$home/state/captain-msg-watch.check.sh")
  [ "$sum1" = "$sum2" ] || fail "bootstrap channel setup must be idempotent"
  assert_present "$home/state/captain-msg-watch.check-trust" "bootstrap must register the poll shim as a trusted watcher check"
  rm -f "$home/config/captain-msg.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CAPTAIN_MSG: messaging channel off" "opt-out must report cleanup"
  assert_absent "$home/state/captain-msg-watch.check.sh" "opt-out must remove the poll shim"
  assert_absent "$home/state/captain-msg-watch.check-trust" "opt-out must remove the check-trust binding"
  pass "bootstrap activates from a complete gate idempotently and cleans up on opt-out"
}

# --- run ----------------------------------------------------------------------

test_speech_contract_accepts_plain_text
test_speech_contract_rejects_url
test_speech_contract_rejects_markdown_and_code_fence
test_speech_contract_rejects_over_length
test_speech_contract_rejects_empty
test_send_refuses_without_gate
test_send_refuses_incomplete_config
test_send_refuses_message_failing_speech_contract
test_send_missing_op_token_fails_loud
test_send_missing_credential_field_names_it
test_send_non_2xx_response_fails_loud_and_warns_no_fallback
test_send_success_and_no_secret_in_argv
test_send_direct_address_uses_rcs_prefixed_from_and_to
test_send_messaging_service_uses_plain_to
test_require_config_rejects_neither_addressing_mode
test_require_config_rejects_both_addressing_modes
test_route_404_when_disabled
test_valid_signature_accepted_and_persisted
test_valid_signature_with_rcs_prefixed_from_accepted
test_invalid_signature_rejected
test_from_mismatch_rejected_even_with_valid_signature
test_idempotent_redelivery_by_message_sid
test_inbox_write_is_atomic_no_partial_files_visible
test_recv_serve_fetches_auth_token_from_1password_and_serves_route
test_verify_cli_accepts_valid_stored_payload
test_verify_cli_rejects_tampered_body
test_verify_cli_rejects_wrong_url
test_poll_inert_without_gate
test_poll_surfaces_pending_inbox
test_poll_router_relay_valid_normalizes_and_surfaces_pending
test_poll_router_relay_tampered_body_quarantined
test_poll_router_relay_missing_signature_quarantined
test_poll_router_relay_from_mismatch_quarantined
test_poll_router_relay_unrecognized_shape_quarantined
test_poll_router_relay_auth_token_fetch_failure_stays_pending_not_trusted
test_poll_router_relay_normalized_payload_not_revalidated
test_arm_inert_without_gate
test_arm_refuses_incomplete_config
test_arm_show_url_prints_path_and_configured_url
test_bootstrap_inert_without_gate
test_bootstrap_reports_incomplete_config_and_writes_no_shim
test_bootstrap_activates_and_opts_out
