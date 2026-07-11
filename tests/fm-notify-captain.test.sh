#!/usr/bin/env bash
# Behavior tests for bin/fm-notify-captain.sh: the Pushover last-hop notifier
# from the captain-alert-channel-b3 investigation (fork-only firstmate
# feature).
#
# Covers: tier -> Pushover priority mapping and retry/expire env overrides
# (all exercised through --dry-run, which makes no external calls), the
# dry-run send-nothing guarantee (tripwire mocks that fail the test if
# invoked), and every documented loud-failure path (missing
# OP_SERVICE_ACCOUNT_TOKEN, an absent op binary, a missing or empty 1Password
# field on either the "username" or "credential" field, and a non-2xx
# Pushover response). A final pair of success-path cases mocks op and curl to
# confirm the emergency-tier receipt is printed and that the Pushover user key
# and application token never appear in curl's argv. No test sends a real
# push: op and curl are always PATH-shimmed mocks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify-captain.sh"
TMP_ROOT=$(fm_test_tmproot fm-notify-captain-tests)

# --- fakebin mocks -----------------------------------------------------------

# op mock driven by env vars so one script covers every field-lookup case:
#   FM_TEST_OP_USERNAME / FM_TEST_OP_CREDENTIAL, each one of:
#     unset/normal value -> printed as the field's value
#     __MISSING__        -> op exits non-zero, as if the field/item is absent
#     __EMPTY__          -> op exits 0 with empty output
write_op_mock() {
  local fakebin=$1
  cat > "$fakebin/op" <<'SH'
#!/usr/bin/env bash
field=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--fields" ]; then
    j=$((i + 1))
    field="${!j}"
  fi
done
case "$field" in
  username) val=${FM_TEST_OP_USERNAME-real-user-key} ;;
  credential) val=${FM_TEST_OP_CREDENTIAL-real-app-token} ;;
  *) echo "op mock: unexpected --fields value: $field" >&2; exit 1 ;;
esac
case "$val" in
  __MISSING__) echo "[ERROR] '$field' isn't a field in the \"Pushover\" item." >&2; exit 1 ;;
  __EMPTY__) printf '' ;;
  *) printf '%s' "$val" ;;
esac
SH
  chmod +x "$fakebin/op"
}

# curl mock driven by FM_TEST_CURL_HTTP_CODE / FM_TEST_CURL_BODY. Logs its full
# argv to FM_TEST_CURL_ARGV_LOG (when set) so a test can assert secrets never
# appear there, and the POST body it received on stdin to FM_TEST_CURL_STDIN_LOG.
write_curl_mock() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-o" ]; then
    outfile="${args[$((i + 1))]}"
  fi
done
if [ -n "${FM_TEST_CURL_ARGV_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_TEST_CURL_ARGV_LOG"
fi
if [ -n "${FM_TEST_CURL_STDIN_LOG:-}" ]; then
  cat > "$FM_TEST_CURL_STDIN_LOG"
else
  cat >/dev/null
fi
printf '%s' "$FM_TEST_CURL_BODY" > "$outfile"
printf '%s' "$FM_TEST_CURL_HTTP_CODE"
SH
  chmod +x "$fakebin/curl"
}

# A mock that fails the test if it is ever invoked - used to prove dry-run
# makes no external calls at all.
write_tripwire_mock() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
echo "TRIPWIRE: $name should not have been invoked" >&2
exit 99
SH
  chmod +x "$fakebin/$name"
}

# run_notify <case_dir> <args...>: invoke the script with case_dir/fakebin
# shadowing the real op/curl (real jq still resolves via the inherited PATH)
# and a fake OP_SERVICE_ACCOUNT_TOKEN present.
run_notify() {
  local case_dir=$1; shift
  OP_SERVICE_ACCOUNT_TOKEN="fake-service-account-token" \
  PATH="$case_dir/fakebin:$PATH" \
    "$NOTIFY" "$@"
}

new_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

# --- tier -> priority mapping (dry-run; no external calls) ------------------

test_dry_run_urgent_maps_to_priority_1() {
  local case_dir out rc
  case_dir=$(new_case dry-urgent)

  set +e
  out=$(run_notify "$case_dir" --tier urgent --dry-run "hello captain" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-urgent: --dry-run should succeed"
  assert_contains "$out" "tier=urgent priority=1" "dry-urgent: urgent tier did not map to priority 1"
  assert_not_contains "$out" "retry=" "dry-urgent: urgent tier should not print retry/expire"
  assert_contains "$out" "user=<REDACTED> token=<REDACTED>" "dry-urgent: secrets were not redacted in dry-run output"
  pass "fm-notify-captain maps tier=urgent to Pushover priority 1"
}

test_dry_run_emergency_maps_to_priority_2_with_defaults() {
  local case_dir out rc
  case_dir=$(new_case dry-emergency-defaults)

  set +e
  out=$(run_notify "$case_dir" --tier emergency --dry-run "prod is down" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-emergency-defaults: --dry-run should succeed"
  assert_contains "$out" "tier=emergency priority=2" "dry-emergency-defaults: emergency tier did not map to priority 2"
  assert_contains "$out" "retry=30 expire=3600" "dry-emergency-defaults: default retry/expire were not 30/3600"
  pass "fm-notify-captain maps tier=emergency to Pushover priority 2 with default retry/expire"
}

test_dry_run_respects_retry_expire_env_overrides() {
  local case_dir out rc
  case_dir=$(new_case dry-emergency-overrides)

  set +e
  out=$(FM_NOTIFY_RETRY=45 FM_NOTIFY_EXPIRE=1800 \
    run_notify "$case_dir" --tier emergency --dry-run "still down" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-emergency-overrides: --dry-run should succeed"
  assert_contains "$out" "retry=45 expire=1800" "dry-emergency-overrides: FM_NOTIFY_RETRY/FM_NOTIFY_EXPIRE were not honored"
  pass "fm-notify-captain honors FM_NOTIFY_RETRY and FM_NOTIFY_EXPIRE overrides"
}

test_retry_below_minimum_rejected() {
  local case_dir out rc
  case_dir=$(new_case retry-too-low)

  set +e
  out=$(FM_NOTIFY_RETRY=10 run_notify "$case_dir" --tier emergency --dry-run "msg" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "retry-too-low: a retry below Pushover's 30s minimum should be refused"
  assert_contains "$out" ">= 30 seconds" "retry-too-low: refusal did not explain the 30s minimum"
  pass "fm-notify-captain refuses an emergency retry below Pushover's 30s minimum"
}

test_expire_above_maximum_rejected() {
  local case_dir out rc
  case_dir=$(new_case expire-too-high)

  set +e
  out=$(FM_NOTIFY_EXPIRE=99999 run_notify "$case_dir" --tier emergency --dry-run "msg" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "expire-too-high: an expire above Pushover's 10800s maximum should be refused"
  assert_contains "$out" "<= 10800 seconds" "expire-too-high: refusal did not explain the 10800s maximum"
  pass "fm-notify-captain refuses an emergency expire above Pushover's 10800s maximum"
}

test_non_numeric_retry_rejected() {
  local case_dir out rc
  case_dir=$(new_case retry-non-numeric)

  set +e
  out=$(FM_NOTIFY_RETRY=soon run_notify "$case_dir" --tier emergency --dry-run "msg" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "retry-non-numeric: a non-numeric retry should be refused"
  assert_contains "$out" "must be a positive integer" "retry-non-numeric: refusal did not explain the integer requirement"
  pass "fm-notify-captain refuses a non-numeric FM_NOTIFY_RETRY"
}

test_dry_run_sends_nothing() {
  local case_dir out rc
  case_dir=$(new_case dry-run-tripwire)
  write_tripwire_mock "$case_dir/fakebin" op
  write_tripwire_mock "$case_dir/fakebin" curl

  set +e
  out=$(run_notify "$case_dir" --tier emergency --dry-run "should not call anything" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-run-tripwire: --dry-run should succeed"
  assert_not_contains "$out" "TRIPWIRE" "dry-run-tripwire: --dry-run invoked an external command"
  pass "fm-notify-captain --dry-run calls neither op nor curl"
}

# --- argument validation -----------------------------------------------------

test_missing_tier_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case missing-tier)

  set +e
  out=$(run_notify "$case_dir" --dry-run "no tier here" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-tier: absent --tier should be refused"
  assert_contains "$out" "--tier is required" "missing-tier: refusal did not explain --tier is required"
  pass "fm-notify-captain refuses when --tier is omitted"
}

test_invalid_tier_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case invalid-tier)

  set +e
  out=$(run_notify "$case_dir" --tier routine --dry-run "wrong tier" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "invalid-tier: an unrecognized tier should be refused"
  assert_contains "$out" "must be 'urgent' or 'emergency'" "invalid-tier: refusal did not name the valid tiers"
  pass "fm-notify-captain refuses a tier that is not urgent or emergency"
}

test_missing_message_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case missing-message)

  set +e
  out=$(run_notify "$case_dir" --tier urgent --dry-run 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-message: no message argument should be refused"
  assert_contains "$out" "message is required" "missing-message: refusal did not explain a message is required"
  pass "fm-notify-captain refuses when no message is given"
}

# --- op / secret loud-failure paths ------------------------------------------

test_missing_op_service_account_token_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case missing-op-token)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(env -u OP_SERVICE_ACCOUNT_TOKEN PATH="$case_dir/fakebin:$PATH" \
    "$NOTIFY" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-op-token: an unset OP_SERVICE_ACCOUNT_TOKEN should be refused"
  assert_contains "$out" "OP_SERVICE_ACCOUNT_TOKEN is not set" "missing-op-token: refusal did not name the missing token"
  pass "fm-notify-captain refuses to run without OP_SERVICE_ACCOUNT_TOKEN"
}

test_op_binary_absent_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case op-binary-absent)
  # An empty PATH: the script's own checks are all builtins up to the `op`
  # lookup, and invoking bash directly (rather than through the shebang) means
  # no external command, not even the interpreter, needs to be resolved first.
  set +e
  out=$(OP_SERVICE_ACCOUNT_TOKEN=fake PATH="$case_dir/fakebin" \
    "$BASH" "$NOTIFY" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "op-binary-absent: a missing op binary should be refused"
  assert_contains "$out" "op (1Password CLI) not found on PATH" "op-binary-absent: refusal did not name the missing op binary"
  pass "fm-notify-captain refuses when the op CLI is not on PATH"
}

test_missing_credential_field_names_it() {
  local case_dir out rc
  case_dir=$(new_case missing-credential-field)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(FM_TEST_OP_CREDENTIAL=__MISSING__ run_notify "$case_dir" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-credential-field: a missing 'credential' field should be refused"
  assert_contains "$out" "1Password field 'credential'" "missing-credential-field: refusal did not name the 'credential' field exactly"
  pass "fm-notify-captain names the 'credential' field when the application token is not yet on the Pushover item"
}

test_missing_username_field_names_it() {
  local case_dir out rc
  case_dir=$(new_case missing-username-field)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(FM_TEST_OP_USERNAME=__MISSING__ run_notify "$case_dir" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-username-field: a missing 'username' field should be refused"
  assert_contains "$out" "1Password field 'username'" "missing-username-field: refusal did not name the 'username' field"
  pass "fm-notify-captain names the 'username' field when it cannot be read"
}

test_empty_field_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case empty-field)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(FM_TEST_OP_CREDENTIAL=__EMPTY__ run_notify "$case_dir" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "empty-field: an empty 'credential' field should be refused"
  assert_contains "$out" "1Password field 'credential'" "empty-field: refusal did not name the empty field"
  assert_contains "$out" "is empty" "empty-field: refusal did not say the field is empty"
  pass "fm-notify-captain refuses an empty 1Password field"
}

# --- Pushover API response handling ------------------------------------------

test_non_2xx_response_prints_errors_array() {
  local case_dir out rc
  case_dir=$(new_case non-2xx)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(FM_TEST_CURL_HTTP_CODE=400 \
    FM_TEST_CURL_BODY='{"status":0,"errors":["message parameter is required"],"request":"req-err"}' \
    run_notify "$case_dir" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "non-2xx: a non-2xx Pushover response should be refused"
  assert_contains "$out" "HTTP 400" "non-2xx: refusal did not include the HTTP status"
  assert_contains "$out" "message parameter is required" "non-2xx: refusal did not print Pushover's errors array"
  pass "fm-notify-captain prints Pushover's errors array on a non-2xx response"
}

test_success_emergency_prints_receipt_and_never_leaks_secrets_to_argv() {
  local case_dir out rc argv_log stdin_log
  case_dir=$(new_case success-emergency)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"
  argv_log="$case_dir/curl-argv.log"
  stdin_log="$case_dir/curl-stdin.log"

  out=$(FM_TEST_CURL_HTTP_CODE=200 \
    FM_TEST_CURL_BODY='{"status":1,"request":"req-123","receipt":"recv-456"}' \
    FM_TEST_OP_USERNAME='u-fake-user-key' FM_TEST_OP_CREDENTIAL='t-fake-app-token' \
    FM_TEST_CURL_ARGV_LOG="$argv_log" FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_notify "$case_dir" --tier emergency --title "Prod down" "everything is on fire" 2>&1) \
    || fail "success-emergency: fm-notify-captain should succeed"

  assert_contains "$out" "sent: tier=emergency priority=2" "success-emergency: missing sent confirmation"
  assert_contains "$out" "receipt: recv-456" "success-emergency: emergency send did not print the receipt id"
  assert_no_grep 'u-fake-user-key' "$argv_log" "success-emergency: the user key leaked into curl's argv"
  assert_no_grep 't-fake-app-token' "$argv_log" "success-emergency: the app token leaked into curl's argv"
  assert_grep 'user=u-fake-user-key' "$stdin_log" "success-emergency: user key was not sent in the POST body"
  assert_grep 'token=t-fake-app-token' "$stdin_log" "success-emergency: app token was not sent in the POST body"
  assert_grep 'retry=30' "$stdin_log" "success-emergency: emergency POST body missing retry"
  assert_grep 'expire=3600' "$stdin_log" "success-emergency: emergency POST body missing expire"
  pass "fm-notify-captain prints the receipt id on an emergency send and never puts secrets in curl argv"
}

test_success_urgent_no_receipt_line() {
  local case_dir out rc
  case_dir=$(new_case success-urgent)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  out=$(FM_TEST_CURL_HTTP_CODE=200 \
    FM_TEST_CURL_BODY='{"status":1,"request":"req-789"}' \
    run_notify "$case_dir" --tier urgent "a routine urgent ping" 2>&1) \
    || fail "success-urgent: fm-notify-captain should succeed"

  assert_contains "$out" "sent: tier=urgent priority=1" "success-urgent: missing sent confirmation"
  assert_not_contains "$out" "receipt:" "success-urgent: urgent (priority 1) send should not print a receipt line"
  pass "fm-notify-captain does not print a receipt line for a priority-1 urgent send"
}

test_dry_run_urgent_maps_to_priority_1
test_dry_run_emergency_maps_to_priority_2_with_defaults
test_dry_run_respects_retry_expire_env_overrides
test_retry_below_minimum_rejected
test_expire_above_maximum_rejected
test_non_numeric_retry_rejected
test_dry_run_sends_nothing
test_missing_tier_fails_loud
test_invalid_tier_fails_loud
test_missing_message_fails_loud
test_missing_op_service_account_token_fails_loud
test_op_binary_absent_fails_loud
test_missing_credential_field_names_it
test_missing_username_field_names_it
test_empty_field_fails_loud
test_non_2xx_response_prints_errors_array
test_success_emergency_prints_receipt_and_never_leaks_secrets_to_argv
test_success_urgent_no_receipt_line
