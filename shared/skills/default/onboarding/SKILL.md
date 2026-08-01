---
name: onboarding
description: Handle a Discord subscribe command by generating a unique Solana Pay URL and QR code, persisting the subscriber record in Memory_Store, and posting the payment link to the Subscribe_Channel.
version: 1.0.0
tools:
  - http_request
  - memory_store
  - memory_recall
---

# Skill: Onboarding — Subscribe Command Handling

This skill is invoked by the `onboarding_check` SOP whenever it detects a `subscribe` command in the Subscribe_Channel from a registered user. It manages the full onboarding flow: state lookup, reference key generation, Subscriber_Record persistence, Solana Pay URL construction, QR code generation, and Discord message posting.

**The skill uses only the `http_request` and Memory_Store (memory recall/store) tools. All external API calls route through the Proxy because the `http_request` tool has a POST-body bug — all writes must be issued as GET requests with URL-encoded parameters.**

---

## Inputs

The SOP provides these values to the skill before invoking it:

| Input | Type | Description |
|---|---|---|
| `discord_user_id` | string | Discord snowflake ID of the user who sent the subscribe command |
| `discord_username` | string | Discord username of the user (e.g. `adrs0890`) |
| `tier` | string | Subscription tier parsed from the command message. One of `"standard"` or `"premium"`. Defaults to `"standard"` if absent. |
| `wallet_address` | string | Solana wallet address (base58) already verified during registration. Optional - if not provided, the record will be created without a wallet address. |

---

## Constants

Embed these values exactly as shown — do not modify them.

```
Merchant_Wallet        = pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak
Signup_Channel_ID      = 1532423294354063410
Subscribe_Channel_ID   = 1531347878906302487
Proxy_Base_URL         = https://solana-rpc-proxy.dharadarsh0.workers.dev
```

---

## Tier Configuration

| Tier | `expected_amount_sol` | `period_days` |
|---|---|---|
| `standard` | `0.001` | `30` |
| `premium` | `0.0025` | `30` |

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

**For memory_store:**
```json
{"name": "memory_store", "arguments": {"key": "subscriber:123456", "content": "{\"discord_user_id\": \"123456\", ...}", "category": "subscribers"}}
```

**For memory_recall:**
```json
{"name": "memory_recall", "arguments": {"query": "subscriber:123456", "strategy": "bm25", "limit": 1}}
```

---

## Step 1: Check Existing Subscriber Record

Recall the memory key `"subscriber:<discord_user_id>"` from Memory_Store using:
```json
{"name": "memory_recall", "arguments": {"query": "subscriber:<discord_user_id>", "strategy": "bm25", "limit": 1}}
```

**If the memory_recall tool itself fails (returns an error):**
- This indicates Memory_Store is unavailable. Post an error message to Subscribe_Channel and STOP.
- Post: `<@<discord_user_id>> — Memory service unavailable. Please try again later or contact support.`
- **STOP immediately.**

**If the record is found and `status = "pending_payment"`:**
- The subscriber already has a pending invoice. Re-use the existing `solana_pay_url` and QR URL stored in the record. Post to Subscribe_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — You already have a pending payment. Pay here: <solana_pay_url from record>
  QR: https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=<URL-encoded solana_pay_url from record>
  ```
- **STOP. Do not continue to Step 2.**

**If the record is found and `status = "active"`:**
- Allow the user to re-subscribe for renewal. Proceed to Step 2 to generate a new payment link for renewal (will update existing record).
- Additionally, ensure the user has the subscriber role by calling the grant-subscriber-role skill. If the role grant fails, log the error but continue with renewal flow.

**If the record is found and `status = "registered"`:**
- User has completed wallet registration but not yet paid. Proceed to Step 2 to generate a payment link (will update existing record).

**If the record is not found, or has any status other than `"pending_payment"`:**
- Continue to Step 2.

---

## Step 2: Validate Tier

Check that the `tier` input is one of `["standard", "premium"]` (exact match, case-sensitive).

**If the tier is unrecognized:**
- Post to Subscribe_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Unrecognized subscription tier "<tier>". Available tiers: standard (0.001 SOL / 30 days), premium (0.0025 SOL / 30 days). Example: "subscribe standard" or "subscribe premium".
  ```
- **STOP. Do not continue.**

**If the tier is valid:**
- Set `expected_amount_sol` and `period_days` from the tier config table above:
  - `standard` → `expected_amount_sol = 0.001`, `period_days = 30`
  - `premium` → `expected_amount_sol = 0.0025`, `period_days = 30`
- Continue to Step 3.

---

## Step 3: Validate Amount

Verify that `expected_amount_sol` satisfies both conditions:
1. `expected_amount_sol > 0`
2. The number of decimal digits in `expected_amount_sol` is ≤ 9

**If either condition fails:**
- Post to Subscribe_Channel via the Proxy using Discord's mention format:
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
- Post to Subscribe_Channel via the Proxy using Discord's mention format:
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

**CRITICAL WARNING:** The `content` parameter MUST be a JSON string. Do NOT pass a JSON object. The entire JSON object must be converted to a string with escaped quotes.

**EXACT FORMAT - Copy this pattern:**
```
Call memory_store with:
- key: "subscriber:1532152364381765702"
- content: "{\"discord_user_id\":\"1532152364381765702\",\"discord_username\":\"alex\",\"wallet_address\":null,\"tier\":\"standard\",\"expected_amount_sol\":0.001,\"period_days\":30,\"subscribed_at\":null,\"expires_at\":null,\"grace_started_at\":null,\"reference_key\":\"ABC123\",\"status\":\"pending_payment\",\"last_known_status\":null,\"renewal_dm_sent_for_expiry\":null}"
- category: "subscribers"
```

Notice how:
1. The entire JSON is wrapped in outer quotes
2. All inner quotes are escaped with backslashes
3. Numbers (0.001, 30) are not quoted
4. null values are not quoted

**Create the string by:**
1. Build the JSON object with your values
2. Convert it to a string using JSON.stringify()
3. Pass that string as the content parameter

**Data to include:**
- discord_user_id: string (the Discord user ID)
- discord_username: string (the Discord username)  
- wallet_address: null or string (if available)
- tier: string ("standard" or "premium")
- expected_amount_sol: number (0.001 for standard, 0.005 for premium)
- period_days: number (30 for standard, 90 for premium)
- subscribed_at: null
- expires_at: null
- grace_started_at: null
- reference_key: string (from Step 4)
- status: "pending_payment"
- last_known_status: null
- renewal_dm_sent_for_expiry: null

**Write the record using memory_store:**
Call the memory_store tool with the following format:
```json
{"name": "memory_store", "arguments": {"key": "subscriber:<discord_user_id>", "content": "<JSON string of the record>", "category": "subscribers"}}
```

**If the Memory_Store write fails (tool returns an error or does not confirm the write):**
- Log the specific error for debugging (if possible, include the error message in a Discord message to an admin channel)
- Attempt fallback: Post the payment link directly to the user and inform them that the record will be created when the service recovers:
  ```
  <@<discord_user_id>> — Service temporarily unavailable. Your payment link is: <solana_pay_url>. Please save this link and try the subscribe command again later if payment verification fails.
  QR: <qr_url>
  ```
- Discard the `reference_key` obtained in Step 4 — it must not be reused.
- **STOP. Do not proceed to Discord message posting.**

**If the write succeeds:** continue to Step 5b.

---

### Step 5b: Update the Subscriber Index

The `subscriber_index` entry is the authoritative roster used by the subscription_check SOP to enumerate all subscribers without relying on relevance-ranked search. It must be kept in sync whenever a new subscriber is added.

1. Recall the memory key `"subscriber_index"` from Memory_Store using:
   ```json
   {"name": "memory_recall", "arguments": {"query": "subscriber_index", "strategy": "bm25", "limit": 1}}
   ```

2. Parse the recalled content as a JSON array of Discord user ID strings. If the key does not exist or the content is absent/malformed, start with an empty array `[]`.

3. If `"<discord_user_id>"` is **not already present** in the array, append it.

4. Write the updated array back to Memory_Store under key `"subscriber_index"` using:
   ```json
   {"name": "memory_store", "arguments": {"key": "subscriber_index", "content": "[\"1532152364381765702\", \"123456789012345678\"]", "category": "subscribers"}}
   ```
   **CRITICAL:** The `content` parameter MUST be a JSON string (use `JSON.stringify(updatedArray)`), not a JSON object.

**If the index write fails:**
- Log the failure (write a memory entry under key `"error:index:<current_UTC_timestamp_ISO8601>:<discord_user_id>"` with `{"event": "subscriber_index_update_failed", "discord_user_id": "<discord_user_id>", "timestamp": "<ISO 8601 UTC>"}`).
- The subscriber record written in Step 5a is still valid — **do not roll it back**. The index is a secondary structure; its inconsistency should be flagged for operator review, not used as a reason to abort onboarding.
- Continue to Step 6.

**If the index write succeeds:** continue to Step 6.

---

## Step 6: Construct Solana Pay URL

Build the Solana Pay URL using this exact format — no deviations:

```
solana:<Merchant_Wallet>?amount=<expected_amount_sol>&reference=<reference_key>&label=ZeroClaw+Subscription&memo=<discord_user_id>&cluster=devnet
```

**Example (standard tier, user ID `1531681016249319576`, reference key `4vJ9JU1bfGg1xPcDxY2xFRG7JbN3TxWqZvKmPsHcL8E`):**
```
solana:pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak?amount=0.001&reference=4vJ9JU1bfGg1xPcDxY2xFRG7JbN3TxWqZvKmPsHcL8E&label=ZeroClaw+Subscription&memo=1531681016249319576&cluster=devnet
```

**Example (premium tier):**
```
solana:pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak?amount=0.0025&reference=<reference_key>&label=ZeroClaw+Subscription&memo=<discord_user_id>&cluster=devnet
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
- Post to Subscribe_Channel via the Proxy using Discord's mention format:
  ```
  <@<discord_user_id>> — Service error: failed to generate QR code. Please try again in a moment.
  ```
- **STOP. Do not proceed to Step 8.**

**If the call succeeds (2xx response):**
- Store the full request URL (the `https://api.qrserver.com/v1/create-qr-code/?...` URL you called) as `qr_url`.
- Continue to Step 8.

---

## Step 8: Post Onboarding Message to Subscribe_Channel

Construct the following message using Discord's proper mention format with the user ID:

```
<@<discord_user_id>> — ZeroClaw <tier> subscription (<expected_amount_sol> SOL / <period_days> days)
Pay here: <solana_pay_url>
QR: <qr_url>
```

Use Discord's mention format `<@<discord_user_id>>` (not @username) to ensure proper user tagging regardless of their username format.

Post it to Subscribe_Channel via the Proxy's `/discord/message` endpoint. URL-encode the full message content as the `content` parameter:

```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=<URL-encoded message>
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
- Do NOT silently discard the failure. The Subscriber_Record in `pending_payment` state remains valid — the subscriber can recover by re-issuing the subscribe command in Subscribe_Channel.

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

The Subscriber_Record is **always written to Memory_Store before any Discord API call** (Step 5 precedes Step 8). If the Discord post fails, the record remains in `pending_payment` state. When the subscriber re-issues the subscribe command in Subscribe_Channel, Step 1 detects the `pending_payment` status and re-uses the existing URL without generating a new reference key.

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
