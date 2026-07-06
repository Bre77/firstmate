# ClickStack webhook receiver (fork-only)

A small, robust local HTTP listener that accepts alert webhooks from ClickStack and wakes the firstmate supervisor so it can act on the alert.
This is a downstream-only feature for `Bre77/firstmate`; it is not upstreamed.

It is modeled directly on X mode (`docs/configuration.md` "X mode (.env)"): presence-gated, inert by default, purely additive, and non-interfering with the watcher backbone.
Where X mode pulls mentions from a remote relay, the ClickStack receiver accepts pushed webhooks on a local port; both surface work to firstmate through the same existing durable wake queue, as a `check:` wake.

## Opting in (the presence gate)

The receiver is off unless the firstmate home has a gitignored `config/clickstack-webhook.env` gate file.
Presence alone opts in; every setting has a safe default, so an empty gate file enables the receiver on `127.0.0.1:8092` with no shared secret.
Copy `docs/examples/clickstack-webhook.env` to `config/clickstack-webhook.env` and edit as needed.

| Key | Default | Meaning |
| --- | --- | --- |
| `CLICKSTACK_WEBHOOK_PORT` | `8092` | Loopback port the listener binds (verified free). |
| `CLICKSTACK_WEBHOOK_BIND` | `127.0.0.1` | Bind address; loopback only, behind the captain's reverse proxy. |
| `CLICKSTACK_WEBHOOK_SECRET` | (empty) | Optional shared secret; empty disables the secret check. |
| `CLICKSTACK_WEBHOOK_SECRET_HEADER` | `X-ClickStack-Secret` | Header the secret is read from. |

An explicit environment variable of the same name wins over the gate file, mainly for tests.
Removing the gate file opts out: the next locked session-start bootstrap removes the generated poll shim, and `bin/fm-clickstack-arm.sh --stop` stops the listener.

## Architecture

The feature is three cooperating parts plus a shared config library:

- `bin/fm-clickstack-listener.py` - the HTTP listener (Python 3 stdlib `ThreadingHTTPServer`).
- `bin/fm-clickstack-recv.sh` - the daemon controller: runs the listener under a home-scoped singleton lock; `serve` / `stop` / `status`.
- `bin/fm-clickstack-arm.sh` - the verifying (re-)arm wrapper firstmate runs as a harness-tracked background task, mirroring `bin/fm-watch-arm.sh`.
- `bin/fm-clickstack-poll.sh` - the watcher check-shim body that surfaces pending inbox payloads.
- `bin/fm-clickstack-lib.sh` - shared config resolution and path helpers.

### Why Python 3 stdlib

The listener is `http.server.ThreadingHTTPServer` from the Python 3 standard library.
It is a robust, dependency-light long-running daemon: no package manager, no lockfile, no vendored modules to review, and threading gives concurrent request handling for free so a burst of alerts is served in parallel.
Binding loopback only (the captain fronts it with a reverse proxy) keeps `http.server`'s threat surface appropriate for internal single-tenant use.
Node's stdlib `http` would serve equally well; Python was chosen for the compact, review-friendly single-file daemon and its native threading model.

### Request handling

`POST` to any path (typically `/webhook`) with a ClickStack alert JSON body:

1. If a shared secret is configured, the request must present it (in `CLICKSTACK_WEBHOOK_SECRET_HEADER`, or as a `?secret=` / `?token=` query parameter). A mismatch is rejected `401` with a constant-time comparison. No secret configured means any loopback POST is accepted.
2. The body is bounded by `CSHOOK_MAX_BODY` (default 1 MiB); an oversized body is `413`, an empty body `400`.
3. The raw body is written **atomically** (temp file + `os.replace`) to `state/clickstack-inbox/<name>.json`, then the request is answered `202 Accepted`. The alert is acked only after it is durably on disk, so ClickStack never considers an unstored alert delivered.

`GET /healthz` returns `200 {"status":"ok"}` and is used by the arm wrapper to confirm the port is serving.

The listener never contacts the supervisor.
Its only per-request work is a fast local file write, so a slow or absent firstmate can never block or delay ClickStack's delivery - the wake is done later and asynchronously by the watcher poll.

### Idempotent inbox naming

When the payload carries a recognizable id (`alertId`, `alert_id`, `incidentId`, `incident_id`, `groupKey`, `group_key`, `id`, `fingerprint`, `dedupKey`, `dedup_key`, or a nested `alert.id` / `incident.id`), the inbox filename is derived from it (`alert-<slug>.json`).
A ClickStack redelivery of the same alert then atomically overwrites its prior file instead of piling up duplicates.
A payload with no id gets a unique time+counter name, so distinct alerts never collide.
The id is sanitized to a bounded `[A-Za-z0-9._-]` slug; the relay-issued value is never trusted into a path.

## Wake integration (the durable queue)

The receiver surfaces alerts through the **existing** durable wake queue, never a parallel mechanism, exactly as X mode does:

1. The listener persists each accepted payload to `state/clickstack-inbox/`.
2. When the gate is present, bootstrap generates `state/clickstack-watch.check.sh`, a check shim that execs `bin/fm-clickstack-poll.sh` (mirroring `state/x-watch.check.sh`).
3. On each check cycle the watcher runs that shim. `fm-clickstack-poll.sh` scans the inbox for top-level `*.json` payloads and, if any are pending, prints one compact line: `clickstack-alert <count> pending (state/clickstack-inbox/): <file>...`.
4. The watcher's existing check path turns that output into a `check:` wake and enqueues it durably with `fm_wake_append check` - the same helper, reused, never a hand-formatted queue write. The wake is then drained by `bin/fm-wake-drain.sh` at the top of the next wake-handling turn, like any other wake.

This is why the receiver process itself does not call `fm_wake_append`: doing so would double-enqueue against the watcher's own check-path enqueue.
The inbox file is the durable record, and the poll re-scans it, so the alert survives a firstmate restart in every window - before the first poll (the poll re-surfaces the still-pending file after restart) and after the enqueue (the durable queue entry is drained at session start).

Surfacing latency is bounded by the watcher check cadence (`FM_CHECK_INTERVAL`, default 300s); an operator wanting faster local surfacing can lower it, the same knob X mode uses.
The HTTP `202` is instant regardless.

### firstmate-side handling contract

Handling is the `clickstack-alert-response` agent-only skill (triggered from AGENTS.md section 13 on a `check:` wake naming a `clickstack-alert`).
In short: read the pending payloads from `state/clickstack-inbox/`, resolve which project the alert is about, then relay to the captain, dispatch a scout/ship task, or escalate anything destructive - and, as the mandatory last step, move each handled payload into `state/clickstack-inbox/processed/` so the poll does not re-surface it.
The full procedure lives in the skill.

## Lifecycle and non-interference

The receiver is a clean, home-scoped singleton, run and re-armed like the watcher:

- **Singleton:** `bin/fm-clickstack-recv.sh serve` acquires `state/.clickstack-recv.lock` (via the shared `fm-wake-lib.sh` lock primitives). A second `serve` for the same home no-ops with `already running`.
- **Arm / re-arm:** firstmate runs `bin/fm-clickstack-arm.sh` as a harness-tracked background task at session start when the gate is present, mirroring `bin/fm-watch-arm.sh`. It forks the daemon, waits for the bound-and-listening marker (`state/.clickstack-recv.ready`), prints one honest status line (`started` / `healthy` / `FAILED`), and blocks on the child so a daemon death re-notifies firstmate to re-arm.
- **Stop / restart:** `bin/fm-clickstack-arm.sh --stop` / `--restart` and `bin/fm-clickstack-recv.sh stop` act only on the pid recorded in this home's lock - never a broad `pkill` that would hit sibling firstmate homes running the same daemon.
- **Non-interference:** the receiver is its own process with its own lock. It never touches the watcher's `state/.watch.lock` or its `state/.last-watcher-beat` beacon, and bootstrap wires it purely additively, with no edit to `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh`, or the afk daemon.

Bootstrap does not start the daemon itself (it must never block); it only generates the poll shim and prints a `CLICKSTACK:` line telling firstmate the listener should be armed.
When the gate is present but `python3` is missing, bootstrap reports `MISSING: python3` and does not arm the shim.

## Verification

Verified 2026-07-06 with Python 3.11.2 on Linux.

`shellcheck` (the CI command) is clean on all new and edited scripts:

```
$ shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
shellcheck: clean (exit 0)
```

The colocated suite `tests/fm-clickstack.test.sh` passes, covering the presence gate (off = inert), poll surfacing, live accept/persist, secret rejection, idempotent redelivery, the singleton, the real port-to-durable-wake path through the actual watcher, and bootstrap activation/opt-out:

```
$ bash tests/fm-clickstack.test.sh
ok - poll is a hard no-op without the config gate
ok - recv and arm are inert without the config gate
ok - poll surfaces only unhandled top-level inbox payloads
ok - listener accepts a POST, persists the raw payload, and leaves the watcher untouched
ok - listener rejects a missing or wrong shared secret and accepts the right one
ok - same-id redelivery is idempotent; id-less alerts stay distinct
ok - receiver is a clean home-scoped singleton
ok - a delivered webhook lands as a durable check wake through the real watcher
ok - bootstrap is inert without the config gate (non-users unaffected)
ok - bootstrap activates from the gate idempotently and cleans up on opt-out
```

A live loopback session (gate with port 8092 and `CLICKSTACK_WEBHOOK_SECRET=example-secret`, receiver armed via `bin/fm-clickstack-arm.sh`):

```
$ curl -sS -o /dev/null -w "%{http_code}\n" -H "X-ClickStack-Secret: example-secret" \
    -H "Content-Type: application/json" \
    -d '{"alertId":"AL-42","title":"High error rate","severity":"critical","state":"firing"}' \
    http://127.0.0.1:8092/webhook
202

$ curl -sS -o /dev/null -w "%{http_code}\n" -d "{...}" http://127.0.0.1:8092/webhook   # no secret
401

$ ls state/clickstack-inbox/ ; cat state/clickstack-inbox/alert-AL-42.json
alert-AL-42.json
{"alertId":"AL-42","title":"High error rate","severity":"critical","state":"firing"}
```

The real-watcher wake path (from `tests/fm-clickstack.test.sh` `test_wake_lands_through_watcher`): after a `202`-accepted webhook, running the actual `bin/fm-watch.sh` with checks due immediately surfaces the alert and enqueues a durable record such as:

```
<epoch>	1	check	<home>/state/clickstack-watch.check.sh	check: <home>/state/clickstack-watch.check.sh: clickstack-alert 1 pending (state/clickstack-inbox/): alert-AL-1001.json
```

which `bin/fm-wake-drain.sh` then surfaces as an ordinary `check` wake.
