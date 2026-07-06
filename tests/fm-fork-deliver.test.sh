#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-deliver.sh: the codified fork-only delivery
# path. The helper must run the local gate, then push the current branch to the
# fork remote and open a PR into the fork's default branch - and it must refuse
# to deliver from a detached HEAD or the fork default branch, never open a PR
# when the gate fails, and parse the fork <owner>/<repo> from the remote URL.
#
# The fork remote is a GitHub-shaped URL (so <owner>/<repo> parsing is exercised)
# whose pushes are redirected to a local bare repo via git pushInsteadOf, so real
# pushes succeed offline while `git remote get-url` still returns the GitHub URL.
# Every case passes --check or --skip-validate so the heavy default gate (which
# would recurse into tests/*.test.sh) never runs here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

DELIVER="$ROOT/bin/fm-fork-deliver.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-deliver)

# make_case <name> [remote-url]: build case_dir with a repo on feature branch
# fm/feat-x1, a fork remote (default GitHub https, pushes redirected to a local
# bare repo), and a fakebin gh-axi that logs its invocation. Echoes case_dir.
make_case() {
  local name=$1 url=${2:-https://github.com/Bre77/firstmate}
  local case_dir="$TMP_ROOT/$name" repo bare fakebin
  repo="$case_dir/repo"; bare="$case_dir/fork.git"; fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git init --bare -q "$bare"
  # Redirect only pushes to the local bare repo; get-url still returns the URL.
  git -C "$repo" config "url.$bare.pushInsteadOf" "$url"
  git -C "$repo" remote add fork "$url"
  git -C "$repo" checkout -q -b fm/feat-x1
  git -C "$repo" commit -q --allow-empty -m change
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

run_deliver() {
  local case_dir=$1; shift
  ( cd "$case_dir/repo" \
    && PATH="$case_dir/fakebin:$PATH" FM_TEST_GH_LOG="$case_dir/gh.log" \
       "$DELIVER" "$@" )
}

pushed_branch() { git -C "$1/fork.git" rev-parse --verify --quiet refs/heads/fm/feat-x1 >/dev/null 2>&1; }

test_happy_path_pushes_and_opens_fork_pr() {
  local case_dir rc
  case_dir=$(make_case happy)
  set +e
  run_deliver "$case_dir" --check 'exit 0' --title "fork feat" --body "why" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "happy: fm-fork-deliver should succeed"
  pushed_branch "$case_dir" || fail "happy: branch was not pushed to the fork bare repo"
  assert_present "$case_dir/gh.log" "happy: gh-axi pr create was not invoked"
  grep -qxF 'pr create --repo Bre77/firstmate --base main --head fm/feat-x1 --title fork feat --body why' \
    "$case_dir/gh.log" || fail "happy: gh-axi pr create args wrong: $(cat "$case_dir/gh.log")"
  pass "fm-fork-deliver pushes the branch and opens a PR into the fork with parsed owner/repo"
}

test_body_file_variant() {
  local case_dir
  case_dir=$(make_case bodyfile)
  printf 'body from file\n' > "$case_dir/pr-body.md"
  run_deliver "$case_dir" --check 'exit 0' --title "t" --body-file "$case_dir/pr-body.md" \
    > "$case_dir/out" 2> "$case_dir/err" || fail "bodyfile: fm-fork-deliver failed"
  grep -qF -- "--body-file $case_dir/pr-body.md" "$case_dir/gh.log" \
    || fail "bodyfile: --body-file was not forwarded to gh-axi: $(cat "$case_dir/gh.log")"
  pass "fm-fork-deliver forwards --body-file to gh-axi pr create"
}

test_ssh_url_slug_parsed() {
  local case_dir
  case_dir=$(make_case ssh git@github.com:Bre77/firstmate.git)
  run_deliver "$case_dir" --check 'exit 0' --title "t" --body "b" \
    > "$case_dir/out" 2> "$case_dir/err" || fail "ssh: fm-fork-deliver failed"
  grep -qF -- '--repo Bre77/firstmate ' "$case_dir/gh.log" \
    || fail "ssh: owner/repo not parsed from git@ URL: $(cat "$case_dir/gh.log")"
  pass "fm-fork-deliver parses owner/repo from a git@github.com: fork URL"
}

test_draft_flag_forwarded() {
  local case_dir
  case_dir=$(make_case draft)
  run_deliver "$case_dir" --check 'exit 0' --title "t" --body "b" --draft \
    > "$case_dir/out" 2> "$case_dir/err" || fail "draft: fm-fork-deliver failed"
  grep -qF -- '--draft' "$case_dir/gh.log" || fail "draft: --draft not forwarded: $(cat "$case_dir/gh.log")"
  pass "fm-fork-deliver forwards --draft to gh-axi pr create"
}

test_gate_failure_aborts_before_delivery() {
  local case_dir rc
  case_dir=$(make_case gate-fail)
  set +e
  run_deliver "$case_dir" --check 'exit 1' --title "t" --body "b" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "gate-fail: a failing gate must abort delivery"
  ! pushed_branch "$case_dir" || fail "gate-fail: branch was pushed despite gate failure"
  assert_absent "$case_dir/gh.log" "gate-fail: gh-axi was invoked despite gate failure"
  assert_grep "validation gate failed" "$case_dir/err" "gate-fail: no gate-failure message"
  pass "fm-fork-deliver aborts before push/PR when the gate fails"
}

test_validate_only_runs_gate_but_no_delivery() {
  local case_dir rc
  case_dir=$(make_case validate-only)
  set +e
  run_deliver "$case_dir" --validate-only --check 'exit 0' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "validate-only: should pass the gate"
  ! pushed_branch "$case_dir" || fail "validate-only: branch was pushed"
  assert_absent "$case_dir/gh.log" "validate-only: gh-axi was invoked"
  assert_grep "validate-only" "$case_dir/out" "validate-only: no confirmation line"
  pass "fm-fork-deliver --validate-only runs the gate without push or PR"
}

test_skip_validate_delivers_without_running_check() {
  local case_dir
  case_dir=$(make_case skip-validate)
  # --check would fail, but --skip-validate means it is never run.
  run_deliver "$case_dir" --skip-validate --check 'exit 1' --title "t" --body "b" \
    > "$case_dir/out" 2> "$case_dir/err" || fail "skip-validate: fm-fork-deliver failed"
  pushed_branch "$case_dir" || fail "skip-validate: branch was not pushed"
  assert_present "$case_dir/gh.log" "skip-validate: gh-axi pr create was not invoked"
  pass "fm-fork-deliver --skip-validate opens the PR without running the gate"
}

test_refuses_detached_head() {
  local case_dir rc
  case_dir=$(make_case detached)
  git -C "$case_dir/repo" checkout -q --detach
  set +e
  run_deliver "$case_dir" --skip-validate --title "t" --body "b" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "detached: must refuse a detached HEAD"
  assert_grep "HEAD is detached" "$case_dir/err" "detached: wrong refusal message"
  assert_absent "$case_dir/gh.log" "detached: gh-axi was invoked"
  pass "fm-fork-deliver refuses to deliver from a detached HEAD"
}

test_refuses_delivering_from_default_branch() {
  local case_dir rc
  case_dir=$(make_case on-default)
  git -C "$case_dir/repo" checkout -q main
  set +e
  run_deliver "$case_dir" --skip-validate --title "t" --body "b" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "on-default: must refuse delivering from the fork default branch"
  assert_grep "refusing to deliver from the fork default branch" "$case_dir/err" \
    "on-default: wrong refusal message"
  assert_absent "$case_dir/gh.log" "on-default: gh-axi was invoked"
  pass "fm-fork-deliver refuses to deliver from the fork default branch"
}

test_refuses_missing_fork_remote() {
  local case_dir rc
  case_dir=$(make_case no-remote)
  git -C "$case_dir/repo" remote remove fork
  set +e
  run_deliver "$case_dir" --skip-validate --title "t" --body "b" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-remote: must refuse when the fork remote is absent"
  assert_grep "fork remote 'fork' not found" "$case_dir/err" "no-remote: wrong refusal message"
  pass "fm-fork-deliver refuses when the fork remote does not exist"
}

test_requires_title_before_push() {
  local case_dir rc
  case_dir=$(make_case no-title)
  set +e
  run_deliver "$case_dir" --skip-validate --body "b" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-title: must require --title to open a PR"
  ! pushed_branch "$case_dir" || fail "no-title: branch was pushed without a title"
  assert_grep "title is required" "$case_dir/err" "no-title: wrong message"
  pass "fm-fork-deliver requires --title before pushing or opening a PR"
}

test_requires_body_before_push() {
  local case_dir rc
  case_dir=$(make_case no-body)
  set +e
  run_deliver "$case_dir" --skip-validate --title "t" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-body: must require a body to open a PR"
  ! pushed_branch "$case_dir" || fail "no-body: branch was pushed without a body"
  assert_grep "one of --body or --body-file is required" "$case_dir/err" "no-body: wrong message"
  pass "fm-fork-deliver requires a body before pushing or opening a PR"
}

test_body_and_body_file_mutually_exclusive() {
  local case_dir rc
  case_dir=$(make_case both-bodies)
  printf 'x\n' > "$case_dir/b.md"
  set +e
  run_deliver "$case_dir" --skip-validate --title "t" --body "b" --body-file "$case_dir/b.md" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "both-bodies: --body and --body-file must be mutually exclusive"
  assert_grep "only one of --body or --body-file" "$case_dir/err" "both-bodies: wrong message"
  pass "fm-fork-deliver rejects both --body and --body-file together"
}

test_validate_and_skip_mutually_exclusive() {
  local case_dir rc
  case_dir=$(make_case both-validate)
  set +e
  run_deliver "$case_dir" --skip-validate --validate-only \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "both-validate: --skip-validate and --validate-only must conflict"
  assert_grep "mutually exclusive" "$case_dir/err" "both-validate: wrong message"
  pass "fm-fork-deliver rejects --skip-validate with --validate-only"
}

test_default_gate_errors_when_nothing_applies() {
  local case_dir rc
  case_dir=$(make_case no-gate)
  set +e
  run_deliver "$case_dir" --validate-only \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-gate: default gate must error when no scripts or tests exist"
  assert_grep "no default gate applies" "$case_dir/err" "no-gate: wrong message"
  pass "fm-fork-deliver default gate errors (pass --check) when nothing is validatable"
}

test_happy_path_pushes_and_opens_fork_pr
test_body_file_variant
test_ssh_url_slug_parsed
test_draft_flag_forwarded
test_gate_failure_aborts_before_delivery
test_validate_only_runs_gate_but_no_delivery
test_skip_validate_delivers_without_running_check
test_refuses_detached_head
test_refuses_delivering_from_default_branch
test_refuses_missing_fork_remote
test_requires_title_before_push
test_requires_body_before_push
test_body_and_body_file_mutually_exclusive
test_validate_and_skip_mutually_exclusive
test_default_gate_errors_when_nothing_applies
