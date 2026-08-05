#!/bin/bash

# Test script to verify concurrency guard and claim-release mechanism
# This test manually triggers an SOP during an active cron run to verify:
# 1. Concurrency guard rejects the second attempt
# 2. Claim is released after completion
# 3. Subsequent runs succeed after completion

set -e

echo "=== Testing Concurrency Guard and Claim-Release ==="
echo ""

# Pre-cleanup
echo "Pre-cleanup: removing any existing zeroclaw processes..."
pkill -9 zeroclaw 2>/dev/null || true
sleep 2

# Start daemon
echo "Starting daemon with project config..."
/opt/homebrew/bin/zeroclaw daemon --config-dir /Users/adarsh/Documents/zeroclaw > /tmp/test-concurrency-daemon.log 2>&1 &
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

# Check for active runs
echo ""
echo "Checking for active SOP runs..."
/opt/homebrew/bin/zeroclaw sop list --config-dir /Users/adarsh/Documents/zeroclaw

# Trigger first run manually (since cron might not align)
echo ""
echo "Triggering first run manually..."
RESPONSE0=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "First trigger response: $RESPONSE0"

if echo "$RESPONSE0" | grep -q "run_id"; then
    echo "✅ First trigger succeeded"
    RUN_ID=$(echo "$RESPONSE0" | jq -r '.run_id')
    echo "Run ID: $RUN_ID"
else
    echo "❌ First trigger failed: $RESPONSE0"
    exit 1
fi

# Wait a moment for run to start
echo ""
echo "Waiting 5 seconds for run to start..."
sleep 5

# Try to manually trigger during active run
echo ""
echo "Attempting second trigger during active run (should be rejected)..."
RESPONSE1=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Response: $RESPONSE1"

if echo "$RESPONSE1" | grep -q "cooldown\|concurrency\|limit"; then
    echo "✅ Concurrency guard correctly rejected second trigger during active run"
    CONCURRENCY_REJECTED=true
elif echo "$RESPONSE1" | grep -q "run_id"; then
    echo "⚠️  Second trigger succeeded (concurrency guard may not be working)"
    CONCURRENCY_REJECTED=false
else
    echo "⚠️  Unexpected response: $RESPONSE1"
    CONCURRENCY_REJECTED=false
fi

# Wait for active run to complete
echo ""
echo "Waiting 30 seconds for active run to complete..."
sleep 30

# Check run status
echo ""
echo "Checking run status..."
/opt/homebrew/bin/zeroclaw sop list --config-dir /Users/adarsh/Documents/zeroclaw

# Try manual trigger again (should succeed now)
echo ""
echo "Attempting third trigger after completion (should succeed)..."
RESPONSE2=$(curl -s -X POST http://127.0.0.1:42617/api/sops/role_audit/run \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}')
echo "Response: $RESPONSE2"

if echo "$RESPONSE2" | grep -q "run_id"; then
    echo "✅ Third trigger succeeded after completion (claim was released)"
    CLAIM_RELEASED=true
else
    echo "❌ Third trigger failed after completion (claim may not have been released)"
    CLAIM_RELEASED=false
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
if [ "$CONCURRENCY_REJECTED" = true ]; then
    echo "✅ Concurrency guard: WORKING"
else
    echo "❌ Concurrency guard: FAILED/INCONCLUSIVE"
fi

if [ "$CLAIM_RELEASED" = true ]; then
    echo "✅ Claim release: WORKING"
else
    echo "❌ Claim release: FAILED"
fi

echo ""
echo "=== Test Complete ==="
