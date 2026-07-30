# Requirements Document

## Introduction

This feature replaces the static `wallet_mapping.json`-based subscriber onboarding with a self-service, Solana Pay-driven subscription system for the ZeroClaw subscription gatekeeper. When a Discord user expresses intent to subscribe, the system generates a unique Solana Pay transfer-request URL and QR code, posts it to Discord, and tracks the subscriber's state (tier, amount, period, grace, renewal) in ZeroClaw's SQLite memory backend. The check-payment skill is upgraded to use per-user reference key lookups (`getSignaturesForAddress` on the reference key), enforce amount verification, respect subscription tiers and grace periods, and proactively DM renewal links before expiry. All Solana RPC and Discord API calls continue to route through the existing Cloudflare Worker proxy because the `http_request` tool's POST body bug is still present. No private keys are held anywhere and the system never signs transactions (T1 custody tier).

---

## Glossary

- **Onboarding_Bot**: The ZeroClaw `test_agent` acting on Discord subscribe commands to generate and post Solana Pay links.
- **Subscription_Manager**: The ZeroClaw `test_agent` acting during the hourly cron cycle to evaluate subscriber state and execute role/DM actions.
- **Memory_Store**: ZeroClaw's SQLite-backed memory system (configured as `backend = "sqlite.sqlite"` in `config.toml`), used as the authoritative subscriber state database.
- **Proxy**: The Cloudflare Worker deployed at `https://solana-rpc-proxy.dharadarsh0.workers.dev` that accepts GET requests and forwards them as authenticated POST calls to Solana RPC endpoints and the Discord API.
- **Solana_Pay_URL**: A URI of the form `solana:<merchant_address>?amount=<amount>&spl-token=<USDC_mint>&reference=<reference_key>&label=<label>&memo=<memo>` conforming to the Solana Pay transfer-request specification.
- **Reference_Key**: A unique Ed25519 public key generated per subscription invoice, embedded in the Solana Pay URL, and used as the lookup key for `getSignaturesForAddress` to find the matching on-chain payment.
- **Subscriber_Record**: A memory entry in Memory_Store keyed by `"subscriber:<discord_user_id>"` containing: `discord_user_id`, `discord_username`, `wallet_address`, `tier`, `expected_amount_usdc`, `period_days`, `subscribed_at`, `expires_at`, `grace_started_at` (optional; may be `null`), `reference_key`, `status` (`pending_payment | active | lapsed | grace | expired`).
- **Tier**: A named subscription level (e.g., `standard`, `premium`) that determines `expected_amount_usdc` and `period_days`.
- **Grace_Period**: A configurable number of days (1–30 inclusive, default 3) after `expires_at` during which the subscriber retains the Discord role before removal is proposed.
- **Renewal_Window**: A configurable number of days (1–30 inclusive, default 5) before `expires_at` during which the Subscription_Manager proactively sends a renewal Solana Pay link.
- **USDC_Mint**: The USDC SPL token mint address `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU` (devnet).
- **Merchant_Wallet**: The receiving Solana wallet `pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak` — accepts payments only, never holds signing keys in the system.
- **Discord_Guild**: Server ID `1531347878906302484`.
- **Subscriber_Role**: Discord role ID `1531669950819733575` within Discord_Guild.
- **Subscribe_Channel**: Discord channel ID `1531347878906302487`.

---

## Requirements

### Requirement 1: Subscribe Command Detection

**User Story:** As a Discord user, I want to type a subscribe command in the Discord channel and receive a payment link immediately, so that I can start a subscription without admin intervention.

#### Acceptance Criteria

1. WHEN a Discord message in Subscribe_Channel contains the word "subscribe" as a standalone word (case-insensitive, not as part of a longer word such as "unsubscribe"), THE Onboarding_Bot SHALL detect the message within 5 seconds and begin the onboarding flow for the author of that message.
2. WHEN the onboarding flow begins for a Discord user who already has an active Subscriber_Record with `status = "active"`, THE Onboarding_Bot SHALL reply to that user within 5 seconds with a message indicating their subscription is already active and include the `expires_at` date formatted as ISO 8601 UTC (e.g., `2026-08-28T00:00:00Z`).
3. WHEN the onboarding flow begins for a Discord user who has an existing Subscriber_Record with `status = "pending_payment"`, THE Onboarding_Bot SHALL reply within 5 seconds with the previously generated Solana Pay URL and QR code link rather than generating a new reference key.
4. IF the Proxy returns an error during onboarding message posting, THEN THE Onboarding_Bot SHALL retry the Proxy call once after a 2-second delay and, if still failing, log the error as a memory entry in Memory_Store without silently discarding it.
5. WHEN a Discord message is sent by a bot account (i.e., the message author has `bot = true`), THE Onboarding_Bot SHALL ignore the message and SHALL NOT begin the onboarding flow.
6. IF Memory_Store is unavailable when the Onboarding_Bot attempts to look up or write a Subscriber_Record, THEN THE Onboarding_Bot SHALL reply to the user within 5 seconds with a message stating the service is temporarily unavailable and SHALL NOT partially create a Subscriber_Record.

---

### Requirement 2: Reference Key Generation

**User Story:** As the system, I want each subscription invoice to have a cryptographically unique reference key, so that payment lookup is precise and collision-free.

#### Acceptance Criteria

1. WHEN a Discord user initiates onboarding and no Subscriber_Record exists or the existing record does not have `status = "pending_payment"`, THE Onboarding_Bot SHALL generate a unique reference key that is a valid base58-encoded Ed25519 public key not matching any `reference_key` currently stored across all Subscriber_Records in Memory_Store.
2. WHEN a reference key is successfully generated, THE Onboarding_Bot SHALL write the complete Subscriber_Record (including the reference key and `status = "pending_payment"`) to Memory_Store before posting the Solana Pay URL to Discord, so that the key is persisted even if the Discord post subsequently fails; the Subscriber_Record SHALL include the `tier`, `expected_amount_usdc`, and `period_days` values for the selected tier, with any field not yet known at creation time stored as `null`.
3. IF the reference key generation step fails for any reason, THEN THE Onboarding_Bot SHALL abort the onboarding flow, post an error message to the subscriber in Subscribe_Channel, and SHALL NOT proceed to Discord message posting.
4. IF the Memory_Store write of the Subscriber_Record fails, THEN THE Onboarding_Bot SHALL discard the generated key, abort the onboarding flow, post an error message to the subscriber in Subscribe_Channel, and SHALL NOT proceed to Discord message posting.

---

### Requirement 3: Solana Pay URL and QR Code Generation

**User Story:** As a Discord user, I want to receive a Solana Pay link and scannable QR code so that I can pay with any Solana Pay-compatible wallet without copying addresses manually.

#### Acceptance Criteria

1. WHEN a reference key is generated for a subscriber, THE Onboarding_Bot SHALL construct a Solana_Pay_URL in the format `solana:<Merchant_Wallet>?amount=<expected_amount_usdc>&spl-token=<USDC_Mint>&reference=<reference_key>&label=ZeroClaw+Subscription&memo=<discord_user_id>`.
2. WHEN the Solana_Pay_URL is constructed, THE Onboarding_Bot SHALL generate a QR code URL by calling `https://chart.googleapis.com/chart?chs=300x300&cht=qr&chl=<URL-encoded Solana_Pay_URL>` via an `http_request` GET call within a 10-second timeout.
3. WHEN the Solana_Pay_URL and QR code URL are ready, THE Onboarding_Bot SHALL post a message to Subscribe_Channel via the Proxy containing: the subscriber's Discord mention, the plain-text Solana_Pay_URL, the QR code image link, the tier name, the USDC amount, and the subscription period in days.
4. IF the `expected_amount_usdc` for a tier is not a positive number with at most 6 decimal places, THEN THE Onboarding_Bot SHALL halt the onboarding flow without creating a pending payment record and SHALL post an error message to Subscribe_Channel identifying the invalid amount.
5. IF the Google Charts QR API call times out (> 10 seconds) or returns a non-2xx response, THEN THE Onboarding_Bot SHALL halt the onboarding flow without creating a pending payment record and SHALL post an error message to Subscribe_Channel.

---

### Requirement 4: Subscriber State Persistence in Memory_Store

**User Story:** As the system operator, I want subscriber state stored in ZeroClaw's memory backend, so that state survives agent restarts and no longer requires manual edits to wallet_mapping.json.

#### Acceptance Criteria

1. THE Memory_Store SHALL be the single authoritative source for all Subscriber_Records; THE Subscription_Manager SHALL NOT read from `wallet_mapping.json` during payment verification or role management.
2. WHEN a Subscriber_Record is created or updated, THE Onboarding_Bot or Subscription_Manager SHALL store the following fields: `discord_user_id`, `discord_username`, `wallet_address`, `tier`, `expected_amount_usdc`, `period_days`, `subscribed_at`, `expires_at`, `grace_started_at`, `reference_key`, `status`; any field not yet known at creation time SHALL be stored as `null`.
3. WHEN a payment is confirmed for a subscriber, THE Subscription_Manager SHALL update the Subscriber_Record with `status = "active"`, `subscribed_at` set to the payment block time (UTC Unix timestamp), and `expires_at` set to `subscribed_at + (period_days × 86400)` seconds, and SHALL update `subscribed_at` and `expires_at` on each subsequent renewal payment confirmation.
4. WHEN a subscription expires (current time ≥ `expires_at`) and no renewal payment is found within the same evaluation cycle, THE Subscription_Manager SHALL update the Subscriber_Record `status` to `"lapsed"` and, if `grace_started_at` is null, set `grace_started_at` to the current UTC timestamp.
5. IF a subscriber's `status` transitions from `"lapsed"` back to `"active"` due to a renewal payment, THEN THE Subscription_Manager SHALL reset `grace_started_at` to null and update `subscribed_at` and `expires_at` to the renewal payment values.
6. IF Memory_Store is unavailable when the Subscription_Manager attempts to read or write Subscriber_Records at the start of a cron cycle, THEN THE Subscription_Manager SHALL post an operator alert to Subscribe_Channel via the Proxy and SHALL terminate that cycle without modifying any Discord roles.
7. IF a Subscriber_Record is not found in Memory_Store for a given discord_user_id during a payment check, THEN THE Subscription_Manager SHALL log the missing record, skip that subscriber for the current cycle, and post an operator alert to Subscribe_Channel.

---

### Requirement 5: Per-User Reference Key Payment Verification

**User Story:** As the system, I want payment detection to use the subscriber's unique reference key rather than scanning all merchant transactions, so that payment matching is precise and scales to many subscribers.

#### Acceptance Criteria

1. WHEN the Subscription_Manager checks payment status for a subscriber, THE Subscription_Manager SHALL call `getSignaturesForAddress` on the subscriber's `reference_key` (not on the Merchant_Wallet address) via the Proxy, with `limit=100`.
2. WHEN `getSignaturesForAddress` returns one or more signatures for the reference key, THE Subscription_Manager SHALL call `getTransaction` for each returned signature (up to 100 per cycle) via the Proxy to retrieve parsed transaction details.
3. WHEN a transaction is retrieved, THE Subscription_Manager SHALL verify that: the transaction contains a USDC SPL token transfer instruction, the transfer destination is the Merchant_Wallet or an associated token account owned by the Merchant_Wallet, the USDC mint matches `USDC_Mint`, and the transfer amount expressed in integer raw token units (where 1 USDC = 1,000,000 units) is ≥ the subscriber's `expected_amount_usdc × 1,000,000`.
4. WHEN multiple transactions satisfy all conditions in criterion 3, THE Subscription_Manager SHALL select the one with the most recent `blockTime` as the confirmed payment (tie-breaking by highest `blockTime` value) and set `status = "active"`.
5. IF `getSignaturesForAddress` returns an empty list or no transaction satisfies all conditions, THEN THE Subscription_Manager SHALL set `status = "lapsed"` for that subscriber without modifying the subscriber's Discord role.
6. IF the Proxy returns an error or unparseable response for any RPC call, THEN THE Subscription_Manager SHALL set `status = "check_failed"`, retain the subscriber's previous status in a `last_known_status` field, and SHALL NOT change the subscriber's existing Discord role.
7. WHEN evaluating transactions, THE Subscription_Manager SHALL only consider transactions whose `blockTime` falls within the subscription window `[subscribed_at, subscribed_at + (period_days × 86400)]` seconds; transactions outside this window SHALL be discarded as non-qualifying.

---

### Requirement 6: Amount Verification

**User Story:** As the system operator, I want on-chain payment amounts verified against the subscriber's tier, so that under-payments cannot activate or extend a subscription.

#### Acceptance Criteria

1. WHEN evaluating a candidate payment transaction, THE Subscription_Manager SHALL read `expected_amount_usdc` from the subscriber's Subscriber_Record in Memory_Store.
2. WHEN the parsed USDC transfer amount in integer raw token units is less than `expected_amount_usdc × 1,000,000`, THE Subscription_Manager SHALL discard that transaction as non-qualifying and continue evaluating remaining signatures.
3. WHEN a transaction's USDC transfer amount in integer raw token units is ≥ `expected_amount_usdc × 1,000,000`, THE Subscription_Manager SHALL treat that transaction as qualifying and proceed with activating the subscription.
4. WHEN no qualifying transaction is found because all candidate transactions had insufficient amounts, THE Subscription_Manager SHALL set `status = "lapsed"` and SHALL post a message to Subscribe_Channel via the Proxy noting that payment was detected but the amount was insufficient, including the highest received amount (in USDC, 6 decimal places) and the required amount.
5. IF `expected_amount_usdc` is absent, null, or non-numeric in the Subscriber_Record, THEN THE Subscription_Manager SHALL set `status = "check_failed"` for that subscriber, log the configuration error, and SHALL NOT update the subscriber's Discord role.
6. THE Subscription_Manager SHALL perform all amount comparisons using integer arithmetic on raw token units (1 USDC = 1,000,000 units) with no floating-point rounding.

---

### Requirement 7: Subscription Tier Support

**User Story:** As the system operator, I want multiple subscription tiers with configurable amounts and periods, so that different access levels can coexist without code changes.

#### Acceptance Criteria

1. THE Subscription_Manager SHALL support at least two tiers: `standard` (0.1 USDC, 30 days) and `premium` (0.25 USDC, 30 days), with tier definitions readable from the Subscription_Manager's configuration context without requiring a restart or redeployment.
2. WHEN a subscriber's tier is `standard`, THE Subscription_Manager SHALL use `expected_amount_usdc = 0.1` and `period_days = 30` (derived from the tier's configuration values) for all payment and expiry calculations.
3. WHEN a subscriber's tier is `premium`, THE Subscription_Manager SHALL use `expected_amount_usdc = 0.25` and `period_days = 30` (derived from the tier's configuration values) for all payment and expiry calculations.
4. WHEN the onboarding flow runs for a new subscriber and no tier is specified in the subscribe command, THE Onboarding_Bot SHALL default to the `standard` tier and record `"standard"` as the `tier` field in the Subscriber_Record.
5. WHEN a subscriber specifies a valid tier in the subscribe command (e.g., "subscribe premium"), THE Onboarding_Bot SHALL use that tier's `expected_amount_usdc` and `period_days` values from configuration when constructing the Solana_Pay_URL and Subscriber_Record.
6. IF a subscriber specifies an unrecognized tier name in the subscribe command, THEN THE Onboarding_Bot SHALL post an error message to Subscribe_Channel listing the available tier names and SHALL NOT begin the onboarding flow.
7. IF a required tier definition (name, amount, or period) is missing from the configuration at agent startup, THEN THE Subscription_Manager SHALL log a fatal configuration error and SHALL NOT process any subscription checks until the configuration is corrected.

---

### Requirement 8: Grace Period Enforcement

**User Story:** As a subscriber, I want a grace period after my subscription expires before losing access, so that a brief payment delay doesn't immediately revoke my role.

#### Acceptance Criteria

1. THE Subscription_Manager SHALL read the grace period duration in days from a configurable value (`grace_period_days`) bounded between 1 and 30 inclusive; if the value is not set or falls outside this range, it SHALL default to 3 days.
2. WHEN a subscriber's `status` is `"lapsed"` and `grace_started_at` is not null and `current_time - grace_started_at < grace_period_days × 86400` seconds, THE Subscription_Manager SHALL treat the subscriber's effective status as `"grace"` and SHALL NOT propose role removal.
3. WHEN a subscriber's `status` is `"lapsed"` and `current_time - grace_started_at ≥ grace_period_days × 86400` seconds, THE Subscription_Manager SHALL transition the subscriber's effective status to `"expired"` and SHALL propose Discord role removal for that subscriber.
4. WHEN a subscriber transitions into `"grace"` status for the first time in a cycle, THE Subscription_Manager SHALL post a single reminder message to Subscribe_Channel via the Proxy indicating the subscriber's Discord mention, the grace expiry timestamp in ISO 8601 UTC format, and a renewal Solana Pay URL; duplicate reminders within the same hourly cycle SHALL NOT be posted.
5. IF a subscriber's `grace_started_at` is null and `status` is `"lapsed"`, THEN THE Subscription_Manager SHALL set `grace_started_at` to the current UTC timestamp, persist this value to Memory_Store immediately, and treat the subscriber as being in `"grace"` for that cycle.
6. IF the Proxy is unavailable when posting the grace reminder message, THEN THE Subscription_Manager SHALL retry once after 2 seconds; if still failing, the Subscription_Manager SHALL log the failure and continue role evaluation for that subscriber without blocking on the message.

---

### Requirement 9: Proactive Renewal DMs

**User Story:** As a subscriber, I want to receive a renewal payment link before my subscription expires, so that I can renew without losing access.

#### Acceptance Criteria

1. THE Subscription_Manager SHALL read the renewal reminder window in days from a configurable value (`renewal_reminder_days`) bounded between 1 and 30 inclusive; if the value is not set or falls outside this range, it SHALL default to 5 days.
2. WHEN a subscriber's `status` is `"active"` and `expires_at - current_time ≤ renewal_reminder_days × 86400` seconds, THE Subscription_Manager SHALL generate a fresh Solana Pay URL with a new reference key for that subscriber and deliver it as a Direct Message to the subscriber's Discord account within 60 seconds of the check cycle start.
3. WHEN generating a renewal Solana Pay URL, THE Subscription_Manager SHALL generate a new unique reference key, store it in the Subscriber_Record as the current `reference_key`, update `status` to `"pending_payment"`, and preserve the existing `subscribed_at` and `expires_at` fields until the renewal payment is confirmed.
4. IF a renewal reminder has already been sent for the current `expires_at` value (i.e., the `reference_key` in the Subscriber_Record was already rotated in a previous cycle for this expiry), THEN THE Subscription_Manager SHALL NOT update `reference_key` or `status` again and SHALL NOT send a duplicate renewal message.
5. WHEN a renewal payment is confirmed via the new reference key, THE Subscription_Manager SHALL calculate the new `expires_at` as `renewal_payment_block_time + (period_days × 86400)` seconds, set `status = "active"`, and reset `grace_started_at` to null.
6. IF the Proxy is unavailable when delivering the renewal DM, THEN THE Subscription_Manager SHALL retain the `status = "pending_payment"` state and retry delivery in up to 3 subsequent hourly cycles before marking the renewal delivery as failed without reverting the Subscriber_Record.
7. IF a subscriber's `expires_at` field is null or not a valid UTC timestamp, THEN THE Subscription_Manager SHALL skip renewal processing for that subscriber, log the error, and SHALL NOT mutate the Subscriber_Record.

---

### Requirement 10: Discord Role Management with Grace Awareness

**User Story:** As the system operator, I want Discord role grants and removals to respect the grace period and amount-verified payment status, so that access decisions are accurate and fair.

#### Acceptance Criteria

1. WHEN a subscriber's effective status is `"active"` and the subscriber does not have Subscriber_Role in Discord_Guild, THE Subscription_Manager SHALL grant Subscriber_Role to that subscriber via the Discord API (direct PUT, no approval required) within 30 seconds and SHALL record the grant timestamp in the Subscriber_Record.
2. WHEN a subscriber's effective status is `"lapsed"` and `grace_started_at` is null, THE Subscription_Manager SHALL set `grace_started_at` to the current UTC timestamp, persist it to Memory_Store, and retain the subscriber's Subscriber_Role for that cycle.
3. WHILE a subscriber's effective status is `"grace"` (i.e., lapsed but within the active grace window), THE Subscription_Manager SHALL retain the subscriber's Subscriber_Role and SHALL NOT propose role removal.
4. WHEN the grace period has elapsed for a subscriber with Subscriber_Role (effective status `"expired"`), THE Subscription_Manager SHALL post a role removal proposal to Subscribe_Channel via the Proxy and await admin approval before removing Subscriber_Role.
5. WHEN a subscriber's effective status is `"check_failed"`, THE Subscription_Manager SHALL NOT change the subscriber's Subscriber_Role and SHALL post an error notice to Subscribe_Channel within 60 seconds including the subscriber's Discord mention and the failure timestamp.
6. IF the Discord API returns a non-2xx response when granting or checking Subscriber_Role, THEN THE Subscription_Manager SHALL set that subscriber's status to `"check_failed"` for the current cycle, retain the previously held role unchanged, and SHALL NOT proceed with role changes.
7. IF the Discord API returns a non-2xx response when removing Subscriber_Role after admin approval, THEN THE Subscription_Manager SHALL log the failure, post an error notice to Subscribe_Channel, and SHALL NOT retry removal automatically without a new admin approval.

---

### Requirement 11: Cloudflare Worker Proxy Extensions

**User Story:** As the system, I want the Cloudflare Worker proxy to support reference key lookups and Discord DM sending, so that the agent's `http_request`-only constraint is satisfied for all new operations.

#### Acceptance Criteria

1. THE Proxy SHALL accept a GET request to `/?method=getSignaturesForAddress&wallet=<reference_key>&limit=<n>` (where `limit` is a positive integer between 1 and 1000) and forward it as a JSON-RPC POST with `{"jsonrpc":"2.0","id":1,"method":"getSignaturesForAddress","params":["<reference_key>",{"limit":<n>}]}` to the Solana RPC endpoint, returning the raw JSON-RPC response body and HTTP status code unmodified.
2. THE Proxy SHALL accept a GET request to `/discord/dm?user_id=<discord_user_id>&content=<URL-encoded-message>` (where `content` is 1–2000 characters after URL-decoding) and forward it as an authenticated POST using `Authorization: Bot <DISCORD_BOT_TOKEN>` to `https://discord.com/api/v10/users/<user_id>/channels` to open a DM channel, followed by a POST to `https://discord.com/api/v10/channels/<dm_channel_id>/messages` with `{"content":"<message>"}`, returning the sent message object and HTTP status code.
3. IF the first Discord API call (`/users/<user_id>/channels`) fails with a non-2xx response, THEN THE Proxy SHALL short-circuit and return the error response without attempting the second message-send call.
4. THE Proxy SHALL return a 400 status with a JSON body `{"error":"missing required parameter: <parameter_name>"}` if any required query parameter is absent from a supported endpoint.
5. IF the `limit` parameter in a `getSignaturesForAddress` request is absent, non-integer, less than 1, or greater than 1000, THEN THE Proxy SHALL return a 400 status with a descriptive error body.
6. THE Proxy SHALL NOT store any subscriber state, wallet addresses, or Discord user IDs beyond the scope of a single request.
7. WHEN the Proxy's Solana RPC primary endpoint returns a 5xx status or no response within 5 seconds, THE Proxy SHALL retry once against `https://api.devnet.solana.com` and return that response.
8. IF the fallback RPC endpoint also fails or times out, THEN THE Proxy SHALL return a 502 status with a JSON body `{"error":"both primary and fallback RPC endpoints failed"}`.

---

### Requirement 12: Subscription Check SOP Migration

**User Story:** As the system operator, I want the subscription_check SOP to drive from Memory_Store rather than a static file injection, so that the cron run is self-contained and doesn't require a shell wrapper.

#### Acceptance Criteria

1. WHEN a cron cycle starts, THE Subscription_Manager SHALL retrieve all Subscriber_Records from Memory_Store using ZeroClaw's memory recall capability, without reading from `wallet_mapping.json` or requiring the wrapper script to inject the roster.
2. IF Memory_Store is unavailable or returns an error when the Subscription_Manager attempts to retrieve Subscriber_Records at cron cycle start, THEN THE Subscription_Manager SHALL post an operator alert to Subscribe_Channel via the Proxy and SHALL terminate the cycle without modifying any Discord roles.
3. WHEN no Subscriber_Records are found in Memory_Store, THE Subscription_Manager SHALL post a notice to Subscribe_Channel via the Proxy indicating that no subscribers are registered and SHALL terminate the cycle without error.
4. THE Subscription_Manager SHALL process each Subscriber_Record independently; a `"check_failed"` outcome for one subscriber SHALL NOT prevent processing of remaining subscribers.
5. WHEN all subscribers have been processed, THE Subscription_Manager SHALL post a single consolidated status summary to Subscribe_Channel via the Proxy listing each subscriber's Discord mention, tier, effective status, `expires_at`, and role action taken (one of: `"granted"`, `"revoked"`, `"unchanged"`, `"check_failed"`); if the summary exceeds 2000 characters, it SHALL be split into multiple sequential messages.

---

### Requirement 13: Round-Trip Subscriber Record Serialization

**User Story:** As the system, I want Subscriber_Records serialized to and deserialized from Memory_Store without data loss, so that state is consistent across restarts.

#### Acceptance Criteria

1. THE Memory_Store SHALL serialize Subscriber_Records to JSON and store them as memory entries keyed by `"subscriber:<discord_user_id>"`, where `<discord_user_id>` is the exact string value of the field without transformation.
2. WHEN a Subscriber_Record is written to Memory_Store and then recalled by the Subscription_Manager, the recalled record SHALL contain identical values for all fields: `discord_user_id`, `discord_username`, `wallet_address`, `tier`, `expected_amount_usdc`, `period_days`, `subscribed_at`, `expires_at`, `reference_key`, `status`; the optional field `grace_started_at` SHALL be preserved as `null` when absent.
3. FOR ALL valid Subscriber_Records, serializing then deserializing SHALL produce a record with equal field values (round-trip property); all datetime fields (`subscribed_at`, `expires_at`, `grace_started_at`) SHALL be stored and retrieved as ISO 8601 UTC strings with millisecond precision (e.g., `"2026-07-29T12:00:00.000Z"`).
4. IF a recalled memory entry is missing any of the 10 required fields (`discord_user_id`, `discord_username`, `wallet_address`, `tier`, `expected_amount_usdc`, `period_days`, `subscribed_at`, `expires_at`, `reference_key`, `status`) or contains malformed JSON, THEN THE Subscription_Manager SHALL log the error identifying the affected key and the nature of the failure, skip that subscriber for the current cycle, and post an operator alert to Subscribe_Channel.
5. IF Memory_Store itself is unreachable at cycle start, THEN THE Subscription_Manager SHALL log the connectivity failure, post an operator alert to Subscribe_Channel via the Proxy, and terminate the cycle without processing any subscribers or modifying any Discord roles.
