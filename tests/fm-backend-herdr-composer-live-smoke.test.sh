#!/usr/bin/env bash
# tests/fm-backend-herdr-composer-live-smoke.test.sh - REAL-herdr coverage for
# fm_backend_herdr_composer_state and the send_text_submit confirmation path
# (bin/backends/herdr.sh), which tests/fm-backend-herdr.test.sh otherwise only
# exercises against captured `herdr pane read` fixtures. A herdr upgrade that
# changes the JSON shape of `agent get`/`pane report-agent`, the byte shape of
# `pane read --format ansi`, or how ANSI de-emphasis round-trips through a
# real pty would still pass every fixture (the fixtures hardcode the OLD
# bytes) while silently breaking the adapter in production. This suite drives
# a real pty through the composer shapes the classifier distinguishes (no
# composer row, bare empty, bare pending, a bordered ghost placeholder, and a
# real ANSI dim-ghost run) and confirms send_text_submit's native agent-state
# verification against a real `agent get`/`pane report-agent` round trip, on
# an ISOLATED, never-default herdr lab session. Skips cleanly when herdr or
# jq is not installed, so CI/dev machines without herdr are unaffected.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/ambient `herdr server stop`.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

SESSION="fm-lab-composer-live-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- a real task pane in the isolated session --------------------------------

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-composerlive1" /tmp "$SEEDED_TAB_ID") || fail "create_task failed"
read -r _TAB_ID PANE_ID <<EOF
$IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
TARGET="$SESSION:$PANE_ID"

# --- composer_state: no composer row on a bare, freshly spawned shell -------

out=$(fm_backend_herdr_composer_state "$TARGET")
[ "$out" = unknown ] || fail "a freshly spawned shell's own prompt row must not be misread as a composer, got '$out'"
pass "real herdr: composer_state reports unknown for a bare shell prompt with no composer row"

# --- composer_state: bare '<glyph>' row is empty -----------------------------

fm_backend_herdr_send_text_line "$TARGET" 'printf "\xe2\x9d\xaf\n"' || fail "could not drive the bare-empty composer shape"
sleep 0.5
out=$(fm_backend_herdr_composer_state "$TARGET")
[ "$out" = empty ] || fail "a live bare '<glyph>' composer row should read empty, got '$out'"
pass "real herdr: composer_state reads empty for a live bare '<glyph>' composer row"

# --- composer_state: bare '<glyph> text' row is pending ----------------------

fm_backend_herdr_send_text_line "$TARGET" 'printf "\xe2\x9d\xaf hello captain\n"' || fail "could not drive the bare-pending composer shape"
sleep 0.5
out=$(fm_backend_herdr_composer_state "$TARGET")
[ "$out" = pending ] || fail "a live bare '<glyph> text' composer row should read pending, got '$out'"
pass "real herdr: composer_state reads pending for a live bare '<glyph> text' composer row"

# --- composer_state: a bordered ghost/placeholder row is empty --------------
# A real bordered composer always draws a complete box (top and bottom rule),
# never a lone side-bordered row: the shared classifier's box detector
# requires that pair to recognize a box shape at all, matching what every
# real agent (Claude, Codex, ...) actually renders. The placeholder text
# itself must carry real dim (SGR 2) styling too - herdr's ANSI capture
# always reports styled=1, and the classifier only trusts an idle-regex
# match as ghost/placeholder text under styled=1 when de-emphasis proves it,
# exactly like the dim-ghost assertions below this one.

fm_backend_herdr_send_text_line "$TARGET" 'printf "\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 \x1b[0m\x1b[2mType a message...\x1b[0m      \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n"' || fail "could not drive the bordered ghost-placeholder shape"
sleep 0.5
out=$(fm_backend_herdr_composer_state "$TARGET")
[ "$out" = empty ] || fail "a live bordered ghost-placeholder row should read empty, got '$out'"
pass "real herdr: composer_state reads empty for a live bordered ghost-placeholder row"

# --- composer_state: a REAL ANSI dim-ghost run round-trips through a real ---
# pty and 'pane read --format ansi' the same way fm_composer_strip_ghost
# expects (docs/herdr-backend.md "Composer and injection safety").

fm_backend_herdr_send_text_line "$TARGET" 'printf "\xe2\x9d\xaf \x1b[0m\x1b[2msuggested next step\x1b[0m\n"' || fail "could not drive the dim-ghost-only composer shape"
sleep 0.5
out=$(fm_backend_herdr_composer_state "$TARGET")
[ "$out" = empty ] || fail "a live dim-ghost-only composer row should read empty, got '$out'"
pass "real herdr: composer_state strips a REAL ANSI dim-ghost run and reads empty"

fm_backend_herdr_send_text_line "$TARGET" 'printf "\xe2\x9d\xaf \x1b[0m\x1b[2mghost\x1b[0mreal-text\n"' || fail "could not drive the dim-ghost-plus-real-text composer shape"
sleep 0.5
out=$(fm_backend_herdr_composer_state "$TARGET")
[ "$out" = pending ] || fail "real typed text following a REAL ANSI dim-ghost run should still read pending, got '$out'"
pass "real herdr: composer_state keeps real typed text following a REAL ANSI dim-ghost run as pending"

# --- busy_state: real native agent-state round trip via report-agent -------

fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-composer-live-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not register the pane's agent as idle"
out=$(fm_backend_herdr_busy_state "$TARGET")
[ "$out" = idle ] || fail "busy_state should read idle after a real report-agent idle call, got '$out'"
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-composer-live-test --agent claude --state working >/dev/null 2>&1 \
  || fail "could not register the pane's agent as working"
out=$(fm_backend_herdr_busy_state "$TARGET")
[ "$out" = busy ] || fail "busy_state should read busy after a real report-agent working call, got '$out'"
pass "real herdr: busy_state reflects a real report-agent idle/working round trip"

# --- send_text_submit: confirms via a real agent_status idle->working->idle ---
# transition (the production confirmation path, docs/herdr-backend.md "Native
# agent-state submit confirmation"), never by reading composer content.

fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-composer-live-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not reset the pane's agent to idle before the landed-submit check"
(
  sleep 0.3
  fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-composer-live-test --agent claude --state working >/dev/null 2>&1
  sleep 0.3
  fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-composer-live-test --agent claude --state idle >/dev/null 2>&1
) &
DRIVER_PID=$!
out=$(fm_backend_herdr_send_text_submit "$TARGET" "hello captain" 3 0.6 0.1)
wait "$DRIVER_PID"
[ "$out" = empty ] || fail "send_text_submit should report empty (confirmed) once a real agent_status transition to working is observed, got '$out'"
pass "real herdr: send_text_submit confirms submission via a real agent_status idle->working transition"

# --- send_text_submit: reports pending when agent_status never confirms ----
# (a swallowed Enter - no real turn ever started).

fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-composer-live-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not reset the pane's agent to idle before the swallowed-submit check"
out=$(fm_backend_herdr_send_text_submit "$TARGET" "hello captain" 2 0.6 0.1)
[ "$out" = pending ] || fail "send_text_submit should report pending when agent_status never reports working after retried Enters, got '$out'"
pass "real herdr: send_text_submit reports pending when the real agent_status never confirms a submit"

fm_backend_herdr_kill "$TARGET"
cleanup_all
trap - EXIT
