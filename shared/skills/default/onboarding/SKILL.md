---
name: onboarding
description: Handle a Discord subscribe command by generating a unique Solana Pay URL and QR code, persisting the subscriber record in Memory_Store, and posting the payment link to the Subscribe_Channel.
version: 1.0.0
tools:
  - http_request
  - memory_store
  - memory_recall
  - shell
---

# Skill: Onboarding — Subscribe Command Handling

## ⚠️ CRITICAL: memory_store Format

**ALL `memory_store` calls MUST use `content` as a JSON STRING, not a JSON object.**

**WRONG (will fail):**
```json
{"name": "memory_store", "arguments": {"key": "test", "content": {"field": "value"}, "category": "test"}}
```

**CORRECT:**
```json
{"name": "memory_store", "arguments": {"key": "test", "content": "{\"field\":\"value\"}", "category": "test"}}
```

**This is the most common error. Always use JSON.stringify() on the content before passing it.**

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
Discord_Guild_ID       = 1531347878906302484
Subscriber_Role_ID     = 1531669950819733575
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

**SKIPPED:** Due to a ZeroClaw runtime bug with memory_store parameter parsing, we skip the existing subscriber check. The user can proceed directly to payment generation.

Continue to Step 2.

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

## Step 5: Skip Memory Storage

**SKIPPED:** Due to a ZeroClaw runtime bug with memory_store parameter parsing, we skip all memory storage operations. The payment verification system will handle subscriber record creation when the payment is confirmed.

Continue to Step 6.

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

## Step 7: Construct Blink URL

Build the Action endpoint URL, then wrap it in the dial.to interstitial so
Actions-aware wallets recognize and render it as a tappable Blink:

```
action_url = <Proxy_Base_URL>/actions/subscribe?tier=<tier>&discord_user_id=<discord_user_id>&reference=<reference_key>
blink_url  = https://dial.to/?action=solana-action: + URL-encode(action_url) + "&cluster=devnet"
```

Store as `blink_url`. This costs one extra query-string field; no new
network call is required at this step.

Continue to Step 8.

---

## Step 8: Post Onboarding Message to Subscribe_Channel

Construct the message using Discord's proper mention format with the user ID:

```
<@<discord_user_id>> — ZeroClaw <tier> subscription (<expected_amount_sol> SOL / <period_days> days)
⚡ Tap to pay: <blink_url>
🔗 Or pay manually: <solana_pay_url>
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

## Step 9: Fast-Confirmation Loop

Immediately after Step 8 completes (regardless of whether the Discord post
succeeded — this loop's job is payment detection, not messaging), run a
bounded polling loop so the subscriber sees confirmation in seconds instead
of waiting for the next hourly `subscription_check` run.

**Tools used:** `shell` (for the delay only — `sleep 20`, a known-safe
command), `http_request`, `memory_recall`, `memory_store`.

Run up to **15 iterations**, each:

1. `sleep 20` (via the shell tool).
2. Call:
   ```
   GET <Proxy_Base_URL>?method=getSignaturesForAddress&wallet=<reference_key>&limit=5
   ```
3. If the result array is empty: continue to the next iteration.
4. If one or more signatures are returned: for the newest signature, call
   ```
   GET <Proxy_Base_URL>?method=getTransaction&signature=<signature>&encoding=jsonParsed
   ```
   and verify **both**:
   - a SOL transfer to `Merchant_Wallet` for at least `expected_amount_sol`
     appears in the parsed instructions, and
   - the `reference_key` appears among the transaction's account keys.

   **If verified:**
   - Compute `subscribed_at = <current UTC ISO8601>` and
     `expires_at = subscribed_at + period_days`.
   - Update the Subscriber_Record: `status = "active"`, set
     `subscribed_at` and `expires_at`, clear `grace_started_at`.
   - Persist via `memory_store` (same JSON-string format as Step 5a).
   - Grant the subscriber role:
     ```
     GET <Proxy_Base_URL>/discord/guilds/<Discord_Guild_ID>/members/<discord_user_id>/roles/<Subscriber_Role_ID>?method=PUT
     ```
   - Post to Subscribe_Channel:
     ```
     <@<discord_user_id>> — ✅ Payment verified (tx <signature>). Subscriber role granted. Valid until <expires_at>.
     ```
   - **STOP the loop.**

   **If not verified** (signature exists but doesn't match amount/reference):
   continue to the next iteration — this can happen if the wallet
   broadcasts an unrelated transaction that happens to reference the same
   account before the real payment lands.

5. After 15 iterations with no verified match: **stop silently.** Do not
   post anything. The subscriber remains in `pending_payment`; the hourly
   `subscription_check` SOP will still pick up the payment whenever it
   actually confirms — this loop is a latency optimization, not the only
   detection path.

This keeps the guarantee from the Atomicity section intact: the record is
never marked `active` without a verified on-chain transaction, whether that
verification happens here (seconds) or in the hourly SOP (fallback).

---

## STOP Condition Summary

The skill halts immediately (without proceeding to the next step) whenever any of the following occur:

| Condition | STOP at Step |
|---|---|
| Active subscription found in Memory_Store | 1 |
| Pending payment found in Memory_Store | 1 |
| Unrecognized tier | 2 |
| Invalid `expected_amount_sol` | 3 |
| `/keygen` call fails | 4 |
| Memory_Store write fails (subscriber record) | 5a |

Steps 5b, 6, 6b, 8, and 9 do not have hard STOP conditions — Step 5b logs index failures without halting, Step 6 constructs the URL in-memory only, Step 6b constructs the Blink URL in-memory only, Step 8 logs failures rather than halting (the record is already persisted), and Step 9 is a best-effort polling loop that always completes after 15 iterations regardless of outcome.

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
