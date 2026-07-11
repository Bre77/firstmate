#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh and bin/fm-pr-activity-poll.sh: the tracked-PR
# poll that must surface BOTH merge state and new PR activity (issue comments,
# inline review comments, review summaries) from anyone, as a check: wake.
#
# Matrix:
#   (a) arming a fresh task creates state/<id>.pr-activity-seen set to "now",
#       so a pre-arm history of old items never floods the first poll
#   (b) re-arming an existing task preserves its watermark instead of resetting it
#   (c) a poll surfaces new items across all three kinds (comment, review-comment,
#       review), formats them as `pr-comment <id> <author> (<kind>): <text>`,
#       filters out anything at/before the watermark, and advances the
#       watermark to the newest item's timestamp
#   (d) a long comment body is truncated to ~120 chars in the wake line
#   (e) merge takes precedence: once merged the check reports "merged" and
#       never invokes the activity poll (no gh api calls at all)
#   (f) a legacy merge-only check.sh (pre-dating the activity poll) still works
#       untouched until fm-pr-check.sh re-arms it
#   (g) re-arming a legacy task upgrades its check.sh to include the activity poll
#   (h) the activity-poll script defensively initializes a missing watermark
#       and stays silent on that first run, mirroring the arm-time contract
#   (i) a gh api error response (its JSON error body lands on stdout, not just
#       stderr, on a non-2xx status) must never be treated as activity data
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
ACTIVITY_POLL="$ROOT/bin/fm-pr-activity-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# Builds a fresh case dir with a state dir and a fakebin. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/fixtures"
  printf '%s\n' "$case_dir"
}

# write_gh_mock <fakebin>: a `gh` stub covering both call shapes this feature
# needs - `pr view ... --json state|headRefOid` for merge detection, and
# `api <path> ... -q <expr>` for activity polling. The api branch runs the
# REAL jq against a fixture file selected by path, executing the actual jq
# expression the script under test built - not a canned response - so a bug in
# that expression fails the test instead of hiding behind a dumb mock.
# FM_TEST_PR_STATE (default OPEN), FM_TEST_PR_HEAD, FM_TEST_FIXTURE_ISSUE_COMMENTS,
# FM_TEST_FIXTURE_REVIEW_COMMENTS, FM_TEST_FIXTURE_REVIEWS, and
# FM_TEST_GH_API_FAIL=1 (simulate a non-2xx response whose error body still
# lands on stdout) are read at call time.
write_gh_mock() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case " $* " in
    *'--json headRefOid'*)
      if [ -n "${FM_TEST_PR_HEAD:-}" ]; then printf '%s\n' "$FM_TEST_PR_HEAD"; exit 0; fi
      exit 1
      ;;
    *'--json state'*)
      printf '%s\n' "${FM_TEST_PR_STATE:-OPEN}"
      exit 0
      ;;
  esac
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  if [ "${FM_TEST_GH_API_FAIL:-}" = "1" ]; then
    printf '%s\n' '{"message":"Not Found","documentation_url":"https://docs.github.com","status":"404"}'
    exit 1
  fi
  path=$2
  case "$path" in
    repos/*/issues/*/comments) fixture=${FM_TEST_FIXTURE_ISSUE_COMMENTS:-} ;;
    repos/*/pulls/*/comments) fixture=${FM_TEST_FIXTURE_REVIEW_COMMENTS:-} ;;
    repos/*/pulls/*/reviews) fixture=${FM_TEST_FIXTURE_REVIEWS:-} ;;
    *) fixture= ;;
  esac
  [ -n "$fixture" ] && [ -f "$fixture" ] || exit 0
  jqexpr=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      -q) jqexpr=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  jq -r "$jqexpr" "$fixture" 2>/dev/null
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

run_check_sh() {
  local case_dir=$1 id=$2
  PATH="$case_dir/fakebin:$PATH" \
    bash "$case_dir/state/$id.check.sh"
}

run_activity_poll_directly() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ACTIVITY_POLL" "$@"
}

# assert_iso8601 <file> <msg>: content must look like a UTC ISO 8601 stamp.
assert_iso8601() {
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$1" || fail "$2"
}

test_arm_sets_watermark_now_and_no_flood() {
  local case_dir url
  case_dir=$(make_case arm-fresh)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/9"

  run_pr_check "$case_dir" task-x1 "$url" > "$case_dir/arm.out" 2>&1 \
    || fail "arm-fresh: fm-pr-check.sh should succeed"$'\n'"$(cat "$case_dir/arm.out")"

  assert_present "$case_dir/state/task-x1.pr-activity-seen" \
    "arm-fresh: watermark file must be created on first arm"
  assert_iso8601 "$case_dir/state/task-x1.pr-activity-seen" \
    "arm-fresh: watermark must look like a UTC ISO 8601 timestamp"

  # An item dated long before "now" must not flood the very first poll.
  cat > "$case_dir/fixtures/issue-comments.json" <<'JSON'
[{"created_at":"2000-01-01T00:00:00Z","user":{"login":"oldbot"},"body":"ancient history"}]
JSON
  printf '[]' > "$case_dir/fixtures/review-comments.json"
  printf '[]' > "$case_dir/fixtures/reviews.json"

  local out
  out=$(FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_check_sh "$case_dir" task-x1)
  [ -z "$out" ] || fail "arm-fresh: pre-arm history must not flood the first poll (got: $out)"
  pass "fm-pr-check.sh arms a fresh watermark at now and the first poll ignores pre-arm history"
}

test_rearm_preserves_existing_watermark() {
  local case_dir url
  case_dir=$(make_case rearm-preserve)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/11"
  mkdir -p "$case_dir/state"
  printf '2020-05-05T05:05:05Z\n' > "$case_dir/state/task-x2.pr-activity-seen"

  run_pr_check "$case_dir" task-x2 "$url" > /dev/null 2>&1 \
    || fail "rearm-preserve: fm-pr-check.sh should succeed"

  assert_grep '2020-05-05T05:05:05Z' "$case_dir/state/task-x2.pr-activity-seen" \
    "rearm-preserve: re-arming must not reset an existing watermark"
  pass "fm-pr-check.sh preserves an existing watermark across a re-arm"
}

test_poll_surfaces_new_activity_and_advances_watermark() {
  local case_dir url out
  case_dir=$(make_case new-activity)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/21"

  run_pr_check "$case_dir" task-x3 "$url" > /dev/null 2>&1 \
    || fail "new-activity: fm-pr-check.sh should succeed"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/state/task-x3.pr-activity-seen"

  cat > "$case_dir/fixtures/issue-comments.json" <<'JSON'
[
  {"created_at":"2019-01-01T00:00:00Z","user":{"login":"oldbot"},"body":"before the watermark, must not appear"},
  {"created_at":"2021-03-01T00:00:00Z","user":{"login":"brett"},"body":"a fresh captain comment on the artifact"}
]
JSON
  cat > "$case_dir/fixtures/review-comments.json" <<'JSON'
[{"created_at":"2021-03-01T00:00:01Z","user":{"login":"maintainer"},"body":"inline nit: rename this"}]
JSON
  cat > "$case_dir/fixtures/reviews.json" <<'JSON'
[{"submitted_at":"2021-03-01T00:00:02Z","user":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","body":""}]
JSON

  out=$(FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_check_sh "$case_dir" task-x3)

  assert_not_contains "$out" "oldbot" "new-activity: an item at/before the watermark must not surface"
  assert_contains "$out" "pr-comment task-x3 brett (comment): a fresh captain comment on the artifact" \
    "new-activity: issue comment wake line must match the contract format"
  assert_contains "$out" "pr-comment task-x3 maintainer (review-comment): inline nit: rename this" \
    "new-activity: inline review comment wake line must match the contract format"
  assert_contains "$out" "pr-comment task-x3 reviewer1 (review): CHANGES_REQUESTED" \
    "new-activity: a review with an empty body must fall back to its state"

  assert_grep '2021-03-01T00:00:02Z' "$case_dir/state/task-x3.pr-activity-seen" \
    "new-activity: watermark must advance to the newest surfaced item's timestamp"
  pass "poll surfaces new comments/review-comments/reviews from anyone, filters old items, and advances the watermark"
}

test_wake_line_truncates_long_body() {
  local case_dir url out long_body display
  case_dir=$(make_case long-body)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/31"

  run_pr_check "$case_dir" task-x4 "$url" > /dev/null 2>&1 \
    || fail "long-body: fm-pr-check.sh should succeed"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/state/task-x4.pr-activity-seen"

  long_body=$(printf 'x%.0s' $(seq 1 200))
  cat > "$case_dir/fixtures/issue-comments.json" <<JSON
[{"created_at":"2021-01-01T00:00:00Z","user":{"login":"chatty"},"body":"$long_body"}]
JSON
  printf '[]' > "$case_dir/fixtures/review-comments.json"
  printf '[]' > "$case_dir/fixtures/reviews.json"

  out=$(FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_check_sh "$case_dir" task-x4)

  display=${out#*"(comment): "}
  [ "${#display}" -le 120 ] || fail "long-body: wake line body must be truncated to ~120 chars (got ${#display})"
  assert_not_contains "$out" "$long_body" "long-body: the full untruncated body must not appear in the wake line"
  pass "a long comment body is truncated to ~120 chars in the wake line"
}

test_merge_takes_precedence_no_activity_poll() {
  local case_dir url out
  case_dir=$(make_case merge-precedence)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/41"

  run_pr_check "$case_dir" task-x5 "$url" > /dev/null 2>&1 \
    || fail "merge-precedence: fm-pr-check.sh should succeed"

  : > "$case_dir/gh.log"
  out=$(FM_TEST_PR_STATE=MERGED FM_TEST_GH_LOG="$case_dir/gh.log" run_check_sh "$case_dir" task-x5)
  [ "$out" = "merged" ] || fail "merge-precedence: a merged PR must report exactly 'merged' (got: $out)"
  assert_no_grep 'api ' "$case_dir/gh.log" \
    "merge-precedence: a merged PR must skip the activity poll entirely (no gh api calls)"
  pass "merge detection takes precedence and short-circuits the activity poll once merged"
}

test_legacy_merge_only_check_still_works() {
  local case_dir url
  case_dir=$(make_case legacy-check)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/51"
  mkdir -p "$case_dir/state"
  cat > "$case_dir/state/task-x6.check.sh" <<EOF
state=\$(gh pr view "$url" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF

  local out
  out=$(run_check_sh "$case_dir" task-x6)
  [ -z "$out" ] || fail "legacy-check: an un-merged legacy check.sh must stay silent (got: $out)"
  out=$(FM_TEST_PR_STATE=MERGED run_check_sh "$case_dir" task-x6)
  [ "$out" = "merged" ] || fail "legacy-check: a merged legacy check.sh must still report merged (got: $out)"
  pass "a pre-upgrade merge-only check.sh keeps working untouched until re-armed"
}

test_rearm_upgrades_legacy_check_script() {
  local case_dir url
  case_dir=$(make_case legacy-upgrade)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/61"
  mkdir -p "$case_dir/state"
  cat > "$case_dir/state/task-x7.check.sh" <<EOF
state=\$(gh pr view "$url" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF

  run_pr_check "$case_dir" task-x7 "$url" > /dev/null 2>&1 \
    || fail "legacy-upgrade: fm-pr-check.sh should succeed"

  assert_grep 'fm-pr-activity-poll.sh' "$case_dir/state/task-x7.check.sh" \
    "legacy-upgrade: re-arming a legacy task must upgrade its check.sh to the activity poll"
  assert_present "$case_dir/state/task-x7.pr-activity-seen" \
    "legacy-upgrade: re-arming a legacy task must create its watermark"
  pass "re-running fm-pr-check.sh upgrades an existing legacy task to the activity poll"
}

test_defensive_missing_watermark_initializes_silently() {
  local case_dir out
  case_dir=$(make_case defensive-init)
  write_gh_mock "$case_dir/fakebin"
  mkdir -p "$case_dir/state"

  out=$(run_activity_poll_directly "$case_dir" task-x8 "https://github.com/example/repo/pull/71")
  [ -z "$out" ] || fail "defensive-init: a first run with no watermark file must stay silent (got: $out)"
  assert_present "$case_dir/state/task-x8.pr-activity-seen" \
    "defensive-init: the poll script must create the watermark itself when missing"
  assert_iso8601 "$case_dir/state/task-x8.pr-activity-seen" \
    "defensive-init: the defensively-created watermark must look like a UTC ISO 8601 timestamp"
  pass "fm-pr-activity-poll.sh defensively initializes a missing watermark and stays silent on that run"
}

test_gh_api_error_body_not_treated_as_activity() {
  local case_dir url out
  case_dir=$(make_case api-error)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/81"

  run_pr_check "$case_dir" task-x9 "$url" > /dev/null 2>&1 \
    || fail "api-error: fm-pr-check.sh should succeed"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/state/task-x9.pr-activity-seen"

  out=$(FM_TEST_GH_API_FAIL=1 run_check_sh "$case_dir" task-x9)
  [ -z "$out" ] || fail "api-error: a non-2xx gh api response must never surface as activity (got: $out)"
  assert_grep '2020-01-01T00:00:00Z' "$case_dir/state/task-x9.pr-activity-seen" \
    "api-error: the watermark must not advance when gh api calls fail"
  pass "a gh api error response body is never mistaken for activity data"
}

test_arm_sets_watermark_now_and_no_flood
test_rearm_preserves_existing_watermark
test_poll_surfaces_new_activity_and_advances_watermark
test_wake_line_truncates_long_body
test_merge_takes_precedence_no_activity_poll
test_legacy_merge_only_check_still_works
test_rearm_upgrades_legacy_check_script
test_defensive_missing_watermark_initializes_silently
test_gh_api_error_body_not_treated_as_activity
