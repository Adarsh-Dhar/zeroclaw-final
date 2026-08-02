#!/bin/bash
# test_flow.sh — ZeroClaw DM subscription flow verification
#
# Covers all 9 steps from the verification checklist:
#   0. Daemon sanity + SOP list intact
#   1. Baseline reply (bot online + peer group working)
#   2. Trigger negotiation (bot presents tiers, no premature grant)
#   3. Tier selection -> solana: URI + pending Memory_Store record
#   4. [MANUAL] Real on-chain payment
#   5. Payment confirmation -> RPC check fires
#   6. Role confirmed via Discord API
#   7. Memory_Store record updated to active
#   8. SOP regression — subscription_check doesn't re-process active subscriber
#   9. Negative test — "I paid" without a real tx -> role NOT granted
#
# Usage:
#   ./test_flow.sh <TEST_DISCORD_USER_ID> [SECOND_TEST_DISCORD_USER_ID]
#
# Prerequisites:
#   - jq installed  (brew install jq)
#   - zeroclaw binary on PATH or at ~/.cargo/bin/zeroclaw
#   - Daemon running for steps 8+  (zeroclaw daemon &)

# compat: do NOT use bash 4-only features (macOS ships bash 3.2)
# No ${var,,}, no (( )), no [[ =~ ]] with groups, no mapfile

# ── Constants ────────────────────────────────────────────────────────────────
PROXY="https://solana-rpc-proxy.dharadarsh0.workers.dev"
GUILD_ID="1531347878906302484"
SUBSCRIBER_ROLE_ID="1531669950819733575"
MERCHANT_WALLET="pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
AGENT="${ZEROCLAW_AGENT:-test_agent}"
ZC_CONFIG_DIR="${ZEROCLAW_CONFIG_DIR:-$HOME/.zeroclaw}"
ZC="${ZEROCLAW_BIN:-}"
if [ -z "$ZC" ]; then
  ZC=$(which zeroclaw 2>/dev/null || true)
fi
if [ -z "$ZC" ]; then
  ZC="$HOME/.cargo/bin/zeroclaw"
fi

# ── Colours (safe subset) ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

FAILURES=0

pass() { echo "${GREEN}  PASS${RESET}  $*"; }
fail() { echo "${RED}  FAIL${RESET}  $*"; FAILURES=$((FAILURES + 1)); }
info() { echo "${CYAN}  INFO${RESET}  $*"; }
step() { echo ""; echo "${BOLD}${YELLOW}>> Step $*${RESET}"; }
warn() { echo "${YELLOW}  WARN  $*${RESET}"; }

lowercase() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# ── Args ─────────────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  echo "Usage: $0 <TEST_DISCORD_USER_ID> [SECOND_TEST_DISCORD_USER_ID]"
  echo "  TEST_DISCORD_USER_ID        primary test account Discord snowflake"
  echo "  SECOND_TEST_DISCORD_USER_ID optional; used for negative test (step 9)"
  exit 1
fi

PRIMARY_USER_ID="$1"
NEGATIVE_USER_ID="${2:-$1}"

# ── Dependency checks ────────────────────────────────────────────────────────
echo ""
echo "${BOLD}ZeroClaw DM Subscription Flow -- Test Suite${RESET}"
echo "=============================================="

if ! command -v jq >/dev/null 2>&1; then
  echo "${RED}ERROR: jq is required. Install with: brew install jq${RESET}"
  exit 1
fi
if [ ! -x "$ZC" ]; then
  echo "${RED}ERROR: zeroclaw binary not found at: $ZC${RESET}"
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
member_has_role() {
  _uid="$1"
  _rid="$2"
  _resp=$(curl -sf "${PROXY}/discord/guilds/${GUILD_ID}/members/${_uid}" 2>/dev/null) || return 1
  echo "$_resp" | jq -e --arg r "$_rid" '(.roles // []) | index($r) != null' >/dev/null 2>&1
}

memory_subscriber() {
  _uid="$1"
  "$ZC" memory export --agent "$AGENT" --config-dir "$ZC_CONFIG_DIR" 2>/dev/null \
    | grep -A1 "subscriber:${_uid}" \
    | tail -1 \
    | sed 's/^[[:space:]]*//'
}

json_field() {
  # json_field <json_string> <field>
  echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2','') or '')" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0 — Sanity: SOP list + proxy
# ─────────────────────────────────────────────────────────────────────────────
step "0 -- Sanity: SOP list + proxy reachable"

SOP_LIST=$("$ZC" sop list --config-dir "$ZC_CONFIG_DIR" 2>&1 || true)

if echo "$SOP_LIST" | grep -q "subscription_check"; then
  pass "subscription_check SOP loaded"
else
  fail "subscription_check SOP not found (output: $SOP_LIST)"
fi

if echo "$SOP_LIST" | grep -q "onboarding_check"; then
  fail "onboarding_check SOP still present at $ZC_CONFIG_DIR/sops/ -- should have been deleted"
else
  pass "onboarding_check SOP absent (correctly cleaned up)"
fi

KEYGEN_RESP=$(curl -sf "${PROXY}/keygen" 2>/dev/null || true)
if echo "$KEYGEN_RESP" | jq -e '.reference_key' >/dev/null 2>&1; then
  pass "Proxy /keygen reachable"
else
  fail "Proxy /keygen unreachable (response: $KEYGEN_RESP) -- check worker deployment"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Baseline reply
# ─────────────────────────────────────────────────────────────────────────────
step "1 -- Baseline: bot replies to DMs"
echo ""
warn "MANUAL ACTION REQUIRED"
info "From your test Discord account (ID: ${PRIMARY_USER_ID}), DM the bot: \"hi\""
info "Wait up to 30 seconds for a reply, then answer below."
printf "  Did the bot reply? [y/n]: "
read baseline_reply

if [ "$(lowercase "$baseline_reply")" = "y" ]; then
  pass "Bot replies to DMs (peer group + intents confirmed working)"
else
  fail "Bot did not reply"
  info "Checklist:"
  info "  1. config.toml has [peer_groups.discord_dm] with external_peers = [\"*\"]"
  info "  2. Discord Developer Portal: Message Content Intent ON"
  info "  3. Discord Developer Portal: Server Members Intent ON"
  info "  4. Bot is invited to the server with correct scopes"
  info "  5. zeroclaw daemon is running  (zeroclaw daemon &)"
  echo "${RED}  Cannot continue -- steps 2-9 require DM connectivity.${RESET}"
  echo "  Failures: $FAILURES"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Trigger negotiation, verify no premature grant
# ─────────────────────────────────────────────────────────────────────────────
step "2 -- Tier negotiation (correct prices, no premature grant)"
echo ""
warn "MANUAL ACTION REQUIRED"
info "DM the bot: \"I want to subscribe\""
info "Verify it presents ONLY these two prices:"
info "  standard = 0.001 SOL / 30 min  (testing)"
info "  premium  = 0.0025 SOL / 30 min (testing)"
info "It must never quote any other number."
printf "  Did it present only those two tiers with correct prices? [y/n]: "
read tiers_ok

if [ "$(lowercase "$tiers_ok")" = "y" ]; then
  pass "Correct tiers quoted, no invented prices"
else
  fail "Incorrect tier/price presented -- check negotiate-subscription/SKILL.md Constants section"
fi

if member_has_role "$PRIMARY_USER_ID" "$SUBSCRIBER_ROLE_ID"; then
  fail "Subscriber role already present before payment -- premature grant"
else
  pass "Subscriber role absent (correctly not granted before payment)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Pick tier, get solana: URI, check pending record
# ─────────────────────────────────────────────────────────────────────────────
step "3 -- Tier selection: solana: URI + pending Memory_Store record"
echo ""
warn "MANUAL ACTION REQUIRED"
info "DM the bot: \"standard\""
info "You should receive a solana: payment URI."
printf "  Paste the full solana: URI you received: "
read SOLANA_URI

if echo "$SOLANA_URI" | grep -q "^solana:"; then
  pass "Received a solana: URI"
else
  fail "Response is not a solana: URI (got: ${SOLANA_URI:0:60})"
fi

REFERENCE_KEY=$(echo "$SOLANA_URI" | grep -oE 'reference=[^&]+' | cut -d= -f2 || true)
if [ -n "$REFERENCE_KEY" ]; then
  pass "reference_key present in URI: ${REFERENCE_KEY:0:16}..."
else
  fail "No reference= parameter in URI -- skill may not be calling /keygen"
fi

if echo "$SOLANA_URI" | grep -q "$MERCHANT_WALLET"; then
  pass "Merchant wallet correct in URI"
else
  fail "Wrong merchant wallet in URI -- check negotiate-subscription/SKILL.md Constants"
fi

if echo "$SOLANA_URI" | grep -q "amount=0.001"; then
  pass "Amount 0.001 SOL correct for standard tier"
else
  fail "Amount incorrect in URI (expected amount=0.001 for standard)"
fi

info "Checking Memory_Store for pending_payment record..."
sleep 2
MEM_RECORD=$(memory_subscriber "$PRIMARY_USER_ID" || true)

if [ -n "$MEM_RECORD" ]; then
  pass "Subscriber record found in Memory_Store"

  STATUS=$(json_field "$MEM_RECORD" "status")
  WALLET_IN_MEM=$(json_field "$MEM_RECORD" "wallet_address")
  PERIOD_IN_MEM=$(json_field "$MEM_RECORD" "period_seconds")
  REF_IN_MEM=$(json_field "$MEM_RECORD" "reference_key")

  if [ "$STATUS" = "pending_payment" ]; then
    pass "status = pending_payment"
  else
    fail "status = '${STATUS}' (expected pending_payment)"
  fi

  if [ -n "$REF_IN_MEM" ] && [ "$REF_IN_MEM" != "null" ] && [ "$REF_IN_MEM" != "None" ]; then
    pass "reference_key present in record"
  else
    fail "reference_key missing or null in record"
  fi

  if [ "$WALLET_IN_MEM" = "null" ] || [ "$WALLET_IN_MEM" = "None" ] || [ -z "$WALLET_IN_MEM" ]; then
    pass "wallet_address = null (correctly unpopulated at pending stage)"
  else
    fail "wallet_address already set at pending stage (unexpected): ${WALLET_IN_MEM}"
  fi

  if [ "$PERIOD_IN_MEM" = "1800" ]; then
    pass "period_seconds = 1800 (30-min test value correct)"
  else
    fail "period_seconds = '${PERIOD_IN_MEM}' (expected 1800) -- check negotiate-subscription/SKILL.md"
  fi
else
  fail "No subscriber record found in Memory_Store -- skill may not be persisting the pending record"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Real payment (manual)
# ─────────────────────────────────────────────────────────────────────────────
step "4 -- Real on-chain payment"
echo ""
warn "MANUAL ACTION REQUIRED"
info "Send exactly 0.001 SOL on Solana devnet to:"
info "  ${MERCHANT_WALLET}"
info "Use Phantom or any Solana Pay-compatible wallet."
info "The solana: URI from the bot will pre-fill all fields."
info "After sending, wait ~15 seconds for devnet confirmation."
printf "  Have you sent the payment? [y/n]: "
read payment_sent

if [ "$(lowercase "$payment_sent")" = "y" ]; then
  SKIP_PAYMENT_STEPS="false"
else
  warn "Skipping steps 5-7 (require confirmed on-chain payment)."
  SKIP_PAYMENT_STEPS="true"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — "I paid" triggers RPC check
# ─────────────────────────────────────────────────────────────────────────────
step "5 -- Payment confirmation triggers on-chain verification"
echo ""

if [ "$SKIP_PAYMENT_STEPS" = "true" ]; then
  warn "SKIPPED (no payment sent in step 4)"
else
  warn "MANUAL ACTION REQUIRED"
  info "Reply in the DM: \"I paid\""
  info "The bot should respond confirming the payment was verified on-chain."
  printf "  Did the bot confirm on-chain verification and mention role grant? [y/n]: "
  read rpc_ok

  if [ "$(lowercase "$rpc_ok")" = "y" ]; then
    pass "Bot confirmed on-chain payment verification in DM"
  else
    fail "Bot did not confirm -- check daemon logs: tail -f $HOME/.zeroclaw/logs/*.log"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Role confirmed via Discord API
# ─────────────────────────────────────────────────────────────────────────────
step "6 -- Discord role confirmed via API"
echo ""

if [ "$SKIP_PAYMENT_STEPS" = "true" ]; then
  warn "SKIPPED (no payment sent in step 4)"
else
  info "Querying Discord API for member roles..."
  sleep 3

  MEMBER_JSON=$(curl -sf "${PROXY}/discord/guilds/${GUILD_ID}/members/${PRIMARY_USER_ID}" 2>/dev/null || true)

  if [ -z "$MEMBER_JSON" ]; then
    fail "Could not fetch member record from Discord API"
  else
    HAS_ROLE=$(echo "$MEMBER_JSON" | jq -e --arg r "$SUBSCRIBER_ROLE_ID" '(.roles // []) | index($r) != null' 2>/dev/null || echo "false")
    if [ "$HAS_ROLE" = "true" ]; then
      pass "Subscriber role ${SUBSCRIBER_ROLE_ID} present in Discord member roles"
    else
      fail "Subscriber role NOT in Discord API roles array"
      ROLE_LIST=$(echo "$MEMBER_JSON" | jq -r '.roles // [] | join(", ")' 2>/dev/null || true)
      info "  Current roles: $ROLE_LIST"
    fi
  fi

  info "Also verify manually: can you see the gated channel in Discord?"
  printf "  Visible in Discord client? [y/n]: "
  read discord_visible
  if [ "$(lowercase "$discord_visible")" = "y" ]; then
    pass "Role confirmed visible in Discord client"
  else
    fail "Gated channel not visible -- Discord propagation may be delayed or grant failed"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Memory_Store updated to active
# ─────────────────────────────────────────────────────────────────────────────
step "7 -- Memory_Store record updated to active with wallet + timestamps"
echo ""

if [ "$SKIP_PAYMENT_STEPS" = "true" ]; then
  warn "SKIPPED (no payment sent in step 4)"
else
  info "Checking Memory_Store..."
  sleep 2
  MEM_AFTER=$(memory_subscriber "$PRIMARY_USER_ID" || true)

  if [ -n "$MEM_AFTER" ]; then
    STATUS_AFTER=$(json_field "$MEM_AFTER" "status")
    WALLET_AFTER=$(json_field "$MEM_AFTER" "wallet_address")
    SUB_AT=$(json_field "$MEM_AFTER" "subscribed_at")
    EXP_AT=$(json_field "$MEM_AFTER" "expires_at")

    if [ "$STATUS_AFTER" = "active" ]; then
      pass "status = active"
    else
      fail "status = '${STATUS_AFTER}' (expected active)"
    fi

    if [ -n "$WALLET_AFTER" ] && [ "$WALLET_AFTER" != "null" ] && [ "$WALLET_AFTER" != "None" ]; then
      pass "wallet_address populated: ${WALLET_AFTER:0:8}..."
    else
      fail "wallet_address still null after confirmed payment"
    fi

    if [ -n "$SUB_AT" ] && [ "$SUB_AT" != "null" ] && [ "$SUB_AT" != "None" ]; then
      pass "subscribed_at set: $SUB_AT"
    else
      fail "subscribed_at is null -- skill did not record blockTime"
    fi

    if [ -n "$EXP_AT" ] && [ "$EXP_AT" != "null" ] && [ "$EXP_AT" != "None" ]; then
      pass "expires_at set: $EXP_AT"
    else
      fail "expires_at is null -- skill did not compute blockTime + period_seconds"
    fi
  else
    fail "No subscriber record found in Memory_Store after confirmed payment"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Regression: subscription_check SOP doesn't double-process
# ─────────────────────────────────────────────────────────────────────────────
step "8 -- Regression: subscription_check SOP runs cleanly on active subscriber"
echo ""
info "Running subscription_check SOP manually (may take 30-60s)..."

SOP_OUTPUT=$("$ZC" sop run subscription_check --config-dir "$ZC_CONFIG_DIR" 2>&1 || true)

if echo "$SOP_OUTPUT" | grep -i "grant" | grep -q "$PRIMARY_USER_ID"; then
  fail "SOP attempted to re-grant role for already-active subscriber $PRIMARY_USER_ID"
else
  pass "SOP did not attempt to re-grant role for active subscriber"
fi

if echo "$SOP_OUTPUT" | grep -i "removal_proposed" | grep -q "$PRIMARY_USER_ID"; then
  fail "SOP proposed removal for active subscriber $PRIMARY_USER_ID"
else
  pass "No removal proposal raised for active subscriber"
fi

if echo "$SOP_OUTPUT" | grep -qi "summary\|completed\|processed\|active"; then
  pass "SOP ran to completion"
else
  warn "Could not confirm SOP completion from output -- check logs at $HOME/.zeroclaw/logs/"
  info "SOP output (last 10 lines):"
  echo "$SOP_OUTPUT" | tail -10 | sed 's/^/    /'
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Negative test: no payment -> no role
# ─────────────────────────────────────────────────────────────────────────────
step "9 -- Negative test: unverified claim does not grant role"
echo ""

if [ "$NEGATIVE_USER_ID" = "$PRIMARY_USER_ID" ]; then
  warn "Using same account as primary test."
  warn "For a cleaner negative test, pass a second Discord user ID as arg 2."
fi

warn "MANUAL ACTION REQUIRED"
info "From the test account (ID: ${NEGATIVE_USER_ID}):"
info "  1. DM the bot: \"I want to subscribe\""
info "  2. Reply: \"standard\" (a solana: URI will be generated)"
info "  3. Do NOT send any payment"
info "  4. Reply: \"I paid\""
printf "  Did the bot refuse (say payment not visible / not verified)? [y/n]: "
read negative_ok

if [ "$(lowercase "$negative_ok")" = "y" ]; then
  pass "Bot correctly rejected unverified payment claim"
else
  fail "Bot may have granted role without on-chain verification -- CRITICAL security regression"
fi

info "Verifying via Discord API that no role was granted..."
if member_has_role "$NEGATIVE_USER_ID" "$SUBSCRIBER_ROLE_ID"; then
  fail "Subscriber role found for negative-test user $NEGATIVE_USER_ID -- granted without verified payment"
else
  pass "Subscriber role absent for negative-test user (correctly not granted)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
if [ "$FAILURES" -eq 0 ]; then
  echo "${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
else
  echo "${RED}${BOLD}FAILURES: ${FAILURES}${RESET}"
  echo "  Review the FAIL items above."
fi
echo "=============================================="
echo ""
echo "Production restore checklist (run after testing is complete):"
echo "  sops/subscription_check/SOP.md:"
echo "    period_seconds           = 2592000  (30 days)"
echo "    grace_period_seconds     = 259200   (3 days)"
echo "    renewal_reminder_seconds = 432000   (5 days before expiry)"
echo ""

exit $FAILURES
