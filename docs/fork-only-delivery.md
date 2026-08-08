# Fork-only delivery

Some firstmate-repo changes live only on this fork (`Bre77/firstmate`) and are never contributed upstream (`kunchenguid/firstmate`).
The ClickStack webhook receiver is the first example: it is specific to this captain's fleet and has no place upstream.
This note explains when to use fork-only delivery, why the default no-mistakes path cannot serve it, and how to run it.

## Upstream vs fork-only: pick at intake

| | Upstream delivery (default) | Fork-only delivery |
| --- | --- | --- |
| Intended home | `kunchenguid/firstmate:main` (shared with every user) | `Bre77/firstmate:main` (this fork only) |
| Use for | Anything generalizable to every firstmate user | Changes that only make sense for this fork and are never upstreamed |
| Validation | The no-mistakes pipeline (review, test, lint, CI) | The local quality gate (`bin/fm-fork-deliver.sh`) before delivery, plus the fork's own PR checks after |
| PR base | `kunchenguid/firstmate:main` | `Bre77/firstmate:main` |
| Landing | Captain merges the upstream PR | Firstmate folds the fork PR |
| Scaffold | `bin/fm-brief.sh <id> <repo>` (registered mode) | `bin/fm-brief.sh <id> <repo> --fork-only` |

If a change is generalizable to every firstmate user, deliver it upstream through the normal no-mistakes path; do not use fork-only just to skip the pipeline.
Fork-only is for changes that genuinely belong only on this fork.

## Why the no-mistakes path cannot retarget the fork

A clone's no-mistakes gate is wired for upstream contribution when its `origin` remote is the parent (`kunchenguid/firstmate`):

- `no-mistakes init --fork-url <your-fork-URL>` records that fork URL as the push target while opening PRs against `origin`; a plain `no-mistakes init` (no `--fork-url`) works the same way for a maintainer who pushes `origin` directly.
- The PR base it resolves to is fixed at `init` time by the checkout's own `origin` remote at that moment; `no-mistakes status` reports it back as `remote:`.
- There is no per-run or per-branch base override.

That routing is correct for upstream-intended work and must not change; retargeting the bare repo would misroute every normal `fm-brief-*` and general PR.
So a fork-only feature cannot simply "run no-mistakes against the fork" - the pipeline would still open (or attempt) a PR against whatever `origin` resolved to at gate-init time, which for an upstream-wired clone is the upstream "PR must be raised via no-mistakes" provenance check.
Fork-only delivery therefore stays entirely off the no-mistakes bare repo and validates locally instead.

## When this clone's own `origin` is the fork, not the parent

Some clones of this repo are inverted relative to the layout above: `origin` points at the fork (e.g. `Bre77/firstmate`) and a separate `upstream` remote points at the parent (`kunchenguid/firstmate`), instead of the other way around.
Run `git remote -v` to check; `no-mistakes status`'s `remote:` line shows the same URL the gate actually targets.

In that layout, every no-mistakes run in this clone - not just fork-only ones - pushes to and opens PRs against the fork, because the gate's PR base was fixed at `init` time from this clone's own `origin`, and there is no supported way to repoint an already-initialized gate at a different base without re-running `init` against a checkout whose `origin` is the parent.
A PR opened by hand against the parent to route around this is not raised through the pipeline and fails the parent's required "PR must be raised via no-mistakes" check (`.github/workflows/no-mistakes-required.yml`): that check looks for a deterministic signature only a real pipeline run writes into the PR body, and hand-adding it without an actual pipeline run would misrepresent the PR's provenance rather than satisfy the check's intent.

### Sanctioned procedure for upstream contribution from an inverted clone

Follow CONTRIBUTING.md's contributor workflow using a second clone whose `origin` is the parent, kept separate from this one:

1. Clone the parent directly (or point an existing scratch clone's `origin` at it): `git clone https://github.com/kunchenguid/firstmate`.
2. Initialize its gate with this fork as the push target: `no-mistakes init --fork-url https://github.com/<fork-owner>/firstmate`.
3. Make the change there, then `git push no-mistakes` and drive the pipeline to a PR against the parent, per CONTRIBUTING.md's Workflow section.

`no-mistakes init` keys its gate off the checkout's `origin` URL, so this is purely additive: it registers a second, independent gate mirror and never touches this (inverted) clone's own gate, remotes, or the no-mistakes daemon's existing registration for this project.

**Limits:** setting up that second clone is a project-registration decision (see the `project-management` skill), not something a single task can do from inside its own disposable worktree - worktrees share the pooled clone's git config, so remotes cannot be changed per task, and the daemon's project registrations are shared fleet-wide state that a single task must not touch.
Until that second clone exists, treat an upstream-generalizable change discovered while working in an inverted clone as a decision for the captain or firstmate to route, rather than shipping it as a no-mistakes-mode PR from here.

## The local quality gate

`bin/fm-fork-deliver.sh` runs a local gate before pushing, as a mirror of `.github/workflows/ci.yml` (the `lint` and `tests` jobs):

1. `shellcheck` over the shell scripts that exist (`bin/*.sh`, `bin/backends/*.sh`, `tests/*.sh`).
2. Each `tests/*.test.sh` behavior test (needs `tmux` on PATH, as CI does).

Keep the default gate in sync with that workflow.
Pass `--check '<command>'` to substitute a different gate for a non-firstmate repo, or `--skip-validate` when validation was already run separately.
Once the branch is pushed, the fork's own `.github/workflows/ci.yml` runs the real PR checks: the lint job, the portable behavior-test suites, and the stock-macOS-Bash snapshot compatibility check.
A red check on the fork PR blocks folding the same as it would on an upstream PR.

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
In an inverted clone (see above), there is no remote literally named `fork` - the fork is reached through `origin` instead - so pass `--fork-remote origin` explicitly; the same substitution applies to the Setup step's `git fetch fork` command.

## Folding the fork PR

The crewmate reports `done: PR <url>`; firstmate reviews the diff and folds the fork PR.
Reviewing and merging use the same tooling as any other PR: `bin/fm-review-diff.sh <id>` (after `bin/fm-pr-check.sh <id> <url>` records `pr=`), then `bin/fm-pr-merge.sh <id> <url>`, which derives the repo from the URL and so merges on `Bre77/firstmate`.
Teardown then verifies the work landed exactly as it does for any ship task.
