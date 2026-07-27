# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Claude, Codex, OpenCode, and Grok were observed under their own process names.
Kimi Code CLI 0.29.1 was observed under `kimi` on 2026-07-25.
Pi remained a generic `node` process and is intentionally inconclusive.

The structural multi-row composer reader, Kimi pointer-delivery path, and OpenCode 1.18.4 busy-queue behavior are pinned by:

```sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
```

Expected structural matrix: real text on any content row is pending; all-empty complete boxes are empty; unreadable, incomplete, or unsafe boxes are unknown; and non-bordered panes retain cursor-row compatibility.
Expected submit matrix: proven pending plus busy is accepted as queued; proven pending plus idle remains pending; ambiguous pending is never converted by the busy exception; and only a proven empty composer succeeds directly.

## Herdr

The compatibility floor is protocol 14.
The latest active verification uses Herdr 0.7.5 protocol 16 on macOS aarch64, with earlier 0.7.4, protocol-14, and 0.7.3 evidence retained where they define current behavior or fallbacks.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed current shapes:

```text
herdr 0.7.5
{"client":16,"server":16}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height; a 200-line request plus local trim was stable. |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible; long foreground tool waits required rendered-busy corroboration. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/fm-herdr-lab.sh` with a non-default `fm-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing captain-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Per-home and presentation topology

Per-home behavior is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed guarantee: the primary and secondmate used distinct home workspaces, a child launched by the secondmate stayed in that secondmate workspace, list-live remained home-scoped, and exact cleanup did not affect sibling homes.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from a secondmate home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, active-tab refusal, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
```

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact home-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default fleet session remained unchanged, and a repeat run was a no-op.

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.

`tests/fm-composer-ghost.test.sh`, `tests/fm-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.
The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; the byte-exact active regression is:

```sh
FM_SEND_MARKER_HERDR_E2E=1 \
  tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Away-mode transport

The Pi/Herdr return and injection path was reverified on Herdr 0.7.3 and Pi 0.80.7:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Observed guarantees: pending composer input refused injection and raised one alert; idle Pi accepted one marked escalation; the return gate refused ordinary work while a live blocker remained; resolving the blocker allowed the return flow.
The dedicated Herdr daemon workspace topology is covered by `tests/fm-afk-launch.test.sh` and preserves the captain tab's pane count.

### Watcher stale-dedup: semantic signal for a settled pane

`bin/fm-watch.sh`'s stale detection hashes a bounded pane capture and surfaces a fresh wake whenever a settled pane produces a new stable hash.
On herdr this churned: an idle or done `claude` pane repaints timer-driven volatile UI even when the crew has not changed - the `※ recap:` line toggling on and off, rotating `Tip:` lines, the animated `✻ …ed for Xm Ys` summary, and transient slash-completion menus - so the capture's hash flips every few minutes and re-wakes the supervisor for a crew that is genuinely done.
Verified live against the real herdr 0.7.1 backend on 2026-07-05 by capturing `herdr pane read --source recent --lines 200` for every workspace pane every 20 seconds for ~7 minutes and correlating with each pane's `agent get` state: a `done` pane produced 4 distinct hashes over the window and an `idle` pane 8, each one a spurious stale re-wake, while a plain post-exit shell pane stayed at 1.
Line-stripping the volatile rows before hashing does not converge, because those rows also change the total line count, which shifts the tail-N hash window over a variable-length prefix (measured: stripping still left 3 distinct hashes across 4 `done`-pane samples).

The fix keys the stale-dedup signal on the native SETTLED agent state instead of the pane content, but only after corroborating that the idle pane no longer renders the busy banner, per the native-idle-during-a-long-foreground-tool-call corroboration in [Current transport behavior](../herdr-backend.md#current-transport-behavior).
When `fm_backend_busy_state` reports `idle` (herdr's `idle`/`done`/`blocked` native agent state) and the last 6 non-blank pane lines do not match `BUSY_REGEX`, the watcher hashes the constant `agentstate:idle` rather than the capture, so a settled pane that merely repaints keeps one signal and is surfaced once; a genuine state change still mints a new signal and surfaces once.
tmux (busy state always `unknown`), a herdr pane whose state is `working`/`unknown`, and an `idle` herdr pane that still displays the busy banner keep the pane-content hash exactly as before, so the proven default path is unchanged byte-for-byte.
The same resolved busy state feeds both this signal and the existing busy-suppression check, so herdr's `agent.get` is read once per pane per poll, not twice.
This is a distinct axis from the native-idle corroboration gap above (a still-working crew misread as not-working); here a correctly-settled crew was surfaced repeatedly rather than once.

### Incident (2026-07-11/12): recurrence of the false-pending wedge, plus a daemon that outlived its own away-mode flag

Two separate defects on the same overnight primary claude-on-herdr pane (target `default:w3:pM`, backend herdr), diagnosed from `state/.supervise-daemon.log` (the only surviving evidence - see the capture gap noted below).

**Defect 1: the false-pending wedge recurred despite an earlier ghost-text fix.** The daemon logged continuous `inject deferred: supervisor composer not confirmed-empty (state=pending: ...)` from 18:29 through 07:39 the next morning (~9.4h, `ERROR: away-mode escalation undelivered` climbing from 20698s to 33964s across dozens of 5-minute wedge-alarm log lines) - the identical symptom, backend, and duration shape as the already-fixed 2026-07-10 ghost-text de-emphasis incident.
No raw composer-row bytes were captured for this run (unlike the 2026-07-10 incident, which had a live read-only `herdr pane read ... --format ansi` capture); `state/.subsuper-*` holds only delivery-cache artifacts, never a diagnostic pane dump.
**Capture gap:** a future recurrence needs the daemon (or an operator, read-only) to `herdr pane read <target> --format ansi` and persist the raw bytes the moment a wedge alarm fires, or this class of incident stays undiagnosable beyond "still state=pending."
Absent that capture, the strongest supported hypothesis is that claude's ghost-text rendering used SGR 90 ("bright black"/gray, the other conventional basic-ANSI de-emphasis code besides SGR 2 dim) rather than SGR 2 - `fm_composer_strip_ghost` (`bin/fm-composer-lib.sh`) stripped SGR 2 dim and dark-truecolor runs but treated SGR 90 as an ordinary foreground colour, so gray-rendered ghost text would read as real, persistent pending input for as long as it kept rotating.
Fixed by tracking SGR 90 as a de-emphasis run alongside SGR 2 dim (ended by a reset, SGR 39, 30-37, or any of 91-97 - real bright hues, never muted, so they stay kept).
Regression coverage: `tests/fm-composer-ghost.test.sh` (`test_strip_ghost_drops_sgr90_gray_ghost`, `test_sgr90_gray_ghost_only_composer_is_not_pending`, plus 91-97-stay-kept assertions) and `tests/fm-backend-herdr.test.sh` (`test_composer_state_claude_sgr90_gray_prompt_suggestion_ghost_is_empty`, reusing the exact overnight row shape from the 2026-07-10 fixture with SGR 90 in place of SGR 2).
`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` remains crew/secondmate-only (`bin/fm-spawn.sh`'s `launch_template`, applied to every `kind`, including secondmate, but never reachable for the human-launched top-level primary) - firstmate has no launch point to set it on a captain's own primary session, so the classifier is the only fixable layer here.

**Defect 2: the daemon outlived `state/.afk` by ~3.5h.** At 07:41:20, ~14s after a composer read showed real pending text (the captain typing their return message), the log switched from composer-pending defers to `inject deferred: afk inactive` - `state/.afk` was gone, meaning the captain had returned and firstmate had (by whatever means) cleared the flag - but daemon pid 1078131 kept polling, self-handling wakes, and buffering new escalations no delivery could ever reach until an unrelated event finally stopped it at 11:04:11.
Contrast: a healthy exit from the prior evening (18:31:24) shows `afk inactive` and `daemon shutting down` landing in the same log second - the flag clearing and the daemon dying were coupled.
Root cause: the daemon's own main loop never watched `state/.afk`; every exit path was 100% dependent on an external `SIGTERM` (`bin/fm-afk-launch.sh stop`) actually reaching it, and `fm-afk-launch.sh stop`'s kill step is itself gated on `daemon_lock_held_by_live_daemon` returning true - any false negative there (a stale or unreadable lock/identity file, while the daemon process is still genuinely alive) skips the kill entirely and falls straight through to clearing `state/.afk`, orphaning a daemon that never received a signal.
Fixed at the daemon's own layer instead of chasing that lock race: `fm_super_main`'s loop now checks `afk_active "$STATE"` at the top of every iteration and self-exits (calling the same `cleanup` the `TERM` trap uses) the moment the flag is gone, regardless of how it disappeared.
This makes "exit is automatic" (per the `/afk` skill's own description) a property of the daemon process itself, not of an external actor's signal delivery succeeding.
No last-ditch flush is attempted on this path: `escalate_flush`'s own presence gate would no-op it anyway (afk already inactive), and any buffered items survive in `state/.subsuper-escalations` for the "while you were out" catch-up.
Regression coverage: `tests/fm-afk-inject-e2e.test.sh`'s Scenario D spawns a real daemon process, clears `state/.afk` directly (no signal, no `fm-afk-launch.sh` call), and asserts the process exits itself within a few housekeeping ticks with the expected log lines.

### Incident (2026-07-16): fm-send false-negative on a landed steer (herdr, claude)

Two `fm-send` submit-verification false negatives were reported the same day, both herdr backend, both claude crews, both `error: text not submitted ... (Enter swallowed; text left in composer)` on a steer that had actually landed:

1. Steering a busy claude pane (~15:0x AEST): the pane accepted the text as a QUEUED message - composer cleared, pane showed "Press up to edit queued messages" - and `fm_backend_herdr_composer_state` read that as unsubmitted composer text.
2. A very narrow pane (~18:3x AEST): composer verification broke while the message visibly landed and processing began.

Neither incident's raw pane bytes were captured, so the fixes below are reasoned from the reported symptoms and the existing verified composer-classification design, not from a byte-for-byte real capture. Treat the exact row shapes in the two new `tests/fm-backend-herdr.test.sh` fixtures (`composer-claude-queued-hint-*`) as a plausible reconstruction, not a verified-real capture.

**Fix 1 (queued-message hint).** `bin/fm-composer-lib.sh` gained `FM_COMPOSER_QUEUED_HINT_RE` (default `Press up to edit queued messages`), checked in `fm_composer_idle_matches` independent of any caller-supplied `idle_re` - the same always-on treatment already given to the `❯`/`›` agent glyphs, since this hint is a fleet-wide (not per-harness-configured) signal that the composer is genuinely empty. `fm_backend_herdr_composer_state`'s structural bare-shape scan (`bin/backends/herdr.sh`) now also selects a row that IS this hint text even with no leading prompt glyph, since a busy pane may render the hint in place of the prompt row rather than after it. Herdr's own capture already delegates hint recognition to the same shared classifier, so a hint landing on any row it scans is covered.

**Fix 2 (narrow-pane capture).** `fm_backend_herdr_composer_state` now captures with `--source recent-unwrapped` instead of `--source recent` (verified live, herdr 0.7.3: `herdr pane read <pane> --source recent-unwrapped --format ansi` returns full LOGICAL lines regardless of terminal width - a very long status-bar row that would wrap under `--source recent` on a narrow pane comes back as one unbroken line). This is a targeted fix scoped to `fm_backend_herdr_composer_state`'s own capture only: `fm_backend_herdr_capture`/`fm_backend_herdr_capture_ansi` gained an optional third `[source]` argument (default `recent`, unchanged), so every other caller (`fm-peek.sh`, `fm-watch.sh`, and anything dispatched through `bin/fm-backend.sh`'s generic capture) keeps the human-legible, width-wrapped shape. tmux's own composer classifier was not touched by this fix; its narrow-pane handling is unrelated to herdr's capture-source choice.

Regression coverage: `tests/fm-composer-lib.test.sh`'s `test_queued_hint_is_empty_standalone_and_inline`; `tests/fm-backend-herdr.test.sh`'s `composer_state_claude_queued_hint_*` (hint below an empty prompt row, hint as the standalone bottom-most row, and a real pending row below a stale hint still winning) and `composer_state_requests_recent_unwrapped_capture` / `capture_ansi_and_plain_pass_through_an_explicit_source`.

### Verified bug: an unrecognized `--source` value hard-errors, not a graceful fallback

Verified 2026-07-18, herdr 0.7.3, protocol 16, Linux (`hq`).

`herdr pane read <pane> --source <value>` rejects any value outside its own enum (`visible`, `recent`, `recent-unwrapped`) with a nonzero exit and an error body, rather than falling back to a default:

```
$ herdr --session fm-crewstate-repro-q5 pane read w1:p1 --source recent --lines 200
brett@hq:~/.treehouse/firstmate-fork-87afa0/3/firstma
te-fork$
$ echo $?
0
$ herdr --session fm-crewstate-repro-q5 pane read w1:p1 --source fm-web-widget-tools-more-h3 --lines 200
Error: Custom { kind: Other, error: "invalid read source: fm-web-widget-tools-more-h3" }
$ echo $?
1
```

This mattered because `fm_backend_herdr_capture`'s third positional argument is `[source]`, but the shared `fm_backend_capture` dispatcher's cross-backend contract (`bin/fm-backend.sh`) is `<backend> <target> <lines> [expected-label]` - the shape zellij's and cmux's own capture functions genuinely implement.
Several callers written against that shared contract (`bin/fm-crew-state.sh`'s `pane_readable`, `bin/fm-watch.sh`'s heartbeat sweep, `bin/fm-peek.sh`, `bin/fm-fleet-snapshot.sh`) pass a task's `fm-<id>` expected-label positionally into what herdr treats as `source`.
The resulting CLI error made `fm_backend_herdr_capture` return failure for a target that was actually reachable, and `bin/fm-crew-state.sh`'s no-run fallback reported it as `state: unknown - backend target gone: <target>` for a pane independently confirmed alive via `fm-peek`.
A raw `session:pane` selector never carries an expected-label, so `fm-peek` invoked that way sidesteps the bug and reads correctly - which is why the two tools visibly disagreed on the same pane.
Since `bin/fm-crew-state.sh`'s `EXPECTED_LABEL` is unconditionally non-empty for any resolved task, every herdr crew reaching that fallback path hit this deterministically, not intermittently.

**Fix:** `fm_backend_herdr_normalize_source` validates the `[source]` argument against herdr's real enum before it reaches the CLI, falling back to `recent` for anything else (including a stray expected-label).
`tests/fm-backend-herdr.test.sh`'s `test_capture_normalizes_an_unrecognized_source_to_recent` covers it.

### Incident (2026-07-16 through 07-21): away-mode injection wedged by an NBSP-padded empty composer, not ghost text

Three away-mode injection wedges recurred after the SGR-90 fix above landed (2026-07-13): ~9h on 2026-07-20 (33247s undelivered), ~2h on 2026-07-21 (7262s undelivered), and 45 buffered escalations plus a `state/.subsuper-inject-wedged` marker on 2026-07-16/17.
Unlike every prior wedge in this section, the primary claude-on-herdr pane was confirmed genuinely idle throughout (`pane_is_busy` false), so this was not the "keep turns short, injection defers mid-turn" shape.

**Root cause, reproduced live.** An isolated Herdr lab session (`bin/fm-herdr-lab.sh`, never the live `default` session) ran a freshly launched `claude --dangerously-skip-permissions` pane, idle, no message sent.
`herdr --version`: 0.7.4.
`claude --version`: 2.1.217 (model "Fable 5").
The exact bytes `fm_backend_herdr_composer_state` itself reads (`herdr pane read <pane> --source recent-unwrapped --lines 20 --format ansi`), captured read-only from the lab pane and inspected with `hexdump -C`, showed the composer row is the bare `❯` prompt glyph followed by a NON-BREAKING SPACE (U+00A0, raw bytes `e2 9d af c2 a0`), carrying no ANSI styling at all.
`fm_composer_classify_content` (`bin/fm-composer-lib.sh`) trims and strips the leading glyph using bash's `[:space:]` class, which does not match U+00A0, so the trailing NBSP survived every trim/strip step and the row read `pending` forever.
Confirmed directly against the live lab pane: `fm_backend_herdr_composer_state "$TARGET"` returned `pending` before the fix and `empty` after, with `fm_backend_busy_state herdr "$TARGET"` reporting `idle` throughout both runs.
`housekeeping`'s batch-flush and max-defer retries (`FM_ESCALATE_BATCH_SECS`, default 90s; `FM_MAX_DEFER_SECS`, default 300s) were already re-probing on a bounded cadence the whole time - the wedge was a deterministic misclassification of the identical row on every retry, not an abandoned or broken retry loop.

**Fix.** `fm_composer_classify_content` normalizes a literal U+00A0 to a plain space before its trim and glyph-strip logic runs, so an NBSP-padded empty composer reads `empty` exactly like a space-padded one.
This is the single shared owner every adapter delegates to (tmux, herdr, orca, cmux), so no per-adapter change was needed.
Real typed text, including text carrying an incidental interior NBSP, still reads `pending`.

**Adjacent claim checked, not reproduced.** This investigation's brief also named a claim that `escalate_flush` fails to clear `state/.subsuper-escalations` on a successful delivery, causing an identical digest to re-inject.
Reading the current `escalate_flush` (`bin/fm-supervise-daemon.sh`) shows it truncates the buffer and removes `.since`/`.subsuper-inject-wedged` unconditionally on every successful `inject_msg`, and every call site (`housekeeping`'s batch flush and max-defer escape, and the daemon's shutdown `cleanup`) goes through this one function.
No other code path writes the buffer outside `escalate_add`'s own create-if-absent `.since` handling.
Left unchanged: no reproduction found in the current code.

**Regression coverage.** `tests/fm-composer-lib.test.sh`'s `test_nbsp_padded_glyph_is_empty` and `test_nbsp_padding_does_not_mask_real_text` pin the shared owner directly, byte-exact.
`tests/fm-backend-herdr.test.sh`'s `test_composer_state_claude_nbsp_padded_empty_composer_is_empty` and `test_composer_state_claude_nbsp_then_real_text_is_pending` reproduce the real captured row shape through the herdr adapter.
`shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` passes clean.

**Also noted, not fixed (out of scope for this fix).** While tracing the classifier, a bare (unbordered) dead-shell prompt glyph followed by a plain trailing space - `"$ "`, not just the exact single-character `"$"` - already misread as `empty` before this change too, via the same late glyph-strip fallback in `fm_composer_classify_content` that does not re-check the `bordered` flag after stripping the glyph.
This is a pre-existing gap in the bare-shell-prompt safety rule described above under [Composer and injection safety](../herdr-backend.md#composer-and-injection-safety), independent of the NBSP fix, and is left for a separate fix.

## Zellij

The current compatibility floor and latest verification are Zellij 0.44.0 with `jq` on macOS aarch64.
All real tests use a uniquely named session and `tests/zellij-test-safety.sh`; they never touch a session named `firstmate` or call all-session deletion.

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Headless session | `zellij attach -b <name>` without a TTY | Created a persistent background session and returned. |
| Session list | `zellij list-sessions --short --no-formatting` | Returned one plain name per line without starting a session. |
| Create tab | `zellij action new-tab --cwd <dir> --name <title>` | Returned a numeric tab id and focused the new tab when a client was attached. |
| Pane discovery | `zellij action list-panes --json` | Included terminal pane id, tab id, plugin flag, and top-level `pane_cwd`. |
| Literal send | `zellij action paste --pane-id <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-keys --pane-id <id> Enter`, `Esc`, and one argument `Ctrl c` | All three shared operations worked. |
| Capture | `dump-screen --pane-id <id>` or `--full` | Worked with no attached client; no line-bound flag exists. |
| Close | `close-tab-by-id <id>` | Removed the live task pane and tab together. |
| Failure exit | actions against missing targets | Returned exit 0, requiring structural preflight and output-shape validation. |

`pane_cwd` stayed frozen when a foreground subshell changed directory.
The marker-delimited `pwd` probe returned the live nested cwd and is covered by the real smoke.
The focus mitigation restored the previously active tab after `new-tab`, with the unavoidable narrow race documented in the operator guide.

```sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-zellij-smoke.test.sh
```

The real lifecycle smoke proved spawn, metadata, nested-subshell worktree discovery, send, capture, unlanded-work refusal, approved local landing, exact tab cleanup, and session cleanup without retaining task-specific ids or branch names here.

## Orca

Real readiness was verified against `/usr/local/bin/orca` with `/Applications/Orca.app` bundle version 1.4.116.

```sh
orca status --json
```

Observed fields:

```text
result.runtime.reachable=true
result.runtime.state=ready
```

`orca terminal create --json` returned `result.terminal.handle`.
`orca worktree create` returned `result.worktree.id` and `result.worktree.path`.
Speculative bare ids and nested terminal fields were deliberately rejected.

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

The fake-Orca suite covers readiness, registration, create response parsing, metadata routing, popup-safe submit, and path-matched release refusal.

## cmux

The current compatibility floor is cmux 0.64, and the active live evidence uses 0.64.17 build 97 on macOS aarch64.
Real tests use only exact `fm-test-` workspaces guarded by `tests/cmux-test-safety.sh` and never quit or relaunch the captain's app.

```sh
cmux version
cmux ping
```

Observed version:

```text
cmux 0.64.17 (97) [9ed29d81a]
```

Source and live checks established the five control modes:

- `off` starts no listener.
- `cmuxOnly` rejects an external Firstmate process by ancestry.
- `automation` uses an owner-only 0600 socket with no handshake.
- `password` uses the same 0600 socket plus `auth <password>`.
- `allowAll` uses a 0666 socket with no authentication.

The live default rejection was `Access denied - only processes started inside cmux can connect`.
The live password challenge was `Authentication required - send auth <password> first`.
The app configuration writer did not retain a hand-added socket password, which is why the operator guide requires Settings and a local Firstmate password source.

Current active CLI findings:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Create | `new-workspace --name <title> --cwd <dir> --focus false --id-format uuids` | Created one workspace with one surface without focusing it. |
| Fresh readiness | `list-panes --workspace <id> --json --id-format uuids` | Found a brand-new surface before content existed. |
| Fresh read counterexample | `read-screen` before any write | Returned `internal_error: Failed to read terminal text`. |
| Literal send | `send --workspace <id> --surface <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-key ... enter|escape|ctrl-c` | All shared key operations worked. |
| Nested cwd | `current_directory` plus foreground subshell | Structured cwd froze; the marker-delimited `pwd` probe found the live cwd. |
| Last surface | `close-surface` on the only surface | Refused with `invalid_state: Cannot close the last surface`. |
| Last workspace | `close-workspace` on the only workspace in a window | Printed success but left the workspace present. |

The last-workspace workaround was reverified on 2026-07-10 in Automation mode.
After creating one unfocused unnamed sibling in the same window, `close-workspace` removed the exact task workspace and left only cmux's default sibling.
A selected non-last workspace closed directly, proving that window cardinality rather than selection is the trigger.

Source inspection confirmed each workspace constructor creates a new UUID with no restored-id input.
Recovery therefore remains title-based.
The bundled Claude wrapper was observed stripping `CMUX_*` variables on its failed socket-probe path while retaining the app bundle id, supporting the macOS-only bundle-id and ancestry fallbacks.

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

The real smoke proves socket access, fresh readiness, current-path probing, send and keys, bounded capture, title identity, and guarded exact cleanup.

## Codex App host tools

A reusable Desktop host-tool smoke ran on 2026-07-06 against Codex Desktop bundle version 26.623.101652, build 4674, bundle id `com.openai.codex`.
Local paths and task-specific ids are intentionally not retained here.

The host-tool sequence was:

1. list a saved project;
2. create a Desktop-owned worktree thread;
3. recover and read the thread while active and after completion;
4. verify the thread appended a Firstmate status line and wrote its report;
5. send a follow-up to the same thread;
6. read the completed follow-up;
7. archive the exact thread;
8. read the archived transcript with state `notLoaded`.

Observed guarantee: a Desktop-owned thread can write Firstmate lifecycle files when the prompt provides an authorized absolute path, and create, send, read, and archive work at the Desktop host-tool layer.
The missing guarantee remains a supported shell-callable bridge that lets Firstmate perform those operations against the same visible Desktop endpoint.
App-server partial methods and raw socket experiments do not satisfy that bridge contract.
