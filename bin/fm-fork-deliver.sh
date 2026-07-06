#!/usr/bin/env bash
# Deliver a FORK-ONLY change: run the local quality gate in the current
# worktree, push the current branch to the fork remote, and open a PR into the
# fork's default branch. This is the first-class, codified version of what
# firstmate did by hand for the ClickStack webhook receiver.
#
# Why this exists: this clone's no-mistakes gate pushes branches to the fork but
# opens PRs INTO the upstream (kunchenguid) repo, and the PR base is fixed by the
# shared bare-repo's origin remote with no per-run override. That routing is
# correct for UPSTREAM-intended work. But a fork-only feature (e.g. the webhook
# receiver) must validate and land on the fork's own main WITHOUT going through
# the upstream "PR must be raised via no-mistakes" path and WITHOUT misrouting an
# upstream-intended run. This helper does exactly that, decoupled from the
# no-mistakes bare repo, so it can never misroute to upstream.
# See docs/fork-only-delivery.md for when to use fork-only vs upstream delivery.
#
# The fork repo runs no CI provenance check, so LOCAL validation is the only
# gate. The default gate mirrors .github/workflows/ci.yml (the lint + behavior
# tests jobs): shellcheck the shell scripts, then run each tests/*.test.sh. Keep
# it in sync with that workflow; pass --check to substitute a different gate.
#
# Operates on the current working directory's git worktree. Refuses to deliver
# from a detached HEAD or from the fork's default branch, so only a feature
# branch is ever delivered.
#
# Usage:
#   fm-fork-deliver.sh --title <text> (--body <text> | --body-file <path>) [options]
#   fm-fork-deliver.sh --validate-only [--check <command>]
# Options:
#   --title <text>        PR title (required unless --validate-only)
#   --body <text>         PR body text  } one required unless --validate-only
#   --body-file <path>    PR body file  }
#   --fork-remote <name>  fork remote name (default: fork)
#   --base <branch>       base branch on the fork (default: fork default branch, else main)
#   --check <command>     validation command run at the worktree root (default: the CI mirror)
#   --skip-validate       skip the local gate (use only when validated separately)
#   --validate-only       run the gate only; do not push or open a PR
#   --draft               open the PR as a draft
set -eu

usage() {
  # Print the "# Usage:" comment block (up to the first non-comment line).
  awk '/^# Usage:/{p=1} p{if($0 !~ /^#/)exit; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" >&2
}

TITLE=""
BODY=""
BODY_FILE=""
FORK_REMOTE="fork"
BASE=""
CHECK=""
SKIP_VALIDATE=false
VALIDATE_ONLY=false
DRAFT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE=${2:?--title needs a value}; shift 2 ;;
    --body) BODY=${2:?--body needs a value}; shift 2 ;;
    --body-file) BODY_FILE=${2:?--body-file needs a value}; shift 2 ;;
    --fork-remote) FORK_REMOTE=${2:?--fork-remote needs a value}; shift 2 ;;
    --base) BASE=${2:?--base needs a value}; shift 2 ;;
    --check) CHECK=${2:?--check needs a value}; shift 2 ;;
    --skip-validate) SKIP_VALIDATE=true; shift ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --draft) DRAFT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if "$SKIP_VALIDATE" && "$VALIDATE_ONLY"; then
  echo "error: --skip-validate and --validate-only are mutually exclusive" >&2
  exit 1
fi

# Must be inside a git worktree.
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: not inside a git worktree (run this from the task worktree)" >&2
  exit 1
}

# Must be on a named branch, never a detached HEAD.
BRANCH=$(git -C "$TOPLEVEL" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
  echo "error: HEAD is detached; check out your fm/<id> feature branch before delivering" >&2
  exit 1
}

# Resolve the fork remote and its owner/repo. Even --validate-only needs the
# remote so the guard against delivering from the fork's default branch applies
# uniformly, and so a misconfigured remote is caught before the gate runs.
git -C "$TOPLEVEL" remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || {
  echo "error: fork remote '$FORK_REMOTE' not found; add it or pass --fork-remote <name>" >&2
  exit 1
}
FORK_URL=$(git -C "$TOPLEVEL" remote get-url "$FORK_REMOTE")

parse_owner_repo() {
  # Accept https://github.com/<owner>/<repo>[.git][/] and
  # git@github.com:<owner>/<repo>[.git]. Echo <owner>/<repo>.
  local url=$1 path
  case "$url" in
    https://github.com/*) path=${url#https://github.com/} ;;
    git@github.com:*)     path=${url#git@github.com:} ;;
    *) echo "error: fork remote '$FORK_REMOTE' is not a GitHub URL: $url" >&2; return 1 ;;
  esac
  path=${path%.git}
  path=${path%/}
  if [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf '%s' "$path"
    return 0
  fi
  echo "error: cannot parse <owner>/<repo> from fork remote URL: $url" >&2
  return 1
}
FORK_SLUG=$(parse_owner_repo "$FORK_URL") || exit 1

# Resolve the fork's default branch (the delivery base) unless overridden.
fork_default_branch() {
  local ref b
  ref=$(git -C "$TOPLEVEL" symbolic-ref --quiet --short "refs/remotes/$FORK_REMOTE/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#"$FORK_REMOTE"/}"
    return 0
  fi
  for b in main master; do
    if git -C "$TOPLEVEL" show-ref --verify --quiet "refs/remotes/$FORK_REMOTE/$b"; then
      echo "$b"
      return 0
    fi
  done
  echo main
}
[ -n "$BASE" ] || BASE=$(fork_default_branch)

# Never deliver from the fork's own default branch: the crewmate works on a
# feature branch and firstmate folds it. This mirrors the never-push-to-default
# rule the fork-only brief carries.
if [ "$BRANCH" = "$BASE" ]; then
  echo "error: refusing to deliver from the fork default branch '$BASE'; deliver a feature branch" >&2
  exit 1
fi

# --- local quality gate -----------------------------------------------------
run_default_gate() {
  local targets=() t rc=0
  # Lint: shellcheck whatever shell scripts exist, matching the CI lint job.
  for t in bin/*.sh bin/backends/*.sh tests/*.sh; do
    [ -e "$TOPLEVEL/$t" ] && targets+=("$t")
  done
  if [ "${#targets[@]}" -gt 0 ]; then
    if command -v shellcheck >/dev/null 2>&1; then
      echo "gate: shellcheck ${#targets[@]} script(s)"
      ( cd "$TOPLEVEL" && shellcheck "${targets[@]}" ) || rc=1
    else
      echo "error: shellcheck not found but shell scripts are present; install it or pass --check" >&2
      return 1
    fi
  fi
  # Behavior tests: run each tests/*.test.sh, matching the CI tests job.
  local ran=false test_script
  if compgen -G "$TOPLEVEL/tests/*.test.sh" >/dev/null 2>&1; then
    ran=true
    for test_script in "$TOPLEVEL"/tests/*.test.sh; do
      echo "gate: $(basename "$test_script")"
      ( cd "$TOPLEVEL" && "$test_script" ) || rc=1
    done
  fi
  if [ "${#targets[@]}" -eq 0 ] && [ "$ran" = false ]; then
    echo "error: no default gate applies here (no shell scripts, no tests/*.test.sh); pass --check <command>" >&2
    return 1
  fi
  return "$rc"
}

if ! "$SKIP_VALIDATE"; then
  if [ -n "$CHECK" ]; then
    echo "gate: $CHECK"
    ( cd "$TOPLEVEL" && bash -c "$CHECK" ) || { echo "error: validation gate failed; not delivering" >&2; exit 1; }
  else
    run_default_gate || { echo "error: validation gate failed; not delivering" >&2; exit 1; }
  fi
  echo "gate: passed"
fi

if "$VALIDATE_ONLY"; then
  echo "validate-only: gate passed for branch '$BRANCH' (no push, no PR)"
  exit 0
fi

# --- open the fork PR -------------------------------------------------------
[ -n "$TITLE" ] || { echo "error: --title is required to open a PR" >&2; usage; exit 1; }
if [ -n "$BODY" ] && [ -n "$BODY_FILE" ]; then
  echo "error: pass only one of --body or --body-file" >&2
  exit 1
fi
if [ -z "$BODY" ] && [ -z "$BODY_FILE" ]; then
  echo "error: one of --body or --body-file is required to open a PR" >&2
  exit 1
fi
[ -z "$BODY_FILE" ] || [ -f "$BODY_FILE" ] || { echo "error: --body-file not found: $BODY_FILE" >&2; exit 1; }

echo "push: $BRANCH -> $FORK_REMOTE"
git -C "$TOPLEVEL" push "$FORK_REMOTE" "$BRANCH"

create_args=(pr create --repo "$FORK_SLUG" --base "$BASE" --head "$BRANCH" --title "$TITLE")
if [ -n "$BODY_FILE" ]; then
  create_args+=(--body-file "$BODY_FILE")
else
  create_args+=(--body "$BODY")
fi
"$DRAFT" && create_args+=(--draft)

echo "pr: opening against $FORK_SLUG:$BASE"
gh-axi "${create_args[@]}"
