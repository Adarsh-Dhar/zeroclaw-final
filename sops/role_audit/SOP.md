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

   **Case B — Record exists but `status` is anything else (`lapsed`, `expired`,
   `grace`, `check_failed`, `pending_payment` is NOT in this case):**
   Wait — `subscription_check` SOP owns the grace/lapsed/expired lifecycle.
   Do NOT remove the role here for lapsed/grace/expired status — that would
   bypass the grace period and removal-proposal checkpoint. Only remove
   for statuses that clearly have no subscription: `"cancelled"`, `"deleted"`,
   or any unrecognised/null status value.
   Set `audit_result = "skip_owned_by_subscription_check"` for lapsed/grace/expired.

   **Case C — No record found, or record has null/empty `status`:**
   This member holds the role with no subscription record at all — orphan grant.
   Proceed to role removal below.
   Set `audit_result = "remove_orphan"`.

   **Role removal (Cases B-null and C only):**

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

   Step 2c — On role removal non-2xx: log to Memory_Store under key
   `"error:role_audit_removal:{member.id}:<ISO 8601 UTC>"` and continue.
   Do NOT re-attempt in the same cycle.

   Append to `audit_rows`: `{member.username} | {audit_result} | {timestamp}`

3. **Post audit summary**
   - tools: http_request

   Build summary:
   ```
   🔍 Role Audit Complete ({current_time_iso})
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Role holders checked: {count of role_holders}
   Roles removed (orphan): {count where audit_result = "remove_orphan"}
   Skipped (active sub): {count where audit_result = "ok"}
   Skipped (subscription_check owns): {count where audit_result = "skip_owned_by_subscription_check"}
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
| `memory_recall` tool error | Treat as "no record" (Case C), proceed to removal |
| Role removal non-2xx | Log error entry, continue to next member |
| Summary post non-2xx | Log failure, cycle still complete |
