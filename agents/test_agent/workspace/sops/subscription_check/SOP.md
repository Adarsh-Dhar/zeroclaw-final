# Subscription Check SOP

## Context

```toml
[tiers.standard]
amount_usdc = 10.0
period_days = 30

[tiers.premium]
amount_usdc = 25.0
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
wallet_mapping_path = "/Users/adarsh/Documents/zeroclaw/wallet_mapping.json"
```

---

## Step 1 — Load Subscriber Records

Use the `recall` memory tool to retrieve all entries whose key matches the prefix `"subscriber:"` from Memory_Store.

**On failure** (Memory_Store unavailable or returns an error):

Post an operator alert to Subscribe_Channel:

```
GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "⚠️ OPERATOR ALERT: Memory_Store unavailable at subscription check cycle start. No role changes made.">
```

Then terminate the cycle immediately. Do NOT process any subscribers or modify any Discord roles.

**On success:** Set `subscriber_records` = the list of recalled entries (may be empty). Proceed to Step 2.

---

## Step 2 — Check for Empty List / Trigger Migration

If `subscriber_records` is empty, proceed with the following sub-step. If `subscriber_records` is non-empty, skip to Step 4.

### Sub-step 2a — Attempt One-Time Migration

Try to read `wallet_mapping.json` using the `read_file` tool at path `{wallet_mapping_path}`.

**If the file is not readable** (does not exist, permission error, or any read error):

Post a notice to Subscribe_Channel:

```
GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "ℹ️ No subscribers registered in Memory_Store.">
```

Terminate the cycle. Do not proceed further.

**If the file is readable:**

Parse the JSON. The file is a JSON object where each key is the `wallet_address` and each value contains at minimum `discord_user_id` and `discord_username`.

For each entry in the JSON object:

1. Read `discord_user_id` and `discord_username` from the entry value. The JSON key is the `wallet_address`.

2. Call `GET {proxy_base_url}/keygen` to obtain a fresh `reference_key`.
   - Expected response: `{"reference_key": "<base58 string>"}`
   - On non-2xx or missing `reference_key` field: skip this entry, continue with remaining entries.

3. Construct a Subscriber_Record:
   ```json
   {
     "discord_user_id": "<from file>",
     "discord_username": "<from file>",
     "wallet_address": "<JSON key>",
     "tier": "standard",
     "expected_amount_usdc": 10.0,
     "period_days": 30,
     "subscribed_at": null,
     "expires_at": null,
     "grace_started_at": null,
     "reference_key": "<from /keygen>",
     "status": "pending_payment",
     "last_known_status": null,
     "renewal_dm_sent_for_expiry": null
   }
   ```

4. Store the record in Memory_Store under key `"subscriber:<discord_user_id>"`.

After all entries have been processed, set `subscriber_records` = the list of newly seeded records. Proceed to Step 4.

---

## Step 3 — Set Up Processing State

Set `current_time` = current UTC Unix timestamp in integer seconds (e.g., `1753920000`).

Set `current_time_iso` = current UTC time as ISO 8601 string with millisecond precision (e.g., `"2026-08-01T12:00:00.000Z"`).

Set `summary_rows` = empty list.

---

## Step 4 — Process Each Subscriber

> **CRITICAL: Process each subscriber independently. A failure in any sub-step for one subscriber MUST NOT prevent processing of the remaining subscribers. Catch errors per subscriber and record `role_action = "check_failed"` for that subscriber in the summary.**

For each `record` in `subscriber_records`, execute sub-steps 4a through 4f in order.

---

### Step 4a — Renewal Window Check

**Only execute this sub-step if ALL of the following are true:**

- `record.status == "active"`
- `record.expires_at` is not null and is a valid ISO 8601 UTC timestamp
- `unix(record.expires_at) - current_time ≤ renewal_reminder_days * 86400` (i.e., within 5 days of expiry)
- `record.renewal_dm_sent_for_expiry != record.expires_at` (deduplication: only send once per expiry cycle)

If all four conditions hold:

1. Call `GET {proxy_base_url}/keygen` → capture `new_reference_key`.
   - On non-2xx or missing field: retain `status = "pending_payment"` (do not revert), log the error, skip DM delivery this cycle, and proceed to Step 4b with the unchanged record.

2. Record the current `record.expires_at` as `old_expires_at` (used for dedup tracking below).

3. Update `record`:
   - Set `record.reference_key = new_reference_key`
   - Set `record.status = "pending_payment"`
   - Set `record.renewal_dm_sent_for_expiry = old_expires_at`
   - Keep `record.subscribed_at` and `record.expires_at` unchanged

4. Persist the updated record to Memory_Store immediately under key `"subscriber:{record.discord_user_id}"`.

5. Build the renewal Solana Pay URL:
   ```
   solana:{merchant_wallet}?amount={record.expected_amount_usdc}&spl-token={usdc_mint}&reference={new_reference_key}&label=ZeroClaw+Subscription&memo={record.discord_user_id}
   ```

6. Build the renewal DM message:
   ```
   🔔 ZeroClaw Subscription Renewal

   Your {record.tier} subscription expires on {record.expires_at}.

   Renew now:
   {renewal_solana_pay_url}

   Amount: {record.expected_amount_usdc} USDC / {record.period_days} days
   ```

7. Send the renewal DM:
   ```
   GET {proxy_base_url}/discord/dm?user_id={record.discord_user_id}&content=<URL-encoded renewal message>
   ```
   - On proxy failure: retain `status = "pending_payment"`. The record is already persisted with `renewal_dm_sent_for_expiry` set, so the key will not be re-rotated. DM delivery will be retried naturally in up to 3 subsequent hourly cycles. Log the failure and proceed to Step 4b.

---

### Step 4b — Invoke check-payment SKILL

Call the `check-payment` SKILL, passing the current `record` as the full context input (after any Step 4a mutations).

The SKILL returns:
```json
{
  "status": "active|lapsed|check_failed|pending_payment",
  "role_action": "grant|revoke|unchanged|check_failed",
  "expires_at": "ISO8601|null",
  "highest_amount_usdc_seen": "number|null"
}
```

Update the in-memory `record` based on the SKILL result:

- Update `record.status` from the SKILL result `status` field.
- If the SKILL returns a non-null `expires_at`, update `record.expires_at` to that value.
- If the SKILL returns `status = "active"`, set `record.grace_started_at = null`.
- If the SKILL returns `status = "check_failed"`, set `record.last_known_status = record.status` (the prior status value before overwriting), then set `record.status = "check_failed"`.

---

### Step 4c — Grace Period Logic

Apply the following logic based on `record.status` after Step 4b. If `record.status` is `"active"`, `"check_failed"`, or `"pending_payment"`, skip to Step 4d.

**Case A — Newly lapsed (grace_started_at is null):**

Condition: `record.status == "lapsed"` AND `record.grace_started_at == null`

Actions:

1. Set `record.grace_started_at = current_time_iso`.
2. Persist the updated record to Memory_Store immediately under key `"subscriber:{record.discord_user_id}"`.
3. Set `effective_status = "grace"` for this cycle.
4. Build a grace renewal Solana Pay URL using `record.reference_key`:
   ```
   solana:{merchant_wallet}?amount={record.expected_amount_usdc}&spl-token={usdc_mint}&reference={record.reference_key}&label=ZeroClaw+Subscription&memo={record.discord_user_id}
   ```
5. Compute `grace_expiry_iso` = ISO 8601 UTC of `(current_time + grace_period_days * 86400)` seconds.
6. Post a grace reminder to Subscribe_Channel:
   ```
   GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "⚠️ @{record.discord_username}'s subscription has lapsed. Grace period ends at {grace_expiry_iso}. Renewal: {renewal_solana_pay_url}">
   ```
   - On proxy failure: retry once after 2 seconds.
   - If the second attempt also fails: log the failure and continue. Do NOT block role evaluation on the message.

**Case B — Within grace window:**

Condition: `record.status == "lapsed"` AND `record.grace_started_at != null` AND `current_time - unix(record.grace_started_at) < grace_period_days * 86400`

Actions: Set `effective_status = "grace"`. No message posted (reminder already sent). Retain role.

**Case C — Grace period elapsed (expired):**

Condition: `record.status == "lapsed"` AND `record.grace_started_at != null` AND `current_time - unix(record.grace_started_at) >= grace_period_days * 86400`

Actions:

1. Set `effective_status = "expired"`.
2. Compute `grace_expiry_iso` = ISO 8601 UTC of `(unix(record.grace_started_at) + grace_period_days * 86400)` seconds.
3. Post a role removal proposal to Subscribe_Channel:
   ```
   GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "⚠️ ROLE REMOVAL PROPOSAL: @{record.discord_username}'s grace period has ended (expired at {grace_expiry_iso}). Admin approval required to remove Subscriber_Role.">
   ```

**Other statuses:**

If `record.status` is `"active"`, `"check_failed"`, or `"pending_payment"`, set `effective_status = record.status`. No grace logic applies.

---

### Step 4d — Discord Role Action

Execute the following based on `effective_status`:

**`effective_status = "active"`:**

Check whether the subscriber currently holds `subscriber_role` in `discord_guild`:

```
GET {proxy_base_url}/discord/guilds/{discord_guild}/members/{record.discord_user_id}
```

- If the member does NOT have `subscriber_role` (or if the response is 404): Grant the role:
  ```
  GET {proxy_base_url}/discord/guilds/{discord_guild}/members/{record.discord_user_id}/roles/{subscriber_role}
  ```
  *(This translates to a PUT equivalent via the proxy.)*
  - On success: set `role_action = "granted"`.
  - On non-2xx: set `effective_status = "check_failed"`, set `role_action = "check_failed"`, post error notice to Subscribe_Channel (see `check_failed` below).

- If the member already has `subscriber_role`: set `role_action = "unchanged"`.

- On Discord API non-2xx when checking membership (not 404): set `effective_status = "check_failed"`, set `role_action = "check_failed"`, post error notice to Subscribe_Channel (see `check_failed` below).

**`effective_status = "expired"`:**

Set `role_action = "removal_proposed"`. Role removal only proceeds after admin approval — the proposal was already posted in Step 4c Case C. Do NOT remove the role in this step.

**`effective_status = "check_failed"`:**

Set `role_action = "check_failed"`. Do NOT change the subscriber's role.

Post an error notice to Subscribe_Channel:
```
GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded: "❌ Check failed for @{record.discord_username} at {current_time_iso}. Role unchanged.">
```

**`effective_status = "grace"`:**

Set `role_action = "unchanged"`. Retain the subscriber's role. No role change.

**`effective_status = "pending_payment"`:**

Set `role_action = "unchanged"`. No role change.

---

### Step 4e — Persist Updated Record

Write the fully updated `record` back to Memory_Store:

```
store "subscriber:{record.discord_user_id}" = JSON.stringify(record)
```

Ensure all datetime fields are ISO 8601 UTC strings with millisecond precision (e.g., `"2026-08-01T12:00:00.000Z"`) or `null`. Do not omit optional fields — write them as `null` if not set.

On Memory_Store write failure: log the error and continue to the next subscriber. Do NOT terminate the cycle.

---

### Step 4f — Append to Summary

Add one row to `summary_rows`:

```
@{record.discord_username} | {record.tier} | {effective_status} | expires: {record.expires_at ?? "N/A"} | role: {role_action}
```

---

## Step 5 — Post Consolidated Summary

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

Post each message via:

```
GET {proxy_base_url}/discord/message?channel_id={subscribe_channel}&content=<URL-encoded summary>
```

On proxy failure posting the summary: log the failure. The summary is informational — its failure does NOT affect the correctness of actions already taken in Step 4.

---

## Error Reference

| Failure | Detection | Response |
|---|---|---|
| Memory_Store unavailable at Step 1 | Recall tool returns error | Post operator alert, terminate cycle, no role changes |
| `wallet_mapping.json` not readable in Step 2a | `read_file` returns error | Post no-subscribers notice, terminate cycle |
| `/keygen` non-2xx in Step 2a migration | Non-2xx HTTP | Skip that entry, continue with remaining entries |
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

1. Memory_Store is unavailable at Step 1 (operator alert posted).
2. `subscriber_records` is empty AND `wallet_mapping.json` is not readable (no-subscribers notice posted).

In all other cases — including individual subscriber failures — the cycle runs to completion and posts a summary.
