# BetterStack status-page webhook route (fork-only)

A route on the existing ClickStack webhook receiver that accepts BetterStack status-page subscription webhooks (from `status.teslemetry.com`) and wakes the firstmate supervisor so it can act on the update.
This is a downstream-only feature for `Bre77/firstmate`; it is not upstreamed.

It is modeled directly on the ClickStack webhook receiver (`docs/clickstack-webhook.md`), itself modeled on X mode: presence-gated, inert by default, purely additive, and non-interfering with the watcher backbone.
Where ClickStack accepts alert webhooks with a header-or-query shared secret, BetterStack status-page webhook subscriptions cannot deliver a custom header at all - authentication here is a single unguessable token carried in the URL query string instead.
Both routes surface work to firstmate through the same existing durable wake queue, as a `check:` wake.

## Why this shares the ClickStack receiver's process and port

The captain's reverse proxy (`fm.ba.id.au`) forwards the whole host to the ClickStack receiver's single port.
A second listener on a different port would be unreachable from the public internet without an out-of-repo reverse-proxy change, which this feature cannot make or verify.
So instead of a second daemon, `bin/fm-clickstack-listener.py` dispatches by path: any POST to `/betterstack` is handled by this route; everything else keeps its original ClickStack behavior, completely unchanged.
`bin/fm-clickstack-recv.sh` and `bin/fm-clickstack-arm.sh` now start the shared daemon when **either** gate file is present, and each route is independently 404'd off unless its own gate is present - so a captain who only wants BetterStack (no ClickStack) still gets a working, safely-scoped receiver, and the already-deployed ClickStack behavior is unaffected when only its own gate is present.

A parallel, independently-listening daemon was considered and rejected: it cannot be reached through the existing proxy without a manual, unverifiable infrastructure change, so it would ship a feature the captain could not actually use without a separate follow-up.
Sharing the process is the only design that is reachable today.

## What BetterStack webhook subscriptions actually support

Per BetterStack's own docs ([subscribing with webhooks](https://betterstack.com/docs/uptime/status-pages/subscribing-to-status-updates/subscribing-with-webhooks/)), a status-page webhook subscription:

- Is configured entirely from the status page's "Get updates" -> "Webhook" flow: an endpoint URL (must be `https://`) plus a confirmation email, no header/auth configuration in the UI.
- Delivers no custom headers and no signature - "use URL-based auth if needed" is BetterStack's own guidance, which is exactly what this route does (an unguessable `?token=` query parameter, validated server-side).
- Sends `event_type: "incident" | "maintenance" | "component_update"`, with a `page` object (status page id/indicator/description) and an event-specific nested object (`incident`, `maintenance`, or `component_update`) carrying its own `id` and, for incidents/maintenance, an `incident_updates`/`maintenance_updates` array that is the full history to date - not just the latest delta.
- Advises deduplicating on `id` fields so repeated deliveries don't create duplicate work.
- Uses a 10s connect / 30s total timeout, treats any 2xx as success, retries with exponential backoff (30s, ..., up to 8 minutes) for up to 10 attempts, and **deactivates the subscription** after exhausting retries.

That last point is why the listener always durably persists-then-202s before doing anything else (mirroring ClickStack): a slow or absent firstmate must never cause BetterStack to give up and silently stop delivering.

## Opting in (the presence gate)

The route is off (404) unless the firstmate home has a gitignored `config/betterstack-webhook.env` gate file.
Copy `docs/examples/betterstack-webhook.env` to `config/betterstack-webhook.env` to opt in, then arm:

```sh
bin/fm-betterstack-arm.sh          # generates a token on first run, (re)starts the shared receiver
bin/fm-betterstack-arm.sh --show-url   # prints the path and token, for building the subscription URL
```

Unlike ClickStack's secret, there is no safe empty default: with no token generated yet, every request to `/betterstack` is rejected.
`fm-betterstack-arm.sh` generates and persists an unguessable 32-byte urlsafe token (`python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`) into the gate file the first time it runs, and restarts the shared receiver so the new token takes effect immediately (the listener reads its config once, at process start; a config edit alone does not reach an already-running process).
On later runs, with a token already present and the shared receiver already healthy, it does a plain no-restart (re)arm so it never disrupts an already-serving ClickStack route.

| Key | Default | Meaning |
| --- | --- | --- |
| `BETTERSTACK_WEBHOOK_TOKEN` | (generated at first arm) | Unguessable token required as the `?token=` query parameter on every request. |

The subscription URL to paste into BetterStack's status page "Get updates" -> "Webhook" flow is:

```
https://<your-reverse-proxy-domain>/betterstack?token=<BETTERSTACK_WEBHOOK_TOKEN>
```

For this captain's deployment that is `https://fm.ba.id.au/betterstack?token=<BETTERSTACK_WEBHOOK_TOKEN>`, with the real token read from `config/betterstack-webhook.env` (or `bin/fm-betterstack-arm.sh --show-url`) - it is never printed by plain arming and never committed anywhere.

Removing the gate file opts out: the next locked session-start bootstrap removes the generated poll shim.
The route itself goes back to 404 only once the shared receiver is restarted (`bin/fm-clickstack-arm.sh --restart`), since - like the token - config is read once at process start; if ClickStack is also off at that point, `bin/fm-clickstack-recv.sh stop` stops the shared receiver entirely.

## Architecture

The feature adds two new pieces plus a config library, layered onto the existing ClickStack receiver rather than duplicating it (see "Why this shares..." above):

- `bin/fm-clickstack-listener.py` - unchanged for ClickStack; extended with a `/betterstack` route, dispatched by path, gated by its own `BSHOOK_ENABLED`/`BSHOOK_TOKEN` env passed in by the launcher.
- `bin/fm-clickstack-recv.sh` / `bin/fm-clickstack-arm.sh` - daemon lifecycle mechanics untouched (singleton lock, ready-file confirm loop); their "is anything enabled" gate now checks both `config/clickstack-webhook.env` and `config/betterstack-webhook.env`, and they pass BetterStack's token/inbox/enabled flag through to the listener alongside ClickStack's own config.
- `bin/fm-betterstack-lib.sh` - config resolution and path helpers for this route, mirroring `bin/fm-clickstack-lib.sh`'s shape; also owns token generation (`bshook_ensure_token`).
- `bin/fm-betterstack-poll.sh` - the watcher check-shim body that surfaces pending `state/betterstack-inbox/` payloads, mirroring `bin/fm-clickstack-poll.sh` exactly.
- `bin/fm-betterstack-arm.sh` - ensures a token exists, then delegates the actual daemon (re)arm to `bin/fm-clickstack-arm.sh` (one implementation of "start a listener and verify it bound", not two).

### Request handling

`POST /betterstack?token=<token>` with a BetterStack status-page event JSON body:

1. The route must be enabled (`config/betterstack-webhook.env` present) or the response is `404`, indistinguishable from an unconfigured path.
2. The supplied `token` query parameter must match `BETTERSTACK_WEBHOOK_TOKEN` via constant-time comparison, or the response is `401`.
   An unset token (not yet generated) always rejects.
3. The body is bounded by the same `CSHOOK_MAX_BODY` the ClickStack route uses (default 1 MiB); an oversized body is `413`, an empty body `400`.
4. The raw body is written **atomically** (temp file + `os.replace`) to `state/betterstack-inbox/<name>.json`, then the request is answered `202 Accepted` - inside BetterStack's "any 2xx" success contract, and only after the event is durably on disk, exactly like ClickStack.

`GET /healthz` is shared with the ClickStack route unchanged.

The listener never contacts the supervisor.
Its only per-request work is a fast local file write, so a slow or absent firstmate can never delay BetterStack's delivery within its 30s timeout, and never cause the 10-retry exhaustion that deactivates the subscription.

### Idempotent inbox naming

The inbox filename is derived from `event_type` plus that event's own nested id (`incident.id`, `maintenance.id`, or `component_update.id`) as `<event_type>-<id>.json`.
A redelivery of the exact same event (BetterStack's own retry, or a resubmitted webhook test) atomically overwrites its prior file in place.
A *new* update to an in-progress incident or maintenance window (BetterStack's own docs: "Deduplicate on `id` fields") also lands on the SAME id and overwrites - this is intentional, not a bug: each delivery's `incident_updates`/`maintenance_updates` array is BetterStack's complete history to date, so the newest payload is always a superset of the prior one, and firstmate only ever needs to act on the latest state.
A payload with no recognizable id gets a unique time+counter name, so distinct unrecognized events never collide.
The id is sanitized to a bounded `[A-Za-z0-9._-]` slug; the sender-issued value is never trusted into a path.

## Wake integration (the durable queue)

Identical mechanism to ClickStack, on its own independent shim and inbox:

1. The listener persists each accepted event to `state/betterstack-inbox/`.
2. When the gate is present, bootstrap generates `state/betterstack-watch.check.sh`, a check shim that execs `bin/fm-betterstack-poll.sh` (mirroring `state/clickstack-watch.check.sh`).
3. On each check cycle the watcher runs that shim.
   `fm-betterstack-poll.sh` scans the inbox for top-level `*.json` payloads and, if any are pending, prints one compact line: `betterstack-alert <count> pending (state/betterstack-inbox/): <file>...`.
4. The watcher's existing check path turns that output into a `check:` wake and enqueues it durably with `fm_wake_append check` - the same helper both integrations reuse, never a hand-formatted queue write.

Surfacing latency is bounded by the watcher check cadence (`FM_CHECK_INTERVAL`, default 300s), same as ClickStack.
The HTTP `202` is instant regardless, well inside BetterStack's 30s timeout.

### firstmate-side handling contract

Handling is the `betterstack-alert-response` agent-only skill (triggered from AGENTS.md section 13 on a `check:` wake naming a `betterstack-alert`).
In short: read the pending payloads from `state/betterstack-inbox/`, relay a status-page update to the captain or route it per normal intake (a production status-page incident routes the same way a ClickStack alert does, typically to whichever secondmate's scope covers uptime/observability), and, as the mandatory last step, move each handled payload into `state/betterstack-inbox/processed/` so the poll does not re-surface it.
The full procedure lives in the skill.

## Lifecycle and non-interference

Shares the ClickStack receiver's singleton, arm/re-arm, and non-interference properties exactly (see `docs/clickstack-webhook.md` "Lifecycle and non-interference"), with one addition: because the two routes share one process, `bin/fm-clickstack-recv.sh stop` / `bin/fm-clickstack-arm.sh --stop`/`--restart` act on **both** routes together - there is no way to stop only one without stopping the shared daemon.
To disable only the BetterStack route while keeping ClickStack live, remove `config/betterstack-webhook.env` and run `bin/fm-clickstack-arm.sh --restart`.

Bootstrap does not start the daemon itself (it must never block); it only generates the `state/betterstack-watch.check.sh` poll shim and prints a `BETTERSTACK:` line telling firstmate the route should be armed.
When the gate is present but `python3` is missing, bootstrap reports `MISSING: python3` and does not arm the shim (shared with the ClickStack check, since both routes need the same interpreter).

## Verification

Verified 2026-07-11 with Python 3.11.2 on Linux.

`shellcheck` (the CI command) is clean on all new and edited scripts:

```
$ shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
shellcheck: clean (exit 0)
```

The colocated suite `tests/fm-betterstack.test.sh` passes, covering the presence gate (off = 404, inert), poll surfacing, live accept/persist, token rejection, idempotent redelivery (including a same-id "new update" overwrite), the shared-daemon dual-gate independence (BetterStack-only starts the daemon and 404s the ClickStack path; ClickStack-only 404s the BetterStack path), token generation and the no-restart-when-already-healthy path, the real port-to-durable-wake path through the actual watcher, and bootstrap activation/opt-out:

```
$ bash tests/fm-betterstack.test.sh
ok - poll is a hard no-op without the config gate
ok - recv and both arm wrappers are inert without either config gate
ok - poll surfaces only unhandled top-level inbox payloads
ok - a BetterStack-only gate starts the shared daemon and leaves the ClickStack path 404
ok - a ClickStack-only gate leaves the BetterStack route 404 regardless of token
ok - both gates together serve both routes concurrently on the shared port
ok - the route rejects a missing or wrong token and accepts the right one
ok - an unconfigured (empty) token rejects every request rather than defaulting open
ok - same-id redelivery (including an in-progress update) is idempotent; distinct/id-less events stay separate
ok - bshook_ensure_token generates an unguessable token once and is idempotent thereafter
ok - fm-betterstack-arm.sh recognizes an already-healthy daemon and skips the restart, --show-url matches
ok - a delivered webhook lands as a durable check wake through the real watcher
ok - bootstrap is inert without the config gate (non-users unaffected)
ok - bootstrap activates from the gate idempotently and cleans up on opt-out
```

The full existing `tests/fm-clickstack.test.sh` suite still passes unchanged, confirming the shared-listener refactor left ClickStack's own behavior untouched when only its gate is present.

A live loopback session (gate present, token generated via `bin/fm-betterstack-arm.sh --show-url`, ephemeral port standing in for the production 8111):

```
$ FM_HOME=<scratch home> bin/fm-betterstack-arm.sh &
$ FM_HOME=<scratch home> bin/fm-betterstack-arm.sh --show-url
betterstack webhook: path=/betterstack token=7LNWYPPs2Hmtc0tQxaE-ccK5RsB3-8-r5XoiW7zSnmI

$ curl -sS -o /dev/null -w "%{http_code}\n" \
    -H "Content-Type: application/json" \
    -d '{"event_type":"incident","page":{"id":12345,"status_indicator":"downtime","status_description":"Some services are down"},"incident":{"id":98765,"name":"Database connection issues","incident_updates":[{"id":1,"status":"investigating"}]}}' \
    "http://127.0.0.1:<port>/betterstack?token=7LNWYPPs2Hmtc0tQxaE-ccK5RsB3-8-r5XoiW7zSnmI"
202

$ curl -sS -o /dev/null -w "%{http_code}\n" -d '{"event_type":"incident"}' http://127.0.0.1:<port>/betterstack   # no token
401

$ ls state/betterstack-inbox/ ; cat state/betterstack-inbox/event-incident-98765.json
event-incident-98765.json
{"event_type":"incident","page":{"id":12345,"status_indicator":"downtime","status_description":"Some services are down"},"incident":{"id":98765,"name":"Database connection issues","incident_updates":[{"id":1,"status":"investigating"}]}}

$ curl -sS -o /dev/null -w "%{http_code}\n" -d '{"alertId":"x"}' http://127.0.0.1:<port>/webhook   # ClickStack path, its own gate absent
404

$ curl -sS http://127.0.0.1:<port>/healthz
{"status": "ok"}
```

The token above was generated for this scratch verification run only, on a throwaway loopback port; the scratch home was deleted immediately afterward and that token was never reachable from the internet.
