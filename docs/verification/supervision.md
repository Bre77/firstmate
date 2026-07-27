# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-captain-translation-contract.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.93 | Passive `Stop` plus bounded resume | Project hook ran under trust, resumed once without inherited bypass permissions, and the environment latch prevented recursion. |

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

### 2026-07-15: watcher startup identity race closed

Reproduced repeatedly on 2026-07-14 and 2026-07-15: the guard blocked a turn end immediately after `bin/fm-watch-arm.sh`, reporting "no live watcher holds this home lock", while the watcher it had just armed was genuinely alive, with a live pid in `state/.watch.lock/pid` and a beacon that showed as freshly touched moments later.
Root cause: `bin/fm-watch.sh` published the watch lock's `pid` file, which is enough for `fm_pid_alive` to succeed, before it wrote the `fm-home`, `watcher-path`, and `pid-identity` files that `fm_watcher_lock_matches_pid` requires to match.
A guard read landing in that gap saw a live pid with no matching identity yet and reported an unhealthy watcher, even though the watcher was mid-startup and about to finish within milliseconds.
The gap widened under fleet load because `fm_pid_identity` shells out to `ps`, and the `pid` file was already visible to readers well before that subprocess returned.
The fix threads an optional `prep_fn` hook through `fm_lock_try_create`/`fm_lock_try_acquire` (`bin/fm-wake-lib.sh`) that writes into the not-yet-published lock owner directory before the `ln -s` that makes the lock discoverable.
`bin/fm-watch.sh` now writes `fm-home`, `watcher-path`, and `pid-identity` through that hook, so `pid` and identity become visible to any reader in one atomic step; there is no longer a window where the lock looks claimed but unmatched.
`tests/fm-watcher-lock.test.sh` (`test_lock_prep_fn_publishes_atomically_before_ln`) reproduces the window deterministically with a slow `prep_fn` and asserts the lock stays entirely undiscoverable until the write completes.

### 2026-07-15: watcher READ-side race closed

A second, distinct false-positive fired a dozen-plus times in the same sessions after the write-side fix above landed: the guard still reported "no live watcher holds this home lock" moments after a re-arm, with a live pid and a beacon that was demonstrably fresh (1-40s old) by the time it was inspected.
Root cause: `fm_watcher_healthy` and `fm_watcher_lock_matches_pid` read a watcher's `pid`, `fm-home`, `watcher-path`, and `pid-identity` via four separate `$state/.watch.lock/<file>` accesses, each independently re-following the `.watch.lock` symlink.
That symlink is swapped to a fresh owner directory whenever a re-arm steals a dead watcher's lock (`fm_lock_try_create`'s remove-then-recreate sequence in `bin/fm-wake-lib.sh`).
A reader landing between two of those four accesses while a swap was in flight could read fields from two different owners - a live pid from the new owner crossed with a stale or empty identity from the old one, or vice versa - and misreport a live, fresh-beacon watcher as mismatched, even though each owner's own published files were individually consistent.
The fix resolves the lock's owner directory exactly once per call (`fm_lock_read_dir`, `bin/fm-wake-lib.sh`) and reads every field from that fixed path, so a concurrent swap can no longer tear a read across two owners; a straggling reader either sees one owner's fully-consistent data or a clean absent read, never a chimera.
`fm_watcher_healthy` additionally retries a few times with a short sleep when that resolution fails while the beacon is still within grace, to ride out the residual sub-millisecond window where an owner directory is being torn down by its own process's exit trap; a stale beacon still short-circuits without retrying, since a real "no live watcher" report only gets slower, never wrong, from retrying it.
`tests/fm-watcher-lock.test.sh` (`test_watcher_healthy_survives_read_side_lock_swap`) reproduces the race deterministically: it arms a real watcher, resolves its owner directory once the way `fm_watcher_healthy` now does, swaps the published lock to a second dead owner, and asserts the already-resolved snapshot still describes the original owner consistently while a fresh call correctly reports the swapped-to dead owner as unhealthy.

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
