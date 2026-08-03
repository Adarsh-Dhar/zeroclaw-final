---
name: check-payment
description: Check payment status for Solana Pay subscriptions using per-user reference keys, enforce amount verification, respect subscription windows, and manage Discord roles. Supports batch processing of multiple subscriber records in a single call to minimize API usage and avoid rate limits.
version: 2.0.0
tools:
  - http_request
  - memory_store
  - memory_recall
---

# Skill: Check Payment Status and Manage Discord Roles

## Overview

This skill receives an array of `Subscriber_Record` objects from SOP context and performs payment verification plus Discord role management for all records in a single batch call. It does NOT take a raw wallet address — it uses the `reference_key` field from each record to look up transactions. Batch processing reduces LLM API calls and avoids rate limits.

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

An array of `Subscriber_Record` objects from SOP context. Each record has the following fields:

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

## Output

An array of result objects with the same length as the input array, where each result corresponds to the input record at the same index. Each result object contains:

| Field | Type | Description |
|---|---|---|
| `status` | string | Updated status: `active`, `lapsed`, `check_failed`, or unchanged from input |
| `role_action` | string | Discord role action: `granted`, `removed`, `no_change`, or `check_failed` |
| `expires_at` | string \| null | ISO 8601 UTC expiry timestamp if payment found, otherwise `null` |
| `highest_amount_sol_seen` | number \| null | Highest SOL amount seen in any transaction, or `null` if none found |
| `sender_wallet` | string \| null | Sender wallet address from qualifying transaction, or `null` |

## Pre-flight: Validate expected_amount_sol

Before making any RPC calls, validate the `expected_amount_sol` field from each Subscriber_Record:
- If `expected_amount_sol` is absent, `null`, or not a valid positive number for any record, this is a configuration error.
- Log the error (e.g., write a memory entry: `"error:config:<discord_user_id>"` with the nature of the failure).
- Set `status = "check_failed"` for that specific record.
- Do NOT update that subscriber's Discord role.
- Continue processing remaining records (failure in one record does not abort the entire batch).

## Step 1: Batch Fetch Signatures for Merchant Wallet

Call once for the entire batch:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/?method=getSignaturesForAddress&wallet={merchant_wallet}&limit=100
```

**On any proxy error** (non-2xx status, timeout, or unparseable JSON):
- Save the current `status` value as `last_known_status` in all records.
- Set `status = "check_failed"` for all records.
- Return an array of failure results for all records:
  ```json
  [
    {
      "status": "check_failed",
      "role_action": "no_change",
      "expires_at": null,
      "highest_amount_sol_seen": null,
      "sender_wallet": null
    },
    ...
  ]
  ```
- Do NOT proceed to any further steps.

## Step 2: Batch Fetch Individual Transactions

For each signature in the list returned by Step 1, call:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/?method=getTransaction&signature={sig}&encoding=jsonParsed
```

**On error for a specific signature** (non-2xx or unparseable response):
- Mark that individual signature as `check_failed`.
- Continue to the next signature.
- Do NOT abort the entire batch check.

After fetching all transactions, build a shared transaction map that all subscriber records can query against. This avoids redundant RPC calls across subscribers.

## Step 3: Process Each Subscriber Record Against Shared Transaction Map

For each `Subscriber_Record` in the input array, evaluate ALL of the following conditions against the shared transaction map. A transaction qualifies only if every condition holds:

### Condition A: Subscription Window
Compute `subscribed_at_unix`:
- If `subscribed_at` is not null: parse it as an ISO 8601 UTC string and obtain its Unix timestamp (integer seconds).
- If `subscribed_at` is null: use `0` as `subscribed_at_unix` (any past blockTime is in-window).

The transaction's `blockTime` must satisfy:
```
subscribed_at_unix ≤ blockTime ≤ subscribed_at_unix + period_seconds
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

## Step 4: Per-Subscriber Result Generation

For each subscriber record, based on the transaction filtering results:

**If one or more transactions satisfy ALL conditions in Step 3:**
- Select the transaction with the **highest `blockTime`** (most recent).
- Extract the sender wallet address from the winning transaction's transfer instruction `source` field
- Set result for this subscriber:
  - `status = "active"`
  - `subscribed_at` = ISO 8601 UTC string derived from the winning `blockTime` (e.g., `"2026-07-29T12:00:00.000Z"`)
  - `expires_at` = ISO 8601 UTC string derived from `blockTime + period_seconds` seconds
  - `sender_wallet` = the extracted sender wallet address

**If NO qualifying transactions were found, but at least one SOL transfer to the Merchant Wallet was detected with an amount below the required threshold:**
- Set result for this subscriber:
  - `status = "lapsed"`
  - `sender_wallet = null` (no qualifying transaction found)
- Note: The SOP will handle posting the insufficient amount notice

**If NO SOL transfers were found at all:**
- Set result for this subscriber:
  - `status = "lapsed"`
  - `sender_wallet = null` (no transaction found)

Proceed to Step 5 for Discord role checking.

## Step 5: Batch Discord Role Checking

For each subscriber record with their computed result, check the current Discord role status:

Call for each subscriber:
```
GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/{discord_guild}/members/{discord_user_id}
```

**On error checking membership (non-2xx, not 404):**
- Set `role_action = "check_failed"` for that subscriber
- Continue with remaining subscribers

**If member has subscriber_role:**
- Set `role_action = "no_change"` for that subscriber

**If member does NOT have subscriber_role (or 404 response):**
- If result status is `active`: Grant the role via:
  ```
  GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/guilds/{discord_guild}/members/{discord_user_id}/roles/{subscriber_role}?method=PUT
  ```
  - On success: set `role_action = "granted"`
  - On non-2xx: set `role_action = "check_failed"`
- If result status is not `active`: set `role_action = "no_change"`

## Step 6: Return Batch Results

Return an array of result objects with the same length as the input array, where each result corresponds to the input record at the same index:

```json
[
  {
    "status": "<final_status>",
    "role_action": "<final_role_action>",
    "expires_at": "<final_expires_at_or_null>",
    "highest_amount_sol_seen": "<final_highest_amount_or_null>",
    "sender_wallet": "<final_sender_wallet_or_null>"
  },
  ...
]
```

**Note:** Discord role changes (grant/removal proposals) are handled by the SOP based on the returned status and role_action values. The skill focuses on payment verification and role status checking only.

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
