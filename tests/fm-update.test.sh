#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# Build a FORK-MODEL world: two bare remotes (upstream = the source, origin = the
# fork integration line) that share a common base commit, each advanced by one
# divergent commit, and a firstmate repo cloned from the fork with an `upstream`
# remote. The divergence is (ufile=ucontent) upstream vs (ffile=fcontent) on the
# fork; pass the same path for both to force a merge conflict, different paths for
# a clean merge. Files seeded at base: AGENTS.md, README.md, bin/tool.sh. Echoes w.
new_fork_world() {
  local name=$1 ufile=$2 ucontent=$3 ffile=$4 fcontent=$5 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main

  # Common base commit, pushed to BOTH remotes (the fork starts as a mirror of
  # upstream), so a real 3-way merge is possible.
  git clone -q "$w/upstream.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm base
  git -C "$w/seed" push -q origin main
  git -C "$w/seed" remote add fork "$w/origin.git"
  git -C "$w/seed" push -q fork main

  # Upstream-only commit on upstream/main.
  git clone -q "$w/upstream.git" "$w/uwork" 2>/dev/null
  printf '%s\n' "$ucontent" > "$w/uwork/$ufile"
  git -C "$w/uwork" add -A
  git -C "$w/uwork" commit -qm upstream-change
  git -C "$w/uwork" push -q origin main

  # Fork-only commit on origin/main (the integration line).
  git clone -q "$w/origin.git" "$w/fwork" 2>/dev/null
  printf '%s\n' "$fcontent" > "$w/fwork/$ffile"
  git -C "$w/fwork" add -A
  git -C "$w/fwork" commit -qm fork-change
  git -C "$w/fwork" push -q origin main

  # The running firstmate repo: cloned from the fork tip, with an upstream remote,
  # on branch main. origin/HEAD resolves to main; upstream/HEAD is deliberately
  # left unset to exercise the main/master fallback in remote_default_branch.
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote add upstream "$w/upstream.git"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- F1: fork-model detection true on a fork clone, false on a plain clone --
test_fork_model_detection() {
  local w nf
  w=$(new_fork_world f1 README.md up bin/tool.sh fork)
  ( . "$ROOT/bin/fm-ff-lib.sh"; is_fork_model "$w/main" ) \
    || fail "fork model not detected on a clone with a distinct upstream remote"
  # A plain upstream-origin firstmate (origin only, no upstream remote).
  nf=$(new_world f1n)
  ( . "$ROOT/bin/fm-ff-lib.sh"; is_fork_model "$nf/main" ) \
    && fail "fork model falsely detected on a plain upstream-origin clone"
  pass "F1 fork-model detection: true with a distinct upstream remote, false without"
}

# --- F2: phase (a) clean merge integrates upstream and pushes; primary FFs ---
test_phase_a_clean_merge() {
  local w out before tip
  # Upstream changes README.md, the fork changes bin/tool.sh: disjoint paths, so
  # merging upstream into the integration line is a clean 3-way merge.
  w=$(new_fork_world f2 README.md up-readme bin/tool.sh fork-tool)
  add_sm "$w" sm1
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "integrate-upstream: integrated " "phase (a) reports a clean integration"
  assert_contains "$out" "integrate-upstream-status: integrated" "phase (a) status is integrated"
  assert_not_contains "$out" "integrate-upstream-delegate:" "a clean merge emits no delegation signal"

  # The integration line on the fork now carries BOTH divergent changes.
  git -C "$w/main" fetch -q origin 2>/dev/null || true
  tip=$(git -C "$w/main" rev-parse origin/main)
  [ "$(git -C "$w/main" show "$tip:README.md")" = "up-readme" ] \
    || fail "integrated tip is missing the upstream change"
  [ "$(git -C "$w/main" show "$tip:bin/tool.sh")" = "fork-tool" ] \
    || fail "integrated tip is missing the fork change"
  # It is a real merge commit (two parents).
  [ "$(git -C "$w/main" rev-list --parents -n1 "$tip" | wc -w | tr -d ' ')" -eq 3 ] \
    || fail "integrated tip is not a two-parent merge commit"

  # Phase (b) then fast-forwarded the running primary onto that tip: the move is a
  # fast-forward (old HEAD is an ancestor of the new tip), preserving the invariant.
  assert_contains "$out" "firstmate: updated " "phase (b) fast-forwarded the primary onto the integrated tip"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$tip" ] \
    || fail "primary did not advance to the integrated tip"
  git -C "$w/main" merge-base --is-ancestor "$before" "$tip" \
    || fail "primary advance was not a fast-forward (old HEAD not an ancestor of the new tip)"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "primary left its default branch"

  # No scratch integration worktree is left behind.
  assert_not_contains "$(git -C "$w/main" worktree list)" "fm-integrate" "scratch merge worktree was cleaned up"
  pass "F2 phase (a) clean merge integrates upstream, pushes, and the primary fast-forwards"
}

# --- F3: phase (a) conflict path delegates instead of resolving -------------
test_phase_a_conflict_delegates() {
  local w out fork_tip after_tip
  # Both sides change AGENTS.md from the same base line: an unresolvable 3-way
  # conflict that phase (a) must hand off rather than resolve in-line.
  w=$(new_fork_world f3 AGENTS.md up-agents AGENTS.md fork-agents)
  fork_tip=$(git -C "$w/origin.git" rev-parse main)

  out=$(run_update "$w")

  assert_contains "$out" "integrate-upstream: CONFLICT " "phase (a) reports a conflict"
  assert_contains "$out" "integrate-upstream-status: conflict" "phase (a) status is conflict"
  assert_contains "$out" "integrate-upstream-delegate:" "phase (a) emits a delegation signal"
  assert_contains "$out" "AGENTS.md" "the delegation signal names the conflicted path"

  # The integration line was NOT advanced: no half-merged state was pushed.
  after_tip=$(git -C "$w/origin.git" rev-parse main)
  [ "$after_tip" = "$fork_tip" ] \
    || fail "conflict path pushed to the integration line (origin/main moved)"

  # Phase (b) still ran after the conflict: the primary was already at the fork
  # tip, so it reports already current rather than advancing onto a bad merge.
  assert_contains "$out" "firstmate: already current" "phase (b) runs after a phase (a) conflict"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$fork_tip" ] \
    || fail "primary moved despite the unresolved conflict"

  # No scratch integration worktree is left behind.
  assert_not_contains "$(git -C "$w/main" worktree list)" "fm-integrate" "scratch merge worktree was cleaned up after conflict"
  pass "F3 phase (a) conflict hands off a delegation signal and leaves the integration line untouched"
}

# --- F4: non-fork backward compat - phase (a) is skipped entirely -----------
test_non_fork_backward_compat() {
  local w out
  w=$(new_world f4)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  # Not a single phase-(a) line appears: a plain upstream-origin firstmate is
  # byte-for-byte unchanged.
  assert_not_contains "$out" "integrate-upstream" "non-fork run emits no phase-(a) output at all"
  # Phase (b) behaves exactly as before.
  assert_contains "$out" "firstmate: updated " "phase (b) still fast-forwards the primary"
  assert_contains "$out" "secondmate sm1: updated " "phase (b) still sweeps secondmates"
  assert_contains "$out" "reread-firstmate: yes" "phase (b) reread signalling unchanged"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "phase (b) nudge signalling unchanged"
  pass "F4 non-fork firstmate skips phase (a) entirely and behaves as before"
}

# --- F5: opt-out - FM_UPDATE_NO_INTEGRATE disables phase (a) on a fork -------
test_phase_a_opt_out() {
  local w out fork_tip
  w=$(new_fork_world f5 README.md up-readme bin/tool.sh fork-tool)
  fork_tip=$(git -C "$w/origin.git" rev-parse main)

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" FM_UPDATE_NO_INTEGRATE=1 "$UPDATE" 2>/dev/null)

  assert_contains "$out" "integrate-upstream: skipped: disabled via FM_UPDATE_NO_INTEGRATE" "opt-out reports the skip"
  assert_not_contains "$out" "integrate-upstream-status: integrated" "opt-out performs no merge"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$fork_tip" ] \
    || fail "opt-out still advanced the integration line"
  # Phase (b) still runs.
  assert_contains "$out" "firstmate: already current" "phase (b) still runs under opt-out"
  pass "F5 FM_UPDATE_NO_INTEGRATE skips phase (a) on a fork while phase (b) still runs"
}

test_fork_model_detection
test_phase_a_clean_merge
test_phase_a_conflict_delegates
test_non_fork_backward_compat
test_phase_a_opt_out
test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update

echo "# all fm-update tests passed"
