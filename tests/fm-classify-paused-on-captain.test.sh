#!/usr/bin/env bash
# tests/fm-classify-paused-on-captain.test.sh - a paused: line whose note names
# firstmate or the captain (a decision, an approval, a merge word, a
# credential, an answer) is a mislabeled blocked wait, not a genuine bounded
# external wait (AGENTS.md section 8). Observed 2026-08-23: three workers ended
# on lines like "paused: awaiting captain merge decision on <branch>" and sat
# unsurfaced on the long recheck cadence for 12-22 hours with finished work
# unlanded, because status_is_paused_or_captain_held only ever read the verb.
#
# bin/fm-classify-lib.sh's status_is_paused_on_captain is the ONE pattern-list
# owner (FM_CLASSIFY_PAUSED_ON_CAPTAIN_RE_DEFAULT); this pins its two
# consumers - status_is_captain_relevant (drives the queue/blocked wake path)
# and status_is_paused_or_captain_held (drives the watcher/daemon pause-absorb
# cadence gate in bin/fm-watch.sh and bin/fm-supervise-daemon.sh) - without
# touching the keyed open/resolved decision grammar those two never parse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

test_paused_on_captain_is_blocked() {
  local line

  line='paused: awaiting captain merge decision on fm/foo'
  status_is_paused "$line" || fail "verb parse regressed for a captain-named pause: $line"
  status_is_paused_on_captain "$line" \
    || fail "a pause naming the captain was not recognised as waiting on us: $line"
  status_is_captain_relevant "$line" \
    || fail "a pause naming the captain did not classify as captain-relevant (blocked): $line"
  status_is_paused_or_captain_held "$line" \
    && fail "a pause naming the captain kept the declared-wait absorb cadence: $line"

  line='paused: doc commit awaiting captain decision'
  status_is_paused_on_captain "$line" \
    || fail "a pause naming a captain decision was not recognised: $line"
  status_is_captain_relevant "$line" \
    || fail "a pause naming a captain decision did not classify as captain-relevant (blocked): $line"
  status_is_paused_or_captain_held "$line" \
    && fail "a pause naming a captain decision kept the declared-wait absorb cadence: $line"

  line='paused: blocked on firstmate approval before continuing'
  status_is_paused_on_captain "$line" \
    || fail "a pause naming firstmate approval was not recognised: $line"
  status_is_captain_relevant "$line" \
    || fail "a pause naming firstmate approval did not classify as captain-relevant (blocked): $line"

  pass "a paused: line naming the captain or firstmate classifies as blocked, on the blocked cadence"
}

test_paused_on_upstream_stays_paused() {
  local line

  line='paused: awaiting upstream CI'
  status_is_paused "$line" || fail "verb parse regressed for a genuine external pause: $line"
  status_is_paused_on_captain "$line" \
    && fail "a genuine external wait false-matched the captain-named pattern: $line"
  status_is_captain_relevant "$line" \
    && fail "a genuine external wait became captain-relevant: $line"
  status_is_paused_or_captain_held "$line" \
    || fail "a genuine external wait lost the declared-wait absorb cadence: $line"

  line='paused: canary deploy verification until 14:30 UTC'
  status_is_paused_on_captain "$line" \
    && fail "a timed deploy wait false-matched the captain-named pattern: $line"
  status_is_captain_relevant "$line" \
    && fail "a timed deploy wait became captain-relevant: $line"

  line='paused: vendor rate-limit reset expected within the hour'
  status_is_paused_on_captain "$line" \
    && fail "a vendor rate-limit wait false-matched the captain-named pattern: $line"

  # A bare "merge" substring inside ordinary past-tense prose ("merged") must
  # never false-match: tests/fm-daemon.test.sh pins this exact pause note as a
  # genuine external wait, so the pattern deliberately matches the PHRASE
  # "merge decision" rather than the bare word "merge".
  line='paused: waiting for upstream checks green, merged, and blocked state to clear'
  status_is_paused_on_captain "$line" \
    && fail "'merged' inside ordinary status prose false-matched the merge pattern: $line"
  status_is_captain_relevant "$line" \
    && fail "'merged' inside ordinary status prose became captain-relevant: $line"

  pass "a paused: line naming a genuine external wait keeps the long pause recheck cadence"
}

test_paused_on_merge_decision_without_naming_captain() {
  # "merge decision" alone (no "captain"/"firstmate" word) still names a wait
  # only firstmate can clear, and must classify as blocked - the "merge word"
  # case named in the pattern-list rule, distinct from the captain/firstmate
  # word cases covered above.
  local line='paused: docs commit awaiting merge decision'

  status_is_paused_on_captain "$line" \
    || fail "a bare merge-decision wait was not recognised as waiting on us: $line"
  status_is_captain_relevant "$line" \
    || fail "a bare merge-decision wait did not classify as captain-relevant (blocked): $line"
  status_is_paused_or_captain_held "$line" \
    && fail "a bare merge-decision wait kept the declared-wait absorb cadence: $line"

  pass "a paused: line naming a merge decision classifies as blocked even without the word captain"
}

test_blocked_stays_blocked() {
  local line='blocked: awaiting captain merge decision on fm/foo'

  status_is_paused "$line" && fail "an already-blocked line was misread as paused: $line"
  status_is_paused_on_captain "$line" \
    && fail "status_is_paused_on_captain matched a non-paused verb: $line"
  status_is_captain_relevant "$line" \
    || fail "an ordinary blocked: line regressed to non-captain-relevant: $line"
  status_is_paused_or_captain_held "$line" \
    && fail "an ordinary blocked: line was absorbed on the declared-wait cadence: $line"

  pass "an already-blocked line is unaffected and stays blocked"
}

test_paused_on_captain_never_touches_decision_grammar() {
  # status_is_paused_on_captain and its two consumers are pure verb/note reads;
  # they must never fold, open, or close a keyed decision themselves. Pin that a
  # keyed captain-named pause still reports the same key through the ordinary
  # verb/key readers, with the classification layered on top rather than
  # rewriting the line.
  local line='paused [key=merge-wait]: awaiting captain merge decision on fm/foo'

  [ "$(status_line_verb "$line")" = paused ] \
    || fail "a keyed captain-named pause no longer parses as the paused verb"
  status_is_paused_on_captain "$line" \
    || fail "a keyed captain-named pause was not recognised as waiting on us"
  status_is_captain_relevant "$line" \
    || fail "a keyed captain-named pause did not classify as captain-relevant (blocked)"

  pass "captain-named pause classification leaves the keyed decision grammar untouched"
}

test_paused_on_captain_is_blocked
test_paused_on_upstream_stays_paused
test_paused_on_merge_decision_without_naming_captain
test_blocked_stays_blocked
test_paused_on_captain_never_touches_decision_grammar
