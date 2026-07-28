---
name: captain-msg-response
description: >-
  Agent-only playbook for handling inbound captain replies over Twilio RCS for Business (fork-only firstmate feature).
  Use on a "check:" wake whose output names "captain-msg" to read the reply payloads stashed in state/captain-msg-inbox/, apply the channel's authority contract, act or reply, and clear each handled payload so it does not re-fire.
  Relevant only when the captain messaging channel is enabled (config/captain-msg.env present; see docs/captain-messaging.md).
user-invocable: false
metadata:
  internal: true
---

# captain-msg-response

The captain messaging channel (fork-only; `docs/captain-messaging.md`) shares the ClickStack receiver's HTTP listener on `/captain-msg`, validates every inbound Twilio webhook's signature and sender before persisting it, and lets the watcher surface it.
A reply reaches firstmate through the watcher as a `check:` wake whose payload looks like `captain-msg <count> pending (state/captain-msg-inbox/): <file>...`.
This skill turns those stashed payloads into action.

This runs only when the channel is on (the captain dropped `config/captain-msg.env`; see `docs/captain-messaging.md`).
If no such wake is in play, this skill does not apply.

## When you are woken

The wake is a normal `check:` wake, so it is handled exactly like any other check per AGENTS.md section 8: drain the queue, then act.
The wake payload names the count and up to five pending files; the inbox directory is the source of truth for the full set.

## Procedure

1. **Read the pending payloads.**
   List `state/captain-msg-inbox/*.json` (top-level only; `processed/` is the handled archive, never re-read).
   Each file is a normalized envelope (`received_at`, `params`) where `params` holds every Twilio form field for that inbound message - the reply text is `params.Body`.
   The listener already validated the Twilio signature and confirmed `From` matches the configured captain number before persisting, so every file here is a genuine, trusted reply.

2. **Read the reply as spoken words, not typed text.**
   The captain dictated this in the car; expect informal phrasing, no punctuation discipline, and occasional transcription artifacts from in-car voice-to-text.
   Interpret intent generously rather than requiring an exact command syntax.

3. **Apply the authority contract (`docs/captain-messaging.md` "Authority contract").**
   A verified inbound reply carries the captain's authority for routine, reversible actions only - treat it exactly like an instruction relayed through any other trusted channel (AGENTS.md section 1, section 7).
   It does **not** authorize anything destructive, irreversible, or security-sensitive (merges, deletions, credential handling); those still need the captain's explicit word through whatever channel is actually appropriate for that decision.
   If the reply is answering a pending decision (a hold, an ask-user finding, a blocker) route it there per the normal decision/backlog contract; if it is a new instruction, treat it as ordinary intake per AGENTS.md section 7.

4. **Reply only when a reply is actually useful**, using `bin/fm-captain-msg.sh` (which enforces the speech contract itself - see `docs/captain-messaging.md` "Speech contract").
   A routine acknowledgment or status update does not need a text reply if the same information is already going to reach the captain through the normal chat escalation path (AGENTS.md section 9); reserve the RCS channel for outcomes and confirmations that matter while the captain is away from the normal interface (e.g. driving).
   Keep replies short, plain, multi-sentence text - never a link, never markdown, never over 300 characters; the tool itself will refuse anything that violates this, so a refusal here means the message needs to be simplified, not routed around.

5. **Clear each handled payload - always, as the last step.**
   Move every payload you have acted on into `state/captain-msg-inbox/processed/` (create it if needed): `mkdir -p state/captain-msg-inbox/processed && mv state/captain-msg-inbox/<file>.json state/captain-msg-inbox/processed/`.
   This is mandatory and idempotent-critical: the poll re-surfaces any top-level payload on the next check, so a payload left in place would re-fire every check cycle after the watcher re-arms.
   Handle every pending payload before re-arming the watcher; do not leave one behind for "later".

## Notes

- The listener rejects an invalid signature or a `From` mismatch before persisting anything, so a payload appearing in the inbox is never something to re-verify - trust it as you would any other already-validated wake.
- The receiver never contacts firstmate directly and never touches the watcher lock or beacon, so nothing here needs to coordinate with the supervision backbone beyond normal check-wake handling.
- This sender has no phone number and therefore no SMS fallback; if a reply attempt via `bin/fm-captain-msg.sh` fails, treat it as a real delivery failure (the captain did not receive it) and fall back to the normal chat escalation path rather than assuming the message got through.
