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

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
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

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
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

# The PR-body contract rides only on PR-producing modes: no-mistakes,
# direct-PR, and fork-only briefs get the "# PR body" section. Its priority
# order is: match the target repo's own merged-PR norm first, treat a
# discovered PR template as the whole contract, write why/goal over a diff
# tour, and self-calibrate size to that norm; the old structured Intent/What
# tree survives only as an explicitly-labeled last-resort fallback for a repo
# with neither a template nor a discoverable norm. local-only has no PR, so
# its brief must not carry the section.
test_pr_body_contract_by_mode() {
  local home brief
  home="$TMP_ROOT/prbody-home"
  write_registry "$home"

  for id_proj in "brief-prbody-nm-c1:no-registry-proj" "brief-prbody-dp-c2:direct-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# PR body" "$brief" "$id: brief missing the PR body section"
    assert_grep "target repo's own merged-PR history is the norm to match" "$brief" \
      "$id: PR body section lost the match-the-target-repo-norm primary rule"
    assert_grep "our prior PRs are never the gold standard" "$brief" \
      "$id: PR body section lost the never-hold-up-our-own-PRs steer"
    assert_grep "that template IS the whole contract" "$brief" \
      "$id: PR body section lost the template-is-the-whole-contract rule"
    assert_grep "Write the WHY and the goal the change serves, not a line-by-line tour of the diff" "$brief" \
      "$id: PR body section lost the why-not-diff-tour rule"
    assert_grep "Size follows the same calibration" "$brief" \
      "$id: PR body section lost the self-calibrating size rule"
    assert_grep "a single sentence disclosing any unverified work" "$brief" \
      "$id: PR body section lost the one-sentence unverified-work disclosure keep"
    assert_grep "a dependency bump's compare link, never dropped" "$brief" \
      "$id: PR body section lost the hard-keep compare-link rule"
    assert_grep "gh-axi pr edit" "$brief" "$id: PR body section lost the restructure tool"
    assert_grep "BOTTOM of the body" "$brief" "$id: PR body section lost the bottom-narrative rule"
    assert_grep "Last-resort default: only when the target repo has no PR template AND no discoverable merged-PR norm" "$brief" \
      "$id: PR body section did not demote the structured tree to an explicit last-resort fallback"
    assert_grep "scannable tree" "$brief" "$id: PR body section lost the fallback tree shape"
    assert_no_grep "Typically 3-8 top-level bullets, nested 2-3 levels max; let the shape flex" "$brief" \
      "$id: PR body section regressed the fallback tree to the old primary-rule wording"
  done

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-prbody-fo-c3 direct-proj --fork-only >/dev/null 2>&1
  brief="$home/data/brief-prbody-fo-c3/brief.md"
  assert_present "$brief" "fork-only: brief was not scaffolded"
  assert_grep "# PR body" "$brief" "fork-only brief missing the PR body section"
  assert_grep "--body-file" "$brief" "fork-only PR body section lost the body-file mention"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-prbody-lo-c4 local-proj >/dev/null 2>&1
  brief="$home/data/brief-prbody-lo-c4/brief.md"
  assert_present "$brief" "local-only: brief was not scaffolded"
  assert_no_grep "# PR body" "$brief" "local-only brief must not carry the PR body section (no PR exists)"
  pass "fm-brief.sh: PR body contract present for no-mistakes/direct-PR/fork-only, absent for local-only"
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
  assert_grep "gh-axi pr checkout <number>" "$brief" \
    "amend brief must check out the PR through gh-axi"
  assert_grep "where \`<number>\` is the trailing digits of \`https://github.com/kunchenguid/firstmate/pull/999\`" "$brief" \
    "amend brief must explain how to derive the PR number"
  assert_grep "Record the original head with \`git rev-parse HEAD\`" "$brief" \
    "amend brief must record the local original head"
  assert_grep "confirm \`git rev-parse HEAD\` differs from deadbeef1234 after your successful push" "$brief" \
    "amend brief must verify the new head locally after push"
  assert_no_grep "gh-axi pr view .*--json" "$brief" \
    "amend brief must not rely on unsupported gh-axi pr view --json"
  assert_no_grep "git remote add amend-head" "$brief" \
    "amend brief must not hand-roll a PR head remote"
  assert_no_grep "git fetch origin <branch>" "$brief" \
    "amend brief must not assume the PR branch lives on origin"
  assert_grep "never create a new branch for this work" "$brief" "amend brief must check out the existing PR branch, not create a new branch"
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

# --amend is a ship-only flag; combined with --scout, --secondmate, or
# --fork-only it must refuse instead of silently picking one contract over
# the other.
test_amend_incompatible_with_other_kinds() {
  local home
  home="$TMP_ROOT/amend-incompatible-home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" amend-scout some-proj --scout \
    --amend https://x/1 --head deadbeef >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --amend with --scout should refuse"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" amend-second --secondmate some-proj \
    --amend https://x/1 --head deadbeef >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --amend with --secondmate should refuse"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" amend-forkonly some-proj --fork-only \
    --amend https://x/1 --head deadbeef >/dev/null 2>&1
  expect_code 1 "$?" "fm-brief.sh --amend with --fork-only should refuse"
  pass "fm-brief.sh: --amend refuses to combine with --scout/--secondmate/--fork-only"
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

# The Code comments contract rides EVERY ship brief regardless of delivery
# mode (a shipped comment is a shipped comment whether or not it lands via a
# PR), so pin the banned-pattern list, the AGENTS.md/ARCHITECTURE.md
# exception, and the terseness bar across all four modes. The
# never-ride-your-PR line is scoped narrower - it lives in the PR body
# section, so it must appear only on PR-producing modes and be absent from
# local-only, mirroring test_pr_body_contract_by_mode's mode split.
test_code_comments_contract() {
  local home brief

  home="$TMP_ROOT/code-comments-home"
  write_registry "$home"

  for id_proj in "brief-comments-nm-e1:no-registry-proj" "brief-comments-dp-e2:direct-proj" "brief-comments-lo-e3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Code comments" "$brief" "$id: brief missing the Code comments section"
    assert_grep "see docs/..." "$brief" "$id: code-comment contract lost the banned docs/... pointer pattern"
    assert_grep "\`docs/plans\` references" "$brief" "$id: code-comment contract lost the docs/plans-references ban"
    assert_grep "PR numbers (\`#123\`)" "$brief" "$id: code-comment contract lost the PR-number ban"
    assert_grep "AGENTS.md\` or \`ARCHITECTURE.md\` is fine" "$brief" \
      "$id: code-comment contract lost the project AGENTS.md/ARCHITECTURE.md exception"
    assert_grep "longer than about 3 lines" "$brief" "$id: code-comment contract lost the terseness bar"
  done

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-comments-fo-e4 direct-proj --fork-only >/dev/null 2>&1
  brief="$home/data/brief-comments-fo-e4/brief.md"
  assert_present "$brief" "fork-only: brief was not scaffolded"
  assert_grep "# Code comments" "$brief" "fork-only brief missing the Code comments section"

  for id in brief-comments-nm-e1 brief-comments-dp-e2 brief-comments-fo-e4; do
    brief="$home/data/$id/brief.md"
    assert_grep "never ride your PR" "$brief" \
      "$id: PR-producing brief lost the internal-planning-docs-never-ride-your-PR line"
  done
  brief="$home/data/brief-comments-lo-e3/brief.md"
  assert_no_grep "never ride your PR" "$brief" \
    "local-only brief must not carry the never-ride-your-PR line (it has no PR)"

  pass "fm-brief.sh: Code comments contract present on every ship mode, PR-riding rule scoped to PR-producing modes"
}

# The project-memory section carries the AGENTS.md authoring bar (durable
# knowledge only, pointers over copied detail) and has the crewmate add the
# fm-ensure-agents-md.sh self-governance section when a touched project
# AGENTS.md lacks it.
test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_fork_only_brief_contract
test_pr_body_contract_by_mode
test_amend_brief_renders_contract
test_amend_requires_head
test_amend_incompatible_with_other_kinds
test_non_amend_calls_keep_standard_sections
test_code_comments_contract
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
