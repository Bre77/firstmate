#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against the PR head, not a
# stale local branch left behind after no-mistakes fix rounds push to the PR.
# A fork-only task (mode=fork-only in meta) branched off the fork remote's
# default instead of origin's, so its base and PR-head fetches must use the
# fork remote too; origin for a fork-only project is an unrelated upstream.
#
# Matrix:
#   (a) pr= + reachable pr_head= -> diff uses PR head, not the lagging local branch
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) mode=fork-only -> diff base is fork/<default>, not origin/<default>
#   (f) mode=fork-only + pr= without pr_head= -> PR head fetched from the fork
#       remote, not origin
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# make_fork_case <name>: like make_case, but the project clone has two
# unrelated remotes - "origin" (an upstream repo with its own history) and
# "fork" (the actual fork the fm/task-x1 branch was created from) - so a test
# can prove the diff base follows mode=fork-only to "fork", not "origin".
make_fork_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/fork.git" symbolic-ref HEAD refs/heads/main

  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'upstream-only\n' > "$case_dir/_seed/upstream.txt"
  git -C "$case_dir/_seed" add upstream.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "upstream baseline"
  git -C "$case_dir/_seed" push -q origin main

  # The fork's main is an unrelated history: this is what the task actually
  # branched from, and it must never be diffed against origin's baseline.
  git -C "$case_dir/_seed" checkout -q --orphan fork-main
  git -C "$case_dir/_seed" rm -qf upstream.txt
  printf 'fork-baseline\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "fork baseline"
  git -C "$case_dir/_seed" push -q "$case_dir/fork.git" fork-main:main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  git -C "$case_dir/project" fetch -q fork
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" fork/main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when pr_head is reachable"
  pass "fm-review-diff uses recorded pr_head instead of the lagging local branch"
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

test_fork_only_uses_fork_remote_base() {
  local case_dir out
  case_dir=$(make_fork_case fork-only-base)
  printf 'feature-change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "task change"
  write_task_meta "$case_dir" "mode=fork-only"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: fork/main' "fork-only-base: base must be fork/main, not origin/main"
  assert_contains "$out" '+feature-change' "fork-only-base: diff should show the task's own change"
  assert_not_contains "$out" 'upstream-only' "fork-only-base: diff must not include origin's unrelated history"
  assert_not_contains "$out" 'upstream.txt' "fork-only-base: diff must not include origin's unrelated history"
  pass "fm-review-diff bases a fork-only task's diff on fork/main, not origin/main"
}

test_fork_only_pr_head_fetched_from_fork_remote() {
  local case_dir out pr_sha
  case_dir=$(make_fork_case fork-only-pr-fetch)

  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "fix round on fork PR"
  pr_sha=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" branch -qD pr-head-tmp
  git -C "$case_dir/wt" push -q fork "$pr_sha:refs/pull/9/head"

  write_task_meta "$case_dir" "mode=fork-only" "pr=https://github.com/example/fork-repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "fork-only-pr-fetch: diff should use the PR head fetched from the fork remote"
  assert_not_contains "$out" 'stale-local' "fork-only-pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "fork-only-pr-fetch: should not warn when the fork-remote fetch succeeds"
  pass "fm-review-diff fetches a fork-only task's PR head from the fork remote, not origin"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_fork_only_uses_fork_remote_base
test_fork_only_pr_head_fetched_from_fork_remote
