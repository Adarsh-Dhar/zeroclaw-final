# Role Audit SOP

Cross-reference every guild member who holds the Subscriber role against
Memory_Store subscription records. Anyone holding the role without a
corresponding `active` or `pending_payment` subscription record has their
role removed immediately — no approval checkpoint, no grace window.

This is a corrective sweep, not the ongoing renewal flow. Renewal grace
periods and removal proposals are handled by `subscription_check`. This
SOP only removes roles that were never legitimately granted (orphan grants,
test data, manual assignments, or records cleared from memory).

---

## Context

```toml
[constants]
proxy_base_url  = "https://solana-rpc-proxy.dharadarsh0.workers.dev"
discord_guild   = "1531347878906302484"
subscriber_role = "1531669950819733575"
subscription_channel = "1531347878906302487"
```

---

## Tool Call Format (Critical — Follow Exactly)

All tool parameters must be nested inside `"arguments"`.

```json
{"name": "http_request",  "arguments": {"url": "...", "method": "GET"}}
{"name": "memory_recall", "arguments": {"query": "subscriber:123456", "strategy": "bm25", "limit": 1}}
```

---

## Steps

1. **Fetch all guild members with subscriber role**
   - tools: http_request

   Call the raw members endpoint (returns full objects including role arrays):
   ```
   GET {proxy_base_url}/discord/guilds/{discord_guild}/members?limit=1000
   ```

   On non-2xx or unparseable JSON: log the error to Memory_Store under
   key `"error:role_audit:<ISO 8601 UTC>"` and terminate immediately.

   From the response array, filter to members where:
   - `member.user.bot` is false or absent
   - `"{subscriber_role}"` appears in `member.roles`

   Set `role_holders` = list of `{id: member.user.id, username: member.user.username}`
   for each matching member.

   If `role_holders` is empty: log a summary with `role_holders_count = 0`
   and terminate — nothing to audit.

2. **Check each role holder against Memory_Store**
   - tools: memory_recall, http_request

   CRITICAL: Process each member independently. A failure for one must
   NOT stop processing of the rest.

   For each member in `role_holders`:

   **Recall their subscription record:**
   ```json
   {"name": "memory_recall", "arguments": {"query": "subscriber:{member.id}", "strategy": "bm25", "limit": 1}}
   ```

   Evaluate the result:

   **Case A — Record exists with `status` = `"active"` or `"pending_payment"`:**
   This member has a legitimate subscription. Skip — do NOT remove the role.
   Set `audit_result = "ok"` for this member.

   **Case B — Record exists but `status` is `lapsed`, `expired`, `grace`, or `check_failed`:**
   Wait — `subscription_check` SOP owns the grace/lapsed/expired lifecycle.
   Do NOT remove the role here for lapsed/grace/expired status — that would
   bypass the grace period and removal-proposal checkpoint.
   Set `audit_result = "skip_owned_by_subscription_check"` for lapsed/grace/expired.

   **Case B2 — Record exists but `status` is `cancelled`, `deleted`, or any unrecognised value:**
   These statuses indicate the subscription was explicitly ended or is invalid.
   Proceed to role removal below (same as Case C).
   Set `audit_result = "remove_cancelled"`.

   **Case C — No record found, or record has null/empty `status`:**
   This member holds the role with no subscription record at all — orphan grant.
   Proceed to role removal below.
   Set `audit_result = "remove_orphan"`.

   **Case D — `memory_recall` itself errored (tool failure, not "no results"):**
   This is NOT the same as Case C. A lookup failure means you don't know
   this member's status — it does not mean they have no subscription.
   Do NOT remove the role. Log to Memory_Store under
   `"error:role_audit_lookup:{member.id}:<ISO 8601 UTC>"` and set
   `audit_result = "lookup_failed_skipped"`. Continue to the next member.

   **Role removal (Cases B2 and C only):**

   Step 2a — Remove the role:
   ```json
   {"name": "http_request", "arguments": {
     "url": "{proxy_base_url}/discord/guilds/{discord_guild}/members/{member.id}/roles/{subscriber_role}",
     "method": "DELETE"
   }}
   ```

   Step 2b — On success (2xx or 204): post a notice to Subscribe_Channel:
   ```
   GET {proxy_base_url}/discord/message?channel_id={subscription_channel}&content=<URL-encoded:
   "🔴 ROLE REMOVED (audit): @{member.username} held Subscriber role with no active subscription record. Role removed automatically.">
   ```
   For Case B2 (cancelled): include "cancelled" in the message context.

   Step 2c — On role removal non-2xx: log to Memory_Store under key
   `"error:role_audit_removal:{member.id}:<ISO 8601 UTC>"` and continue.
   Do NOT re-attempt in the same cycle.

   For Case D only (lookup failed): already logged above when the error occurred.

   Append to `audit_rows`: `{member.username} | {audit_result} | {timestamp}`

3. **Post audit summary**
   - tools: http_request

   Build summary:
   ```
   🔍 Role Audit Complete ({current_time_iso})
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Role holders checked: {count of role_holders}
   Roles removed (orphan): {count where audit_result = "remove_orphan"}
   Roles removed (cancelled): {count where audit_result = "remove_cancelled"}
   Skipped (active sub): {count where audit_result = "ok"}
   Skipped (subscription_check owns): {count where audit_result = "skip_owned_by_subscription_check"}
   Skipped (lookup failed): {count where audit_result = "lookup_failed_skipped"}
   ```

   Post to Subscribe_Channel:
   ```
   GET {proxy_base_url}/discord/message?channel_id={subscription_channel}&content=<URL-encoded summary>
   ```

   On failure: log and continue — the removals already happened, the
   summary is informational only.

---

## What this SOP does NOT do

- Does not remove roles from members with `status: lapsed`, `grace`, or
  `expired` — `subscription_check` owns that flow with its grace period
  and approval checkpoint.
- Does not send DMs to affected members — a channel notice is sufficient
  for an audit sweep; personal DMs are reserved for the live DM flow.
- Does not create or update any subscription records — read-only on
  Memory_Store except for error/warn log entries.

---

## Error Reference

| Failure | Response |
|---|---|
| `/members` non-2xx or bad JSON | Log error entry, terminate cycle |
| `memory_recall` tool error | Treat as unknown status (Case D) — skip, log, do NOT remove |
| Role removal non-2xx | Log error entry, continue to next member |
| Summary post non-2xx | Log failure, cycle still complete |
