# Implementation Plan: Solana Pay Onboarding

## Overview

Implement the self-service Solana Pay subscription system by extending the Cloudflare Worker proxy with three new endpoints, writing the Onboarding SKILL and SOP, rewriting the check-payment SKILL and subscription_check SOP to drive from Memory_Store, and covering all 14 correctness properties with fast-check property-based tests.

The dependency order enforced by hard constraints is:
1. Proxy extensions (`solana-rpc-proxy/worker.js`)
2. Onboarding SKILL (`shared/skills/default/onboarding/SKILL.md`)
3. Onboarding SOP (`agents/test_agent/workspace/sops/onboarding_check/`)
4. check-payment SKILL rewrite
5. subscription_check SOP rewrite
6. Property-based tests

---

## Tasks

- [x] 1. Extend the Cloudflare Worker Proxy (`solana-rpc-proxy/worker.js`)
  - [x] 1.1 Add `/keygen` endpoint to the proxy
    - Read `solana-rpc-proxy/worker.js` and locate the request router
    - Add a route for `GET /keygen` that calls `crypto.getRandomValues()` on a 32-byte `Uint8Array`
    - Implement base58 encoding using the Bitcoin alphabet (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`) with big-integer division; preserve leading zero bytes as `'1'`
    - Return `{"reference_key": "<base58_string>"}` with status 200
    - _Requirements: 2.1, 11.1_

  - [x] 1.2 Add `/discord/dm` endpoint to the proxy
    - Add a route for `GET /discord/dm?user_id=<id>&content=<URL-encoded-msg>`
    - Validate `user_id` and `content` are present; return 400 `{"error":"missing required parameter: <name>"}` if absent
    - URL-decode `content`; if decoded length is 0 or > 2000, return 400
    - POST to `https://discord.com/api/v10/users/<user_id>/channels` with `Authorization: Bot <DISCORD_BOT_TOKEN>` to open DM channel; on non-2xx, short-circuit and return the error
    - POST to `https://discord.com/api/v10/channels/<dm_channel_id>/messages` with `{"content":"<message>"}`; return `{"dm_channel_id":..., "message_id":..., "status":200}`
    - _Requirements: 11.2, 11.3, 11.4_

  - [x] 1.3 Add `/discord/channels/{id}/messages` passthrough to the proxy
    - Add a route matching `GET /discord/channels/<channel_id>/messages`
    - Forward as `GET https://discord.com/api/v10/channels/<channel_id>/messages?limit=<n>` with `Authorization: Bot <DISCORD_BOT_TOKEN>`
    - Return the raw Discord API JSON and status code unchanged
    - _Requirements: 11.1_

  - [x] 1.4 Add `limit` parameter validation for `getSignaturesForAddress`
    - In the existing `getSignaturesForAddress` handler, parse the `limit` query parameter before forwarding
    - If `limit` is absent, non-integer, < 1, or > 1000, return 400 with a descriptive JSON error body
    - _Requirements: 11.5_

  - [x] 1.5 Write property test for proxy limit validation (Property 13)
    - **Property 13: Proxy limit parameter validation**
    - **Validates: Requirements 11.1, 11.5**
    - Use `fc.integer()`, non-integer strings, and boundary values 0, 1, 1000, 1001 as inputs to the extracted `isValidLimit` helper
    - Tag comment: `// Feature: solana-pay-onboarding, Property 13: Proxy limit parameter validation`

  - [x] 1.6 Write property test for proxy DM content length validation (Property 14)
    - **Property 14: Proxy DM content length validation**
    - **Validates: Requirements 11.2, 11.4**
    - Generate arbitrary strings of varying length and URL-encoded forms with `fc.string()`; verify accept/reject boundary at length 1 and 2000
    - Tag comment: `// Feature: solana-pay-onboarding, Property 14: Proxy DM content length validation`

  - [x] 1.7 Add `/discord/guilds/*` member and role passthrough routes to the proxy
    - Add route matching `GET /discord/guilds/<guild_id>/members/<user_id>` → forward as `GET https://discord.com/api/v10/guilds/{guild_id}/members/{user_id}` with Bot auth
    - Add route matching `GET /discord/guilds/<guild_id>/members/<user_id>/roles/<role_id>` → translate to `PUT https://discord.com/api/v10/guilds/{guild_id}/members/{user_id}/roles/{role_id}` with Bot auth (role grant)
    - Both routes use `env.DISCORD_BOT_TOKEN`, return raw response body and status unchanged
    - Identified and added during Task 6 checkpoint: these routes were referenced by check-payment SKILL (Steps 7–8) and subscription_check SOP (Step 4d) but were missing from worker.js
    - _Requirements: 6.4, 6.5, 10.5_

- [x] 2. Write the Onboarding SKILL (`shared/skills/default/onboarding/SKILL.md`)
  - [x] 2.1 Write the SKILL.md with subscribe-command handling logic
    - Create `shared/skills/default/onboarding/SKILL.md`
    - Document inputs: `discord_user_id`, `discord_username`, `tier`, tier config (standard: 10 USDC / 30 days, premium: 25 USDC / 30 days)
    - Step 1: Recall `"subscriber:<discord_user_id>"` from Memory_Store; if `status=active` reply with expiry and stop; if `status=pending_payment` reply with existing URL and stop
    - Step 2: Validate tier against `[standard, premium]`; post error and stop if unrecognized
    - Step 3: Validate `expected_amount_usdc > 0` with ≤ 6 decimal places; post error and stop if invalid
    - Step 4: Call `GET /keygen`; on non-2xx abort, post error, do NOT write record
    - Step 5: Write Subscriber_Record to Memory_Store with `status=pending_payment`; on failure discard key, abort, post error
    - Step 6: Construct Solana_Pay_URL (`solana:<Merchant_Wallet>?amount=<amount>&spl-token=<USDC_Mint>&reference=<reference_key>&label=ZeroClaw+Subscription&memo=<discord_user_id>`)
    - Step 7: Call Google Charts QR API with 10-second timeout; on failure abort and post error
    - Step 8: Post to Subscribe_Channel via Proxy; retry once after 2 seconds on failure; on second failure log error memory entry
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.6, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 7.4, 7.5, 7.6_

  - [x] 2.2 Write property test for subscribe command detector (Property 1)
    - **Property 1: Subscribe command detector correctly classifies messages**
    - **Validates: Requirements 1.1, 1.5**
    - Extract the `shouldProcessMessage(content, isBot)` helper into a pure function testable with arbitrary strings and boolean bot flag
    - Verify `true` iff content matches `\bsubscribe\b` (case-insensitive) AND `isBot = false`; `false` for "unsubscribe", "subscribed", partial matches, or any bot message
    - Tag comment: `// Feature: solana-pay-onboarding, Property 1: Subscribe command detector correctly classifies messages`

  - [x] 2.3 Write property test for Solana Pay URL structure (Property 3)
    - **Property 3: Solana Pay URL structural completeness**
    - **Validates: Requirements 3.1**
    - Extract `buildSolanaPayURL(merchantWallet, amount, usdcMint, referenceKey, discordUserId)` as a pure function
    - Use `fc.string()` for wallet/key/userId and `fc.float({min:0.000001, max:999999})` for amount; assert URL starts with `"solana:"`, pathname = merchantWallet, and all five query params present with correct values
    - Tag comment: `// Feature: solana-pay-onboarding, Property 3: Solana Pay URL structural completeness`

  - [x] 2.4 Write property test for amount field validation (Property 4)
    - **Property 4: Amount field validation**
    - **Validates: Requirements 3.4**
    - Extract `isValidAmount(v)` as a pure function
    - Use `fc.float()` and `fc.integer()` including edge values 0, -1, 0.0000001, 1.1234567; assert accept iff `v > 0` and decimal digits ≤ 6
    - Tag comment: `// Feature: solana-pay-onboarding, Property 4: Amount field validation`

  - [x] 2.5 Write property test for Discord onboarding message completeness (Property 5)
    - **Property 5: Discord onboarding message contains all required fields**
    - **Validates: Requirements 3.3**
    - Extract `buildOnboardingMessage(record, solanaPayURL, qrURL)` as a pure function
    - Generate arbitrary valid Subscriber_Records with `fc.record()`; assert output contains Discord mention, full Solana_Pay_URL, QR URL, tier name, USDC amount string, and period days
    - Tag comment: `// Feature: solana-pay-onboarding, Property 5: Discord onboarding message contains all required fields`

- [x] 3. Write the Onboarding SOP (`agents/test_agent/workspace/sops/onboarding_check/`)
  - [x] 3.1 Create `SOP.md` for the onboarding_check SOP
    - Create `agents/test_agent/workspace/sops/onboarding_check/SOP.md`
    - Step 1: Poll Subscribe_Channel via `GET /discord/channels/1531347878906302487/messages?limit=20` through Proxy
    - Step 2: Iterate messages newest-first; skip `author.bot = true`; apply `\bsubscribe\b` (case-insensitive) regex; extract tier from second word (default `standard`); invoke Onboarding SKILL
    - Step 3: If Memory_Store unavailable, post "service temporarily unavailable" and abort without partial record
    - _Requirements: 1.1, 1.5, 1.6, 7.4_

  - [x] 3.2 Create `SOP.toml` for the onboarding_check SOP
    - Create `agents/test_agent/workspace/sops/onboarding_check/SOP.toml`
    - Configure `name = "onboarding_check"`, `max_concurrent = 1`, `admission_policy = "parallel"`
    - Add cron trigger: `schedule = "*/5 * * * *"`
    - _Requirements: 1.1_

- [x] 4. Rewrite the check-payment SKILL (`shared/skills/default/check-payment/SKILL.md`)
  - [x] 4.1 Rewrite SKILL.md to use reference_key lookup and integer amount verification
    - Rewrite `shared/skills/default/check-payment/SKILL.md`
    - Input: a `Subscriber_Record` object from SOP context (not a wallet address)
    - Step 1: Call `GET /?method=getSignaturesForAddress&wallet={reference_key}&limit=100`; on proxy error set `status=check_failed`, save `last_known_status`, return
    - Step 2: For each signature call `GET /?method=getTransaction&signature={sig}&encoding=jsonParsed`; on error mark that signature `check_failed` and continue
    - Step 3: Filter transactions — `blockTime` in `[subscribed_at_unix, subscribed_at_unix + period_days * 86400]`; must contain USDC SPL token transfer; destination = Merchant_Wallet or ATA; mint = `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU`; raw units ≥ `expected_amount_usdc × 1,000,000` (integer)
    - Step 4: Qualifying transactions found → select highest `blockTime`; set `status=active`, `subscribed_at` = blockTime, `expires_at` = `blockTime + period_days * 86400`
    - Step 5: No qualifying but insufficient-amount USDC transfers found → `status=lapsed`, post insufficient-amount notice with highest seen amount and required amount
    - Step 6: No USDC transactions → `status=lapsed`
    - Step 7: Check Discord role via `GET /guilds/1531347878906302484/members/{discord_user_id}`
    - Step 8: Apply role logic — active + no role → grant; expired + has role → post removal proposal; check_failed → no change; grace → retain
    - Document return structure: `{status, role_action, expires_at, highest_amount_usdc_seen}`
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 10.1, 10.4, 10.5, 10.6_

  - [x] 4.2 Write property test for transaction payment validation (Property 8)
    - **Property 8: Transaction payment validation correctness**
    - **Validates: Requirements 5.3, 6.1, 6.2, 6.3, 6.6**
    - Extract `isQualifyingTransaction(tx, record)` as a pure function
    - Generate arbitrary transaction objects (valid/invalid mint, destination, amount, instruction type) and Subscriber_Records with `fc.record()`; assert `qualifying=true` iff all four conditions simultaneously hold
    - Tag comment: `// Feature: solana-pay-onboarding, Property 8: Transaction payment validation correctness`

  - [x] 4.3 Write property test for subscription window filter (Property 9)
    - **Property 9: Subscription window filter**
    - **Validates: Requirements 5.7**
    - Extract `isInSubscriptionWindow(blockTime, subscribedAt, periodDays)` as a pure function
    - Use `fc.integer({min: 0})` for timestamps and `fc.integer({min:1, max:3650})` for periodDays; assert `inside=true` iff `subscribedAt ≤ blockTime ≤ subscribedAt + periodDays * 86400`
    - Tag comment: `// Feature: solana-pay-onboarding, Property 9: Subscription window filter`

  - [x] 4.4 Write property test for subscription expiry calculation (Property 7)
    - **Property 7: Subscription expiry calculation**
    - **Validates: Requirements 4.3**
    - Extract `computeExpiresAt(subscribedAtUnix, periodDays)` as a pure function (integer arithmetic only)
    - Use `fc.integer({min:0})` for timestamps and `fc.integer({min:1, max:3650})` for periodDays; assert `expiresAt === subscribedAtUnix + periodDays * 86400`
    - Tag comment: `// Feature: solana-pay-onboarding, Property 7: Subscription expiry calculation`

- [x] 5. Rewrite the subscription_check SOP
  - [x] 5.1 Rewrite `SOP.md` to drive from Memory_Store
    - Rewrite `agents/test_agent/workspace/sops/subscription_check/SOP.md`
    - Embed tier config and `grace_period_days=3`, `renewal_reminder_days=5` in a context block
    - Step 1: Recall all `"subscriber:*"` entries from Memory_Store; on failure post operator alert and terminate
    - Step 2: If empty, post "no subscribers registered" notice and terminate
    - Step 3 (one-time migration): If no subscriber records found but `wallet_mapping.json` is readable, seed Subscriber_Records from legacy file (`wallet_address` = JSON key, `tier=standard`, `expected_amount_usdc=0.1`, `period_days=30`, `status=pending_payment`, fresh reference key per entry)
    - Step 4 (per subscriber, independent — no stop-on-failure):
      - 4a: Renewal window check — if `status=active` and `expires_at - now ≤ renewal_reminder_days * 86400` and `renewal_dm_sent_for_expiry ≠ expires_at`: call `/keygen`, update record (`new reference_key`, `status=pending_payment`), set `renewal_dm_sent_for_expiry = expires_at`, send renewal DM via `/discord/dm`; retry DM up to 3 cycles on proxy failure
      - 4b: Invoke check-payment SKILL with the Subscriber_Record
      - 4c: Grace logic — `lapsed` + `grace_started_at=null` → set `grace_started_at=now`, persist, treat as `grace`, post reminder; `lapsed` + `now - grace_started_at < grace_period_days * 86400` → treat as `grace`; `lapsed` + elapsed ≥ → effective `expired`, post removal proposal
      - 4d: Execute Discord role action (active → grant; expired → propose removal; check_failed → no change; grace → retain)
      - 4e: Persist updated Subscriber_Record to Memory_Store
    - Step 5: Post consolidated summary (split at 2000 chars if needed) listing mention, tier, status, expires_at, role action
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 10.1, 10.2, 10.3, 10.4, 12.1, 12.2, 12.3, 12.4, 12.5_

  - [x] 5.2 Update `SOP.toml` to add cron trigger
    - Rewrite `agents/test_agent/workspace/sops/subscription_check/SOP.toml` to retain existing `manual` trigger and add `schedule = "0 * * * *"` (hourly) cron trigger
    - _Requirements: 12.1_

  - [x] 5.3 Write property test for grace period window enforcement (Property 11)
    - **Property 11: Grace period window enforcement**
    - **Validates: Requirements 8.2**
    - Extract `isInGracePeriod(currentTime, graceStartedAt, gracePeriodDays)` as a pure function
    - Use `fc.integer({min:0})` for timestamps and `fc.integer({min:1, max:30})` for gracePeriodDays; assert `inGrace=true` iff `currentTime - graceStartedAt < gracePeriodDays * 86400`
    - Tag comment: `// Feature: solana-pay-onboarding, Property 11: Grace period window enforcement`

  - [x] 5.4 Write property test for renewal DM deduplication (Property 12)
    - **Property 12: Renewal DM deduplication**
    - **Validates: Requirements 9.4**
    - Extract `shouldSendRenewalDM(record, currentTime, renewalWindowDays)` as a pure function
    - Generate Subscriber_Records where `renewal_dm_sent_for_expiry` equals or differs from `expires_at`; assert that when they are equal and `status=active`, no DM is triggered and reference key is not rotated
    - Tag comment: `// Feature: solana-pay-onboarding, Property 12: Renewal DM deduplication`

  - [x] 5.5 Write property test for bounded configuration value clamping (Property 10)
    - **Property 10: Bounded configuration value clamping**
    - **Validates: Requirements 8.1, 9.1**
    - Extract `resolveConfigValue(v, min, max, defaultVal)` as a pure function
    - Use `fc.integer()`, `fc.constant(null)`, non-integer strings; assert resolved value = `defaultVal` for null/non-integer, clamped to [min, max] otherwise
    - Tag comment: `// Feature: solana-pay-onboarding, Property 10: Bounded configuration value clamping`

- [x] 6. Checkpoint — verify proxy, skills, and SOPs are consistent
  - Ensure all new proxy endpoints are referenced correctly by SKILL.md files
  - Ensure Subscriber_Record schema is consistent across SKILL.md and SOP.md files
  - Ask the user if any questions arise before proceeding to tests.

- [x] 7. Write property-based tests (`tests/solana-pay-onboarding.test.js`)
  - [x] 7.1 Set up test file with fast-check and extract pure helper functions
    - Create `tests/solana-pay-onboarding.test.js`
    - Import fast-check (`fc`) and configure `fc.configureGlobal({ numRuns: 100 })`
    - Extract and co-locate all pure helper functions under test (or import from a shared `tests/helpers/solana-pay-helpers.js` if the helpers are large)
    - _Requirements: all_

  - [x] 7.2 Implement Property 2 — reference key uniqueness and base58 validity
    - **Property 2: Reference key uniqueness and base58 validity**
    - **Validates: Requirements 2.1**
    - Extract `decodeBase58(str)` from the proxy's keygen implementation; use `fc.integer({min:2, max:50})` as N; generate N keys (or use a deterministic keygen helper with random seeds); assert every key uses only base58 alphabet chars, decodes to exactly 32 bytes, and all N values are pairwise distinct
    - Tag comment: `// Feature: solana-pay-onboarding, Property 2: Reference key uniqueness and base58 validity`

  - [x] 7.3 Implement Property 6 — Subscriber_Record serialization round-trip
    - **Property 6: Subscriber_Record serialization round-trip**
    - **Validates: Requirements 4.2, 13.2, 13.3**
    - Build an `fc.record()` arbitrary for all 11 required fields; generate valid and null-field variants; serialize with `JSON.stringify` and deserialize with `JSON.parse`; assert field-for-field equality; assert datetime fields match `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z` or are null
    - Tag comment: `// Feature: solana-pay-onboarding, Property 6: Subscriber_Record serialization round-trip`

  - [x] 7.4 Collect and run all property tests (1–14)
    - Consolidate all property sub-tasks from tasks 1.5, 1.6, 2.2, 2.3, 2.4, 2.5, 4.2, 4.3, 4.4, 5.3, 5.4, 5.5, 7.2, 7.3 into `tests/solana-pay-onboarding.test.js`
    - Each test block is tagged with its property number and the `fc.configureGlobal` setting applies globally
    - Run `npx jest tests/solana-pay-onboarding.test.js --testTimeout=30000` (or vitest equivalent) and confirm all 14 property tests pass
    - _Requirements: all correctness properties_

- [x] 8. Final checkpoint — ensure all tests pass
  - All 76 tests across 14 property suites pass (confirmed via `npx jest tests/solana-pay-onboarding.test.js --testTimeout=30000`).

---

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- The proxy extensions (Task 1) MUST be complete before any skill or SOP that calls new endpoints
- The Onboarding SKILL (Task 2) MUST be complete before the onboarding_check SOP (Task 3)
- The check-payment SKILL rewrite (Task 4) MUST be complete before the subscription_check SOP rewrite (Task 5)
- Tests (Task 7) go last
- All pure helper functions must be extracted as standalone JS functions to make them testable with fast-check
- fast-check is the PBT library (`npm install --save-dev fast-check`)
- `fc.configureGlobal({ numRuns: 100 })` applies to all 14 property tests
- Each test block must carry a comment `// Feature: solana-pay-onboarding, Property N: <text>`
- The one-time migration in Task 5.1 reads `wallet_mapping.json` via `read_file` tool and seeds Memory_Store; it fires only when Memory_Store has no `"subscriber:*"` entries
- After migration, `wallet_mapping.json` is never read again by any component
- Checkpoints (Tasks 6, 8) ensure incremental validation at natural workflow breaks

---

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "1.3", "1.4", "1.7"] },
    { "id": 1, "tasks": ["1.5", "1.6", "2.1"] },
    { "id": 2, "tasks": ["2.2", "2.3", "2.4", "2.5", "3.1", "3.2"] },
    { "id": 3, "tasks": ["4.1"] },
    { "id": 4, "tasks": ["4.2", "4.3", "4.4", "5.1", "5.2"] },
    { "id": 5, "tasks": ["5.3", "5.4", "5.5"] },
    { "id": 6, "tasks": ["7.1"] },
    { "id": 7, "tasks": ["7.2", "7.3"] },
    { "id": 8, "tasks": ["7.4"] }
  ]
}
```
