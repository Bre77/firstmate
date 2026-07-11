---
name: betterstack-alert-response
description: >-
  Agent-only playbook for handling BetterStack status-page webhook events (fork-only firstmate feature).
  Use on a "check:" wake whose output names a "betterstack-alert" to read the event payloads stashed in state/betterstack-inbox/, triage them, act or relay, and clear each handled payload so it does not re-fire.
  Relevant only when the BetterStack webhook route is enabled (config/betterstack-webhook.env present; see docs/betterstack-webhook.md).
user-invocable: false
metadata:
  internal: true
---

# betterstack-alert-response

The BetterStack webhook route (fork-only; `docs/betterstack-webhook.md`) shares the ClickStack receiver's HTTP listener on `/betterstack`, persists each accepted status-page event to `state/betterstack-inbox/<name>.json`, and lets the watcher surface it.
An event reaches firstmate through the watcher as a `check:` wake whose payload looks like `betterstack-alert <count> pending (state/betterstack-inbox/): <file>...`.
This skill turns those stashed payloads into action.

This runs only when the route is on (the captain dropped `config/betterstack-webhook.env`; see `docs/betterstack-webhook.md`).
If no such wake is in play, this skill does not apply.

## When you are woken

The wake is a normal `check:` wake, so it is handled exactly like any other check per AGENTS.md section 8: drain the queue, then act.
The wake payload names the count and up to five pending files; the inbox directory is the source of truth for the full set.

## Procedure

1. **Read the pending payloads.**
   List `state/betterstack-inbox/*.json` (top-level only; `processed/` is the handled archive, never re-read).
   Each payload is the raw JSON BetterStack sent for `status.teslemetry.com`.
   The top-level `event_type` is `"incident"`, `"maintenance"`, or `"component_update"`; `page.status_indicator` (`operational`/`degraded`/`downtime`/`maintenance`) and `page.status_description` summarize the page's overall state.
   For an incident or maintenance event, the nested object's `*_updates` array is the FULL history to date, not just the latest delta - read the last entry in that array for the current status, and earlier entries for context if useful.
   For a `component_update` event, `component_update` names the change (`old_status` -> `new_status`) and `component` names the affected component.

2. **Resolve which service the event is about.**
   `status.teslemetry.com` is the Teslemetry production status page; cross-reference the incident/component name and `data/projects.md` to identify the affected service, exactly like normal task intake (AGENTS.md section 7).
   If it clearly maps to one project or known component, say so; if ambiguous, relay the raw event to the captain and ask.

3. **Decide the action, by the event's nature:**
   - **`operational`/resolved, or a routine `component_update` with no ongoing incident:** relay a one-line outcome summary to the captain (plain chat), no task.
   - **A new or escalating incident, or a `downtime`/`degraded` page status:** captain-relevant.
     Escalate immediately with the evidence (status, affected component, latest update text) and, if a production observability secondmate is registered for this scope (check `data/secondmates.md`), route the triage to it exactly like a ClickStack alert would be routed - the wake naming is deliberately parallel so the same intake routing applies.
   - **Scheduled maintenance:** relay the window (`starts_at`/`ends_at`) to the captain as an FYI; only escalate as urgent if a maintenance event carries an unexpected/unplanned status.
   - **Anything destructive, irreversible, or security-sensitive:** escalate to the captain; never self-act.
   When in doubt, relay to the captain rather than dispatching.

4. **Clear each handled payload - always, as the last step.**
   Move every payload you have acted on or relayed into `state/betterstack-inbox/processed/` (create it if needed): `mkdir -p state/betterstack-inbox/processed && mv state/betterstack-inbox/<file>.json state/betterstack-inbox/processed/`.
   This is mandatory and idempotent-critical: the poll re-surfaces any top-level payload on the next check, so a payload left in place would re-fire the same event every check cycle after the watcher re-arms.
   Moving it (rather than deleting) keeps an audit trail out of the poll's scan path.
   Handle every pending payload before re-arming the watcher; do not leave a top-level payload behind for "later".

5. **Record durable knowledge if any.**
   A recurring status-page pattern that reveals a project-intrinsic gotcha belongs in that project's `AGENTS.md` via normal crewmate delivery, or in `data/learnings.md` if it is a fleet-operational fact (AGENTS.md section 6 knowledge routing).
   A one-off event needs no record.

## Notes

- A same-id redelivery (BetterStack's own retry, or a new update to an in-progress incident/maintenance window) overwrites its inbox file in place with the latest full state, so you never act on a stale duplicate - see `docs/betterstack-webhook.md` "Idempotent inbox naming" for why an in-progress incident's later update is expected to overwrite, not append.
- The receiver never contacts firstmate directly and never touches the watcher lock or beacon, so nothing here needs to coordinate with the supervision backbone beyond normal check-wake handling.
- Captain-facing messages stay in outcome language (AGENTS.md section 9): describe the status-page event and what you are doing about it, not the inbox/poll/wake machinery.
