#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's concurrent ship/scout admission cap
# (bin/fm-crew-admission-lib.sh).
#
# The cap counts already-live ship/scout crews recorded in state/*.meta and
# refuses a NEW ship/scout launch once a configurable ceiling is met, so a
# burst of concurrent launches queues instead of piling straight onto the
# host. See docs/configuration.md "Concurrent crew admission cap" for the
# full contract this exercises.
#
# These tests seed state/*.meta fixtures directly (no real prior spawns) and
# drive the real fm-spawn.sh for the new launch under test, with a fake tmux
# whose display-message '#{pane_id}' probe reports a target dead only when it
# is named in a test-controlled list (FM_FAKE_DEAD_TARGETS) and alive
# otherwise - matching real tmux, where a target exists unless something
# proves it gone, so the new task's own freshly created window (which
# fm-spawn.sh itself re-checks before sending Enter) needs no special-casing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-admission-cap)

# make_admission_fakebin <dir>: a fake tmux whose '#{pane_id}' liveness probe
# for a -t <target> query fails only when <target> is one of the
# comma-separated FM_FAKE_DEAD_TARGETS (default: everything is alive),
# independent of the bare '#S' session-name probe and the new task's own
# '#{pane_current_path}' probe (FM_FAKE_PANE_PATH). Also drops trivial
# systemd-run/treehouse stubs so a real ship/scout spawn under test completes
# end to end.
make_admission_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
if [ "${1:-}" = display-message ]; then
  case "$*" in
    *"#{pane_id}"*)
      target=
      prev=
      for a in "$@"; do
        [ "$prev" = "-t" ] && target=$a
        prev=$a
      done
      case ",${FM_FAKE_DEAD_TARGETS:-}," in
        *",$target,"*) exit 1 ;;
        *) printf '%%1\n'; exit 0 ;;
      esac
      ;;
    *) printf 'firstmate\n'; exit 0 ;;
  esac
fi
case "${1:-}" in
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
  fm_fake_exit0 "$fakebin" treehouse systemd-run
  printf '%s\n' "$fakebin"
}

# make_admission_case <name>: fresh home/project/worktree/fakebin/launchlog
# quintet, "<case_dir>|<home>|<proj>|<wt>|<fakebin>|<launchlog>".
make_admission_case() {
  local name=$1 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_admission_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# seed_live_meta <home> <id> <target>: a kind=ship meta whose recorded
# endpoint is alive unless <target> is listed in FM_FAKE_DEAD_TARGETS.
seed_live_meta() {
  local home=$1 id=$2 target=$3
  fm_write_meta "$home/state/$id.meta" "kind=ship" "window=$target"
}

# seed_inflight_meta <home> <id>: a kind=ship meta with no window recorded
# yet - a spawn still mid-flight elsewhere - which always counts as live.
seed_inflight_meta() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" "kind=ship"
}

# seed_secondmate_meta <home> <id> <target>: a kind=secondmate meta, which
# must never count toward the cap.
seed_secondmate_meta() {
  local home=$1 id=$2 target=$3
  fm_write_meta "$home/state/$id.meta" "kind=secondmate" "window=$target"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 dead=$5 id=$6
  shift 5
  : > "$launchlog"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_DEAD_TARGETS="$dead" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

test_ship_spawn_refused_at_default_cap() {
  local rec i out status
  rec=$(make_admission_case admit-at-cap)
  read_case_record "$rec"

  for i in 1 2 3 4 5 6; do
    seed_live_meta "$HOME_DIR" "admit-live-$i" "firstmate:fm-admit-live-$i"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-z1 "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn at the default cap of 6 live crews should be refused"
  assert_contains "$out" "6 crew already live" "refusal did not name the live count"
  assert_contains "$out" "cap of 6" "refusal did not name the configured cap"
  assert_contains "$out" "config/max-crew" "refusal did not name the config file override"
  assert_contains "$out" "FM_MAX_CREW" "refusal did not name the env override"
  pass "ship spawn is refused once 6 crews are already live under the default cap"
}

test_ship_spawn_allowed_under_cap() {
  local rec i out status
  rec=$(make_admission_case admit-under-cap)
  read_case_record "$rec"

  for i in 1 2 3; do
    seed_live_meta "$HOME_DIR" "admit-live-$i" "firstmate:fm-admit-live-$i"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-z2 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn with only 3 of 6 slots live should succeed"
  assert_contains "$out" "spawned admit-new-z2 harness=claude kind=ship" "spawn did not report success"
  pass "ship spawn is allowed while under the default cap"
}

test_dead_crews_do_not_count_toward_cap() {
  local rec i out status dead=""
  rec=$(make_admission_case admit-dead-crews)
  read_case_record "$rec"

  for i in 1 2 3 4 5 6; do
    seed_live_meta "$HOME_DIR" "admit-dead-$i" "firstmate:fm-admit-dead-$i"
    dead="${dead:+$dead,}firstmate:fm-admit-dead-$i"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$dead" admit-new-z3 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn should succeed when every recorded crew's endpoint is actually gone"
  assert_contains "$out" "spawned admit-new-z3 harness=claude kind=ship" "spawn did not report success"
  pass "a meta whose recorded endpoint no longer exists does not count toward the cap"
}

test_secondmate_metas_do_not_count_toward_cap() {
  local rec i out status
  rec=$(make_admission_case admit-secondmate-metas)
  read_case_record "$rec"

  for i in 1 2 3 4 5 6; do
    seed_secondmate_meta "$HOME_DIR" "admit-sm-$i" "firstmate:fm-admit-sm-$i"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-z4 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn should succeed when the only live entries are secondmates"
  assert_contains "$out" "spawned admit-new-z4 harness=claude kind=ship" "spawn did not report success"
  pass "persistent secondmate entries never count toward the ship/scout admission cap"
}

test_inflight_meta_without_window_counts_as_live() {
  local rec out status
  rec=$(make_admission_case admit-inflight)
  read_case_record "$rec"

  printf '1\n' > "$HOME_DIR/config/max-crew"
  seed_inflight_meta "$HOME_DIR" admit-inflight-1

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-z5 "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a mid-flight spawn (no window recorded yet) should count toward the cap"
  assert_contains "$out" "1 crew already live" "refusal did not count the mid-flight spawn"
  pass "a meta with no window recorded yet counts as live, not skipped"
}

test_config_max_crew_lowers_the_cap() {
  local rec out status
  rec=$(make_admission_case admit-config-cap)
  read_case_record "$rec"

  printf '2\n' > "$HOME_DIR/config/max-crew"
  seed_live_meta "$HOME_DIR" admit-cfg-1 firstmate:fm-admit-cfg-1
  seed_live_meta "$HOME_DIR" admit-cfg-2 firstmate:fm-admit-cfg-2

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-z6 "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn should be refused at a config-lowered cap of 2"
  assert_contains "$out" "cap of 2" "refusal did not reflect config/max-crew"
  pass "config/max-crew lowers the ceiling below the default"
}

test_fm_max_crew_env_overrides_config_file() {
  local rec out status
  rec=$(make_admission_case admit-env-override)
  read_case_record "$rec"

  printf '2\n' > "$HOME_DIR/config/max-crew"
  seed_live_meta "$HOME_DIR" admit-env-1 firstmate:fm-admit-env-1
  seed_live_meta "$HOME_DIR" admit-env-2 firstmate:fm-admit-env-2

  : > "$LAUNCH_LOG"
  mkdir -p "$HOME_DIR/data/admit-new-z7"
  printf 'brief for admit-new-z7\n' > "$HOME_DIR/data/admit-new-z7/brief.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_MAX_CREW=10 \
    "$SPAWN" admit-new-z7 "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 0 "$status" "FM_MAX_CREW=10 should win over a lower config/max-crew for this one spawn"
  assert_contains "$out" "spawned admit-new-z7 harness=claude kind=ship" "spawn did not report success"
  pass "FM_MAX_CREW overrides config/max-crew for a single spawn"
}

test_invalid_max_crew_value_refuses_with_clear_error() {
  local rec out status
  rec=$(make_admission_case admit-invalid-cap)
  read_case_record "$rec"

  printf 'not-a-number\n' > "$HOME_DIR/config/max-crew"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-z8 "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a malformed config/max-crew must refuse the spawn, not silently fall back"
  assert_contains "$out" "config/max-crew must be a positive integer" "invalid-value error was not reported clearly"
  pass "a malformed config/max-crew is reported and refuses the spawn rather than silently defaulting"
}

test_secondmate_launch_exempt_from_cap() {
  local rec i out status sm
  rec=$(make_admission_case admit-secondmate-exempt)
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" admit-new-sm1

  for i in 1 2 3 4 5 6; do
    seed_live_meta "$HOME_DIR" "admit-exempt-$i" "firstmate:fm-admit-exempt-$i"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "" admit-new-sm1 "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "a --secondmate launch must be exempt from the ship/scout admission cap"
  assert_contains "$out" "spawned admit-new-sm1 harness=claude kind=secondmate" "secondmate spawn did not report success"
  pass "a --secondmate launch is never refused by the ship/scout admission cap, even at 6 live ship crews"
}

test_ship_spawn_refused_at_default_cap
test_ship_spawn_allowed_under_cap
test_dead_crews_do_not_count_toward_cap
test_secondmate_metas_do_not_count_toward_cap
test_inflight_meta_without_window_counts_as_live
test_config_max_crew_lowers_the_cap
test_fm_max_crew_env_overrides_config_file
test_invalid_max_crew_value_refuses_with_clear_error
test_secondmate_launch_exempt_from_cap

echo "# all fm-crew-admission-cap tests passed"
