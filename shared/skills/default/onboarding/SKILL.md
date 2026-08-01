---
name: onboarding
description: Handle a Discord subscribe command by generating a unique Solana Pay URL and self-hosted payment page, persisting the subscriber record in proxy storage, and posting the payment link to the Subscribe_Channel.
version: 1.0.0
tools:
  - http_request
  - shell
---

# Skill: Onboarding — Subscribe Command Handling

This skill is invoked by the `onboarding_check` SOP whenever it detects a `subscribe` command in the Subscribe_Channel from a registered user. It manages the full onboarding flow: state lookup, reference key generation, Subscriber_Record persistence (via proxy storage), Solana Pay URL construction, QR code generation, and Discord message posting.

**The skill uses only the `http_request` tool. All external API calls route through the Proxy because the `http_request` tool has a POST-body bug — all writes must be issued as GET requests with URL-encoded parameters. Storage operations use the proxy's KV storage endpoints to bypass ZeroClaw's memory_store tool.**

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

---

## Step 1: Check Existing Subscriber Record

Call the proxy storage endpoint to check for existing subscriber record:
```
GET <Proxy_Base_URL>/storage/subscriber/<discord_user_id>
```

**If the request fails (non-2xx response):**
- This indicates the storage service is unavailable. Post an error message to Subscribe_Channel and STOP.
- Post: `<@<discord_user_id>> — Memory service unavailable. Please try again later or contact support.` 
- **STOP immediately.**

**If the response is `null` (no record found):**
- Continue to Step 2.

**If a record is found (response is JSON):**
- Parse the response as the subscriber record.
- Check the `status` field:
  - If `status = "pending_payment"`: The subscriber already has a pending invoice. Re-use the existing payment link. If the record contains a `pay_url` field, use it directly. Otherwise, construct the pay page URL from the stored reference key and tier. Also construct the Solana Pay URL from the stored reference key. Post to Subscribe_Channel via the Proxy using Discord's mention format:
    ```
    <@<discord_user_id>> — You already have a pending payment. Pay here: <pay_url from record, or construct as <Proxy_Base_URL>/pay?tier=<tier from record>&discord_user_id=<discord_user_id>&reference=<reference_key from record>>
    🔗 Or pay manually with Solana Pay: solana:<Merchant_Wallet>?amount=<expected_amount_sol from record>&reference=<reference_key from record>&label=ZeroClaw+Subscription&memo=<discord_user_id>&cluster=devnet
    ```
    **STOP. Do not continue to Step 2.**
  - If `status = "active"`: Allow the user to re-subscribe for renewal. Proceed to Step 2 to generate a new payment link for renewal (will update existing record). Additionally, ensure the user has the subscriber role by calling the grant-subscriber-role skill. If the role grant fails, log the error but continue with renewal flow.
  - If `status = "registered"`: User has completed wallet registration but not yet paid. Proceed to Step 2 to generate a payment link (will update existing record).
  - For any other status: Continue to Step 2.

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

Build the subscriber record as a JSON object:

```json
{
  "discord_user_id": "<discord_user_id>",
  "discord_username": "<discord_username>",
  "wallet_address": <wallet_address_or_null>,
  "tier": "<tier>",
  "expected_amount_sol": <expected_amount_sol>,
  "period_days": <period_days>,
  "subscribed_at": null,
  "expires_at": null,
  "grace_started_at": null,
  "reference_key": "<reference_key>",
  "status": "pending_payment",
  "last_known_status": null,
  "renewal_dm_sent_for_expiry": null,
  "pay_url": "<Proxy_Base_URL>/pay?tier=<tier>&discord_user_id=<discord_user_id>&reference=<reference_key>"
}
```

Placeholder rules:
- `<discord_user_id>`, `<discord_username>`, `<tier>`, `<reference_key>` — plain text, with quotes
- `<wallet_address_or_null>` — literal `null` (no quotes) if not available; otherwise the wallet address string with quotes
- `<expected_amount_sol>` and `<period_days>` — plain numbers, unquoted (e.g. `0.001`, `30`)

Call the proxy storage endpoint to store the record:
```
PUT <Proxy_Base_URL>/storage/subscriber/<discord_user_id>
Content-Type: application/json

<JSON object from above>
```

**If the storage write fails (non-2xx response):**
- Log the specific error for debugging (if possible, include the error message in a Discord message to an admin channel).
- Attempt fallback: Post the payment link directly to the user and inform them that the record will be created when the service recovers:
  ```
  <@<discord_user_id>> — Service temporarily unavailable. Your payment link is: <pay_url>. Please save this link and try the subscribe command again later if payment verification fails.
  ```
- Discard the `reference_key` obtained in Step 4 — it must not be reused.
- **STOP. Do not proceed to Discord message posting.**

**If the write succeeds:** continue to Step 5b.

---

### Step 5b: Update the Subscriber Index

The `subscriber_index` entry is the authoritative roster used by the subscription_check SOP to enumerate all subscribers without relying on relevance-ranked search. It must be kept in sync whenever a new subscriber is added.

1. Get the current subscriber index from the proxy:
   ```
   GET <Proxy_Base_URL>/storage/subscriber_index
   ```

2. Parse the response as a JSON array of Discord user ID strings. If the response is `null`, `[]`, or malformed, start with an empty array `[]`.

3. If `"<discord_user_id>"` is **not already present** in the array, append it.

4. Update the subscriber index via the proxy:
   ```
   PUT <Proxy_Base_URL>/storage/subscriber_index
   Content-Type: application/json

   <updated JSON array>
   ```

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

## Step 7: Construct Pay Page URL

Build the self-hosted payment page URL. This page is served directly by the Proxy, so there is no third-party dependency in this step at all:

```
pay_url = <Proxy_Base_URL>/pay?tier=<tier>&discord_user_id=<discord_user_id>&reference=<reference_key>
```

Store as `pay_url`. No network call is required at this step — it's a plain URL construction, same as Step 6.

Continue to Step 8.

---

## Step 8: Post Onboarding Message to Subscribe_Channel

Construct the message using Discord's proper mention format with the user ID:

```
<@<discord_user_id>> — ZeroClaw <tier> subscription (<expected_amount_sol> SOL / <period_days> days)
⚡ Tap to pay: <pay_url>
🔗 Or pay manually with Solana Pay: <solana_pay_url>
```

Use Discord's mention format `<@<discord_user_id>>` (not @username) to ensure proper user tagging regardless of their username format.

Post it to Subscribe_Channel via the Proxy's `/discord/message` endpoint. URL-encode the full message content as the `content` parameter:

```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=<URL-encoded message>
```

**On success (2xx response):** The onboarding flow is complete.

**On Proxy error (non-2xx response):**
- Write an error entry to proxy storage under the key `"error:<current_UTC_timestamp_ISO8601>:<discord_user_id>"` with the following content:
  ```json
  {
    "event": "onboarding_discord_post_failed",
    "discord_user_id": "<discord_user_id>",
    "discord_username": "<discord_username>",
    "tier": "<tier>",
    "pay_url": "<pay_url>",
    "timestamp": "<current_UTC_timestamp_ISO8601>",
    "error": "Discord message post failed"
  }
  ```
  Call:
  ```
  PUT <Proxy_Base_URL>/storage/subscriber/error:<current_UTC_timestamp_ISO8601>:<discord_user_id>
  Content-Type: application/json

  <error JSON object from above>
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
   - Persist via proxy storage:
     ```
     PUT <Proxy_Base_URL>/storage/subscriber/<discord_user_id>
     Content-Type: application/json

     <updated JSON object with status="active">
     ```
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
| Active subscription found in proxy storage | 1 |
| Pending payment found in proxy storage | 1 |
| Unrecognized tier | 2 |
| Invalid `expected_amount_sol` | 3 |
| `/keygen` call fails | 4 |
| Proxy storage write fails (subscriber record) | 5a |

Steps 5b, 6, 7, 8, and 9 do not have hard STOP conditions — Step 5b logs index failures without halting, Step 6 constructs the URL in-memory only, Step 7 constructs the Blink URL in-memory only, Step 8 logs failures rather than halting (the record is already persisted), and Step 9 is a best-effort polling loop that always completes after 15 iterations regardless of outcome.

---

## Atomicity Guarantee

The Subscriber_Record is **always written to proxy storage before any Discord API call** (Step 5 precedes Step 8). If the Discord post fails, the record remains in `pending_payment` state. When the subscriber re-issues the subscribe command in Subscribe_Channel, Step 1 detects the `pending_payment` status and re-uses the existing URL without generating a new reference key.

This makes the onboarding flow idempotent: multiple subscribe commands from the same user while `status = "pending_payment"` return the same payment link without side effects.

---

## Error Entry Schema

When the Discord post fails (Step 8), write to proxy storage under key `"error:<timestamp>:<discord_user_id>"`:

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
