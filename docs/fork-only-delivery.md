# Fork-only delivery

Some firstmate-repo changes live only on this fork (`Bre77/firstmate`) and are never contributed upstream (`kunchenguid/firstmate`).
The ClickStack webhook receiver is the first example: it is specific to this captain's fleet and has no place upstream.
This note explains when to use fork-only delivery, why the default no-mistakes path cannot serve it, and how to run it.

## Upstream vs fork-only: pick at intake

| | Upstream delivery (default) | Fork-only delivery |
| --- | --- | --- |
| Intended home | `kunchenguid/firstmate:main` (shared with every user) | `Bre77/firstmate:main` (this fork only) |
| Use for | Anything generalizable to every firstmate user | Changes that only make sense for this fork and are never upstreamed |
| Validation | The no-mistakes pipeline (review, test, lint, CI) | The local quality gate (`bin/fm-fork-deliver.sh`), because the fork runs no CI |
| PR base | `kunchenguid/firstmate:main` | `Bre77/firstmate:main` |
| Landing | Captain merges the upstream PR | Firstmate folds the fork PR |
| Scaffold | `bin/fm-brief.sh <id> <repo>` (registered mode) | `bin/fm-brief.sh <id> <repo> --fork-only` |

If a change is generalizable to every firstmate user, deliver it upstream through the normal no-mistakes path; do not use fork-only just to skip the pipeline.
Fork-only is for changes that genuinely belong only on this fork.

## Why the no-mistakes path cannot retarget the fork

This clone's no-mistakes gate is wired for upstream contribution:

- It pushes feature branches to the fork (`Bre77/firstmate`), but opens PRs INTO the upstream repo (`kunchenguid/firstmate:main`).
- The PR base is fixed by the shared no-mistakes bare repo, whose `origin` remote is `kunchenguid`.
- There is no per-run or per-branch base override.

That routing is correct for upstream-intended work and must not change; retargeting the bare repo would misroute every normal `fm-brief-*` and general PR.
So a fork-only feature cannot simply "run no-mistakes against the fork" - the pipeline would still open (or attempt) an upstream PR and hit the upstream "PR must be raised via no-mistakes" provenance check.
Fork-only delivery therefore stays entirely off the no-mistakes bare repo and validates locally instead.

## The local quality gate

The fork (`Bre77/firstmate`) runs no CI, so local validation is the only gate before a fork PR lands.
`bin/fm-fork-deliver.sh` runs that gate by default as a mirror of `.github/workflows/ci.yml` (the `lint` and `tests` jobs):

1. `shellcheck` over the shell scripts that exist (`bin/*.sh`, `bin/backends/*.sh`, `tests/*.sh`).
2. Each `tests/*.test.sh` behavior test (needs `tmux` on PATH, as CI does).

Keep the default gate in sync with that workflow.
Pass `--check '<command>'` to substitute a different gate for a non-firstmate repo, or `--skip-validate` when validation was already run separately.

## Running it

The `--fork-only` brief tells the crewmate to branch off the fork main, implement, then deliver with `bin/fm-fork-deliver.sh`:

```sh
# firstmate, at intake, for a fork-only firstmate feature:
bin/fm-brief.sh <id> firstmate-fork --fork-only     # emit the fork-only contract
# ... replace {TASK}, spawn, supervise as usual ...
```

The crewmate, from inside its worktree on the `fm/<id>` branch:

```sh
bin/fm-fork-deliver.sh --title "<pr title>" --body-file <path>
```

which runs the local gate, pushes the branch to the `fork` remote, opens a PR into `Bre77/firstmate:main`, and prints the PR URL.
Options: `--validate-only` (gate only, no push/PR), `--fork-remote <name>` (default `fork`), `--base <branch>` (default the fork default branch), `--draft`.
The helper refuses to deliver from a detached HEAD or the fork default branch, so only a feature branch is ever delivered.

## Folding the fork PR

The crewmate reports `done: PR <url>`; firstmate reviews the diff and folds the fork PR.
Reviewing and merging use the same tooling as any other PR: `bin/fm-review-diff.sh <id>` (after `bin/fm-pr-check.sh <id> <url>` records `pr=`), then `bin/fm-pr-merge.sh <id> <url>`, which derives the repo from the URL and so merges on `Bre77/firstmate`.
Teardown then verifies the work landed exactly as it does for any ship task.
