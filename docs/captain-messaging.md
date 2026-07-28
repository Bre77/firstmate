# Captain messaging over Twilio RCS for Business (fork-only)

A two-way text channel between firstmate and the captain over Twilio **RCS for Business**, sharing the ClickStack receiver's existing webhook listener and the fleet's existing durable wake queue.
This is a downstream-only feature for `Bre77/firstmate`; it is not upstreamed.

The captain's Android runs Google Messages (RCS-capable) and his Tesla reads the phone's default messaging app aloud and takes dictated replies.
That in-car experience is the whole point: every outbound message must be short, plain, speakable text, and every inbound reply is understood as spoken-then-transcribed, not typed.

It is modeled directly on the ClickStack and BetterStack webhook receivers (`docs/clickstack-webhook.md`, `docs/betterstack-webhook.md`): presence-gated, inert by default, purely additive, and non-interfering with the watcher backbone.
The Twilio sender ("Teslemetry") is a business RCS sender with **no phone number**, so unlike ordinary SMS there is no automatic carrier fallback - a send that Twilio rejects is a hard failure, never a silent one.

## Authority contract

An inbound text from the captain's verified phone number, delivered through Twilio's signed webhook, carries the captain's authority for **routine, reversible actions only** - the same standing as a spoken instruction relayed through any other trusted channel.
It does **not** expand authority beyond that: destructive, irreversible, or security-sensitive actions (merges, deletions, credential handling, anything AGENTS.md section 1 or section 7 already reserves for the captain's explicit word) still require confirmation through a trusted channel exactly as they do today.
A reply is trusted only when both the Twilio signature validates AND the message's `From` matches the configured `CAPTAIN_MSG_DESTINATION`; anything else is rejected before it ever reaches firstmate (see "Inbound route" below).

## Speech contract

Every outbound message must be safe to have read aloud by a car or a headset.
`bin/fm-captain-msg.sh` enforces this in the tool, not by convention - a message that fails any rule is refused (nonzero exit, reason on stderr) before it ever reaches Twilio:

- Plain text only: no URLs (`http://`, `https://`, `www.`), no markdown formatting characters (`` ` ``, `*`, `_`, `#`, `[`, `]`), no code fences (` ``` `).
- No control characters or raw non-ASCII text.
- 300 characters or fewer.
- Not empty.

This is a stricter subset of AGENTS.md section 9's captain-facing etiquette (plain outcomes, no internal terms, no verbatim tool output): every message sent through this channel must additionally read naturally as spoken words, batched like any other escalation rather than sent as step-by-step progress.

## Setup

1. **Twilio side (captain-owned, already provisioned):** an RCS for Business sender ("Teslemetry") attached to a Messaging Service, with no phone number in its sender pool.
2. **1Password (captain-owned):** two separate credentials, because Twilio always signs inbound webhooks with the Account Auth Token and never with an API key secret, so a Restricted API Key cannot serve both purposes:
   - Item `Twilio` in vault `CLI` (already present): `username` = a Restricted API Key SID (`SK...`, scoped to Messaging only), `credential` = its secret. Used for outbound sends.
   - Item `Twilio Auth Token` in vault `CLI` (**captain must add this** - it did not exist as of this feature's initial build): `credential` = the Twilio **Account** Auth Token (from the Twilio console's Account Info, not an API key). Used only to validate `X-Twilio-Signature` on inbound webhooks.
   - Both item/vault names are configurable (see "Config schema") if the captain prefers different naming.
3. **`config/captain-msg.env`** (gitignored, local): copy `docs/examples/captain-msg.env` and fill in the destination number, Account SID, and Messaging Service SID. This file's presence is the whole opt-in gate.
4. **Arm the shared receiver:** `bin/fm-captain-msg-arm.sh` (run as a standalone background task, exactly like `bin/fm-clickstack-arm.sh`). Then `bin/fm-captain-msg-arm.sh --show-url` to get the exact webhook URL.
5. **Twilio console:** paste that URL into the Messaging Service's inbound webhook configuration (HTTP POST, "when a message comes in").
6. **Smoke-test:** `bin/fm-captain-msg.sh "Firstmate messaging channel test - reply to confirm two-way"` and confirm receipt on the phone, then reply and confirm it surfaces as a pending inbound message (see "Inbound route" below).

If `op` cannot authenticate (`OP_SERVICE_ACCOUNT_TOKEN` missing) or a 1Password field cannot be read, `bin/fm-captain-msg.sh` and the receiver's arm both fail loudly with the exact field and item named - never a silent no-op.

## Config schema

`config/captain-msg.env`, resolved by `bin/fm-captain-msg-lib.sh`'s `cmsg_load_config` (an explicit environment variable always wins over the file, mainly for tests):

| Key | Default | Meaning |
| --- | --- | --- |
| `CAPTAIN_MSG_DESTINATION` | (required) | Captain's phone in E.164. The only send destination and the only accepted inbound sender. |
| `CAPTAIN_MSG_ACCOUNT_SID` | (required) | Twilio Account SID (`AC...`); needed to address the Messages REST resource even under API-key auth. |
| `CAPTAIN_MSG_MESSAGING_SERVICE_SID` | (required) | Messaging Service SID (`MG...`) whose sender pool holds the RCS Business sender. |
| `CAPTAIN_MSG_WEBHOOK_URL` | `https://fm.ba.id.au/captain-msg` | The exact public URL Twilio POSTs to; part of the signature computation, so it must match the Twilio console configuration byte-for-byte. |
| `CAPTAIN_MSG_OP_VAULT` | `CLI` | 1Password vault holding both Twilio credentials. |
| `CAPTAIN_MSG_OP_ITEM` | `Twilio` | 1Password item for the Restricted API Key (`username`/`credential`) used for outbound sends. |
| `CAPTAIN_MSG_OP_AUTHTOKEN_ITEM` | `Twilio Auth Token` | 1Password item for the Account Auth Token (`credential`) used for inbound signature validation. |

Unlike the ClickStack gate, the first three keys have **no safe default**: a present-but-incomplete file is a misconfiguration, reported loudly by every caller (`cmsg_require_config`), not treated as "feature off".
"Feature off" is specifically the gate file's total absence.

## Outbound: `bin/fm-captain-msg.sh`

```text
fm-captain-msg.sh "<message>"
```

1. Off (one-line refusal, exit 1) unless `config/captain-msg.env` is present and complete.
2. The message must pass the speech contract above.
3. Fetches the Restricted API Key SID/secret from 1Password at call time (never touches disk, stdout, or stderr; never appears in `curl`'s argv - see the script header for the config-file-on-stdin mechanism, mirroring `bin/fm-notify-captain.sh`).
4. `POST https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Messages.json` with `MessagingServiceSid`, `To`, `Body`, Basic-authed with the API key.
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
4. The validated request's `From` must equal `CAPTAIN_MSG_DESTINATION`, or it is rejected the same way - defense in depth beyond the signature, since the signature alone only proves "this Twilio account sent it", not "the captain sent it".
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

The colocated suite `tests/fm-captain-msg.test.sh` passes (see its header for exact coverage): the presence gate, speech-contract rejection (URLs, markdown, code fences, over-length, empty), signature validation accept/reject, `From` mismatch rejection, idempotent inbox naming, atomic persistence, and bootstrap activation/opt-out/incomplete-config reporting.

Live account verification and the live smoke send were **not completed** during this feature's initial build: read-only inspection of the Twilio account (via the existing `Twilio` 1Password item) returned `HTTP 401 {"code":20003,"message":"Authenticate"}` on every endpoint tried, including the unauthenticated-safe `Accounts.json` listing, so neither the Account SID nor the Messaging Service SID could be confirmed against the live account.
The credential's shape is correct (a 34-character `SK`-prefixed API Key SID paired with a 32-character secret), so this looks like an invalid, expired, or not-yet-propagated key rather than a wrong 1Password lookup.
The `Twilio Auth Token` 1Password item referenced in "Setup" also did not exist at build time.
Remaining verification is captain-side: confirm/regenerate the API key, add the Account Auth Token item, fill in `config/captain-msg.env`, then run the setup steps above.
