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

# The amendment contract exists so a fresh crew handed "amend this PR" cannot
# anchor on the branch's already-finished-looking diff and declare done without
# ever pushing (the misfire this scaffold flag fixes). Pin the loud deliverable
# statement, both the PR URL and sha landing in the text, and that the standard
# ship Setup/Definition-of-done sections are swapped out rather than merged in.
test_amend_brief_renders_contract() {
  local home id brief
  home="$TMP_ROOT/amend-home"
  id="brief-amend-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj \
    --amend https://github.com/kunchenguid/firstmate/pull/999 --head deadbeef1234 \
    >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "amend brief was not scaffolded"
  assert_grep "# Amendment contract" "$brief" "amend brief missing the Amendment contract section"
  assert_grep "THE ONLY DELIVERABLE IS A NEW PUSHED HEAD ON https://github.com/kunchenguid/firstmate/pull/999, DIFFERENT FROM deadbeef1234." "$brief" \
    "amend brief missing the loud new-head statement"
  assert_grep "deadbeef1234" "$brief" "amend brief lost the required head sha"
  assert_grep "do NOT create a new \`fm/$id\` branch" "$brief" "amend brief must check out the existing PR branch, not create fm/<id>"
  assert_no_grep "no-mistakes" "$brief" "amend brief should not carry the standard no-mistakes Definition of done"
  assert_no_grep "EOF" "$brief" "amend brief leaked a heredoc EOF marker (unterminated heredoc)"
  pass "fm-brief.sh: --amend renders the amendment contract with PR url and sha"
}

# --amend without --head (and --head without --amend) must refuse rather than
# scaffold a brief with an unenforceable contract.
test_amend_requires_head() {
  local home
  home="$TMP_ROOT/amend-missing-head-home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" amend-missing-head some-proj --amend https://x/1 \
    >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --amend without --head should refuse"
  assert_absent "$home/data/amend-missing-head/brief.md" "--amend without --head must not scaffold a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" head-without-amend some-proj --head deadbeef \
    >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --head without --amend should refuse"
  assert_absent "$home/data/head-without-amend/brief.md" "--head without --amend must not scaffold a brief"
  pass "fm-brief.sh: --amend and --head are refused unless paired"
}

# --amend is a ship-only flag; combined with --scout or --secondmate it must
# refuse instead of silently picking one contract over the other.
test_amend_incompatible_with_scout_and_secondmate() {
  local home
  home="$TMP_ROOT/amend-incompatible-home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" amend-scout some-proj --scout \
    --amend https://x/1 --head deadbeef >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --amend with --scout should refuse"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" amend-second --secondmate some-proj \
    --amend https://x/1 --head deadbeef >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --amend with --secondmate should refuse"
  pass "fm-brief.sh: --amend refuses to combine with --scout/--secondmate"
}

# A non-amend call must be entirely unaffected: the standard ship contract
# (branch-creation Setup, mode-specific Definition of done) stays intact and
# no Amendment contract section leaks in.
test_non_amend_calls_keep_standard_sections() {
  local home id brief
  home="$TMP_ROOT/non-amend-home"
  id="brief-non-amend-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "non-amend brief was not scaffolded"
  assert_grep "git checkout -b fm/$id" "$brief" "non-amend brief lost the standard new-branch Setup step"
  assert_grep "# Definition of done" "$brief" "non-amend brief lost the standard Definition of done section"
  assert_no_grep "# Amendment contract" "$brief" "non-amend brief must not carry the Amendment contract section"
  pass "fm-brief.sh: a plain ship call keeps the standard Setup/Definition-of-done sections"
}

test_script_parses
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_amend_brief_renders_contract
test_amend_requires_head
test_amend_incompatible_with_scout_and_secondmate
test_non_amend_calls_keep_standard_sections
