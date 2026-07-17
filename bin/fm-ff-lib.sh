# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A standalone clone moves through that path only when
# it already has the target; otherwise it is skipped until the origin path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# secondmate's backlog, projects, or in-flight work.
# The seeded .fm-secondmate-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve a named remote's default branch (the branch its HEAD points at), for a
# remote whose tracking refs are already fetched. Reads refs/remotes/<remote>/HEAD
# when present (set by `git remote set-head <remote> -a`), otherwise falls back to
# main then master. Echoes the branch name, or returns 1. Used for the `upstream`
# remote in the fork model, where upstream/HEAD is commonly unset.
remote_default_branch() {
  local dir=$1 remote=$2 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#"$remote"/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Is this checkout running the fork operating model? True only when it has a
# distinct `upstream` remote whose URL differs from `origin` - i.e. origin is the
# fork's integration line and upstream is the read-mostly source. A plain
# upstream-origin firstmate (no upstream remote, or upstream==origin) is NOT the
# fork model, so phase (a) integration is skipped and behavior is unchanged.
is_fork_model() {
  local dir=$1 origin_url upstream_url
  origin_url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  upstream_url=$(git -C "$dir" remote get-url upstream 2>/dev/null || true)
  [ -n "$origin_url" ] || return 1
  [ -n "$upstream_url" ] || return 1
  [ "$origin_url" != "$upstream_url" ] || return 1
  return 0
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md symlinks), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print; exit }'
  else
    git -C "$dir" status --porcelain 2>/dev/null | head -1
  fi
}

secondmate_registry_field() {
  local reg=$1 id=$2 key=$3 line value
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' | sed 's/[[:space:]]*$//') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/.*; projects:[[:space:]]*\([^;)]*\); added .*/\1/p' | sed 's/[[:space:]]*$//') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# List this home's LIVE secondmate direct reports from state/<id>.meta records.
# The meta file is the liveness signal; data/secondmates.md is only the fallback
# for durable fields such as home= when an older/incomplete meta lacks them.
# Output is pipe-delimited: id|home|window|meta-file.
live_secondmate_meta_records() {
  local state=$1 registry=${2:-} meta id home window
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$home" ] && [ -n "$registry" ]; then
      home=$(secondmate_registry_field "$registry" "$id" home || true)
    fi
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s|%s|%s|%s\n' "$id" "$home" "$window" "$meta"
  done
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# dirty, diverged, or wrong-branch target and leave its work untouched.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one secondmate home, accumulating its stable
# fm-<id> task selector into FF_NUDGE_WINDOWS when it should be live-converged.
# Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a
# live window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# firstmate repo itself (FM_ROOT) is never processed as its own secondmate, and
# each resolved home is processed at most once.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} home_real fm_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "secondmate $id" "$base_mode" yes yes
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
    if [ "$nudge_requires_instr" = yes ] && [ -n "$FF_INSTR" ] \
      && type fm_ff_after_instruction_update >/dev/null 2>&1; then
      fm_ff_after_instruction_update "$id" "$home_real" "$window" "$FF_INSTR"
    fi
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_secondmate. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
# The registry argument is only for home= fallback on older or incomplete meta records.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$FM_HOME/data/secondmates.md} id home window meta
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta; do
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr"
  done < <(live_secondmate_meta_records "$state" "$registry")
}

# --- phase (a): integrate upstream into the fork integration line -----------
#
# Merge upstream/<default> into the fork integration line (origin/<default>) so
# the fork stays current with its source before phase (b) fast-forwards the
# running primary onto the integration tip. This is the ONLY firstmate self-sync
# path that MERGES rather than fast-forwards, and it is why it is confined here:
#   - It runs in an ISOLATED worktree, never the running primary checkout, so the
#     primary only ever sees phase (b)'s already-fast-forwardable result and the
#     fast-forward-only invariant on the primary is preserved.
#   - On a clean merge it pushes the integration line to origin (a fast-forward of
#     origin/<default>, since the merge commit's first parent is the old tip).
#   - On CONFLICT it never resolves in-line: it aborts, tears down its scratch
#     worktree, and reports a delegation signal so firstmate can dispatch an
#     off-primary crewmate to resolve and push, then re-run.
# It is a strict no-op (silent, INTEGRATE_STATUS=not-fork) outside the fork model.
#
# Sets globals for the caller:
#   INTEGRATE_STATUS   = not-fork|current|integrated|conflict|error|skipped
#   INTEGRATE_DELEGATE = merge description + conflicted paths (only when conflict)
# Both are consumed by the sourcing bin/fm-update.sh, not within this library.
# shellcheck disable=SC2034
INTEGRATE_STATUS=""
# shellcheck disable=SC2034
INTEGRATE_DELEGATE=""
integrate_upstream() {
  local root=$1
  INTEGRATE_STATUS="not-fork"
  INTEGRATE_DELEGATE=""

  is_fork_model "$root" || return 0

  local fdefault udefault obase ubase before after wt_parent wt out conflicts

  # Refresh both remotes. Fetching only updates remote-tracking refs, never the
  # working tree, so it is safe against the running primary. fetch_once dedups the
  # origin fetch with phase (b), which shares this object store.
  if ! fetch_once "$root"; then
    INTEGRATE_STATUS="skipped"
    echo "integrate-upstream: skipped: origin fetch failed"
    return 0
  fi
  if ! git -C "$root" fetch upstream --prune --quiet 2>/dev/null; then
    INTEGRATE_STATUS="skipped"
    echo "integrate-upstream: skipped: upstream fetch failed"
    return 0
  fi

  fdefault=$(default_branch "$root") || {
    INTEGRATE_STATUS="skipped"
    echo "integrate-upstream: skipped: cannot determine fork default branch"
    return 0
  }
  udefault=$(remote_default_branch "$root" upstream) || {
    INTEGRATE_STATUS="skipped"
    echo "integrate-upstream: skipped: cannot determine upstream default branch"
    return 0
  }
  obase="origin/$fdefault"
  ubase="upstream/$udefault"

  if ! git -C "$root" rev-parse --verify --quiet "$obase^{commit}" >/dev/null; then
    INTEGRATE_STATUS="skipped"
    echo "integrate-upstream: skipped: $obase does not exist"
    return 0
  fi
  if ! git -C "$root" rev-parse --verify --quiet "$ubase^{commit}" >/dev/null; then
    INTEGRATE_STATUS="skipped"
    echo "integrate-upstream: skipped: $ubase does not exist"
    return 0
  fi

  # Nothing to integrate when the integration line already contains upstream.
  if git -C "$root" merge-base --is-ancestor "$ubase" "$obase" 2>/dev/null; then
    INTEGRATE_STATUS="current"
    echo "integrate-upstream: already current ($obase contains $ubase)"
    return 0
  fi

  # Merge in an isolated, disposable worktree checked out at the integration tip.
  # A fresh mktemp path guarantees it is distinct from the primary; the assertion
  # below is the fm-spawn-style defense in depth.
  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/fm-integrate.XXXXXX") || {
    INTEGRATE_STATUS="error"
    echo "integrate-upstream: skipped: cannot create scratch directory"
    return 0
  }
  wt="$wt_parent/wt"
  if ! git -C "$root" worktree add --detach --quiet "$wt" "$obase" 2>/dev/null; then
    rm -rf "$wt_parent"
    INTEGRATE_STATUS="error"
    echo "integrate-upstream: skipped: cannot create isolated worktree"
    return 0
  fi

  if ! integration_worktree_is_isolated "$wt" "$root"; then
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$wt_parent"
    git -C "$root" worktree prune 2>/dev/null || true
    INTEGRATE_STATUS="error"
    echo "integrate-upstream: skipped: worktree not isolated from the primary checkout"
    return 0
  fi

  before=$(git -C "$root" rev-parse --short "$obase")
  if git -C "$wt" merge --no-edit "$ubase" >/dev/null 2>&1; then
    after=$(git -C "$wt" rev-parse --short HEAD)
    if out=$(git -C "$wt" push --quiet origin "HEAD:$fdefault" 2>&1); then
      INTEGRATE_STATUS="integrated"
      echo "integrate-upstream: integrated $ubase into $obase ($before..$after), pushed origin/$fdefault"
    else
      INTEGRATE_STATUS="error"
      echo "integrate-upstream: skipped: push to origin/$fdefault failed: $(first_line "$out")"
    fi
  else
    conflicts=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    git -C "$wt" merge --abort 2>/dev/null || true
    # Output contract read by bin/fm-update.sh, not within this library.
    # shellcheck disable=SC2034
    INTEGRATE_STATUS="conflict"
    # shellcheck disable=SC2034
    INTEGRATE_DELEGATE="merge $ubase into $obase; conflicted paths: ${conflicts:-unknown}"
    echo "integrate-upstream: CONFLICT merging $ubase into $obase; off-primary resolution needed (conflicted: ${conflicts:-unknown})"
  fi

  git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$wt_parent"
  git -C "$root" worktree prune 2>/dev/null || true
  return 0
}

# Assert a merge worktree is a genuine isolated worktree distinct from the primary
# checkout, mirroring fm-spawn.sh's validate_spawn_worktree. Returns 0 when the
# worktree resolves to its own top-level path that is not the primary root.
integration_worktree_is_isolated() {
  local wt=$1 root=$2 wt_real root_real wt_top wt_top_real
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  root_real=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  wt_top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$wt_top" ] || return 1
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || return 1
  [ "$wt_real" = "$wt_top_real" ] || return 1
  [ "$wt_real" != "$root_real" ] || return 1
  return 0
}
