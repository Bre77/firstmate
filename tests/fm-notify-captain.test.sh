#!/usr/bin/env bash
# Behavior tests for bin/fm-notify-captain.sh: the Better Stack last-hop pager
# from the captain-alert-channel-b3 investigation (fork-only firstmate
# feature).
#
# Covers: tier -> notification-channel mapping and the team-wait env override
# (all exercised through --dry-run, which makes no external calls), the
# dry-run send-nothing guarantee (tripwire mocks that fail the test if
# invoked), and every documented loud-failure path (missing
# OP_SERVICE_ACCOUNT_TOKEN, an absent op binary, a missing or empty 1Password
# field on either the "username" or "credential" field, a non-2xx Better Stack
# response, and an accepted page whose response carries no incident id). The
# success-path cases mock op and curl to confirm the incident body always
# carries a `name` (an incident with none reaches the phone titled "API
# request"), that the two tiers really differ, that the API token never
# appears in curl's argv, and that --resolve closes an incident. No test pages
# anyone: op and curl are always PATH-shimmed mocks.
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
  username) val=${FM_TEST_OP_USERNAME-captain@example.com} ;;
  credential) val=${FM_TEST_OP_CREDENTIAL-real-api-token} ;;
  *) echo "op mock: unexpected --fields value: $field" >&2; exit 1 ;;
esac
case "$val" in
  __MISSING__) echo "[ERROR] '$field' isn't a field in the \"BetterStack API Token\" item." >&2; exit 1 ;;
  __EMPTY__) printf '' ;;
  *) printf '%s' "$val" ;;
esac
SH
  chmod +x "$fakebin/op"
}

# curl mock driven by FM_TEST_CURL_HTTP_CODE / FM_TEST_CURL_BODY. Logs its full
# argv to FM_TEST_CURL_ARGV_LOG (when set) so a test can assert the API token
# never appears there, and the config file it received on stdin to
# FM_TEST_CURL_STDIN_LOG.
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

# The JSON body the script handed curl, recovered from the config file it wrote
# to curl's stdin.
body_from_config() {
  local stdin_log=$1
  sed -n 's/^data-raw = "\(.*\)"$/\1/p' "$stdin_log" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

# --- tier -> channel mapping (dry-run; no external calls) --------------------

test_dry_run_urgent_is_a_critical_push_without_a_call() {
  local case_dir out rc
  case_dir=$(new_case dry-urgent)

  set +e
  out=$(run_notify "$case_dir" --tier urgent --dry-run "hello captain" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-urgent: --dry-run should succeed"
  assert_contains "$out" "tier=urgent push=true critical_alert=true call=false" \
    "dry-urgent: urgent tier did not map to a critical push without a phone call"
  assert_not_contains "$out" "team_wait=" "dry-urgent: urgent tier should not escalate to the team"
  assert_contains "$out" "requester_email=<REDACTED> token=<REDACTED>" "dry-urgent: secrets were not redacted in dry-run output"
  pass "fm-notify-captain maps tier=urgent to a critical push with no phone call"
}

test_dry_run_emergency_adds_a_call_and_team_escalation() {
  local case_dir out rc
  case_dir=$(new_case dry-emergency-defaults)

  set +e
  out=$(run_notify "$case_dir" --tier emergency --dry-run "prod is down" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-emergency-defaults: --dry-run should succeed"
  assert_contains "$out" "tier=emergency push=true critical_alert=true call=true" \
    "dry-emergency-defaults: emergency tier did not add a phone call"
  assert_contains "$out" "team_wait=300" "dry-emergency-defaults: default team wait was not 300 seconds"
  pass "fm-notify-captain maps tier=emergency to a critical push plus a call and team escalation"
}

test_dry_run_respects_team_wait_override() {
  local case_dir out rc
  case_dir=$(new_case dry-emergency-override)

  set +e
  out=$(FM_NOTIFY_TEAM_WAIT=60 run_notify "$case_dir" --tier emergency --dry-run "still down" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-emergency-override: --dry-run should succeed"
  assert_contains "$out" "team_wait=60" "dry-emergency-override: FM_NOTIFY_TEAM_WAIT was not honored"
  pass "fm-notify-captain honors FM_NOTIFY_TEAM_WAIT"
}

test_non_numeric_team_wait_rejected() {
  local case_dir out rc
  case_dir=$(new_case team-wait-non-numeric)

  set +e
  out=$(FM_NOTIFY_TEAM_WAIT=soon run_notify "$case_dir" --tier emergency --dry-run "msg" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "team-wait-non-numeric: a non-numeric team wait should be refused"
  assert_contains "$out" "must be a positive integer" "team-wait-non-numeric: refusal did not explain the integer requirement"
  pass "fm-notify-captain refuses a non-numeric FM_NOTIFY_TEAM_WAIT"
}

test_zero_team_wait_rejected() {
  local case_dir out rc
  case_dir=$(new_case team-wait-zero)

  set +e
  out=$(FM_NOTIFY_TEAM_WAIT=0 run_notify "$case_dir" --tier emergency --dry-run "msg" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "team-wait-zero: a zero team wait should be refused"
  assert_contains "$out" "must be a positive integer" "team-wait-zero: refusal did not explain the integer requirement"
  pass "fm-notify-captain refuses a zero FM_NOTIFY_TEAM_WAIT"
}

test_dry_run_titles_the_page_when_no_title_is_given() {
  local case_dir out rc
  case_dir=$(new_case dry-default-title)

  set +e
  out=$(run_notify "$case_dir" --tier emergency --dry-run "no title given" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-default-title: --dry-run should succeed"
  assert_contains "$out" "title=Firstmate emergency" "dry-default-title: an omitted --title did not fall back to a tier-derived title"
  pass "fm-notify-captain supplies a default title when --title is omitted"
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

test_non_numeric_resolve_id_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case resolve-non-numeric)

  set +e
  out=$(run_notify "$case_dir" --resolve "993937396/../../delete" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "resolve-non-numeric: a non-numeric incident id should be refused"
  assert_contains "$out" "numeric Better Stack incident id" "resolve-non-numeric: refusal did not require a numeric id"
  pass "fm-notify-captain refuses a --resolve id that is not a plain number"
}

test_resolve_with_tier_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case resolve-with-tier)

  set +e
  out=$(run_notify "$case_dir" --resolve 993937396 --tier urgent 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "resolve-with-tier: --resolve plus --tier should be refused"
  assert_contains "$out" "cannot be combined with --tier" "resolve-with-tier: refusal did not explain the conflict"
  pass "fm-notify-captain refuses --resolve combined with --tier"
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
  pass "fm-notify-captain names the 'credential' field when the API token cannot be read"
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
  pass "fm-notify-captain names the 'username' field when the requester email cannot be read"
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

# --- Better Stack API response handling --------------------------------------

test_non_2xx_response_prints_errors() {
  local case_dir out rc
  case_dir=$(new_case non-2xx)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(FM_TEST_CURL_HTTP_CODE=422 \
    FM_TEST_CURL_BODY='{"errors":"Sorry, you are missing some required attributes","required_attributes":["requester_email"]}' \
    run_notify "$case_dir" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "non-2xx: a non-2xx Better Stack response should be refused"
  assert_contains "$out" "HTTP 422" "non-2xx: refusal did not include the HTTP status"
  assert_contains "$out" "missing some required attributes" "non-2xx: refusal did not print Better Stack's errors"
  pass "fm-notify-captain prints Better Stack's errors on a non-2xx response"
}

test_accepted_page_without_incident_id_fails_loud() {
  local case_dir out rc
  case_dir=$(new_case no-incident-id)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"

  set +e
  out=$(FM_TEST_CURL_HTTP_CODE=201 FM_TEST_CURL_BODY='{"data":{"type":"incident"}}' \
    run_notify "$case_dir" --tier urgent "hello" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "no-incident-id: a 2xx with no incident id should be refused"
  assert_contains "$out" "no incident id" "no-incident-id: refusal did not explain the missing incident id"
  pass "fm-notify-captain refuses a page it could never resolve afterwards"
}

test_success_emergency_body_and_no_token_in_argv() {
  local case_dir out argv_log stdin_log body
  case_dir=$(new_case success-emergency)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"
  argv_log="$case_dir/curl-argv.log"
  stdin_log="$case_dir/curl-stdin.log"

  out=$(FM_TEST_CURL_HTTP_CODE=201 \
    FM_TEST_CURL_BODY='{"data":{"id":"993937396","type":"incident"}}' \
    FM_TEST_OP_USERNAME='oncall@example.com' FM_TEST_OP_CREDENTIAL='t-fake-api-token' \
    FM_TEST_CURL_ARGV_LOG="$argv_log" FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_notify "$case_dir" --tier emergency --title "Prod down" "everything is on fire" 2>&1) \
    || fail "success-emergency: fm-notify-captain should succeed"

  assert_contains "$out" "paged: tier=emergency incident=993937396" "success-emergency: missing paged confirmation"
  assert_contains "$out" "--resolve 993937396" "success-emergency: did not print how to resolve the incident"
  assert_no_grep 't-fake-api-token' "$argv_log" "success-emergency: the API token leaked into curl's argv"
  assert_grep 'authorization: Bearer t-fake-api-token' "$stdin_log" "success-emergency: the API token was not passed through curl's stdin config"

  body=$(body_from_config "$stdin_log")
  [ "$(printf '%s' "$body" | jq -r '.name')" = "Prod down" ] \
    || fail "success-emergency: the incident body did not carry --title as name (got: $body)"
  [ "$(printf '%s' "$body" | jq -r '.summary')" = "everything is on fire" ] \
    || fail "success-emergency: the incident body did not carry the message as summary"
  [ "$(printf '%s' "$body" | jq -r '.requester_email')" = "oncall@example.com" ] \
    || fail "success-emergency: the incident body did not carry the requester email"
  [ "$(printf '%s' "$body" | jq -r '.push, .critical_alert, .call, .team_wait' | tr '\n' ' ')" = "true true true 300 " ] \
    || fail "success-emergency: emergency tier did not send a critical push plus a call and team escalation (got: $body)"
  pass "fm-notify-captain sends the emergency incident body and keeps the API token out of curl's argv"
}

test_success_urgent_differs_from_emergency() {
  local case_dir out stdin_log body
  case_dir=$(new_case success-urgent)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"
  stdin_log="$case_dir/curl-stdin.log"

  out=$(FM_TEST_CURL_HTTP_CODE=201 \
    FM_TEST_CURL_BODY='{"data":{"id":"993937400","type":"incident"}}' \
    FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_notify "$case_dir" --tier urgent "a routine urgent ping" 2>&1) \
    || fail "success-urgent: fm-notify-captain should succeed"

  assert_contains "$out" "paged: tier=urgent incident=993937400" "success-urgent: missing paged confirmation"

  body=$(body_from_config "$stdin_log")
  [ "$(printf '%s' "$body" | jq -r '.push, .critical_alert, .call' | tr '\n' ' ')" = "true true false " ] \
    || fail "success-urgent: urgent tier did not send a critical push without a call (got: $body)"
  [ "$(printf '%s' "$body" | jq -r 'has("team_wait")')" = "false" ] \
    || fail "success-urgent: urgent tier should not escalate to the whole team (got: $body)"
  # An incident with no name reaches the phone titled "API request", so the
  # default title matters as much as an explicit one.
  [ "$(printf '%s' "$body" | jq -r '.name')" = "Firstmate urgent" ] \
    || fail "success-urgent: urgent tier sent no default incident name (got: $body)"
  pass "fm-notify-captain sends a quieter incident for the urgent tier, still titled"
}

test_resolve_closes_the_incident() {
  local case_dir out stdin_log
  case_dir=$(new_case resolve-success)
  write_op_mock "$case_dir/fakebin"
  write_curl_mock "$case_dir/fakebin"
  stdin_log="$case_dir/curl-stdin.log"

  # __MISSING__ requester email: resolving needs no requester, so it must not
  # fail on a field only a new page reads.
  out=$(FM_TEST_CURL_HTTP_CODE=200 FM_TEST_CURL_BODY='{}' \
    FM_TEST_OP_USERNAME=__MISSING__ \
    FM_TEST_CURL_STDIN_LOG="$stdin_log" \
    run_notify "$case_dir" --resolve 993937396 2>&1) \
    || fail "resolve-success: fm-notify-captain --resolve should succeed"

  assert_contains "$out" "resolved: incident=993937396" "resolve-success: missing resolved confirmation"
  assert_grep 'incidents/993937396/resolve' "$stdin_log" "resolve-success: did not POST to the incident's resolve endpoint"
  pass "fm-notify-captain --resolve closes an open incident without needing a requester email"
}

test_dry_run_urgent_is_a_critical_push_without_a_call
test_dry_run_emergency_adds_a_call_and_team_escalation
test_dry_run_respects_team_wait_override
test_non_numeric_team_wait_rejected
test_zero_team_wait_rejected
test_dry_run_titles_the_page_when_no_title_is_given
test_dry_run_sends_nothing
test_missing_tier_fails_loud
test_invalid_tier_fails_loud
test_missing_message_fails_loud
test_non_numeric_resolve_id_fails_loud
test_resolve_with_tier_fails_loud
test_missing_op_service_account_token_fails_loud
test_op_binary_absent_fails_loud
test_missing_credential_field_names_it
test_missing_username_field_names_it
test_empty_field_fails_loud
test_non_2xx_response_prints_errors
test_accepted_page_without_incident_id_fails_loud
test_success_emergency_body_and_no_token_in_argv
test_success_urgent_differs_from_emergency
test_resolve_closes_the_incident
