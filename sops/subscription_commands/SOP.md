# Subscription Commands — Subscribe Command Detection and Processing

Triggered every 5 minutes by the cron scheduler. Polls the Signup_Channel for recent messages from registered users, detects standalone `subscribe` commands, and invokes the Onboarding SKILL for each qualifying message.

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
Proxy_Base_URL           = https://solana-rpc-proxy.dharadarsh0.workers.dev
Onboarding_SKILL         = shared/skills/default/onboarding/SKILL.md
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

2. **Process messages (newest-first)** — Iterate through messages, filter bots, detect subscribe commands, extract tier, and invoke Onboarding SKILL.
   - tools: http_request

   Iterate through each message in the array, from index 0 (newest) to the end (oldest). For each message, apply the following logic in order:

   **Skip Bot Messages:**
   If `message.author.bot = true`, skip this message and proceed to the next one. Do not invoke the Onboarding SKILL for bot messages.

   **Check for Standalone `subscribe` Command:**
   Test the message `content` field against the case-insensitive regex `\bsubscribe\b`.
   - If the regex does NOT match: skip this message and proceed to the next one.
   - If the regex matches: this is a qualifying subscribe command. Continue to verification check.

   **Verify User Registration:**
   Use `memory_recall` with `query="subscriber:{message.author.id}"`, `strategy="bm25"`, `limit=1`.
   - If no record exists or record.status != "registered": skip this message (user not yet verified wallet).
   - If record exists and record.status == "registered": proceed to tier extraction.

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
   - `discord_username`: Use `message.author.global_name` if it exists and is not null/empty, otherwise use `message.author.username`
   - `tier`: The tier extracted above
   - `wallet_address`: Use the wallet_address from the existing subscriber record

   The Onboarding SKILL handles all further state checks, reference key generation, record persistence, and Discord message posting. This SOP does not perform those actions directly.

   After the Onboarding SKILL returns (or errors), continue to the next message in the array. Do not stop the cycle if a single SKILL invocation fails — process all qualifying messages before terminating.

---

## Memory_Store Unavailability Handling

If Memory_Store is unavailable at any point during Steps 1 or 2 (detected when a memory recall or store operation returns an error):

1. Post `service temporarily unavailable` to Subscription_Channel via the Proxy (as shown in Step 1).
2. **Abort the cycle immediately.** Do not process any further messages and do not create any partial Subscriber_Records.

This ensures no half-written records are created when the backing store is down.

---

## Requirements Addressed

| Requirement | Description |
|---|---|
| 1.1 | Subscribe command detected within 5-minute polling window; onboarding flow begins |
| 1.5 | Messages from bot accounts (`author.bot = true`) are skipped |
| 1.6 | Memory_Store unavailability causes immediate abort with "service temporarily unavailable" reply |
| 2.1 | Only registered users (verified wallet) can subscribe |
| 7.4 | No tier specified in subscribe command defaults to `standard` |