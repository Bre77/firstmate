#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# --fork-only overrides the registered mode with the fork-only delivery contract:
# it must branch off the fork's main, point at bin/fm-fork-deliver.sh, forbid
# /no-mistakes, and render cleanly (no leaked heredoc EOF, quote-escape artifact,
# or unreplaced $SETUP2), regardless of the project's registered upstream mode.
test_fork_only_brief_contract() {
  local home id brief
  home="$TMP_ROOT/fork-only-home"
  write_registry "$home"   # direct-proj is registered [direct-PR]; fork-only must override it
  id="brief-forkonly-c1"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --fork-only >/dev/null 2>&1 \
    || fail "$id: --fork-only brief should exit 0"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "$id: fork-only brief was not scaffolded"
  assert_grep "**fork-only**" "$brief" "$id: brief missing the fork-only label"
  assert_grep "git fetch fork --prune && git checkout -B fm/$id fork/main" "$brief" \
    "$id: fork-only Setup does not branch off the fork's main"
  assert_grep "bin/fm-fork-deliver.sh" "$brief" "$id: fork-only DOD does not point at fm-fork-deliver.sh"
  assert_grep "Do NOT run /no-mistakes" "$brief" "$id: fork-only DOD does not forbid /no-mistakes"
  assert_grep "only to the fork remote" "$brief" "$id: fork-only Rule 1 does not scope pushes to the fork"
  assert_no_grep "EOF" "$brief" "$id: fork-only brief leaked a heredoc EOF marker"
  assert_no_grep "\$SETUP2" "$brief" "$id: fork-only brief leaked an unreplaced \$SETUP2"
  # The apostrophe-escape dance ('"'"') must never leak into rendered text.
  assert_no_grep "'\"'\"'" "$brief" "$id: fork-only brief leaked a shell quote-escape artifact"
  # It must NOT regress into the default upstream branch step.
  assert_no_grep "create your branch: \`git checkout -b fm/$id\`" "$brief" \
    "$id: fork-only brief kept the default upstream branch step"
  pass "fm-brief.sh: --fork-only overrides the registered mode with a clean fork-only contract"
}

test_script_parses
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_fork_only_brief_contract
