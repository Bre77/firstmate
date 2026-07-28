# Captain messaging over Twilio RCS for Business (fork-only)

A two-way text channel between firstmate and the captain over Twilio **RCS for Business**, sharing the ClickStack receiver's existing webhook listener and the fleet's existing durable wake queue.
This is a downstream-only feature for `Bre77/firstmate`; it is not upstreamed.

The captain's Android runs Google Messages (RCS-capable) and his Tesla reads the phone's default messaging app aloud and takes dictated replies.
That in-car experience is the whole point: every outbound message must be short, plain, speakable text, and every inbound reply is understood as spoken-then-transcribed, not typed.

It is modeled directly on the ClickStack and BetterStack webhook receivers (`docs/clickstack-webhook.md`, `docs/betterstack-webhook.md`): presence-gated, inert by default, purely additive, and non-interfering with the watcher backbone.
The Twilio sender ("Teslemetry") is a business RCS sender with **no phone number and no Messaging Service** - it is addressed directly by its own channel address (`rcs:<agent-id>`) - so unlike ordinary SMS there is no automatic carrier fallback and no Twilio-side channel selection: a send that Twilio rejects is a hard failure, never a silent one.

## Authority contract

An inbound text from the captain's verified phone number, delivered through Twilio's signed webhook, carries the captain's authority for **routine, reversible actions only** - the same standing as a spoken instruction relayed through any other trusted channel.
It does **not** expand authority beyond that: destructive, irreversible, or security-sensitive actions (merges, deletions, credential handling, anything AGENTS.md section 1 or section 7 already reserves for the captain's explicit word) still require confirmation through a trusted channel exactly as they do today.
A reply is trusted only when both the Twilio signature validates AND the message's `From` (channel-prefix stripped, e.g. `rcs:+<E.164>` -> `+<E.164>`) matches the configured `CAPTAIN_MSG_DESTINATION`; anything else is rejected before it ever reaches firstmate (see "Inbound route" below).

## Speech contract

Every outbound message must be safe to have read aloud by a car or a headset.
`bin/fm-captain-msg.sh` enforces this in the tool, not by convention - a message that fails any rule is refused (nonzero exit, reason on stderr) before it ever reaches Twilio:

- Plain text only: no URLs (`http://`, `https://`, `www.`), no markdown formatting characters (`` ` ``, `*`, `_`, `#`, `[`, `]`), no code fences (` ``` `).
- No control characters or raw non-ASCII text.
- 300 characters or fewer.
- Not empty.

This is a stricter subset of AGENTS.md section 9's captain-facing etiquette (plain outcomes, no internal terms, no verbatim tool output): every message sent through this channel must additionally read naturally as spoken words, batched like any other escalation rather than sent as step-by-step progress.

## Setup

1. **Twilio side (captain-owned, already provisioned):** an RCS for Business sender ("Teslemetry", channel address `rcs:<agent-id>`), with no phone number and no Messaging Service - the sender is addressed directly.
2. **1Password (captain-owned):** two separate credentials, because Twilio always signs inbound webhooks with the Account Auth Token and never with an API key secret, so a Restricted API Key cannot serve both purposes:
   - Item `Twilio API key` in vault `CLI`: `username` = a Restricted API Key SID (`SK...`, scoped to Messaging only), `credential` = its secret. Used for outbound sends. A Standard API key cannot list the account itself (`Accounts.json`), so never health-check this credential against that endpoint - `messaging.twilio.com/v1/Services` or the account's own `Messages.json` both work.
   - Item `Twilio Auth token` in vault `CLI`: `credential` = the Twilio **Account** Auth Token (from the Twilio console's Account Info, not an API key). Used only to validate `X-Twilio-Signature` on inbound webhooks.
   - Both item/vault names are configurable (see "Config schema") if the captain prefers different naming.
3. **`config/captain-msg.env`** (gitignored, local): copy `docs/examples/captain-msg.env` and fill in the destination number, Account SID, and `CAPTAIN_MSG_FROM_ADDRESS` (the sender's bare channel address, e.g. `teslemetry_fwz8vdzw_agent` - no `rcs:` prefix needed, the tool adds it). This file's presence is the whole opt-in gate.
4. **Arm the shared receiver:** `bin/fm-captain-msg-arm.sh` (run as a standalone background task, exactly like `bin/fm-clickstack-arm.sh`). Then `bin/fm-captain-msg-arm.sh --show-url` to get the exact webhook URL.
5. **Twilio console:** paste that URL into the sender's inbound webhook configuration (HTTP POST, "when a message comes in").
6. **Smoke-test:** `bin/fm-captain-msg.sh "Firstmate messaging channel test - reply to confirm two-way"` and confirm receipt on the phone, then reply and confirm it surfaces as a pending inbound message (see "Inbound route" below).

If `op` cannot authenticate (`OP_SERVICE_ACCOUNT_TOKEN` missing) or a 1Password field cannot be read, `bin/fm-captain-msg.sh` and the receiver's arm both fail loudly with the exact field and item named - never a silent no-op.

## Config schema

`config/captain-msg.env`, resolved by `bin/fm-captain-msg-lib.sh`'s `cmsg_load_config` (an explicit environment variable always wins over the file, mainly for tests):

| Key | Default | Meaning |
| --- | --- | --- |
| `CAPTAIN_MSG_DESTINATION` | (required) | Captain's phone in plain E.164, no channel prefix. The only send destination and the only accepted inbound sender. |
| `CAPTAIN_MSG_ACCOUNT_SID` | (required) | Twilio Account SID (`AC...`); needed to address the Messages REST resource even under API-key auth. |
| `CAPTAIN_MSG_FROM_ADDRESS` | (see below) | The RCS sender's bare channel address (e.g. `teslemetry_fwz8vdzw_agent`), addressed directly with no Messaging Service. |
| `CAPTAIN_MSG_MESSAGING_SERVICE_SID` | (see below) | Messaging Service SID (`MG...`) whose sender pool holds the RCS sender, for an account that has one instead. |
| `CAPTAIN_MSG_WEBHOOK_URL` | `https://fm.ba.id.au/captain-msg` | The exact public URL Twilio POSTs to; part of the signature computation, so it must match the Twilio console configuration byte-for-byte. |
| `CAPTAIN_MSG_OP_VAULT` | `CLI` | 1Password vault holding both Twilio credentials. |
| `CAPTAIN_MSG_OP_ITEM` | `Twilio API key` | 1Password item for the Restricted API Key (`username`/`credential`) used for outbound sends. |
| `CAPTAIN_MSG_OP_AUTHTOKEN_ITEM` | `Twilio Auth token` | 1Password item for the Account Auth Token (`credential`) used for inbound signature validation. |

Exactly one of `CAPTAIN_MSG_FROM_ADDRESS` / `CAPTAIN_MSG_MESSAGING_SERVICE_SID` must be set: a Twilio account either exposes its RCS sender through a Messaging Service's sender pool (Twilio picks the channel; `To` stays plain) or, as this account does, has no Messaging Service at all and must be addressed directly by channel (both `From` and `To` need the `rcs:` prefix - confirmed live: a bare-number `To` with no Messaging Service failed, `rcs:+<E.164>` succeeded and was read). `bin/fm-captain-msg.sh` adds the `rcs:` prefix itself; store both config values as plain identifiers/numbers.
Unlike the ClickStack gate, `CAPTAIN_MSG_DESTINATION` and `CAPTAIN_MSG_ACCOUNT_SID` have **no safe default**, and neither does the addressing pair above: a present-but-incomplete file is a misconfiguration, reported loudly by every caller (`cmsg_require_config`), not treated as "feature off".
"Feature off" is specifically the gate file's total absence.

## Outbound: `bin/fm-captain-msg.sh`

```text
fm-captain-msg.sh "<message>"
```

1. Off (one-line refusal, exit 1) unless `config/captain-msg.env` is present and complete.
2. The message must pass the speech contract above.
3. Fetches the Restricted API Key SID/secret from 1Password at call time (never touches disk, stdout, or stderr; never appears in `curl`'s argv - see the script header for the config-file-on-stdin mechanism, mirroring `bin/fm-notify-captain.sh`).
4. `POST https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Messages.json`, Basic-authed with the API key, with `Body` plus either `From`/`To` (both `rcs:`-prefixed, direct channel addressing) or `MessagingServiceSid`/`To` (plain `To`, Twilio picks the channel), depending on which is configured.
5. A non-2xx response, a curl failure, or a missing `sid` in Twilio's response is a loud failure: nonzero exit, the reason on stderr, and an explicit reminder that this sender has no SMS fallback so the captain did not receive the message.
6. On success, prints the Twilio message SID and initial status (e.g. `queued`) to stdout.

## Inbound route

Shares the ClickStack receiver's listener process and port (`docs/clickstack-webhook.md` "Why this shares the ClickStack receiver's process and port" applies identically here: the reverse proxy forwards the whole host to one port).
`bin/fm-clickstack-listener.py` dispatches `POST /captain-msg` to its own handler, gated by `CMHOOK_ENABLED` (set from `config/captain-msg.env`'s presence by the launcher, `bin/fm-clickstack-recv.sh`).

Request handling, in order:

1. The route must be enabled or the response is `404`, indistinguishable from an unconfigured path.
2. The body is form-urlencoded (Twilio's native inbound format, not JSON) and bound by the same `CSHOOK_MAX_BODY` the other two routes share.
3. `X-Twilio-Signature` is validated with the standard Twilio algorithm (HMAC-SHA1 over the exact configured webhook URL plus every POST parameter, sorted by key, concatenated with no delimiters; keyed by the Account Auth Token) - reimplemented in the listener's stdlib Python rather than depending on `twilio-python`, because this daemon deliberately has no package manager or vendored dependencies (see the listener's module docstring) and this pip package was not available in this fork's build environment. The implementation is verified against Twilio's own documented canonical test vector (see "Verification" below).
   An invalid or missing signature is rejected with a generic `403` (no detail in the response body) but logged locally with the specific reason, so a misconfigured webhook URL or a rotated Auth Token stays diagnosable without leaking validation details to a would-be forger.
4. The validated request's `From` (with any `rcs:` channel prefix stripped) must equal `CAPTAIN_MSG_DESTINATION`, or it is rejected the same way - defense in depth beyond the signature, since the signature alone only proves "this Twilio account sent it", not "the captain sent it".
5. The raw form parameters are normalized into a JSON envelope (`received_at`, `params`) and persisted **atomically** (temp file + `os.replace`, mode 0600) to `state/captain-msg-inbox/message-<MessageSid>.json` - `MessageSid` gives idempotent dedup, exactly like the other two routes' id-based inbox naming.
6. Twilio gets an empty-TwiML `200` (`<Response></Response>`, meaning "no immediate reply") only after the message is durably on disk.

The listener never contacts the supervisor directly.
Surfacing to firstmate is entirely through the **existing** durable wake queue, identical in shape to the ClickStack/BetterStack integrations:

1. `bin/fm-captain-msg-poll.sh` (the body of the generated `state/captain-msg-watch.check.sh` check shim) scans `state/captain-msg-inbox/*.json` and, if any are pending, prints one compact `captain-msg <count> pending (state/captain-msg-inbox/): <file>...` line.
2. The watcher's existing check path turns that into a `check:` wake and enqueues it durably with `fm_wake_append check`.
3. Handling that wake, applying the authority contract above, replying with `bin/fm-captain-msg.sh`, and clearing the payload is the `captain-msg-response` agent-only skill (AGENTS.md section 13).

## Lifecycle and non-interference

Shares the ClickStack receiver's singleton, arm/re-arm, and non-interference properties exactly (`docs/clickstack-webhook.md` "Lifecycle and non-interference").
`bin/fm-captain-msg-arm.sh` always restarts the shared daemon (never a plain re-arm) because the Twilio Account Auth Token is fetched fresh from 1Password on every daemon start rather than cached anywhere - see its header for why a plain re-arm cannot safely detect a rotated credential.
`bin/fm-clickstack-recv.sh stop` / `bin/fm-clickstack-arm.sh --stop`/`--restart` act on all three integrations together, exactly as they already do for ClickStack and BetterStack.

## Public ingress follow-up

This route needs no new infrastructure: it rides the same reverse-proxied host and port the ClickStack and BetterStack routes already use, so `https://fm.ba.id.au/captain-msg` is reachable as soon as the shared daemon is armed.
No servers-repo change is required for this feature.

## Verification

Verified 2026-07-28 on Linux.

The HMAC-SHA1 signature implementation matches Twilio's own documented canonical example (`AuthToken=12345`, the standard `CallSid`/`Caller`/`Digits`/`From`/`To` sample parameters) byte-for-byte: `RSOYDt4T1cUTdK1PDd93/VVr8B8=`.

```
$ shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
shellcheck: clean (exit 0)
```

The colocated suite `tests/fm-captain-msg.test.sh` passes (see its header for exact coverage): the presence gate, speech-contract rejection (URLs, markdown, code fences, over-length, empty), the `CAPTAIN_MSG_FROM_ADDRESS`/`CAPTAIN_MSG_MESSAGING_SERVICE_SID` exactly-one-of contract, signature validation accept/reject, `From` mismatch rejection (with and without the `rcs:` prefix), idempotent inbox naming, atomic persistence, and bootstrap activation/opt-out/incomplete-config reporting.

Live account verification: read-only inspection against the live Twilio account (`messaging.twilio.com/v1/Services` and the account's own `Messages.json`, both authenticated with the `Twilio API key` 1Password item) confirmed the account has no Messaging Service, and that its own message history already carried a genuine outbound RCS send read by the captain's phone and multiple genuine inbound replies - all addressed with the `From`/`To` `rcs:`-prefixed, no-Messaging-Service shape this feature now implements, and a prior attempt with a bare (unprefixed) `To` and no Messaging Service on record as a failed send.
That live evidence is what drove the `CAPTAIN_MSG_FROM_ADDRESS` addressing mode and the inbound `From`-prefix-stripping fix in this revision; the 1Password item names in "Setup" reflect the account's actual current item names.
