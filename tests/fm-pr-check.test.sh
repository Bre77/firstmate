#!/usr/bin/env bash
# Tests for bin/fm-pr-activity-poll.sh (fork-only) and its wiring into the
# watcher's per-task check loop (bin/fm-watch.sh), which is the ONLY caller of
# this script in production: whenever fm-pr-poll.sh's static merge check finds
# a tracked PR still open, the watcher additionally runs the activity poll to
# surface new issue comments, inline review comments, and review summaries
# from anyone, as a check: wake. fm-pr-check.sh itself never touches the
# activity watermark; it only arms the byte-static merge poll
# (tests/fm-pr-check-security.test.sh owns that mechanism).
#
# Matrix:
#   (a) re-arming an existing task never resets its activity watermark, since
#       fm-pr-check.sh does not manage it at all
#   (b) the activity-poll script defensively initializes a missing watermark
#       and stays silent on that first run (no pre-arm history flood)
#   (c) a direct poll surfaces new items across all three kinds (comment,
#       review-comment, review), formats them as
#       `pr-comment <id> <author> (<kind>): <text>`, filters out anything
#       at/before the watermark, and advances the watermark to the newest
#       item's timestamp
#   (d) a long comment body is truncated to ~120 chars in the wake line
#   (e) a gh api error response (its JSON error body lands on stdout, not just
#       stderr, on a non-2xx status) must never be treated as activity data
#   (f) the watcher runs the activity poll and surfaces a `pr-comment` wake
#       line only when the tracked PR is still open
#   (g) merge takes precedence in the watcher: once merged, the merge poll
#       reports "merged" and the watcher never invokes the activity poll (no
#       gh api calls at all)
#   (h) a chatgpt-codex-connector review on a newer commit surfaces through
#       the separate bot-review cursor even when its own submitted_at already
#       lags a self/crew reply that advanced the general watermark past it
#   (i) a first-sighted bot review seeds the cursor silently, matching the
#       general watermark's own no-flood behavior on arm
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
ACTIVITY_POLL="$ROOT/bin/fm-pr-activity-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# Builds a fresh case dir with a home (state/data/config), a task meta, and a
# fakebin. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/fixtures"
  fm_write_meta "$case_dir/home/state/task-x.meta" \
    "window=fm-task-x" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# write_gh_mock <fakebin>: a `gh` stub covering both call shapes the merge
# check and the activity poll need - `pr view ... --json state|headRefOid`
# for merge detection, and `api <path> ... -q <expr>` for activity polling.
# The api branch runs the REAL jq against a fixture file selected by path,
# executing the actual jq expression the script under test built - not a
# canned response - so a bug in that expression fails the test instead of
# hiding behind a dumb mock. FM_TEST_PR_STATE (default OPEN), FM_TEST_PR_HEAD,
# FM_TEST_FIXTURE_ISSUE_COMMENTS, FM_TEST_FIXTURE_REVIEW_COMMENTS,
# FM_TEST_FIXTURE_REVIEWS, and FM_TEST_GH_API_FAIL=1 (simulate a non-2xx
# response whose error body still lands on stdout) are read at call time.
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
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

run_activity_poll_directly() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
    "$ACTIVITY_POLL" "$@"
}

# Runs one bounded real watcher cycle against the real $ROOT (so the fork-only
# bin/fm-pr-activity-poll.sh is reachable at its real path), bounded by a hard
# wall-clock timeout so a hang never wedges the suite.
run_watcher_bounded() {
  local case_dir=$1 fakebin=$2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 5; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_TEST_GH_LOG="$case_dir/gh.log" \
      PATH="$fakebin:$BASE_PATH" "$WATCH"
}

# assert_iso8601 <file> <msg>: content must look like a UTC ISO 8601 stamp.
assert_iso8601() {
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$1" || fail "$2"
}

test_rearm_does_not_touch_watermark() {
  local case_dir url
  case_dir=$(make_case rearm-preserve)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/11"
  printf '2020-05-05T05:05:05Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

  run_pr_check "$case_dir" task-x "$url" > /dev/null 2>&1 \
    || fail "rearm-preserve: fm-pr-check.sh should succeed"

  assert_grep '2020-05-05T05:05:05Z' "$case_dir/home/state/task-x.pr-activity-seen" \
    "rearm-preserve: fm-pr-check.sh must never touch the activity watermark"
  pass "fm-pr-check.sh never touches the activity watermark, on first arm or re-arm"
}

test_defensive_missing_watermark_initializes_silently() {
  local case_dir out
  case_dir=$(make_case defensive-init)
  write_gh_mock "$case_dir/fakebin"

  out=$(run_activity_poll_directly "$case_dir" task-x "https://github.com/example/repo/pull/71")
  [ -z "$out" ] || fail "defensive-init: a first run with no watermark file must stay silent (got: $out)"
  assert_present "$case_dir/home/state/task-x.pr-activity-seen" \
    "defensive-init: the poll script must create the watermark itself when missing"
  assert_iso8601 "$case_dir/home/state/task-x.pr-activity-seen" \
    "defensive-init: the defensively-created watermark must look like a UTC ISO 8601 timestamp"
  pass "fm-pr-activity-poll.sh defensively initializes a missing watermark and stays silent on that run"
}

test_poll_surfaces_new_activity_and_advances_watermark() {
  local case_dir url out
  case_dir=$(make_case new-activity)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/21"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

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
        run_activity_poll_directly "$case_dir" task-x "$url")

  assert_not_contains "$out" "oldbot" "new-activity: an item at/before the watermark must not surface"
  assert_contains "$out" "pr-comment task-x brett (comment): a fresh captain comment on the artifact" \
    "new-activity: issue comment wake line must match the contract format"
  assert_contains "$out" "pr-comment task-x maintainer (review-comment): inline nit: rename this" \
    "new-activity: inline review comment wake line must match the contract format"
  assert_contains "$out" "pr-comment task-x reviewer1 (review): CHANGES_REQUESTED" \
    "new-activity: a review with an empty body must fall back to its state"

  assert_grep '2021-03-01T00:00:02Z' "$case_dir/home/state/task-x.pr-activity-seen" \
    "new-activity: watermark must advance to the newest surfaced item's timestamp"
  pass "poll surfaces new comments/review-comments/reviews from anyone, filters old items, and advances the watermark"
}

test_wake_line_truncates_long_body() {
  local case_dir url out long_body display
  case_dir=$(make_case long-body)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/31"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

  long_body=$(printf 'x%.0s' $(seq 1 200))
  cat > "$case_dir/fixtures/issue-comments.json" <<JSON
[{"created_at":"2021-01-01T00:00:00Z","user":{"login":"chatty"},"body":"$long_body"}]
JSON
  printf '[]' > "$case_dir/fixtures/review-comments.json"
  printf '[]' > "$case_dir/fixtures/reviews.json"

  out=$(FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_activity_poll_directly "$case_dir" task-x "$url")

  display=${out#*"(comment): "}
  [ "${#display}" -le 120 ] || fail "long-body: wake line body must be truncated to ~120 chars (got ${#display})"
  assert_not_contains "$out" "$long_body" "long-body: the full untruncated body must not appear in the wake line"
  pass "a long comment body is truncated to ~120 chars in the wake line"
}

test_gh_api_error_body_not_treated_as_activity() {
  local case_dir url out
  case_dir=$(make_case api-error)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/81"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

  out=$(FM_TEST_GH_API_FAIL=1 run_activity_poll_directly "$case_dir" task-x "$url")
  [ -z "$out" ] || fail "api-error: a non-2xx gh api response must never surface as activity (got: $out)"
  assert_grep '2020-01-01T00:00:00Z' "$case_dir/home/state/task-x.pr-activity-seen" \
    "api-error: the watermark must not advance when gh api calls fail"
  pass "a gh api error response body is never mistaken for activity data"
}

test_watcher_merge_takes_precedence_no_activity_poll() {
  local case_dir url out rc
  case_dir=$(make_case watcher-merge-precedence)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/41"

  run_pr_check "$case_dir" task-x "$url" > /dev/null 2>&1 \
    || fail "watcher-merge-precedence: fm-pr-check.sh should succeed"

  : > "$case_dir/gh.log"
  set +e
  out=$(FM_TEST_PR_STATE=MERGED run_watcher_bounded "$case_dir" "$case_dir/fakebin")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher-merge-precedence: bounded watcher did not complete (rc=$rc): $out"
  assert_contains "$out" "check: $case_dir/home/state/task-x.check.sh: merged" \
    "watcher-merge-precedence: a merged PR must wake with exactly 'merged'"
  assert_no_grep 'api ' "$case_dir/gh.log" \
    "watcher-merge-precedence: a merged PR must skip the activity poll entirely (no gh api calls)"
  pass "the watcher's merge poll takes precedence and short-circuits the activity poll once merged"
}

test_watcher_surfaces_pr_comment_when_open() {
  local case_dir url out rc
  case_dir=$(make_case watcher-open-activity)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/51"

  run_pr_check "$case_dir" task-x "$url" > /dev/null 2>&1 \
    || fail "watcher-open-activity: fm-pr-check.sh should succeed"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

  cat > "$case_dir/fixtures/issue-comments.json" <<'JSON'
[{"created_at":"2021-03-01T00:00:00Z","user":{"login":"brett"},"body":"a fresh captain comment on the artifact"}]
JSON
  printf '[]' > "$case_dir/fixtures/review-comments.json"
  printf '[]' > "$case_dir/fixtures/reviews.json"

  set +e
  out=$(FM_TEST_PR_STATE=OPEN \
        FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_watcher_bounded "$case_dir" "$case_dir/fakebin")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher-open-activity: bounded watcher did not complete (rc=$rc): $out"
  assert_contains "$out" "pr-comment task-x brett (comment): a fresh captain comment on the artifact" \
    "watcher-open-activity: an open PR's new comment must reach the watcher's wake line"
  assert_grep 'pr view' "$case_dir/gh.log" \
    "watcher-open-activity: the merge check must still have run before the activity poll"
  pass "the watcher runs the activity poll and surfaces a new PR comment while the tracked PR is still open"
}

test_bot_review_cursor_seeds_silently_on_first_sighting() {
  local case_dir url out
  case_dir=$(make_case bot-cursor-seed)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/61"
  printf '2020-01-01T00:00:00Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

  cat > "$case_dir/fixtures/reviews.json" <<'JSON'
[{"submitted_at":"2019-06-01T00:00:00Z","user":{"login":"chatgpt-codex-connector"},"commit_id":"sha-preexisting","state":"COMMENTED","body":"pre-arm bot review, must not appear"}]
JSON
  printf '[]' > "$case_dir/fixtures/issue-comments.json"
  printf '[]' > "$case_dir/fixtures/review-comments.json"

  out=$(FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_activity_poll_directly "$case_dir" task-x "$url")

  [ -z "$out" ] || fail "bot-cursor-seed: a first-sighted bot review must seed the cursor silently (got: $out)"
  assert_grep 'sha-preexisting' "$case_dir/home/state/task-x.pr-bot-review-seen" \
    "bot-cursor-seed: the cursor file must be seeded with the newest bot review's commit SHA"
  pass "a first-sighted bot review seeds the cursor silently instead of surfacing pre-arm history"
}

test_bot_review_surfaces_despite_self_reply_watermark_race() {
  local case_dir url out
  case_dir=$(make_case bot-cursor-race)
  write_gh_mock "$case_dir/fakebin"
  url="https://github.com/example/repo/pull/91"

  # Round 2 bot review already surfaced and recorded by the cursor in an
  # earlier poll; the general watermark already sits past a later self/crew
  # reply too, exactly reproducing the captain-caught scenario: node #7's
  # crew replied on its own PR as Bre77 after round 2, advancing the general
  # watermark past a round-3 review whose own submitted_at lags behind it.
  printf 'sha-round2\n' > "$case_dir/home/state/task-x.pr-bot-review-seen"
  printf '2021-06-01T00:00:00Z\n' > "$case_dir/home/state/task-x.pr-activity-seen"

  cat > "$case_dir/fixtures/reviews.json" <<'JSON'
[{"submitted_at":"2021-05-01T00:00:00Z","user":{"login":"chatgpt-codex-connector"},"commit_id":"sha-round3","state":"CHANGES_REQUESTED","body":"round 3: still missing error handling"}]
JSON
  printf '[]' > "$case_dir/fixtures/issue-comments.json"
  printf '[]' > "$case_dir/fixtures/review-comments.json"

  out=$(FM_TEST_FIXTURE_ISSUE_COMMENTS="$case_dir/fixtures/issue-comments.json" \
        FM_TEST_FIXTURE_REVIEW_COMMENTS="$case_dir/fixtures/review-comments.json" \
        FM_TEST_FIXTURE_REVIEWS="$case_dir/fixtures/reviews.json" \
        run_activity_poll_directly "$case_dir" task-x "$url")

  assert_contains "$out" "pr-comment task-x chatgpt-codex-connector (review): round 3: still missing error handling" \
    "bot-cursor-race: a newer bot review must surface via the cursor even though its own timestamp already lags the general watermark"
  assert_grep 'sha-round3' "$case_dir/home/state/task-x.pr-bot-review-seen" \
    "bot-cursor-race: the cursor must advance to the newer bot review's commit SHA"
  assert_grep '2021-06-01T00:00:00Z' "$case_dir/home/state/task-x.pr-activity-seen" \
    "bot-cursor-race: the general watermark is untouched when nothing else is new"
  pass "a new bot review on a newer commit surfaces via the cursor despite an intervening self/crew reply's timestamp race"
}

test_rearm_does_not_touch_watermark
test_defensive_missing_watermark_initializes_silently
test_poll_surfaces_new_activity_and_advances_watermark
test_wake_line_truncates_long_body
test_gh_api_error_body_not_treated_as_activity
test_watcher_merge_takes_precedence_no_activity_poll
test_watcher_surfaces_pr_comment_when_open
test_bot_review_cursor_seeds_silently_on_first_sighting
test_bot_review_surfaces_despite_self_reply_watermark_race
