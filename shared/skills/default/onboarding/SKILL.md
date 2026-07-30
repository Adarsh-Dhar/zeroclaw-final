---
name: onboarding
description: Handle a Discord subscribe command by generating a unique Solana Pay URL and QR code, persisting the subscriber record in Memory_Store, and posting the payment link to the Subscription_Channel.
version: 1.0.0
---

# Skill: Onboarding — Subscribe Command Handling

This skill is invoked by the `subscription_commands` SOP whenever it detects a `subscribe` command in the Subscription_Channel from a registered user. It manages the full onboarding flow: state lookup, reference key generation, Subscriber_Record persistence, Solana Pay URL construction, QR code generation, and Discord message posting.

**The skill uses only the `http_request` and Memory_Store (memory recall/store) tools. All external API calls route through the Proxy because the `http_request` tool has a POST-body bug — all writes must be issued as GET requests with URL-encoded parameters.**

---

## Inputs

The SOP provides these values to the skill before invoking it:

| Input | Type | Description |
|---|---|---|
| `discord_user_id` | string | Discord snowflake ID of the user who sent the subscribe command |
| `discord_username` | string | Discord username of the user (e.g. `adrs0890`) |
| `tier` | string | Subscription tier parsed from the command message. One of `"standard"` or `"premium"`. Defaults to `"standard"` if absent. |
| `wallet_address` | string | Solana wallet address (base58) already verified during registration |

---

## Constants

Embed these values exactly as shown — do not modify them.

```
Merchant_Wallet        = pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak
USDC_Mint              = 4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU
Subscription_Channel_ID = 1532423195884261377
Proxy_Base_URL         = https://solana-rpc-proxy.dharadarsh0.workers.dev
```

---

## Tier Configuration

| Tier | `expected_amount_usdc` | `period_days` |
|---|---|---|
| `standard` | `0.1` | `30` |
| `premium` | `0.25` | `30` |

---

## Tool Call Format (Critical — Follow Exactly)

When calling `http_request`, you MUST nest all parameters inside an `"arguments"` object. Never place `url`, `method`, or `headers` as siblings of `"name"`.

**CORRECT:**
```json
{"name": "http_request", "arguments": {"url": "https://example.com", "method": "GET"}}
```

**INCORRECT (will fail):**
```json
{"name": "http_request", "url": "https://example.com", "method": "GET"}
```

---

## Step 1: Check Existing Subscriber Record

Recall the memory key `"subscriber:<discord_user_id>"` from Memory_Store.

**If the record is found and `status = "active"`:**
- Post the following message to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Your ZeroClaw subscription is already active. It expires at <expires_at formatted as ISO 8601 UTC, e.g. 2026-08-28T00:00:00Z>.
  ```
  Use:
  ```
  GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1532423195884261377&content=<URL-encoded message>
  ```
- **STOP. Do not continue to Step 2.**

**If the record is found and `status = "pending_payment"`:**
- The subscriber already has a pending invoice. Re-use the existing `solana_pay_url` and QR URL stored in the record. Post to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — You already have a pending payment. Pay here: <solana_pay_url from record>
  QR: https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=<URL-encoded solana_pay_url from record>
  ```
- **STOP. Do not continue to Step 2.**

**If the record is not found, or has any status other than `"active"` or `"pending_payment"`:**
- Continue to Step 2.

---

## Step 2: Validate Tier

Check that the `tier` input is one of `["standard", "premium"]` (exact match, case-sensitive).

**If the tier is unrecognized:**
- Post to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Unrecognized subscription tier "<tier>". Available tiers: standard (0.1 USDC / 30 days), premium (0.25 USDC / 30 days). Example: "subscribe standard" or "subscribe premium".
  ```
- **STOP. Do not continue.**

**If the tier is valid:**
- Set `expected_amount_usdc` and `period_days` from the tier config table above:
  - `standard` → `expected_amount_usdc = 0.1`, `period_days = 30`
  - `premium` → `expected_amount_usdc = 0.25`, `period_days = 30`
- Continue to Step 3.

---

## Step 3: Validate Amount

Verify that `expected_amount_usdc` satisfies both conditions:
1. `expected_amount_usdc > 0`
2. The number of decimal digits in `expected_amount_usdc` is ≤ 6

**If either condition fails:**
- Post to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Configuration error: invalid amount for tier "<tier>". Please contact an admin.
  ```
- **STOP. Do not write any record.**

**If both conditions are met:**
- Continue to Step 4.

---

## Step 4: Generate Reference Key

Call the `/keygen` endpoint on the Proxy to obtain a cryptographically unique reference key:

```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/keygen
```

**Expected response (HTTP 200):**
```json
{"reference_key": "<44-char base58 string>"}
```

**If the response is non-2xx, or the JSON body does not contain a `reference_key` field:**
- Post to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Service error: failed to generate a payment reference key. Please try again in a moment.
  ```
- **STOP. Do not write any record.**

**If the call succeeds:**
- Store the returned `reference_key` value in memory for use in subsequent steps.
- Continue to Step 5.

---

## Step 5: Persist Subscriber_Record and Update Subscriber Index

### Step 5a: Write the Subscriber_Record

Write the following JSON object to Memory_Store under the key `"subscriber:<discord_user_id>"`:

```json
{
  "discord_user_id": "<discord_user_id>",
  "discord_username": "<discord_username>",
  "wallet_address": "<wallet_address>",
  "tier": "<tier>",
  "expected_amount_usdc": <expected_amount_usdc>,
  "period_days": <period_days>,
  "subscribed_at": null,
  "expires_at": null,
  "grace_started_at": null,
  "reference_key": "<reference_key>",
  "status": "pending_payment",
  "last_known_status": null,
  "renewal_dm_sent_for_expiry": null
}
```

Replace all `<placeholder>` values with the actual inputs and values from earlier steps. Numeric fields (`expected_amount_usdc`, `period_days`) must be stored as JSON numbers, not strings.

**If the Memory_Store write fails (tool returns an error or does not confirm the write):**
- Discard the `reference_key` obtained in Step 4 — it must not be reused.
- Post to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Service temporarily unavailable. Unable to save your subscription record. Please try again later.
  ```
- **STOP. Do not proceed to Discord message posting.**

**If the write succeeds:** continue to Step 5b.

---

### Step 5b: Update the Subscriber Index

The `subscriber_index` entry is the authoritative roster used by the subscription_check SOP to enumerate all subscribers without relying on relevance-ranked search. It must be kept in sync whenever a new subscriber is added.

1. Recall the memory key `"subscriber_index"` from Memory_Store.

2. Parse the recalled content as a JSON array of Discord user ID strings. If the key does not exist or the content is absent/malformed, start with an empty array `[]`.

3. If `"<discord_user_id>"` is **not already present** in the array, append it.

4. Write the updated array back to Memory_Store under key `"subscriber_index"`:
   ```json
   ["<id_1>", "<id_2>", ..., "<discord_user_id>"]
   ```
   Store the array as a JSON string (i.e., `JSON.stringify(updatedArray)`).

**If the index write fails:**
- Log the failure (write a memory entry under key `"error:index:<current_UTC_timestamp_ISO8601>:<discord_user_id>"` with `{"event": "subscriber_index_update_failed", "discord_user_id": "<discord_user_id>", "timestamp": "<ISO 8601 UTC>"}`).
- The subscriber record written in Step 5a is still valid — **do not roll it back**. The index is a secondary structure; its inconsistency should be flagged for operator review, not used as a reason to abort onboarding.
- Continue to Step 6.

**If the index write succeeds:** continue to Step 6.

---

## Step 6: Construct Solana Pay URL

Build the Solana Pay URL using this exact format — no deviations:

```
solana:<Merchant_Wallet>?amount=<expected_amount_usdc>&spl-token=<USDC_Mint>&reference=<reference_key>&label=ZeroClaw+Subscription&memo=<discord_user_id>
```

**Example (standard tier, user ID `1531681016249319576`, reference key `4vJ9JU1bfGg1xPcDxY2xFRG7JbN3TxWqZvKmPsHcL8E`):**
```
solana:pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak?amount=0.25&spl-token=4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU&reference=4vJ9JU1bfGg1xPcDxY2xFRG7JbN3TxWqZvKmPsHcL8E&label=ZeroClaw+Subscription&memo=1531681016249319576
```

**Example (premium tier):**
```
solana:pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak?amount=0.25&spl-token=4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU&reference=<reference_key>&label=ZeroClaw+Subscription&memo=<discord_user_id>
```

Store the constructed URL as `solana_pay_url` for use in Steps 7 and 8.

Continue to Step 7.

---

## Step 7: Generate QR Code URL

Call the QR Server API with the URL-encoded Solana Pay URL, using a 10-second timeout:

```
GET https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=<URL-encoded solana_pay_url>
```

URL-encode `solana_pay_url` before inserting it as the `data` parameter value. For example, `solana:` becomes `solana%3A`, `?` becomes `%3F`, `&` becomes `%26`, etc.

**If the call times out (> 10 seconds) or returns a non-2xx response:**
- Post to Subscription_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Service error: failed to generate QR code. Please try again in a moment.
  ```
- **STOP. Do not proceed to Step 8.**

**If the call succeeds (2xx response):**
- Store the full request URL (the `https://api.qrserver.com/v1/create-qr-code/?...` URL you called) as `qr_url`.
- Continue to Step 8.

---

## Step 8: Post Onboarding Message to Subscription_Channel

Construct the following message using Discord's proper mention format with the user ID:

```
<@<discord_user_id>> — ZeroClaw <tier> subscription (<expected_amount_usdc> USDC / <period_days> days)
Pay here: <solana_pay_url>
QR: <qr_url>
```

Use Discord's mention format `<@<discord_user_id>>` (not @username) to ensure proper user tagging regardless of their username format.

Post it to Subscription_Channel via the Proxy's `/discord/message` endpoint. URL-encode the full message content as the `content` parameter:

```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1532423195884261377&content=<URL-encoded message>
```

**On success (2xx response):** The onboarding flow is complete.

**On Proxy error (non-2xx response):**
- Write an error memory entry to Memory_Store under the key `"error:<current_UTC_timestamp_ISO8601>:<discord_user_id>"` with the following content:
  ```json
  {
    "event": "onboarding_discord_post_failed",
    "discord_user_id": "<discord_user_id>",
    "discord_username": "<discord_username>",
    "tier": "<tier>",
    "solana_pay_url": "<solana_pay_url>",
    "timestamp": "<current_UTC_timestamp_ISO8601>",
    "error": "Discord message post failed"
  }
  ```
- Do NOT silently discard the failure. The Subscriber_Record in `pending_payment` state remains valid — the subscriber can recover by re-issuing the subscribe command in Subscription_Channel.

---

## STOP Condition Summary

The skill halts immediately (without proceeding to the next step) whenever any of the following occur:

| Condition | STOP at Step |
|---|---|
| Active subscription found in Memory_Store | 1 |
| Pending payment found in Memory_Store | 1 |
| Unrecognized tier | 2 |
| Invalid `expected_amount_usdc` | 3 |
| `/keygen` call fails | 4 |
| Memory_Store write fails (subscriber record) | 5a |
| QR API call times out or returns non-2xx | 7 |

Steps 5b, 6, and 8 do not have hard STOP conditions — Step 5b logs index failures without halting, Step 6 constructs the URL in-memory only, and Step 8 logs failures rather than halting (the record is already persisted).

---

## Atomicity Guarantee

The Subscriber_Record is **always written to Memory_Store before any Discord API call** (Step 5 precedes Step 8). If the Discord post fails, the record remains in `pending_payment` state. When the subscriber re-issues the subscribe command in Subscription_Channel, Step 1 detects the `pending_payment` status and re-uses the existing URL without generating a new reference key.

This makes the onboarding flow idempotent: multiple subscribe commands from the same user while `status = "pending_payment"` return the same payment link without side effects.

---

## Error Memory Entry Schema

When the Discord post fails (Step 8), write to key `"error:<timestamp>:<discord_user_id>"`:

```json
{
  "event": "onboarding_discord_post_failed",
  "discord_user_id": "<discord_user_id>",
  "discord_username": "<discord_username>",
  "tier": "<tier>",
  "solana_pay_url": "<solana_pay_url>",
  "timestamp": "<ISO 8601 UTC, e.g. 2026-07-29T12:34:56.000Z>",
  "error": "Discord message post failed"
}
```

Use the ISO 8601 UTC timestamp with millisecond precision for the key suffix and the `timestamp` field value.
