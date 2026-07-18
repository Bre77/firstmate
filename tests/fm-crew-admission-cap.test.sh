#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's concurrent crew admission cap.
#
# fm-spawn refuses a NEW ship/scout AGENT launch once this home already has
# cap-or-more live ship/scout tasks (state/*.meta recording kind=ship or
# kind=scout). See the fm-spawn.sh header and docs/crew-memory-cap.md
# "Concurrent crew admission cap" for the full rationale.
#
# These tests drive fm-spawn through meta writing and launch construction with
# a fake tmux pane and a real isolated git worktree (as
# fm-spawn-dispatch-profile.test.sh does), plus a fake systemd-run so the
# per-crew memory cap wrapper never touches a real systemd instance. Live
# crews are simulated by pre-seeding minimal state/<id>.meta fixtures rather
# than by spawning real tasks, so each case is fast and isolated.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-admission-cap)

make_spawn_fakebin() {
  local dir=$1 fakebin
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
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse systemd-run
  printf '%s\n' "$fakebin"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# make_case <name> [live-id:kind ...]: sets up a fresh home/project/worktree
# and seeds one minimal state/<id>.meta per "id:kind" pair (kind counting is
# all fm_live_crew_count reads, so the fixtures need nothing else). Echoes
# "case_dir|home|proj|wt|fakebin".
make_case() {
  local name=$1 case_dir home proj wt fakebin pair id kind
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for pair in "$@"; do
    id=${pair%%:*}
    kind=${pair#*:}
    printf 'kind=%s\n' "$kind" > "$home/state/$id.meta"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <home> <wt> <fakebin> <id> <spawn-args...>: writes a brief for
# <id> (fm-spawn requires one) and drives a real fm-spawn.sh invocation
# against the fake tmux/systemd-run/treehouse and the isolated worktree.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 id=$4
  shift 4
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  env -u FM_MAX_CREW \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$@" 2>&1
}

test_spawn_admitted_below_default_cap() {
  local rec i out status
  rec=$(make_case below-cap)
  read_case_record "$rec"
  for i in 1 2 3 4 5; do
    printf 'kind=ship\n' > "$HOME_DIR/state/live-$i.meta"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" admit-z1 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a 6th ship spawn with 5 already live (default cap 6) should be admitted"
  assert_contains "$out" "spawned admit-z1 harness=claude kind=ship" "admitted spawn did not report success"
  pass "spawn is admitted while live count stays below the default cap of 6"
}

test_spawn_refused_at_default_cap() {
  local rec i out status
  rec=$(make_case at-cap)
  read_case_record "$rec"
  for i in 1 2 3 4 5 6; do
    printf 'kind=ship\n' > "$HOME_DIR/state/live-$i.meta"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" refuse-z2 "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "a 7th ship spawn with 6 already live (default cap 6) should be refused"
  assert_contains "$out" "error: crew admission cap reached" "refusal did not use the expected error prefix"
  assert_contains "$out" "6 ship/scout task(s) already live" "refusal did not name the live count"
  assert_contains "$out" "cap 6" "refusal did not name the cap"
  assert_contains "$out" "config/max-crew" "refusal did not name the config override knob"
  assert_contains "$out" "FM_MAX_CREW" "refusal did not name the env override knob"
  assert_not_contains "$out" "spawned refuse-z2" "refused spawn must not report success"
  pass "spawn is refused once live count reaches the default cap, with a loud actionable message"
}

test_scout_kind_counts_toward_cap() {
  local rec i out status
  rec=$(make_case scout-counts)
  read_case_record "$rec"
  for i in 1 2 3; do
    printf 'kind=ship\n' > "$HOME_DIR/state/live-ship-$i.meta"
  done
  for i in 1 2 3; do
    printf 'kind=scout\n' > "$HOME_DIR/state/live-scout-$i.meta"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" refuse-scout-z3 "$PROJ_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn should count existing scouts toward the cap and be refused at 6 live"
  assert_contains "$out" "error: crew admission cap reached" "scout refusal did not use the expected error prefix"
  pass "kind=scout live tasks count toward the same cap as kind=ship"
}

test_secondmate_kind_is_never_counted() {
  local rec i out status
  rec=$(make_case secondmate-excluded)
  read_case_record "$rec"
  for i in 1 2 3 4 5 6; do
    printf 'kind=secondmate\n' > "$HOME_DIR/state/live-sm-$i.meta"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" admit-z4 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "6 live kind=secondmate records must never count toward the ship/scout cap"
  assert_contains "$out" "spawned admit-z4 harness=claude kind=ship" "spawn blocked by unrelated secondmate records"
  pass "kind=secondmate meta records are excluded from the live crew count"
}

test_secondmate_agent_launch_is_exempt_from_the_cap() {
  local rec i out status sm
  rec=$(make_case secondmate-exempt)
  read_case_record "$rec"
  for i in 1 2 3 4 5 6; do
    printf 'kind=ship\n' > "$HOME_DIR/state/live-$i.meta"
  done
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" secondmate-z5

  out=$(env -u FM_MAX_CREW \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" secondmate-z5 "$sm" --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "a --secondmate launch must be exempt from the ship/scout admission cap"
  assert_contains "$out" "spawned secondmate-z5 harness=claude kind=secondmate" "secondmate spawn did not report success"
  pass "a --secondmate AGENT launch is exempt from the admission cap even at 6 live ship tasks"
}

test_relaunch_of_same_id_excludes_its_own_record() {
  local rec i out status
  rec=$(make_case relaunch-self)
  read_case_record "$rec"
  for i in 1 2 3 4 5; do
    printf 'kind=ship\n' > "$HOME_DIR/state/live-$i.meta"
  done
  # This id's own prior record is already live (recovery relaunch scenario);
  # excluding it keeps the OTHER live count at 5, under the cap of 6.
  printf 'kind=ship\n' > "$HOME_DIR/state/relaunch-z6.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" relaunch-z6 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "relaunching an already-tracked id must not be blocked by its own prior meta record"
  assert_contains "$out" "spawned relaunch-z6 harness=claude kind=ship" "relaunch spawn did not report success"
  pass "a task's own prior meta record is excluded from its own admission count"
}

test_config_max_crew_lowers_the_cap() {
  local rec out status
  rec=$(make_case config-lowers-cap)
  read_case_record "$rec"
  printf '2\n' > "$HOME_DIR/config/max-crew"
  printf 'kind=ship\n' > "$HOME_DIR/state/live-1.meta"
  printf 'kind=ship\n' > "$HOME_DIR/state/live-2.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" refuse-z7 "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "config/max-crew=2 with 2 already live should refuse the 3rd spawn"
  assert_contains "$out" "cap 2" "refusal did not honor the config/max-crew override"
  pass "config/max-crew overrides the default cap"
}

test_fm_max_crew_env_wins_over_config_file() {
  local rec out status
  rec=$(make_case env-wins-over-file)
  read_case_record "$rec"
  printf '2\n' > "$HOME_DIR/config/max-crew"
  printf 'kind=ship\n' > "$HOME_DIR/state/live-1.meta"
  printf 'kind=ship\n' > "$HOME_DIR/state/live-2.meta"

  mkdir -p "$HOME_DIR/data/admit-z8"
  printf 'brief for admit-z8\n' > "$HOME_DIR/data/admit-z8/brief.md"
  out=$(FM_MAX_CREW=5 \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" admit-z8 "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 0 "$status" "FM_MAX_CREW=5 must win over config/max-crew=2, admitting the 3rd spawn"
  assert_contains "$out" "spawned admit-z8 harness=claude kind=ship" "env-overridden spawn did not report success"
  pass "FM_MAX_CREW env var overrides config/max-crew"
}

test_spawn_admitted_below_default_cap
test_spawn_refused_at_default_cap
test_scout_kind_counts_toward_cap
test_secondmate_kind_is_never_counted
test_secondmate_agent_launch_is_exempt_from_the_cap
test_relaunch_of_same_id_excludes_its_own_record
test_config_max_crew_lowers_the_cap
test_fm_max_crew_env_wins_over_config_file

echo "# all fm-crew-admission-cap tests passed"
