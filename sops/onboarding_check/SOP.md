# Onboarding Check — Registration, Subscribe Command Detection, and Subscription Deletion

Triggered every 5 minutes by the cron scheduler. Polls the Signup_Channel for WALLET_VERIFIED messages to handle wallet registration, polls the Subscribe_Channel for recent messages to detect standalone `subscribe` commands (invoking the Onboarding SKILL for each qualifying message), and detects `delete my subscription` commands to handle subscription cancellation with automatic role removal.

**Tools allowed:** `http_request`, Memory_Store (memory recall/store). All external API calls route through the Proxy.

---

## Tool Call Format (Critical — Follow Exactly)

When calling `memory_store` or `memory_recall`, you MUST use the correct parameter format:

**For memory_store:**
- `key`: string (required) - the memory key
- `content`: string (required) - the content to store (MUST be a JSON string with escaped quotes, not a JSON object)
- `category`: string (optional) - category for organization

**CRITICAL - content must be a JSON string:**
✅ CORRECT: `"content": "{\"discord_user_id\":\"123456\"}"`
❌ WRONG: `"content": {"discord_user_id":"123456"}` (this will fail)

**Example call:**
```json
{"name": "memory_store", "arguments": {"key": "subscriber:123456", "content": "{\"discord_user_id\":\"123456\",\"tier\":\"standard\"}", "category": "subscribers"}}
```

**For memory_recall:**
```json
{"name": "memory_recall", "arguments": {"query": "subscriber:123456", "strategy": "bm25", "limit": 1}}
```
- `query`: string (required) - the search query or key
- `strategy`: string (optional) - search strategy (e.g., "bm25")
- `limit`: number (optional) - maximum results to return

**INCORRECT (will fail):**
```json
{"name": "memory_store", "key": "subscriber:123456", "content": "{\"discord_user_id\": \"123456\", ...}"}
```

**For http_request:**
```json
{"name": "http_request", "arguments": {"url": "https://example.com", "method": "GET"}}
```
- `url`: string (required) - the request URL
- `method`: string (optional) - HTTP method (default: "GET")
- `headers`: object (optional) - request headers
- `body`: string (optional) - request body

**INCORRECT (will fail):**
```json
{"name": "http_request", "url": "https://example.com", "method": "GET"}
```

---
## Trigger

```yaml
schedule: "*/5 * * * *"
```

---
## Dispatch

```yaml
execution_mode: "auto"
```

---

## Constants

```
Signup_Channel_ID    = 1532423294354063410
Subscribe_Channel_ID = 1531347878906302487
Proxy_Base_URL       = https://solana-rpc-proxy.dharadarsh0.workers.dev
Discord_Guild_ID     = 1531347878906302484
Subscriber_Role_ID  = 1531669950819733575
Onboarding_SKILL     = shared/skills/default/onboarding/SKILL.md
```

---

## Steps

1. **Poll Signup_Channel for WALLET_VERIFIED messages** — Retrieve the last 20 messages from Signup_Channel via the Proxy to detect wallet verification completions.
   - tools: http_request, memory_store

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
   Process messages to detect WALLET_VERIFIED markers:
   - Iterate through each message, from index 0 (newest) to the end (oldest).
   - Skip bot messages (`message.author.bot = true`).
   - Check if message content exactly matches `WALLET_VERIFIED:<wallet_address>` format (case-sensitive).
   - If a WALLET_VERIFIED message is found:
     - Extract the wallet_address from the message content (after the colon).
     - Extract discord_user_id from `message.author.id`.
     - Extract discord_username from `message.author.username`.
     - Use `memory_recall` with `query="subscriber:{discord_user_id}"`, `strategy="bm25"`, `limit=1` to check if a record already exists.
     - If no record exists, create a new Subscriber_Record with:
       ```json
       {
         "discord_user_id": "<discord_user_id>",
         "discord_username": "<discord_username>",
         "wallet_address": "<wallet_address>",
         "tier": "standard",
         "expected_amount_sol": 0.001,
         "period_days": 30,
         "subscribed_at": null,
         "expires_at": null,
         "grace_started_at": null,
         "reference_key": null,
         "status": "registered",
         "last_known_status": null,
         "renewal_dm_sent_for_expiry": null,
         "pay_url": null
       }
       ```
     - Store the record under key `"subscriber:<discord_user_id>"` using `memory_store`.
     - Update the subscriber_index by recalling it, appending the discord_user_id if not present, and storing it back.
     - If a record already exists and status is not "registered", update it to `"registered"` and persist.

2. **Poll Subscribe_Channel for recent messages** — Retrieve the last 20 messages from Subscribe_Channel via the Proxy.
   - tools: http_request

   Call the Proxy's Discord messages passthrough endpoint:
   ```
   GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/channels/1531347878906302487/messages?limit=20
   ```
   Expected response (HTTP 200): A JSON array of Discord message objects, ordered newest-first.

   **If Memory_Store is unavailable at any point during this cycle:**
   Post the following reply to Subscribe_Channel via the Proxy:
   ```
   GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=service%20temporarily%20unavailable
   ```
   ABORT the entire cycle immediately. Do NOT create any partial Subscriber_Records.

   **If the Proxy returns a non-2xx response or unparseable JSON:**
   Log the failure and terminate the cycle. Do not attempt to process messages.

   **If the call succeeds:**
   Continue to processing messages with the retrieved message array.

3. **Process messages (newest-first)** — Iterate through messages, filter bots, detect subscribe commands and deletion commands, and invoke appropriate SKILLs or perform role removal.
   - tools: http_request, memory_recall

   Iterate through each message in the array, from index 0 (newest) to the end (oldest). For each message, apply the following logic in order:

   **Skip Bot Messages:**
   If `message.author.bot = true`, skip this message and proceed to the next one. Do not invoke the Onboarding SKILL for bot messages.

   **Check for Standalone `subscribe` Command:**
   Test the message `content` field against the case-insensitive regex `\bsubscribe\b`.
   - If the regex does NOT match: skip this message and proceed to the next one.
   - If the regex matches: this is a qualifying subscribe command. Continue to verification check.

   **Check for Standalone `delete my subscription` Command:**
   Test the message `content` field against the case-insensitive regex `\bdelete my subscription\b`.
   - If the regex matches: this is a delete subscription command. Handle deletion by:
     * Use `memory_recall` with `query="subscriber:{message.author.id}"`, `strategy="bm25"`, `limit=1` to get the subscriber record.
     * If record exists and status is "active" or "pending_payment":
       - Update the record: set status to "lapsed", keep all other fields unchanged.
       - Persist the updated record using `memory_store` with key="subscriber:{discord_user_id}", content=updated_record (as JSON string with escaped quotes), category="subscribers". Follow the same format as in Step 1.
       - **Immediately remove the subscriber role using http_request:**
         ```
         {"name": "http_request", "arguments": {"url": "https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}/roles/1531669950819733575?method=DELETE", "method": "GET"}}
         ```
         The proxy translates the `?method=DELETE` query parameter to a DELETE request to the Discord API.
       - Post confirmation message to Subscribe_Channel: `<@{discord_user_id}> — Your subscription has been cancelled and your subscriber role has been removed.`
     * If record does not exist or status is already "lapsed"/"expired": 
       - Post message: `<@{discord_user_id}> — You do not have an active subscription to cancel.`
     * Skip to next message after handling deletion.

   **Verify User Registration (Optional):**
   Use `memory_recall` with `query="subscriber:{message.author.id}"`, `strategy="bm25"`, `limit=1`.
   - If no record exists: proceed to tier extraction (allow new subscriptions without prior registration).
   - If record exists and record.status == "registered": proceed to tier extraction.
   - If record exists and record.status == "pending_payment":
     * Extract the tier, reference_key, and expected_amount_sol from the record.
     * Construct the pay page URL: `https://solana-rpc-proxy.dharadarsh0.workers.dev/pay?tier={tier}&discord_user_id={message.author.id}&reference={reference_key}`
     * Construct the Solana Pay URL: `solana:pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak?amount={expected_amount_sol}&reference={reference_key}&label=ZeroClaw+Subscription&memo={message.author.id}&cluster=devnet`
     * Post to Subscribe_Channel: `<@{message.author.id}> — You already have a pending payment. Pay here: {pay_url} 🔗 Or pay manually with Solana Pay: {solana_pay_url}`
     * Skip this message (do not invoke the skill).
   - If record exists and record.status == "active": proceed to tier extraction (allow renewals).

   **Extract Subscription Tier:**
   Parse the tier from the message `content` field:
   - Split the message content on whitespace.
   - Look at the word immediately following `subscribe` (the second word of the command).
   - If that word is one of `["standard", "premium"]` (case-insensitive), use it as the `tier` (normalized to lowercase).
   - If no second word is present, or the second word is not a recognized tier name, default to `"standard"`.

   Examples:
   - `subscribe` → `standard`
   - `subscribe premium` → `premium`
   - `subscribe STANDARD` → `standard`
   - `subscribe gold` → `standard` (unrecognized → default)
   - `please subscribe me` → `standard` (second word is `me` → unrecognized → default)
   - `unsubscribe` → skipped (regex does not match)

   **Invoke Onboarding SKILL:**
   Invoke the Onboarding SKILL (`shared/skills/default/onboarding/SKILL.md`) with the following inputs:
   - `discord_user_id`: `message.author.id`
   - `discord_username`: `message.author.username`
   - `tier`: The tier extracted above
   - `wallet_address`: Use the wallet_address from the existing subscriber record if available, otherwise `null`

   The Onboarding SKILL handles all further state checks, reference key generation, record persistence, and Discord message posting. This SOP does not perform those actions directly.

   After the Onboarding SKILL returns (or errors), continue to the next message in the array. Do not stop the cycle if a single SKILL invocation fails — process all qualifying messages before terminating.

---

## Memory_Store Unavailability Handling

If Memory_Store is unavailable at any point during Steps 1, 2, or 3 (detected when a memory recall or store operation returns an error):

1. Log the specific error details including timestamp, step number, and error message to Memory_Store under key `"error:memory_unavailable:<current_UTC_timestamp_ISO8601>"` with content:
   ```json
   {
     "event": "memory_store_unavailable",
     "step": "<step_number>",
     "sop": "onboarding_check",
     "timestamp": "<ISO 8601 UTC>",
     "error_details": "<specific error message if available>"
   }
   ```

2. Post `service temporarily unavailable` to the relevant channel (Signup_Channel for Step 1, Subscribe_Channel for Steps 2-3) via the Proxy.

3. **Abort the cycle immediately.** Do not process any further messages and do not create any partial Subscriber_Records.

This ensures Requirement 1.6: no half-written records are created when the backing store is down, and provides diagnostic information for troubleshooting.

---

## Requirements Addressed

| Requirement | Description |
|---|---|
| 1.1 | Subscribe command detected within 5-minute polling window; onboarding flow begins |
| 1.2 | WALLET_VERIFIED messages are detected and processed to register users with verified wallets (optional feature) |
| 1.5 | Messages from bot accounts (`author.bot = true`) are skipped |
| 1.6 | Memory_Store unavailability causes immediate abort with "service temporarily unavailable" reply |
| 2.1 | Users can subscribe without prior wallet registration (registration is optional) |
| 7.4 | No tier specified in subscribe command defaults to `standard` |
