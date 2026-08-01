---
name: check-payment
description: Check payment status for Solana Pay subscriptions using per-user reference keys, enforce amount verification, respect subscription windows, and manage Discord roles.
version: 1.0.0
tools:
  - http_request
  - memory_store
  - memory_recall
---

# Skill: Check Payment Status and Manage Discord Roles

## Overview

This skill receives a `Subscriber_Record` object from SOP context and performs payment verification plus Discord role management. It does NOT take a raw wallet address — it uses the `reference_key` field from the record to look up transactions.

## Constants

- **Proxy URL:** `https://solana-rpc-proxy.dharadarsh0.workers.dev`
- **Merchant Wallet:** `pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak`
- **Discord Guild ID:** `1531347878906302484`
- **Subscriber Role ID:** `1531669950819733575`
- **Subscribe Channel ID:** `1531347878906302487`
- **Signup Channel ID:** `1532423294354063410`

## Tool Call Format (critical — follow exactly)

When calling `http_request`, you MUST nest all parameters inside an `"arguments"` object. Never place `url`, `method`, or `headers` as siblings of `"name"`.

CORRECT:
```json
{"name": "http_request", "arguments": {"url": "https://example.com", "method": "GET"}}
```

INCORRECT (will fail):
```json
{"name": "http_request", "url": "https://example.com", "method": "GET"}
```

## Input

A `Subscriber_Record` object from SOP context with the following fields:

| Field | Type | Description |
|---|---|---|
| `discord_user_id` | string | Discord snowflake ID of the subscriber |
| `discord_username` | string | Discord username |
| `reference_key` | string | Base58-encoded 32-byte reference key for the current invoice |
| `expected_amount_sol` | number | Required SOL amount (e.g. `0.001` or `0.0025`) |
| `period_days` | integer | Subscription duration in days (e.g. `30`) |
| `subscribed_at` | string \| null | ISO 8601 UTC timestamp of last confirmed payment, or `null` if pending |
| `status` | string | Current status: `pending_payment`, `active`, `lapsed`, `grace`, `expired`, `check_failed` |
| (other fields) | various | All other Subscriber_Record fields as defined in the schema |

## Pre-flight: Validate expected_amount_sol

Before making any RPC calls, validate the `expected_amount_sol` field from the Subscriber_Record:
- If `expected_amount_sol` is absent, `null`, or not a valid positive number, this is a configuration error.
- Log the error (e.g., write a memory entry: `"error:config:<discord_user_id>"` with the nature of the failure).
- Set `status = "check_failed"`.
- Do NOT update the subscriber's Discord role.
- Return immediately:
  ```json
  {
    "status": "check_failed",
    "role_action": "no_change",
    "expires_at": null,
    "highest_amount_sol_seen": null,
    "sender_wallet": null
  }
  ```

## Step 1: Fetch Signatures for Merchant Wallet

Call:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/?method=getSignaturesForAddress&wallet={merchant_wallet}&limit=100
```

**On any proxy error** (non-2xx status, timeout, or unparseable JSON):
- Save the current `status` value as `last_known_status` in the record.
- Set `status = "check_failed"`.
- Return immediately:
  ```json
  {
    "status": "check_failed",
    "role_action": "no_change",
    "expires_at": null,
    "highest_amount_sol_seen": null,
    "sender_wallet": null
  }
  ```
- Do NOT proceed to any further steps.

## Step 2: Fetch Individual Transactions

For each signature in the list returned by Step 1, call:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/?method=getTransaction&signature={sig}&encoding=jsonParsed
```

**On error for a specific signature** (non-2xx or unparseable response):
- Mark that individual signature as `check_failed`.
- Continue to the next signature.
- Do NOT abort the entire check.

## Step 3: Filter and Score Transactions

For each successfully retrieved transaction, evaluate ALL of the following conditions. A transaction qualifies only if every condition holds:

### Condition A: Subscription Window
Compute `subscribed_at_unix`:
- If `subscribed_at` is not null: parse it as an ISO 8601 UTC string and obtain its Unix timestamp (integer seconds).
- If `subscribed_at` is null: use `0` as `subscribed_at_unix` (any past blockTime is in-window).

The transaction's `blockTime` must satisfy:
```
subscribed_at_unix ≤ blockTime ≤ subscribed_at_unix + period_days × 86400
```
Transactions outside this window are discarded.

### Condition B: Native SOL Transfer Instruction
The transaction must contain a native SOL transfer instruction. This means there must be an instruction in `transaction.message.instructions` or within `meta.innerInstructions[*].instructions` where:
- `program` is `"system"` (System Program)
- `parsed.type` is `"transfer"`

### Condition C: Transfer Destination is Merchant Wallet
The transfer destination (the `destination` or `account` field in `parsed.info`) must be exactly the Merchant Wallet address `pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak`.

### Condition D: Amount ≥ Required (integer arithmetic)
Read the raw integer lamports from `parsed.info.lamports`. Parse as an integer. This amount must satisfy:
```
raw_lamports ≥ expected_amount_sol × 1,000,000,000
```
This comparison MUST be done with integer arithmetic only — no floating-point rounding. For example, for `expected_amount_sol = 0.001`, the threshold is exactly `1000000` lamports.

### Condition E: User Identification (Best Effort)
Since Solana Pay memos are not reliably included by all wallets and reference keys may not appear in transaction data, we use a best-effort approach:

**If the Subscriber_Record has a `wallet_address` field (not null):**
- Extract the sender wallet from the transfer instruction's `source` field in `parsed.info`
- This sender wallet should match the `wallet_address` field from the Subscriber_Record
- If they don't match, discard the transaction

**If the Subscriber_Record has no `wallet_address` (null):**
- Skip wallet address validation
- Accept the transaction based on amount, destination, and timing alone
- This allows manual recovery for users who haven't completed wallet registration

**Note**: The reference key in the Solana Pay URL is primarily for idempotency and tracking purposes, but cannot be reliably extracted from the transaction data since not all wallets include it as an account key or memo.

### Tracking Highest Amount Seen
As you iterate over all instructions in all transactions, track the highest SOL transfer amount seen across ALL SOL transfers (qualifying or not) to the Merchant Wallet. Express this as:
```
highest_amount_sol_seen = max_lamports / 1,000,000,000
```
(a float with 9 decimal places, e.g. `0.001500000`). If no SOL transfers are found at all, this value remains `null`.

## Step 4: Qualifying Transactions Found

If one or more transactions satisfy ALL conditions in Step 3:
- Select the transaction with the **highest `blockTime`** (most recent).
- Extract the sender wallet address from the winning transaction's transfer instruction `source` field
- Set:
  - `status = "active"`
  - `subscribed_at` = ISO 8601 UTC string derived from the winning `blockTime` (e.g., `"2026-07-29T12:00:00.000Z"`)
  - `expires_at` = ISO 8601 UTC string derived from `blockTime + period_days × 86400` seconds
  - `sender_wallet` = the extracted sender wallet address

Proceed to Step 7.

## Step 5: No Qualifying Transactions — Insufficient Amount

If NO qualifying transactions were found, but at least one SOL transfer to the Merchant Wallet was detected with an amount below the required threshold:
- Set `status = "lapsed"`.
- Set `sender_wallet = null` (no qualifying transaction found).
- Post a notice to Subscribe_Channel via proxy:
  ```
  GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=<URL-encoded message>
  ```
  Message content (URL-encode before sending):
  ```
  ⚠️ @{discord_username} — payment detected but amount insufficient. Highest amount seen: {highest_amount_sol_seen} SOL. Required: {expected_amount_sol} SOL.
  ```

Proceed to Step 7.

## Step 6: No SOL Transactions Found

If NO SOL transfers were found at all (no transactions matched conditions B–D, regardless of amount):
- Set `status = "lapsed"`.
- Set `sender_wallet = null` (no transaction found).

Proceed to Step 7.

## Step 7: Check Current Discord Role

Call:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}
```

Check if the role `"1531669950819733575"` appears in the `roles` array of the response JSON.

- If it does: `subscriber_has_role = true`
- If it does not: `subscriber_has_role = false`
- If the Discord API call fails (non-2xx response): treat as `check_failed` **for role purposes only** — set `role_check_failed = true`.

## Step 8: Apply Role Logic

Evaluate the following rules **in order**, applying the first matching rule:

| Condition | `role_action` | Action |
|---|---|---|
| `status = "check_failed"` | `"no_change"` | No Discord role change. Post an error notice to Subscribe_Channel via proxy: `⚠️ Payment check failed for @{discord_username}. Failed at: {ISO 8601 UTC timestamp of failure}. Manual review required.` Then return. |
| `role_check_failed = true` | `"no_change"` | Discord role check failed; no change. Return. |
| `status = "active"` AND `subscriber_has_role = false` | `"grant_role"` | Execute role grant via proxy using ?method=PUT. Record grant timestamp in Subscriber_Record. |
| `status = "active"` AND `subscriber_has_role = true` | `"no_change"` | Subscriber already has role; nothing to do. |
| `status = "grace"` | `"no_change"` | Retain role during grace window. |
| `status = "lapsed"` AND `subscriber_has_role = true` | `"propose_removal"` | Post removal proposal to Subscribe_Channel via proxy. |
| `status = "lapsed"` AND `subscriber_has_role = false` | `"no_change"` | Subscriber does not have role; nothing to do. |
| `status = "expired"` AND `subscriber_has_role = true` | `"propose_removal"` | Post removal proposal to Subscribe_Channel via proxy. |
| `status = "expired"` AND `subscriber_has_role = false` | `"no_change"` | Nothing to do. |

### Grant Role (when `role_action = "grant_role"`)
Execute via the `http_request` tool:
```
{"name": "http_request", "arguments": {"url": "https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/1531347878906302484/members/{discord_user_id}/roles/1531669950819733575?method=PUT", "method": "GET"}}
```
The proxy requires `?method=PUT` as a query parameter to specify the HTTP method for the Discord API call, but the http_request tool should call it with method="GET".

After a successful grant, record the grant timestamp in the Subscriber_Record by setting a `role_granted_at` field to the current ISO 8601 UTC timestamp (e.g., `"2026-07-29T12:00:00.000Z"`). This persists into Memory_Store when the SOP updates the record after the skill returns.

### Propose Removal (when `role_action = "propose_removal"`)
Post to Subscribe_Channel via proxy:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=<URL-encoded message>
```
Message content (URL-encode before sending):
```
⚠️ Payment lapsed for @{discord_username}. Propose removal of subscriber role. Admin approval required. React with ✅ to approve or ❌ to decline.
```
Do NOT remove the role until admin approval is received.

## Return Structure

After completing all steps, return the following JSON object:

```json
{
  "status": "<active|lapsed|check_failed>",
  "role_action": "<grant_role|propose_removal|no_change>",
  "expires_at": "<ISO 8601 UTC string or null>",
  "highest_amount_sol_seen": "<float with 9 decimal places or null>",
  "sender_wallet": "<base58 wallet address or null>"
}
```

### Return value semantics

| Field | Description |
|---|---|
| `status` | Final effective status after payment evaluation. One of: `active`, `lapsed`, `check_failed`. |
| `role_action` | Action taken (or proposed) for the Discord role. One of: `grant_role`, `propose_removal`, `no_change`. |
| `expires_at` | ISO 8601 UTC string of subscription expiry (`blockTime + period_days × 86400`), or `null` if payment was not confirmed. |
| `highest_amount_sol_seen` | Highest SOL amount observed in any SOL transfer to the Merchant Wallet, expressed as a float with 9 decimal places (e.g. `0.001500000`). `null` if no SOL transfers were found. |
| `sender_wallet` | The wallet address that sent the qualifying payment transaction, or `null` if no qualifying transaction was found. |

## Error Summary

| Failure | Response |
|---|---|
| `expected_amount_sol` absent, null, or non-numeric | Return `{status: "check_failed", role_action: "no_change", expires_at: null, highest_amount_sol_seen: null, sender_wallet: null}` immediately; log config error. |
| `getSignaturesForAddress` proxy error (non-2xx, timeout, bad JSON) | Return `{status: "check_failed", role_action: "no_change", expires_at: null, highest_amount_sol_seen: null, sender_wallet: null}` immediately. |
| `getTransaction` error for a specific signature | Mark that signature as failed; continue processing remaining signatures. |
| Discord role check returns non-2xx | Set `role_check_failed = true`; apply `role_action = "no_change"`. |
| Discord role grant returns non-2xx | Set `status = "check_failed"` for this cycle; retain existing role; post error notice to Subscribe_Channel. |
| `status = "check_failed"` (any cause) | Post error notice to Subscribe_Channel including subscriber's Discord mention and failure timestamp. |
| Insufficient-amount SOL transfer detected | Set `status = "lapsed"`; post insufficient-amount notice to Subscribe_Channel. |
