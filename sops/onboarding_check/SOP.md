# Onboarding Check — Register Command Detection and Processing

Triggered every 5 minutes by the cron scheduler. Polls the Signup_Channel for recent messages, detects standalone `register` commands, and sends users the wallet verification link. Additionally polls Subscription_Channel for wallet verification confirmation messages and persists verified wallet addresses.

**Tools allowed:** `http_request`, Memory_Store (memory recall/store). All external API calls route through the Proxy.

---
## Trigger

```yaml
schedule: "*/5 * * * *"
```

---
## Dispatch

```yaml
mode: "headless"
```

---

## Constants

```
Signup_Channel_ID        = 1532423294354063410
Subscription_Channel_ID  = 1532423195884261377
Proxy_Base_URL           = https://solana-rpc-proxy.dharadarsh0.workers.dev
```

---

## Steps

1. **Poll Signup_Channel for recent messages** — Retrieve the last 20 messages from Signup_Channel via the Proxy.
   - tools: http_request

   Call the Proxy's Discord messages passthrough endpoint:
   ```
   GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/channels/1532423294354063410/messages?limit=20
   ```
   Expected response (HTTP 200): A JSON array of Discord message objects, ordered newest-first.

   **If Memory_Store is unavailable at any point during this cycle:**
   Post the following reply to Signup_Channel via the Proxy:
   ```
   GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1532423294354063410&content=service%20temporarily%20unavailable
   ```
   ABORT the entire cycle immediately. Do NOT create any partial Subscriber_Records.

   **If the Proxy returns a non-2xx response or unparseable JSON:**
   Log the failure and terminate the cycle. Do not attempt to process messages.

   **If the call succeeds:**
   Continue to processing messages with the retrieved message array.

2. **Process messages (newest-first)** — Iterate through messages, filter bots, detect register commands, and send wallet verification links.
   - tools: http_request

   Iterate through each message in the array, from index 0 (newest) to the end (oldest). For each message, apply the following logic in order:

   **Skip Bot Messages:**
   If `message.author.bot = true`, skip this message and proceed to the next one.

   **Check for Standalone `register` Command:**
   Test the message `content` field against the case-insensitive regex `\bregister\b`.
   - If the regex does NOT match: skip this message and proceed to the next one.
   - If the regex matches: this is a qualifying register command. Continue to sending the verification link.

   **Send Wallet Verification Link:**
   Build the registration URL with Discord user parameters:
   ```
   https://solana-rpc-proxy.dharadarsh0.workers.dev/register?discord_id={message.author.id}&discord_username={message.author.global_name or message.author.username}
   ```
   Send this URL to the user via DM using the Proxy:
   ```
   GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/dm?user_id={message.author.id}&content=<URL-encoded: "To verify your wallet ownership and unlock #subscription, visit: {registration_url}">
   ```
   On proxy failure: log the error and continue to the next message.

   After processing the message, continue to the next message in the array. Do not stop the cycle if a single DM fails — process all qualifying messages before terminating.

3. **Poll Subscription_Channel for wallet verification messages** — Retrieve the last 20 messages from Subscription_Channel via the Proxy.
   - tools: http_request

   Call the Proxy's Discord messages passthrough endpoint:
   ```
   GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/channels/1532423195884261377/messages?limit=20
   ```
   Expected response (HTTP 200): A JSON array of Discord message objects, ordered newest-first.

   **If the Proxy returns a non-2xx response or unparseable JSON:**
   Log the failure and terminate this step. Proceed to step 4.

   **If the call succeeds:**
   Continue to processing verification messages with the retrieved message array.

4. **Process wallet verification messages** — Iterate through messages, detect WALLET_VERIFIED markers, and persist wallet addresses to Memory_Store.
   - tools: http_request, memory_store

   Iterate through each message in the array, from index 0 (newest) to the end (oldest). For each message, apply the following logic in order:

   **Skip Bot Messages:**
   If `message.author.bot = true`, skip this message and proceed to the next one.

   **Check for WALLET_VERIFIED Marker:**
   Test the message `content` field against the regex `WALLET_VERIFIED discord_user_id=(\d+) wallet_address=([1-9A-HJ-NP-Za-km-z]+) verified_at=([0-9T:.Z-]+)`.
   - If the regex does NOT match: skip this message and proceed to the next one.
   - If the regex matches: extract `discord_user_id`, `wallet_address`, and `verified_at` from the capture groups.

   **Check for Existing Record:**
   Use `memory_recall` with `query="subscriber:{discord_user_id}"`, `strategy="bm25"`, `limit=1`.
   - If a record already exists: skip this message (wallet already verified for this user).
   - If no record exists: proceed to create a new Subscriber_Record.

   **Create Subscriber_Record:**
   Call `GET {proxy_base_url}/keygen` to obtain a fresh `reference_key`. Expected response: `{"reference_key": "<base58 string>"}`. On non-2xx or missing `reference_key` field: skip this message and continue.

   Construct a Subscriber_Record with the schema:
   ```
   {
     discord_user_id: {discord_user_id},
     discord_username: null,  // Will be filled when they subscribe
     wallet_address: {wallet_address},
     tier: null,  // Will be set when they subscribe
     expected_amount_usdc: null,  // Will be set when they subscribe
     period_days: null,  // Will be set when they subscribe
     subscribed_at: null,
     expires_at: null,
     grace_started_at: null,
     reference_key: {reference_key},
     status: "registered",
     last_known_status: null,
     renewal_dm_sent_for_expiry: null
   }
   ```
   Store the record in Memory_Store under key `"subscriber:{discord_user_id}"`.

   **Update subscriber_index:**
   Recall the current `subscriber_index` via `memory_recall` with query `"subscriber_index"`, `strategy="bm25"`, `limit=1`.
   - If not found or parsing fails: create new index as `[discord_user_id]`.
   - If found and parses: append `discord_user_id` to the array if not already present.
   Store the updated index: `store "subscriber_index" = JSON.stringify(updated_index_array)`.

   After processing the message, continue to the next message in the array.

---

## Memory_Store Unavailability Handling

If Memory_Store is unavailable at any point during Steps 2 or 4 (detected when a memory recall or store operation returns an error):

1. Post `service temporarily unavailable` to Signup_Channel via the Proxy (as shown in Step 1).
2. **Abort the cycle immediately.** Do not process any further messages and do not create any partial Subscriber_Records.

This ensures no half-written records are created when the backing store is down.

---

## Requirements Addressed

| Requirement | Description |
|---|---|
| 1.1 | Register command detected within 5-minute polling window; wallet verification flow begins |
| 1.5 | Messages from bot accounts (`author.bot = true`) are skipped |
| 1.6 | Memory_Store unavailability causes immediate abort with "service temporarily unavailable" reply |
| 2.1 | Wallet verification requires cryptographic signature proof |
| 2.2 | Verified wallet addresses are persisted to Memory_Store for subscription use |
