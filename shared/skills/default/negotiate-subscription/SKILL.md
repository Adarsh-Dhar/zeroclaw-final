---
name: negotiate-subscription
description: Conversationally help a user pick a subscription tier via DM, generate their Solana Pay payment link, and grant the Subscriber role once payment is confirmed on-chain.
version: 1.0.0
tools:
  - http_request
  - memory_store
  - memory_recall
---

# Skill: Negotiate Subscription (Live DM)

## When this applies

Any direct message from a user who does not have an active subscription.
**CRITICAL: Before doing anything else, check Memory_Store:**

```json
{"name": "memory_recall", "arguments": {"query": "subscriber:<discord_user_id>", "strategy": "bm25", "limit": 1}}
```

**STOP IMMEDIATELY if a record is found with `status: "active"`**:
- Do NOT generate a payment link
- Do NOT check for on-chain payments
- Do NOT grant any roles
- Do NOT update any memory records
- Simply respond conversationally that they already have an active subscription

This check is mandatory - never re-run onboarding on someone who is already subscribed.

---

## Constants

Keep these in sync with `check-payment/SKILL.md` and
`sops/subscription_check/SOP.md` if either changes.

- **Proxy URL:** `https://solana-rpc-proxy.dharadarsh0.workers.dev`
- **Discord Guild ID:** `1531347878906302484`
- **Subscriber Role ID:** `1531669950819733575`
- **Merchant Wallet:** `pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak`
- **Tiers:**
  - `standard` — 0.001 SOL / 30 min (testing; 30 days in production)
  - `premium` — 0.0025 SOL / 30 min (testing; 30 days in production)

---

## Tool Call Format (critical — follow exactly)

All `http_request` parameters must be nested inside an `"arguments"`
object. This matches the format used in `grant-subscriber-role/SKILL.md`
and `check-payment/SKILL.md`.

```json
{"name": "http_request", "arguments": {"url": "...", "method": "GET"}}
```

All `memory_store` and `memory_recall` parameters must also be nested
inside `"arguments"`:

```json
{"name": "memory_store", "arguments": {"key": "subscriber:123456", "content": "{\"discord_user_id\":\"123456\"}", "category": "subscribers"}}
{"name": "memory_recall", "arguments": {"query": "subscriber:123456", "strategy": "bm25", "limit": 1}}
```

The `content` field in `memory_store` must always be a **JSON string**
(i.e. the inner object serialised and then wrapped in outer quotes with
escaped inner quotes). Never pass a raw JSON object as `content`.

---

## Conversation Flow

### Phase 1 — Engage and discover intent

Be a genuinely good, low-pressure salesperson — warm, curious about
what the user is looking for, quick to highlight real value once you
know what that is, never pushy or repetitive.

**Ask before pitching.** Start by finding out what brought them here or
what they're hoping to get out of the community. Lead with benefits
specific to what they say they want, not a generic feature list.

**Address actual hesitation.** If they pause or push back, respond to
the real concern — price, trust, unclear value — rather than repeating
the pitch louder. A second copy of the same pitch is never the answer.

**Know when to back off.** If someone says "not now" or "not
interested", thank them, leave the door genuinely open ("happy to
answer questions any time"), and end the conversation. Do not send
another pitch in the same session, and do not use a follow-up welcome
DM to re-approach them after they've already declined.

**Explain the tiers once they show interest.** Only then introduce
both tiers and their prices. Answer comparison questions, help them
decide — but never quote a price other than the two listed in
Constants above, and never fabricate scarcity or urgency (no "only 2
spots left", no fake countdown, no invented deadlines). Manufactured
pressure tactics are explicitly off-limits here — they undermine trust
and will fail any manipulation review.

---

### Phase 2 — Tier confirmed: generate reference key and payment link

Once the user confirms a tier choice (`standard` or `premium`), call:

```
GET {proxy_url}/keygen
```

Expected response: `{"reference_key": "<base58 string>"}`.

- On non-2xx or missing `reference_key`: apologise to the user, tell
  them there was a temporary error generating their payment link, and
  ask them to try again in a moment. Do not proceed.

Capture `reference_key`. Set `tier_amount_sol` from the constants above.

Build the Solana Pay URL:
```
solana:{merchant_wallet}?amount={tier_amount_sol}&reference={reference_key}&label=ZeroClaw+Subscription&memo={discord_user_id}&cluster=devnet
```

Send the payment link to the user in the DM. Format it as a Markdown link for visibility:
```
[Payment Link](solana:{merchant_wallet}?amount={tier_amount_sol}&reference={reference_key}&label=ZeroClaw+Subscription&memo={discord_user_id}&cluster=devnet)
```

Also mention:
- The exact SOL amount they need to send.
- That they should reply in this conversation once they've paid.
- That you'll verify on-chain before granting access (so they don't need
  to worry about delays — it's instant once the transaction confirms).

---

### Phase 3 — Persist pending record immediately

Right after sending the payment link, write a pending subscriber record
to Memory_Store so the `subscription_check` SOP can pick it up as a
safety net even if this live conversation ends before verification:

```json
{"name": "memory_store", "arguments": {
  "key": "subscriber:<discord_user_id>",
  "content": "{\"discord_user_id\":\"<discord_user_id>\",\"discord_username\":\"<discord_username>\",\"tier\":\"<tier>\",\"reference_key\":\"<reference_key>\",\"expected_amount_sol\":<tier_amount_sol>,\"period_seconds\":1800,\"status\":\"pending_payment\",\"subscribed_at\":null,\"expires_at\":null,\"grace_started_at\":null,\"wallet_address\":null,\"last_known_status\":null,\"renewal_dm_sent_for_expiry\":null}",
  "category": "subscribers"
}}
```

Then update the subscriber index. Recall the current index first:

```json
{"name": "memory_recall", "arguments": {"query": "subscriber_index", "strategy": "bm25", "limit": 1}}
```

Parse the recalled content as a JSON array. If absent or malformed,
treat as `[]`. Append `discord_user_id` if not already present. Write
back:

```json
{"name": "memory_store", "arguments": {
  "key": "subscriber_index",
  "content": "[\"<id_1>\",\"<id_2>\",...]",
  "category": "subscribers"
}}
```

On any Memory_Store write failure: log the error but do NOT stop the
conversation — the live verification path below is the primary flow;
the index write is only a safety net.

---

### Phase 4 — Wait for user to confirm payment

Tell the user to reply once they've paid. Do not poll silently or loop.
Stay in the conversation and answer any questions while they complete the
payment.

---

### Phase 5 — Payment verification

When the user says they've paid (or words to that effect), verify
on-chain. Use the same qualifying-transaction logic as
`check-payment/SKILL.md` Steps 1–3 — do not invent different
verification rules here.

**Step 5a — Fetch signatures for the merchant wallet:**

```
GET {proxy_url}/?method=getSignaturesForAddress&wallet={merchant_wallet}&limit=100
```

On non-2xx or unparseable JSON: tell the user the on-chain check hit a
temporary error and offer to try again in a moment. Do not grant
anything.

**Step 5b — Fetch individual transactions:**

For each returned signature:
```
GET {proxy_url}/?method=getTransaction&signature={sig}&encoding=jsonParsed
```

Skip failed individual lookups and continue with the rest.

**Step 5c — Filter qualifying transactions:**

A transaction qualifies only if ALL of the following hold:

1. Contains a native SOL transfer instruction (`program = "system"`,
   `parsed.type = "transfer"`).
2. Transfer destination is exactly `{merchant_wallet}`.
3. Transfer lamports (integer) ≥ `tier_amount_sol × 1,000,000,000`
   (integer arithmetic only — no floating-point).
4. `blockTime` is reasonably recent (within the last 24 hours is a
   sensible sanity check for a live DM flow — discard obviously stale
   transactions).

Select the qualifying transaction with the highest `blockTime`.

**Step 5d — If no qualifying transaction found:**

Tell the user the payment isn't visible on-chain yet. Offer to check
again in a minute. Do NOT grant the role on their word alone — every
grant must be backed by an independent on-chain match, the same standard
as everywhere else in this system.

---

### Phase 6 — Grant role and finalise record

If a qualifying transaction is found:

**Step 6a — Grant the Subscriber role** using the same logic as
`grant-subscriber-role/SKILL.md`:

1. Check current role status:
   ```
   GET {proxy_url}/discord/guilds/{discord_guild}/members/{discord_user_id}
   ```
   If `subscriber_role` is already in the `roles` array, skip the grant
   (idempotent).

2. If not already granted:
   ```json
   {"name": "http_request", "arguments": {
     "url": "{proxy_url}/discord/guilds/{discord_guild}/members/{discord_user_id}/roles/{subscriber_role}?method=PUT",
     "method": "GET"
   }}
   ```
   On non-2xx: tell the user something went wrong granting the role,
   post an operator alert to Subscribe_Channel
   (`channel_id: 1531347878906302487`), and do not confirm access to
   the user.

**Step 6b — Update Memory_Store with the confirmed record:**

```json
{"name": "memory_store", "arguments": {
  "key": "subscriber:<discord_user_id>",
  "content": "{\"discord_user_id\":\"<discord_user_id>\",\"discord_username\":\"<discord_username>\",\"tier\":\"<tier>\",\"reference_key\":\"<reference_key>\",\"expected_amount_sol\":<tier_amount_sol>,\"period_seconds\":1800,\"status\":\"active\",\"subscribed_at\":\"<blockTime as ISO 8601 UTC>\",\"expires_at\":\"<blockTime + 1800s as ISO 8601 UTC>\",\"grace_started_at\":null,\"wallet_address\":\"<sender wallet from transaction>\",\"last_known_status\":null,\"renewal_dm_sent_for_expiry\":null}",
  "category": "subscribers"
}}
```

`subscribed_at` and `expires_at` must be ISO 8601 UTC strings with
millisecond precision derived from the winning transaction's `blockTime`
(e.g. `"2026-08-02T12:00:00.000Z"`).

**Step 6c — Confirm to the user in the DM:**

Tell them their payment has been verified on-chain, their Subscriber
role has been granted, and they now have access to the subscriber-gated
channels. Keep it warm and brief.

---

## Error Reference

| Failure | Response |
|---|---|
| `/keygen` non-2xx or missing field | Apologise, ask user to retry in a moment. Do not proceed. |
| `memory_store` write fails (Phase 3) | Log error, continue — live verification is the primary path. |
| `getSignaturesForAddress` error (Phase 5a) | Tell user on-chain check hit a temporary error, offer to retry. |
| `getTransaction` error for one signature | Skip that signature, continue with the rest. |
| No qualifying transaction found (Phase 5d) | Tell user payment not visible yet, offer to check again shortly. Never grant on user's word alone. |
| Role grant non-2xx (Phase 6a) | Tell user something went wrong, post operator alert to Subscribe_Channel, do not confirm access. |
| `memory_store` write fails (Phase 6b) | Log error but do not block — role is already granted; `subscription_check` SOP will reconcile on its next run. |
