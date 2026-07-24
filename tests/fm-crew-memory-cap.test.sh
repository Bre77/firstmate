#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's per-crew memory cap.
#
# fm-spawn wraps every ship/scout AGENT launch in a `systemd-run --user --scope`
# so a runaway crew (and every child process it spawns) is bounded to one
# cgroup instead of being able to exhaust host memory. See the fm-spawn.sh
# header comment and docs/crew-memory-cap.md for the full rationale and the
# empirical verification these defaults are based on.
#
# These tests drive fm-spawn through meta writing and launch construction with
# a fake tmux pane (as fm-spawn-dispatch-profile.test.sh does) plus a fake
# `systemd-run` whose exit code simulates a host with/without a reachable user
# systemd instance. The fake tmux captures the literal launch command sent
# with `tmux send-keys -l`, so assertions pin the exact command firstmate would
# run, without starting any real harness or systemd scope.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-memory-cap)

# make_spawn_fakebin <dir> <systemd-run-exit-code>: a fake tmux (captures the
# literal send-keys -l payload to FM_FAKE_LAUNCH_LOG) plus a fake systemd-run
# that always exits with the given code, simulating either a healthy user
# systemd instance (0) or one that is unreachable/unusable (non-zero).
make_spawn_fakebin() {
  local dir=$1 rc=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/systemd-run" <<SH
#!/usr/bin/env bash
exit $rc
SH
  chmod +x "$fakebin/systemd-run"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 systemd_run_rc=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$systemd_run_rc")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  env -u FM_CREW_MEMORY_HIGH -u FM_CREW_MEMORY_MAX -u FM_CREW_MEMORY_SWAP \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_spawn_with_env() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

expected_unwrapped_claude_launch() {
  local brief=$1
  printf '%s' "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$brief')\""
}

# Given a full launch string wrapped as:
#   systemd-run --user --scope --slice=firstmate-crew.slice -p MemoryHigh=<h> -p MemoryMax=<m> -p MemorySwapMax=<s> -- bash -c '<quoted inner>'
# extract <h>, <m>, <s>, and the INNER command recovered by a real shell
# unquote (not a hand-rolled parser), so the test proves the wrap round-trips
# through an actual shell rather than merely resembling the right shape.
assert_wrapped_launch() {
  local launch=$1 expect_high=$2 expect_max=$3 expect_swap=$4 expect_inner=$5 msg_ctx=$6
  local prefix="systemd-run --user --scope --slice=firstmate-crew.slice -p MemoryHigh=$expect_high -p MemoryMax=$expect_max -p MemorySwapMax=$expect_swap -- bash -c "
  case "$launch" in
    "$prefix"*) : ;;
    *) fail "$msg_ctx: launch does not start with expected systemd-run prefix"$'\n'"--- prefix ---"$'\n'"$prefix"$'\n'"--- actual ---"$'\n'"$launch" ;;
  esac
  local quoted_inner=${launch#"$prefix"}
  local recovered
  eval "recovered=$quoted_inner"
  [ "$recovered" = "$expect_inner" ] \
    || fail "$msg_ctx: inner command did not round-trip through shell quoting"$'\n'"--- expected ---"$'\n'"$expect_inner"$'\n'"--- recovered ---"$'\n'"$recovered"
}

test_ship_spawn_wraps_launch_with_default_caps() {
  local rec id out status launch expected_inner
  id=memcap-ship-z1
  rec=$(make_spawn_case memcap-ship-default 0 "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn with a healthy systemd-run should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "spawn did not report ship kind"
  assert_not_contains "$out" "without a per-crew memory cap" "healthy systemd-run should not trigger the fallback warning"

  launch=$(cat "$LAUNCH_LOG")
  expected_inner=$(expected_unwrapped_claude_launch "$HOME_DIR/data/$id/brief.md")
  assert_wrapped_launch "$launch" 8G 12G 2G "$expected_inner" "ship spawn default caps"
  pass "ship spawn wraps the launch in a systemd --user scope with the 8G/12G/2G defaults"
}

test_scout_spawn_is_also_wrapped() {
  local rec id out status launch expected_inner
  id=memcap-scout-z2
  rec=$(make_spawn_case memcap-scout 0 "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn with a healthy systemd-run should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=scout" "spawn did not report scout kind"

  launch=$(cat "$LAUNCH_LOG")
  expected_inner=$(expected_unwrapped_claude_launch "$HOME_DIR/data/$id/brief.md")
  assert_wrapped_launch "$launch" 8G 12G 2G "$expected_inner" "scout spawn default caps"
  pass "scout spawn is wrapped in a memory-capped scope exactly like a ship spawn"
}

test_env_vars_override_default_caps() {
  local rec id out status launch expected_inner
  id=memcap-override-z3
  rec=$(make_spawn_case memcap-override 0 "$id")
  read_case_record "$rec"

  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_CREW_MEMORY_HIGH=1G FM_CREW_MEMORY_MAX=2G FM_CREW_MEMORY_SWAP=512M \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 0 "$status" "ship spawn with overridden memory env vars should succeed"

  launch=$(cat "$LAUNCH_LOG")
  expected_inner=$(expected_unwrapped_claude_launch "$HOME_DIR/data/$id/brief.md")
  assert_wrapped_launch "$launch" 1G 2G 512M "$expected_inner" "ship spawn overridden caps"
  pass "FM_CREW_MEMORY_HIGH/_MAX/_SWAP override the 8G/12G/2G defaults"
}

test_unavailable_systemd_run_falls_back_unwrapped_with_warning() {
  local rec id out status launch expected
  id=memcap-fallback-z4
  rec=$(make_spawn_case memcap-fallback 1 "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn must still succeed when systemd-run --user is unavailable"
  assert_contains "$out" "warning: systemd-run --user is unavailable on this host" \
    "spawn did not warn about the missing per-crew memory cap"
  assert_contains "$out" "without a per-crew memory cap" "fallback warning missing its explanation"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "fallback spawn did not still report success"

  launch=$(cat "$LAUNCH_LOG")
  expected=$(expected_unwrapped_claude_launch "$HOME_DIR/data/$id/brief.md")
  [ "$launch" = "$expected" ] \
    || fail "fallback launch should be byte-identical to the unwrapped claude launch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "spawn falls back to an unwrapped launch, with a warning, when systemd-run --user is unavailable"
}

test_secondmate_agent_launch_is_not_wrapped() {
  local rec id sm out status launch expected_prefix
  id=memcap-secondmate-z5
  rec=$(make_spawn_case memcap-secondmate 0 "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn_with_env "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" "secondmate spawn did not report kind=secondmate"

  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "systemd-run" \
    "the secondmate AGENT's own launch must not be wrapped in a memory-capped scope"
  expected_prefix="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME="
  case "$launch" in
    "$expected_prefix"*) : ;;
    *) fail "secondmate launch missing its FM_HOME env prefix"$'\n'"--- actual ---"$'\n'"$launch" ;;
  esac
  pass "a --secondmate AGENT launch is not wrapped (only the crewmates it spawns are, via this same script)"
}

test_ship_spawn_wraps_launch_with_default_caps
test_scout_spawn_is_also_wrapped
test_env_vars_override_default_caps
test_unavailable_systemd_run_falls_back_unwrapped_with_warning
test_secondmate_agent_launch_is_not_wrapped

echo "# all fm-crew-memory-cap tests passed"
