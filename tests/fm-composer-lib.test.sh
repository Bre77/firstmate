#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- NBSP-padded empty composer reads empty, not pending ---------------------
# The 2026-07-16..07-21 away-mode injection wedges: an idle claude composer's
# only content was the bare "❯" prompt glyph followed by a NON-BREAKING SPACE
# (U+00A0), carrying no ANSI styling at all - so the ghost stripper never
# applied - yet bash's [:space:] trim does not strip U+00A0, so the byte
# survived every trim/glyph-strip step and read as leftover real content.

NBSP=$'\xc2\xa0'

test_nbsp_padded_glyph_is_empty() {
  local out
  out=$(classify 0 "❯${NBSP}")
  [ "$out" = empty ] || fail "a bare '❯' padded with a trailing NBSP should be empty, got '$out'"
  out=$(classify 1 "❯${NBSP}")
  [ "$out" = empty ] || fail "a bordered '❯' padded with a trailing NBSP should be empty, got '$out'"
  out=$(classify 0 '' '' sensitive "❯${NBSP}")
  [ "$out" = empty ] || fail "an empty-content/NBSP-padded plain_content fallback should be empty, got '$out'"
  pass "fm_composer_classify_content: an NBSP-padded empty composer reads empty, not pending (the 2026-07-16..07-21 wedge)"
}

test_nbsp_padding_does_not_mask_real_text() {
  local out
  out=$(classify 0 "❯${NBSP}fix the login bug")
  [ "$out" = pending ] || fail "real text after glyph+NBSP padding should still be pending, got '$out'"
  out=$(classify 0 "❯ fix${NBSP}the login bug")
  [ "$out" = pending ] || fail "real text carrying an interior NBSP should still be pending, got '$out'"
  pass "fm_composer_classify_content: NBSP normalization never masks real unsubmitted text as empty"
}

# --- Queued-message hint reads empty, always, regardless of caller idle_re ---
# fm-send false-negative incident: a busy pane accepts a steer as a QUEUED
# message and clears its composer, but shows this hint - and the old
# classifier had no way to know it was not real unsubmitted text.

test_queued_hint_is_empty_standalone_and_inline() {
  local out
  # Standalone: the hint row carries no leading agent glyph at all.
  out=$(classify 0 'Press up to edit queued messages')
  [ "$out" = empty ] || fail "a standalone queued-message hint row should read empty, got '$out'"
  # Inline: the hint appears right after the agent prompt glyph.
  out=$(classify 0 '❯ Press up to edit queued messages')
  [ "$out" = empty ] || fail "the queued-message hint after a bare glyph should read empty, got '$out'"
  out=$(classify 1 '> Press up to edit queued messages')
  [ "$out" = empty ] || fail "the queued-message hint inside a bordered composer should read empty, got '$out'"
  # No caller idle_re was supplied for any of the above - recognition is
  # built in, not dependent on a per-harness idle placeholder regex.
  pass "fm_composer_classify_content: the queued-message hint reads empty standalone or inline, without a caller idle_re"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_nbsp_padded_glyph_is_empty
test_nbsp_padding_does_not_mask_real_text
test_queued_hint_is_empty_standalone_and_inline
