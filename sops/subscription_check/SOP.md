# Subscription Check SOP

## Context

```toml
[tiers.standard]
amount_usdc = 0.1
period_days = 30

[tiers.premium]
amount_usdc = 0.25
period_days = 30

[subscription]
grace_period_days = 3
renewal_reminder_days = 5

[constants]
proxy_base_url = "https://solana-rpc-proxy.dharadarsh0.workers.dev"
merchant_wallet = "pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
usdc_mint = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
discord_guild = "1531347878906302484"
subscriber_role = "1531669950819733575"
subscribe_channel = "1531347878906302487"
wallet_mapping_path = "~/.zeroclaw/wallet_mapping.json"
```

---

## Steps

1. **Load subscriber records** — Recall subscriber_index from Memory_Store; fall back to one-time migration from wallet_mapping.json if empty.
   - tools: memory_recall, read_file, memory_store

   The `subscriber_index` entry is the authoritative roster of all Discord user IDs that have ever started an onboarding flow. Loading via the index gives an exact enumeration rather than a relevance-ranked search that could silently drop subscribers as the memory corpus grows.

   **Recall the Index:**
   Use the `memory_recall` tool with query `"subscriber_index"`, `strategy="bm25"`, and `limit=1` to retrieve the index entry.
   - Parse the recalled content as a JSON array of Discord user ID strings.
   - If the key is not found, content is absent, or parsing fails: treat as `index = []` and proceed to migration.
   - If the key is found and parses successfully: set `subscriber_ids = <parsed array>`. If the array is empty, proceed to migration. Otherwise skip migration and proceed to loading individual records.

   **On Memory_Store tool error** (the recall tool itself returns an error, not just an empty result):
   Post an operator alert to Subscribe_Channel:
   ```
   GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "⚠️ OPERATOR ALERT: Memory_Store unavailable at subscription check cycle start. No role changes made.">
   ```
   Then terminate the cycle immediately. Do NOT process any subscribers or modify any Discord roles.

   **Empty Index: Attempt One-Time Migration:**
   If `subscriber_ids` is empty (index not found or empty array), try to read `wallet_mapping.json` using the `read_file` tool at path `{wallet_mapping_path}`.

   If the file is not readable (does not exist, permission error, or any read error):
   Post a notice to Subscribe_Channel:
   ```
   GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "ℹ️ No subscribers registered in Memory_Store.">
   ```
   Terminate the cycle. Do not proceed further.

   If the file is readable:
   Parse the JSON. The file is a JSON object where each key is the `wallet_address` and each value contains at minimum `discord_user_id` and `discord_username`.
   For each entry in the JSON object:
   - Read `discord_user_id` and `discord_username` from the entry value. The JSON key is the `wallet_address`.
   - Call `GET {proxy_base_url}/keygen` to obtain a fresh `reference_key`. Expected response: `{"reference_key": "<base58 string>"}`. On non-2xx or missing `reference_key` field: skip this entry, continue with remaining entries.
   - Construct a Subscriber_Record with the schema: discord_user_id, discord_username, wallet_address, tier="standard", expected_amount_usdc=0.1, period_days=30, subscribed_at=null, expires_at=null, grace_started_at=null, reference_key from /keygen, status="pending_payment", last_known_status=null, renewal_dm_sent_for_expiry=null.
   - Store the record in Memory_Store under key `"subscriber:<discord_user_id>"`.
   After all entries have been processed, collect all successfully seeded `discord_user_id` values into a list and write the subscriber index: `store "subscriber_index" = JSON.stringify(["<id_1>", "<id_2>", ...])`. Set `subscriber_ids` = the list of seeded IDs.

   **Load Individual Records:**
   For each `discord_user_id` in `subscriber_ids`:
   - Use `memory_recall` with `query="subscriber:<discord_user_id>"`, `strategy="bm25"`, `limit=1`.
   - Parse the recalled content as a JSON object (the Subscriber_Record).
   - If the recall fails or content is missing/malformed: log a warning (write a memory entry under key `"error:load:<discord_user_id>"` with `{"event": "record_load_failed", "discord_user_id": "<id>", "timestamp": "<ISO 8601 UTC>"}`) and skip this subscriber for this cycle.
   - If successful: add the parsed record to `subscriber_records`.
   After iterating all IDs: set `subscriber_records` = the list of successfully loaded records.

2. **Set up processing state** — Initialize current time and summary tracking.
   - tools: none

   Set `current_time` = current UTC Unix timestamp in integer seconds (e.g., `1753920000`).
   Set `current_time_iso` = current UTC time as ISO 8601 string with millisecond precision (e.g., `"2026-08-01T12:00:00.000Z"`).
   Set `summary_rows` = empty list.

3. **Process each subscriber** — Check renewal window, invoke payment check, apply grace logic, determine role actions, persist records, and build summary.
   - tools: http_request, memory_store
   - requires_confirmation: false

   CRITICAL: Process each subscriber independently. A failure in any sub-step for one subscriber MUST NOT prevent processing of the remaining subscribers. Catch errors per subscriber and record `role_action = "check_failed"` for that subscriber in the summary.

   For each `record` in `subscriber_records`, execute the following logic in order:

   **Renewal Window Check:**
   Only execute if ALL of the following are true: `record.status == "active"`, `record.expires_at` is not null and is a valid ISO 8601 UTC timestamp, `unix(record.expires_at) - current_time ≤ renewal_reminder_days * 86400` (within 5 days of expiry), and `record.renewal_dm_sent_for_expiry != record.expires_at` (deduplication).
   If all four conditions hold:
   - Call `GET {proxy_base_url}/keygen` → capture `new_reference_key`. On non-2xx or missing field: retain `status = "pending_payment"`, log the error, skip DM delivery this cycle, and proceed to payment check with the unchanged record.
   - Record the current `record.expires_at` as `old_expires_at`.
   - Update `record`: set `record.reference_key = new_reference_key`, set `record.status = "pending_payment"`, set `record.renewal_dm_sent_for_expiry = old_expires_at`, keep `record.subscribed_at` and `record.expires_at` unchanged.
   - Persist the updated record to Memory_Store immediately under key `"subscriber:{record.discord_user_id}"`.
   - Build the renewal Solana Pay URL: `solana:{merchant_wallet}?amount={record.expected_amount_usdc}&spl-token={usdc_mint}&reference={new_reference_key}&label=ZeroClaw+Subscription&memo={record.discord_user_id}`.
   - Build the renewal DM message with subscription details and renewal URL.
   - Send the renewal DM via `GET {proxy_base_url}/discord/dm?user_id={record.discord_user_id}&content=<URL-encoded renewal message>`. On proxy failure: retain `status = "pending_payment"`, log the failure, and proceed to payment check.

   **Invoke check-payment SKILL:**
   Call the `check-payment` SKILL, passing the current `record` as the full context input. The SKILL returns status, role_action, expires_at, and highest_amount_usdc_seen.
   Update the in-memory `record` based on the SKILL result:
   - Update `record.status` from the SKILL result `status` field.
   - If the SKILL returns a non-null `expires_at`, update `record.expires_at` to that value.
   - If the SKILL returns `status = "active"`, set `record.grace_started_at = null`.
   - If the SKILL returns `status = "check_failed"`, set `record.last_known_status = record.status` (the prior status value before overwriting), then set `record.status = "check_failed"`.

   **Grace Period Logic:**
   Apply the following logic based on `record.status` after payment check. If `record.status` is `"active"`, `"check_failed"`, or `"pending_payment"`, skip to role action.
   - **Newly lapsed (grace_started_at is null):** Condition: `record.status == "lapsed"` AND `record.grace_started_at == null`. Actions: Set `record.grace_started_at = current_time_iso`, persist the updated record to Memory_Store, set `effective_status = "grace"` for this cycle, build a grace renewal Solana Pay URL using `record.reference_key`, compute `grace_expiry_iso` = ISO 8601 UTC of `(current_time + grace_period_days * 86400)` seconds, post a grace reminder to Subscribe_Channel. On proxy failure: retry once after 2 seconds; if the second attempt also fails: log the failure and continue.
   - **Within grace window:** Condition: `record.status == "lapsed"` AND `record.grace_started_at != null` AND `current_time - unix(record.grace_started_at) < grace_period_days * 86400`. Actions: Set `effective_status = "grace"`. No message posted (reminder already sent). Retain role.
   - **Grace period elapsed (expired):** Condition: `record.status == "lapsed"` AND `record.grace_started_at != null` AND `current_time - unix(record.grace_started_at) >= grace_period_days * 86400`. Actions: Set `effective_status = "expired"`, compute `grace_expiry_iso` = ISO 8601 UTC of `(unix(record.grace_started_at) + grace_period_days * 86400)` seconds. Do NOT post the role removal proposal here — that happens in the next step.
   - **Other statuses:** If `record.status` is `"active"`, `"check_failed"`, or `"pending_payment"`, set `effective_status = record.status`. No grace logic applies.

   **Discord Role Action:**
   Execute the following based on `effective_status`:
   - **`effective_status = "active"`:** Check whether the subscriber currently holds `subscriber_role` in `discord_guild` via `GET {proxy_base_url}/discord/guilds/{discord_guild}/members/{record.discord_user_id}`. If the member does NOT have `subscriber_role` (or if the response is 404): Grant the role via `GET {proxy_base_url}/discord/guilds/{discord_guild}/members/{record.discord_user_id}/roles/{subscriber_role}`. On success: set `role_action = "granted"`. On non-2xx: set `effective_status = "check_failed"`, set `role_action = "check_failed"`, post error notice to Subscribe_Channel. If the member already has `subscriber_role`: set `role_action = "unchanged"`. On Discord API non-2xx when checking membership (not 404): set `effective_status = "check_failed"`, set `role_action = "check_failed"`, post error notice to Subscribe_Channel.
   - **`effective_status = "expired"`:** Set `role_action = "removal_proposed"`. Do NOT remove the role in this step — the proposal is posted in the next step.
   - **`effective_status = "check_failed"`:** Set `role_action = "check_failed"`. Do NOT change the subscriber's role. Post an error notice to Subscribe_Channel.
   - **`effective_status = "grace"`:** Set `role_action = "unchanged"`. Retain the subscriber's role. No role change.
   - **`effective_status = "pending_payment"`:** Set `role_action = "unchanged"`. No role change.

   **Persist Updated Record:**
   Write the fully updated `record` back to Memory_Store: `store "subscriber:{record.discord_user_id}" = JSON.stringify(record)`. Ensure all datetime fields are ISO 8601 UTC strings with millisecond precision or `null`. Do not omit optional fields — write them as `null` if not set. On Memory_Store write failure: log the error and continue to the next subscriber. Do NOT terminate the cycle.

   **Append to Summary:**
   Add one row to `summary_rows`: `@{record.discord_username} | {record.tier} | {effective_status} | expires: {record.expires_at ?? "N/A"} | role: {role_action}`.

4. **Propose role removal** — Post role removal proposals for expired subscribers to Subscribe_Channel for admin approval.
   - kind: checkpoint
   - requires_confirmation: true

   For each subscriber where `role_action = "removal_proposed"` from the previous step:
   - Compute `grace_expiry_iso` = ISO 8601 UTC of `(unix(record.grace_started_at) + grace_period_days * 86400)` seconds.
   - Post a role removal proposal to Subscribe_Channel:
     ```
     GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "⚠️ ROLE REMOVAL PROPOSAL: @{record.discord_username}'s grace period has ended (expired at {grace_expiry_iso}). Admin approval required to remove Subscriber_Role.">
     ```
   On proxy failure: retry once after 2 seconds. If the second attempt also fails: log the failure and continue to the next subscriber. Do NOT block the entire step on a single failure.

5. **Execute approved removal** — Remove Subscriber_Role from Discord for approved proposals.
   - tools: http_request

   For each subscriber where the role removal proposal was approved in the previous step:
   - Remove the role via `GET {proxy_base_url}/discord/guilds/{discord_guild}/members/{record.discord_user_id}/roles/{subscriber_role}`.
   - On success: update the summary row for this subscriber to reflect `role_action = "removed"`.
   - On non-2xx: log the failure, post an error notice to Subscribe_Channel, and continue to the next subscriber. Do NOT block the entire step on a single failure.

6. **Post consolidated summary** — Send the processing summary to Subscribe_Channel.
   - tools: http_request

   After all subscribers have been processed, build the summary message:
   ```
   📊 Subscription Check Summary ({current_time_iso})
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   {row 1}
   {row 2}
   ...
   ```
   Each row in `summary_rows` is on its own line.

   **Sending rules:**
   - If the total message length is ≤ 2000 characters: post as one message.
   - If the total message length is > 2000 characters: split at 2000-character boundaries and post as multiple sequential messages in order.

   Post each message via: `GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded summary>`.
   On proxy failure posting the summary: log the failure. The summary is informational — its failure does NOT affect the correctness of actions already taken.

---

## Error Reference

| Failure | Detection | Response |
|---|---|---|
| Memory_Store unavailable at Step 1a | Recall tool returns error | Post operator alert, terminate cycle, no role changes |
| `subscriber_index` absent or malformed | Recall returns empty/bad content | Treat as empty index, proceed to Step 1b |
| `wallet_mapping.json` not readable in Step 1b | `read_file` returns error | Post no-subscribers notice, terminate cycle |
| `/keygen` non-2xx in Step 1b migration | Non-2xx HTTP | Skip that entry, continue with remaining entries |
| Individual record load fails in Step 1c | Recall error or bad JSON | Log warning entry, skip subscriber this cycle |
| `subscriber_index` write fails after migration (Step 1b) | Write tool error | Log error, subscriber records still valid |
| `/keygen` non-2xx in Step 4a renewal | Non-2xx HTTP | Log error, skip DM, proceed to Step 4b unchanged |
| check-payment SKILL returns `check_failed` | SKILL result status | Save `last_known_status`, no role change, post error notice |
| Grace reminder proxy failure (Step 4c Case A) | Non-2xx HTTP | Retry once after 2s; log and continue if still failing |
| Discord member check non-2xx (Step 4d) | Non-2xx HTTP | Set `check_failed`, post error notice, skip role action |
| Discord role grant non-2xx (Step 4d) | Non-2xx HTTP | Set `check_failed`, retain role, post error notice |
| Memory_Store write failure (Step 4e) | Write tool error | Log error, continue to next subscriber |
| Summary post failure (Step 5) | Non-2xx HTTP | Log failure, cycle still considered complete |

---

## Cycle Termination Conditions

The cycle terminates early (before processing any subscribers) only in these cases:

1. Memory_Store is unavailable at Step 1a (operator alert posted).
2. `subscriber_ids` is empty AND `wallet_mapping.json` is not readable (no-subscribers notice posted).

In all other cases — including individual subscriber record load failures and individual subscriber processing failures — the cycle runs to completion and posts a summary.
