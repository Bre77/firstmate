---
name: clickstack-alert-response
description: >-
  Agent-only playbook for handling ClickStack webhook alerts (fork-only firstmate feature).
  Use on a "check:" wake whose output names a "clickstack-alert" to read the alert payloads stashed in state/clickstack-inbox/, triage them, act or relay, and clear each handled payload so it does not re-fire.
  Relevant only when the ClickStack webhook receiver is enabled (config/clickstack-webhook.env present; see docs/clickstack-webhook.md).
user-invocable: false
metadata:
  internal: true
---

# clickstack-alert-response

The ClickStack webhook receiver (fork-only; `docs/clickstack-webhook.md`) accepts alert webhooks from ClickStack on a loopback port fronted by the captain's reverse proxy, persists each accepted payload to `state/clickstack-inbox/<name>.json`, and lets the watcher surface it.
An alert reaches firstmate through the watcher as a `check:` wake whose payload looks like `clickstack-alert <count> pending (state/clickstack-inbox/): <file>...`.
This skill turns those stashed payloads into action.

This runs only when the receiver is on (the captain dropped `config/clickstack-webhook.env`; see `docs/clickstack-webhook.md`).
If no such wake is in play, this skill does not apply.

## When you are woken

The wake is a normal `check:` wake, so it is handled exactly like any other check per AGENTS.md section 8: drain the queue, then act.
The wake payload names the count and up to five pending files; the inbox directory is the source of truth for the full set.

## Procedure

1. **Read the pending payloads.**
   List `state/clickstack-inbox/*.json` (top-level only; `processed/` is the handled archive, never re-read).
   Read each pending payload.
   It is the raw JSON body ClickStack sent; common fields are an id (`alertId`/`id`/`fingerprint`), a `title`/`state` (firing/resolved), `severity`, and `labels` identifying the service.
   Do not assume a fixed schema - ClickStack alert bodies vary; read defensively and summarize what is actually present.

2. **Resolve which project the alert is about.**
   Use the alert's service/label/title against what you know of the fleet (`data/projects.md` and the projects' code), exactly like normal task intake (AGENTS.md section 7).
   If it clearly maps to one project, say so; if ambiguous, relay the raw alert to the captain and ask.

3. **Decide the action, by the alert's nature:**
   - **Informational / resolved / low severity:** relay a one-line outcome summary to the captain (plain chat), no task.
   - **Actionable investigation ("why is error rate high on X"):** this is a scout task.
     Dispatch a crewmate scout against the resolved project per section 7, with the alert payload summarized in the brief, so the deliverable is a findings report.
   - **A clear, safe fix the captain has authorized (or a `yolo`-on project's routine call):** a ship task per section 7.
   - **Anything destructive, irreversible, or security-sensitive:** escalate to the captain; never self-act.
   When in doubt, relay to the captain rather than dispatching.

4. **Clear each handled payload - always, as the last step.**
   Move every payload you have acted on or relayed into `state/clickstack-inbox/processed/` (create it if needed): `mkdir -p state/clickstack-inbox/processed && mv state/clickstack-inbox/<file>.json state/clickstack-inbox/processed/`.
   This is mandatory and idempotent-critical: the poll re-surfaces any top-level payload on the next check, so a payload left in place would re-fire the same alert every check cycle after the watcher re-arms.
   Moving it (rather than deleting) keeps an audit trail out of the poll's scan path.
   Handle every pending payload before re-arming the watcher; do not leave a top-level payload behind for "later".

5. **Record durable knowledge if any.**
   A recurring alert that reveals a project-intrinsic gotcha belongs in that project's `AGENTS.md` via normal crewmate delivery, or in `data/learnings.md` if it is a fleet-operational fact (AGENTS.md section 6 knowledge routing).
   A one-off alert needs no record.

## Notes

- A redelivered alert with the same id overwrites its inbox file in place, so you never see stale duplicates; an updated (re-fired) alert re-surfaces because its payload changed.
- The receiver never contacts firstmate directly and never touches the watcher lock or beacon, so nothing here needs to coordinate with the supervision backbone beyond normal check-wake handling.
- Captain-facing messages stay in outcome language (AGENTS.md section 9): describe the alert and what you are doing about it, not the inbox/poll/wake machinery.
