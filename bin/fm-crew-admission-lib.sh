#!/usr/bin/env bash
# fm-crew-admission-lib.sh - concurrent ship/scout admission cap for fm-spawn.sh.
#
# Refuses a NEW ship/scout launch once too many crews are already live in this
# home, so a burst of concurrent launches queues instead of piling straight
# onto the host. Resource hygiene against host oversubscription, not a proven
# fix for any specific incident - see AGENTS.md for the config/max-crew entry.
#
# Sourced by bin/fm-spawn.sh, after bin/fm-backend.sh (needs fm_meta_get,
# fm_backend_of_meta, fm_backend_target_of_meta, fm_backend_target_exists).
# Requires STATE and CONFIG already resolved by the caller. No side effects on
# source.

FM_CREW_ADMISSION_DEFAULT_MAX=6

# fm_crew_admission_max: the configured concurrent-crew ceiling, printed on
# stdout. FM_MAX_CREW wins when set; else the first non-empty line of
# CONFIG/max-crew; else FM_CREW_ADMISSION_DEFAULT_MAX. Returns 1 with a clear
# stderr message on a malformed override rather than silently falling back -
# a typo'd cap should be reported, not ignored.
fm_crew_admission_max() {
  local raw source
  if [ -n "${FM_MAX_CREW:-}" ]; then
    raw=$FM_MAX_CREW
    source=FM_MAX_CREW
  elif [ -f "$CONFIG/max-crew" ]; then
    raw=$(awk 'NF { print; exit }' "$CONFIG/max-crew")
    source='config/max-crew'
  else
    printf '%s' "$FM_CREW_ADMISSION_DEFAULT_MAX"
    return 0
  fi
  case "$raw" in
    ''|*[!0-9]*|0)
      echo "error: $source must be a positive integer (got: '$raw')" >&2
      return 1
      ;;
  esac
  printf '%s' "$raw"
}

# fm_crew_count_live: number of already-live ship/scout crews in this home,
# printed on stdout. A meta with kind=secondmate is never counted (persistent
# supervisors, not burst load). A meta with no window recorded yet - a spawn
# still mid-flight elsewhere - counts as live: undercounting a concurrent
# spawn racing this one is the unsafe direction.
fm_crew_count_live() {
  local meta count=0 kind window backend target
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    window=$(fm_meta_get "$meta" window)
    if [ -z "$window" ]; then
      count=$((count + 1))
      continue
    fi
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$(basename "$meta" .meta)"; then
      count=$((count + 1))
    fi
  done
  printf '%s' "$count"
}

# fm_crew_admission_check <kind>: refuse (return 1, message on stderr) a new
# ship/scout launch once this home's live crew count already meets the
# configured ceiling. Exempt for kind=secondmate - a secondmate AGENT is a
# persistent supervisor, not burst load, and is never counted or capped here.
fm_crew_admission_check() {
  local kind=$1 max live
  [ "$kind" != secondmate ] || return 0
  max=$(fm_crew_admission_max) || return 1
  live=$(fm_crew_count_live)
  if [ "$live" -ge "$max" ]; then
    echo "error: $live crew already live in this home, at the configured cap of $max - refusing this launch. Let one finish, raise the cap in config/max-crew, or override for one spawn with FM_MAX_CREW=<n>." >&2
    return 1
  fi
  return 0
}
