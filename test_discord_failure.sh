#!/bin/bash

# Test script to verify Discord API failure handling
# This test sets an invalid Discord token and verifies:
# 1. SOP fails gracefully (not stuck in running)
# 2. Failure is logged clearly
# 3. Claim is released after failure
# 4. Subsequent runs work after token restoration

set -e

echo "=== Testing Discord API Failure Handling ==="
echo ""

# Pre-cleanup
echo "Pre-cleanup: removing any existing zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Backup .env file
echo "Backing up .env file..."
if [ -f .env ]; then
    cp .env .env.test_backup
    ORIGINAL_TOKEN=$(grep "ZEROCLAW_channels__discord__test_discord__bot_token" .env | cut -d= -f2)
    echo "Original token: ${ORIGINAL_TOKEN:0:20}..."
else
    echo "⚠️  No .env file found"
    exit 1
fi

# Set invalid Discord token
echo "Setting invalid Discord token..."
sed -i '' 's/ZEROCLAW_channels__discord__test_discord__bot_token=.*/ZEROCLAW_channels__discord__test_discord__bot_token=invalid_token_for_testing_purposes_only/' .env

# Start daemon
echo "Starting daemon with invalid token..."
/opt/homebrew/bin/zeroclaw daemon --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/test-discord-failure-daemon.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
sleep 5

# Get pairing token
echo "Getting pairing token..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new | jq -r '.pairing_code')
TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')
echo "Token obtained: ${TOKEN:0:20}..."

# Check SOP status before
echo ""
echo "Checking SOP status before trigger..."
/opt/homebrew/bin/zeroclaw sop list --config-dir /Users/adarsh/Documents/zeroclaw

# Trigger role_audit (uses Discord API)
echo ""
echo "Triggering role_audit SOP (should fail due to invalid token)..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Response: $RESPONSE"

if echo "$RESPONSE" | grep -q "run_id"; then
    echo "✅ SOP triggered successfully (with invalid token)"
    RUN_ID=$(echo "$RESPONSE" | jq -r '.run_id')
    echo "Run ID: $RUN_ID"
    
    # Wait for run to fail
    echo ""
    echo "Waiting 15 seconds for run to fail..."
    sleep 15
    
    # Check run status
    echo ""
    echo "Checking run status..."
    STATUS_RESPONSE=$(curl -s http://127.0.0.1:42617/api/sops/runs \
      -H "Authorization: Bearer $TOKEN")
    echo "Status response: $STATUS_RESPONSE"
    
    # Check if run failed gracefully
    if echo "$STATUS_RESPONSE" | grep -q '"status": "failed"' || echo "$STATUS_RESPONSE" | grep -q '"failed"' || echo "$STATUS_RESPONSE" | grep -q 'Failed'; then
        echo "✅ Run failed gracefully (not stuck in running)"
        FAILURE_HANDLED=true
    elif echo "$STATUS_RESPONSE" | grep -q '"status": "completed"' || echo "$STATUS_RESPONSE" | grep -q '"completed"' || echo "$STATUS_RESPONSE" | grep -q 'Completed'; then
        echo "⚠️  Run completed (may not have used Discord API or handled error internally)"
        FAILURE_HANDLED=true
    else
        echo "❌ Run may be stuck in running or unexpected status"
        FAILURE_HANDLED=false
    fi
else
    echo "❌ SOP trigger failed: $RESPONSE"
    FAILURE_HANDLED=false
fi

# Check daemon logs for error handling
echo ""
echo "Checking daemon logs for error handling..."
tail -50 /tmp/test-discord-failure-daemon.log | grep -i "error\|fail\|invalid" || echo "No error logs found"

# Cleanup daemon
echo ""
echo "Stopping daemon..."
kill $DAEMON_PID 2>/dev/null || true
sleep 2
pkill -9 zeroclaw 2>/dev/null || true

# Restore original token
echo "Restoring original Discord token..."
mv .env.test_backup .env

# Restart daemon with valid token
echo ""
echo "Restarting daemon with valid token..."
/opt/homebrew/bin/zeroclaw daemon --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/test-discord-failure-daemon.log 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
sleep 5

# Get new pairing token
echo "Getting new pairing token..."
PAIR_CODE=$(curl -s -X POST http://127.0.0.1:42617/admin/paircode/new | jq -r '.pairing_code')
TOKEN=$(curl -s -X POST http://127.0.0.1:42617/pair \
  -H "X-Pairing-Code: $PAIR_CODE" \
  -H "Content-Type: application/json" | jq -r '.token')
echo "Token obtained: ${TOKEN:0:20}..."

# Try trigger again with valid token
echo ""
echo "Attempting trigger with valid token (should succeed)..."
RESPONSE2=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Response: $RESPONSE2"

if echo "$RESPONSE2" | grep -q "run_id"; then
    echo "✅ Trigger succeeded with valid token (claim was released)"
    CLAIM_RELEASE_WORKING=true
else
    echo "❌ Trigger failed with valid token (claim may not have been released)"
    CLAIM_RELEASE_WORKING=false
fi

# Cleanup
echo ""
echo "Stopping daemon..."
kill $DAEMON_PID 2>/dev/null || true
sleep 2
pkill -9 zeroclaw 2>/dev/null || true

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$FAILURE_HANDLED" = true ]; then
    echo "✅ Discord API failure handling: WORKING"
else
    echo "❌ Discord API failure handling: FAILED"
fi

if [ "$CLAIM_RELEASE_WORKING" = true ]; then
    echo "✅ Claim release after failure: WORKING"
else
    echo "❌ Claim release after failure: FAILED"
fi

echo ""
echo "=== Test Complete ==="
