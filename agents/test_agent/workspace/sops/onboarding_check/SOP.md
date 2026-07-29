# Onboarding Check — Subscribe Command Detection and Processing

Triggered every 5 minutes by the cron scheduler. Polls the Subscribe_Channel for recent messages, detects standalone `subscribe` commands, and invokes the Onboarding SKILL for each qualifying message.

**Tools allowed:** `http_request`, Memory_Store (memory recall/store). All external API calls route through the Proxy.

---

## Constants

```
Subscribe_Channel_ID = 1531347878906302487
Proxy_Base_URL       = https://solana-rpc-proxy.dharadarsh0.workers.dev
Onboarding_SKILL     = shared/skills/default/onboarding/SKILL.md
```

---

## Steps

### Step 1: Poll Subscribe_Channel for Recent Messages

Call the Proxy's Discord messages passthrough endpoint to retrieve the last 20 messages from Subscribe_Channel:

```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/channels/1531347878906302487/messages?limit=20
```

**Expected response (HTTP 200):** A JSON array of Discord message objects, ordered newest-first.

**If Memory_Store is unavailable at any point during this cycle:**
- Post the following reply to Subscribe_Channel via the Proxy:
  ```
  service temporarily unavailable
  ```
  Use:
  ```
  GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=service%20temporarily%20unavailable
  ```
- **ABORT the entire cycle immediately. Do NOT create any partial Subscriber_Records.**

**If the Proxy returns a non-2xx response or unparseable JSON:**
- Log the failure and terminate the cycle. Do not attempt to process messages.

**If the call succeeds:**
- Continue to Step 2 with the retrieved message array.

---

### Step 2: Process Messages (Newest-First)

Iterate through each message in the array, from index 0 (newest) to the end (oldest). For each message, apply the following logic in order:

#### 2a: Skip Bot Messages

If `message.author.bot = true`, **skip this message** and proceed to the next one. Do not invoke the Onboarding SKILL for bot messages.

#### 2b: Check for Standalone `subscribe` Command

Test the message `content` field against the case-insensitive regex `\bsubscribe\b`.

- **If the regex does NOT match:** skip this message and proceed to the next one.
- **If the regex matches:** this is a qualifying subscribe command. Continue to Step 2c.

#### 2c: Extract Subscription Tier

Parse the tier from the message `content` field:

1. Split the message content on whitespace.
2. Look at the word immediately following `subscribe` (the second word of the command).
3. If that word is one of `["standard", "premium"]` (case-insensitive), use it as the `tier` (normalized to lowercase).
4. If no second word is present, or the second word is not a recognized tier name, default to `"standard"`.

Examples:
| Message content | Extracted tier |
|---|---|
| `subscribe` | `standard` |
| `subscribe premium` | `premium` |
| `subscribe STANDARD` | `standard` |
| `subscribe gold` | `standard` (unrecognized → default) |
| `please subscribe me` | `standard` (second word is `me` → unrecognized → default) |
| `unsubscribe` | _(skipped — `\bsubscribe\b` does not match `unsubscribe`)_ |

#### 2d: Invoke Onboarding SKILL

Invoke the Onboarding SKILL (`shared/skills/default/onboarding/SKILL.md`) with the following inputs:

| Input | Value |
|---|---|
| `discord_user_id` | `message.author.id` |
| `discord_username` | `message.author.username` |
| `tier` | The tier extracted in Step 2c |

The Onboarding SKILL handles all further state checks, reference key generation, record persistence, and Discord message posting. This SOP does not perform those actions directly.

After the Onboarding SKILL returns (or errors), continue to the next message in the array. Do **not** stop the cycle if a single SKILL invocation fails — process all qualifying messages before terminating.

---

## Memory_Store Unavailability Handling

If Memory_Store is unavailable at any point during Steps 1 or 2 (detected when a memory recall or store operation returns an error):

1. Post `service temporarily unavailable` to Subscribe_Channel via the Proxy (as shown in Step 1).
2. **Abort the cycle immediately.** Do not process any further messages and do not create any partial Subscriber_Records.

This ensures Requirement 1.6: no half-written records are created when the backing store is down.

---

## Requirements Addressed

| Requirement | Description |
|---|---|
| 1.1 | Subscribe command detected within 5-minute polling window; onboarding flow begins |
| 1.5 | Messages from bot accounts (`author.bot = true`) are skipped |
| 1.6 | Memory_Store unavailability causes immediate abort with "service temporarily unavailable" reply |
| 7.4 | No tier specified in subscribe command defaults to `standard` |
