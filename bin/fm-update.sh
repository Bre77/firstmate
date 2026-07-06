#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Runs in two phases:
#
#   (a) Fork-model integration (fork only, off-primary, conflict-aware). When this
#       checkout runs the fork model - a distinct `upstream` remote whose URL
#       differs from origin - merge upstream/<default> INTO the fork integration
#       line (origin/<default>) in an isolated worktree, never the running primary,
#       and push on a clean merge. On conflict it does NOT resolve in-line: it
#       reports a delegation signal so firstmate can hand off to an off-primary
#       crewmate, then re-run. A plain upstream-origin firstmate skips phase (a)
#       entirely and behaves byte-for-byte as before. The merge/conflict work is
#       confined here so the running primary only ever sees phase (b)'s already-
#       fast-forwardable result. Opt out with FM_UPDATE_NO_INTEGRATE=1.
#
#   (b) Fast-forward sweep (all models, unchanged). Fast-forwards the running
#       firstmate repo's default branch from origin, then fast-forwards every
#       registered secondmate home (each a treehouse worktree of this same repo, or
#       a standalone clone) the same way.
#
# Phase (b) is FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: <window-targets...>|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- phase (a): integrate upstream into the fork integration line ----------
# Fork model only (a distinct `upstream` remote whose URL differs from origin);
# a plain upstream-origin firstmate skips this entirely and behaves exactly as
# before. The merge runs off-primary in an isolated worktree; on conflict it
# emits a delegation signal instead of resolving in-line. Phase (b) below then
# runs unchanged, so the running primary only ever sees an already-fast-
# forwardable integration tip. Set FM_UPDATE_NO_INTEGRATE=1 to opt out.
integrate_status="not-fork"
if [ -z "${FM_UPDATE_NO_INTEGRATE:-}" ]; then
  integrate_upstream "$FM_ROOT"
  integrate_status="$INTEGRATE_STATUS"
elif is_fork_model "$FM_ROOT"; then
  echo "integrate-upstream: skipped: disabled via FM_UPDATE_NO_INTEGRATE"
  integrate_status="skipped"
fi
if [ "$integrate_status" != "not-fork" ]; then
  echo "integrate-upstream-status: $integrate_status"
  [ "$integrate_status" = "conflict" ] && echo "integrate-upstream-delegate: $INTEGRATE_DELEGATE"
fi

# --- phase (b): main firstmate repo ----------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
